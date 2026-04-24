// EZRWorkerApp/Views/MainView.swift

import SwiftUI

struct MainView: View {
    @State private var selection: SidebarDestination? = .agents

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 180, ideal: 250, max: 260)
        } detail: {
            detailView
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .agents:
            NavigationStack {
                AgentGridView()
                    .navigationDestination(for: String.self) { agentId in
                        AgentWorkspaceView(agentId: agentId)
                    }
            }
        case .cron:
            CronTaskView()
        case .skills:
            SkillsView()
        case .channels:
            ChannelView()
        case .models:
            ModelConfigView()
        case .settings:
            AppSettingsView()
        case nil:
            ContentUnavailableView(
                L10n.k("main.select_item", fallback: "选择一个菜单项"),
                systemImage: "sidebar.left"
            )
        }
    }
}
