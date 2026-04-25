// EZRWorkerApp/Views/Agent/AgentWorkspaceView.swift
// 数字员工详情页 — 员工控制台 + 工作区

import AppKit
import SwiftUI

struct AgentWorkspaceView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayService.self) private var gateway
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(AgentWorkspaceManager.self) private var workspaceManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: WorkspaceTab = .overview
    @State private var showEditorSheet = false
    @State private var isRefreshing = false
    @State private var workspaceProbe: WorkspaceProbeResult?
    @State private var actionToast: String?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteError: String?

    private var agent: Agent? {
        store.agents.first(where: { $0.id == agentId })
    }

    var body: some View {
        Group {
            if let agent {
                detailContent(for: agent)
            } else {
                ContentUnavailableView {
                    Label(L10n.k("agent.detail.missing", fallback: "找不到这个数字员工"), systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(agentId)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .navigationTitle(agent?.name ?? agentId)
        .sheet(isPresented: $showEditorSheet) {
            if let agent {
                AgentEditorView(agent: agent)
            }
        }
        .confirmationDialog(
            L10n.k("agent.delete.confirm_title", fallback: "确认删除"),
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
            if let agent, agent.id != "main" {
                Button(L10n.k("agent.delete.confirm", fallback: "删除"), role: .destructive) {
                    deleteAgent(agent)
                }
                .disabled(isDeleting)
            }
        } message: {
            if let agent {
                Text(L10n.k("agent.delete.confirm_msg", fallback: "确定要删除智能体「\(agent.name)」吗？此操作不可撤销。"))
            }
        }
        .alert(
            L10n.k("agent.delete.failed_title", fallback: "删除失败"),
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )
        ) {
            Button("OK") { deleteError = nil }
        } message: {
            Text(deleteError ?? "")
        }
        .overlay(alignment: .bottom) {
            if let actionToast {
                Text(actionToast)
                    .font(.system(size: AgentDetailFont.detail, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 18)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: actionToast)
        .task(id: agentId) {
            await refreshWorkspaceProbe()
        }
        .onChange(of: gateway.isConnected) { _, _ in
            Task { await refreshWorkspaceProbe() }
        }
    }

    @ViewBuilder
    private func detailContent(for agent: Agent) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                heroSection(for: agent)
                tabPicker
            }
            .padding(.horizontal, AgentDetailLayout.pageHorizontalPadding)
            .padding(.top, 16)
            .padding(.bottom, 10)

            Divider()

            tabContent(for: agent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func heroSection(for agent: Agent) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text(displayEmoji(for: agent))
                .font(.system(size: 42))
                .frame(width: 60, height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )
                )

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    statusBadges(for: agent)
                    heroActions(for: agent)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(agent.name)
                        .font(.system(size: 32, weight: .bold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(agent.description.isEmpty
                         ? L10n.k("agent.detail.no_description", fallback: "暂无描述")
                         : agent.description)
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                let metaSummary = heroMetaSummary(for: agent)
                if !metaSummary.isEmpty {
                    Text(metaSummary)
                        .font(.system(size: AgentDetailFont.meta, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statusBadges(for agent: Agent) -> some View {
        AgentDetailStatusBadge(
            title: statusTitle(for: agent.status),
            systemImage: statusIcon(for: agent.status),
            tint: statusColor(for: agent.status)
        )
        AgentDetailStatusBadge(
            title: gateway.isConnected
                ? L10n.k("dashboard.connected", fallback: "已连接")
                : L10n.k("dashboard.disconnected", fallback: "未连接"),
            systemImage: gateway.isConnected ? "checkmark.circle.fill" : "wifi.slash",
            tint: gateway.isConnected ? .green : .orange
        )
    }

    @ViewBuilder
    private func heroActions(for agent: Agent) -> some View {
        HStack(spacing: 8) {
            heroActionButtons(for: agent)
        }
    }

    @ViewBuilder
    private func heroActionButtons(for agent: Agent) -> some View {
        Button {
            showEditorSheet = true
        } label: {
            Label(L10n.k("agent.workspace.edit", fallback: "编辑信息"), systemImage: "pencil")
                .font(.system(size: AgentDetailFont.detail, weight: .semibold))
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.regular)

        Button {
            Task { await refreshDetail() }
        } label: {
            if isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Label(L10n.k("common.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                    .font(.system(size: AgentDetailFont.detail, weight: .semibold))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .disabled(isRefreshing)

        Menu {
            Button {
                copyToPasteboard(agent.id, toast: L10n.k("agent.detail.copied_id", fallback: "已复制 Agent ID"))
            } label: {
                Label("Agent ID", systemImage: "number")
            }

            if let workspacePath = workspaceAbsolutePath(for: agent) {
                Button {
                    openWorkspace(path: workspacePath)
                } label: {
                    Label(L10n.k("agent.detail.open_workspace", fallback: "打开 Workspace"), systemImage: "folder")
                }

                Button {
                    copyToPasteboard(workspacePath, toast: L10n.k("agent.detail.copied_workspace", fallback: "已复制 Workspace 路径"))
                } label: {
                    Label(L10n.k("agent.detail.copy_workspace", fallback: "复制 Workspace 路径"), systemImage: "doc.on.doc")
                }
            }

            if agent.id != "main" {
                Divider()
                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label(L10n.k("agent.editor.delete", fallback: "删除此智能体"), systemImage: "trash")
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 18, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        .menuStyle(.borderlessButton)
        .disabled(isDeleting)
    }

    @ViewBuilder
    private func overviewCards(for agent: Agent) -> some View {
        LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 16) {
            AgentDetailOverviewCard(
                icon: "cpu",
                title: L10n.k("agent.settings.model", fallback: "模型配置"),
                value: modelDisplayLabel(for: agent),
                subtitle: agent.preferredModel == nil
                    ? L10n.k("agent.settings.model_default", fallback: "使用全局默认")
                    : L10n.k("agent.detail.model_override", fallback: "员工独立模型"),
                tint: agent.preferredModel == nil ? .secondary : .accentColor
            ) {
                selectTab(.settings)
            }

            AgentDetailOverviewCard(
                icon: "arrow.triangle.branch",
                title: L10n.k("agent.bindings.title", fallback: "渠道绑定"),
                value: "\(agent.boundBindings.count)",
                subtitle: bindingSummary(for: agent),
                tint: agent.boundBindings.isEmpty ? .orange : .green
            ) {
                selectTab(.bindings)
            }

            AgentDetailOverviewCard(
                icon: "bubble.left.and.bubble.right",
                title: L10n.k("agent.tab.sessions", fallback: "会话历史"),
                value: "\(agent.sessionCount)",
                subtitle: lastActiveLabel(for: agent),
                tint: agent.sessionCount > 0 ? .green : .secondary
            ) {
                selectTab(.sessions)
            }

            AgentDetailOverviewCard(
                icon: "folder",
                title: "Workspace",
                value: workspaceStatusTitle,
                subtitle: workspaceDisplayPath(for: agent),
                tint: workspaceStatusColor
            ) {
                selectTab(.persona)
            }
        }
    }

    @ViewBuilder
    private var tabPicker: some View {
        HStack(spacing: 3) {
            ForEach(WorkspaceTab.allCases) { tab in
                Button {
                    selectTab(tab)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(tab.label)
                            .font(.system(size: AgentDetailFont.detail, weight: .semibold))
                    }
                    .foregroundStyle(selectedTab == tab ? Color.primary : Color.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .contentShape(Rectangle())
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selectedTab == tab ? Color(nsColor: .selectedControlColor).opacity(0.28) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .frame(maxWidth: 620)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func tabContent(for agent: Agent) -> some View {
        Group {
            switch selectedTab {
            case .overview:
                AgentOverviewTab(
                    agent: agent,
                    gatewayConnected: gateway.isConnected,
                    workspaceProbe: workspaceProbe,
                    modelLabel: modelDisplayLabel(for: agent),
                    workspacePath: workspaceDisplayPath(for: agent),
                    onSelectTab: { selectTab($0) }
                )
            case .persona:
                AgentPersonaEditorView(agentId: agentId)
            case .bindings:
                AgentBindingsView(agentId: agentId)
            case .sessions:
                AgentSessionsView(agentId: agentId)
            case .settings:
                AgentSettingsView(agentId: agentId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var overviewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 210, maximum: 320), spacing: 16)]
    }

    private var workspaceStatusTitle: String {
        switch workspaceProbe {
        case .exists:
            return L10n.k("agent.detail.workspace.ready", fallback: "已就绪")
        case .missing:
            return L10n.k("agent.detail.workspace.missing", fallback: "待创建")
        case .indeterminate:
            return L10n.k("agent.detail.workspace.check", fallback: "需检查")
        case nil:
            return L10n.k("agent.detail.workspace.loading", fallback: "检查中")
        }
    }

    private var workspaceStatusColor: Color {
        switch workspaceProbe {
        case .exists:
            return .green
        case .missing, .indeterminate:
            return .orange
        case nil:
            return .secondary
        }
    }

    private func refreshDetail() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await store.refreshRuntimeState(for: agentId)
        workspaceProbe = await workspaceManager.probeWorkspace(agentId: agentId)
    }

    private func selectTab(_ tab: WorkspaceTab) {
        guard selectedTab != tab else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selectedTab = tab
        }
    }

    private func refreshWorkspaceProbe() async {
        workspaceProbe = await workspaceManager.probeWorkspace(agentId: agentId)
    }

    private func deleteAgent(_ agent: Agent) {
        Task {
            isDeleting = true
            defer { isDeleting = false }
            do {
                try await store.removeAgent(id: agent.id)
                dismiss()
            } catch {
                deleteError = error.localizedDescription
                appLog("删除智能体失败: \(error)", level: .error)
            }
        }
    }

    private func copyToPasteboard(_ value: String, toast: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        showToast(toast)
    }

    private func openWorkspace(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func showToast(_ message: String) {
        actionToast = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
            if actionToast == message {
                actionToast = nil
            }
        }
    }

    private func modelDisplayLabel(for agent: Agent) -> String {
        guard let preferredModel = agent.preferredModel, !preferredModel.isEmpty else {
            return L10n.k("agent.settings.model_default", fallback: "使用全局默认")
        }
        return modelStore.allTemplateModels.first(where: { $0.id == preferredModel })?.label
            ?? preferredModel
    }

    private func bindingSummary(for agent: Agent) -> String {
        let bindings = uniqueBindings(for: agent)
        guard !bindings.isEmpty else {
            return L10n.k("agent.card.channels.none", fallback: "未绑定渠道")
        }
        return bindings
            .map { $0.channelType?.displayName ?? $0.channel.capitalized }
            .joined(separator: "、")
    }

    private func uniqueBindings(for agent: Agent) -> [AgentBinding] {
        var seen = Set<String>()
        return agent.boundBindings.filter { binding in
            seen.insert(binding.channel).inserted
        }
    }

    private func heroMetaSummary(for agent: Agent) -> String {
        var parts: [String] = []
        if !agent.skills.isEmpty {
            parts.append(agent.skills.prefix(3).map { "#\($0)" }.joined(separator: " "))
        }
        let bindings = uniqueBindings(for: agent)
        if !bindings.isEmpty {
            parts.append(bindings.prefix(3).map { $0.channelType?.displayName ?? $0.channel.capitalized }.joined(separator: "、"))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func lastActiveLabel(for agent: Agent) -> String {
        guard let lastActiveAt = agent.lastActiveAt else {
            return L10n.k("agent.detail.no_activity", fallback: "暂无最近活动")
        }
        return lastActiveAt.formatted(date: .abbreviated, time: .shortened)
    }

    private func workspaceDisplayPath(for agent: Agent) -> String {
        if let workspace = agent.workspace,
           !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: workspace).abbreviatingWithTildeInPath
        }

        if let resolution = workspaceManager.currentProfileResolution {
            return NSString(string: resolution.workspacePath(for: agentId)).abbreviatingWithTildeInPath
        }

        return L10n.k("agent.settings.workspace_pending", fallback: "当前 profile 未就绪")
    }

    private func workspaceAbsolutePath(for agent: Agent) -> String? {
        if let workspace = agent.workspace,
           !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return workspace
        }
        return workspaceManager.currentProfileResolution?.workspacePath(for: agentId)
    }

    private func displayEmoji(for agent: Agent) -> String {
        let trimmed = agent.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "🤖" : trimmed
    }

    private func statusTitle(for status: AgentStatus) -> String {
        switch status {
        case .active:
            return L10n.k("agent.status.active", fallback: "活跃")
        case .idle:
            return L10n.k("agent.status.idle", fallback: "待命")
        case .uninitialized:
            return L10n.k("agent.status.uninitialized", fallback: "未初始化")
        }
    }

    private func statusIcon(for status: AgentStatus) -> String {
        switch status {
        case .active:
            return "bolt.fill"
        case .idle:
            return "moon"
        case .uninitialized:
            return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for status: AgentStatus) -> Color {
        switch status {
        case .active:
            return .green
        case .idle:
            return .secondary
        case .uninitialized:
            return .orange
        }
    }
}

// MARK: - WorkspaceTab

private enum WorkspaceTab: String, CaseIterable, Identifiable {
    case overview
    case persona
    case bindings
    case sessions
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overview: return L10n.k("agent.tab.overview", fallback: "概览")
        case .persona:  return L10n.k("agent.tab.persona", fallback: "人设文件")
        case .bindings: return L10n.k("agent.tab.bindings", fallback: "渠道")
        case .sessions: return L10n.k("agent.tab.sessions", fallback: "会话")
        case .settings: return L10n.k("agent.tab.settings", fallback: "配置")
        }
    }

    var icon: String {
        switch self {
        case .overview: return "rectangle.grid.2x2"
        case .persona:  return "person.text.rectangle"
        case .bindings: return "arrow.triangle.branch"
        case .sessions: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Design Tokens

private enum AgentDetailFont {
    static let sectionTitle: CGFloat = 20
    static let cardTitle: CGFloat = 20
    static let body: CGFloat = 16
    static let detail: CGFloat = 15
    static let meta: CGFloat = 14
    static let badge: CGFloat = 13
    static let mono: CGFloat = 13
    static let action: CGFloat = 16
}

private enum AgentDetailLayout {
    static let pageHorizontalPadding: CGFloat = 28
    static let pageTopPadding: CGFloat = 24
    static let pageBottomPadding: CGFloat = 28
    static let cardPadding: CGFloat = 22
    static let cardCornerRadius: CGFloat = 24
    static let compactCornerRadius: CGFloat = 10
    static let overviewCardMinHeight: CGFloat = 132
}

// MARK: - Overview Tab

private struct AgentOverviewTab: View {
    let agent: Agent
    let gatewayConnected: Bool
    let workspaceProbe: WorkspaceProbeResult?
    let modelLabel: String
    let workspacePath: String
    let onSelectTab: (WorkspaceTab) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                AgentDetailSectionCard(
                    title: L10n.k("agent.detail.readiness", fallback: "就绪检查"),
                    subtitle: L10n.k("agent.detail.readiness.subtitle", fallback: "关键运行条件和需要补齐的配置。")
                ) {
                    VStack(spacing: 12) {
                        AgentReadinessRow(
                            icon: gatewayConnected ? "checkmark.circle.fill" : "wifi.slash",
                            title: L10n.k("dashboard.gateway_status", fallback: "WebSocket"),
                            detail: gatewayConnected
                                ? L10n.k("dashboard.connected", fallback: "已连接")
                                : L10n.k("dashboard.disconnected", fallback: "未连接"),
                            status: gatewayConnected
                                ? L10n.k("dashboard.connected", fallback: "已连接")
                                : L10n.k("dashboard.disconnected", fallback: "未连接"),
                            tint: gatewayConnected ? .green : .orange
                        )

                        AgentReadinessRow(
                            icon: "cpu",
                            title: L10n.k("agent.settings.model", fallback: "模型配置"),
                            detail: modelLabel,
                            status: agent.preferredModel == nil
                                ? L10n.k("agent.settings.model_default", fallback: "使用全局默认")
                                : L10n.k("agent.detail.model_override", fallback: "员工独立模型"),
                            tint: agent.preferredModel == nil ? .secondary : .accentColor,
                            actionTitle: L10n.k("agent.detail.configure", fallback: "配置")
                        ) {
                            onSelectTab(.settings)
                        }

                        AgentReadinessRow(
                            icon: "arrow.triangle.branch",
                            title: L10n.k("agent.bindings.title", fallback: "渠道绑定"),
                            detail: agent.boundBindings.isEmpty
                                ? L10n.k("agent.bindings.empty_desc", fallback: "添加渠道绑定后，入站消息将路由到此智能体")
                                : L10n.k("agent.detail.bindings.ready", fallback: "入站消息已可路由到该员工"),
                            status: agent.boundBindings.isEmpty
                                ? L10n.k("agent.card.channels.none", fallback: "未绑定渠道")
                                : L10n.k("agent.detail.ready", fallback: "已就绪"),
                            tint: agent.boundBindings.isEmpty ? .orange : .green,
                            actionTitle: agent.boundBindings.isEmpty
                                ? L10n.k("agent.bindings.add", fallback: "添加绑定")
                                : L10n.k("agent.detail.manage", fallback: "管理")
                        ) {
                            onSelectTab(.bindings)
                        }

                        AgentReadinessRow(
                            icon: "folder",
                            title: "Workspace",
                            detail: workspacePath,
                            status: workspaceStatusTitle,
                            tint: workspaceStatusColor,
                            actionTitle: L10n.k("agent.detail.edit_persona", fallback: "编辑人设")
                        ) {
                            onSelectTab(.persona)
                        }
                    }
                }

                AgentDetailSectionCard(
                    title: L10n.k("agent.detail.runtime", fallback: "最近状态"),
                    subtitle: L10n.k("agent.detail.runtime.subtitle", fallback: "会话、渠道和活动时间。")
                ) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 12)], alignment: .leading, spacing: 12) {
                        AgentRuntimeMetric(title: L10n.k("agent.settings.sessions_count", fallback: "会话数"), value: "\(agent.sessionCount)")
                        AgentRuntimeMetric(title: L10n.k("agent.settings.bindings_count", fallback: "绑定数"), value: "\(agent.boundBindings.count)")
                        AgentRuntimeMetric(title: L10n.k("agent.settings.last_active_at", fallback: "最近活跃"), value: lastActiveText)
                        AgentRuntimeMetric(title: "Agent ID", value: agent.id, isMonospaced: true)
                    }
                }
            }
            .padding(.horizontal, AgentDetailLayout.pageHorizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, AgentDetailLayout.pageBottomPadding)
        }
    }

    private var workspaceStatusTitle: String {
        switch workspaceProbe {
        case .exists:
            return L10n.k("agent.detail.workspace.ready", fallback: "已就绪")
        case .missing:
            return L10n.k("agent.detail.workspace.missing", fallback: "待创建")
        case .indeterminate:
            return L10n.k("agent.detail.workspace.check", fallback: "需检查")
        case nil:
            return L10n.k("agent.detail.workspace.loading", fallback: "检查中")
        }
    }

    private var workspaceStatusColor: Color {
        switch workspaceProbe {
        case .exists:
            return .green
        case .missing, .indeterminate:
            return .orange
        case nil:
            return .secondary
        }
    }

    private var lastActiveText: String {
        guard let lastActiveAt = agent.lastActiveAt else {
            return L10n.k("agent.detail.no_activity", fallback: "暂无最近活动")
        }
        return lastActiveAt.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - Persona 编辑器 Tab

private struct AgentPersonaEditorView: View {
    let agentId: String

    @Environment(AgentWorkspaceManager.self) private var workspaceManager

    @State private var selectedFile: PersonaFile = .soul
    @State private var editorContents: [PersonaFile: String] = [:]
    @State private var savedContents: [PersonaFile: String] = [:]
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var saveToast: String?

    var body: some View {
        HSplitView {
            fileSidebar
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 260)

            editorArea
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: agentId) {
            await loadFile(.soul)
        }
    }

    @ViewBuilder
    private var fileSidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.k("agent.tab.persona", fallback: "人设文件"))
                    .font(.system(size: AgentDetailFont.sectionTitle, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Divider()

            List(PersonaFile.allCases, selection: $selectedFile) { file in
                HStack(spacing: 10) {
                    Text(file.icon)
                        .font(.system(size: 18))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(file.rawValue)
                            .font(.system(size: AgentDetailFont.meta, weight: .semibold, design: .monospaced))
                        Text(file.description)
                            .font(.system(size: AgentDetailFont.badge))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    if isDirty(file) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.vertical, 4)
                .tag(file)
            }
            .listStyle(.sidebar)
            .onChange(of: selectedFile) { _, newFile in
                Task { await loadFile(newFile) }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var editorArea: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(selectedFile.icon) \(selectedFile.rawValue)")
                        .font(.system(size: AgentDetailFont.cardTitle, weight: .semibold))
                    Text(selectedFile.description)
                        .font(.system(size: AgentDetailFont.detail))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                if isDirty(selectedFile) {
                    AgentDetailStatusBadge(
                        title: L10n.k("agent.persona.unsaved", fallback: "未保存"),
                        systemImage: "circle.fill",
                        tint: .orange
                    )
                }

                Button(L10n.k("agent.persona.discard", fallback: "放弃更改")) {
                    discardCurrentFile()
                }
                .buttonStyle(.bordered)
                .disabled(!isDirty(selectedFile) || isSaving)

                Button {
                    Task { await saveCurrentFile() }
                } label: {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.k("common.save", fallback: "保存"), systemImage: "checkmark")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isDirty(selectedFile) || isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            if let saveError {
                Text(saveError)
                    .font(.system(size: AgentDetailFont.detail))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 10)
            }

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                ContentUnavailableView {
                    Label(L10n.k("agent.persona.load_error", fallback: "加载失败"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                }
            } else {
                TextEditor(text: Binding(
                    get: { editorContents[selectedFile] ?? "" },
                    set: { editorContents[selectedFile] = $0 }
                ))
                .font(.system(size: AgentDetailFont.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(12)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            if let msg = saveToast {
                Text(msg)
                    .font(.system(size: AgentDetailFont.detail, weight: .medium))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: saveToast)
    }

    private func isDirty(_ file: PersonaFile) -> Bool {
        (editorContents[file] ?? "") != (savedContents[file] ?? "")
    }

    private func loadFile(_ file: PersonaFile) async {
        isLoading = true
        loadError = nil
        saveError = nil
        defer { isLoading = false }
        do {
            let content = try await workspaceManager.readPersonaFile(agentId: agentId, file: file)
            editorContents[file] = content
            savedContents[file] = content
        } catch {
            let msg = error.localizedDescription
            if isMissingFileError(msg) {
                editorContents[file] = editorContents[file] ?? ""
                savedContents[file] = savedContents[file] ?? ""
                loadError = nil
            } else {
                loadError = msg
            }
        }
    }

    private func saveCurrentFile() async {
        isSaving = true
        saveError = nil
        defer { isSaving = false }
        let content = editorContents[selectedFile] ?? ""
        do {
            try await workspaceManager.writePersonaFile(agentId: agentId, file: selectedFile, content: content)
            savedContents[selectedFile] = content
            saveToast = L10n.f("persona.save.toast.saved", fallback: "已保存 %@", selectedFile.rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                saveToast = nil
            }
        } catch {
            saveError = error.localizedDescription
            appLog("保存 persona 文件失败: \(error)", level: .error)
        }
    }

    private func discardCurrentFile() {
        editorContents[selectedFile] = savedContents[selectedFile] ?? ""
    }

    private func isMissingFileError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("no such file")
            || normalized.contains("not found")
            || normalized.contains("doesn't exist")
            || normalized.contains("doesn’t exist")
            || normalized.contains("couldn’t be opened")
            || normalized.contains("could not be opened")
            || normalized.contains("不存在")
    }
}

// MARK: - Settings Tab

private struct AgentSettingsView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayService.self) private var gateway
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(AgentWorkspaceManager.self) private var workspaceManager

    @State private var preferredModel = ""
    @State private var skillsAllowList = ""
    @State private var isSavingModel = false
    @State private var isSavingSkills = false
    @State private var modelSaveError: String?
    @State private var skillsSaveMessage: String?

    private var agent: Agent? {
        store.agents.first(where: { $0.id == agentId })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                modelSection
                skillsSection
                infoSection
            }
            .padding(.horizontal, AgentDetailLayout.pageHorizontalPadding)
            .padding(.top, 20)
            .padding(.bottom, AgentDetailLayout.pageBottomPadding)
        }
        .onAppear {
            syncStateFromAgent()
        }
        .onChange(of: agent?.preferredModel) { _, _ in
            syncStateFromAgent()
        }
        .onChange(of: agent?.skills) { _, _ in
            syncStateFromAgent()
        }
    }

    @ViewBuilder
    private var modelSection: some View {
        AgentDetailSectionCard(
            title: L10n.k("agent.settings.model", fallback: "模型配置"),
            subtitle: L10n.k("agent.detail.model_section.subtitle", fallback: "为这个员工指定独立模型，或继承全局默认模型。")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Picker(
                    L10n.k("agent.settings.model_picker", fallback: "首选模型"),
                    selection: $preferredModel
                ) {
                    Text(L10n.k("agent.settings.model_default", fallback: "使用全局默认"))
                        .tag("")
                    Divider()
                    ForEach(modelStore.allTemplateModels) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .frame(maxWidth: 520)
                .disabled(!gateway.isConnected || isSavingModel)
                .onChange(of: preferredModel) { _, newValue in
                    guard !isSavingModel else { return }
                    Task { await saveModel(newValue) }
                }

                if !gateway.isConnected {
                    AgentInlineStatus(
                        text: L10n.k("agent.settings.model_gateway_disconnected", fallback: "Gateway 未连接，无法修改模型"),
                        tint: .orange,
                        icon: "wifi.slash"
                    )
                } else if let error = modelSaveError {
                    AgentInlineStatus(text: error, tint: .red, icon: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        AgentDetailSectionCard(
            title: L10n.k("agent.settings.skills", fallback: "Skills 允许列表"),
            subtitle: L10n.k("agent.settings.skills_hint", fallback: "对应 agents.list[].skills 配置")
        ) {
            VStack(alignment: .leading, spacing: 14) {
                TextField(
                    L10n.k("agent.settings.skills_placeholder", fallback: "逗号分隔的 skill 名称（留空继承全局）"),
                    text: $skillsAllowList,
                    axis: .vertical
                )
                .lineLimit(3...6)
                .font(.system(size: AgentDetailFont.body))

                HStack(spacing: 12) {
                    Button {
                        saveSkills()
                    } label: {
                        if isSavingSkills {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(L10n.k("common.save", fallback: "保存"), systemImage: "checkmark")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSavingSkills || skillsAllowList == (agent?.skills.joined(separator: ", ") ?? ""))

                    if let skillsSaveMessage {
                        AgentInlineStatus(text: skillsSaveMessage, tint: .green, icon: "checkmark.circle.fill")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var infoSection: some View {
        AgentDetailSectionCard(
            title: L10n.k("agent.settings.info", fallback: "信息"),
            subtitle: L10n.k("agent.detail.info.subtitle", fallback: "本地路径、绑定数量和运行统计。")
        ) {
            VStack(alignment: .leading, spacing: 12) {
                AgentInfoRow("Agent ID", value: agentId, isMonospaced: true)
                if let agent {
                    AgentInfoRow(
                        L10n.k("agent.settings.workspace_path", fallback: "Workspace 路径"),
                        value: workspaceDisplayPath(for: agent),
                        isMonospaced: true,
                        allowsWrapping: true,
                        copyValue: workspaceAbsolutePath(for: agent)
                    )
                    AgentInfoRow(
                        L10n.k("agent.settings.bindings_count", fallback: "绑定数"),
                        value: "\(agent.boundBindings.count)"
                    )
                    AgentInfoRow(
                        L10n.k("agent.settings.sessions_count", fallback: "会话数"),
                        value: "\(agent.sessionCount)"
                    )
                    if let lastActiveAt = agent.lastActiveAt {
                        AgentInfoRow(
                            L10n.k("agent.settings.last_active_at", fallback: "最近活跃"),
                            value: lastActiveAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
            }
        }
    }

    private func syncStateFromAgent() {
        preferredModel = agent?.preferredModel ?? ""
        skillsAllowList = agent?.skills.joined(separator: ", ") ?? ""
    }

    private func saveModel(_ modelId: String) async {
        isSavingModel = true
        modelSaveError = nil
        do {
            try await store.setAgentModel(
                agentId: agentId,
                modelId: modelId.isEmpty ? nil : modelId
            )
        } catch {
            modelSaveError = error.localizedDescription
            preferredModel = agent?.preferredModel ?? ""
        }
        isSavingModel = false
    }

    private func saveSkills() {
        guard var updated = agent else { return }
        updated.skills = skillsAllowList
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        Task {
            isSavingSkills = true
            defer { isSavingSkills = false }
            await store.updateAgent(updated)
            skillsSaveMessage = L10n.k("agent.detail.skills_saved", fallback: "Skills 已保存")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {
                skillsSaveMessage = nil
            }
        }
    }

    private func workspaceDisplayPath(for agent: Agent) -> String {
        if let workspace = agent.workspace,
           !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return NSString(string: workspace).abbreviatingWithTildeInPath
        }

        if let resolution = workspaceManager.currentProfileResolution {
            return NSString(string: resolution.workspacePath(for: agentId)).abbreviatingWithTildeInPath
        }

        return L10n.k("agent.settings.workspace_pending", fallback: "当前 profile 未就绪")
    }

    private func workspaceAbsolutePath(for agent: Agent) -> String? {
        if let workspace = agent.workspace,
           !workspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return workspace
        }
        return workspaceManager.currentProfileResolution?.workspacePath(for: agentId)
    }
}

// MARK: - Shared Detail Components

private struct AgentDetailSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let content: Content

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: AgentDetailFont.cardTitle, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: AgentDetailFont.detail))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(AgentDetailLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: AgentDetailLayout.cardCornerRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: AgentDetailLayout.cardCornerRadius, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 14, y: 6)
        )
    }
}

private struct AgentDetailOverviewCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                    Text(title)
                        .font(.system(size: AgentDetailFont.meta, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                Text(value)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(subtitle)
                    .font(.system(size: AgentDetailFont.meta))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: AgentDetailLayout.overviewCardMinHeight, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(tint.opacity(0.16), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct AgentDetailStatusBadge: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
        }
            .font(.system(size: AgentDetailFont.badge, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
    }
}

private struct AgentDetailChip: View {
    let title: String
    let systemImage: String?

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
            }
            Text(title)
        }
        .font(.system(size: AgentDetailFont.badge, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.10), in: Capsule())
    }
}

private struct AgentReadinessRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: String
    let tint: Color
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: AgentDetailFont.body, weight: .semibold))
                Text(detail)
                    .font(.system(size: AgentDetailFont.detail))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            AgentDetailStatusBadge(title: status, systemImage: "circle.fill", tint: tint)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

private struct AgentRuntimeMetric: View {
    let title: String
    let value: String
    var isMonospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: AgentDetailFont.badge, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(valueFont)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AgentDetailLayout.compactCornerRadius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        )
    }

    private var valueFont: Font {
        isMonospaced
            ? .system(size: AgentDetailFont.mono, weight: .semibold, design: .monospaced)
            : .system(size: AgentDetailFont.body, weight: .semibold)
    }
}

private struct AgentInlineStatus: View {
    let text: String
    let tint: Color
    let icon: String

    var body: some View {
        Label(text, systemImage: icon)
            .font(.system(size: AgentDetailFont.detail, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct AgentInfoRow: View {
    let title: String
    let value: String
    let isMonospaced: Bool
    let allowsWrapping: Bool
    let copyValue: String?

    init(
        _ title: String,
        value: String,
        isMonospaced: Bool = false,
        allowsWrapping: Bool = false,
        copyValue: String? = nil
    ) {
        self.title = title
        self.value = value
        self.isMonospaced = isMonospaced
        self.allowsWrapping = allowsWrapping
        self.copyValue = copyValue
    }

    var body: some View {
        HStack(alignment: allowsWrapping ? .top : .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: AgentDetailFont.detail))
                .foregroundStyle(.secondary)
                .frame(width: 120, alignment: .leading)

            Text(value)
                .font(valueFont)
                .lineLimit(allowsWrapping ? 3 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let copyValue {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyValue, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.k("common.copy", fallback: "复制"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var valueFont: Font {
        isMonospaced
            ? .system(size: AgentDetailFont.mono, design: .monospaced)
            : .system(size: AgentDetailFont.body, weight: .medium)
    }
}
