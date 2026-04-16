// ClawdHome/Views/Agent/AgentCardView.swift

import SwiftUI

struct AgentCardView: View {
    let agent: Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 顶部：emoji + 状态 + 自定义标记
            HStack(spacing: 8) {
                Text(agent.emoji)
                    .font(.title)
                statusBadge
                Spacer()
                if !agent.isPreset {
                    Image(systemName: "person.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // 名称
            Text(agent.name)
                .font(.headline)
                .lineLimit(1)

            // 描述
            Text(agent.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            // 底部：渠道绑定图标 + 技能标签
            HStack(spacing: 6) {
                // 渠道绑定图标
                if !agent.boundBindings.isEmpty {
                    HStack(spacing: 2) {
                        ForEach(uniqueChannelIcons, id: \.self) { icon in
                            Image(systemName: icon)
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }

                // 技能标签
                ForEach(agent.skills.prefix(3), id: \.self) { skill in
                    Text("#\(skill)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            // session 统计
            if agent.sessionCount > 0 {
                Text(L10n.k("agent.card.sessions", fallback: "\(agent.sessionCount) 个会话"))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: borderWidth)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 状态徽章

    @ViewBuilder
    private var statusBadge: some View {
        switch agent.status {
        case .active:
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                Text(L10n.k("agent.status.active", fallback: "运行中"))
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
            }
        case .idle:
            HStack(spacing: 3) {
                Circle()
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(L10n.k("agent.status.idle", fallback: "空闲"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        case .uninitialized:
            HStack(spacing: 3) {
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                    .frame(width: 7, height: 7)
                Text(L10n.k("agent.status.uninitialized", fallback: "未初始化"))
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 辅助

    private var borderColor: Color {
        switch agent.status {
        case .active: return .green
        case .idle: return .clear
        case .uninitialized: return .clear
        }
    }

    private var borderWidth: CGFloat {
        agent.status == .active ? 2 : 0
    }

    /// 去重后的渠道图标列表
    private var uniqueChannelIcons: [String] {
        Array(Set(agent.boundBindings.map(\.channelIcon)))
    }
}
