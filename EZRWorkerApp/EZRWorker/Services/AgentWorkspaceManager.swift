import Foundation
import Observation

enum WorkspaceProbeResult: Equatable, Sendable {
    case exists
    case missing
    case indeterminate(String)
}

struct AgentSessionStats: Sendable {
    var count: Int
    var lastModifiedAt: Date?
}

@MainActor
@Observable
final class AgentWorkspaceManager {
    private(set) var currentProfileResolution: GatewayProfileResolution?

    func configure(profile: GatewayProfileResolution) {
        self.currentProfileResolution = profile
    }

    func resetConfiguration() {
        currentProfileResolution = nil
    }

    func workspacePath(for agentId: String) throws -> String {
        let resolution = try configuredResolution()
        return relativePath(
            forAbsolutePath: workspaceURL(for: agentId, resolution: resolution).path,
            resolution: resolution
        )
    }

    func personaFilePath(agentId: String, file: PersonaFile) throws -> String {
        try workspacePath(for: agentId) + "/\(file.rawValue)"
    }

    func agentDirPath(for agentId: String) throws -> String {
        let resolution = try configuredResolution()
        return relativePath(
            forAbsolutePath: agentDirURL(for: agentId, resolution: resolution).path,
            resolution: resolution
        )
    }

    func metadataPath(for agentId: String) throws -> String {
        let resolution = try configuredResolution()
        return relativePath(
            forAbsolutePath: metadataURL(for: agentId, resolution: resolution).path,
            resolution: resolution
        )
    }

    func sessionsDirPath(for agentId: String) throws -> String {
        let resolution = try configuredResolution()
        return relativePath(
            forAbsolutePath: sessionsDirURL(for: agentId, resolution: resolution).path,
            resolution: resolution
        )
    }

    func initializeWorkspace(
        agentId: String,
        seedContent: [PersonaFile: String] = [:]
    ) async throws {
        let resolution = try configuredResolution()

        try createDirectory(workspaceURL(for: agentId, resolution: resolution))
        try createDirectory(agentDirURL(for: agentId, resolution: resolution))
        try createDirectory(sessionsDirURL(for: agentId, resolution: resolution))

        for file in PersonaFile.allCases {
            let content = seedContent[file] ?? ""
            guard !content.isEmpty else { continue }
            try writeFile(
                to: personaFileURL(agentId: agentId, file: file, resolution: resolution),
                data: Data(content.utf8)
            )
        }
    }

    func readPersonaFile(agentId: String, file: PersonaFile) async throws -> String {
        let data = try await readRelativeFile(try personaFilePath(agentId: agentId, file: file))
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writePersonaFile(agentId: String, file: PersonaFile, content: String) async throws {
        let resolution = try configuredResolution()
        try createDirectory(workspaceURL(for: agentId, resolution: resolution))
        try writeFile(
            to: personaFileURL(agentId: agentId, file: file, resolution: resolution),
            data: Data(content.utf8)
        )
    }

    func readAgentMetadata(agentId: String) async throws -> AgentPersistedMetadata {
        let data = try await readRelativeFile(try metadataPath(for: agentId))
        return try JSONDecoder().decode(AgentPersistedMetadata.self, from: data)
    }

    func writeAgentMetadata(agentId: String, metadata: AgentPersistedMetadata) async throws {
        let resolution = try configuredResolution()
        try createDirectory(agentDirURL(for: agentId, resolution: resolution).deletingLastPathComponent())
        let data = try JSONEncoder().encode(metadata)
        try writeFile(to: metadataURL(for: agentId, resolution: resolution), data: data)
    }

    func listWorkspaceFiles(agentId: String) async throws -> [FileEntry] {
        let resolution = try configuredResolution()
        return try await Self.listDirectoryOffMain(
            at: workspaceURL(for: agentId, resolution: resolution),
            showHidden: false,
            stateDirPath: resolution.stateDirURL.path
        )
    }

    func listSessions(agentId: String) async throws -> [FileEntry] {
        let resolution = try configuredResolution()
        return try await Self.listDirectoryOffMain(
            at: sessionsDirURL(for: agentId, resolution: resolution),
            showHidden: false,
            stateDirPath: resolution.stateDirURL.path
        )
            .filter { entry in
                guard !entry.isDirectory else { return false }
                guard entry.name != "sessions.json" else { return false }
                return entry.name.hasSuffix(".jsonl")
            }
    }

    func sessionStats(agentId: String) async throws -> AgentSessionStats {
        let resolution = try configuredResolution()
        return try await Self.sessionStatsOffMain(at: sessionsDirURL(for: agentId, resolution: resolution))
    }

    func readRelativeFile(_ relativePath: String) async throws -> Data {
        let resolution = try configuredResolution()
        let url = resolvedURL(relativeOrAbsolutePath: relativePath, resolution: resolution)
        return try await Task.detached(priority: .userInitiated) {
            try Data(contentsOf: url)
        }.value
    }

    func probeWorkspace(agentId: String) async -> WorkspaceProbeResult {
        do {
            let resolution = try configuredResolution()
            let path = workspaceURL(for: agentId, resolution: resolution).path
            return await Self.probeDirectoryOffMain(path: path)
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
        let resolution = try configuredResolution()
        let fm = FileManager.default
        let paths = [
            workspaceURL(for: agentId, resolution: resolution),
            agentDirURL(for: agentId, resolution: resolution).deletingLastPathComponent(),
        ]

        for path in paths where fm.fileExists(atPath: path.path) {
            try? fm.removeItem(at: path)
        }
    }

    private func configuredResolution() throws -> GatewayProfileResolution {
        guard let currentProfileResolution else {
            throw AgentWorkspaceError.notConfigured
        }
        return currentProfileResolution
    }

    private func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func writeFile(to url: URL, data: Data) throws {
        try createDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
    }

    nonisolated private static func listDirectoryOffMain(
        at url: URL,
        showHidden: Bool,
        stateDirPath: String
    ) async throws -> [FileEntry] {
        try await Task.detached(priority: .userInitiated) {
            try listDirectory(at: url, showHidden: showHidden, stateDirPath: stateDirPath)
        }.value
    }

    nonisolated private static func sessionStatsOffMain(at url: URL) async throws -> AgentSessionStats {
        try await Task.detached(priority: .utility) {
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else {
                return AgentSessionStats(count: 0, lastModifiedAt: nil)
            }

            let keys: [URLResourceKey] = [
                .isDirectoryKey,
                .contentModificationDateKey,
            ]
            let items = try fm.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles]
            )

            var count = 0
            var lastModifiedAt: Date?
            for itemURL in items {
                guard itemURL.lastPathComponent != "sessions.json",
                      itemURL.lastPathComponent.hasSuffix(".jsonl") else {
                    continue
                }
                let values = try? itemURL.resourceValues(forKeys: Set(keys))
                guard values?.isDirectory != true else { continue }
                count += 1
                if let modifiedAt = values?.contentModificationDate,
                   lastModifiedAt == nil || modifiedAt > lastModifiedAt! {
                    lastModifiedAt = modifiedAt
                }
            }
            return AgentSessionStats(count: count, lastModifiedAt: lastModifiedAt)
        }.value
    }

    nonisolated private static func probeDirectoryOffMain(path: String) async -> WorkspaceProbeResult {
        await Task.detached(priority: .utility) {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            guard exists else { return .missing }
            return isDirectory.boolValue ? .exists : .indeterminate("目标不是目录")
        }.value
    }

    nonisolated private static func listDirectory(
        at url: URL,
        showHidden: Bool,
        stateDirPath: String
    ) throws -> [FileEntry] {
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
                path: relativePath(forAbsolutePath: itemURL.path, stateDirPath: stateDirPath),
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

    nonisolated private static func relativePath(forAbsolutePath path: String, stateDirPath: String) -> String {
        if path == stateDirPath {
            return "."
        }
        if path.hasPrefix(stateDirPath + "/") {
            return String(path.dropFirst(stateDirPath.count + 1))
        }
        return path
    }

    private func workspaceURL(for agentId: String, resolution: GatewayProfileResolution) -> URL {
        if agentId == "main" {
            return resolution.workspaceRootURL
        }
        return resolution.stateDirURL.appendingPathComponent("workspace-\(agentId)", isDirectory: true)
    }

    private func personaFileURL(
        agentId: String,
        file: PersonaFile,
        resolution: GatewayProfileResolution
    ) -> URL {
        workspaceURL(for: agentId, resolution: resolution).appendingPathComponent(file.rawValue)
    }

    private func agentDirURL(for agentId: String, resolution: GatewayProfileResolution) -> URL {
        return URL(fileURLWithPath: resolution.agentDirPath(for: agentId), isDirectory: true)
    }

    private func metadataURL(for agentId: String, resolution: GatewayProfileResolution) -> URL {
        return URL(fileURLWithPath: resolution.metadataPath(for: agentId))
    }

    private func sessionsDirURL(for agentId: String, resolution: GatewayProfileResolution) -> URL {
        return URL(fileURLWithPath: resolution.sessionsDirPath(for: agentId), isDirectory: true)
    }

    private func resolvedURL(
        relativeOrAbsolutePath: String,
        resolution: GatewayProfileResolution
    ) -> URL {
        let trimmed = relativeOrAbsolutePath.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            return URL(fileURLWithPath: trimmed)
        }
        return resolution.stateDirURL.appendingPathComponent(trimmed)
    }

    private func relativePath(
        forAbsolutePath path: String,
        resolution: GatewayProfileResolution
    ) -> String {
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

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AgentWorkspaceManager 未配置"
        case .workspaceNotFound(let agentId):
            return "智能体 \(agentId) 的 workspace 不存在"
        case .localAccessUnavailable:
            return "当前用户本地文件访问不可用"
        }
    }
}
