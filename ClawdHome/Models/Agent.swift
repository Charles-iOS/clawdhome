// ClawdHome/Models/Agent.swift

import Foundation

struct Agent: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var emoji: String
    var description: String
    var systemPrompt: String
    var identity: String
    var userTemplate: String
    var preferredModel: String?
    var skills: [String]
    var category: AgentCategory
    var isPreset: Bool
    var isActive: Bool
    var createdAt: Date

    static func == (lhs: Agent, rhs: Agent) -> Bool {
        lhs.id == rhs.id
    }
}
