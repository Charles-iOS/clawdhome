// EZRWorkerApp/Models/ProviderKeyConfig.swift
// 支持的 AI Provider 及其配置路径

import Foundation

enum ProviderConfigValue {
    case string(String)
    case bool(Bool)
    /// OpenClaw `models.providers.*.models` 数组（与 UserInitWizard MinimaxModel 结构一致）
    case jsonArray([[String: Any]])
}

struct ProviderKeyConfig: Identifiable {
    let id: String           // provider 标识（如 "anthropic"）
    let displayName: String  // UI 显示名
    let configPath: String   // openclaw config dot-path
    let placeholder: String  // 输入框占位符
    let isUrlConfig: Bool    // true = 填 URL 而非 API Key（Ollama）
    let supportsOAuth: Bool  // true = 支持 OAuth 授权（如 OpenAI Codex）
    /// 设置主配置时必须同步写入的附加键值对（如 moonshot 需要同时设 baseUrl）
    let sideConfigs: [(key: String, value: ProviderConfigValue)]

    init(id: String, displayName: String, configPath: String, placeholder: String,
         isUrlConfig: Bool, supportsOAuth: Bool,
         sideConfigs: [(key: String, value: ProviderConfigValue)] = []) {
        self.id = id
        self.displayName = displayName
        self.configPath = configPath
        self.placeholder = placeholder
        self.isUrlConfig = isUrlConfig
        self.supportsOAuth = supportsOAuth
        self.sideConfigs = sideConfigs
    }

    var inputLabel: String { isUrlConfig ? L10n.k("models.provider_key_config.service_url", fallback: "服务地址") : "API Key" }
}

let defaultMiniMaxModelId = "minimax/MiniMax-M2.7"

/// MiniMax 系列在 OpenClaw 中要求的 `models` 清单（与 UserInitWizard MinimaxModel.providerModelConfig 对齐）
let minimaxOpenClawModelCatalog: [[String: Any]] = [
    [
        "id": "MiniMax-M2.7",
        "name": "MiniMax M2.7",
        "reasoning": true,
        "input": ["text"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
    [
        "id": "MiniMax-M2.7-highspeed",
        "name": "MiniMax M2.7 Highspeed",
        "reasoning": true,
        "input": ["text"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
    [
        "id": "MiniMax-M2.5",
        "name": "MiniMax M2.5",
        "reasoning": true,
        "input": ["text"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
    [
        "id": "MiniMax-M2.5-highspeed",
        "name": "MiniMax M2.5 Highspeed",
        "reasoning": true,
        "input": ["text"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
    [
        "id": "MiniMax-VL-01",
        "name": "MiniMax VL 01",
        "reasoning": false,
        "input": ["text", "image"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
    [
        "id": "MiniMax-M2",
        "name": "MiniMax M2",
        "reasoning": true,
        "input": ["text"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
    [
        "id": "MiniMax-M2.1",
        "name": "MiniMax M2.1",
        "reasoning": true,
        "input": ["text"],
        "cost": ["input": 0.3, "output": 1.2, "cacheRead": 0.03, "cacheWrite": 0.12],
        "contextWindow": 200_000,
        "maxTokens": 8192,
    ],
]

/// 所有支持的 Provider（顺序即界面显示顺序）
/// 与 openclaw src/agents/models-config.providers.ts 同步
let supportedProviderKeys: [ProviderKeyConfig] = [
    // ── 直连 Provider ──────────────────────────────────────
    ProviderKeyConfig(
        id: "anthropic",
        displayName: "Anthropic",
        configPath: "models.providers.anthropic.apiKey",
        placeholder: "sk-ant-api...",
        isUrlConfig: false, supportsOAuth: false),
    ProviderKeyConfig(
        id: "openai",
        displayName: "OpenAI",
        configPath: "models.providers.openai.apiKey",
        placeholder: "sk-proj-...",
        isUrlConfig: false, supportsOAuth: true),   // OpenAI Codex (ChatGPT OAuth)
    ProviderKeyConfig(
        id: "openai-compatible",
        displayName: "OpenAI-compatible",
        configPath: "models.providers.openai-compatible.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.openai-compatible.api", .string("openai-completions")),
        ]),
    ProviderKeyConfig(
        id: "google",
        displayName: "Google Gemini",
        configPath: "models.providers.google.apiKey",
        placeholder: "AIzaSy...",
        isUrlConfig: false, supportsOAuth: false),
    ProviderKeyConfig(
        id: "moonshot",
        displayName: "Moonshot（Kimi）",
        configPath: "models.providers.moonshot.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.moonshot.api", .string("openai-completions")),
            ("models.providers.moonshot.baseUrl", .string("https://api.moonshot.cn/v1")),
        ]),
    ProviderKeyConfig(
        id: "kimi-coding",
        displayName: "Kimi Coding",
        configPath: "models.providers.kimi-coding.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.kimi-coding.api", .string("anthropic-messages")),
            ("models.providers.kimi-coding.baseUrl", .string("https://api.kimi.com/coding/")),
        ]),
    ProviderKeyConfig(
        id: "minimax",
        displayName: "MiniMax",
        configPath: "models.providers.minimax.apiKey",
        placeholder: "eyJ...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.minimax.api", .string("anthropic-messages")),
            ("models.providers.minimax.baseUrl", .string("https://api.minimaxi.com/anthropic")),
            ("models.providers.minimax.authHeader", .bool(true)),
            ("models.providers.minimax.models", .jsonArray(minimaxOpenClawModelCatalog)),
        ]),
    ProviderKeyConfig(
        id: "minimax-cn",
        displayName: "MiniMax（国内）",
        configPath: "models.providers.minimax-cn.apiKey",
        placeholder: "eyJ...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.minimax-cn.api", .string("anthropic-messages")),
            ("models.providers.minimax-cn.baseUrl", .string("https://api.minimaxi.com/anthropic")),
            ("models.providers.minimax-cn.authHeader", .bool(true)),
            ("models.providers.minimax-cn.models", .jsonArray(minimaxOpenClawModelCatalog)),
        ]),
    ProviderKeyConfig(
        id: "zai",
        displayName: "智谱 Z.AI",
        configPath: "models.providers.zai.apiKey",
        placeholder: "sk-...",
        isUrlConfig: false, supportsOAuth: false,
        sideConfigs: [
            ("models.providers.zai.api", .string("openai-completions")),
            ("models.providers.zai.baseUrl", .string("https://open.bigmodel.cn/api/paas/v4")),
        ]),
    // ── 网关 / 聚合 ────────────────────────────────────────
    ProviderKeyConfig(
        id: "openrouter",
        displayName: "OpenRouter",
        configPath: "models.providers.openrouter.apiKey",
        placeholder: "sk-or-...",
        isUrlConfig: false, supportsOAuth: false),
    // ── 本地 ───────────────────────────────────────────────
    ProviderKeyConfig(
        id: "ollama",
        displayName: "Ollama",
        configPath: "models.providers.ollama.baseUrl",
        placeholder: "http://localhost:11434",
        isUrlConfig: true, supportsOAuth: false),
]

private func providerConfigJSONValue(_ value: ProviderConfigValue) -> Any {
    switch value {
    case .string(let s): return s
    case .bool(let b): return b
    case .jsonArray(let rows): return rows
    }
}

func providerDisplayNameForID(_ providerId: String) -> String {
    supportedProviderKeys.first(where: { $0.id == providerId })?.displayName ?? providerId
}

func normalizedModelID(_ rawModelId: String, providerId: String) -> String {
    let trimmed = rawModelId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if trimmed.hasPrefix("\(providerId)/") {
        return trimmed
    }
    return "\(providerId)/\(trimmed)"
}

func modelDisplayLabel(
    for modelId: String,
    labels: [String: String] = [:]
) -> String {
    if let explicit = labels[modelId], !explicit.isEmpty {
        return explicit
    }
    if let builtIn = builtInModelGroups
        .flatMap(\.models)
        .first(where: { $0.id == modelId }) {
        return builtIn.label
    }

    let components = modelId.split(separator: "/", omittingEmptySubsequences: true)
    if components.count >= 2 {
        return String(components.dropFirst().joined(separator: "/"))
    }
    return modelId
}

func suggestedModelsForProvider(_ providerId: String) -> [ModelEntry] {
    switch providerId {
    case "minimax", "minimax-cn":
        return minimaxOpenClawModelCatalog.compactMap { row in
            guard let rawID = row["id"] as? String else { return nil }
            let name = row["name"] as? String ?? rawID
            return ModelEntry(
                id: normalizedModelID(rawID, providerId: providerId),
                label: name
            )
        }
    default:
        return []
    }
}

extension ProviderKeyConfig {
    var defaultBaseURL: String? {
        switch id {
        case "openai":
            return "https://api.openai.com/v1"
        case "openrouter":
            return "https://openrouter.ai/api/v1"
        case "moonshot":
            return "https://api.moonshot.cn/v1"
        case "zai":
            return "https://open.bigmodel.cn/api/paas/v4"
        case "ollama":
            return "http://localhost:11434/v1"
        default:
            return sideConfigs.first(where: { $0.key.hasSuffix(".baseUrl") }).flatMap { entry in
                if case .string(let value) = entry.value {
                    return value
                }
                return nil
            }
        }
    }

    var requiresBaseURLInput: Bool {
        id == "openai-compatible"
    }

    var allowsCustomProviderID: Bool {
        id == "openai-compatible"
    }

    var defaultAPIType: String {
        switch id {
        case "openai-compatible":
            return "openai-completions"
        default:
            return sideConfigs.first(where: { $0.key.hasSuffix(".api") }).flatMap { entry in
                if case .string(let value) = entry.value {
                    return value
                }
                return nil
            } ?? "openai-completions"
        }
    }

    var supportsRemoteModelDiscovery: Bool {
        switch id {
        case "openai", "openai-compatible", "openrouter", "moonshot", "zai":
            return true
        default:
            return false
        }
    }

    var suggestedModels: [ModelEntry] {
        suggestedModelsForProvider(id)
    }

    func makeModelCatalog(
        modelIds: [String],
        labels: [String: String] = [:]
    ) -> [[String: Any]] {
        let normalizedIDs = modelIds
            .map { normalizedModelID($0, providerId: id) }
            .filter { !$0.isEmpty }

        switch id {
        case "minimax", "minimax-cn":
            return normalizedIDs.compactMap { fullID in
                let rawID = String(fullID.dropFirst("\(id)/".count))
                if let builtIn = minimaxOpenClawModelCatalog.first(where: { ($0["id"] as? String) == rawID }) {
                    return builtIn
                }
                return [
                    "id": rawID,
                    "name": modelDisplayLabel(for: fullID, labels: labels),
                    "reasoning": true,
                    "input": ["text"],
                    "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0],
                    "contextWindow": 200_000,
                    "maxTokens": 8192,
                ]
            }
        default:
            return normalizedIDs.map { fullID in
                let rawID = fullID.hasPrefix("\(id)/")
                    ? String(fullID.dropFirst("\(id)/".count))
                    : fullID.components(separatedBy: "/").dropFirst().joined(separator: "/")
                return [
                    "id": rawID,
                    "name": modelDisplayLabel(for: fullID, labels: labels),
                    "input": ["text"],
                    "contextWindow": 128_000,
                    "maxTokens": 8192,
                ]
            }
        }
    }

    func makeProviderPayload(
        secret: String?,
        modelIds: [String],
        labels: [String: String] = [:]
    ) -> [String: Any] {
        let trimmedSecret = (secret ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let hasWritableSecret = !trimmedSecret.isEmpty && !isRedactedProviderSecret(trimmedSecret)
        var payload: [String: Any] = [:]

        for entry in sideConfigs {
            payload[entry.key.components(separatedBy: ".").last ?? entry.key] = providerConfigJSONValue(entry.value)
        }

        if isUrlConfig {
            if hasWritableSecret {
                payload["baseUrl"] = trimmedSecret
            } else if let defaultBaseURL {
                payload["baseUrl"] = defaultBaseURL
            }
        } else if hasWritableSecret {
            payload["apiKey"] = trimmedSecret
        }

        let catalog = makeModelCatalog(modelIds: modelIds, labels: labels)
        if !catalog.isEmpty {
            payload["models"] = catalog
        }

        return payload
    }

    private func isRedactedProviderSecret(_ value: String) -> Bool {
        value.count >= 3 && value.allSatisfy { $0 == "*" }
    }
}
