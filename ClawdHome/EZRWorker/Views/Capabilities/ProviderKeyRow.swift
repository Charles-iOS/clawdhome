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
            DynamicProviderKeyEditSheet(providerId: providerId, isPresented: $isEditing)
        }
    }
}

// MARK: - 编辑表单（钥匙串 + Gateway config.set）

private struct DynamicProviderKeyEditSheet: View {
    let providerId: String
    @Binding var isPresented: Bool

    @Environment(ProviderKeychainStore.self) private var keychainStore
    @Environment(GatewayService.self) private var gateway

    @State private var keyValue = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var showLocalOnlyAlert = false

    private var staticCfg: ProviderKeyConfig? {
        OpenClawProviderKeySync.staticConfig(for: providerId)
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Text(providerId).font(.headline)
                Text(staticCfg?.inputLabel ?? "API Key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if let cfg = staticCfg, cfg.isUrlConfig {
                TextField(cfg.placeholder, text: $keyValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            } else {
                SecureField(staticCfg?.placeholder ?? "API Key", text: $keyValue)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Text(L10n.f(
                "models.gateway_key_sync.path_hint",
                fallback: "配置路径：%@",
                OpenClawProviderKeySync.primaryConfigPath(for: providerId)
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Button(L10n.k("common.cancel", fallback: "取消")) {
                    isPresented = false
                }
                .keyboardShortcut(.escape)
                Button(isSaving ? L10n.k("common.saving", fallback: "保存中…") : L10n.k("common.save", fallback: "保存")) {
                    Task { await save() }
                }
                .keyboardShortcut(.return)
                .disabled(isSaving)
            }
        }
        .padding(20)
        .frame(minWidth: 380)
        .onAppear {
            keyValue = keychainStore.read(forProvider: providerId) ?? ""
            saveError = nil
        }
        .alert(
            L10n.k("models.gateway_key_sync.local_only_title", fallback: "已保存到本机"),
            isPresented: $showLocalOnlyAlert
        ) {
            Button(L10n.k("common.ok", fallback: "好")) {
                isPresented = false
            }
        } message: {
            Text(L10n.k(
                "models.gateway_key_sync.local_only",
                fallback: "Gateway 未连接，API 密钥已写入本机钥匙串，尚未写入 OpenClaw。连接 Gateway 后可再次打开此处保存以同步。"
            ))
        }
    }

    private func save() async {
        saveError = nil
        let trimmed = keyValue.trimmingCharacters(in: .whitespaces)
        isSaving = true
        defer { isSaving = false }

        if trimmed.isEmpty {
            if gateway.isConnected {
                do {
                    try await OpenClawProviderKeySync.applyToGateway(
                        gateway: gateway,
                        providerId: providerId,
                        secret: nil
                    )
                    keychainStore.delete(forProvider: providerId)
                    isPresented = false
                } catch {
                    saveError = L10n.f(
                        "models.gateway_key_sync.clear_failed",
                        fallback: "清除 Gateway 配置失败：%@",
                        error.localizedDescription
                    )
                }
            } else {
                keychainStore.delete(forProvider: providerId)
                isPresented = false
            }
            return
        }

        keychainStore.save(apiKey: trimmed, forProvider: providerId)

        guard gateway.isConnected else {
            showLocalOnlyAlert = true
            return
        }

        do {
            try await OpenClawProviderKeySync.applyToGateway(
                gateway: gateway,
                providerId: providerId,
                secret: trimmed
            )
            isPresented = false
        } catch {
            saveError = L10n.f(
                "models.gateway_key_sync.failed",
                fallback: "已保存到本机，但写入 Gateway 失败：%@",
                error.localizedDescription
            )
        }
    }
}
