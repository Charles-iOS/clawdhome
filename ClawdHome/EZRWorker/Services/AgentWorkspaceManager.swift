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
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        let data = try await helper.readFile(
            username: username,
            relativePath: personaFilePath(agentId: agentId, file: file)
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
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        return try await helper.listDirectory(
            username: username,
            relativePath: workspacePath(for: agentId),
            showHidden: false
        )
    }

    /// 列出 sessions 目录
    func listSessions(agentId: String) async throws -> [FileEntry] {
        guard let helper = helperClient else { throw AgentWorkspaceError.notConfigured }
        return try await helper.listDirectory(
            username: username,
            relativePath: sessionsDirPath(for: agentId),
            showHidden: false
        )
        .filter { entry in
            guard !entry.isDirectory else { return false }
            if entry.name == "sessions.json" { return false }
            return entry.name.hasSuffix(".jsonl")
        }
    }

    // MARK: - Workspace 检测

    /// 检查智能体 workspace 是否存在（通过读取目录）
    func workspaceExists(agentId: String) async -> Bool {
        guard let helper = helperClient else { return false }
        do {
            _ = try await helper.listDirectory(
                username: username,
                relativePath: workspacePath(for: agentId),
                showHidden: false
            )
            return true
        } catch {
            return false
        }
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
}

// MARK: - 错误类型

enum AgentWorkspaceError: LocalizedError {
    case notConfigured
    case workspaceNotFound(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "AgentWorkspaceManager 未配置"
        case .workspaceNotFound(let agentId):
            return "智能体 \(agentId) 的 workspace 不存在"
        }
    }
}
