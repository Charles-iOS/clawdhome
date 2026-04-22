// EZRWorkerApp/Models/AgentStyle.swift
// 智能体风格标签

import Foundation

enum AgentStyle: String, Codable, CaseIterable, Identifiable {
    case professional = "professional"
    case friendly = "friendly"
    case creative = "creative"
    case concise = "concise"
    case casual = "casual"
    case expert = "expert"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .professional: return L10n.k("agent.style.professional", fallback: "专业")
        case .friendly:     return L10n.k("agent.style.friendly", fallback: "友好")
        case .creative:     return L10n.k("agent.style.creative", fallback: "创意")
        case .concise:      return L10n.k("agent.style.concise", fallback: "简洁")
        case .casual:       return L10n.k("agent.style.casual", fallback: "随意")
        case .expert:       return L10n.k("agent.style.expert", fallback: "专家")
        }
    }
}
