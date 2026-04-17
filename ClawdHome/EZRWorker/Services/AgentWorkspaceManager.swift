// ClawdHome/Services/AgentWorkspaceManager.swift
// 管理智能体 workspace 的文件读写（通过 HelperClient XPC）
//
// 每个智能体对应一个 workspace 目录：
//   - main → ~/.openclaw/workspace/
//   - 其他 → ~/.openclaw/workspace-<agentId>/
//
// 文件操作全部委托给 HelperClient（以 Shrimp 用户身份执行）

import Foundation
import Observation

enum WorkspaceProbeResult: Equatable {
    case exists
    case missing
    case indeterminate(String)
}

@MainActor @Observable
final class AgentWorkspaceManager {

    private var helperClient: HelperClient?
    private(set) var username: String = ""

    // MARK: - 配置

    func configure(helperClient: HelperClient, username: String) {
        self.helperClient = helperClient
        self.username = username
    }

    // MARK: - 路径计算

    /// workspace 目录相对路径
    func workspacePath(for agentId: String) -> String {
        agentId == "main"
            ? ".openclaw/workspace"
            : ".openclaw/workspace-\(agentId)"
    }

    /// persona 文件相对路径
    func personaFilePath(agentId: String, file: PersonaFile) -> String {
        "\(workspacePath(for: agentId))/\(file.rawValue)"
    }

    /// agent 目录相对路径
    func agentDirPath(for agentId: String) -> String {
        ".openclaw/agents/\(agentId)/agent"
    }

    /// 智能体元数据文件相对路径
    func metadataPath(for agentId: String) -> String {
        ".openclaw/agents/\(agentId)/metadata.json"
    }

    /// sessions 目录相对路径
    func sessionsDirPath(for agentId: String) -> String {
        ".openclaw/agents/\(agentId)/sessions"
    }

    // MARK: - Workspace 初始化

    /// 创建智能体 workspace 目录并写入初始 persona 文件
    /// seedContent: 可选的初始内容字典（PersonaFile → 内容），用于从预置模板创建
    func initializeWorkspace(
        agentId: String,
        seedContent: [PersonaFile: String] = [:]
    ) async throws {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }

        let wsPath = workspacePath(for: agentId)
        let agentDir = agentDirPath(for: agentId)
        let sessionsDir = sessionsDirPath(for: agentId)

        // 创建目录结构
        try await helper.createDirectory(username: username, relativePath: wsPath)
        try await helper.createDirectory(username: username, relativePath: agentDir)
        try await helper.createDirectory(username: username, relativePath: sessionsDir)

        // 写入初始 persona 文件
        for file in PersonaFile.allCases {
            let content = seedContent[file] ?? ""
            if !content.isEmpty {
                let data = Data(content.utf8)
                try await helper.writeFile(
                    username: username,
                    relativePath: personaFilePath(agentId: agentId, file: file),
                    data: data
                )
            }
        }
    }

    // MARK: - Persona 文件读写

    func readPersonaFile(agentId: String, file: PersonaFile) async throws -> String {
        let data = try await readRelativeFile(
            personaFilePath(agentId: agentId, file: file)
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    func writePersonaFile(agentId: String, file: PersonaFile, content: String) async throws {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        try await helper.writeFile(
            username: username,
            relativePath: personaFilePath(agentId: agentId, file: file),
            data: Data(content.utf8)
        )
    }

    // MARK: - 智能体元数据读写

    func readAgentMetadata(agentId: String) async throws -> AgentPersistedMetadata {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        let data = try await helper.readFile(
            username: username,
            relativePath: metadataPath(for: agentId)
        )
        return try JSONDecoder().decode(AgentPersistedMetadata.self, from: data)
    }

    func writeAgentMetadata(agentId: String, metadata: AgentPersistedMetadata) async throws {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        let parent = ".openclaw/agents/\(agentId)"
        try await helper.createDirectory(username: username, relativePath: parent)
        let data = try JSONEncoder().encode(metadata)
        try await helper.writeFile(
            username: username,
            relativePath: metadataPath(for: agentId),
            data: data
        )
    }

    // MARK: - Git 操作（persona 文件版本控制）

    func commitPersonaFile(agentId: String, file: PersonaFile, message: String) async throws {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        // commitPersonaFile 目前按 workspace 目录工作，filename 为文件名（如 SOUL.md）
        // 对非 main 智能体，需要扩展 Helper 端支持或使用完整路径
        // 暂时只支持通过 writeFile 保存，git 提交后续迭代
        try await helper.commitPersonaFile(
            username: username,
            filename: file.rawValue,
            message: message
        )
    }

    func getPersonaFileHistory(agentId: String, file: PersonaFile) async throws -> [PersonaCommit] {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        return try await helper.getPersonaFileHistory(
            username: username,
            filename: file.rawValue
        )
    }

    // MARK: - Workspace 文件浏览

    func listWorkspaceFiles(agentId: String) async throws -> [FileEntry] {
        try await listDirectory(
            relativePath: workspacePath(for: agentId),
            showHidden: false
        )
    }

    /// 列出 sessions 目录
    func listSessions(agentId: String) async throws -> [FileEntry] {
        try await listDirectory(
            relativePath: sessionsDirPath(for: agentId),
            showHidden: false
        )
        .filter { entry in
            guard !entry.isDirectory else { return false }
            if entry.name == "sessions.json" { return false }
            return entry.name.hasSuffix(".jsonl")
        }
    }

    func readRelativeFile(_ relativePath: String) async throws -> Data {
        if let helper = helperClient, helper.isConnected {
            do {
                return try await helper.readFile(
                    username: username,
                    relativePath: relativePath
                )
            } catch {
                if let data = try? readFileLocally(relativePath: relativePath) {
                    appLog("AgentWorkspace: 读取文件回退本地路径 \(relativePath): \(error)", level: .warn)
                    return data
                }
                throw error
            }
        }

        if currentUserHomeURL != nil {
            return try readFileLocally(relativePath: relativePath)
        }

        if helperClient == nil {
            throw AgentWorkspaceError.notConfigured
        }
        throw HelperError.notConnected
    }

    // MARK: - Workspace 检测

    func probeWorkspace(agentId: String) async -> WorkspaceProbeResult {
        let relativePath = workspacePath(for: agentId)

        if let helper = helperClient, helper.isConnected {
            do {
                _ = try await helper.listDirectory(
                    username: username,
                    relativePath: relativePath,
                    showHidden: false
                )
                return .exists
            } catch {
                if Self.isMissingWorkspaceError(error) {
                    return .missing
                }
                if let localResult = probeWorkspaceLocally(relativePath: relativePath) {
                    appLog("AgentWorkspace: workspace 探测回退本地路径 \(relativePath): \(error)", level: .warn)
                    return localResult
                }
                return .indeterminate(error.localizedDescription)
            }
        }

        if let localResult = probeWorkspaceLocally(relativePath: relativePath) {
            return localResult
        }

        if helperClient == nil {
            return .indeterminate(AgentWorkspaceError.notConfigured.localizedDescription)
        }
        return .indeterminate(HelperError.notConnected.localizedDescription)
    }

    /// 检查智能体 workspace 是否存在（通过读取目录）
    func workspaceExists(agentId: String) async -> Bool {
        if case .exists = await probeWorkspace(agentId: agentId) {
            return true
        }
        return false
    }

    // MARK: - Workspace 删除

    func deleteWorkspace(agentId: String) async throws {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        let normalizedId = Self.normalizedAgentKey(agentId)

        // 删除 workspace 目录（不存在时忽略）
        let workspaceCandidates = try await deletionCandidates(
            parentRelativePath: ".openclaw",
            exactName: workspacePath(for: agentId).split(separator: "/").last.map(String.init) ?? "",
            normalizedMatch: { entryName in
                guard entryName.hasPrefix("workspace-") else { return false }
                return Self.normalizedAgentKey(String(entryName.dropFirst("workspace-".count))) == normalizedId
            }
        )
        for relativePath in workspaceCandidates {
            do {
                try await helper.deleteItem(username: username, relativePath: relativePath)
            } catch {
                appLog("AgentWorkspace: 删除 workspace 目录失败（可忽略）: \(error)", level: .warn)
            }
        }

        // 删除 agent 目录（含 sessions，不存在时忽略）
        let agentCandidates = try await deletionCandidates(
            parentRelativePath: ".openclaw/agents",
            exactName: agentId,
            normalizedMatch: { entryName in
                Self.normalizedAgentKey(entryName) == normalizedId
            }
        )
        for relativePath in agentCandidates {
            do {
                try await helper.deleteItem(username: username, relativePath: relativePath)
            } catch {
                appLog("AgentWorkspace: 删除 agent 目录失败（可忽略）: \(error)", level: .warn)
            }
        }
    }

    private func deletionCandidates(
        parentRelativePath: String,
        exactName: String,
        normalizedMatch: (String) -> Bool
    ) async throws -> [String] {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }

        var candidates = Set<String>()
        if !exactName.isEmpty {
            candidates.insert("\(parentRelativePath)/\(exactName)")
        }

        let entries = (try? await helper.listDirectory(
            username: username,
            relativePath: parentRelativePath,
            showHidden: false
        )) ?? []

        for entry in entries where entry.isDirectory && normalizedMatch(entry.name) {
            candidates.insert("\(parentRelativePath)/\(entry.name)")
        }

        return Array(candidates).sorted()
    }

    private func listDirectory(
        relativePath: String,
        showHidden: Bool
    ) async throws -> [FileEntry] {
        if let helper = helperClient, helper.isConnected {
            do {
                return try await helper.listDirectory(
                    username: username,
                    relativePath: relativePath,
                    showHidden: showHidden
                )
            } catch {
                if let entries = try? listDirectoryLocally(relativePath: relativePath, showHidden: showHidden) {
                    appLog("AgentWorkspace: 列目录回退本地路径 \(relativePath): \(error)", level: .warn)
                    return entries
                }
                throw error
            }
        }

        if currentUserHomeURL != nil {
            return try listDirectoryLocally(relativePath: relativePath, showHidden: showHidden)
        }

        if helperClient == nil {
            throw AgentWorkspaceError.notConfigured
        }
        throw HelperError.notConnected
    }
}

private extension AgentWorkspaceManager {
    static func normalizedAgentKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? trimmed.lowercased() : normalized
    }

    static func isMissingWorkspaceError(_ error: Error) -> Bool {
        let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            .lowercased()

        return message.contains("no such file or directory")
            || message.contains("doesn't exist")
            || message.contains("doesn’t exist")
            || message.contains("not found")
            || message.contains("不存在")
            || message.contains("不是目录")
    }

    var currentUserHomeURL: URL? {
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUsername.isEmpty, trimmedUsername == NSUserName() else { return nil }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
    }

    func resolvedLocalURL(relativePath: String) -> URL? {
        guard let homeURL = currentUserHomeURL else { return nil }
        let normalizedRelativePath = relativePath.isEmpty ? "." : relativePath
        let url = homeURL.appendingPathComponent(normalizedRelativePath).standardizedFileURL
        guard url.path == homeURL.path || url.path.hasPrefix(homeURL.path + "/") else { return nil }
        return url
    }

    func probeWorkspaceLocally(relativePath: String) -> WorkspaceProbeResult? {
        guard let url = resolvedLocalURL(relativePath: relativePath) else { return nil }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if exists {
            return isDirectory.boolValue ? .exists : .indeterminate("目标不是目录")
        }
        return .missing
    }

    func listDirectoryLocally(relativePath: String, showHidden: Bool) throws -> [FileEntry] {
        guard let directoryURL = resolvedLocalURL(relativePath: relativePath) else {
            throw AgentWorkspaceError.localAccessUnavailable
        }

        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .isSymbolicLinkKey
        ]
        let options: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let items = try fm.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: keys,
            options: options
        )
        let homePrefix = "\(currentUserHomeURL!.path)/"

        let entries: [FileEntry] = items.compactMap { itemURL in
            let values = try? itemURL.resourceValues(forKeys: Set(keys))
            let absolutePath = itemURL.standardizedFileURL.path
            guard absolutePath.hasPrefix(homePrefix) else { return nil }
            let relativeItemPath = String(absolutePath.dropFirst(homePrefix.count))
            return FileEntry(
                name: itemURL.lastPathComponent,
                path: relativeItemPath,
                isDirectory: values?.isDirectory ?? false,
                size: Int64(values?.fileSize ?? 0),
                modifiedAt: values?.contentModificationDate,
                isSymlink: values?.isSymbolicLink ?? false,
                ownerUsername: nil
            )
        }

        return entries.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func readFileLocally(relativePath: String) throws -> Data {
        guard let url = resolvedLocalURL(relativePath: relativePath) else {
            throw AgentWorkspaceError.localAccessUnavailable
        }
        return try Data(contentsOf: url)
    }
}

// MARK: - 错误类型

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
