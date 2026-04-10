// ClawdHome/Views/Capabilities/ProviderKeyRow.swift

import SwiftUI

struct ProviderKeyRow: View {
    let provider: KnownProvider

    @Environment(ProviderKeychainStore.self) private var keychainStore
    @State private var isEditing = false
    @State private var keyValue = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.displayName)
                    .fontWeight(.medium)
                let hasKey = keychainStore.hasKey(for: provider)
                Text(hasKey
                     ? L10n.k("models.key_set", fallback: "已配置")
                     : L10n.k("models.key_missing", fallback: "未配置"))
                    .font(.caption)
                    .foregroundStyle(hasKey ? .green : .orange)
            }
            Spacer()
            Button(L10n.k("models.edit_key", fallback: "编辑")) {
                isEditing = true
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(spacing: 12) {
                Text(String(format: L10n.k("models.key_sheet.title", fallback: "%@ API Key"), provider.displayName))
                    .font(.headline)
                SecureField(provider.keyPlaceholder, text: $keyValue)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.k("common.cancel", fallback: "取消")) { isEditing = false }
                    Button(L10n.k("common.save", fallback: "保存")) {
                        keychainStore.save(apiKey: keyValue, for: provider)
                        isEditing = false
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 360)
        }
    }
}

// MARK: - 动态 provider（从 gateway models.list 获取）

struct DynamicProviderKeyRow: View {
    let providerId: String

    @Environment(ProviderKeychainStore.self) private var keychainStore
    @State private var isEditing = false
    @State private var keyValue = ""

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(providerId)
                    .fontWeight(.medium)
                let hasKey = keychainStore.hasKey(forProvider: providerId)
                Text(hasKey
                     ? L10n.k("models.key_set", fallback: "已配置")
                     : L10n.k("models.key_missing", fallback: "未配置"))
                    .font(.caption)
                    .foregroundStyle(hasKey ? .green : .orange)
            }
            Spacer()
            Button(L10n.k("models.edit_key", fallback: "编辑")) {
                isEditing = true
            }
        }
        .sheet(isPresented: $isEditing) {
            VStack(spacing: 12) {
                Text(String(format: L10n.k("models.key_sheet.title", fallback: "%@ API Key"), providerId))
                    .font(.headline)
                SecureField("API Key", text: $keyValue)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button(L10n.k("common.cancel", fallback: "取消")) { isEditing = false }
                    Button(L10n.k("common.save", fallback: "保存")) {
                        let trimmed = keyValue.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            keychainStore.delete(forProvider: providerId)
                        } else {
                            keychainStore.save(apiKey: trimmed, forProvider: providerId)
                        }
                        isEditing = false
                    }
                }
            }
            .padding(20)
            .frame(minWidth: 360)
        }
    }
}
