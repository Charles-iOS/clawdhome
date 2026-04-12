// ClawdHome/Models/AgentBinding.swift
// 渠道绑定模型 — 对应 openclaw.json 中 bindings[] 条目
// 描述入站消息如何路由到某个智能体

import Foundation

struct AgentBinding: Codable, Identifiable, Equatable {

    var agentId: String               // 目标智能体 ID
    var channel: String               // 渠道类型："whatsapp", "telegram", "discord", etc.
    var accountId: String?            // 渠道账号 ID（nil 表示默认账号）
    var peerId: String?               // 精确匹配的 peer ID（私信/群组）
    var peerKind: String?             // peer 类型："direct", "group" 等
    var guildId: String?              // Discord guild ID
    var teamId: String?               // Slack team ID

    // MARK: - Identifiable

    var id: String {
        "\(agentId):\(channel):\(accountId ?? "*"):\(peerId ?? "*")"
    }

    // MARK: - ChannelType 桥接

    /// 匹配 ChannelType 枚举（weixin/feishu/telegram/discord）；其它 channel 字符串仍为合法绑定
    var channelType: ChannelType? {
        ChannelType(rawValue: channel)
    }

    // MARK: - 显示辅助

    /// 渠道图标（优先使用 ChannelType 元数据）
    var channelIcon: String {
        if let ct = channelType { return ct.iconName }
        switch channel.lowercased() {
        case "dingtalk":  return "bolt.circle.fill"
        case "whatsapp":  return "message.fill"
        case "telegram":  return "paperplane.fill"
        case "discord":   return "bubble.left.and.bubble.right.fill"
        case "slack":     return "number"
        case "imessage":  return "message.circle.fill"
        case "signal":    return "lock.shield.fill"
        default:          return "antenna.radiowaves.left.and.right"
        }
    }

    /// 简短描述
    var summary: String {
        var parts = [channel]
        if let acc = accountId { parts.append(acc) }
        if let peer = peerId {
            let kind = peerKind ?? "peer"
            parts.append("\(kind):\(peer)")
        }
        if let guild = guildId { parts.append("guild:\(guild)") }
        if let team = teamId { parts.append("team:\(team)") }
        return parts.joined(separator: " / ")
    }

    // MARK: - Codable（match 嵌套结构）
    // OpenClaw 配置中 binding 格式为：
    // { agentId, match: { channel, accountId?, peer?: { kind, id }, guildId?, teamId? } }

    enum CodingKeys: String, CodingKey {
        case agentId, match
    }

    enum MatchKeys: String, CodingKey {
        case channel, accountId, peer, guildId, teamId
    }

    enum PeerKeys: String, CodingKey {
        case kind, id
    }

    init(
        agentId: String,
        channel: String,
        accountId: String? = nil,
        peerId: String? = nil,
        peerKind: String? = nil,
        guildId: String? = nil,
        teamId: String? = nil
    ) {
        self.agentId = agentId
        self.channel = channel
        self.accountId = accountId
        self.peerId = peerId
        self.peerKind = peerKind
        self.guildId = guildId
        self.teamId = teamId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        agentId = try container.decode(String.self, forKey: .agentId)
        let match = try container.nestedContainer(keyedBy: MatchKeys.self, forKey: .match)
        channel = try match.decode(String.self, forKey: .channel)
        accountId = try match.decodeIfPresent(String.self, forKey: .accountId)
        guildId = try match.decodeIfPresent(String.self, forKey: .guildId)
        teamId = try match.decodeIfPresent(String.self, forKey: .teamId)
        if let peer = try? match.nestedContainer(keyedBy: PeerKeys.self, forKey: .peer) {
            peerKind = try peer.decodeIfPresent(String.self, forKey: .kind)
            peerId = try peer.decodeIfPresent(String.self, forKey: .id)
        } else {
            peerKind = nil
            peerId = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(agentId, forKey: .agentId)
        var match = container.nestedContainer(keyedBy: MatchKeys.self, forKey: .match)
        try match.encode(channel, forKey: .channel)
        try match.encodeIfPresent(accountId, forKey: .accountId)
        try match.encodeIfPresent(guildId, forKey: .guildId)
        try match.encodeIfPresent(teamId, forKey: .teamId)
        if peerId != nil || peerKind != nil {
            var peer = match.nestedContainer(keyedBy: PeerKeys.self, forKey: .peer)
            try peer.encodeIfPresent(peerKind, forKey: .kind)
            try peer.encodeIfPresent(peerId, forKey: .id)
        }
    }

    /// 转为配置 patch 使用的字典
    func toPatchDict() -> [String: Any] {
        var matchDict: [String: Any] = ["channel": channel]
        if let acc = accountId { matchDict["accountId"] = acc }
        if let guild = guildId { matchDict["guildId"] = guild }
        if let team = teamId { matchDict["teamId"] = team }
        if peerId != nil || peerKind != nil {
            var peer: [String: Any] = [:]
            if let kind = peerKind { peer["kind"] = kind }
            if let id = peerId { peer["id"] = id }
            matchDict["peer"] = peer
        }
        return ["agentId": agentId, "match": matchDict]
    }
}
