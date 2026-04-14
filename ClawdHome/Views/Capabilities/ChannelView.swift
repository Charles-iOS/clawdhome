// ClawdHome/Views/Capabilities/ChannelView.swift
// 消息渠道管理：卡片网格布局，支持各渠道的机器人配置 + 智能体绑定

import SwiftUI

struct ChannelView: View {
    @Environment(GatewayService.self) private var gateway
    @Environment(AgentStore.self) private var agentStore
    @State private var configuringChannel: ChannelType?
    @State private var channelConfigs: [ChannelType: [String: String]] = [:]
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
                Text(L10n.f("channel.page.count", fallback: "%d 个渠道", ChannelType.allCases.count))
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                // 渠道卡片网格
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ChannelType.allCases) { channel in
                        ChannelCardView(
                            channel: channel,
                            isConnected: isChannelConnected(channel),
                            pairingStats: pairingStats[channel],
                            bindings: agentStore.bindings.filter { $0.channel == channel.rawValue },
                            agents: agentStore.agents,
                            onSetup: { configuringChannel = channel },
                            onRemoveBinding: { binding in
                                Task { try? await agentStore.removeBinding(binding) }
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
                    Task { await loadChannelConfigs() }
                } label: {
                    Label(L10n.k("common.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .disabled(!gateway.isConnected || isLoading)
            }
        }
        .task {
            await loadChannelConfigs()
            await loadPairingStats()
        }
        .sheet(item: $configuringChannel) { channel in
            if channel.usesInteractiveOnboarding {
                // 微信走 QR 配对流程
                FeishuChannelOnboardingSheet(
                    flow: .weixin,
                    displayName: "",
                    username: agentStore.username
                )
                .frame(minWidth: 900, minHeight: 460)
            } else {
                ChannelBotConfigSheet(channelType: channel) {
                    Task { await loadChannelConfigs() }
                }
                .environment(gateway)
            }
        }
    }

    /// 判断渠道是否已配置凭据
    private func isChannelConnected(_ channel: ChannelType) -> Bool {
        guard let config = channelConfigs[channel] else { return false }
        // 有任一非空凭据字段即视为已关联
        return config.values.contains(where: { !$0.isEmpty })
    }

    /// 从 gateway config 加载各渠道的配置状态
    private func loadChannelConfigs() async {
        guard gateway.isConnected else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let (config, _) = try await gateway.configGetFull()
            let channelsDict = config["channels"] as? [String: Any] ?? [:]

            var result: [ChannelType: [String: String]] = [:]
            for channel in ChannelType.allCases {
                guard let chConfig = channelsDict[channel.rawValue] as? [String: Any] else { continue }
                var fields: [String: String] = [:]
                for field in channel.configFields {
                    if let value = chConfig[field.id] as? String, !value.isEmpty {
                        fields[field.id] = value
                    }
                }
                if !fields.isEmpty {
                    result[channel] = fields
                }
            }
            channelConfigs = result
        } catch {
            appLog("[channel] 加载渠道配置失败: \(error)", level: .error)
        }
    }

    /// 直接读取本地 JSON 文件加载配对统计（无需启动 Node 进程）
    private func loadPairingStats() async {
        let credDir = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("credentials")
        let fm = FileManager.default

        for channel in ChannelType.allCases where isChannelConnected(channel) {
            let ch = channel.rawValue
            var pendingCount = 0
            var approvedCount = 0

            // 待审批：<channel>-pairing.json → { requests: [...] }
            let pairingFile = credDir.appendingPathComponent("\(ch)-pairing.json")
            if let data = fm.contents(atPath: pairingFile.path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let requests = json["requests"] as? [Any] {
                pendingCount = requests.count
            }

            // 已配对：<channel>-*-allowFrom.json → { allowFrom: [...] }
            let prefix = "\(ch)-"
            let suffix = "-allowFrom.json"
            if let entries = try? fm.contentsOfDirectory(atPath: credDir.path) {
                for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
                    let filePath = credDir.appendingPathComponent(entry)
                    if let data = fm.contents(atPath: filePath.path),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let allowFrom = json["allowFrom"] as? [Any] {
                        approvedCount += allowFrom.count
                    }
                }
            }

            pairingStats[channel] = ChannelPairingStats(
                directCount: approvedCount,
                groupCount: 0,
                pendingCount: pendingCount
            )
        }
    }
}

// MARK: - 配对统计

struct ChannelPairingStats {
    var directCount: Int
    var groupCount: Int
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
    private static let cardHeight: CGFloat = 452
    /// 智能体区域固定高度，多绑定时内部滚动
    private static let agentAreaHeight: CGFloat = 148
    /// 与 `pairingButton` 视觉高度对齐，未关联时占位
    private static let pairingRowReservedHeight: CGFloat = 42

    let channel: ChannelType
    let isConnected: Bool
    let pairingStats: ChannelPairingStats?
    let bindings: [AgentBinding]
    let agents: [Agent]
    let onSetup: () -> Void
    let onRemoveBinding: (AgentBinding) -> Void

    @Environment(AgentStore.self) private var agentStore
    @State private var showAgentPicker = false
    @State private var showPairingSheet = false

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
                if isConnected {
                    pairingButton
                } else {
                    Color.clear
                        .frame(height: Self.pairingRowReservedHeight)
                }
            }
            Spacer(minLength: 0)
            // 底部操作按钮
            actionButton
        }
        .frame(maxWidth: .infinity, minHeight: Self.cardHeight, maxHeight: Self.cardHeight, alignment: .top)
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
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var channelHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // 渠道图标
            Image(systemName: channel.iconName)
                .font(.system(size: FontSize.icon, weight: .medium))
                .foregroundStyle(channel.swiftUIColor)
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
            Text(isConnected
                 ? L10n.k("channel.status.connected", fallback: "已关联")
                 : L10n.k("channel.status.disconnected", fallback: "未关联"))
                .font(.system(size: FontSize.badge, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(isConnected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
                .foregroundStyle(isConnected ? .green : .secondary)
                .clipShape(Capsule())
        }
    }

    // MARK: - 统计行

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(
                label: L10n.k("channel.stat.paired_users", fallback: "已配对\n用户"),
                value: pairingStats.map { "\($0.directCount)" } ?? "–"
            )
            Divider().frame(height: 40)
            if channel.supportsGroupChat {
                statItem(
                    label: L10n.k("channel.stat.paired_groups", fallback: "已配对\n群聊"),
                    value: pairingStats.map { "\($0.groupCount)" } ?? "–"
                )
            } else {
                statItem(label: L10n.k("channel.stat.no_group", fallback: "不支持群聊配\n对"), value: nil)
            }
            Divider().frame(height: 40)
            statItem(
                label: L10n.k("channel.stat.pending", fallback: "待处理\n请求"),
                value: pairingStats.map { "\($0.pendingCount)" } ?? "–"
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
                        Text(L10n.k("channel.agent.placeholder.title", fallback: "请配置智能体"))
                            .font(.system(size: FontSize.placeholderTitle, weight: .semibold))
                        Text(L10n.k("channel.agent.placeholder.desc", fallback: "选择一个智能体来处理此渠道的消息"))
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
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // 已绑定：展示智能体列表（固定高度内滚动）
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(bindings) { binding in
                        boundAgentRow(binding)
                    }
                    Button { showAgentPicker = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle")
                                .font(.system(size: FontSize.smallControl))
                            Text(L10n.k("channel.agent.add_more", fallback: "添加更多智能体"))
                                .font(.system(size: FontSize.placeholderDesc))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
        static let emoji: CGFloat = 22
        static let name: CGFloat = 15
        static let desc: CGFloat = 13
        static let badge: CGFloat = 12
        static let checkmark: CGFloat = 18
    }

    let channelType: ChannelType
    let agents: [Agent]
    let existingBindings: [AgentBinding]

    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var selectedAgentId: String?
    @State private var accountId = ""
    @State private var peerId = ""
    @State private var peerKind = ""
    @State private var guildId = ""
    @State private var searchText = ""
    @State private var isAdding = false

    private var filteredAgents: [Agent] {
        if searchText.isEmpty { return agents }
        let q = searchText.lowercased()
        return agents.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    /// 已绑定到此渠道的智能体 ID 集合
    private var boundAgentIds: Set<String> {
        Set(existingBindings.map(\.agentId))
    }

    var body: some View {
        NavigationStack {
            Form {
                // 智能体选择
                Section(L10n.k("channel.picker.agent", fallback: "选择智能体")) {
                    TextField(L10n.k("channel.picker.search", fallback: "搜索智能体…"), text: $searchText)

                    ForEach(filteredAgents) { agent in
                        let isBound = boundAgentIds.contains(agent.id)
                        Button {
                            selectedAgentId = agent.id
                        } label: {
                            HStack(spacing: 10) {
                                Text(agent.emoji)
                                    .font(.system(size: PickerFont.emoji))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(agent.name)
                                        .font(.system(size: PickerFont.name, weight: .medium))
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
                                        .font(.system(size: PickerFont.badge))
                                        .foregroundStyle(.secondary)
                                }
                                if selectedAgentId == agent.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: PickerFont.checkmark))
                                        .foregroundStyle(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                // 可选匹配条件
                Section(L10n.k("channel.picker.match", fallback: "匹配条件（可选）")) {
                    TextField(
                        L10n.k("agent.binding.account_placeholder", fallback: "账号 ID（留空使用默认账号）"),
                        text: $accountId
                    )
                    TextField(
                        L10n.k("agent.binding.peer_id", fallback: "Peer ID（如电话号码、群组 ID）"),
                        text: $peerId
                    )
                    Picker(L10n.k("agent.binding.peer_kind", fallback: "Peer 类型"), selection: $peerKind) {
                        Text(L10n.k("agent.binding.peer_any", fallback: "不限")).tag("")
                        Text(L10n.k("agent.binding.peer_direct", fallback: "私信")).tag("direct")
                        if channelType.supportsGroupChat {
                            Text(L10n.k("agent.binding.peer_group", fallback: "群组")).tag("group")
                        }
                    }
                    if channelType == .discord {
                        TextField("Guild ID", text: $guildId)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.f("channel.picker.title", fallback: "%@ · 绑定智能体", channelType.displayName))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.k("agent.binding.add_confirm", fallback: "添加绑定")) {
                        addBinding()
                    }
                    .disabled(selectedAgentId == nil || isAdding)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 400)
    }

    private func addBinding() {
        guard let agentId = selectedAgentId else { return }
        isAdding = true
        let binding = AgentBinding(
            agentId: agentId,
            channel: channelType.rawValue,
            accountId: accountId.isEmpty ? nil : accountId,
            peerId: peerId.isEmpty ? nil : peerId,
            peerKind: peerKind.isEmpty ? nil : peerKind,
            guildId: guildId.isEmpty ? nil : guildId
        )
        Task {
            do {
                try await store.addBinding(binding)
                dismiss()
            } catch {
                appLog("[channel] 添加绑定失败: \(error)", level: .error)
                isAdding = false
            }
        }
    }
}
