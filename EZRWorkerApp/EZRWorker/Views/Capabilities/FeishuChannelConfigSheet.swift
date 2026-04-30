import Foundation
import SwiftUI

enum ChannelDmPolicy: String, CaseIterable, Identifiable {
    case open
    case pairing
    case allowlist
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "开放"
        case .pairing: return "配对审批"
        case .allowlist: return "仅白名单"
        case .disabled: return "禁用私信"
        }
    }

    var description: String {
        switch self {
        case .open:
            return "任何私信都可直接触发机器人。"
        case .pairing:
            return "陌生私信先进入配对审批，通过后才能继续对话。"
        case .allowlist:
            return "只有已配对 / 已加入 allow-from store 的用户可私信机器人。"
        case .disabled:
            return "关闭飞书私信入口。"
        }
    }
}

enum ChannelGroupPolicy: String, CaseIterable, Identifiable {
    case open
    case allowlist
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return "开放"
        case .allowlist: return "仅白名单"
        case .disabled: return "禁用群聊"
        }
    }

    var description: String {
        switch self {
        case .open:
            return "允许群聊接入，具体是否放行由 mention 和发送者策略共同决定。"
        case .allowlist:
            return "只有 `groups` 里声明的群可接入。"
        case .disabled:
            return "关闭群聊入口。"
        }
    }
}

enum ChannelCredentialMode {
    case qrCode
    case manual
    case unknown

    var title: String {
        switch self {
        case .qrCode: return "已通过扫码绑定"
        case .manual: return "已通过手动凭据配置"
        case .unknown: return "已配置飞书渠道"
        }
    }

    var detail: String {
        switch self {
        case .qrCode:
            return "当前 App Secret 来自本地 `lark.secrets.json` 文件 provider。"
        case .manual:
            return "当前直接在渠道配置中保存了 App ID / App Secret。"
        case .unknown:
            return "当前已检测到飞书配置，但无法判断来源模式。"
        }
    }

    var manualActionTitle: String {
        switch self {
        case .qrCode: return "改用手动凭据"
        case .manual, .unknown: return "编辑手动凭据"
        }
    }
}

struct FeishuChannelConfigDraft {
    var isEnabled = true
    var dmPolicy: ChannelDmPolicy = .pairing
    var groupPolicy: ChannelGroupPolicy = .allowlist
    var requireMention = true
    var groupAllowFromText = ""
    var groupsJSONText = "{}"
    var credentialMode: ChannelCredentialMode = .unknown
    var isReadOnly = false
    var validationError: String?
}

private struct ChannelConfigValidationError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

enum ChannelPairingDataLoader {
    static func pendingRequests(
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) -> [PairingRequest] {
        guard let localPaths else {
            return []
        }
        let pairingFile = localPaths.credentialFileCandidates(named: "\(channel.rawValue)-pairing.json")
            .first(where: { FileManager.default.fileExists(atPath: $0.path) })
        guard let pairingFile,
              let data = FileManager.default.contents(atPath: pairingFile.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRequests = json["requests"] as? [[String: Any]] else {
            return []
        }

        return rawRequests.compactMap { raw in
            guard let code = raw["code"] as? String, !code.isEmpty else { return nil }

            if channel == .feishu {
                let meta = raw["meta"] as? [String: Any] ?? [:]
                let accountId = normalizeAccountID(meta["accountId"])
                guard accountId == defaultFeishuAccountID else { return nil }

                let userId = (raw["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !userId.isEmpty else { return nil }

                return PairingRequest(
                    code: code,
                    userId: userId,
                    displayName: firstNonEmptyString(
                        meta["displayName"],
                        meta["name"],
                        meta["senderName"],
                        raw["displayName"]
                    ),
                    requestedAt: firstNonEmptyString(raw["createdAt"], raw["requestedAt"])
                )
            }

            let userId = (raw["userId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !userId.isEmpty else { return nil }

            return PairingRequest(
                code: code,
                userId: userId,
                displayName: firstNonEmptyString(raw["displayName"]),
                requestedAt: firstNonEmptyString(raw["requestedAt"], raw["createdAt"])
            )
        }
    }

    static func approvedPeers(
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) -> [PairingPeer] {
        guard let localPaths else { return [] }
        var peersByID: [String: PairingPeer] = [:]

        for credentialsDirectory in localPaths.credentialsDirectoryCandidates {
            let storePeers: [PairingPeer]
            if channel == .feishu {
                storePeers = loadFeishuApprovedPeers(credentialsDirectory: credentialsDirectory)
            } else {
                storePeers = loadStoreApprovedPeers(for: channel, credentialsDirectory: credentialsDirectory)
            }

            for peer in storePeers {
                merge(peer, into: &peersByID)
            }
        }

        for peerId in ChannelConfigSupport.allowFromPeerIDs(for: channel, localPaths: localPaths) {
            merge(
                PairingPeer(
                    id: peerId,
                    kind: "direct",
                    sources: [.configAllowFrom]
                ),
                into: &peersByID
            )
        }

        return peersByID.values.sorted { $0.id < $1.id }
    }

    static func approvedPeerIDs(
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) -> [String] {
        approvedPeers(for: channel, localPaths: localPaths).map(\.id)
    }

    static func storeAllowFromPeerIDs(
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) -> [String] {
        guard let localPaths else { return [] }
        var peersByID: [String: PairingPeer] = [:]

        for credentialsDirectory in localPaths.credentialsDirectoryCandidates {
            let storePeers = channel == .feishu
                ? loadFeishuApprovedPeers(credentialsDirectory: credentialsDirectory)
                : loadStoreApprovedPeers(for: channel, credentialsDirectory: credentialsDirectory)

            for peer in storePeers {
                merge(peer, into: &peersByID)
            }
        }

        return peersByID.values.map(\.id).sorted()
    }

    private static let defaultFeishuAccountID = "default"

    private static func loadStoreApprovedPeers(
        for channel: ChannelType,
        credentialsDirectory: URL
    ) -> [PairingPeer] {
        let prefix = "\(channel.rawValue)-"
        let suffix = "-allowFrom.json"
        var peersByID: [String: PairingPeer] = [:]

        if let entries = try? FileManager.default.contentsOfDirectory(atPath: credentialsDirectory.path) {
            for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
                let filePath = credentialsDirectory.appendingPathComponent(entry)
                for peerId in normalizeStringList(fromAllowFromFile: filePath) {
                    merge(
                        PairingPeer(
                            id: peerId,
                            sources: [.storeAllowFrom]
                        ),
                        into: &peersByID
                    )
                }
            }
        }

        return peersByID.values.sorted { $0.id < $1.id }
    }

    private static func loadFeishuApprovedPeers(credentialsDirectory: URL) -> [PairingPeer] {
        let scopedFile = credentialsDirectory.appendingPathComponent("feishu-\(defaultFeishuAccountID)-allowFrom.json")
        let legacyFile = credentialsDirectory.appendingPathComponent("feishu-allowFrom.json")
        let ids = dedupePreservingOrder(
            normalizeStringList(fromAllowFromFile: scopedFile) + normalizeStringList(fromAllowFromFile: legacyFile)
        )

        return ids.map {
            PairingPeer(
                id: $0,
                kind: "direct",
                sources: [.storeAllowFrom]
            )
        }
    }

    private static func normalizeStringList(fromAllowFromFile fileURL: URL) -> [String] {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return normalizeStringList(fromAny: json["allowFrom"])
    }

    private static func normalizeStringList(fromAny rawValue: Any?) -> [String] {
        switch rawValue {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        case let items as [Any]:
            return dedupePreservingOrder(
                items
                    .map { String(describing: $0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && $0 != "*" }
            )
        default:
            return []
        }
    }

    private static func dedupePreservingOrder(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items {
            let key = item.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(item)
        }
        return result
    }

    private static func merge(_ peer: PairingPeer, into peersByID: inout [String: PairingPeer]) {
        let key = peer.id.lowercased()
        if var existing = peersByID[key] {
            existing.sources = dedupeSources(existing.sources + peer.sources)
            if existing.kind == nil {
                existing.kind = peer.kind
            }
            if existing.displayName == nil {
                existing.displayName = peer.displayName
            }
            if existing.pairedAt == nil {
                existing.pairedAt = peer.pairedAt
            }
            peersByID[key] = existing
        } else {
            peersByID[key] = peer
        }
    }

    private static func dedupeSources(_ sources: [PairingPeerSource]) -> [PairingPeerSource] {
        var seen = Set<PairingPeerSource>()
        var result: [PairingPeerSource] = []
        for source in sources where seen.insert(source).inserted {
            result.append(source)
        }
        return result
    }

    private static func normalizeAccountID(_ rawValue: Any?) -> String {
        let trimmed = String(describing: rawValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return trimmed.isEmpty ? defaultFeishuAccountID : trimmed
    }

    private static func firstNonEmptyString(_ values: Any?...) -> String? {
        for value in values {
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }
}

enum ChannelConfigSupport {
    static func loadLocalChannelConfig(
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) -> [String: Any] {
        let rootConfig = loadLocalConfigRoot(localPaths: localPaths)
        let channels = rootConfig["channels"] as? [String: Any] ?? [:]
        return channels[channel.rawValue] as? [String: Any] ?? [:]
    }

    static func resolvedChannelConfig(
        for channel: ChannelType,
        from channelConfig: [String: Any]
    ) -> [String: Any] {
        guard channel == .feishu,
              let accountConfig = defaultAccountConfig(in: channelConfig)
        else {
            return channelConfig
        }

        var mergedConfig = channelConfig
        for (key, value) in accountConfig {
            mergedConfig[key] = value
        }
        return mergedConfig
    }

    static func defaultAccountID(in channelConfig: [String: Any]) -> String {
        if let configured = normalizedString(channelConfig["defaultAccount"]) {
            return configured
        }

        guard let accounts = channelConfig["accounts"] as? [String: Any],
              !accounts.isEmpty
        else {
            return "default"
        }

        if accounts["default"] != nil {
            return "default"
        }

        if accounts.count == 1, let onlyAccountID = accounts.keys.first {
            return onlyAccountID
        }

        return accounts.keys.sorted().first ?? "default"
    }

    static func usesDefaultAccountLayout(
        for channel: ChannelType,
        in channelConfig: [String: Any]
    ) -> Bool {
        guard channel == .feishu else { return false }
        if let accounts = channelConfig["accounts"] as? [String: Any], !accounts.isEmpty {
            return true
        }
        return normalizedString(channelConfig["defaultAccount"]) != nil
    }

    static func credentialWritePatch(
        for channel: ChannelType,
        existingChannelConfig: [String: Any],
        credentials: [String: Any]
    ) -> [String: Any] {
        guard usesDefaultAccountLayout(for: channel, in: existingChannelConfig) else {
            return credentials
        }

        let accountID = defaultAccountID(in: existingChannelConfig)
        return [
            "defaultAccount": accountID,
            "accounts": [
                accountID: credentials
            ]
        ]
    }

    static func allowFromPeerIDs(
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) -> [String] {
        let channelConfig = loadLocalChannelConfig(for: channel, localPaths: localPaths)
        let resolvedConfig = resolvedChannelConfig(for: channel, from: channelConfig)
        return normalizeStringArray(from: resolvedConfig["allowFrom"])
    }

    @discardableResult
    static func removeAllowFromPeerFromLocalConfig(
        _ peerID: String,
        for channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) throws -> Bool {
        guard let localPaths else {
            throw ChannelConfigValidationError(message: "当前未选择 profile，无法更新本地渠道配置。")
        }

        var rootConfig = loadLocalConfigRoot(localPaths: localPaths)
        var channels = rootConfig["channels"] as? [String: Any] ?? [:]
        var channelConfig = channels[channel.rawValue] as? [String: Any] ?? [:]
        let currentAllowFrom = normalizeStringArray(from: channelConfig["allowFrom"], allowWildcard: true)
        let updatedAllowFrom = currentAllowFrom.filter {
            $0.caseInsensitiveCompare(peerID) != .orderedSame
        }

        guard updatedAllowFrom.count != currentAllowFrom.count else {
            return false
        }

        if updatedAllowFrom.isEmpty {
            channelConfig.removeValue(forKey: "allowFrom")
        } else {
            channelConfig["allowFrom"] = updatedAllowFrom
        }
        channels[channel.rawValue] = channelConfig
        rootConfig["channels"] = channels

        let configURL = localPaths.preferredConfigWriteURL
        guard JSONSerialization.isValidJSONObject(rootConfig) else {
            throw ChannelConfigValidationError(message: "本地 OpenClaw 配置不是合法 JSON，无法更新私信白名单。")
        }
        let data = try JSONSerialization.data(withJSONObject: rootConfig, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL, options: .atomic)
        return true
    }

    static func normalizeStringArray(from rawValue: Any?, allowWildcard: Bool = false) -> [String] {
        switch rawValue {
        case let value as String:
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            if trimmed == "*", !allowWildcard {
                return []
            }
            return [trimmed]
        case let values as [Any]:
            var seen = Set<String>()
            var result: [String] = []
            for value in values {
                let trimmed = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                guard allowWildcard || trimmed != "*" else { continue }
                let key = trimmed.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                result.append(trimmed)
            }
            return result
        default:
            return []
        }
    }

    static func normalizeLineSeparatedIDs(_ text: String, allowWildcard: Bool = false) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard allowWildcard || trimmed != "*" else { continue }
            let key = trimmed.lowercased()
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(trimmed)
        }
        return result
    }

    static func lineSeparatedText(from ids: [String]) -> String {
        ids.joined(separator: "\n")
    }

    static func prettyPrintedJSONText(from object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    static func parseObjectJSON(from text: String, fieldName: String) -> Result<[String: Any], Error> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(ChannelConfigValidationError(message: "`\(fieldName)` 需要是一个 JSON 对象，空文本无效。"))
        }
        guard let data = trimmed.data(using: .utf8) else {
            return .failure(ChannelConfigValidationError(message: "`\(fieldName)` JSON 编码失败。"))
        }

        do {
            let object = try JSONSerialization.jsonObject(with: data)
            guard let dict = object as? [String: Any] else {
                return .failure(ChannelConfigValidationError(message: "`\(fieldName)` 只能保存为 JSON 对象。"))
            }
            return .success(dict)
        } catch {
            return .failure(ChannelConfigValidationError(message: "`\(fieldName)` JSON 语法错误：\(error.localizedDescription)"))
        }
    }

    private static func loadLocalConfigRoot(localPaths: GatewayProfileLocalPaths?) -> [String: Any] {
        localPaths?.loadConfigRoot() ?? [:]
    }

    private static func defaultAccountConfig(in channelConfig: [String: Any]) -> [String: Any]? {
        guard let accounts = channelConfig["accounts"] as? [String: Any],
              !accounts.isEmpty
        else {
            return nil
        }

        let accountID = defaultAccountID(in: channelConfig)
        if let accountConfig = accounts[accountID] as? [String: Any] {
            return accountConfig
        }
        if let defaultConfig = accounts["default"] as? [String: Any] {
            return defaultConfig
        }
        if accounts.count == 1, let onlyConfig = accounts.values.first as? [String: Any] {
            return onlyConfig
        }
        return nil
    }

    private static func normalizedString(_ rawValue: Any?) -> String? {
        guard let string = rawValue as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

@MainActor
enum ChannelPairingMutationSupport {
    @discardableResult
    static func rejectPendingRequest(
        code: String,
        channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) throws -> Bool {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else { return false }
        guard let localPaths else {
            throw ChannelConfigValidationError(message: "当前未选择 profile，无法修改本地配对请求。")
        }

        var removedAny = false
        for fileURL in localPaths.credentialFileCandidates(named: "\(channel.rawValue)-pairing.json")
            where FileManager.default.fileExists(atPath: fileURL.path) {
            removedAny = try removePendingRequest(trimmedCode, fileURL: fileURL) || removedAny
        }
        return removedAny
    }

    static func removeApprovedPeer(
        _ peer: PairingPeer,
        channel: ChannelType,
        gateway: GatewayService,
        localPaths: GatewayProfileLocalPaths?
    ) async throws -> Bool {
        var removedAny = false
        var errors: [String] = []

        if peer.isStoreBacked {
            do {
                let changed = try removeStoreAllowFromPeer(
                    peer.id,
                    channel: channel,
                    localPaths: localPaths
                )
                removedAny = removedAny || changed
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if peer.isConfigBacked {
            do {
                let changed = try await removeConfigAllowFromPeer(
                    peer.id,
                    channel: channel,
                    gateway: gateway,
                    localPaths: localPaths
                )
                removedAny = removedAny || changed
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        if !errors.isEmpty {
            throw ChannelConfigValidationError(message: errors.joined(separator: "；"))
        }

        return removedAny
    }

    private static func removePendingRequest(
        _ code: String,
        fileURL: URL
    ) throws -> Bool {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let requests = json["requests"] as? [[String: Any]] else {
            return false
        }

        let updatedRequests = requests.filter { request in
            let requestCode = (request["code"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return requestCode != code
        }
        guard updatedRequests.count != requests.count else {
            return false
        }

        json["version"] = json["version"] ?? 1
        json["requests"] = updatedRequests

        guard JSONSerialization.isValidJSONObject(json) else {
            throw ChannelConfigValidationError(message: "配对请求 store 不是合法 JSON，无法更新。")
        }

        let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: fileURL, options: .atomic)
        return true
    }

    private static func removeStoreAllowFromPeer(
        _ peerID: String,
        channel: ChannelType,
        localPaths: GatewayProfileLocalPaths?
    ) throws -> Bool {
        guard let localPaths else {
            throw ChannelConfigValidationError(message: "当前未选择 profile，无法修改本地配对 store。")
        }

        var removedAny = false
        for credentialsDirectory in localPaths.credentialsDirectoryCandidates {
            for fileURL in storeAllowFromFileCandidates(
                channel: channel,
                credentialsDirectory: credentialsDirectory
            ) where FileManager.default.fileExists(atPath: fileURL.path) {
                removedAny = try removePeerFromAllowFromFile(peerID, fileURL: fileURL) || removedAny
            }
        }
        return removedAny
    }

    private static func storeAllowFromFileCandidates(
        channel: ChannelType,
        credentialsDirectory: URL
    ) -> [URL] {
        if channel == .feishu {
            return [
                credentialsDirectory.appendingPathComponent("feishu-default-allowFrom.json"),
                credentialsDirectory.appendingPathComponent("feishu-allowFrom.json"),
            ]
        }

        let prefix = "\(channel.rawValue)-"
        let suffix = "-allowFrom.json"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: credentialsDirectory.path) else {
            return []
        }

        return entries
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }
            .map { credentialsDirectory.appendingPathComponent($0) }
    }

    private static func removePeerFromAllowFromFile(
        _ peerID: String,
        fileURL: URL
    ) throws -> Bool {
        guard let data = FileManager.default.contents(atPath: fileURL.path),
              var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }

        let currentAllowFrom = ChannelConfigSupport.normalizeStringArray(
            from: json["allowFrom"],
            allowWildcard: true
        )
        let updatedAllowFrom = currentAllowFrom.filter {
            $0.caseInsensitiveCompare(peerID) != .orderedSame
        }

        guard updatedAllowFrom.count != currentAllowFrom.count else {
            return false
        }

        json["version"] = json["version"] ?? 1
        json["allowFrom"] = updatedAllowFrom

        guard JSONSerialization.isValidJSONObject(json) else {
            throw ChannelConfigValidationError(message: "配对 store 不是合法 JSON，无法更新。")
        }

        let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: fileURL, options: .atomic)
        return true
    }

    private static func removeConfigAllowFromPeer(
        _ peerID: String,
        channel: ChannelType,
        gateway: GatewayService,
        localPaths: GatewayProfileLocalPaths?
    ) async throws -> Bool {
        if gateway.isConnected {
            do {
                return try await removeConfigAllowFromPeerViaGateway(peerID, channel: channel, gateway: gateway)
            } catch {
                if gateway.isConnected {
                    throw error
                }
            }
        }

        return try ChannelConfigSupport.removeAllowFromPeerFromLocalConfig(
            peerID,
            for: channel,
            localPaths: localPaths
        )
    }

    private static func removeConfigAllowFromPeerViaGateway(
        _ peerID: String,
        channel: ChannelType,
        gateway: GatewayService
    ) async throws -> Bool {
        let (config, baseHash) = try await gateway.configGetFull()
        let channels = config["channels"] as? [String: Any] ?? [:]
        let channelConfig = channels[channel.rawValue] as? [String: Any] ?? [:]
        let resolvedConfig = ChannelConfigSupport.resolvedChannelConfig(
            for: channel,
            from: channelConfig
        )
        let currentAllowFrom = ChannelConfigSupport.normalizeStringArray(
            from: resolvedConfig["allowFrom"],
            allowWildcard: true
        )
        let updatedAllowFrom = currentAllowFrom.filter {
            $0.caseInsensitiveCompare(peerID) != .orderedSame
        }

        guard updatedAllowFrom.count != currentAllowFrom.count else {
            return false
        }

        let allowFromPatchValue: Any = updatedAllowFrom.isEmpty ? NSNull() : updatedAllowFrom
        let channelPatch: [String: Any]
        if ChannelConfigSupport.usesDefaultAccountLayout(for: channel, in: channelConfig) {
            let accountID = ChannelConfigSupport.defaultAccountID(in: channelConfig)
            channelPatch = [
                "defaultAccount": accountID,
                "accounts": [
                    accountID: [
                        "allowFrom": allowFromPatchValue
                    ]
                ]
            ]
        } else {
            channelPatch = [
                "allowFrom": allowFromPatchValue
            ]
        }
        let patch: [String: Any] = [
            "channels": [
                channel.rawValue: channelPatch
            ]
        ]

        _ = try await gateway.configPatch(
            patch: patch,
            baseHash: baseHash,
            note: "移除\(channel.displayName)私信白名单用户 \(peerID)"
        )
        return true
    }
}

private enum FeishuChannelConfigSupport {
    static func hasQRCodeCredentials(localPaths: GatewayProfileLocalPaths?) -> Bool {
        guard let localPaths else {
            return false
        }
        let candidateURLs = [
            localPaths.existingSecretProviderFileURL(providerID: "lark-secrets"),
            localPaths.existingCredentialFile(named: "lark.secrets.json"),
        ].compactMap { $0 }

        for fileURL in candidateURLs {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
                  let fileSize = attrs[.size] as? NSNumber else {
                continue
            }
            if fileSize.intValue > 0 {
                return true
            }
        }
        return false
    }

    static func credentialMode(
        for feishuConfig: [String: Any],
        localPaths: GatewayProfileLocalPaths?
    ) -> ChannelCredentialMode {
        let resolvedConfig = ChannelConfigSupport.resolvedChannelConfig(
            for: .feishu,
            from: feishuConfig
        )
        if let appSecret = resolvedConfig["appSecret"] as? String,
           !appSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .manual
        }
        if isQRCodeSecretReference(resolvedConfig["appSecret"])
            || hasQRCodeCredentials(localPaths: localPaths) {
            return .qrCode
        }
        return .unknown
    }

    private static func isQRCodeSecretReference(_ rawValue: Any?) -> Bool {
        guard let secretRef = rawValue as? [String: Any] else { return false }
        let source = (secretRef["source"] as? String)?.lowercased()
        let provider = (secretRef["provider"] as? String)?.lowercased()
        return source == "file" || provider == "lark-secrets"
    }
}

struct FeishuChannelConfigSheet: View {
    private enum FontSize {
        static let title: CGFloat = 20
        static let subtitle: CGFloat = 14
        static let section: CGFloat = 15
        static let body: CGFloat = 14
        static let meta: CGFloat = 13
        static let action: CGFloat = 15
    }

    let username: String
    var onSaved: (() -> Void)?

    @Environment(GatewayService.self) private var gateway
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @State private var draft = FeishuChannelConfigDraft()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showOnboardingSheet = false
    @State private var showCredentialSheet = false
    @State private var loadedFeishuConfig: [String: Any] = [:]

    private var selectedLocalPaths: GatewayProfileLocalPaths? { profileStore.selectedLocalPaths }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 860, minHeight: 760)
        .task(id: gateway.isConnected) {
            await loadConfig()
        }
        .sheet(isPresented: $showOnboardingSheet) {
            FeishuChannelOnboardingSheet(
                flow: .feishu,
                displayName: "",
                username: username
            )
            .frame(minWidth: 900, minHeight: 560)
            .onDisappear {
                Task { await refreshAfterExternalChange() }
            }
        }
        .sheet(isPresented: $showCredentialSheet) {
            ChannelBotConfigSheet(channelType: .feishu) {
                Task { await refreshAfterExternalChange() }
            }
            .environment(gateway)
        }
        .onReceive(NotificationCenter.default.publisher(for: .channelOnboardingAutoDetected)) { notification in
            guard let userInfo = notification.userInfo,
                  let flow = userInfo["flow"] as? String,
                  flow == ChannelOnboardingFlow.feishu.rawValue,
                  let eventUsername = userInfo["username"] as? String,
                  eventUsername == username else { return }
            Task { await refreshAfterExternalChange() }
        }
        .onChange(of: draft.groupsJSONText) { _, _ in
            validateGroupsJSON()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            ChannelType.feishu.iconView(size: 24, weight: .medium)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("飞书 · 渠道配置")
                    .font(.system(size: FontSize.title, weight: .semibold))
                Text("管理接入状态、群聊策略，以及私信配对审批。")
                    .font(.system(size: FontSize.subtitle))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && successMessage == nil && errorMessage == nil {
            ProgressView("加载配置中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    messageSection
                    accessStatusSection
                    strategySection
                    pairingSection
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private var messageSection: some View {
        if draft.isReadOnly {
            sectionCard {
                Label("当前为离线只读模式，策略可以查看，但保存、重新扫码和手动凭据入口已禁用。", systemImage: "lock.fill")
                    .font(.system(size: FontSize.body, weight: .medium))
                    .foregroundStyle(.orange)
            }
        }

        if let successMessage {
            sectionCard {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: FontSize.body, weight: .medium))
                    .foregroundStyle(.green)
            }
        }

        if let errorMessage {
            sectionCard {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: FontSize.body, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var accessStatusSection: some View {
        sectionBlock(title: "接入状态", systemImage: "link.badge.plus") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    Text(draft.credentialMode.title)
                        .font(.system(size: FontSize.body, weight: .semibold))
                    if draft.isReadOnly {
                        Text("只读")
                            .font(.system(size: FontSize.meta, weight: .medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.12))
                            .foregroundStyle(.orange)
                            .clipShape(Capsule())
                    }
                }
                Text(draft.credentialMode.detail)
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用飞书渠道", isOn: $draft.isEnabled)
                        .disabled(draft.isReadOnly)
                    Text("对应 `channels.feishu.enabled`。关闭后飞书渠道不会启动，但扫码凭据、群配置和配对数据都会保留。")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("重新扫码绑定") {
                        showOnboardingSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(draft.isReadOnly)

                    Button(draft.credentialMode.manualActionTitle) {
                        showCredentialSheet = true
                    }
                    .buttonStyle(.bordered)
                    .disabled(draft.isReadOnly)
                }
            }
        }
    }

    @ViewBuilder
    private var strategySection: some View {
        sectionBlock(title: "渠道策略", systemImage: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                policyPicker(
                    title: "私信策略",
                    description: draft.dmPolicy.description
                ) {
                    Picker("私信策略", selection: $draft.dmPolicy) {
                        ForEach(ChannelDmPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .disabled(draft.isReadOnly)
                }

                policyPicker(
                    title: "群聊策略",
                    description: draft.groupPolicy.description
                ) {
                    Picker("群聊策略", selection: $draft.groupPolicy) {
                        ForEach(ChannelGroupPolicy.allCases) { policy in
                            Text(policy.title).tag(policy)
                        }
                    }
                    .disabled(draft.isReadOnly)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("群消息必须 @ 机器人", isOn: $draft.requireMention)
                        .disabled(draft.isReadOnly)
                    Text("对应 `channels.feishu.requireMention`，只影响群聊入口。")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("群内发送者白名单 (`groupAllowFrom`)")
                        .font(.system(size: FontSize.body, weight: .semibold))
                    Text("一行一个发送者 `open_id`（如 `ou_xxx`）。这里不要放群 `chat_id (oc_xxx)`；群 ID 请写进下面的 `groups` 高级 JSON。")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                    editor(text: $draft.groupAllowFromText, minHeight: 96, isReadOnly: draft.isReadOnly)
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("`groups` 高级 JSON")
                            .font(.system(size: FontSize.body, weight: .semibold))
                        Spacer()
                        Button("格式化 JSON") {
                            formatGroupsJSON()
                        }
                        .buttonStyle(.borderless)
                        .disabled(draft.isReadOnly || draft.validationError != nil)
                    }
                    Text("根节点必须是对象。可写 `\"*\"` 默认项，也可写逐群 override，例如 `\"oc_xxx\": { \"enabled\": true }`。")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                    editor(
                        text: $draft.groupsJSONText,
                        minHeight: 180,
                        isReadOnly: draft.isReadOnly,
                        monospaced: true
                    )
                    if let validationError = draft.validationError {
                        Text(validationError)
                            .font(.system(size: FontSize.meta))
                            .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pairingSection: some View {
        sectionBlock(title: "配对管理", systemImage: "person.badge.key.fill") {
            ChannelPairingManagerSection(
                channelType: .feishu,
                policyNotice: pairingNoticeText,
                onChanged: {
                    await loadConfig()
                    onSaved?()
                }
            )
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            Spacer()

            Button("关闭") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button(isSaving ? "保存中…" : "保存") {
                Task { await save() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isSaveDisabled)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var pairingNoticeText: String? {
        guard draft.dmPolicy != .pairing else { return nil }
        return "当前私信策略为“\(draft.dmPolicy.title)”，不会再自动产生新的待审批请求；已有配对数据仍可查看和移除。"
    }

    private var isSaveDisabled: Bool {
        draft.isReadOnly || isSaving || isLoading || draft.validationError != nil
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func sectionBlock<Content: View>(title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: FontSize.section, weight: .semibold))
                .foregroundStyle(.secondary)
            sectionCard {
                content()
            }
        }
    }

    @ViewBuilder
    private func policyPicker<PickerContent: View>(
        title: String,
        description: String,
        @ViewBuilder picker: () -> PickerContent
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: FontSize.body, weight: .semibold))
            picker()
            Text(description)
                .font(.system(size: FontSize.meta))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func editor(
        text: Binding<String>,
        minHeight: CGFloat,
        isReadOnly: Bool,
        monospaced: Bool = false
    ) -> some View {
        TextEditor(text: text)
            .font(monospaced ? .system(size: 13, design: .monospaced) : .system(size: 14))
            .frame(minHeight: minHeight)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .disabled(isReadOnly)
    }

    private func loadConfig() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        let localConfig = ChannelConfigSupport.loadLocalChannelConfig(
            for: .feishu,
            localPaths: selectedLocalPaths
        )
        var feishuConfig = localConfig
        var readOnly = !gateway.isConnected

        if gateway.isConnected {
            do {
                let (config, _) = try await gateway.configGetFull()
                let channels = config["channels"] as? [String: Any] ?? [:]
                feishuConfig = channels[ChannelType.feishu.rawValue] as? [String: Any] ?? localConfig
                readOnly = false
            } catch {
                readOnly = true
                errorMessage = "读取 gateway 配置失败，已回退为离线只读：\(error.localizedDescription)"
            }
        }

        loadedFeishuConfig = feishuConfig
        draft = makeDraft(from: feishuConfig, isReadOnly: readOnly)
        validateGroupsJSON()
    }

    private func makeDraft(from feishuConfig: [String: Any], isReadOnly: Bool) -> FeishuChannelConfigDraft {
        let resolvedConfig = ChannelConfigSupport.resolvedChannelConfig(
            for: .feishu,
            from: feishuConfig
        )
        let groupsObject = resolvedConfig["groups"] as? [String: Any] ?? [:]
        return FeishuChannelConfigDraft(
            isEnabled: feishuConfig["enabled"] as? Bool ?? true,
            dmPolicy: ChannelDmPolicy(rawValue: (resolvedConfig["dmPolicy"] as? String)?.lowercased() ?? "") ?? .pairing,
            groupPolicy: ChannelGroupPolicy(rawValue: (resolvedConfig["groupPolicy"] as? String)?.lowercased() ?? "") ?? .allowlist,
            requireMention: resolvedConfig["requireMention"] as? Bool ?? true,
            groupAllowFromText: ChannelConfigSupport.lineSeparatedText(
                from: ChannelConfigSupport.normalizeStringArray(from: resolvedConfig["groupAllowFrom"])
            ),
            groupsJSONText: ChannelConfigSupport.prettyPrintedJSONText(from: groupsObject),
            credentialMode: FeishuChannelConfigSupport.credentialMode(
                for: feishuConfig,
                localPaths: selectedLocalPaths
            ),
            isReadOnly: isReadOnly,
            validationError: nil
        )
    }

    private func validateGroupsJSON() {
        switch ChannelConfigSupport.parseObjectJSON(from: draft.groupsJSONText, fieldName: "groups") {
        case .success:
            draft.validationError = nil
        case .failure(let error):
            draft.validationError = error.localizedDescription
        }
    }

    private func formatGroupsJSON() {
        guard case .success(let groupsObject) = ChannelConfigSupport.parseObjectJSON(from: draft.groupsJSONText, fieldName: "groups") else {
            return
        }
        draft.groupsJSONText = ChannelConfigSupport.prettyPrintedJSONText(from: groupsObject)
        draft.validationError = nil
    }

    private func save() async {
        guard !draft.isReadOnly else { return }
        validateGroupsJSON()
        guard draft.validationError == nil else { return }

        isSaving = true
        errorMessage = nil
        successMessage = nil
        defer { isSaving = false }

        let groupsObject: [String: Any]
        switch ChannelConfigSupport.parseObjectJSON(from: draft.groupsJSONText, fieldName: "groups") {
        case .success(let object):
            groupsObject = object
        case .failure(let error):
            draft.validationError = error.localizedDescription
            return
        }

        do {
            let (config, baseHash) = try await gateway.configGetFull()
            let channels = config["channels"] as? [String: Any] ?? [:]
            let feishuConfig = channels[ChannelType.feishu.rawValue] as? [String: Any] ?? loadedFeishuConfig
            let channelPatch = channelPatchForSave(
                existingFeishuConfig: feishuConfig,
                groupsObject: groupsObject
            )
            let patch: [String: Any] = [
                "channels": [
                    ChannelType.feishu.rawValue: channelPatch
                ]
            ]

            _ = try await gateway.configPatch(
                patch: patch,
                baseHash: baseHash,
                note: "更新飞书渠道配置"
            )

            successMessage = "飞书渠道配置已保存"
            onSaved?()
            await loadConfig()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func channelPatchForSave(
        existingFeishuConfig: [String: Any],
        groupsObject: [String: Any]
    ) -> [String: Any] {
        let strategyPatch: [String: Any] = [
            "dmPolicy": draft.dmPolicy.rawValue,
            "groupPolicy": draft.groupPolicy.rawValue,
            "requireMention": draft.requireMention,
            "groupAllowFrom": ChannelConfigSupport.normalizeLineSeparatedIDs(draft.groupAllowFromText),
            "groups": groupsObject,
        ]

        guard ChannelConfigSupport.usesDefaultAccountLayout(
            for: .feishu,
            in: existingFeishuConfig
        ) else {
            var legacyPatch = strategyPatch
            legacyPatch["enabled"] = draft.isEnabled
            return legacyPatch
        }

        let accountID = ChannelConfigSupport.defaultAccountID(in: existingFeishuConfig)
        return [
            "enabled": draft.isEnabled,
            "defaultAccount": accountID,
            "accounts": [
                accountID: strategyPatch
            ]
        ]
    }

    private func refreshAfterExternalChange() async {
        await loadConfig()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await loadConfig()
        onSaved?()
    }
}

struct ChannelPairingManagerSection: View {
    private enum FontSize {
        static let body: CGFloat = 14
        static let meta: CGFloat = 13
        static let mono: CGFloat = 13
        static let section: CGFloat = 15
        static let action: CGFloat = 15
    }

    let channelType: ChannelType
    let policyNotice: String?
    var onChanged: (() async -> Void)?

    @Environment(GatewayService.self) private var gateway
    @Environment(GatewayProfileStore.self) private var profileStore

    @State private var pendingRequests: [PairingRequest] = []
    @State private var approvedPeers: [PairingPeer] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var manualCode = ""
    @State private var isApproving = false
    @State private var peerToRemove: PairingPeer?

    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private var selectedResolution: GatewayProfileResolution? { profileStore.selectedResolution }
    private var selectedLocalPaths: GatewayProfileLocalPaths? { profileStore.selectedLocalPaths }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let policyNotice {
                sectionCard {
                    Label(policyNotice, systemImage: "info.circle.fill")
                        .font(.system(size: FontSize.body, weight: .medium))
                        .foregroundStyle(.orange)
                }
            }

            if let successMessage {
                sectionCard {
                    Label(successMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: FontSize.body, weight: .medium))
                        .foregroundStyle(.green)
                }
            }

            if let errorMessage {
                sectionCard {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: FontSize.body, weight: .medium))
                        .foregroundStyle(.red)
                }
            }

            if !hasLoadedOnce && isLoading {
                ProgressView("加载配对状态中…")
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                approveCodeSection
                if !pendingRequests.isEmpty {
                    pendingSection
                }
                approvedSection
            }
        }
        .task { await loadAll() }
        .onReceive(refreshTimer) { _ in
            Task { await loadAll() }
        }
        .alert(
            "确认移除",
            isPresented: Binding(
                get: { peerToRemove != nil },
                set: { if !$0 { peerToRemove = nil } }
            ),
            presenting: peerToRemove
        ) { peer in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                Task { await removePeer(peer) }
            }
        } message: { peer in
            Text("将移除 \(peer.displayName ?? peer.id) 的配对关系，该用户将无法继续与机器人对话。")
        }
    }

    @ViewBuilder
    private var approveCodeSection: some View {
        sectionBlock(
            title: "配对审批",
            systemImage: "key.fill",
            trailing: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("用户给机器人发消息后会收到一个配对码，在此输入即可审批通过。")
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("输入配对码（如 LHSTVRP9）", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: FontSize.body, design: .monospaced))
                    Button {
                        Task { await approveCode(manualCode) }
                    } label: {
                        Label("审批通过", systemImage: "checkmark.circle")
                    }
                    .font(.system(size: FontSize.action, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApproving)
                }
            }
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        sectionBlock(
            title: "待审批请求",
            systemImage: "bell.badge",
            trailing: {
                Text("\(pendingRequests.count)")
                    .font(.system(size: FontSize.meta, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        ) {
            VStack(spacing: 10) {
                ForEach(pendingRequests) { request in
                    pendingRequestRow(request)
                }
            }
        }
    }

    @ViewBuilder
    private func pendingRequestRow(_ request: PairingRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let name = request.displayName {
                        Text(name)
                            .font(.system(size: FontSize.body, weight: .semibold))
                    }
                    Text("ID: \(request.userId)")
                        .font(.system(size: FontSize.mono, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("配对码")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                    Text(request.code)
                        .font(.system(size: FontSize.mono, design: .monospaced))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let ts = request.requestedAt {
                        Text(ts)
                            .font(.system(size: FontSize.meta))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            Button {
                Task { await approveCode(request.code) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .help("审批通过")

            Button {
                Task { await rejectCode(request.code) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
            .help("拒绝")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var approvedSection: some View {
        sectionBlock(
            title: "已配对 (\(approvedPeers.count))",
            systemImage: "person.crop.circle.badge.checkmark"
        ) {
            if approvedPeers.isEmpty {
                Text("暂无已配对的用户")
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(approvedPeers) { peer in
                        approvedPeerRow(peer)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func approvedPeerRow(_ peer: PairingPeer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: peer.isGroup ? "person.3.fill" : "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName ?? peer.id)
                    .font(.system(size: FontSize.body, weight: .semibold))
                HStack(spacing: 6) {
                    Text(peer.kindLabel)
                        .font(.system(size: FontSize.meta))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(peer.isGroup ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
                        .foregroundStyle(peer.isGroup ? .purple : .blue)
                        .clipShape(Capsule())
                    Text("ID: \(peer.id)")
                        .font(.system(size: FontSize.mono, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ts = peer.pairedAt {
                Text(ts)
                    .font(.system(size: FontSize.meta))
                    .foregroundStyle(.tertiary)
            }

            Button(role: .destructive) {
                peerToRemove = peer
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func sectionBlock<Trailing: View, Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: FontSize.section, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            sectionCard {
                content()
            }
        }
    }

    private func loadAll() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        pendingRequests = ChannelPairingDataLoader.pendingRequests(
            for: channelType,
            localPaths: selectedLocalPaths
        )
        approvedPeers = ChannelPairingDataLoader.approvedPeers(
            for: channelType,
            localPaths: selectedLocalPaths
        )
    }

    private func approveCode(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isApproving = true
        errorMessage = nil
        successMessage = nil
        defer { isApproving = false }

        guard let selectedResolution else {
            errorMessage = "当前未选择 profile，无法执行配对审批"
            return
        }

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(args: [
            "pairing", "approve", channelType.rawValue, trimmed
        ], profile: selectedResolution)

        if ok {
            successMessage = "已审批通过配对码 \(trimmed)"
            manualCode = ""
            await loadAll()
            if let onChanged {
                await onChanged()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if successMessage?.contains(trimmed) == true {
                    successMessage = nil
                }
            }
        } else {
            errorMessage = "审批失败：\(output)"
        }
    }

    private func rejectCode(_ code: String) async {
        errorMessage = nil
        successMessage = nil

        do {
            let changed = try ChannelPairingMutationSupport.rejectPendingRequest(
                code: code,
                channel: channelType,
                localPaths: selectedLocalPaths
            )
            guard changed else {
                errorMessage = "未找到配对码 \(code)"
                return
            }
            await loadAll()
            if let onChanged {
                await onChanged()
            }
            successMessage = "已拒绝配对码 \(code)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if successMessage?.contains(code) == true {
                    successMessage = nil
                }
            }
        } catch {
            errorMessage = "拒绝失败：\(error.localizedDescription)"
        }
    }

    private func removePeer(_ peer: PairingPeer) async {
        errorMessage = nil
        successMessage = nil

        do {
            let changed = try await ChannelPairingMutationSupport.removeApprovedPeer(
                peer,
                channel: channelType,
                gateway: gateway,
                localPaths: selectedLocalPaths
            )
            if changed {
                await loadAll()
                if let onChanged {
                    await onChanged()
                }
                successMessage = "已移除 \(peer.displayName ?? peer.id) 的私信授权"
            } else {
                errorMessage = "\(peer.displayName ?? peer.id) 不在当前白名单中"
            }
        } catch {
            errorMessage = "移除失败：\(error.localizedDescription)"
        }
    }
}
