import Darwin
import Foundation

enum GatewayProfileSourceKind: String, Codable, CaseIterable {
    case managed
    case legacyReuse
}

struct GatewayProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var slug: String
    var displayName: String
    var autoStart: Bool
    var sourceKind: GatewayProfileSourceKind
    var configPathOverride: String?
    var stateDirOverride: String?
    var workspaceRootOverride: String?
    var portOverride: Int?
    var createdAt: Date
}

struct GatewayProfilesDocument: Codable {
    var version: Int = 1
    var profiles: [GatewayProfile] = []
}

struct GatewayProfileLocalPaths: Equatable, Hashable {
    var configURL: URL
    var configDirectoryURL: URL
    var credentialsDirectoryURL: URL
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
    var configDirectoryURL: URL { configURL.deletingLastPathComponent() }
    var credentialsDirectoryURL: URL {
        configDirectoryURL.appendingPathComponent("credentials", isDirectory: true)
    }
    var stateDirURL: URL { URL(fileURLWithPath: resolvedStateDir, isDirectory: true) }
    var workspaceRootURL: URL { URL(fileURLWithPath: resolvedWorkspaceRoot, isDirectory: true) }
    var localPaths: GatewayProfileLocalPaths {
        GatewayProfileLocalPaths(
            configURL: configURL,
            configDirectoryURL: configDirectoryURL,
            credentialsDirectoryURL: credentialsDirectoryURL
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

struct SupervisorProfileRuntime: Codable, Identifiable, Equatable {
    var id: UUID { profileID }

    var profileID: UUID
    var slug: String
    var displayName: String
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
    var lastError: String?

    var resolution: GatewayProfileResolution {
        GatewayProfileResolution(
            profileID: profileID,
            slug: slug,
            displayName: displayName,
            sourceKind: .managed,
            resolvedConfigPath: resolvedConfigPath,
            resolvedStateDir: resolvedStateDir,
            resolvedWorkspaceRoot: resolvedWorkspaceRoot,
            resolvedPort: resolvedPort
        )
    }
}

enum GatewayProfileResolver {
    static let defaultGatewayPort = 18789
    static let managedPortRange = 18789...18999
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
        let configURL = profile.configPathOverride
            .flatMap(Self.absoluteURLIfValid(path:))
            ?? managedRoot.appendingPathComponent("openclaw.json")
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
