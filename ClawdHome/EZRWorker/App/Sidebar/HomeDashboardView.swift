// ClawdHome/Views/Sidebar/DashboardView.swift
// 仪表盘：显示 Gateway 状态和快捷操作入口

import SwiftUI

struct HomeDashboardView: View {
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(GatewayService.self) private var gateway
    @Environment(AgentStore.self) private var agentStore
    @Environment(EnvironmentChecker.self) private var envChecker

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                PageHeroHeader(
                    title: L10n.k("dashboard.title", fallback: "仪表盘"),
                    subtitle: L10n.k("dashboard.hero.subtitle", fallback: "查看 Gateway 状态与快捷入口。")
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                gatewayStatusCard
                quickStatsGrid
                activeAgentCard
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var gatewayStatusCard: some View {
        GroupBox {
            HStack(spacing: 16) {
                stateIcon
                    .font(.largeTitle)
                VStack(alignment: .leading, spacing: 4) {
                    Text(stateTitle)
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text(stateSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                gatewayControls
            }
            .padding(.vertical, 8)
        } label: {
            Text("OpenClaw Gateway")
        }
    }

    @ViewBuilder
    private var stateIcon: some View {
        switch processManager.state {
        case .running:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .stopping:
            ProgressView()
                .controlSize(.large)
        case .starting:
            ProgressView()
                .controlSize(.large)
        case .stopped:
            Image(systemName: "stop.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var stateTitle: String {
        switch processManager.state {
        case .running:    return L10n.k("dashboard.running", fallback: "运行中")
        case .stopping:   return L10n.k("dashboard.stopping", fallback: "正在停止…")
        case .starting:   return L10n.k("dashboard.starting", fallback: "正在启动…")
        case .stopped:    return L10n.k("dashboard.stopped", fallback: "已停止")
        case .failed(let msg): return msg
        }
    }

    private var stateSubtitle: String {
        if processManager.isRunning {
            return String(format: L10n.k("dashboard.port", fallback: "监听端口 %d"), processManager.gatewayPort)
        }
        return L10n.k("dashboard.port_idle", fallback: "—")
    }

    @ViewBuilder
    private var gatewayControls: some View {
        HStack(spacing: 8) {
            switch processManager.state {
            case .running:
                Button(L10n.k("dashboard.restart", fallback: "重启")) {
                    processManager.restart()
                }
                Button(L10n.k("dashboard.stop", fallback: "停止")) {
                    Task {
                        await gateway.disconnect()
                        agentStore.markGatewayDisconnected()
                        processManager.stop()
                    }
                }
            case .stopped, .failed:
                Button(L10n.k("dashboard.start", fallback: "启动")) {
                    Task {
                        processManager.start()
                        for _ in 0..<30 {
                            if processManager.state == .running || gateway.isConnected { break }
                            if case .failed = processManager.state { break }
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        guard processManager.state == .running else { return }
                        await gateway.connect()
                        if gateway.isConnected {
                            await agentStore.refreshFromGateway()
                        }
                    }
                }
                .disabled(!envChecker.isReady)
            case .starting, .stopping:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var quickStatsGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 140, maximum: 200), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            StatCard(
                title: L10n.k("dashboard.agents", fallback: "智能体"),
                value: "\(agentStore.agents.count)",
                icon: "person.2.fill"
            )
            StatCard(
                title: L10n.k("dashboard.cron_jobs", fallback: "定时任务"),
                value: "\(gateway.cronStore.jobs.count)",
                icon: "clock.fill"
            )
            StatCard(
                title: L10n.k("dashboard.skills_count", fallback: "技能"),
                value: "\(gateway.skillsStore.skills.count)",
                icon: "wrench.and.screwdriver.fill"
            )
            StatCard(
                title: L10n.k("dashboard.gateway_status", fallback: "WebSocket"),
                value: gateway.isConnected
                    ? L10n.k("dashboard.connected", fallback: "已连接")
                    : L10n.k("dashboard.disconnected", fallback: "未连接"),
                icon: "bolt.fill",
                valueColor: gateway.isConnected ? .green : .secondary
            )
        }
    }

    @ViewBuilder
    private var activeAgentCard: some View {
        let activeAgents = agentStore.agents.filter { $0.status == .active }
        if !activeAgents.isEmpty {
            GroupBox {
                VStack(spacing: 8) {
                    ForEach(activeAgents) { agent in
                        HStack(spacing: 12) {
                            Text(agent.emoji).font(.title)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(agent.name).fontWeight(.medium)
                                Text(agent.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if !agent.boundBindings.isEmpty {
                                HStack(spacing: 2) {
                                    ForEach(agent.boundBindings.prefix(3)) { binding in
                                        Image(systemName: binding.channelIcon)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            } label: {
                Text(L10n.k("dashboard.active_agents", fallback: "活跃智能体"))
            }
        }
    }
}

// MARK: - StatCard

private struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    var valueColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(valueColor)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
