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
        case needsExistingOpenClawImport([OpenClawInstanceCandidate])
        case ready
        case failed(String)
    }

    private(set) var status: Status = .loading
    private(set) var profiles: [GatewayProfile] = []
    private(set) var selectedProfileID: UUID?

    @ObservationIgnored
    private var didLoad = false

    init() {
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

    var selectedLocalPaths: GatewayProfileLocalPaths? {
        selectedResolution?.localPaths
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
        EZRWorkerPaths.ensureApplicationSupportDirectories()

        if let document = readProfilesDocument() {
            profiles = document.profiles.sorted(by: { $0.createdAt < $1.createdAt })
            if profiles.isEmpty {
                restoreDefaultProfileAfterEmptyDocument()
                return
            }
            ensureSelectedProfileExists()
            status = .ready
            return
        }

        if FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path) {
            let candidates = OpenClawInstanceDiscoveryService.scanLightweightCandidates()
            if candidates.contains(where: { !Self.isLegacyConfigPath($0.configPath) }) || candidates.count > 1 {
                profiles = []
                selectedProfileID = nil
                status = .needsExistingOpenClawImport(candidates)
                return
            }

            profiles = []
            selectedProfileID = nil
            status = .needsLegacyMigration(legacyPort: GatewayProfileResolver.readLegacyGatewayPort())
            return
        }

        let candidates = OpenClawInstanceDiscoveryService.scanLightweightCandidates()
        if !candidates.isEmpty {
            profiles = []
            selectedProfileID = nil
            status = .needsExistingOpenClawImport(candidates)
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

    func skipExistingOpenClawImportAndCreateManagedProfile() throws {
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

    @discardableResult
    func importExternalProfile(
        candidate: OpenClawInstanceCandidate,
        displayName: String? = nil,
        slug: String? = nil,
        autoStart: Bool = false,
        managementMode: GatewayProfileManagementMode = .observeOnly,
        launchAgentHandoff: GatewayProfileLaunchAgentHandoff? = nil
    ) throws -> GatewayProfile {
        let normalizedConfigPath = try normalizedExistingConfigPath(candidate.configPath)
        let normalizedStateDir = try normalizedExternalDirectoryPath(
            candidate.stateDir,
            label: "OPENCLAW_STATE_DIR"
        )
        let normalizedWorkspaceRoot = try normalizedOptionalExternalDirectoryPath(
            candidate.workspaceRoot ?? Self.inferWorkspaceRoot(
                configPath: normalizedConfigPath,
                stateDir: normalizedStateDir
            ),
            label: "workspaceRoot"
        )
        let resolvedPort = candidate.port
            ?? Self.readGatewayPort(configPath: normalizedConfigPath)
            ?? GatewayProfileResolver.defaultGatewayPort
        let resolvedHandoff = try resolvedLaunchAgentHandoff(
            candidate: candidate,
            managementMode: managementMode,
            launchAgentHandoff: launchAgentHandoff
        )

        try validateExternalProfileImport(
            configPath: normalizedConfigPath,
            stateDir: normalizedStateDir,
            workspaceRoot: normalizedWorkspaceRoot,
            port: resolvedPort,
            managementMode: managementMode
        )

        let requestedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = candidate.displayNameSuggestion.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalDisplayName = requestedName?.isEmpty == false
            ? requestedName!
            : (fallbackName.isEmpty ? "Imported OpenClaw" : fallbackName)
        let baseSlug = slug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? slug!
            : candidate.slugSuggestion
        let resolvedSlug = GatewayProfileResolver.makeUniqueSlug(base: baseSlug, existing: profiles)

        let profile = GatewayProfile(
            id: UUID(),
            slug: resolvedSlug,
            displayName: finalDisplayName,
            autoStart: managementMode == .observeOnly ? false : autoStart,
            sourceKind: .externalReuse,
            managementMode: managementMode,
            configPathOverride: normalizedConfigPath,
            stateDirOverride: normalizedStateDir,
            workspaceRootOverride: normalizedWorkspaceRoot,
            portOverride: resolvedPort,
            createdAt: Date(),
            launchAgentHandoff: resolvedHandoff
        )

        profiles.append(profile)
        profiles.sort(by: { $0.createdAt < $1.createdAt })
        selectProfile(id: profile.id)
        try persistProfiles()
        status = .ready
        return profile
    }

    private func resolvedLaunchAgentHandoff(
        candidate: OpenClawInstanceCandidate,
        managementMode: GatewayProfileManagementMode,
        launchAgentHandoff: GatewayProfileLaunchAgentHandoff?
    ) throws -> GatewayProfileLaunchAgentHandoff? {
        guard let launchAgent = candidate.launchAgent else {
            return nil
        }

        if managementMode == .managedByEZRWorker {
            guard let launchAgentHandoff,
                  launchAgentHandoff.status == .disabled else {
                throw NSError(domain: "GatewayProfileStore", code: 33, userInfo: [
                    NSLocalizedDescriptionKey:
                        "该实例仍由旧 LaunchAgent 管理。请先完成交接旧自启项，或改为仅观察模式。"
                ])
            }
            return launchAgentHandoff
        }

        return GatewayProfileLaunchAgentHandoff(
            originalLabel: launchAgent.label,
            originalPlistPath: launchAgent.plistPath,
            disabledPlistPath: nil,
            disabledAt: nil,
            status: .pending,
            message: "仅观察模式保留旧 LaunchAgent，由原启动链路继续管理"
        )
    }

    func update(profileID: UUID, autoStart: Bool) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].autoStart = profiles[index].managementMode == .observeOnly ? false : autoStart
        try persistProfiles()
    }

    func update(profileID: UUID, launchAgentHandoff: GatewayProfileLaunchAgentHandoff) throws {
        guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { return }
        profiles[index].launchAgentHandoff = launchAgentHandoff
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
        try validateOverridePath(
            configPathOverride,
            label: "OPENCLAW_CONFIG_PATH",
            expectsDirectory: false,
            invalidPathCode: 1,
            unusablePathCode: 7
        )
        try validateOverridePath(
            stateDirOverride,
            label: "OPENCLAW_STATE_DIR",
            expectsDirectory: true,
            invalidPathCode: 2,
            unusablePathCode: 8
        )
        try validateOverridePath(
            workspaceRootOverride,
            label: "workspaceRoot",
            expectsDirectory: true,
            invalidPathCode: 3,
            unusablePathCode: 9
        )
        if let portOverride {
            guard (1...65535).contains(portOverride) else {
                throw NSError(domain: "GatewayProfileStore", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "端口必须位于 1-65535"
                ])
            }
            let usedPorts = profiles.map { GatewayProfileResolver.resolve($0).resolvedPort }
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

    private func validateExternalProfileImport(
        configPath: String,
        stateDir: String,
        workspaceRoot: String?,
        port: Int,
        managementMode: GatewayProfileManagementMode
    ) throws {
        guard (1...65535).contains(port) else {
            throw NSError(domain: "GatewayProfileStore", code: 20, userInfo: [
                NSLocalizedDescriptionKey: "端口必须位于 1-65535"
            ])
        }

        let normalizedConfigPath = Self.standardizedPath(configPath)
        if profiles.contains(where: {
            Self.standardizedPath(GatewayProfileResolver.resolve($0).resolvedConfigPath) == normalizedConfigPath
        }) {
            throw NSError(domain: "GatewayProfileStore", code: 21, userInfo: [
                NSLocalizedDescriptionKey: "该 OpenClaw 配置已经导入过"
            ])
        }

        let usedPorts = profiles.map { GatewayProfileResolver.resolve($0).resolvedPort }
        let conflictingPorts = GatewayProfileResolver.conflictingBasePorts(
            for: port,
            existingPorts: usedPorts
        )
        if !conflictingPorts.isEmpty {
            let conflicts = conflictingPorts.map(String.init).joined(separator: ", ")
            throw NSError(domain: "GatewayProfileStore", code: 22, userInfo: [
                NSLocalizedDescriptionKey:
                    "端口 \(port) 与现有 profile 基础端口 \(conflicts) 间距不足 \(GatewayProfileResolver.managedPortSpacing)，请先调整后再导入"
            ])
        }

        if managementMode == .managedByEZRWorker {
            try validateOverridePath(
                configPath,
                label: "OPENCLAW_CONFIG_PATH",
                expectsDirectory: false,
                invalidPathCode: 23,
                unusablePathCode: 24
            )
            try validateOverridePath(
                stateDir,
                label: "OPENCLAW_STATE_DIR",
                expectsDirectory: true,
                invalidPathCode: 25,
                unusablePathCode: 26
            )
            try validateOverridePath(
                workspaceRoot,
                label: "workspaceRoot",
                expectsDirectory: true,
                invalidPathCode: 27,
                unusablePathCode: 28
            )
        }
    }

    private func normalizedExistingConfigPath(_ path: String) throws -> String {
        guard let url = GatewayProfileResolver.absoluteURLIfValid(path: path) else {
            throw NSError(domain: "GatewayProfileStore", code: 29, userInfo: [
                NSLocalizedDescriptionKey: "OPENCLAW_CONFIG_PATH 必须是绝对路径"
            ])
        }

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            throw NSError(domain: "GatewayProfileStore", code: 30, userInfo: [
                NSLocalizedDescriptionKey: "未找到 openclaw.json：\(url.path)"
            ])
        }
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw NSError(domain: "GatewayProfileStore", code: 31, userInfo: [
                NSLocalizedDescriptionKey: "openclaw.json 不可读：\(url.path)"
            ])
        }
        return url.standardizedFileURL.path
    }

    private func normalizedExternalDirectoryPath(_ path: String, label: String) throws -> String {
        guard let url = GatewayProfileResolver.absoluteURLIfValid(path: path) else {
            throw NSError(domain: "GatewayProfileStore", code: 32, userInfo: [
                NSLocalizedDescriptionKey: "\(label) 必须是绝对路径"
            ])
        }
        return url.standardizedFileURL.path
    }

    private func normalizedOptionalExternalDirectoryPath(_ path: String?, label: String) throws -> String? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return try normalizedExternalDirectoryPath(path, label: label)
    }

    private func validateOverridePath(
        _ path: String?,
        label: String,
        expectsDirectory: Bool,
        invalidPathCode: Int,
        unusablePathCode: Int
    ) throws {
        guard let path else { return }
        guard let url = GatewayProfileResolver.absoluteURLIfValid(path: path) else {
            throw NSError(domain: "GatewayProfileStore", code: invalidPathCode, userInfo: [
                NSLocalizedDescriptionKey: "\(label) 必须是绝对路径"
            ])
        }

        let fm = FileManager.default
        var isDirectory = ObjCBool(false)
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if expectsDirectory && !isDirectory.boolValue {
                throw NSError(domain: "GatewayProfileStore", code: unusablePathCode, userInfo: [
                    NSLocalizedDescriptionKey: "\(label) 已存在，但不是目录"
                ])
            }
            if !expectsDirectory && isDirectory.boolValue {
                throw NSError(domain: "GatewayProfileStore", code: unusablePathCode, userInfo: [
                    NSLocalizedDescriptionKey: "\(label) 不能指向目录"
                ])
            }
        }

        let parentURL = url.deletingLastPathComponent()
        guard let existingParent = nearestExistingDirectory(startingAt: parentURL) else {
            throw NSError(domain: "GatewayProfileStore", code: unusablePathCode, userInfo: [
                NSLocalizedDescriptionKey: "\(label) 的父目录不存在且无法解析"
            ])
        }

        guard fm.isWritableFile(atPath: existingParent.path) else {
            throw NSError(domain: "GatewayProfileStore", code: unusablePathCode, userInfo: [
                NSLocalizedDescriptionKey: "\(label) 的父目录不可写：\(existingParent.path)"
            ])
        }
    }

    private func nearestExistingDirectory(startingAt url: URL) -> URL? {
        let fm = FileManager.default
        var currentURL = url

        while true {
            var isDirectory = ObjCBool(false)
            if fm.fileExists(atPath: currentURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return nil
            }
            currentURL = parentURL
        }
    }

    private func normalizedPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func ensureSelectedProfileExists() {
        guard !profiles.isEmpty else {
            selectedProfileID = nil
            UserDefaults.standard.removeObject(forKey: EZRWorkerBranding.lastSelectedProfileDefaultsKey)
            return
        }

        if let selectedProfileID,
           profiles.contains(where: { $0.id == selectedProfileID }) {
            return
        }
        if let first = profiles.first {
            selectProfile(id: first.id)
        }
    }

    private func restoreDefaultProfileAfterEmptyDocument() {
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
            ensureSelectedProfileExists()
            status = .failed(error.localizedDescription)
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
        let usedPorts = profiles.map { GatewayProfileResolver.resolve($0).resolvedPort }
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

    private static func isLegacyConfigPath(_ path: String) -> Bool {
        standardizedPath(path) == standardizedPath(EZRWorkerPaths.legacyOpenClawConfigURL.path)
    }

    static func readGatewayPort(configPath: String) -> Int? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any]
        else {
            return nil
        }
        if let number = gateway["port"] as? NSNumber {
            return number.intValue
        }
        if let intValue = gateway["port"] as? Int {
            return intValue
        }
        return nil
    }

    static func inferWorkspaceRoot(configPath: String, stateDir: String) -> String {
        if let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let agents = json["agents"] as? [String: Any],
           let defaults = agents["defaults"] as? [String: Any],
           let workspace = defaults["workspace"] as? String,
           !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let expanded = NSString(string: workspace).expandingTildeInPath
            if expanded.hasPrefix("/") {
                return URL(fileURLWithPath: expanded).standardizedFileURL.path
            }
            return URL(fileURLWithPath: stateDir, isDirectory: true)
                .appendingPathComponent(expanded)
                .standardizedFileURL
                .path
        }

        return URL(fileURLWithPath: stateDir, isDirectory: true)
            .appendingPathComponent("workspace", isDirectory: true)
            .standardizedFileURL
            .path
    }

    static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }
}
