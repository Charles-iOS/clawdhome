// ClawdHome/Views/Sidebar/SidebarView.swift

import SwiftUI

enum SidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case dashboard
    case agents
    case models
    case cron
    case skills
    case channels
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dashboard: return L10n.k("sidebar.dashboard", fallback: "仪表盘")
        case .agents:    return L10n.k("sidebar.agents", fallback: "智能体")
        case .models:    return L10n.k("sidebar.models", fallback: "模型")
        case .cron:      return L10n.k("sidebar.cron", fallback: "定时任务")
        case .skills:    return L10n.k("sidebar.skills", fallback: "技能")
        case .channels:  return L10n.k("sidebar.channels", fallback: "消息渠道")
        case .settings:  return L10n.k("sidebar.settings", fallback: "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .agents:    return "person.2.fill"
        case .models:    return "cpu.fill"
        case .cron:      return "clock.fill"
        case .skills:    return "wrench.and.screwdriver.fill"
        case .channels:  return "bubble.left.and.bubble.right.fill"
        case .settings:  return "gearshape.fill"
        }
    }

    var section: SidebarSection {
        switch self {
        case .dashboard: return .overview
        case .agents, .models: return .configuration
        case .cron, .skills, .channels: return .capabilities
        case .settings: return .system
        }
    }
}

enum SidebarSection: String, CaseIterable {
    case overview
    case configuration
    case capabilities
    case system

    var label: String {
        switch self {
        case .overview:       return L10n.k("sidebar.section.overview", fallback: "概览")
        case .configuration:  return L10n.k("sidebar.section.config", fallback: "配置")
        case .capabilities:   return L10n.k("sidebar.section.capabilities", fallback: "能力")
        case .system:         return L10n.k("sidebar.section.system", fallback: "系统")
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    @Environment(GatewayProcessManager.self) private var processManager

    var body: some View {
        List(selection: $selection) {
            ForEach(SidebarSection.allCases, id: \.self) { section in
                let items = SidebarDestination.allCases.filter { $0.section == section }
                Section(section.label) {
                    ForEach(items) { dest in
                        Label(dest.label, systemImage: dest.systemImage)
                            .tag(dest)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            gatewayStatus
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var gatewayStatus: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch processManager.state {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch processManager.state {
        case .running: return L10n.k("sidebar.status.running", fallback: "Gateway 运行中")
        case .starting: return L10n.k("sidebar.status.starting", fallback: "Gateway 启动中…")
        case .stopped: return L10n.k("sidebar.status.stopped", fallback: "Gateway 已停止")
        case .failed(let msg): return msg
        }
    }
}
