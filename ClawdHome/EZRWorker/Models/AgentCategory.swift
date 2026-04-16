// ClawdHome/Models/AgentCategory.swift

import Foundation

enum AgentCategory: String, Codable, CaseIterable, Identifiable {
    case strategy = "战略"
    case growth = "增长"
    case life = "生活"
    case education = "教育"
    case finance = "财务"
    case engineering = "研发"
    case creative = "创作"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .strategy:    return L10n.k("agent.category.strategy", fallback: "战略")
        case .growth:      return L10n.k("agent.category.growth", fallback: "增长")
        case .life:        return L10n.k("agent.category.life", fallback: "生活")
        case .education:   return L10n.k("agent.category.education", fallback: "教育")
        case .finance:     return L10n.k("agent.category.finance", fallback: "财务")
        case .engineering: return L10n.k("agent.category.engineering", fallback: "研发")
        case .creative:    return L10n.k("agent.category.creative", fallback: "创作")
        }
    }

    var emoji: String {
        switch self {
        case .strategy:    return "🧭"
        case .growth:      return "📈"
        case .life:        return "🌿"
        case .education:   return "🧠"
        case .finance:     return "💹"
        case .engineering: return "💻"
        case .creative:    return "🎨"
        }
    }
}
