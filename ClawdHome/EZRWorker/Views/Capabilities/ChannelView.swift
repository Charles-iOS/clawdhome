// ClawdHome/Views/Capabilities/ChannelView.swift
// 消息渠道管理：卡片网格布局，支持各渠道的机器人配置 + 智能体绑定

import SwiftUI

private enum ChannelConnectionStatus {
    case disconnected
    case connected
    case disabled

    var isConfigured: Bool {
        self != .disconnected
    }

    var badgeTitle: String {
        switch self {
        case .disconnected:
            return L10n.k("channel.status.disconnected", fallback: "未关联")
        case .connected:
            return L10n.k("channel.status.connected", fallback: "已关联")
        case .disabled:
            return "已禁用"
        }
    }

    var badgeBackgroundColor: Color {
        switch self {
        case .disconnected:
            return Color.secondary.opacity(0.1)
        case .connected:
            return Color.green.opacity(0.12)
        case .disabled:
            return Color.orange.opacity(0.12)
        }
    }

    var badgeForegroundColor: Color {
        switch self {
        case .disconnected:
            return .secondary
        case .connected:
            return .green
        case .disabled:
            return .orange
        }
    }
}

struct ChannelView: View {
    private enum ChannelSetupDestination: Identifiable {
        case methodPicker(ChannelType)
        case interactive(ChannelType)
        case credentials(ChannelType)
        case channelConfig(ChannelType)

        var id: String {
            switch self {
            case .methodPicker(let channel): return "picker-\(channel.rawValue)"
            case .interactive(let channel): return "interactive-\(channel.rawValue)"
            case .credentials(let channel): return "credentials-\(channel.rawValue)"
            case .channelConfig(let channel): return "config-\(channel.rawValue)"
            }
        }
    }

    @Environment(GatewayService.self) private var gateway
    @Environment(AgentStore.self) private var agentStore
    @Environment(GatewayProcessManager.self) private var processManager
    @State private var setupDestination: ChannelSetupDestination?
    @State private var channelConfigs: [ChannelType: [String: String]] = [:]
    @State private var channelEnabledStates: [ChannelType: Bool] = [:]
    @State private var pairingStats: [ChannelType: ChannelPairingStats] = [:]
    @State private var isLoading = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                PageHeroHeader(
                    title: L10n.k("channel.title", fallback: "消息渠道"),
                    subtitle: L10n.k("channel.page.desc", fallback: "配置 AI 智能体与用户交互的消息平台。所有连接数据存储在本地——无需云端。"),
                    subtitleLineLimit: 4
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.f("channel.page.count", fallback: "%d 个渠道", ChannelType.enabledCases.count))
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                // 渠道卡片网格
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ChannelType.enabledCases) { channel in
                        ChannelCardView(
                            channel: channel,
                            connectionStatus: channelConnectionStatus(for: channel),
                            pairingStats: pairingStats[channel],
                            bindings: agentStore.bindings.filter { $0.channel == channel.rawValue },
                            agents: agentStore.agents,
                            onSetup: { setupDestination = initialSetupDestination(for: channel) },
                            onRemoveBinding: { binding in
                                Task {
                                    do {
                                        try await agentStore.removeBinding(binding)
                                        await restartGatewayAfterBindingMutation()
                                    } catch {
                                        appLog("[channel] 移除绑定失败: \(error)", level: .error)
                                    }
                                }
                            }
                        )
                    }
                }
            }
            .padding(20)
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await reloadChannelState() }
                } label: {
                    Label(L10n.k("common.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .disabled(!gateway.isConnected || isLoading)
            }
        }
        .task(id: gateway.isConnected) {
            await reloadChannelState()
        }
        .onReceive(NotificationCenter.default.publisher(for: .channelOnboardingAutoDetected)) { notification in
            guard let userInfo = notification.userInfo,
                  let username = userInfo["username"] as? String,
                  username == agentStore.username,
                  let flow = userInfo["flow"] as? String,
                  flow == ChannelOnboardingFlow.feishu.rawValue || flow == ChannelOnboardingFlow.wecom.rawValue else { return }
            Task { await refreshAfterPairingSuccess() }
        }
        .sheet(item: $setupDestination) { destination in
            switch destination {
            case .methodPicker(let channel):
                ChannelSetupMethodPickerSheet(channel: channel) { action in
                    switch action {
                    case .interactive:
                        setupDestination = .interactive(channel)
                    case .credentials:
                        setupDestination = .credentials(channel)
                    }
                }
                .frame(minWidth: 520, minHeight: 300)

            case .interactive(let channel):
                FeishuChannelOnboardingSheet(
                    flow: channel.onboardingFlow,
                    displayName: "",
                    username: agentStore.username
                )
                .frame(minWidth: 900, minHeight: 560)
                .onDisappear {
                    Task { await refreshAfterPairingSuccess() }
                }

            case .credentials(let channel):
                ChannelBotConfigSheet(channelType: channel) {
                    Task { await reloadChannelState() }
                }
                .environment(gateway)

            case .channelConfig(let channel):
                if channel == .feishu {
                    FeishuChannelConfigSheet(username: agentStore.username) {
                        Task { await reloadChannelState() }
                    }
                    .environment(gateway)
                } else if channel == .telegram {
                    TelegramChannelConfigSheet {
                        Task { await reloadChannelState() }
                    }
                    .environment(gateway)
                }
            }
        }
    }

    private func initialSetupDestination(for channel: ChannelType) -> ChannelSetupDestination {
        if channel.usesIntegratedConfigSheet, channelConnectionStatus(for: channel).isConfigured {
            return .channelConfig(channel)
        }
        if channel.supportsSetupMethodPicker {
            return .methodPicker(channel)
        }
        if channel.usesInteractiveOnboarding {
            return .interactive(channel)
        }
        return .credentials(channel)
    }

    /// 判断渠道是否已配置凭据
    private func isChannelConnected(_ channel: ChannelType) -> Bool {
        guard let config = channelConfigs[channel] else { return false }
        // 有任一非空凭据字段即视为已关联；飞书扫码模式会注入本地凭据标记字段。
        return config.values.contains(where: { !$0.isEmpty })
    }

    private func isChannelEnabled(_ channel: ChannelType) -> Bool {
        channelEnabledStates[channel] ?? true
    }

    private func channelConnectionStatus(for channel: ChannelType) -> ChannelConnectionStatus {
        guard isChannelConnected(channel) else { return .disconnected }
        if !isChannelEnabled(channel) {
            return .disabled
        }
        return .connected
    }

    private func reloadChannelState() async {
        await loadChannelConfigs()
        await loadPairingStats()
    }

    private func refreshAfterPairingSuccess() async {
        await reloadChannelState()
        // 配对成功提示可能早于配置文件最终落盘，短暂补拉一次避免徽章延迟。
        try? await Task.sleep(nanoseconds: 800_000_000)
        await reloadChannelState()
    }

    private func restartGatewayAfterBindingMutation() async {
        processManager.restart()
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        await reloadChannelState()
    }

    /// 从 gateway config 加载各渠道的配置状态
    private func loadChannelConfigs() async {
        isLoading = true
        defer { isLoading = false }

        let channelsDict = await loadChannelConfigDictionary()
        let hasFeishuQRCodeCredentials = hasFeishuQRCodeCredentials()

        var result: [ChannelType: [String: String]] = [:]
        var enabledStates: [ChannelType: Bool] = [:]
        for channel in ChannelType.enabledCases {
            var fields: [String: String] = [:]
            if let chConfig = channelsDict[channel.rawValue] as? [String: Any] {
                enabledStates[channel] = chConfig["enabled"] as? Bool ?? true
                for field in channel.configFields {
                    if let value = chConfig[field.id] as? String, !value.isEmpty {
                        fields[field.id] = value
                    }
                }
                if channel.configFields.isEmpty, !chConfig.isEmpty {
                    fields["configured"] = "true"
                }
            } else {
                enabledStates[channel] = true
            }
            if channel == .feishu, hasFeishuQRCodeCredentials {
                fields["qrPaired"] = "true"
            }
            if !fields.isEmpty {
                result[channel] = fields
            }
        }
        channelConfigs = result
        channelEnabledStates = enabledStates
    }

    private func hasFeishuQRCodeCredentials() -> Bool {
        let credFile = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("credentials")
            .appendingPathComponent("lark.secrets.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: credFile.path),
              let fileSize = attrs[.size] as? NSNumber else {
            return false
        }
        return fileSize.intValue > 0
    }

    private func loadLocalChannelConfigDictionary() -> [String: Any] {
        let configURL = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("openclaw.json")
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json["channels"] as? [String: Any] ?? [:]
    }

    private func loadChannelConfigDictionary() async -> [String: Any] {
        let localChannels = loadLocalChannelConfigDictionary()
        guard gateway.isConnected else { return localChannels }
        do {
            let (config, _) = try await gateway.configGetFull()
            return (config["channels"] as? [String: Any]) ?? localChannels
        } catch {
            appLog("[channel] 读取 gateway 配置失败，回退本地配置: \(error)", level: .warn)
            return localChannels
        }
    }

    /// 直接读取本地 JSON 文件加载配对统计（无需启动 Node 进程）
    private func loadPairingStats() async {
        let credDir = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("credentials")
        var result: [ChannelType: ChannelPairingStats] = [:]

        for channel in ChannelType.enabledCases where channelConnectionStatus(for: channel).isConfigured {
            result[channel] = ChannelPairingStats(
                directCount: ChannelPairingDataLoader.approvedPeerIDs(
                    for: channel,
                    credentialsDirectory: credDir
                ).count,
                pendingCount: ChannelPairingDataLoader.pendingRequests(
                    for: channel,
                    credentialsDirectory: credDir
                ).count
            )
        }

        pairingStats = result
    }
}

private struct ChannelSetupMethodPickerSheet: View {
    enum SetupAction {
        case interactive
        case credentials
    }

    let channel: ChannelType
    let onSelect: (SetupAction) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(channel.displayName)支持两种接入方式，请选择：")
                        .font(.title3.weight(.semibold))
                    Text("扫码适合快速绑定，手动填写适合自建应用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }

            VStack(spacing: 12) {
                methodCard(
                    icon: "qrcode.viewfinder",
                    accent: .blue,
                    title: L10n.k("agent.binding.feishu.qr", fallback: "扫码配对"),
                    description: L10n.k("agent.binding.feishu.qr_desc", fallback: "通过飞书官方工具生成 QR 码，扫码完成配对")
                ) {
                    onSelect(.interactive)
                }

                methodCard(
                    icon: "key.fill",
                    accent: .orange,
                    title: L10n.k("agent.binding.feishu.manual", fallback: "手动填写凭据"),
                    description: L10n.k("agent.binding.feishu.manual_desc", fallback: "输入 App ID 和 App Secret（适用于自建应用）")
                ) {
                    onSelect(.credentials)
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func methodCard(
        icon: String,
        accent: Color,
        title: String,
        description: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(accent)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 配对统计

struct ChannelPairingStats {
    var directCount: Int
    var pendingCount: Int
}

// MARK: - 渠道卡片

private struct ChannelCardView: View {
    /// 卡片内字号（macOS 上语义字体变化不明显，用固定 pt 保证可读性）
    private enum FontSize {
        static let icon: CGFloat = 26
        static let title: CGFloat = 20
        static let subtitle: CGFloat = 15
        static let link: CGFloat = 14
        static let badge: CGFloat = 13
        static let statLabel: CGFloat = 13
        static let statValue: CGFloat = 26
        static let placeholderTitle: CGFloat = 17
        static let placeholderDesc: CGFloat = 14
        static let smallControl: CGFloat = 15
        static let agentEmoji: CGFloat = 22
        static let agentName: CGFloat = 15
        static let agentMeta: CGFloat = 13
        static let pairing: CGFloat = 15
        static let action: CGFloat = 16
    }

    /// 网格内卡片统一高度（须 ≥ 头/统计/智能体区/配对行/主按钮 之和，否则底部按钮会被裁掉）
    private static let cardHeightWithPairing: CGFloat = 452
    private static let cardHeightWithoutPairing: CGFloat = 396
    /// 智能体区域固定高度，多绑定时内部滚动
    private static let agentAreaHeight: CGFloat = 148
    /// 与 `pairingButton` 视觉高度对齐，未关联时占位
    private static let pairingRowReservedHeight: CGFloat = 42

    let channel: ChannelType
    let connectionStatus: ChannelConnectionStatus
    let pairingStats: ChannelPairingStats?
    let bindings: [AgentBinding]
    let agents: [Agent]
    let onSetup: () -> Void
    let onRemoveBinding: (AgentBinding) -> Void

    @Environment(GatewayService.self) private var gateway
    @Environment(AgentStore.self) private var agentStore
    @State private var showAgentPicker = false
    @State private var showPairingSheet = false

    private var isConfigured: Bool {
        connectionStatus.isConfigured
    }

    private var cardHeight: CGFloat {
        channel.showsStandalonePairingEntry ? Self.cardHeightWithPairing : Self.cardHeightWithoutPairing
    }

    private var pairedUsersStatValue: String {
        channel == .wecom ? "–" : (pairingStats.map { "\($0.directCount)" } ?? "–")
    }

    private var pendingRequestsStatValue: String {
        channel == .wecom ? "–" : (pairingStats.map { "\($0.pendingCount)" } ?? "–")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // 头部：图标 + 名称 + 状态
            channelHeader
            // 统计行
            statsRow
            // 智能体绑定区（固定高度）
            agentBindingArea
                .frame(height: Self.agentAreaHeight)
            // 配对管理入口：未关联时保留占位，保证卡片等高
            Group {
                if channel.showsStandalonePairingEntry {
                    if isConfigured {
                        pairingButton
                    } else {
                        Color.clear
                            .frame(height: Self.pairingRowReservedHeight)
                    }
                }
            }
            Spacer(minLength: 0)
            // 底部操作按钮
            actionButton
        }
        .frame(maxWidth: .infinity, minHeight: cardHeight, maxHeight: cardHeight, alignment: .top)
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .sheet(isPresented: $showAgentPicker) {
            ChannelAgentPickerSheet(
                channelType: channel,
                agents: agents,
                existingBindings: bindings
            )
        }
        .sheet(isPresented: $showPairingSheet) {
            ChannelPairingSheet(channelType: channel)
                .environment(gateway)
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var channelHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // 渠道图标
            channel.iconView(size: FontSize.icon, weight: .medium)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.system(size: FontSize.title, weight: .semibold))
                    if let url = channel.howToConnectURL {
                        Link(L10n.k("channel.how_to_connect", fallback: "如何接入？"), destination: url)
                            .font(.system(size: FontSize.link))
                    }
                }
                Text(channel.subtitle)
                    .font(.system(size: FontSize.subtitle))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 连接状态徽章
            Text(connectionStatus.badgeTitle)
                .font(.system(size: FontSize.badge, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(connectionStatus.badgeBackgroundColor)
                .foregroundStyle(connectionStatus.badgeForegroundColor)
                .clipShape(Capsule())
        }
    }

    // MARK: - 统计行

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(
                label: L10n.k("channel.stat.paired_users", fallback: "已配对\n用户"),
                value: pairedUsersStatValue
            )
            Divider().frame(height: 40)
            statItem(
                label: L10n.k("channel.stat.pending", fallback: "待处理\n请求"),
                value: pendingRequestsStatValue
            )
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statItem(label: String, value: String?) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: FontSize.statLabel))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let value {
                Text(value)
                    .font(.system(size: FontSize.statValue, weight: .medium))
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 智能体绑定区

    @ViewBuilder
    private var agentBindingArea: some View {
        if bindings.isEmpty {
            // 未绑定：占位卡片，可点击
            Button { showAgentPicker = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus")
                        .font(.system(size: FontSize.smallControl, weight: .medium))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.k("channel.agent.placeholder.title", fallback: "请配置数字员工"))
                            .font(.system(size: FontSize.placeholderTitle, weight: .semibold))
                        Text(L10n.k("channel.agent.placeholder.desc", fallback: "选择一个数字员工来处理此渠道的消息"))
                            .font(.system(size: FontSize.placeholderDesc))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: FontSize.smallControl, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                )
                .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .buttonStyle(.plain)
        } else if bindings.count == 1, let binding = bindings.first {
            singleBoundAgentCard(binding)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            // 已绑定：展示智能体列表（固定高度内滚动）
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(bindings) { binding in
                        boundAgentRow(binding)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func singleBoundAgentCard(_ binding: AgentBinding) -> some View {
        let agent = agents.first(where: { $0.id == binding.agentId })
        VStack(alignment: .leading, spacing: 12) {
            Text("当前绑定数字员工")
                .font(.system(size: FontSize.agentMeta, weight: .medium))
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Text(agent?.emoji ?? "🤖")
                    .font(.system(size: 34))
                    .frame(width: 48, height: 48)
                    .background(Color.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(agent?.name ?? binding.agentId)
                        .font(.system(size: 22, weight: .semibold))
                    if let peer = binding.peerId {
                        Text("\(binding.peerKind ?? "peer") · \(peer)")
                            .font(.system(size: FontSize.agentMeta))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("处理此渠道的默认消息")
                            .font(.system(size: FontSize.agentMeta))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button {
                    onRemoveBinding(binding)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: FontSize.smallControl + 3))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    channel.swiftUIColor.opacity(0.10),
                    Color(nsColor: .windowBackgroundColor).opacity(0.75),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(channel.swiftUIColor.opacity(0.14), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func boundAgentRow(_ binding: AgentBinding) -> some View {
        let agent = agents.first(where: { $0.id == binding.agentId })
        HStack(spacing: 10) {
            Text(agent?.emoji ?? "🤖")
                .font(.system(size: FontSize.agentEmoji))
            VStack(alignment: .leading, spacing: 2) {
                Text(agent?.name ?? binding.agentId)
                    .font(.system(size: FontSize.agentName, weight: .semibold))
                if let peer = binding.peerId {
                    Text("\(binding.peerKind ?? "peer"):\(peer)")
                        .font(.system(size: FontSize.agentMeta))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                onRemoveBinding(binding)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: FontSize.smallControl + 1))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 配对管理入口

    @ViewBuilder
    private var pairingButton: some View {
        Button { showPairingSheet = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: FontSize.pairing))
                    .foregroundStyle(channel.swiftUIColor)
                Text("配对管理")
                    .font(.system(size: FontSize.pairing, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: FontSize.agentMeta, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部操作按钮

    @ViewBuilder
    private var actionButton: some View {
        Button {
            onSetup()
        } label: {
            HStack(spacing: 8) {
                if !channel.usesInteractiveOnboarding {
                    Image(systemName: "sparkles")
                        .font(.system(size: FontSize.smallControl))
                }
                Text(channel.actionButtonTitle)
                    .font(.system(size: FontSize.action, weight: .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

// MARK: - 智能体选择 Sheet（从渠道侧选择智能体创建绑定）

struct ChannelAgentPickerSheet: View {
    private enum PickerFont {
        static let headerIcon: CGFloat = 24
        static let headerTitle: CGFloat = 20
        static let headerSubtitle: CGFloat = 15
        static let sectionTitle: CGFloat = 15
        static let emoji: CGFloat = 22
        static let name: CGFloat = 15
        static let desc: CGFloat = 13
        static let badge: CGFloat = 12
        static let checkmark: CGFloat = 18
        static let fieldLabel: CGFloat = 13
        static let footerButton: CGFloat = 16
    }

    let channelType: ChannelType
    let agents: [Agent]
    let existingBindings: [AgentBinding]

    @Environment(AgentStore.self) private var store
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAgentId: String?
    @State private var searchText = ""
    @State private var isAdding = false

    private var filteredAgents: [Agent] {
        if searchText.isEmpty { return agents }
        let q = searchText.lowercased()
        return agents.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    private var defaultBindingAccountId: String? {
        // WeCom plugin resolves the single-account runtime as accountId=default,
        // so channel-level bindings need an explicit account scope to be matched.
        channelType == .wecom ? "default" : nil
    }

    /// 已绑定到此渠道的智能体 ID 集合
    private var boundAgentIds: Set<String> {
        Set(existingBindings.map(\.agentId))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            pickerHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    pickerAgentSection
                }
                .padding(20)
            }
            Divider()
            pickerBottomBar
        }
        .frame(minWidth: 520, minHeight: 520)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var pickerHeader: some View {
        HStack(spacing: 12) {
            channelType.iconView(size: PickerFont.headerIcon, weight: .medium)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.f("channel.picker.title", fallback: "%@ · 绑定数字员工", channelType.displayName))
                    .font(.system(size: PickerFont.headerTitle, weight: .semibold))
                Text("选择一个数字员工处理此渠道消息。")
                    .font(.system(size: PickerFont.headerSubtitle))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(20)
    }

    @ViewBuilder
    private var pickerAgentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.k("channel.picker.agent", fallback: "选择数字员工"))
                .font(.system(size: PickerFont.sectionTitle, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(L10n.k("channel.picker.search", fallback: "搜索数字员工…"), text: $searchText)
                .textFieldStyle(.roundedBorder)

            VStack(spacing: 8) {
                ForEach(filteredAgents) { agent in
                    let isBound = boundAgentIds.contains(agent.id)
                    let isSelected = selectedAgentId == agent.id
                    agentOptionRow(agent: agent, isBound: isBound, isSelected: isSelected)
                }
            }
        }
    }

    @ViewBuilder
    private func agentOptionRow(agent: Agent, isBound: Bool, isSelected: Bool) -> some View {
        let backgroundColor = isSelected
            ? channelType.swiftUIColor.opacity(0.10)
            : Color(nsColor: .windowBackgroundColor).opacity(0.6)
        let borderColor = isSelected
            ? channelType.swiftUIColor.opacity(0.30)
            : Color(nsColor: .separatorColor)
        let borderWidth: CGFloat = isSelected ? 1 : 0.5

        Button {
            selectedAgentId = agent.id
        } label: {
            HStack(spacing: 12) {
                Text(agent.emoji)
                    .font(.system(size: PickerFont.emoji))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text(agent.name)
                        .font(.system(size: PickerFont.name, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.system(size: PickerFont.desc))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if isBound {
                    Text(L10n.k("channel.picker.already_bound", fallback: "已绑定"))
                        .font(.system(size: PickerFont.badge, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.10))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: PickerFont.checkmark))
                    .foregroundStyle(isSelected ? channelType.swiftUIColor : Color.secondary.opacity(0.5))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundColor)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(borderColor, lineWidth: borderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var pickerBottomBar: some View {
        HStack {
            Spacer()
            Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                .font(.system(size: PickerFont.footerButton, weight: .semibold))
                .buttonStyle(.bordered)
            Button(L10n.k("agent.binding.add_confirm", fallback: "添加绑定")) {
                addBinding()
            }
            .font(.system(size: PickerFont.footerButton, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .tint(channelType.swiftUIColor)
            .disabled(selectedAgentId == nil || isAdding)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func addBinding() {
        guard let agentId = selectedAgentId else { return }
        isAdding = true
        let binding = AgentBinding(
            agentId: agentId,
            channel: channelType.rawValue,
            accountId: defaultBindingAccountId
        )
        Task {
            do {
                try await store.addBinding(binding)
                await restartGatewayAfterBindingMutation()
                dismiss()
            } catch {
                appLog("[channel] 添加绑定失败: \(error)", level: .error)
                isAdding = false
            }
        }
    }

    private func restartGatewayAfterBindingMutation() async {
        processManager.restart()
    }
}
