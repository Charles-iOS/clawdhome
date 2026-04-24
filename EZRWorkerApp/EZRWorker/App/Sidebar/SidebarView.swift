// EZRWorkerApp/Views/Sidebar/SidebarView.swift

import SwiftUI

enum SidebarDestination: String, Hashable, CaseIterable, Identifiable {
    case agents
    case cron
    case skills
    case channels
    case models
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agents:    return L10n.k("sidebar.people", fallback: "数字员工")
        case .cron:      return L10n.k("sidebar.cron", fallback: "定时任务")
        case .skills:    return L10n.k("sidebar.skills", fallback: "技能")
        case .channels:  return L10n.k("sidebar.channels", fallback: "消息渠道")
        case .models:    return L10n.k("sidebar.models", fallback: "模型")
        case .settings:  return L10n.k("sidebar.settings", fallback: "设置")
        }
    }

    var systemImage: String {
        switch self {
        case .agents:    return "person.2.fill"
        case .cron:      return "clock.fill"
        case .skills:    return "wrench.and.screwdriver.fill"
        case .channels:  return "bubble.left.and.bubble.right.fill"
        case .models:    return "cpu.fill"
        case .settings:  return "gearshape.fill"
        }
    }

    var section: SidebarSection {
        switch self {
        case .agents: return .configuration
        case .cron, .skills, .channels, .models: return .capabilities
        case .settings: return .system
        }
    }
}

enum SidebarSection: String, CaseIterable {
    case configuration
    case capabilities
    case system

    var label: String {
        switch self {
        case .configuration:  return L10n.k("sidebar.section.people", fallback: "数字员工")
        case .capabilities:   return L10n.k("sidebar.section.capabilities", fallback: "能力")
        case .system:         return L10n.k("sidebar.section.system", fallback: "系统")
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarDestination?
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(GatewayService.self) private var gatewayService
    @Environment(GatewayProfileStore.self) private var profileStore

    var body: some View {
        List(selection: $selection) {
            ForEach(Array(SidebarSection.allCases.enumerated()), id: \.element) { index, section in
                let items = SidebarDestination.allCases.filter { $0.section == section }
                Section {
                    ForEach(items) { dest in
                        Label(dest.label, systemImage: dest.systemImage)
                            .font(.system(size: 18))
                            .labelStyle(SidebarItemLabelStyle())
                            .tag(dest)
                    }
                } header: {
                    if index == 0 {
                        Color.clear
                            .frame(height: 12)
                    } else {
                        Text(section.label)
                            .font(.system(size: 18))
                            .padding(.top, 10)
                            .padding(.bottom, 10)
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
        VStack(alignment: .leading, spacing: 4) {
            if let selectedProfile = profileStore.selectedProfile {
                Text(selectedProfile.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch processManager.state {
        case .running: return gatewayService.isConnected ? .green : .orange
        case .stopping: return .orange
        case .starting: return .orange
        case .stopped: return .secondary
        case .failed: return .red
        }
    }

    private var statusText: String {
        switch processManager.state {
        case .running:
            return gatewayService.isConnected
                ? L10n.k("sidebar.status.running", fallback: "Gateway 运行中")
                : L10n.k("models.not_connected", fallback: "Gateway 未连接")
        case .stopping: return L10n.k("sidebar.status.stopping", fallback: "Gateway 停止中…")
        case .starting: return L10n.k("sidebar.status.starting", fallback: "Gateway 启动中…")
        case .stopped: return L10n.k("sidebar.status.stopped", fallback: "Gateway 已停止")
        case .failed(let msg): return msg
        }
    }
}

private struct SidebarItemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 15) {
            configuration.icon
            configuration.title
        }
    }
}
