// ClawdHome/Services/ProviderKeychainStore.swift
import Foundation
import Security
import Observation

enum KnownProvider: String, CaseIterable {
    case anthropic
    case openai
    case google
    case openrouter

    var displayName: String {
        switch self {
        case .anthropic:  return "Anthropic"
        case .openai:     return "OpenAI"
        case .google:     return "Google AI"
        case .openrouter: return "OpenRouter"
        }
    }

    var keyPlaceholder: String {
        switch self {
        case .anthropic:  return "sk-ant-…"
        case .openai:     return "sk-…"
        case .google:     return "AIza…"
        case .openrouter: return "sk-or-…"
        }
    }

    static func from(modelId: String) -> KnownProvider? {
        let prefix = modelId.components(separatedBy: "/").first ?? ""
        return KnownProvider(rawValue: prefix)
    }
}

@Observable
final class ProviderKeychainStore {
    private let service = "ai.clawdhome.mac"
    // Incrementing this counter inside save/delete causes @Observable to
    // invalidate any computed property (providerStatuses) that reads it.
    private var _keychainVersion: Int = 0

    private func account(for providerId: String) -> String {
        "provider.\(providerId)"
    }

    // MARK: - 字符串 provider 接口（动态 provider）

    func save(apiKey: String, forProvider id: String) {
        delete(forProvider: id)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id),
            kSecValueData as String:   Data(apiKey.utf8)
        ]
        SecItemAdd(query as CFDictionary, nil)
        _keychainVersion += 1
    }

    func read(forProvider id: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id),
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let key = String(data: data, encoding: .utf8)
        else { return nil }
        return key
    }

    func delete(forProvider id: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account(for: id)
        ]
        SecItemDelete(query as CFDictionary)
        _keychainVersion += 1
    }

    func hasKey(forProvider id: String) -> Bool {
        read(forProvider: id) != nil
    }

    // MARK: - KnownProvider 便捷接口（桥接到字符串接口）

    func save(apiKey: String, for provider: KnownProvider) {
        save(apiKey: apiKey, forProvider: provider.rawValue)
    }

    func read(for provider: KnownProvider) -> String? {
        read(forProvider: provider.rawValue)
    }

    func delete(for provider: KnownProvider) {
        delete(forProvider: provider.rawValue)
    }

    func hasKey(for provider: KnownProvider) -> Bool {
        hasKey(forProvider: provider.rawValue)
    }

    /// Reading `_keychainVersion` establishes an @Observable dependency so
    /// SwiftUI views re-evaluate this property after every save/delete.
    var providerStatuses: [(provider: KnownProvider, hasKey: Bool)] {
        _ = _keychainVersion
        return KnownProvider.allCases.map { ($0, hasKey(for: $0)) }
    }
}
