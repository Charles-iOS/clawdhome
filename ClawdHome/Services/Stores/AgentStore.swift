// ClawdHome/Services/Stores/AgentStore.swift
// 管理 OpenClaw 原生多智能体：从 gateway config 驱动，CRUD 通过 configPatch
//
// 数据源：
//   1. 预置模板 → bundled PresetAgents.json（仅提供初始化种子数据）
//   2. 已配置智能体 → openclaw.json 中 agents.list[]
//   3. 渠道绑定 → openclaw.json 中 bindings[]
//   4. 运行时状态 → 各智能体 sessions 目录扫描

import Foundation
import Observation

@MainActor @Observable
final class AgentStore {

    // MARK: - 公开状态

    private(set) var agents: [Agent] = []
    private(set) var bindings: [AgentBinding] = []
    private(set) var presetTemplates: [Agent] = []

    // MARK: - 依赖

    private var gateway: GatewayService?
    private var workspaceManager: AgentWorkspaceManager?
    private var username: String = ""

    // MARK: - 加载

    /// 初始化并加载智能体列表
    func load(
        gateway: GatewayService,
        workspaceManager: AgentWorkspaceManager,
        username: String
    ) async {
        self.gateway = gateway
        self.workspaceManager = workspaceManager
        self.username = username

        // 1. 加载预置模板
        presetTemplates = Self.loadPresets()

        // 2. 从 gateway 配置读取 agents.list 和 bindings
        await refreshFromGateway()
    }

    /// 从 gateway 配置刷新智能体列表和绑定
    func refreshFromGateway() async {
        guard let gateway else { return }

        do {
            let (config, _) = try await gateway.configGetFull()
            parseConfig(config)
        } catch {
            appLog("AgentStore: 无法从 gateway 读取配置: \(error)", level: .error)
        }

        // 扫描 workspace 状态
        await refreshWorkspaceStatus()

        // 确保默认 main 智能体已注册且 workspace 已初始化
        await ensureDefaultAgentInitialized()
    }

    /// 确保默认 main 智能体存在于 gateway 配置中，且 workspace 已初始化
    /// 在新安装场景下，该方法负责完成首次初始化：
    ///   1. 若 gateway 配置中没有 main，追加到 agents.list
    ///   2. 若 workspace 目录不存在，创建目录并写入初始 persona 文件
    private func ensureDefaultAgentInitialized() async {
        guard let gateway, let workspaceManager else { return }

        // 查找 main 智能体
        guard let mainIdx = agents.firstIndex(where: { $0.id == "main" }) else { return }

        // 1. 若 gateway 配置未注册 main，写回配置
        do {
            let (config, baseHash) = try await gateway.configGetFull()
            let agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            let hasMain = agentsList.contains { ($0["id"] as? String) == "main" }
            if !hasMain {
                var newList = agentsList
                newList.append(["id": "main"])
                let patch: [String: Any] = ["agents": ["list": newList]]
                try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "注册默认智能体 main")
                appLog("AgentStore: 已向 gateway 注册默认智能体 main")
            }
        } catch {
            appLog("AgentStore: 注册默认智能体失败: \(error)", level: .error)
        }

        // 2. 若 workspace 不存在，自动初始化
        let exists = await workspaceManager.workspaceExists(agentId: "main")
        if !exists {
            do {
                try await workspaceManager.initializeWorkspace(agentId: "main", seedContent: [:])
                agents[mainIdx].status = .idle
                appLog("AgentStore: 已创建默认智能体 main 的 workspace")
            } catch {
                appLog("AgentStore: 创建默认 workspace 失败: \(error)", level: .error)
            }
        }
    }

    /// 为指定智能体初始化 workspace（供 UI 在未初始化状态下手动触发）
    func initializeAgentWorkspace(id: String, fromPresetId: String? = nil) async throws {
        guard let workspaceManager else { return }
        guard let idx = agents.firstIndex(where: { $0.id == id }) else { return }

        // 从预置模板获取种子内容
        var seedContent: [PersonaFile: String] = [:]
        if let presetId = fromPresetId {
            seedContent = Self.extractPresetSeedContent(presetId: presetId)
        } else if agents[idx].isPreset {
            // 若该 agent 本身就是由预置模板派生，复用其 id
            seedContent = Self.extractPresetSeedContent(presetId: id)
        }

        try await workspaceManager.initializeWorkspace(agentId: id, seedContent: seedContent)
        agents[idx].status = .idle
    }

    // MARK: - 智能体 CRUD

    /// 添加新智能体到 gateway 配置
    func addAgent(
        id: String,
        name: String,
        emoji: String = "🤖",
        description: String = "",
        category: AgentCategory = .strategy,
        workspace: String? = nil,
        fromPresetId: String? = nil
    ) async throws {
        guard let gateway, let workspaceManager else { return }

        // 从预置模板获取种子内容
        var seedContent: [PersonaFile: String] = [:]
        if let presetId = fromPresetId,
           let preset = presetTemplates.first(where: { $0.id == presetId }) {
            // 预置模板中 systemPrompt/identity 字段在旧模型中已移除，
            // 但 PresetAgents.json 仍保留这些字段，通过 raw JSON 提取
            seedContent = Self.extractPresetSeedContent(presetId: presetId)
        }

        // 1. 创建 workspace 目录和文件
        try await workspaceManager.initializeWorkspace(
            agentId: id,
            seedContent: seedContent
        )

        // 2. 更新 gateway 配置：追加到 agents.list
        let (config, baseHash) = try await gateway.configGetFull()
        var agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        var newEntry: [String: Any] = ["id": id]
        if let ws = workspace {
            newEntry["workspace"] = ws
        }
        agentsList.append(newEntry)
        let patch: [String: Any] = ["agents": ["list": agentsList]]
        try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "添加智能体: \(name)")

        // 3. 添加到本地列表
        let agent = Agent(
            id: id,
            name: name,
            emoji: emoji,
            description: description,
            category: category,
            workspace: workspace,
            isDefault: agents.isEmpty
        )
        agents.append(agent)
    }

    /// 删除智能体
    func removeAgent(id: String) async throws {
        guard id != "main" else { return } // 不允许删除默认智能体
        guard let gateway, let workspaceManager else { return }

        // 1. 从 gateway 配置移除
        let (config, baseHash) = try await gateway.configGetFull()
        var agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        agentsList.removeAll { ($0["id"] as? String) == id }

        // 同时移除关联的 bindings
        var bindingsList = config["bindings"] as? [[String: Any]] ?? []
        bindingsList.removeAll { ($0["agentId"] as? String) == id }

        let patch: [String: Any] = [
            "agents": ["list": agentsList],
            "bindings": bindingsList
        ]
        try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "删除智能体: \(id)")

        // 2. 删除 workspace
        try await workspaceManager.deleteWorkspace(agentId: id)

        // 3. 从本地列表移除
        agents.removeAll { $0.id == id }
        bindings.removeAll { $0.agentId == id }
    }

    /// 更新智能体元数据（仅影响本地显示，OpenClaw 配置中只存 id 和 workspace）
    func updateAgent(_ agent: Agent) {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[idx] = agent
    }

    // MARK: - Bindings 管理

    /// 添加渠道绑定
    func addBinding(_ binding: AgentBinding) async throws {
        guard let gateway else { return }

        let (config, baseHash) = try await gateway.configGetFull()
        var bindingsList = config["bindings"] as? [[String: Any]] ?? []
        bindingsList.append(binding.toPatchDict())

        let patch: [String: Any] = ["bindings": bindingsList]
        try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "添加绑定: \(binding.agentId) ← \(binding.channel)")

        bindings.append(binding)
    }

    /// 移除渠道绑定
    func removeBinding(_ binding: AgentBinding) async throws {
        guard let gateway else { return }

        let (config, baseHash) = try await gateway.configGetFull()
        var bindingsList = config["bindings"] as? [[String: Any]] ?? []
        // 按 agentId + channel + accountId + peerId 匹配移除
        bindingsList.removeAll { entry in
            guard let aid = entry["agentId"] as? String, aid == binding.agentId else { return false }
            guard let match = entry["match"] as? [String: Any],
                  let ch = match["channel"] as? String, ch == binding.channel else { return false }
            let acc = match["accountId"] as? String
            if acc != binding.accountId { return false }
            let peer = match["peer"] as? [String: Any]
            let pid = peer?["id"] as? String
            return pid == binding.peerId
        }

        let patch: [String: Any] = ["bindings": bindingsList]
        try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "移除绑定: \(binding.agentId) ← \(binding.channel)")

        bindings.removeAll { $0.id == binding.id }
    }

    // MARK: - 筛选

    func agents(for category: AgentCategory) -> [Agent] {
        agents.filter { $0.category == category }
    }

    func search(_ query: String) -> [Agent] {
        guard !query.isEmpty else { return agents }
        let q = query.lowercased()
        return agents.filter { agent in
            agent.name.lowercased().contains(q)
            || agent.description.lowercased().contains(q)
            || agent.skills.contains(where: { $0.lowercased().contains(q) })
        }
    }

    /// 获取指定智能体的绑定列表
    func bindings(for agentId: String) -> [AgentBinding] {
        bindings.filter { $0.agentId == agentId }
    }

    // MARK: - 预置模板

    private static func loadPresets() -> [Agent] {
        guard let url = Bundle.main.url(forResource: "PresetAgents", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            appLog("AgentStore: PresetAgents.json not found", level: .error)
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode([Agent].self, from: data)
        } catch {
            appLog("AgentStore: failed to decode presets: \(error)", level: .error)
            return []
        }
    }

    /// 从 PresetAgents.json 原始 JSON 提取种子内容（systemPrompt, identity, userTemplate）
    static func extractPresetSeedContent(presetId: String) -> [PersonaFile: String] {
        guard let url = Bundle.main.url(forResource: "PresetAgents", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return [:]
        }
        guard let entry = array.first(where: { ($0["id"] as? String) == presetId }) else {
            return [:]
        }
        var content: [PersonaFile: String] = [:]
        if let sp = entry["systemPrompt"] as? String, !sp.isEmpty { content[.soul] = sp }
        if let id = entry["identity"] as? String, !id.isEmpty { content[.identity] = id }
        if let ut = entry["userTemplate"] as? String, !ut.isEmpty { content[.user] = ut }
        return content
    }

    // MARK: - 配置解析

    /// 从 gateway 配置 JSON 解析 agents 和 bindings
    private func parseConfig(_ config: [String: Any]) {
        // 解析 agents.list
        var parsedAgents: [Agent] = []
        if let agentsConfig = config["agents"] as? [String: Any],
           let list = agentsConfig["list"] as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String else { continue }
                let ws = entry["workspace"] as? String
                let dir = entry["agentDir"] as? String
                let isDefault = entry["default"] as? Bool ?? false

                // 尝试从预置模板匹配显示信息
                let preset = presetTemplates.first(where: { $0.id == id })
                let agent = Agent(
                    id: id,
                    name: preset?.name ?? id,
                    emoji: preset?.emoji ?? "🤖",
                    description: preset?.description ?? "",
                    category: preset?.category ?? .strategy,
                    preferredModel: preset?.preferredModel,
                    skills: preset?.skills ?? [],
                    isPreset: preset != nil,
                    workspace: ws,
                    agentDir: dir,
                    isDefault: isDefault
                )
                parsedAgents.append(agent)
            }
        }

        // 如果 gateway 没有配置任何智能体，添加默认 main
        if parsedAgents.isEmpty {
            parsedAgents.append(Agent(
                id: "main",
                name: L10n.k("agent.default.name", fallback: "默认智能体"),
                emoji: "🧠",
                description: L10n.k("agent.default.desc", fallback: "主智能体"),
                category: .strategy,
                isDefault: true
            ))
        }

        agents = parsedAgents

        // 解析 bindings
        if let bindingsArray = config["bindings"] as? [[String: Any]] {
            var parsed: [AgentBinding] = []
            for entry in bindingsArray {
                guard let agentId = entry["agentId"] as? String,
                      let match = entry["match"] as? [String: Any],
                      let channel = match["channel"] as? String else { continue }
                let accountId = match["accountId"] as? String
                let guildId = match["guildId"] as? String
                let teamId = match["teamId"] as? String
                var peerId: String?
                var peerKind: String?
                if let peer = match["peer"] as? [String: Any] {
                    peerId = peer["id"] as? String
                    peerKind = peer["kind"] as? String
                }
                parsed.append(AgentBinding(
                    agentId: agentId,
                    channel: channel,
                    accountId: accountId,
                    peerId: peerId,
                    peerKind: peerKind,
                    guildId: guildId,
                    teamId: teamId
                ))
            }
            bindings = parsed
        } else {
            bindings = []
        }

        // 关联 bindings 到 agents
        for i in agents.indices {
            agents[i].boundBindings = bindings.filter { $0.agentId == agents[i].id }
        }
    }

    // MARK: - Workspace 状态扫描

    private func refreshWorkspaceStatus() async {
        guard let workspaceManager else { return }
        for i in agents.indices {
            let exists = await workspaceManager.workspaceExists(agentId: agents[i].id)
            agents[i].status = exists ? .idle : .uninitialized

            // 检查 sessions 目录判断是否有活跃会话
            if exists {
                do {
                    let sessions = try await workspaceManager.listSessions(agentId: agents[i].id)
                    agents[i].sessionCount = sessions.count
                    if !sessions.isEmpty {
                        agents[i].status = .active
                    }
                } catch {
                    // sessions 目录可能不存在，忽略
                }
            }
        }
    }

    // MARK: - 数据迁移（旧 agents.json → 新架构）

    /// 检查并执行一次性迁移
    func migrateIfNeeded() async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let oldPath = home.appendingPathComponent(".openclaw/agents.json")

        guard FileManager.default.fileExists(atPath: oldPath.path),
              let data = try? Data(contentsOf: oldPath) else { return }

        appLog("AgentStore: 检测到旧版 agents.json，开始迁移")

        // 解析旧格式（包含 systemPrompt/identity/userTemplate 等字段）
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

        for entry in array {
            guard let id = entry["id"] as? String else { continue }
            let wasActive = entry["isActive"] as? Bool ?? false

            // 只迁移曾激活过的智能体
            guard wasActive else { continue }

            var seedContent: [PersonaFile: String] = [:]
            if let sp = entry["systemPrompt"] as? String, !sp.isEmpty { seedContent[.soul] = sp }
            if let identity = entry["identity"] as? String, !identity.isEmpty { seedContent[.identity] = identity }
            if let ut = entry["userTemplate"] as? String, !ut.isEmpty { seedContent[.user] = ut }

            do {
                try await workspaceManager?.initializeWorkspace(
                    agentId: id,
                    seedContent: seedContent
                )
                appLog("AgentStore: 迁移智能体 \(id) 成功")
            } catch {
                appLog("AgentStore: 迁移智能体 \(id) 失败: \(error)", level: .error)
            }
        }

        // 备份旧文件
        let backupPath = home.appendingPathComponent(".openclaw/agents.json.migrated")
        try? FileManager.default.moveItem(at: oldPath, to: backupPath)
        appLog("AgentStore: 迁移完成，旧文件已备份")
    }
}
