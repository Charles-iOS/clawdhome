import Foundation
import Observation

@MainActor
@Observable
final class GatewayProfileStore {
    struct DeleteProfileResult {
        var deletedProfile: GatewayProfile
        var replacementProfile: GatewayProfile?
        var deletedWasSelected: Bool
        var createdReplacement: Bool
    }

    enum Status: Equatable {
        case loading
        case needsLegacyMigration(legacyPort: Int?)
        case ready
        case failed(String)
    }

    private(set) var status: Status = .loading
    private(set) var profiles: [GatewayProfile] = []
    private(set) var selectedProfileID: UUID?

    @ObservationIgnored
    private let migrationManager: BrandMigrationManager
    @ObservationIgnored
    private var didLoad = false

    convenience init() {
        self.init(migrationManager: BrandMigrationManager())
    }

    init(migrationManager: BrandMigrationManager) {
        self.migrationManager = migrationManager
        if let raw = UserDefaults.standard.string(forKey: EZRWorkerBranding.lastSelectedProfileDefaultsKey),
           let uuid = UUID(uuidString: raw) {
            self.selectedProfileID = uuid
        }
    }

    var selectedProfile: GatewayProfile? {
        guard let selectedProfileID else { return profiles.first }
        return profiles.first(where: { $0.id == selectedProfileID }) ?? profiles.first
    }

    var selectedResolution: GatewayProfileResolution? {
        selectedProfile.map(GatewayProfileResolver.resolve(_:))
    }

    var canBootstrap: Bool {
        if case .ready = status, selectedProfile != nil {
            return true
        }
        return false
    }

    var hasImportedLegacyProfile: Bool {
        profiles.contains(where: { $0.sourceKind == .legacyReuse })
    }

    func loadIfNeeded() async {
        guard !didLoad else { return }
        didLoad = true
        reloadFromDiskOrBootstrap()
    }

    func reloadFromDiskOrBootstrap() {
        status = .loading
        migrationManager.migrateIfNeeded()
        EZRWorkerPaths.ensureApplicationSupportDirectories()

        if let document = readProfilesDocument() {
            profiles = document.profiles.sorted(by: { $0.createdAt < $1.createdAt })
            ensureSelectedProfileExists()
            status = .ready
            return
        }

        if FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path) {
            profiles = []
            selectedProfileID = nil
            status = .needsLegacyMigration(legacyPort: GatewayProfileResolver.readLegacyGatewayPort())
            return
        }

        do {
            let profile = try makeManagedProfile(
                displayName: "Default",
                requestedSlug: "default",
                autoStart: true,
                configPathOverride: nil,
                stateDirOverride: nil,
                workspaceRootOverride: nil,
                portOverride: nil
            )
            profiles = [profile]
            selectProfile(id: profile.id)
            try persistProfiles()
            status = .ready
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func selectProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        selectedProfileID = id
        UserDefaults.standard.set(id.uuidString, forKey: EZRWorkerBranding.lastSelectedProfileDefaultsKey)
    }

    func completeLegacyReuseMigration() throws {
        let port = GatewayProfileResolver.readLegacyGatewayPort()
            ?? GatewayProfileResolver.defaultGatewayPort
        let profile = GatewayProfile(
            id: UUID(),
            slug: GatewayProfileResolver.makeUniqueSlug(base: "default", existing: profiles),
            displayName: "Default",
            autoStart: true,
            sourceKind: .legacyReuse,
            configPathOverride: EZRWorkerPaths.legacyOpenClawConfigURL.path,
            stateDirOverride: EZRWorkerPaths.legacyOpenClawDirectory.path,
            workspaceRootOverride: EZRWorkerPaths.legacyOpenClawDirectory
                .appendingPathComponent("workspace", isDirectory: true)
                .path,
            portOverride: port,
            createdAt: Date()
        )
        profiles = [profile]
        selectProfile(id: profile.id)
        try persistProfiles()
        status = .ready
    }

    func completeCreateNewMigration() throws {
        let profile = try makeManagedProfile(
            displayName: "Default",
            requestedSlug: "default",
            autoStart: true,
            configPathOverride: nil,
            stateDirOverride: nil,
            workspaceRootOverride: nil,
            portOverride: nil
        )
        profiles = [profile]
        selectProfile(id: profile.id)
        try persistProfiles()
        status = .ready
    }

    @discardableResult
    func createManagedProfile(
        displayName: String,
        slug: String? = nil,
        autoStart: Bool = true,
        configPathOverride: String? = nil,
        stateDirOverride: String? = nil,
        workspaceRootOverride: String? = nil,
        portOverride: Int? = nil
    ) throws -> GatewayProfile {
        let profile = try makeManagedProfile(
            displayName: displayName,
            requestedSlug: slug,
            autoStart: autoStart,
            configPathOverride: configPathOverride,
            stateDirOverride: stateDirOverride,
            workspaceRootOverride: workspaceRootOverride,
            portOverride: portOverride
        )
        profiles.append(profile)
        profiles.sort(by: { $0.createdAt < $1.createdAt })
        selectProfile(id: profile.id)
        try persistProfiles()
        status = .ready
        return profile
    }

    @discardableResult
    func importLegacyProfile(
        displayName: String = "Imported Legacy",
        slug: String? = nil,
        autoStart: Bool = false
    ) throws -> GatewayProfile {
        guard FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path) else {
            throw NSError(domain: "GatewayProfileStore", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "未找到 ~/.openclaw/openclaw.json"
            ])
        }

        let resolvedSlug = GatewayProfileResolver.makeUniqueSlug(
            base: slug ?? displayName,
            existing: profiles
        )
        let profile = GatewayProfile(
            id: UUID(),
            slug: resolvedSlug,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? resolvedSlug : displayName,
            autoStart: autoStart,
            sourceKind: .legacyReuse,
            configPathOverride: EZRWorkerPaths.legacyOpenClawConfigURL.path,
            stateDirOverride: EZRWorkerPaths.legacyOpenClawDirectory.path,
            workspaceRootOverride: EZRWorkerPaths.legacyOpenClawDirectory
                .appendingPathComponent("workspace", isDirectory: true)
                .path,
            portOverride: try validatedLegacyPort(),
            createdAt: Date()
        )
        profiles.append(profile)
        profiles.sort(by: { $0.createdAt < $1.createdAt })
        selectProfile(id: profile.id)
        try persistProfiles()
        status = .ready
        return profile
    }

    func update(profileID: UUID, autoStart: Bool) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].autoStart = autoStart
        try persistProfiles()
    }

    @discardableResult
    func deleteProfile(profileID: UUID) throws -> DeleteProfileResult {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else {
            throw NSError(domain: "GatewayProfileStore", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "未找到要删除的 profile"
            ])
        }

        let currentSelectedID = selectedProfile?.id
        let deletedProfile = profiles.remove(at: index)
        let deletedWasSelected = currentSelectedID == deletedProfile.id

        var replacementProfile: GatewayProfile?
        var createdReplacement = false

        if profiles.isEmpty {
            let replacement = try makeManagedProfile(
                displayName: "Default",
                requestedSlug: "default",
                autoStart: true,
                configPathOverride: nil,
                stateDirOverride: nil,
                workspaceRootOverride: nil,
                portOverride: nil
            )
            profiles = [replacement]
            replacementProfile = replacement
            createdReplacement = true
            selectProfile(id: replacement.id)
        } else if deletedWasSelected {
            let fallbackIndex = min(index, profiles.count - 1)
            let fallbackProfile = profiles[fallbackIndex]
            replacementProfile = fallbackProfile
            selectProfile(id: fallbackProfile.id)
        } else {
            ensureSelectedProfileExists()
        }

        try persistProfiles()
        cleanupManagedProfileData(for: deletedProfile)
        status = .ready

        return DeleteProfileResult(
            deletedProfile: deletedProfile,
            replacementProfile: replacementProfile,
            deletedWasSelected: deletedWasSelected,
            createdReplacement: createdReplacement
        )
    }

    private func makeManagedProfile(
        displayName: String,
        requestedSlug: String?,
        autoStart: Bool,
        configPathOverride: String?,
        stateDirOverride: String?,
        workspaceRootOverride: String?,
        portOverride: Int?
    ) throws -> GatewayProfile {
        let trimmedName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseSlug = requestedSlug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? requestedSlug!
            : trimmedName
        let slug = GatewayProfileResolver.makeUniqueSlug(base: baseSlug, existing: profiles)

        try validateOverrides(
            configPathOverride: configPathOverride,
            stateDirOverride: stateDirOverride,
            workspaceRootOverride: workspaceRootOverride,
            portOverride: portOverride
        )

        return GatewayProfile(
            id: UUID(),
            slug: slug,
            displayName: trimmedName.isEmpty ? slug : trimmedName,
            autoStart: autoStart,
            sourceKind: .managed,
            configPathOverride: normalizedPath(configPathOverride),
            stateDirOverride: normalizedPath(stateDirOverride),
            workspaceRootOverride: normalizedPath(workspaceRootOverride),
            portOverride: portOverride ?? suggestedManagedPort(),
            createdAt: Date()
        )
    }

    private func validateOverrides(
        configPathOverride: String?,
        stateDirOverride: String?,
        workspaceRootOverride: String?,
        portOverride: Int?
    ) throws {
        guard GatewayProfileResolver.validateAbsoluteOverridePath(configPathOverride) else {
            throw NSError(domain: "GatewayProfileStore", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "OPENCLAW_CONFIG_PATH 必须是绝对路径"
            ])
        }
        guard GatewayProfileResolver.validateAbsoluteOverridePath(stateDirOverride) else {
            throw NSError(domain: "GatewayProfileStore", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "OPENCLAW_STATE_DIR 必须是绝对路径"
            ])
        }
        guard GatewayProfileResolver.validateAbsoluteOverridePath(workspaceRootOverride) else {
            throw NSError(domain: "GatewayProfileStore", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "workspaceRoot 必须是绝对路径"
            ])
        }
        if let portOverride {
            guard (1...65535).contains(portOverride) else {
                throw NSError(domain: "GatewayProfileStore", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "端口必须位于 1-65535"
                ])
            }
            let usedPorts = profiles.compactMap(\.portOverride)
            let conflictingPorts = GatewayProfileResolver.conflictingBasePorts(
                for: portOverride,
                existingPorts: usedPorts
            )
            if !conflictingPorts.isEmpty {
                let conflicts = conflictingPorts.map(String.init).joined(separator: ", ")
                throw NSError(domain: "GatewayProfileStore", code: 5, userInfo: [
                    NSLocalizedDescriptionKey:
                        "端口 \(portOverride) 与现有 profile 基础端口 \(conflicts) 间距不足 \(GatewayProfileResolver.managedPortSpacing)，请至少保留 \(GatewayProfileResolver.managedPortSpacing) 个端口间隔"
                ])
            }
        }
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensureSelectedProfileExists() {
        if let selectedProfileID,
           profiles.contains(where: { $0.id == selectedProfileID }) {
            return
        }
        if let first = profiles.first {
            selectProfile(id: first.id)
        }
    }

    private func readProfilesDocument() -> GatewayProfilesDocument? {
        guard let data = try? Data(contentsOf: EZRWorkerPaths.profilesDocumentURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GatewayProfilesDocument.self, from: data)
    }

    private func persistProfiles() throws {
        EZRWorkerPaths.ensureApplicationSupportDirectories()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let document = GatewayProfilesDocument(profiles: profiles)
        let data = try encoder.encode(document)
        try data.write(to: EZRWorkerPaths.profilesDocumentURL, options: .atomic)
    }

    private func suggestedManagedPort() -> Int {
        var candidateProfiles = profiles
        if !hasImportedLegacyProfile,
           FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path),
           let legacyPort = GatewayProfileResolver.readLegacyGatewayPort() {
            candidateProfiles.append(
                GatewayProfile(
                    id: UUID(),
                    slug: "legacy-reserved-port",
                    displayName: "legacy-reserved-port",
                    autoStart: false,
                    sourceKind: .legacyReuse,
                    configPathOverride: nil,
                    stateDirOverride: nil,
                    workspaceRootOverride: nil,
                    portOverride: legacyPort,
                    createdAt: .distantPast
                )
            )
        }
        return GatewayProfileResolver.nextAvailablePort(existingProfiles: candidateProfiles)
    }

    private func validatedLegacyPort() throws -> Int {
        let legacyPort = GatewayProfileResolver.readLegacyGatewayPort() ?? GatewayProfileResolver.defaultGatewayPort
        let usedPorts = profiles.compactMap(\.portOverride)
        let conflictingPorts = GatewayProfileResolver.conflictingBasePorts(
            for: legacyPort,
            existingPorts: usedPorts
        )
        guard conflictingPorts.isEmpty else {
            let conflicts = conflictingPorts.map(String.init).joined(separator: ", ")
            throw NSError(domain: "GatewayProfileStore", code: 6, userInfo: [
                NSLocalizedDescriptionKey:
                    "旧 ~/.openclaw 当前端口 \(legacyPort) 与现有 profile 基础端口 \(conflicts) 间距不足 \(GatewayProfileResolver.managedPortSpacing)，请先调整后再导入"
            ])
        }
        return legacyPort
    }

    private func cleanupManagedProfileData(for profile: GatewayProfile) {
        guard profile.sourceKind == .managed else { return }
        let managedRootURL = EZRWorkerPaths.managedProfileRoot(slug: profile.slug)
        guard FileManager.default.fileExists(atPath: managedRootURL.path) else { return }
        try? FileManager.default.removeItem(at: managedRootURL)
    }
}
