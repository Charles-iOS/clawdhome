// ClawdHome/Services/OpenClawProviderKeySync.swift
// 「配置 → 模型」动态 Provider：将 API Key / URL 写入本机 Gateway 的 openclaw 配置（config.set）

import Foundation

enum OpenClawProviderKeySync {

    private static func jsonValue(_ value: ProviderConfigValue) -> Any {
        switch value {
        case .string(let s): return s
        case .bool(let b): return b
        case .jsonArray(let rows): return rows
        }
    }

    static func staticConfig(for providerId: String) -> ProviderKeyConfig? {
        supportedProviderKeys.first { $0.id == providerId }
    }

    /// 主配置 dot-path（用于清除等）
    static func primaryConfigPath(for providerId: String) -> String {
        if let cfg = staticConfig(for: providerId) {
            return cfg.configPath
        }
        return "models.providers.\(providerId).apiKey"
    }

    /// 将密钥写入或清除到本机 Gateway（WebSocket config.set）
    /// - Parameter secret: nil 或空字符串表示清除主路径
    @MainActor
    static func applyToGateway(
        gateway: GatewayService,
        providerId: String,
        secret: String?
    ) async throws {
        let trimmed = (secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let clear = trimmed.isEmpty

        if let cfg = staticConfig(for: providerId) {
            if clear {
                try await gateway.configSet(path: cfg.configPath, value: "")
            } else {
                // 单次 merge patch，避免分步写入时 schema 校验缺少 baseUrl / models 等
                var pairs: [(String, Any)] = cfg.sideConfigs.map { ($0.key, jsonValue($0.value)) }
                pairs.append((cfg.configPath, trimmed))
                try await gateway.applyConfigLeafPatches(pairs)
            }
        } else {
            let path = "models.providers.\(providerId).apiKey"
            try await gateway.configSet(path: path, value: clear ? "" : trimmed)
        }
    }
}
