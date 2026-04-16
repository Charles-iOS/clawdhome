// 简化自 openclaw/apps/macos/Sources/OpenClaw/CronModels.swift

import Foundation

// MARK: - GatewayCronSchedule

enum GatewayCronSchedule: Codable, Equatable {
    case at(at: String)
    case every(everyMs: Int, anchorMs: Int?)
    case cron(expr: String, tz: String?)

    enum CodingKeys: String, CodingKey {
        case kind, at, atMs, everyMs, anchorMs, expr, tz
    }

    var kind: String {
        switch self {
        case .at: "at"
        case .every: "every"
        case .cron: "cron"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case "at":
            if let at = try container.decodeIfPresent(String.self, forKey: .at),
               !at.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                self = .at(at: at)
                return
            }
            if let atMs = try container.decodeIfPresent(Int.self, forKey: .atMs) {
                let date = Date(timeIntervalSince1970: TimeInterval(atMs) / 1000)
                self = .at(at: Self.formatIsoDate(date))
                return
            }
            throw DecodingError.dataCorruptedError(
                forKey: .at,
                in: container,
                debugDescription: "Missing schedule.at")
        case "every":
            self = try .every(
                everyMs: container.decode(Int.self, forKey: .everyMs),
                anchorMs: container.decodeIfPresent(Int.self, forKey: .anchorMs))
        case "cron":
            self = try .cron(
                expr: container.decode(String.self, forKey: .expr),
                tz: container.decodeIfPresent(String.self, forKey: .tz))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown schedule kind: \(kind)")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self {
        case let .at(at):
            try container.encode(at, forKey: .at)
        case let .every(everyMs, anchorMs):
            try container.encode(everyMs, forKey: .everyMs)
            try container.encodeIfPresent(anchorMs, forKey: .anchorMs)
        case let .cron(expr, tz):
            try container.encode(expr, forKey: .expr)
            try container.encodeIfPresent(tz, forKey: .tz)
        }
    }

    static func parseAtDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let date = makeIsoFormatter(withFractional: true).date(from: trimmed) { return date }
        return makeIsoFormatter(withFractional: false).date(from: trimmed)
    }

    static func formatIsoDate(_ date: Date) -> String {
        makeIsoFormatter(withFractional: false).string(from: date)
    }

    private static func makeIsoFormatter(withFractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = withFractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    // MARK: 序列化为 RPC 参数字典

    func toDict() -> [String: Any] {
        switch self {
        case let .at(at):
            return ["kind": "at", "at": at]
        case let .every(everyMs, anchorMs):
            var dict: [String: Any] = ["kind": "every", "everyMs": everyMs]
            if let anchorMs { dict["anchorMs"] = anchorMs }
            return dict
        case let .cron(expr, tz):
            var dict: [String: Any] = ["kind": "cron", "expr": expr]
            if let tz { dict["tz"] = tz }
            return dict
        }
    }
}

// MARK: - GatewayCronPayload

enum GatewayCronPayload: Codable, Equatable {
    case systemEvent(text: String)
    case agentTurn(
        message: String,
        model: String?,
        thinking: String?,
        timeoutSeconds: Int?,
        lightContext: Bool?,
        tools: [String]?)

    enum CodingKeys: String, CodingKey {
        case kind, text, message, model, thinking, timeoutSeconds, lightContext, tools
    }

    var kind: String {
        switch self {
        case .systemEvent: "systemEvent"
        case .agentTurn: "agentTurn"
        }
    }

    init(from decoder: Decoder) throws {
        self = try GatewayCronDecodedPayload(from: decoder).payload
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self {
        case let .systemEvent(text):
            try container.encode(text, forKey: .text)
        case let .agentTurn(message, model, thinking, timeoutSeconds, lightContext, tools):
            try container.encode(message, forKey: .message)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(thinking, forKey: .thinking)
            try container.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
            try container.encodeIfPresent(lightContext, forKey: .lightContext)
            try container.encodeIfPresent(tools, forKey: .tools)
        }
    }

    var primaryText: String {
        switch self {
        case let .systemEvent(text):
            return text
        case let .agentTurn(message, _, _, _, _, _):
            return message
        }
    }

    var isAgentTurn: Bool {
        if case .agentTurn = self { return true }
        return false
    }

    // MARK: 序列化为 RPC 参数字典

    func toDict() -> [String: Any] {
        switch self {
        case let .systemEvent(text):
            return ["kind": "systemEvent", "text": text]
        case let .agentTurn(message, model, thinking, timeoutSeconds, lightContext, tools):
            var dict: [String: Any] = ["kind": "agentTurn", "message": message]
            if let model { dict["model"] = model }
            if let thinking { dict["thinking"] = thinking }
            if let timeoutSeconds { dict["timeoutSeconds"] = timeoutSeconds }
            if let lightContext { dict["lightContext"] = lightContext }
            if let tools, !tools.isEmpty { dict["tools"] = tools }
            return dict
        }
    }

    fileprivate static func decodeTools<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K
    ) throws -> [String]? {
        if let items = try container.decodeIfPresent([String].self, forKey: key) {
            return items.isEmpty ? nil : items
        }
        guard let text = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        let values = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return values.isEmpty ? nil : values
    }
}

private struct GatewayCronLegacyDeliveryFields: Equatable {
    let deliver: Bool?
    let channel: String?
    let to: String?
    let bestEffortDeliver: Bool?
}

private struct GatewayCronDecodedPayload {
    let payload: GatewayCronPayload
    let legacyDelivery: GatewayCronLegacyDeliveryFields?

    private enum CodingKeys: String, CodingKey {
        case kind, text, message, model, thinking, timeoutSeconds, lightContext, tools
        case deliver, channel, provider, to, bestEffortDeliver
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)

        let legacyDeliver = try container.decodeIfPresent(Bool.self, forKey: .deliver)
        let legacyChannel = try container.decodeIfPresent(String.self, forKey: .channel)
            ?? container.decodeIfPresent(String.self, forKey: .provider)
        let legacyTo = try container.decodeIfPresent(String.self, forKey: .to)
        let legacyBestEffortDeliver = try container.decodeIfPresent(Bool.self, forKey: .bestEffortDeliver)

        switch kind {
        case "systemEvent":
            payload = try .systemEvent(text: container.decode(String.self, forKey: .text))
        case "agentTurn":
            payload = try .agentTurn(
                message: container.decode(String.self, forKey: .message),
                model: container.decodeIfPresent(String.self, forKey: .model),
                thinking: container.decodeIfPresent(String.self, forKey: .thinking),
                timeoutSeconds: container.decodeIfPresent(Int.self, forKey: .timeoutSeconds),
                lightContext: container.decodeIfPresent(Bool.self, forKey: .lightContext),
                tools: GatewayCronPayload.decodeTools(from: container, forKey: .tools))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Unknown payload kind: \(kind)")
        }

        if legacyDeliver != nil || legacyChannel != nil || legacyTo != nil || legacyBestEffortDeliver != nil {
            legacyDelivery = GatewayCronLegacyDeliveryFields(
                deliver: legacyDeliver,
                channel: legacyChannel,
                to: legacyTo,
                bestEffortDeliver: legacyBestEffortDeliver
            )
        } else {
            legacyDelivery = nil
        }
    }
}

// MARK: - GatewayCronDelivery

struct GatewayCronFailureDestination: Codable, Equatable {
    let mode: String?
    let channel: String?
    let to: String?
    let accountId: String?

    fileprivate func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let mode = Self.normalizeValue(self.mode) { dict["mode"] = mode }
        if let channel = Self.normalizeValue(self.channel) { dict["channel"] = channel }
        if let to = Self.normalizeValue(self.to) { dict["to"] = to }
        if let accountId = Self.normalizeValue(self.accountId) { dict["accountId"] = accountId }
        return dict
    }

    private static func normalizeValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct GatewayCronDelivery: Codable, Equatable {
    let mode: String?
    let channel: String?
    let to: String?
    let accountId: String?
    let failureDestination: GatewayCronFailureDestination?

    fileprivate func toDict() -> [String: Any] {
        var dict: [String: Any] = [:]
        if let mode = Self.normalizeValue(self.mode) { dict["mode"] = mode }
        if let channel = Self.normalizeValue(self.channel) { dict["channel"] = channel }
        if let to = Self.normalizeValue(self.to) { dict["to"] = to }
        if let accountId = Self.normalizeValue(self.accountId) { dict["accountId"] = accountId }
        if let failureDestination {
            let nested = failureDestination.toDict()
            if !nested.isEmpty {
                dict["failureDestination"] = nested
            }
        }
        return dict
    }

    fileprivate static func fromLegacy(
        _ legacy: GatewayCronLegacyDeliveryFields?,
        payload: GatewayCronPayload
    ) -> GatewayCronDelivery? {
        guard let legacy else { return nil }

        let normalizedChannel = normalizeValue(legacy.channel)
        let normalizedTo = normalizeValue(legacy.to)

        let mode: String?
        if legacy.deliver == false {
            mode = "none"
        } else if normalizedChannel != nil || normalizedTo != nil {
            mode = "announce"
        } else if legacy.deliver == true, payload.isAgentTurn {
            mode = "announce"
        } else {
            mode = nil
        }

        guard mode != nil || normalizedChannel != nil || normalizedTo != nil else { return nil }

        return GatewayCronDelivery(
            mode: mode,
            channel: normalizedChannel,
            to: normalizedTo,
            accountId: nil,
            failureDestination: nil
        )
    }

    private static func normalizeValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - GatewayCronJobState

struct GatewayCronJobState: Codable, Equatable {
    var nextRunAtMs: Int? = nil
    var runningAtMs: Int? = nil
    var lastRunAtMs: Int? = nil
    var lastStatus: String? = nil
    var lastError: String? = nil
    var lastDurationMs: Int? = nil
}

// MARK: - GatewayCronJob

struct GatewayCronJob: Identifiable, Codable, Equatable {
    let id: String
    var name: String
    var description: String?
    var enabled: Bool
    var deleteAfterRun: Bool?
    let createdAtMs: Int
    let updatedAtMs: Int
    let schedule: GatewayCronSchedule
    /// 对应 CLI 的 `--agent <id>`；未设置时使用默认智能体
    let agentId: String?
    /// "main" / "isolated" / "current" 或 "session:<id>"
    let sessionTarget: String
    /// "now" / "next-heartbeat"
    let wakeMode: String
    let payload: GatewayCronPayload
    let delivery: GatewayCronDelivery?
    let state: GatewayCronJobState

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case enabled
        case deleteAfterRun
        case createdAtMs
        case updatedAtMs
        case schedule
        case agentId
        case sessionTarget
        case wakeMode
        case payload
        case delivery
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        deleteAfterRun = try container.decodeIfPresent(Bool.self, forKey: .deleteAfterRun)
        createdAtMs = try container.decode(Int.self, forKey: .createdAtMs)
        updatedAtMs = try container.decode(Int.self, forKey: .updatedAtMs)
        schedule = try container.decode(GatewayCronSchedule.self, forKey: .schedule)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        sessionTarget = try container.decode(String.self, forKey: .sessionTarget)
        wakeMode = try container.decode(String.self, forKey: .wakeMode)

        let decodedPayload = try GatewayCronDecodedPayload(from: container.superDecoder(forKey: .payload))
        payload = decodedPayload.payload
        delivery = try container.decodeIfPresent(GatewayCronDelivery.self, forKey: .delivery)
            ?? GatewayCronDelivery.fromLegacy(decodedPayload.legacyDelivery, payload: payload)
        state = try container.decodeIfPresent(GatewayCronJobState.self, forKey: .state) ?? GatewayCronJobState()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(description, forKey: .description)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(deleteAfterRun, forKey: .deleteAfterRun)
        try container.encode(createdAtMs, forKey: .createdAtMs)
        try container.encode(updatedAtMs, forKey: .updatedAtMs)
        try container.encode(schedule, forKey: .schedule)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encode(sessionTarget, forKey: .sessionTarget)
        try container.encode(wakeMode, forKey: .wakeMode)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(delivery, forKey: .delivery)
        try container.encode(state, forKey: .state)
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled job" : trimmed
    }

    var nextRunDate: Date? {
        guard let ms = state.nextRunAtMs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }

    var lastRunDate: Date? {
        guard let ms = state.lastRunAtMs else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
    }
}

// MARK: - GatewayCronRunLogEntry

struct GatewayCronRunLogEntry: Codable, Identifiable {
    var id: String { "\(ts)-\(jobId)-\(action)" }

    let ts: Int
    let jobId: String
    let action: String
    let status: String?
    let error: String?
    let summary: String?
    let durationMs: Int?

    var date: Date {
        Date(timeIntervalSince1970: TimeInterval(ts) / 1000)
    }
}

// MARK: - GatewayCronAddParams

/// 创建 Cron 任务的 RPC 参数，通过 toDict() 序列化后传入 JSON-RPC 请求
struct GatewayCronAddParams {
    let name: String
    let description: String?
    let enabled: Bool?
    let deleteAfterRun: Bool?
    let schedule: GatewayCronSchedule
    /// 对应 CLI 的 `--agent <id>`
    let agentId: String?
    /// "main" / "isolated" / "current" 或 "session:<id>"
    let sessionTarget: String
    /// "now" / "next-heartbeat"
    let wakeMode: String
    let payload: GatewayCronPayload
    let delivery: GatewayCronDelivery?

    func toDict() -> [String: Any] {
        var dict: [String: Any] = [
            "name": name,
            "schedule": schedule.toDict(),
            "sessionTarget": sessionTarget,
            "wakeMode": wakeMode,
            "payload": payload.toDict(),
        ]
        if let agentId { dict["agentId"] = agentId }
        if let description { dict["description"] = description }
        if let enabled { dict["enabled"] = enabled }
        if let deleteAfterRun { dict["deleteAfterRun"] = deleteAfterRun }
        if let delivery {
            let deliveryDict = delivery.toDict()
            if !deliveryDict.isEmpty {
                dict["delivery"] = deliveryDict
            }
        }
        return dict
    }
}
