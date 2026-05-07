import Foundation

struct SessionEntry: Identifiable {
    var id: String { key }
    let key: String
    let updatedAt: Double
    let inputTokens: Int?
    let outputTokens: Int?
    let model: String?
    let modelProvider: String?
    let label: String?
    let rawDisplayName: String?
    let sessionFile: String?
    let sessionId: String?
    let chatType: String?
    let channel: String?
    let subject: String?

    private static let knownChatTypes: Set<String> = ["direct", "group", "channel", "cron"]
    private static let knownChannels: Set<String> = [
        "discord", "feishu", "slack", "telegram", "wecom", "webchat", "whatsapp"
    ]

    static func from(_ dictionary: [String: Any]) -> SessionEntry? {
        guard let key = dictionary["key"] as? String else { return nil }
        return SessionEntry(
            key: key,
            updatedAt: (dictionary["updatedAt"] as? Double) ?? 0,
            inputTokens: dictionary["inputTokens"] as? Int,
            outputTokens: dictionary["outputTokens"] as? Int,
            model: dictionary["model"] as? String,
            modelProvider: dictionary["modelProvider"] as? String,
            label: dictionary["label"] as? String,
            rawDisplayName: dictionary["displayName"] as? String,
            sessionFile: dictionary["sessionFile"] as? String,
            sessionId: dictionary["sessionId"] as? String,
            chatType: dictionary["chatType"] as? String,
            channel: dictionary["channel"] as? String,
            subject: dictionary["subject"] as? String
        )
    }

    var displayName: String {
        if let label, !label.isEmpty { return label }
        if let rawDisplayName, !rawDisplayName.isEmpty { return rawDisplayName }

        let parts = key.split(separator: ":").map(String.init)
        if parts.count >= 3 {
            let platform = parts[2]
            switch platform {
            case "direct":
                return parts.count > 3
                    ? "\(L10n.k("views.sessions_tab_view.direct_message", fallback: "私聊")) · \(parts[3])"
                    : L10n.k("views.sessions_tab_view.direct_message", fallback: "私聊")
            case "group":
                return parts.count > 3
                    ? "\(L10n.k("views.sessions_tab_view.group", fallback: "群组")) · \(parts[3])"
                    : L10n.k("views.sessions_tab_view.group", fallback: "群组")
            case "cron":
                return L10n.k("views.sessions_tab_view.scheduled_tasks", fallback: "定时任务")
            case "channel":
                return parts.count > 3
                    ? "\(L10n.k("views.sessions_tab_view.channel", fallback: "频道")) · \(parts[3])"
                    : L10n.k("views.sessions_tab_view.channel", fallback: "频道")
            default:
                return platform
            }
        }
        return key
    }

    var normalizedChatType: String? {
        if let chatType {
            let trimmed = chatType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { return trimmed }
        }

        let parts = key.split(separator: ":").map(String.init)
        if parts.count > 3 {
            let candidate = parts[3].lowercased()
            if Self.knownChatTypes.contains(candidate) { return candidate }
        }
        if parts.count > 2 {
            let candidate = parts[2].lowercased()
            if Self.knownChatTypes.contains(candidate) { return candidate }
        }
        return nil
    }

    var normalizedChannel: String? {
        if let channel {
            let trimmed = channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !trimmed.isEmpty { return trimmed }
        }

        let parts = key.split(separator: ":").map(String.init)
        if parts.count > 2 {
            let candidate = parts[2].lowercased()
            if Self.knownChannels.contains(candidate) { return candidate }
        }
        if parts.count > 3 {
            let candidate = parts[3].lowercased()
            if Self.knownChannels.contains(candidate) { return candidate }
        }
        return nil
    }

    var channelDisplayLabel: String? {
        switch normalizedChannel {
        case "feishu": return "飞书"
        case "telegram": return "Telegram"
        case "wecom": return "企微"
        case "discord": return "Discord"
        case "slack": return "Slack"
        case "webchat": return "网页聊天"
        case "whatsapp": return "WhatsApp"
        case let value?: return value.capitalized
        case nil: return nil
        }
    }

    var platformIcon: String {
        switch normalizedChatType {
        case "direct": return "message"
        case "group": return "person.3"
        case "cron": return "clock"
        case "channel": return "megaphone"
        default: return "bubble.left.and.bubble.right"
        }
    }

    var totalTokens: Int { (inputTokens ?? 0) + (outputTokens ?? 0) }

    var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }
}
