import Foundation
import SwiftUI

private struct TelegramChannelConfigDraft {
    var isEnabled = true
    var dmPolicy: ChannelDmPolicy = .pairing
    var allowFromText = ""
    var groupPolicy: ChannelGroupPolicy = .allowlist
    var groupAllowFromText = ""
    var groupsJSONText = "{}"
    var accessStatusTitle = "已配置 Telegram 渠道"
    var accessStatusDetail = "当前已检测到 Telegram 配置。"
    var isReadOnly = false
    var validationError: String?
}

private enum TelegramChannelConfigSupport {
    static func accessStatus(for telegramConfig: [String: Any]) -> (title: String, detail: String) {
        if let tokenFile = telegramConfig["tokenFile"] as? String,
           !tokenFile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (
                "已通过 tokenFile 配置",
                "当前 Telegram Bot Token 通过 `tokenFile` 提供。编辑凭据后会切换为直接写入配置。"
            )
        }

        if let botToken = telegramConfig["botToken"] as? String,
           !botToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return (
                "已通过 Bot Token 配置",
                "当前直接在渠道配置中保存了 Telegram Bot Token。"
            )
        }

        return (
            "已配置 Telegram 渠道",
            "当前已检测到 Telegram 配置，但当前入口未识别到可直接编辑的 Bot Token。"
        )
    }
}

struct TelegramChannelConfigSheet: View {
    private enum FontSize {
        static let title: CGFloat = 20
        static let subtitle: CGFloat = 14
        static let section: CGFloat = 15
        static let body: CGFloat = 14
        static let meta: CGFloat = 13
    }

    var onSaved: (() -> Void)?

    @Environment(GatewayService.self) private var gateway
    @Environment(\.dismiss) private var dismiss

    @State private var draft = TelegramChannelConfigDraft()
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showCredentialSheet = false

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
        .sheet(isPresented: $showCredentialSheet) {
            ChannelBotConfigSheet(channelType: .telegram) {
                Task { await refreshAfterExternalChange() }
            }
            .environment(gateway)
        }
        .onChange(of: draft.groupsJSONText) { _, _ in
            validateGroupsJSON()
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: ChannelType.telegram.iconName)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(ChannelType.telegram.swiftUIColor)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text("Telegram · 渠道配置")
                    .font(.system(size: FontSize.title, weight: .semibold))
                Text("管理 Bot Token、私信与群组策略，以及旧的 DM 配对审批。")
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
                Label("当前为离线只读模式，策略可以查看，但保存和凭据入口已禁用。", systemImage: "lock.fill")
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
                    Text(draft.accessStatusTitle)
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
                Text(draft.accessStatusDetail)
                    .font(.system(size: FontSize.body))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 6) {
                    Toggle("启用 Telegram 渠道", isOn: $draft.isEnabled)
                        .disabled(draft.isReadOnly)
                    Text("对应 `channels.telegram.enabled`。关闭后 Telegram 渠道不会启动，但现有策略、群配置和配对数据都会保留。")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                }

                Button("编辑 Bot Token") {
                    showCredentialSheet = true
                }
                .buttonStyle(.bordered)
                .disabled(draft.isReadOnly)
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

                VStack(alignment: .leading, spacing: 6) {
                    Text("私信白名单 (`allowFrom`)")
                        .font(.system(size: FontSize.body, weight: .semibold))
                    Text("一行一个 Telegram 用户 ID，支持 `telegram:` / `tg:` 前缀。若 `dmPolicy = open`，请包含 `*`；若 `dmPolicy = allowlist`，至少需要一个 sender ID。")
                        .font(.system(size: FontSize.meta))
                        .foregroundStyle(.secondary)
                    editor(text: $draft.allowFromText, minHeight: 96, isReadOnly: draft.isReadOnly)
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
                    Text("群内发送者白名单 (`groupAllowFrom`)")
                        .font(.system(size: FontSize.body, weight: .semibold))
                    Text("一行一个 Telegram 用户 ID。这里不要放负数群 / 超群 chat ID；群 ID 请写进下面的 `groups` JSON。留空表示删除该字段，让运行时回退到 `allowFrom`。")
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
                    Text("根节点必须是对象。可写 `\"*\"` 作为全局默认项；`requireMention`、`allowFrom`、`groupPolicy` 等 Telegram 群配置都放在这里。")
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
                channelType: .telegram,
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

        let localConfig = ChannelConfigSupport.loadLocalChannelConfig(for: .telegram)
        var telegramConfig = localConfig
        var readOnly = !gateway.isConnected

        if gateway.isConnected {
            do {
                let (config, _) = try await gateway.configGetFull()
                let channels = config["channels"] as? [String: Any] ?? [:]
                telegramConfig = channels[ChannelType.telegram.rawValue] as? [String: Any] ?? localConfig
                readOnly = false
            } catch {
                readOnly = true
                errorMessage = "读取 gateway 配置失败，已回退为离线只读：\(error.localizedDescription)"
            }
        }

        draft = makeDraft(from: telegramConfig, isReadOnly: readOnly)
        validateGroupsJSON()
    }

    private func makeDraft(from telegramConfig: [String: Any], isReadOnly: Bool) -> TelegramChannelConfigDraft {
        let status = TelegramChannelConfigSupport.accessStatus(for: telegramConfig)
        let groupsObject = telegramConfig["groups"] as? [String: Any] ?? [:]
        return TelegramChannelConfigDraft(
            isEnabled: telegramConfig["enabled"] as? Bool ?? true,
            dmPolicy: ChannelDmPolicy(rawValue: (telegramConfig["dmPolicy"] as? String)?.lowercased() ?? "") ?? .pairing,
            allowFromText: ChannelConfigSupport.lineSeparatedText(
                from: ChannelConfigSupport.normalizeStringArray(from: telegramConfig["allowFrom"], allowWildcard: true)
            ),
            groupPolicy: ChannelGroupPolicy(rawValue: (telegramConfig["groupPolicy"] as? String)?.lowercased() ?? "") ?? .allowlist,
            groupAllowFromText: ChannelConfigSupport.lineSeparatedText(
                from: ChannelConfigSupport.normalizeStringArray(from: telegramConfig["groupAllowFrom"], allowWildcard: true)
            ),
            groupsJSONText: ChannelConfigSupport.prettyPrintedJSONText(from: groupsObject),
            accessStatusTitle: status.title,
            accessStatusDetail: status.detail,
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

        let allowFrom = ChannelConfigSupport.normalizeLineSeparatedIDs(draft.allowFromText, allowWildcard: true)
        let groupAllowFrom = ChannelConfigSupport.normalizeLineSeparatedIDs(draft.groupAllowFromText, allowWildcard: true)
        let allowFromValue: Any = allowFrom.isEmpty ? NSNull() : allowFrom
        let groupAllowFromValue: Any = groupAllowFrom.isEmpty ? NSNull() : groupAllowFrom

        do {
            let (_, baseHash) = try await gateway.configGetFull()
            let patch: [String: Any] = [
                "channels": [
                    ChannelType.telegram.rawValue: [
                        "enabled": draft.isEnabled,
                        "dmPolicy": draft.dmPolicy.rawValue,
                        "allowFrom": allowFromValue,
                        "groupPolicy": draft.groupPolicy.rawValue,
                        "groupAllowFrom": groupAllowFromValue,
                        "groups": groupsObject,
                    ]
                ]
            ]

            _ = try await gateway.configPatch(
                patch: patch,
                baseHash: baseHash,
                note: "更新 Telegram 渠道配置"
            )

            successMessage = "Telegram 渠道配置已保存"
            onSaved?()
            await loadConfig()
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func refreshAfterExternalChange() async {
        await loadConfig()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await loadConfig()
        onSaved?()
    }
}
