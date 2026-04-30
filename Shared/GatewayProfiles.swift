import Darwin
import Foundation

enum GatewayProfileSourceKind: String, Codable, CaseIterable {
    case managed
    case legacyReuse
    case externalReuse
}

enum GatewayProfileManagementMode: String, Codable, CaseIterable {
    case managedByEZRWorker
    case observeOnly
}

enum OpenClawLaunchAgentDomain: String, Codable, CaseIterable {
    case user
    case systemLaunchAgent
}

struct OpenClawLaunchAgentInfo: Codable, Hashable {
    var label: String
    var plistPath: String
    var domain: OpenClawLaunchAgentDomain
    var programArguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var keepAlive: Bool
    var runAtLoad: Bool
    var isLoaded: Bool?
    var isWritableByCurrentUser: Bool
    var requiresAdminForDisable: Bool
    var matchedConfigPath: String?
    var matchedStateDir: String?
    var matchReason: String
}

enum LaunchAgentHandoffStatus: String, Codable, CaseIterable {
    case notRequired
    case pending
    case disabled
    case manualRequired
    case failed
}

struct GatewayProfileLaunchAgentHandoff: Codable, Hashable {
    var originalLabel: String
    var originalPlistPath: String
    var disabledPlistPath: String?
    var disabledAt: Date?
    var status: LaunchAgentHandoffStatus
    var message: String?
}

struct GatewayProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var slug: String
    var displayName: String
    var autoStart: Bool
    var sourceKind: GatewayProfileSourceKind
    var managementMode: GatewayProfileManagementMode
    var configPathOverride: String?
    var stateDirOverride: String?
    var workspaceRootOverride: String?
    var portOverride: Int?
    var createdAt: Date
    var launchAgentHandoff: GatewayProfileLaunchAgentHandoff?

    init(
        id: UUID,
        slug: String,
        displayName: String,
        autoStart: Bool,
        sourceKind: GatewayProfileSourceKind,
        managementMode: GatewayProfileManagementMode? = nil,
        configPathOverride: String?,
        stateDirOverride: String?,
        workspaceRootOverride: String?,
        portOverride: Int?,
        createdAt: Date,
        launchAgentHandoff: GatewayProfileLaunchAgentHandoff? = nil
    ) {
        let resolvedManagementMode = managementMode ?? Self.defaultManagementMode(for: sourceKind)
        self.id = id
        self.slug = slug
        self.displayName = displayName
        self.autoStart = resolvedManagementMode == .observeOnly ? false : autoStart
        self.sourceKind = sourceKind
        self.managementMode = resolvedManagementMode
        self.configPathOverride = configPathOverride
        self.stateDirOverride = stateDirOverride
        self.workspaceRootOverride = workspaceRootOverride
        self.portOverride = portOverride
        self.createdAt = createdAt
        self.launchAgentHandoff = launchAgentHandoff
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case slug
        case displayName
        case autoStart
        case sourceKind
        case managementMode
        case configPathOverride
        case stateDirOverride
        case workspaceRootOverride
        case portOverride
        case createdAt
        case launchAgentHandoff
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceKind = try container.decode(GatewayProfileSourceKind.self, forKey: .sourceKind)
        let managementMode = try container.decodeIfPresent(
            GatewayProfileManagementMode.self,
            forKey: .managementMode
        ) ?? Self.defaultManagementMode(for: sourceKind)

        self.id = try container.decode(UUID.self, forKey: .id)
        self.slug = try container.decode(String.self, forKey: .slug)
        self.displayName = try container.decode(String.self, forKey: .displayName)
        let decodedAutoStart = try container.decode(Bool.self, forKey: .autoStart)
        self.autoStart = managementMode == .observeOnly ? false : decodedAutoStart
        self.sourceKind = sourceKind
        self.managementMode = managementMode
        self.configPathOverride = try container.decodeIfPresent(String.self, forKey: .configPathOverride)
        self.stateDirOverride = try container.decodeIfPresent(String.self, forKey: .stateDirOverride)
        self.workspaceRootOverride = try container.decodeIfPresent(String.self, forKey: .workspaceRootOverride)
        self.portOverride = try container.decodeIfPresent(Int.self, forKey: .portOverride)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.launchAgentHandoff = try container.decodeIfPresent(
            GatewayProfileLaunchAgentHandoff.self,
            forKey: .launchAgentHandoff
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(slug, forKey: .slug)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(autoStart, forKey: .autoStart)
        try container.encode(sourceKind, forKey: .sourceKind)
        try container.encode(managementMode, forKey: .managementMode)
        try container.encodeIfPresent(configPathOverride, forKey: .configPathOverride)
        try container.encodeIfPresent(stateDirOverride, forKey: .stateDirOverride)
        try container.encodeIfPresent(workspaceRootOverride, forKey: .workspaceRootOverride)
        try container.encodeIfPresent(portOverride, forKey: .portOverride)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(launchAgentHandoff, forKey: .launchAgentHandoff)
    }

    static func defaultManagementMode(for sourceKind: GatewayProfileSourceKind) -> GatewayProfileManagementMode {
        switch sourceKind {
        case .managed, .legacyReuse:
            return .managedByEZRWorker
        case .externalReuse:
            return .observeOnly
        }
    }
}

struct GatewayProfilesDocument: Codable {
    var version: Int = 1
    var profiles: [GatewayProfile] = []
}

struct GatewayProfileLocalPaths: Equatable, Hashable {
    var configURL: URL
    var configDirectoryURL: URL
    var stateDirectoryURL: URL
    var credentialsDirectoryURL: URL
    var legacyConfigURL: URL?
    var legacyCredentialsDirectoryURL: URL?

    var runtimeConfigURL: URL {
        stateDirectoryURL.appendingPathComponent("openclaw.json")
    }

    var configSnapshotURLs: [URL] {
        dedupedURLs([configURL, runtimeConfigURL, legacyConfigURL].compactMap { $0 })
    }

    var credentialsDirectoryCandidates: [URL] {
        dedupedURLs([
            stateDirectoryURL.appendingPathComponent("credentials", isDirectory: true),
            credentialsDirectoryURL,
            legacyCredentialsDirectoryURL,
        ].compactMap { $0 })
    }

    var preferredConfigWriteURL: URL {
        configURL
    }

    func loadConfigRoot() -> [String: Any] {
        for url in configSnapshotURLs {
            if let json = Self.loadJSONObject(at: url) {
                return json
            }
        }
        return [:]
    }

    func credentialFileCandidates(named fileName: String) -> [URL] {
        credentialsDirectoryCandidates.map { directory in
            directory.appendingPathComponent(fileName)
        }
    }

    func existingCredentialFile(named fileName: String) -> URL? {
        credentialFileCandidates(named: fileName)
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    func secretProviderFileURL(providerID: String) -> URL? {
        for url in configSnapshotURLs {
            guard let root = Self.loadJSONObject(at: url),
                  let secrets = root["secrets"] as? [String: Any],
                  let providers = secrets["providers"] as? [String: Any],
                  let provider = providers[providerID] as? [String: Any],
                  let rawPath = provider["path"] as? String else {
                continue
            }
            return Self.resolveFileURL(rawPath, relativeTo: url.deletingLastPathComponent())
        }
        return nil
    }

    func existingSecretProviderFileURL(providerID: String) -> URL? {
        guard let url = secretProviderFileURL(providerID: providerID),
              FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func loadJSONObject(at url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func resolveFileURL(_ rawPath: String, relativeTo baseDirectoryURL: URL) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = NSString(string: trimmed).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded)
        }
        return baseDirectoryURL.appendingPathComponent(expanded)
    }

    private func dedupedURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for url in urls where seen.insert(url.standardizedFileURL.path).inserted {
            result.append(url)
        }
        return result
    }
}

struct GatewayProfileResolution: Codable, Equatable, Hashable {
    var profileID: UUID
    var slug: String
    var displayName: String
    var sourceKind: GatewayProfileSourceKind
    var resolvedConfigPath: String
    var resolvedStateDir: String
    var resolvedWorkspaceRoot: String
    var resolvedPort: Int

    var configURL: URL { URL(fileURLWithPath: resolvedConfigPath) }
    var runtimeConfigURL: URL { stateDirURL.appendingPathComponent("openclaw.json") }
    var configDirectoryURL: URL { configURL.deletingLastPathComponent() }
    var credentialsDirectoryURL: URL {
        configDirectoryURL.appendingPathComponent("credentials", isDirectory: true)
    }
    var stateDirURL: URL { URL(fileURLWithPath: resolvedStateDir, isDirectory: true) }
    var workspaceRootURL: URL { URL(fileURLWithPath: resolvedWorkspaceRoot, isDirectory: true) }
    var legacyManagedRootURL: URL? {
        guard sourceKind == .managed else { return nil }
        guard configURL.standardizedFileURL.path == runtimeConfigURL.standardizedFileURL.path else {
            return nil
        }
        guard stateDirURL.lastPathComponent == "state" else { return nil }
        return stateDirURL.deletingLastPathComponent()
    }
    var legacyManagedConfigURL: URL? {
        legacyManagedRootURL?.appendingPathComponent("openclaw.json")
    }
    var legacyManagedCredentialsDirectoryURL: URL? {
        legacyManagedRootURL?.appendingPathComponent("credentials", isDirectory: true)
    }
    var localPaths: GatewayProfileLocalPaths {
        GatewayProfileLocalPaths(
            configURL: configURL,
            configDirectoryURL: configDirectoryURL,
            stateDirectoryURL: stateDirURL,
            credentialsDirectoryURL: credentialsDirectoryURL,
            legacyConfigURL: legacyManagedConfigURL,
            legacyCredentialsDirectoryURL: legacyManagedCredentialsDirectoryURL
        )
    }

    func workspacePath(for agentId: String) -> String {
        if agentId == "main" {
            return resolvedWorkspaceRoot
        }
        return stateDirURL
            .appendingPathComponent("workspace-\(agentId)", isDirectory: true)
            .path
    }

    func agentDirPath(for agentId: String) -> String {
        stateDirURL
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentId, isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .path
    }

    func sessionsDirPath(for agentId: String) -> String {
        stateDirURL
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentId, isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .path
    }

    func metadataPath(for agentId: String) -> String {
        stateDirURL
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(agentId, isDirectory: true)
            .appendingPathComponent("metadata.json")
            .path
    }
}

enum SupervisorReadyState: String, Codable {
    case unknown
    case stopped
    case preparing
    case starting
    case ready
    case failed
}

enum SupervisorOwnership: String, Codable {
    case none
    case supervised
    case adopted
}

enum SupervisorHealthState: String, Codable {
    case unknown
    case noProcess
    case launching
    case portListening
    case healthy
    case unresponsive
    case failed
}

struct SupervisorProfileRuntime: Codable, Identifiable, Equatable {
    var id: UUID { profileID }

    var profileID: UUID
    var slug: String
    var displayName: String
    var sourceKind: GatewayProfileSourceKind
    var managementMode: GatewayProfileManagementMode
    var resolvedConfigPath: String
    var resolvedStateDir: String
    var resolvedWorkspaceRoot: String
    var resolvedPort: Int
    var isPrepared: Bool
    var isRunning: Bool
    var pid: Int32?
    var readyState: SupervisorReadyState
    var ownership: SupervisorOwnership
    var lastProbeAt: Date?
    var healthState: SupervisorHealthState
    var lastReadyAt: Date?
    var unhealthySince: Date?
    var lastHealthyProbeAt: Date?
    var lastUnhealthyReason: String?
    var userStoppedAt: Date?
    var lastError: String?
    var lastLifecycleMessage: String?

    init(
        profileID: UUID,
        slug: String,
        displayName: String,
        sourceKind: GatewayProfileSourceKind,
        managementMode: GatewayProfileManagementMode,
        resolvedConfigPath: String,
        resolvedStateDir: String,
        resolvedWorkspaceRoot: String,
        resolvedPort: Int,
        isPrepared: Bool,
        isRunning: Bool,
        pid: Int32?,
        readyState: SupervisorReadyState,
        ownership: SupervisorOwnership,
        lastProbeAt: Date?,
        healthState: SupervisorHealthState? = nil,
        lastReadyAt: Date? = nil,
        unhealthySince: Date? = nil,
        lastHealthyProbeAt: Date? = nil,
        lastUnhealthyReason: String? = nil,
        userStoppedAt: Date? = nil,
        lastError: String?,
        lastLifecycleMessage: String?
    ) {
        self.profileID = profileID
        self.slug = slug
        self.displayName = displayName
        self.sourceKind = sourceKind
        self.managementMode = managementMode
        self.resolvedConfigPath = resolvedConfigPath
        self.resolvedStateDir = resolvedStateDir
        self.resolvedWorkspaceRoot = resolvedWorkspaceRoot
        self.resolvedPort = resolvedPort
        self.isPrepared = isPrepared
        self.isRunning = isRunning
        self.pid = pid
        self.readyState = readyState
        self.ownership = ownership
        self.lastProbeAt = lastProbeAt
        self.healthState = healthState ?? Self.defaultHealthState(
            readyState: readyState,
            isRunning: isRunning
        )
        self.lastReadyAt = lastReadyAt
        self.unhealthySince = unhealthySince
        self.lastHealthyProbeAt = lastHealthyProbeAt
        self.lastUnhealthyReason = lastUnhealthyReason
        self.userStoppedAt = userStoppedAt
        self.lastError = lastError
        self.lastLifecycleMessage = lastLifecycleMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profileID = try container.decode(UUID.self, forKey: .profileID)
        slug = try container.decode(String.self, forKey: .slug)
        displayName = try container.decode(String.self, forKey: .displayName)
        sourceKind = try container.decode(GatewayProfileSourceKind.self, forKey: .sourceKind)
        managementMode = try container.decode(GatewayProfileManagementMode.self, forKey: .managementMode)
        resolvedConfigPath = try container.decode(String.self, forKey: .resolvedConfigPath)
        resolvedStateDir = try container.decode(String.self, forKey: .resolvedStateDir)
        resolvedWorkspaceRoot = try container.decode(String.self, forKey: .resolvedWorkspaceRoot)
        resolvedPort = try container.decode(Int.self, forKey: .resolvedPort)
        isPrepared = try container.decode(Bool.self, forKey: .isPrepared)
        isRunning = try container.decode(Bool.self, forKey: .isRunning)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        readyState = try container.decode(SupervisorReadyState.self, forKey: .readyState)
        ownership = try container.decode(SupervisorOwnership.self, forKey: .ownership)
        lastProbeAt = try container.decodeIfPresent(Date.self, forKey: .lastProbeAt)
        healthState = try container.decodeIfPresent(SupervisorHealthState.self, forKey: .healthState)
            ?? Self.defaultHealthState(readyState: readyState, isRunning: isRunning)
        lastReadyAt = try container.decodeIfPresent(Date.self, forKey: .lastReadyAt)
        unhealthySince = try container.decodeIfPresent(Date.self, forKey: .unhealthySince)
        lastHealthyProbeAt = try container.decodeIfPresent(Date.self, forKey: .lastHealthyProbeAt)
        lastUnhealthyReason = try container.decodeIfPresent(String.self, forKey: .lastUnhealthyReason)
        userStoppedAt = try container.decodeIfPresent(Date.self, forKey: .userStoppedAt)
        lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        lastLifecycleMessage = try container.decodeIfPresent(String.self, forKey: .lastLifecycleMessage)
    }

    var resolution: GatewayProfileResolution {
        GatewayProfileResolution(
            profileID: profileID,
            slug: slug,
            displayName: displayName,
            sourceKind: sourceKind,
            resolvedConfigPath: resolvedConfigPath,
            resolvedStateDir: resolvedStateDir,
            resolvedWorkspaceRoot: resolvedWorkspaceRoot,
            resolvedPort: resolvedPort
        )
    }

    private static func defaultHealthState(
        readyState: SupervisorReadyState,
        isRunning: Bool
    ) -> SupervisorHealthState {
        switch readyState {
        case .ready:
            return isRunning ? .healthy : .unknown
        case .preparing, .starting:
            return isRunning ? .launching : .unknown
        case .stopped:
            return .noProcess
        case .failed:
            return .failed
        case .unknown:
            return .unknown
        }
    }
}

enum OpenClawDiscoverySource: String, Codable, CaseIterable {
    case runningProcess
    case launchAgent
    case knownDirectory
    case manualSelection
}

enum OpenClawDiscoveryConfidence: String, Codable, CaseIterable {
    case high
    case medium
    case low
}

enum OpenClawDiscoveryRiskLevel: String, Codable, CaseIterable {
    case safe
    case needsReview
    case blocked
}

struct OpenClawInstanceCandidate: Codable, Identifiable, Hashable {
    var id: UUID
    var displayNameSuggestion: String
    var slugSuggestion: String
    var source: OpenClawDiscoverySource
    var confidence: OpenClawDiscoveryConfidence
    var riskLevel: OpenClawDiscoveryRiskLevel
    var configPath: String
    var stateDir: String
    var workspaceRoot: String?
    var port: Int?
    var pid: Int32?
    var commandLine: String?
    var launchdLabel: String?
    var launchAgent: OpenClawLaunchAgentInfo?
    var warnings: [String]
    var detectedAt: Date
}

enum GatewayProfileResolver {
    #if DEBUG
    static let defaultGatewayPort = 19789
    static let managedPortRange = 19789...19999
    #else
    static let defaultGatewayPort = 18789
    static let managedPortRange = 18789...18999
    #endif
    static let managedPortSpacing = 20

    static func normalizedSlug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber {
                return character
            }
            return "-"
        }
        var slug = String(mapped)
        while slug.contains("--") {
            slug = slug.replacingOccurrences(of: "--", with: "-")
        }
        slug = slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "default" : slug
    }

    static func makeUniqueSlug(base: String, existing: [GatewayProfile]) -> String {
        let normalizedBase = normalizedSlug(base)
        let existingSlugs = Set(existing.map(\.slug))
        guard existingSlugs.contains(normalizedBase) else {
            return normalizedBase
        }

        for suffix in 2...999 {
            let candidate = "\(normalizedBase)-\(suffix)"
            if !existingSlugs.contains(candidate) {
                return candidate
            }
        }
        return "\(normalizedBase)-\(UUID().uuidString.prefix(6))"
    }

    static func resolve(_ profile: GatewayProfile) -> GatewayProfileResolution {
        let managedRoot = EZRWorkerPaths.managedProfileRoot(slug: profile.slug)
        let stateDir = profile.stateDirOverride
            .flatMap(Self.absoluteURLIfValid(path:))
            ?? managedRoot.appendingPathComponent("state", isDirectory: true)
        let defaultConfigURL: URL
        switch profile.sourceKind {
        case .managed:
            defaultConfigURL = stateDir.appendingPathComponent("openclaw.json")
        case .legacyReuse, .externalReuse:
            defaultConfigURL = managedRoot.appendingPathComponent("openclaw.json")
        }
        let configURL = profile.configPathOverride
            .flatMap(Self.absoluteURLIfValid(path:))
            ?? defaultConfigURL
        let workspaceRoot = profile.workspaceRootOverride
            .flatMap(Self.absoluteURLIfValid(path:))
            ?? stateDir.appendingPathComponent("workspace", isDirectory: true)

        return GatewayProfileResolution(
            profileID: profile.id,
            slug: profile.slug,
            displayName: profile.displayName,
            sourceKind: profile.sourceKind,
            resolvedConfigPath: configURL.path,
            resolvedStateDir: stateDir.path,
            resolvedWorkspaceRoot: workspaceRoot.path,
            resolvedPort: profile.portOverride ?? defaultGatewayPort
        )
    }

    static func absoluteURLIfValid(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: trimmed)
    }

    static func readLegacyGatewayPort() -> Int? {
        guard let data = try? Data(contentsOf: EZRWorkerPaths.legacyOpenClawConfigURL),
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

    static func nextAvailablePort(
        existingProfiles: [GatewayProfile],
        preferred: Int? = nil
    ) -> Int {
        let used = existingProfiles.map { resolve($0).resolvedPort }
        if let preferred,
           managedPortRange.contains(preferred),
           !hasReservedPortConflict(preferred, existingPorts: used),
           isPortAvailable(preferred) {
            return preferred
        }

        if let candidate = managedPortRange.first(where: {
            !hasReservedPortConflict($0, existingPorts: used) && isPortAvailable($0)
        }) {
            return candidate
        }
        return preferred ?? defaultGatewayPort
    }

    static func hasReservedPortConflict(_ port: Int, existingPorts: [Int]) -> Bool {
        conflictingBasePorts(for: port, existingPorts: existingPorts).isEmpty == false
    }

    static func conflictingBasePorts(for port: Int, existingPorts: [Int]) -> [Int] {
        existingPorts
            .filter { abs($0 - port) < managedPortSpacing }
            .sorted()
    }

    static func validateAbsoluteOverridePath(_ path: String?) -> Bool {
        guard let path else { return true }
        return absoluteURLIfValid(path: path) != nil
    }

    static func isPortAvailable(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }

        var value: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &value, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.stride)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                bind(sock, pointer, socklen_t(MemoryLayout<sockaddr_in>.stride)) == 0
            }
        }
    }
}
