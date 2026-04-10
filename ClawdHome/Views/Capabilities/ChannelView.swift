// ClawdHome/Views/Capabilities/ChannelView.swift
// 消息渠道管理：卡片网格布局，支持 5 个渠道的机器人配置

import SwiftUI

struct ChannelView: View {
    @Environment(GatewayService.self) private var gateway
    @State private var configuringChannel: ChannelType?
    @State private var channelConfigs: [ChannelType: [String: String]] = [:]
    @State private var isLoading = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 页面描述
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("channel.page.desc", fallback: "配置 AI 智能体与用户交互的消息平台。所有连接数据存储在本地——无需云端。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L10n.f("channel.page.count", fallback: "%d 个渠道", ChannelType.allCases.count))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                // 渠道卡片网格
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(ChannelType.allCases) { channel in
                        ChannelCardView(
                            channel: channel,
                            isConnected: isChannelConnected(channel),
                            onSetup: { configuringChannel = channel }
                        )
                    }
                }
            }
            .padding(20)
        }
        .navigationTitle(L10n.k("channel.title", fallback: "消息渠道"))
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
        .task { await loadChannelConfigs() }
        .sheet(item: $configuringChannel) { channel in
            if channel.usesInteractiveOnboarding {
                // 微信走 QR 配对流程
                FeishuChannelOnboardingSheet(
                    flow: .weixin,
                    displayName: "",
                    username: NSUserName()
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
}

// MARK: - 渠道卡片

private struct ChannelCardView: View {
    let channel: ChannelType
    let isConnected: Bool
    let onSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 头部：图标 + 名称 + 状态
            channelHeader
            // 统计行
            statsRow
            // 智能体占位区
            agentPlaceholder
            // 底部操作按钮
            actionButton
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    // MARK: - 头部

    @ViewBuilder
    private var channelHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // 渠道图标
            channelIcon
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(channel.displayName)
                        .font(.headline)
                    if let url = channel.howToConnectURL {
                        Link(L10n.k("channel.how_to_connect", fallback: "如何接入？"), destination: url)
                            .font(.caption)
                    }
                }
                Text(channel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // 连接状态徽章
            connectionBadge
        }
    }

    @ViewBuilder
    private var channelIcon: some View {
        Image(systemName: channel.iconName)
            .font(.title)
            .foregroundStyle(iconColor)
            .frame(width: 40, height: 40)
    }

    private var iconColor: Color {
        switch channel.iconColor {
        case "blue":   return .blue
        case "green":  return .green
        case "cyan":   return .cyan
        case "indigo": return .indigo
        default:       return .accentColor
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        Text(isConnected
             ? L10n.k("channel.status.connected", fallback: "已关联")
             : L10n.k("channel.status.disconnected", fallback: "未关联"))
            .font(.caption2)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isConnected ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
            .foregroundStyle(isConnected ? .green : .secondary)
            .clipShape(Capsule())
    }

    // MARK: - 统计行

    @ViewBuilder
    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem(label: L10n.k("channel.stat.paired_users", fallback: "已配对\n用户"), value: "0")
            Divider().frame(height: 30)
            if channel.supportsGroupChat {
                statItem(label: L10n.k("channel.stat.paired_groups", fallback: "已配对\n群聊"), value: "0")
            } else {
                statItem(label: L10n.k("channel.stat.no_group", fallback: "不支持群聊配\n对"), value: nil)
            }
            Divider().frame(height: 30)
            statItem(label: L10n.k("channel.stat.pending", fallback: "待处理\n请求"), value: "0")
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statItem(label: String, value: String?) -> some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let value {
                Text(value)
                    .font(.title3)
                    .fontWeight(.medium)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 智能体占位区

    @ViewBuilder
    private var agentPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.k("channel.agent.placeholder.title", fallback: "请配置智能体"))
                    .font(.callout)
                    .fontWeight(.medium)
                Text(L10n.k("channel.agent.placeholder.desc", fallback: "选择一个智能体来处理此渠道的消息"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .foregroundStyle(Color(nsColor: .separatorColor))
        )
    }

    // MARK: - 底部操作按钮

    @ViewBuilder
    private var actionButton: some View {
        Button {
            onSetup()
        } label: {
            HStack {
                if !channel.usesInteractiveOnboarding {
                    Image(systemName: "sparkles")
                        .font(.caption)
                }
                Text(channel.actionButtonTitle)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }
}
