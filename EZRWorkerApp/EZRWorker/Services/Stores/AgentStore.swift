// EZRWorkerApp/Services/Stores/AgentStore.swift
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
    private(set) var username: String = ""

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
            // 网关暂不可用时也要保底生成 main，避免 UI 出现空列表
            parseConfig([:])
        }

        await applyPersistedMetadata()

        // 扫描 workspace 状态
        await refreshWorkspaceStatus()

        // 确保默认 main 智能体已注册且 workspace 已初始化
        await ensureDefaultAgentInitialized()
    }

    /// 仅刷新智能体运行态（workspace / 会话数 / 活跃态），不重读 gateway 配置。
    func refreshRuntimeState() async {
        await refreshWorkspaceStatus()
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
        switch await workspaceManager.probeWorkspace(agentId: "main") {
        case .exists:
            break
        case .missing:
            do {
                try await workspaceManager.initializeWorkspace(agentId: "main", seedContent: [:])
                agents[mainIdx].status = .idle
                appLog("AgentStore: 已创建默认智能体 main 的 workspace")
            } catch {
                appLog("AgentStore: 创建默认 workspace 失败: \(error)", level: .error)
            }
        case .indeterminate(let reason):
            appLog("AgentStore: 无法确认默认智能体 workspace 状态，跳过自动创建: \(reason)", level: .warn)
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
        fromPresetId: String? = nil,
        seedContent overrideSeedContent: [PersonaFile: String]? = nil,
        preferredModel: String? = nil,
        skills: [String]? = nil
    ) async throws {
        guard let gateway, let workspaceManager else { return }
        let resolvedId = try Self.validateAgentId(id)

        // 从预置模板获取种子内容，或使用调用方传入的 seed
        var seedContent: [PersonaFile: String] = [:]
        if let overrideSeedContent {
            // 向导模式：调用方已组装好 seed content
            seedContent = overrideSeedContent
            // 如果同时指定了模板，将模板中的 SOUL 合并进去（若调用方未提供 soul）
            if let presetId = fromPresetId,
               presetTemplates.contains(where: { $0.id == presetId }) {
                let presetSeed = Self.extractPresetSeedContent(presetId: presetId)
                for (file, content) in presetSeed where seedContent[file] == nil {
                    seedContent[file] = content
                }
            }
        } else if let presetId = fromPresetId,
           presetTemplates.contains(where: { $0.id == presetId }) {
            // 预置模板中 systemPrompt/identity 字段在旧模型中已移除，
            // 但 PresetAgents.json 仍保留这些字段，通过 raw JSON 提取
            seedContent = Self.extractPresetSeedContent(presetId: presetId)
        }

        do {
            try await tryAddAgentViaCLI(id: resolvedId)
            appLog("AgentStore: CLI 添加智能体成功 id=\(resolvedId)")
        } catch {
            if await didCLIAddActuallySucceed(gateway: gateway, agentId: resolvedId) {
                appLog("AgentStore: CLI 添加智能体虽超时/报错，但配置已生效 id=\(resolvedId)", level: .warn)
            } else {
            let cliErr = error
            appLog("AgentStore: CLI 添加智能体失败，回退 patch 方案 id=\(resolvedId): \(cliErr)", level: .warn)
            do {
                try await addAgentViaPatchFallback(
                    gateway: gateway,
                    workspaceManager: workspaceManager,
                    id: resolvedId,
                    name: name,
                    workspace: workspace,
                    seedContent: seedContent
                )
            } catch {
                let fallbackErr = error
                throw AgentCreationError(
                    cliReason: (cliErr as? LocalizedError)?.errorDescription ?? cliErr.localizedDescription,
                    fallbackReason: (fallbackErr as? LocalizedError)?.errorDescription ?? fallbackErr.localizedDescription
                )
            }
            }
        }

        do {
            try await ensureAgentWorkspaceSeeded(
                agentId: resolvedId,
                seedContent: seedContent
            )
        } catch {
            appLog("AgentStore: 初始化智能体 workspace 失败 id=\(resolvedId): \(error)", level: .warn)
        }

        do {
            try await persistAgentDisplayName(
                gateway: gateway,
                agentId: resolvedId,
                name: name
            )
        } catch {
            appLog("AgentStore: 持久化智能体名称失败 id=\(resolvedId): \(error)", level: .warn)
        }

        do {
            try await persistAgentMetadata(
                agentId: resolvedId,
                emoji: emoji,
                description: description,
                category: category,
                skills: skills ?? []
            )
        } catch {
            appLog("AgentStore: 持久化智能体元数据失败 id=\(resolvedId): \(error)", level: .warn)
        }

        // 刷新本地列表，避免与 gateway 真实状态漂移
        await refreshFromGateway()

        // 兜底：若刷新后仍未出现（极端时序），补写本地展示项
        guard !agents.contains(where: { $0.id == resolvedId }) else { return }
        let agent = Agent(
            id: resolvedId,
            name: name,
            emoji: emoji,
            description: description,
            category: category,
            workspace: workspace,
            isDefault: agents.isEmpty
        )
        agents.append(agent)
    }

    private func tryAddAgentViaCLI(id: String) async throws {
        guard let profile = workspaceManager?.currentProfileResolution else {
            throw GatewayClientError.requestFailed(
                code: "profile_runtime_missing",
                message: "当前 profile 未就绪，无法执行 agents add"
            )
        }
        let (ok, output) = try await withThrowingTaskGroup(of: (Bool, String).self) { group in
            group.addTask {
                await GatewayProcessManager.addAgentLocally(agentId: id, profile: profile)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw GatewayClientError.requestFailed(
                    code: "agents_add_cli_timeout",
                    message: "openclaw agents add 执行超时，已自动回退"
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        guard ok else {
            throw GatewayClientError.requestFailed(
                code: "agents_add_cli_failed",
                message: output.isEmpty ? "openclaw agents add 执行失败" : output
            )
        }
    }

    private func addAgentViaPatchFallback(
        gateway: GatewayService,
        workspaceManager: AgentWorkspaceManager,
        id: String,
        name: String,
        workspace: String?,
        seedContent: [PersonaFile: String]
    ) async throws {
        // 1. 创建 workspace 目录和文件（旧实现）
        try await workspaceManager.initializeWorkspace(
            agentId: id,
            seedContent: seedContent
        )

        // 2. 更新 gateway 配置：追加到 agents.list（旧实现）
        let (config, baseHash) = try await gateway.configGetFull()
        var agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        var newEntry: [String: Any] = ["id": id]
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newEntry["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let ws = workspace {
            newEntry["workspace"] = ws
        }
        agentsList.append(newEntry)
        let patch: [String: Any] = ["agents": ["list": agentsList]]
        try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "添加智能体: \(name)")
    }

    /// 删除智能体
    func removeAgent(id: String) async throws {
        guard id != "main" else { return } // 不允许删除默认智能体
        guard let gateway, let workspaceManager else {
            appLog("AgentStore: removeAgent(\(id)) 失败 — gateway 或 workspaceManager 未就绪", level: .error)
            return
        }

        func finalizeLocalRemoval() async {
            agents.removeAll { $0.id == id }
            bindings.removeAll { $0.agentId == id }
            do {
                try await workspaceManager.deleteWorkspace(agentId: id)
            } catch {
                appLog("AgentStore: 清理 workspace 失败（不影响删除）: \(error)", level: .warn)
            }
        }

        do {
            try await tryDeleteAgentViaCLI(id: id)
            appLog("AgentStore: CLI 删除智能体成功 id=\(id)")
            await refreshFromGateway()
            await finalizeLocalRemoval()
            return
        } catch {
            do {
                let (config, _) = try await gateway.configGetFull()
                let cliDidActuallyDelete = !((config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? [])
                    .contains { ($0["id"] as? String) == id }
                if cliDidActuallyDelete {
                    appLog("AgentStore: CLI 删除智能体虽超时/报错，但配置已生效 id=\(id)", level: .warn)
                    await refreshFromGateway()
                    await finalizeLocalRemoval()
                    return
                }
            } catch {
                appLog("AgentStore: 校验 CLI 删除结果失败 id=\(id): \(error)", level: .warn)
            }

            appLog("AgentStore: CLI 删除智能体失败，回退 patch 方案 id=\(id): \(error)", level: .warn)
        }

        func removeAgentFromSnapshot(_ config: [String: Any]) -> (agentsList: [[String: Any]], bindingsList: [[String: Any]], didContainAgent: Bool) {
            var agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            let beforeCount = agentsList.count
            agentsList.removeAll { ($0["id"] as? String) == id }

            var bindingsList = config["bindings"] as? [[String: Any]] ?? []
            bindingsList.removeAll { ($0["agentId"] as? String) == id }
            return (agentsList, bindingsList, agentsList.count < beforeCount)
        }

        func configStillContainsAgent(_ config: [String: Any]) -> Bool {
            let agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            return agentsList.contains { ($0["id"] as? String) == id }
        }

        // 1. 从 gateway 配置移除（核心步骤，必须成功）
        let (config, baseHash) = try await gateway.configGetFull()
        let removal = removeAgentFromSnapshot(config)

        if removal.didContainAgent {
            let patch: [String: Any] = [
                "agents": ["list": removal.agentsList],
                "bindings": removal.bindingsList
            ]
            let (noop, patchedConfig) = try await gateway.configPatch(
                patch: patch,
                baseHash: baseHash,
                note: "删除智能体: \(id)"
            )

            let deletedAfterFirstPatch = !configStillContainsAgent(patchedConfig)
            if noop || !deletedAfterFirstPatch {
                appLog("AgentStore: 删除智能体首次 patch 未确认生效，准备重试 id=\(id) noop=\(noop)", level: .warn)

                let (freshConfig, freshHash) = try await gateway.configGetFull()
                let freshRemoval = removeAgentFromSnapshot(freshConfig)
                let retryPatch: [String: Any] = [
                    "agents": ["list": freshRemoval.agentsList],
                    "bindings": freshRemoval.bindingsList
                ]
                let (retryNoop, retryConfig) = try await gateway.configPatch(
                    patch: retryPatch,
                    baseHash: freshHash,
                    note: "删除智能体(重试): \(id)"
                )

                if retryNoop || configStillContainsAgent(retryConfig) {
                    let (verifiedConfig, _) = try await gateway.configGetFull()
                    if configStillContainsAgent(verifiedConfig) {
                        appLog("AgentStore: 删除智能体未持久化，终止本地移除 id=\(id)", level: .error)
                        throw GatewayClientError.requestFailed(
                            code: "agent_delete_not_persisted",
                            message: "删除未写入配置，请重试"
                        )
                    }
                }
            }

            appLog("AgentStore: 已从 gateway 配置移除智能体 id=\(id)")
        } else {
            appLog("AgentStore: 智能体 id=\(id) 不在 gateway agents.list 中，仅做本地清理", level: .warn)
        }

        // 2. 从本地列表和文件系统移除
        await finalizeLocalRemoval()
    }

    private func tryDeleteAgentViaCLI(id: String) async throws {
        guard let profile = workspaceManager?.currentProfileResolution else {
            throw GatewayClientError.requestFailed(
                code: "profile_runtime_missing",
                message: "当前 profile 未就绪，无法执行 agents delete"
            )
        }
        let (ok, output) = try await withThrowingTaskGroup(of: (Bool, String).self) { group in
            group.addTask {
                await GatewayProcessManager.deleteAgentLocally(agentId: id, profile: profile)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 30_000_000_000)
                throw GatewayClientError.requestFailed(
                    code: "agents_delete_cli_timeout",
                    message: "openclaw agents delete 执行超时，已自动回退"
                )
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
        guard ok else {
            throw GatewayClientError.requestFailed(
                code: "agents_delete_cli_failed",
                message: output.isEmpty ? "openclaw agents delete 执行失败" : output
            )
        }
    }

    /// 更新智能体元数据（显示信息持久化到本地 metadata.json）
    func updateAgent(_ agent: Agent) async {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[idx] = agent

        do {
            try await persistAgentMetadata(
                agentId: agent.id,
                emoji: agent.emoji,
                description: agent.description,
                category: agent.category,
                skills: agent.skills
            )
        } catch {
            appLog("AgentStore: 更新智能体元数据失败 id=\(agent.id): \(error)", level: .warn)
        }
    }

    /// 设置智能体的首选模型（写入 agents.list[].model.primary）
    /// - Parameters:
    ///   - agentId: 智能体 ID
    ///   - modelId: 模型 ID（nil 或空字符串表示清除，使用全局默认）
    func setAgentModel(agentId: String, modelId: String?) async throws {
        guard let gateway else { return }

        let (config, baseHash) = try await gateway.configGetFull()
        var agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []

        guard let idx = agentsList.firstIndex(where: { ($0["id"] as? String) == agentId }) else { return }

        if let modelId, !modelId.isEmpty {
            agentsList[idx]["model"] = ["primary": modelId]
        } else {
            agentsList[idx].removeValue(forKey: "model")
        }

        let patch: [String: Any] = ["agents": ["list": agentsList]]
        try await gateway.configPatch(
            patch: patch,
            baseHash: baseHash,
            note: "设置智能体 \(agentId) 模型: \(modelId ?? "全局默认")"
        )

        // 更新本地状态
        if let localIdx = agents.firstIndex(where: { $0.id == agentId }) {
            agents[localIdx].preferredModel = (modelId?.isEmpty == false) ? modelId : nil
        }
    }

    // MARK: - Bindings 管理

    /// 添加渠道绑定
    func addBinding(_ binding: AgentBinding) async throws {
        guard let gateway else { return }

        let (config, baseHash) = try await gateway.configGetFull()
        var bindingsList = config["bindings"] as? [[String: Any]] ?? []

        // WeCom plugin resolves its single-account bot as accountId=default.
        // Drop the legacy unscoped binding before writing the account-scoped one,
        // otherwise the UI can show duplicate "same channel, same agent" rows.
        if binding.channel == "wecom", binding.accountId == "default", binding.peerId == nil {
            bindingsList.removeAll { entry in
                guard let aid = entry["agentId"] as? String, aid == binding.agentId else { return false }
                guard let match = entry["match"] as? [String: Any],
                      let ch = match["channel"] as? String, ch == binding.channel else { return false }
                let acc = match["accountId"] as? String
                let peer = match["peer"] as? [String: Any]
                let pid = peer?["id"] as? String
                return acc == nil && pid == nil
            }
        }
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

    /// Gateway 断开或停止后，清理基于旧连接残留的运行态展示。
    func markGatewayDisconnected() {
        for index in agents.indices where agents[index].status == .active {
            agents[index].status = .idle
            agents[index].sessionCount = 0
        }
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
        var seenNormalizedIds = Set<String>()
        if let agentsConfig = config["agents"] as? [String: Any],
           let list = agentsConfig["list"] as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String else { continue }
                let normalizedId = Self.normalizedAgentIdKey(id)
                if seenNormalizedIds.contains(normalizedId) {
                    appLog("AgentStore: 检测到重复/脏 agent 配置，已忽略后续条目 rawId=\(id) normalizedId=\(normalizedId)", level: .warn)
                    continue
                }
                seenNormalizedIds.insert(normalizedId)
                let ws = entry["workspace"] as? String
                let dir = entry["agentDir"] as? String
                let isDefault = entry["default"] as? Bool ?? false

                // 读取 per-agent 模型配置
                let modelConfig = entry["model"] as? [String: Any]
                let agentModel = modelConfig?["primary"] as? String
                let configuredName = (entry["name"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                // 尝试从预置模板匹配显示信息
                let preset = presetTemplates.first(where: { $0.id == id })
                let agent = Agent(
                    id: id,
                    name: (configuredName?.isEmpty == false ? configuredName! : (preset?.name ?? id)),
                    emoji: preset?.emoji ?? "🤖",
                    description: preset?.description ?? "",
                    category: preset?.category ?? .strategy,
                    preferredModel: agentModel ?? preset?.preferredModel,
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

        var finalizedAgents = parsedAgents

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
        for i in finalizedAgents.indices {
            finalizedAgents[i].boundBindings = bindings.filter { $0.agentId == finalizedAgents[i].id }
        }
        agents = finalizedAgents
    }

    // MARK: - Workspace 状态扫描

    private func refreshWorkspaceStatus() async {
        guard let workspaceManager else { return }
        var updatedAgents = agents
        for i in updatedAgents.indices {
            switch await workspaceManager.probeWorkspace(agentId: updatedAgents[i].id) {
            case .exists:
                updatedAgents[i].status = .idle
                updatedAgents[i].sessionCount = 0
                updatedAgents[i].lastActiveAt = nil
                // 只要存在任意会话文件，就视为运行中。
                do {
                    let sessions = try await workspaceManager.listSessions(agentId: updatedAgents[i].id)
                    updatedAgents[i].sessionCount = sessions.count
                    updatedAgents[i].lastActiveAt = sessions.compactMap(\.modifiedAt).max()
                    if !sessions.isEmpty {
                        updatedAgents[i].status = .active
                    }
                } catch {
                    // sessions 目录可能不存在，忽略
                }
            case .missing:
                updatedAgents[i].status = .uninitialized
                updatedAgents[i].sessionCount = 0
                updatedAgents[i].lastActiveAt = nil
            case .indeterminate(let reason):
                appLog("AgentStore: workspace 探测失败，保留当前状态 id=\(updatedAgents[i].id): \(reason)", level: .warn)
            }
        }
        agents = updatedAgents
    }

    private func ensureAgentWorkspaceSeeded(
        agentId: String,
        seedContent: [PersonaFile: String]
    ) async throws {
        guard let workspaceManager else { return }

        switch await workspaceManager.probeWorkspace(agentId: agentId) {
        case .missing:
            try await workspaceManager.initializeWorkspace(
                agentId: agentId,
                seedContent: seedContent
            )
            return
        case .exists:
            break
        case .indeterminate(let reason):
            throw NSError(
                domain: "AgentStore",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法确认智能体 \(agentId) 的 workspace 状态：\(reason)"]
            )
        }

        for (file, content) in seedContent where !content.isEmpty {
            try await workspaceManager.writePersonaFile(
                agentId: agentId,
                file: file,
                content: content
            )
        }
    }

    private func applyPersistedMetadata() async {
        guard let workspaceManager else { return }

        var updatedAgents = agents
        for i in updatedAgents.indices {
            do {
                let metadata = try await workspaceManager.readAgentMetadata(agentId: updatedAgents[i].id)
                updatedAgents[i].emoji = metadata.emoji
                updatedAgents[i].description = metadata.description
                updatedAgents[i].category = metadata.category
                updatedAgents[i].skills = metadata.skills
            } catch {
                // metadata 文件不存在或不可读时，继续使用配置/模板默认值
            }
        }
        agents = updatedAgents
    }

    // MARK: - 数据迁移（旧 agents.json → 新架构）

    /// 检查并执行一次性迁移
    func migrateIfNeeded() async {
        guard let resolution = workspaceManager?.currentProfileResolution else { return }
        let oldPath = URL(fileURLWithPath: resolution.resolvedStateDir, isDirectory: true)
            .appendingPathComponent("agents.json")

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
        let backupPath = oldPath.deletingPathExtension().appendingPathExtension("json.migrated")
        try? FileManager.default.moveItem(at: oldPath, to: backupPath)
        appLog("AgentStore: 迁移完成，旧文件已备份")
    }
}

private struct AgentCreationError: LocalizedError {
    let cliReason: String
    let fallbackReason: String

    var errorDescription: String? {
        """
        创建智能体失败：CLI 与回退方案均未成功。
        CLI 错误：\(cliReason)
        回退错误：\(fallbackReason)
        """
    }
}

private extension AgentStore {
    func didCLIAddActuallySucceed(gateway: GatewayService, agentId: String) async -> Bool {
        do {
            let (config, _) = try await gateway.configGetFull()
            let agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            return agentsList.contains { Self.normalizedAgentIdKey($0["id"] as? String ?? "") == agentId }
        } catch {
            appLog("AgentStore: 校验 CLI 添加结果失败 id=\(agentId): \(error)", level: .warn)
            return false
        }
    }

    func persistAgentDisplayName(
        gateway: GatewayService,
        agentId: String,
        name: String
    ) async throws {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        let (config, baseHash) = try await gateway.configGetFull()
        var agentsList = (config["agents"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        guard let idx = agentsList.firstIndex(where: {
            Self.normalizedAgentIdKey($0["id"] as? String ?? "") == agentId
        }) else { return }

        let currentName = (agentsList[idx]["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if currentName == trimmedName { return }

        agentsList[idx]["name"] = trimmedName
        let patch: [String: Any] = ["agents": ["list": agentsList]]
        _ = try await gateway.configPatch(
            patch: patch,
            baseHash: baseHash,
            note: "设置智能体名称: \(trimmedName)"
        )
    }

    func persistAgentMetadata(
        agentId: String,
        emoji: String,
        description: String,
        category: AgentCategory,
        skills: [String]
    ) async throws {
        guard let workspaceManager else { return }
        let metadata = AgentPersistedMetadata(
            emoji: emoji,
            description: description,
            category: category,
            skills: skills
        )
        try await workspaceManager.writeAgentMetadata(agentId: agentId, metadata: metadata)
    }

    static func normalizedAgentIdKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed
            .lowercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return normalized.isEmpty ? trimmed.lowercased() : normalized
    }

    static func validateAgentId(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = normalizedAgentIdKey(trimmed)
        guard !trimmed.isEmpty, trimmed == normalized else {
            throw GatewayClientError.requestFailed(
                code: "invalid_agent_id",
                message: "智能体 ID 仅支持英文小写字母、数字和连字符"
            )
        }
        return normalized
    }
}
