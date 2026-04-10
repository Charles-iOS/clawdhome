// ClawdHome/Services/Stores/AgentStore.swift
// 管理智能体定义：预置角色加载 + 自定义角色 CRUD + 持久化

import Foundation
import Observation

@MainActor @Observable
final class AgentStore {

    private(set) var agents: [Agent] = []
    private(set) var activeAgent: Agent?

    private let customStorePath: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".openclaw/agents.json")
    }()

    // MARK: - 初始化

    func load() {
        let presets = Self.loadPresets()
        let custom = loadCustomAgents()
        agents = presets + custom
        activeAgent = agents.first(where: \.isActive)
    }

    // MARK: - CRUD

    func add(_ agent: Agent) {
        var newAgent = agent
        newAgent.isPreset = false
        agents.append(newAgent)
        saveCustomAgents()
    }

    func update(_ agent: Agent) {
        guard let idx = agents.firstIndex(where: { $0.id == agent.id }) else { return }
        agents[idx] = agent
        if agent.isActive { activeAgent = agent }
        saveCustomAgents()
    }

    func delete(id: String) {
        guard let agent = agents.first(where: { $0.id == id }), !agent.isPreset else { return }
        agents.removeAll { $0.id == id }
        if activeAgent?.id == id { activeAgent = nil }
        saveCustomAgents()
    }

    // MARK: - 激活

    func activate(id: String) {
        for i in agents.indices {
            agents[i].isActive = (agents[i].id == id)
        }
        activeAgent = agents.first(where: { $0.id == id })
        saveCustomAgents()
    }

    func deactivateAll() {
        for i in agents.indices { agents[i].isActive = false }
        activeAgent = nil
        saveCustomAgents()
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

    // MARK: - 预置角色

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

    // MARK: - 自定义角色持久化

    private func loadCustomAgents() -> [Agent] {
        guard FileManager.default.fileExists(atPath: customStorePath.path),
              let data = try? Data(contentsOf: customStorePath) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Agent].self, from: data)) ?? []
    }

    private func saveCustomAgents() {
        let custom = agents.filter { !$0.isPreset }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(custom) else { return }
        try? data.write(to: customStorePath, options: .atomic)
    }
}
