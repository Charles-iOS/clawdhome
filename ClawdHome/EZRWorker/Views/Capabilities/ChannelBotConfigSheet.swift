// ClawdHome/Views/Capabilities/ChannelBotConfigSheet.swift
// 渠道机器人凭据配置表单（飞书 / Telegram / Discord 等）

import SwiftUI

struct ChannelBotConfigSheet: View {
    let channelType: ChannelType
    var onSaved: (() -> Void)?

    @Environment(GatewayService.self) private var gateway
    @Environment(\.dismiss) private var dismiss

    @State private var fieldValues: [String: String] = [:]
    @State private var isSaving = false
    @State private var isLoadingConfig = false
    @State private var errorMessage: String?
    @State private var baseHash = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack(spacing: 10) {
                channelType.iconView(size: 20, weight: .medium)
                Text(L10n.f("channel.bot_config.title", fallback: "设置 %@ 机器人", channelType.displayName))
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
            }

            if isLoadingConfig {
                ProgressView(L10n.k("channel.bot_config.loading", fallback: "加载配置中…"))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                // 凭据字段表单
                ForEach(channelType.configFields) { field in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(field.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if field.isSecure {
                            SecureField(field.placeholder, text: binding(for: field.id))
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField(field.placeholder, text: binding(for: field.id))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            // 操作按钮
            HStack {
                Spacer()
                Button(L10n.k("common.cancel", fallback: "取消")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button(L10n.k("common.save", fallback: "保存")) {
                    Task { await save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || !hasAnyValue)
            }
        }
        .padding(20)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 280)
        .task { await loadExistingConfig() }
    }

    // MARK: - Helpers

    private func binding(for fieldId: String) -> Binding<String> {
        Binding(
            get: { fieldValues[fieldId] ?? "" },
            set: { fieldValues[fieldId] = $0 }
        )
    }

    private var hasAnyValue: Bool {
        fieldValues.values.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
    }

    // MARK: - 数据操作

    /// 从 gateway config 加载已有凭据值
    private func loadExistingConfig() async {
        guard gateway.isConnected else { return }
        isLoadingConfig = true
        defer { isLoadingConfig = false }

        do {
            let (config, hash) = try await gateway.configGetFull()
            baseHash = hash
            let channelsDict = config["channels"] as? [String: Any] ?? [:]
            let chConfig = channelsDict[channelType.rawValue] as? [String: Any] ?? [:]

            var values: [String: String] = [:]
            for field in channelType.configFields {
                if let value = chConfig[field.id] as? String {
                    values[field.id] = value
                }
            }
            fieldValues = values
        } catch {
            appLog("[channel] 加载 \(channelType.rawValue) 配置失败: \(error)", level: .error)
        }
    }

    /// 保存凭据到 gateway config
    private func save() async {
        guard gateway.isConnected else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        // 构建配置补丁
        var channelPatch: [String: Any] = [:]
        for field in channelType.configFields {
            let value = fieldValues[field.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            channelPatch[field.id] = value
        }

        let patch: [String: Any] = [
            "channels": [
                channelType.rawValue: channelPatch
            ]
        ]

        do {
            try await gateway.configPatch(
                patch: patch,
                baseHash: baseHash,
                note: "配置 \(channelType.displayName) 机器人凭据"
            )
            onSaved?()
            dismiss()
        } catch {
            errorMessage = L10n.f("channel.bot_config.save_failed", fallback: "保存失败：%@", error.localizedDescription)
            appLog("[channel] 保存 \(channelType.rawValue) 配置失败: \(error)", level: .error)
        }
    }
}
