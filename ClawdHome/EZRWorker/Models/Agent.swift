// ClawdHome/Models/Agent.swift
// OpenClaw 原生多智能体模型 — 对应 openclaw.json 中 agents.list[] 条目

import Foundation

struct Agent: Codable, Identifiable, Equatable {
    let id: String                    // agentId（如 "main", "work", "social"）
    var name: String                  // 显示名称
    var emoji: String                 // 图标
    var description: String           // 简短描述
    var category: AgentCategory       // 分类
    var preferredModel: String?       // 首选模型
    var skills: [String]              // 技能标签
    var isPreset: Bool                // 是否为预置模板（仅 UI 侧使用）

    // OpenClaw 原生字段
    var workspace: String?            // 自定义 workspace 路径（nil 时用默认路径）
    var agentDir: String?             // 自定义 agent 目录路径
    var isDefault: Bool               // 是否为默认智能体

    // 运行时状态（不编码到 JSON）
    var status: AgentStatus = .idle
    var boundBindings: [AgentBinding] = []
    var sessionCount: Int = 0
    var lastActiveAt: Date?

    static func == (lhs: Agent, rhs: Agent) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.emoji == rhs.emoji
            && lhs.description == rhs.description
            && lhs.category == rhs.category
            && lhs.preferredModel == rhs.preferredModel
            && lhs.skills == rhs.skills
            && lhs.isPreset == rhs.isPreset
            && lhs.workspace == rhs.workspace
            && lhs.agentDir == rhs.agentDir
            && lhs.isDefault == rhs.isDefault
            && lhs.status == rhs.status
            && lhs.boundBindings == rhs.boundBindings
            && lhs.sessionCount == rhs.sessionCount
            && lhs.lastActiveAt == rhs.lastActiveAt
    }

    // MARK: - Codable（跳过运行时字段）

    enum CodingKeys: String, CodingKey {
        case id, name, emoji, description, category, preferredModel, skills, isPreset
        case workspace, agentDir, isDefault
    }

    init(
        id: String,
        name: String,
        emoji: String,
        description: String,
        category: AgentCategory,
        preferredModel: String? = nil,
        skills: [String] = [],
        isPreset: Bool = false,
        workspace: String? = nil,
        agentDir: String? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.description = description
        self.category = category
        self.preferredModel = preferredModel
        self.skills = skills
        self.isPreset = isPreset
        self.workspace = workspace
        self.agentDir = agentDir
        self.isDefault = isDefault
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        emoji = try c.decode(String.self, forKey: .emoji)
        description = try c.decode(String.self, forKey: .description)
        category = try c.decode(AgentCategory.self, forKey: .category)
        preferredModel = try c.decodeIfPresent(String.self, forKey: .preferredModel)
        skills = try c.decodeIfPresent([String].self, forKey: .skills) ?? []
        isPreset = try c.decodeIfPresent(Bool.self, forKey: .isPreset) ?? false
        workspace = try c.decodeIfPresent(String.self, forKey: .workspace)
        agentDir = try c.decodeIfPresent(String.self, forKey: .agentDir)
        isDefault = try c.decodeIfPresent(Bool.self, forKey: .isDefault) ?? false
    }
}

struct AgentPersistedMetadata: Codable {
    var emoji: String
    var description: String
    var category: AgentCategory
    var skills: [String]

    init(
        emoji: String,
        description: String,
        category: AgentCategory,
        skills: [String]
    ) {
        self.emoji = emoji
        self.description = description
        self.category = category
        self.skills = skills
    }
}
