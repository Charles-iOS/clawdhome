// EZRWorkerApp/Views/Agent/AgentBindingsView.swift
// 管理单个智能体的渠道绑定（Agent 入口：智能体 → 选渠道）

import SwiftUI

private enum AgentBindingsFont {
    static let title: CGFloat = 20
    static let body: CGFloat = 16
    static let detail: CGFloat = 15
    static let meta: CGFloat = 14
    static let badge: CGFloat = 13
}

struct AgentBindingsView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayProcessManager.self) private var processManager
    @State private var showAddSheet = false

    private var agentBindings: [AgentBinding] {
        store.bindings(for: agentId)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if agentBindings.isEmpty {
                    emptyState
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(agentBindings) { binding in
                            bindingRow(binding)
                        }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showAddSheet) {
            AddBindingSheet(agentId: agentId)
        }
    }

    @ViewBuilder
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L10n.k("agent.bindings.title", fallback: "渠道绑定"))
                    .font(.system(size: AgentBindingsFont.title, weight: .semibold))
                Text(L10n.k("agent.bindings.empty_desc", fallback: "添加渠道绑定后，入站消息将路由到此智能体"))
                    .font(.system(size: AgentBindingsFont.detail))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button {
                showAddSheet = true
            } label: {
                Label(L10n.k("agent.bindings.add", fallback: "添加绑定"), systemImage: "plus")
                    .font(.system(size: AgentBindingsFont.body, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label(L10n.k("agent.bindings.empty", fallback: "暂无绑定"), systemImage: "arrow.triangle.branch")
        } description: {
            Text(L10n.k("agent.bindings.empty_desc", fallback: "添加渠道绑定后，入站消息将路由到此智能体"))
        } actions: {
            Button {
                showAddSheet = true
            } label: {
                Label(L10n.k("agent.bindings.add", fallback: "添加绑定"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func bindingRow(_ binding: AgentBinding) -> some View {
        let tint = binding.channelType?.swiftUIColor ?? Color.accentColor

        HStack(alignment: .center, spacing: 14) {
            Image(systemName: binding.channelIcon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(binding.channelType?.displayName ?? binding.channel.capitalized)
                    .font(.system(size: AgentBindingsFont.body, weight: .semibold))
                Text(binding.summary)
                    .font(.system(size: AgentBindingsFont.detail))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)

                FlowLayout(spacing: 6) {
                    ForEach(bindingScopeBadges(binding), id: \.self) { badge in
                        Text(badge)
                            .font(.system(size: AgentBindingsFont.badge, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.10), in: Capsule())
                    }
                }
            }

            Spacer(minLength: 12)

            Button(role: .destructive) {
                Task {
                    do {
                        try await store.removeBinding(binding)
                        await restartGatewayAfterBindingMutation()
                    } catch {
                        appLog("[binding] 移除绑定失败: \(error)", level: .error)
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.red.opacity(0.82))
            .background(.regularMaterial, in: Circle())
            .overlay {
                Circle()
                    .stroke(Color.red.opacity(0.18), lineWidth: 1)
            }
            .help(L10n.k("agent.bindings.delete", fallback: "删除绑定"))
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
        )
    }

    private func restartGatewayAfterBindingMutation() async {
        processManager.restart()
    }

    private func bindingScopeBadges(_ binding: AgentBinding) -> [String] {
        var badges: [String] = []
        if let accountId = binding.accountId, !accountId.isEmpty {
            badges.append("account: \(accountId)")
        }
        if let peerId = binding.peerId, !peerId.isEmpty {
            let kind = binding.peerKind ?? "peer"
            badges.append("\(kind): \(peerId)")
        }
        if let guildId = binding.guildId, !guildId.isEmpty {
            badges.append("guild: \(guildId)")
        }
        if let teamId = binding.teamId, !teamId.isEmpty {
            badges.append("team: \(teamId)")
        }
        if badges.isEmpty {
            badges.append(L10n.k("agent.bindings.default_route", fallback: "默认路由"))
        }
        return badges
    }
}

// MARK: - 添加绑定 Sheet（三步流程）

private struct AddBindingSheet: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayService.self) private var gateway
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @State private var step: AddBindingStep = .selectChannel
    @State private var selectedChannel: ChannelType?
    @State private var channelConfigs: [ChannelType: Bool] = [:]
    @State private var isLoadingConfigs = true

    @State private var isAdding = false

    // 凭据配置 / QR 子 sheet
    @State private var showCredentialSheet = false
    @State private var showQRSheet = false

    private var selectedLocalPaths: GatewayProfileLocalPaths? {
        profileStore.selectedLocalPaths
    }

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .selectChannel:
                    channelSelectionStep
                case .configureCredentials:
                    credentialConfigStep
                case .bindingMatch:
                    bindingMatchStep
                }
            }
            .navigationTitle(stepTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 420)
        .task(id: gateway.isConnected) { await loadChannelConfigs() }
    }

    private var stepTitle: String {
        switch step {
        case .selectChannel: return L10n.k("agent.binding.step.select", fallback: "选择渠道")
        case .configureCredentials: return L10n.k("agent.binding.step.config", fallback: "配置渠道")
        case .bindingMatch: return L10n.k("agent.binding.step.match", fallback: "绑定条件")
        }
    }

    // MARK: - Step 1: 选择渠道

    @ViewBuilder
    private var channelSelectionStep: some View {
        if isLoadingConfigs {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.k("agent.binding.select_hint", fallback: "选择要绑定的消息渠道"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ChannelType.enabledCases) { channel in
                            channelCard(channel)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private func channelCard(_ channel: ChannelType) -> some View {
        let isConfigured = channelConfigs[channel] ?? false
        Button {
            selectedChannel = channel
            if isConfigured {
                // 渠道已配置，跳过凭据步骤，直接进入绑定匹配
                step = .bindingMatch
            } else if channel.supportsSetupMethodPicker {
                // 飞书：进入配置步骤（提供双路径选择）
                step = .configureCredentials
            } else if channel.usesInteractiveOnboarding {
                // 纯扫码渠道：弹交互式 onboarding 终端
                showQRSheet = true
            } else {
                // Telegram/Discord 等：弹凭据表单
                showCredentialSheet = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    channel.iconView(size: 20, weight: .medium)
                    Spacer()
                    // 配置状态徽章
                    Text(isConfigured
                         ? L10n.k("channel.status.connected", fallback: "已配置")
                         : L10n.k("channel.status.disconnected", fallback: "未配置"))
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isConfigured ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
                        .foregroundStyle(isConfigured ? .green : .secondary)
                        .clipShape(Capsule())
                }
                Text(channel.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(channel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showCredentialSheet) {
            if let ch = selectedChannel {
                ChannelBotConfigSheet(channelType: ch) {
                    // 凭据保存成功后进入绑定匹配步骤
                    channelConfigs[ch] = true
                    step = .bindingMatch
                }
                .environment(gateway)
            }
        }
        .sheet(isPresented: $showQRSheet) {
            if let ch = selectedChannel {
                FeishuChannelOnboardingSheet(
                    flow: ch.onboardingFlow,
                    displayName: "",
                    username: store.username
                )
                .frame(minWidth: 900, minHeight: 560)
                .onDisappear {
                    // QR 窗口关闭后，刷新配置状态并进入绑定步骤
                    Task {
                        await refreshAfterChannelOnboardingClosed()
                        if channelConfigs[ch] == true {
                            step = .bindingMatch
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 2: 配置凭据（飞书双路径）

    @ViewBuilder
    private var credentialConfigStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let channel = selectedChannel, channel == .feishu {
                Text(L10n.k("agent.binding.feishu.choose", fallback: "飞书支持两种接入方式，请选择："))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                VStack(spacing: 12) {
                    // 方式一：QR 扫码
                    Button {
                        showQRSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.k("agent.binding.feishu.qr", fallback: "扫码配对"))
                                    .font(.subheadline).fontWeight(.medium)
                                Text(L10n.k("agent.binding.feishu.qr_desc", fallback: "通过飞书官方工具生成 QR 码，扫码完成配对"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)

                    // 方式二：手动填凭据
                    Button {
                        showCredentialSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.k("agent.binding.feishu.manual", fallback: "手动填写凭据"))
                                    .font(.subheadline).fontWeight(.medium)
                                Text(L10n.k("agent.binding.feishu.manual_desc", fallback: "输入 App ID 和 App Secret（适用于自建应用）"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)

                Spacer()

                HStack {
                    Button(L10n.k("common.back", fallback: "上一步")) {
                        step = .selectChannel
                        selectedChannel = nil
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 16)
        .sheet(isPresented: $showCredentialSheet) {
            if let ch = selectedChannel {
                ChannelBotConfigSheet(channelType: ch) {
                    channelConfigs[ch] = true
                    step = .bindingMatch
                }
                .environment(gateway)
            }
        }
        .sheet(isPresented: $showQRSheet) {
            FeishuChannelOnboardingSheet(
                flow: .feishu,
                displayName: "",
                username: store.username
            )
            .frame(minWidth: 900, minHeight: 560)
            .onDisappear {
                Task {
                    await refreshAfterChannelOnboardingClosed()
                    if let ch = selectedChannel, channelConfigs[ch] == true {
                        step = .bindingMatch
                    }
                }
            }
        }
    }

    // MARK: - Step 3: 绑定匹配条件

    @ViewBuilder
    private var bindingMatchStep: some View {
        Form {
            if let channel = selectedChannel {
                Section {
                    HStack(spacing: 10) {
                        channel.iconView(size: 18, weight: .medium)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.displayName)
                                .font(.subheadline).fontWeight(.medium)
                            Text("此绑定将处理该渠道的默认消息")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(L10n.k("common.back", fallback: "上一步")) {
                    step = .selectChannel
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(L10n.k("agent.binding.add_confirm", fallback: "添加绑定")) {
                    addBinding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdding)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    // MARK: - 数据操作

    private func loadChannelConfigs() async {
        let channelsDict = await loadChannelConfigDictionary()
        let hasFeishuQRCodeCredentials = hasFeishuQRCodeCredentials()
        var result: [ChannelType: Bool] = [:]
        for channel in ChannelType.enabledCases {
            if channel == .feishu, hasFeishuQRCodeCredentials {
                result[channel] = true
                continue
            }
            if let chConfig = channelsDict[channel.rawValue] as? [String: Any] {
                result[channel] = isChannelConfigConfigured(channel, config: chConfig)
            } else {
                result[channel] = false
            }
        }
        channelConfigs = result
        isLoadingConfigs = false
    }

    private func refreshAfterChannelOnboardingClosed() async {
        await loadChannelConfigs()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await loadChannelConfigs()
    }

    private func hasFeishuQRCodeCredentials() -> Bool {
        guard let localPaths = selectedLocalPaths else {
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

    private func isChannelConfigConfigured(_ channel: ChannelType, config: [String: Any]) -> Bool {
        if channel.configFields.isEmpty {
            return !config.isEmpty
        }
        return channel.configFields.contains { field in
            isConfiguredLeafValue(config[field.id])
        }
    }

    private func isConfiguredLeafValue(_ rawValue: Any?) -> Bool {
        switch rawValue {
        case let value as String:
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let value as [String: Any]:
            return !value.isEmpty
        case let value as [Any]:
            return !value.isEmpty
        case nil, is NSNull:
            return false
        default:
            return true
        }
    }

    private func loadLocalChannelConfigDictionary() -> [String: Any] {
        guard let json = selectedLocalPaths?.loadConfigRoot() else { return [:] }
        return json["channels"] as? [String: Any] ?? [:]
    }

    private func loadChannelConfigDictionary() async -> [String: Any] {
        let localChannels = loadLocalChannelConfigDictionary()
        guard gateway.isConnected else { return localChannels }
        do {
            let (config, _) = try await gateway.configGetFull()
            return (config["channels"] as? [String: Any]) ?? localChannels
        } catch {
            appLog("[binding] 读取 gateway 配置失败，回退本地配置: \(error)", level: .warn)
            return localChannels
        }
    }

    private func addBinding() {
        guard let channel = selectedChannel else { return }
        isAdding = true
        let binding = AgentBinding(
            agentId: agentId,
            channel: channel.rawValue,
            accountId: channel == .wecom ? "default" : nil
        )
        Task {
            do {
                try await store.addBinding(binding)
                await restartGatewayAfterBindingMutation()
                dismiss()
            } catch {
                appLog("添加绑定失败: \(error)", level: .error)
                isAdding = false
            }
        }
    }

    private func restartGatewayAfterBindingMutation() async {
        processManager.restart()
    }
}

// MARK: - 步骤枚举

private enum AddBindingStep {
    case selectChannel
    case configureCredentials
    case bindingMatch
}
