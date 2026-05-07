import Foundation

enum PersonaFile: String, CaseIterable, Identifiable {
    case soul = "SOUL.md"
    case identity = "IDENTITY.md"
    case agents = "AGENTS.md"
    case tools = "TOOLS.md"
    case memory = "MEMORY.md"
    case user = "USER.md"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .soul: return "💫"
        case .identity: return "🪪"
        case .agents: return "🤖"
        case .tools: return "🔧"
        case .memory: return "🗂️"
        case .user: return "👤"
        }
    }

    var description: String {
        switch self {
        case .soul:
            return L10n.k("persona.file.soul.desc", fallback: "核心价值观 · 行为准则")
        case .identity:
            return L10n.k("persona.file.identity.desc", fallback: "说话风格 · 身份设定")
        case .agents:
            return L10n.k("persona.file.agents.desc", fallback: "操作指令 · 记忆管理")
        case .tools:
            return L10n.k("persona.file.tools.desc", fallback: "可调用的 API 和工具")
        case .memory:
            return L10n.k("persona.file.memory.desc", fallback: "记住的重要事实")
        case .user:
            return L10n.k("persona.file.user.desc", fallback: "用户认知 · 偏好设定")
        }
    }

    func relPath(agentId: String?) -> String {
        let dir = (agentId == nil || agentId == "main")
            ? ".openclaw/workspace"
            : ".openclaw/workspace-\(agentId!)"
        return "\(dir)/\(rawValue)"
    }
}
