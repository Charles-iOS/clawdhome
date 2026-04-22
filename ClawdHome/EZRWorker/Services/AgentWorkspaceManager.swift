import Foundation
import Observation

enum WorkspaceProbeResult: Equatable {
    case exists
    case missing
    case indeterminate(String)
}

@MainActor
@Observable
final class AgentWorkspaceManager {
    private var helperClient: HelperClient?
    private(set) var username: String = ""
    private(set) var currentProfileResolution: GatewayProfileResolution?

    func configure(helperClient: HelperClient, username: String) {
        self.helperClient = helperClient
        self.username = username

        if currentProfileResolution == nil {
            currentProfileResolution = GatewayProfileResolution(
                profileID: UUID(),
                slug: "legacy-default",
                displayName: "Legacy Default",
                sourceKind: .legacyReuse,
                resolvedConfigPath: EZRWorkerPaths.legacyOpenClawConfigURL.path,
                resolvedStateDir: EZRWorkerPaths.legacyOpenClawDirectory.path,
                resolvedWorkspaceRoot: EZRWorkerPaths.legacyOpenClawDirectory
                    .appendingPathComponent("workspace", isDirectory: true)
                    .path,
                resolvedPort: GatewayProfileResolver.readLegacyGatewayPort() ?? GatewayProfileResolver.defaultGatewayPort
            )
        }
    }

    func configure(profile: GatewayProfileResolution, helperClient: HelperClient? = nil, username: String = NSUserName()) {
        self.currentProfileResolution = profile
        self.helperClient = helperClient
        self.username = username
    }

    func workspacePath(for agentId: String) -> String {
        relativePath(forAbsolutePath: workspaceURL(for: agentId).path)
    }

    func personaFilePath(agentId: String, file: PersonaFile) -> String {
        workspacePath(for: agentId) + "/\(file.rawValue)"
    }

    func agentDirPath(for agentId: String) -> String {
        relativePath(forAbsolutePath: agentDirURL(for: agentId).path)
    }

    func metadataPath(for agentId: String) -> String {
        relativePath(forAbsolutePath: metadataURL(for: agentId).path)
    }

    func sessionsDirPath(for agentId: String) -> String {
        relativePath(forAbsolutePath: sessionsDirURL(for: agentId).path)
    }

    func initializeWorkspace(
        agentId: String,
        seedContent: [PersonaFile: String] = [:]
    ) async throws {
        try ensureConfigured()

        try createDirectory(workspaceURL(for: agentId))
        try createDirectory(agentDirURL(for: agentId))
        try createDirectory(sessionsDirURL(for: agentId))

        for file in PersonaFile.allCases {
            let content = seedContent[file] ?? ""
            guard !content.isEmpty else { continue }
            try writeFile(to: personaFileURL(agentId: agentId, file: file), data: Data(content.utf8))
        }
    }

    func readPersonaFile(agentId: String, file: PersonaFile) async throws -> String {
        let data = try await readRelativeFile(personaFilePath(agentId: agentId, file: file))
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writePersonaFile(agentId: String, file: PersonaFile, content: String) async throws {
        try ensureConfigured()
        try createDirectory(workspaceURL(for: agentId))
        try writeFile(to: personaFileURL(agentId: agentId, file: file), data: Data(content.utf8))
    }

    func readAgentMetadata(agentId: String) async throws -> AgentPersistedMetadata {
        let data = try await readRelativeFile(metadataPath(for: agentId))
        return try JSONDecoder().decode(AgentPersistedMetadata.self, from: data)
    }

    func writeAgentMetadata(agentId: String, metadata: AgentPersistedMetadata) async throws {
        try ensureConfigured()
        try createDirectory(agentDirURL(for: agentId).deletingLastPathComponent())
        let data = try JSONEncoder().encode(metadata)
        try writeFile(to: metadataURL(for: agentId), data: data)
    }

    func commitPersonaFile(agentId: String, file: PersonaFile, message: String) async throws {
        guard let helperClient, helperClient.isConnected else {
            throw AgentWorkspaceError.gitHistoryUnavailable
        }
        try await helperClient.commitPersonaFile(
            username: username,
            filename: file.rawValue,
            message: message
        )
    }

    func getPersonaFileHistory(agentId: String, file: PersonaFile) async throws -> [PersonaCommit] {
        guard let helperClient, helperClient.isConnected else {
            throw AgentWorkspaceError.gitHistoryUnavailable
        }
        return try await helperClient.getPersonaFileHistory(
            username: username,
            filename: file.rawValue
        )
    }

    func listWorkspaceFiles(agentId: String) async throws -> [FileEntry] {
        try ensureConfigured()
        return try listDirectory(at: workspaceURL(for: agentId), showHidden: false)
    }

    func listSessions(agentId: String) async throws -> [FileEntry] {
        try ensureConfigured()
        return try listDirectory(at: sessionsDirURL(for: agentId), showHidden: false)
            .filter { entry in
                guard !entry.isDirectory else { return false }
                guard entry.name != "sessions.json" else { return false }
                return entry.name.hasSuffix(".jsonl")
            }
    }

    func readRelativeFile(_ relativePath: String) async throws -> Data {
        try ensureConfigured()
        return try Data(contentsOf: resolvedURL(relativeOrAbsolutePath: relativePath))
    }

    func probeWorkspace(agentId: String) async -> WorkspaceProbeResult {
        do {
            try ensureConfigured()
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: workspaceURL(for: agentId).path, isDirectory: &isDirectory)
            guard exists else { return .missing }
            return isDirectory.boolValue ? .exists : .indeterminate("目标不是目录")
        } catch {
            return .indeterminate(error.localizedDescription)
        }
    }

    func workspaceExists(agentId: String) async -> Bool {
        if case .exists = await probeWorkspace(agentId: agentId) {
            return true
        }
        return false
    }

    func deleteWorkspace(agentId: String) async throws {
        try ensureConfigured()
        let fm = FileManager.default
        let paths = [
            workspaceURL(for: agentId),
            agentDirURL(for: agentId).deletingLastPathComponent(),
        ]

        for path in paths where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
    }

    private func ensureConfigured() throws {
        guard currentProfileResolution != nil else {
            throw AgentWorkspaceError.notConfigured
        }
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(to url: URL, data: Data) throws {
        try createDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    private func listDirectory(at url: URL, showHidden: Bool) throws -> [FileEntry] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [] }

        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey,
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let items = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: options)

        return items.compactMap { itemURL in
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            return FileEntry(
                name: itemURL.lastPathComponent,
                path: relativePath(forAbsolutePath: itemURL.path),
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate,
                isSymlink: values?.isSymbolicLink ?? false,
                ownerUsername: nil
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func workspaceURL(for agentId: String) -> URL {
        guard let resolution = currentProfileResolution else {
            return EZRWorkerPaths.legacyOpenClawDirectory.appendingPathComponent("workspace", isDirectory: true)
        }
        if agentId == "main" {
            return resolution.workspaceRootURL
        }
        return resolution.stateDirURL.appendingPathComponent("workspace-\(agentId)", isDirectory: true)
    }

    private func personaFileURL(agentId: String, file: PersonaFile) -> URL {
        workspaceURL(for: agentId).appendingPathComponent(file.rawValue)
    }

    private func agentDirURL(for agentId: String) -> URL {
        guard let resolution = currentProfileResolution else {
            return EZRWorkerPaths.legacyOpenClawDirectory
                .appendingPathComponent("agents/\(agentId)/agent", isDirectory: true)
        }
        return URL(fileURLWithPath: resolution.agentDirPath(for: agentId), isDirectory: true)
    }

    private func metadataURL(for agentId: String) -> URL {
        guard let resolution = currentProfileResolution else {
            return EZRWorkerPaths.legacyOpenClawDirectory
                .appendingPathComponent("agents/\(agentId)/metadata.json")
        }
        return URL(fileURLWithPath: resolution.metadataPath(for: agentId))
    }

    private func sessionsDirURL(for agentId: String) -> URL {
        guard let resolution = currentProfileResolution else {
            return EZRWorkerPaths.legacyOpenClawDirectory
                .appendingPathComponent("agents/\(agentId)/sessions", isDirectory: true)
        }
        return URL(fileURLWithPath: resolution.sessionsDirPath(for: agentId), isDirectory: true)
    }

    private func resolvedURL(relativeOrAbsolutePath: String) -> URL {
        let trimmed = relativeOrAbsolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        guard let resolution = currentProfileResolution else {
            return EZRWorkerPaths.legacyOpenClawDirectory.appendingPathComponent(trimmed)
        }
        return resolution.stateDirURL.appendingPathComponent(trimmed)
    }

    private func relativePath(forAbsolutePath path: String) -> String {
        guard let resolution = currentProfileResolution else {
            if path.hasPrefix(EZRWorkerPaths.legacyOpenClawDirectory.path + "/") {
                return String(path.dropFirst(EZRWorkerPaths.legacyOpenClawDirectory.path.count + 1))
            }
            return path
        }
        let stateDirPath = resolution.stateDirURL.path
        if path == stateDirPath {
            return "."
        }
        if path.hasPrefix(stateDirPath + "/") {
            return String(path.dropFirst(stateDirPath.count + 1))
        }
        return path
    }
}

enum AgentWorkspaceError: LocalizedError {
    case notConfigured
    case workspaceNotFound(String)
    case localAccessUnavailable
    case gitHistoryUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AgentWorkspaceManager 未配置"
        case .workspaceNotFound(let agentId):
            return "智能体 \(agentId) 的 workspace 不存在"
        case .localAccessUnavailable:
            return "当前用户本地文件访问不可用"
        case .gitHistoryUnavailable:
            return "当前 profile 未接入 helper Git 历史能力"
        }
    }
}
