// ClawdHome/Views/Agent/AgentGridView.swift

import SwiftUI

struct AgentGridView: View {
    @Environment(AgentStore.self) private var store
    @State private var searchText = ""
    @State private var selectedCategory: AgentCategory?
    @State private var showCreateSheet = false
    @State private var segment: AgentGridSegment = .myAgents
    @State private var agentToDelete: Agent?
    @State private var deletingAgentId: String?
    @State private var deleteError: String?

    private var filteredAgents: [Agent] {
        var results: [Agent]
        switch segment {
        case .myAgents:
            results = store.agents
        case .taskDerived:
            results = store.presetTemplates.filter { preset in
                !store.agents.contains(where: { $0.id == preset.id })
            }
        }
        if let cat = selectedCategory {
            results = results.filter { $0.category == cat }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            results = results.filter {
                $0.name.lowercased().contains(q)
                || $0.description.lowercased().contains(q)
                || $0.skills.contains(where: { $0.lowercased().contains(q) })
            }
        }
        return results
    }

    private var gridRefreshKey: String {
        store.agents.map {
            [
                $0.id,
                $0.status.rawValue,
                String($0.sessionCount),
                String($0.boundBindings.count),
                $0.name,
                $0.description
            ].joined(separator: "|")
        }
        .joined(separator: "||")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                heroHeader
                agentGrid
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCreateSheet) {
            CreateAgentSheet()
        }
        .alert(
            L10n.k("agent.delete.confirm_title", fallback: "确认删除"),
            isPresented: Binding(
                get: { agentToDelete != nil },
                set: { if !$0 { agentToDelete = nil } }
            )
        ) {
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {
                agentToDelete = nil
            }
            .disabled(deletingAgentId != nil)
            Button(L10n.k("agent.delete.confirm", fallback: "删除"), role: .destructive) {
                guard let agent = agentToDelete else { return }
                agentToDelete = nil
                Task {
                    deletingAgentId = agent.id
                    defer { deletingAgentId = nil }
                    do {
                        try await store.removeAgent(id: agent.id)
                    } catch {
                        deleteError = error.localizedDescription
                        appLog("删除智能体失败: \(error)", level: .error)
                    }
                }
            }
        } message: {
            if let agent = agentToDelete {
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
            if let err = deleteError {
                Text(err)
            }
        }
    }

    @ViewBuilder
    private var heroHeader: some View {
        HStack(alignment: .top, spacing: 20) {
            PageHeroHeader(
                title: L10n.k("agent.grid.title", fallback: "数字员工"),
                subtitle: L10n.k("agent.grid.subtitle", fallback: "管理你的个性化助手，创建新角色并开始对话。")
            )
            Spacer()

            VStack(alignment: .trailing, spacing: 12) {
                // Picker("Agent", selection: $segment) {
                //     ForEach(AgentGridSegment.allCases) { option in
                //         Text(option.title).tag(option)
                //     }
                // }
                // .pickerStyle(.segmented)
                // .frame(width: 340)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.k("agent.grid.search", fallback: "搜索员工…"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(.horizontal, 12)
                .frame(width: 340, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                        )
                )
            }
        }
    }
    @ViewBuilder
    private var agentGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 300, maximum: 360), spacing: 20)]
        LazyVGrid(columns: columns, spacing: 20) {
            if segment == .myAgents {
                createAgentCard
            }
            ForEach(filteredAgents) { agent in
                if segment == .myAgents {
                    NavigationLink(value: agent.id) {
                        AgentVisualCard(
                            agent: agent,
                            isDeleting: deletingAgentId == agent.id
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(deletingAgentId == agent.id)
                    .contextMenu { agentContextMenu(agent) }
                } else {
                    presetCard(agent)
                }
            }
        }
        .id(gridRefreshKey)
    }

    @ViewBuilder
    private var createAgentCard: some View {
        Button {
            showCreateSheet = true
        } label: {
            VStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .frame(width: 64, height: 64)
                    Image(systemName: "plus")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(.secondary)
                }
                Text(L10n.k("agent.grid.create", fallback: "新建员工"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .foregroundStyle(Color.secondary.opacity(0.35))
                    )
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func presetCard(_ preset: Agent) -> some View {
        Button {
            Task {
                do {
                    try await store.addAgent(
                        id: preset.id,
                        name: preset.name,
                        emoji: preset.emoji,
                        description: preset.description,
                        category: preset.category,
                        fromPresetId: preset.id
                    )
                } catch {
                    appLog("从模板创建员工失败: \(error)", level: .error)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(preset.emoji)
                        .font(.system(size: 44))
                    Spacer()
                    Text(L10n.k("agent.grid.templates", fallback: "预置模板"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text(preset.name)
                    .font(.system(size: 30, weight: .bold))
                    .lineLimit(1)
                Text(preset.description)
                    .font(.system(size: 22))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text(L10n.k("agent.grid.from_template", fallback: "从模板创建"))
                }
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
            }
            .padding(20)
            .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 右键菜单

    @ViewBuilder
    private func agentContextMenu(_ agent: Agent) -> some View {
        Button {
            // 导航到 workspace（通过 NavigationLink 已处理）
        } label: {
            Label(L10n.k("agent.menu.workspace", fallback: "打开 Workspace"), systemImage: "folder")
        }

        Divider()

        if agent.id != "main" {
            Button(role: .destructive) {
                agentToDelete = agent
            } label: {
                Label(L10n.k("agent.menu.delete", fallback: "删除员工"), systemImage: "trash")
            }
            .disabled(deletingAgentId != nil)
        }
    }
}

private enum AgentGridSegment: String, CaseIterable, Identifiable {
    case myAgents
    case taskDerived

    var id: String { rawValue }

    var title: String {
        switch self {
        case .myAgents:
            return L10n.k("agent.grid.segment.my_agents", fallback: "我的数字员工")
        case .taskDerived:
            return L10n.k("agent.grid.segment.task_derived", fallback: "预置模板")
        }
    }
}

private struct AgentVisualCard: View {
    let agent: Agent
    let isDeleting: Bool

    private var displayEmoji: String {
        let trimmed = agent.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "🤖" : trimmed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(displayEmoji)
                    .font(.system(size: 46))
                Spacer()
                statusTag
            }

            Text(agent.name)
                .font(.system(size: 32, weight: .bold))
                .lineLimit(1)
            Text(agent.description)
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                capabilityRow(
                    icon: "bubble.left.and.bubble.right",
                    text: L10n.k("agent.card.sessions", fallback: "\(agent.sessionCount) 个会话")
                )
                capabilityRow(icon: "link", text: channelSummary)
                capabilityRow(icon: "bolt", text: runtimeSummary)
            }
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, minHeight: 330, maxHeight: 330, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.05), radius: 10, y: 2)
        .overlay {
            if isDeleting {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        VStack(spacing: 12) {
                            ProgressView()
                                .controlSize(.large)
                            Text(L10n.k("agent.delete.loading", fallback: "删除中…"))
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.primary)
                        }
                    }
            }
        }
    }

    @ViewBuilder
    private var statusTag: some View {
        let cfg = statusConfig
        HStack(spacing: 6) {
            Circle()
                .fill(cfg.color)
                .frame(width: 7, height: 7)
            Text(cfg.title)
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(cfg.color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(cfg.color.opacity(0.14), in: Capsule())
    }

    @ViewBuilder
    private func capabilityRow(icon: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(text)
                .lineLimit(1)
        }
    }

    private var channelSummary: String {
        let channels = Array(Set(agent.boundBindings.map(\.channel)))
        if channels.isEmpty {
            return L10n.k("agent.card.channels.none", fallback: "未绑定渠道")
        }
        return L10n.k("agent.card.channels.count", fallback: "已绑定 \(channels.count) 个渠道")
    }

    private var runtimeSummary: String {
        switch agent.status {
        case .active:
            return L10n.k("agent.status.active", fallback: "运行中")
        case .idle:
            return L10n.k("agent.status.idle", fallback: "空闲")
        case .uninitialized:
            return L10n.k("agent.status.uninitialized", fallback: "未初始化")
        }
    }

    private var statusConfig: (title: String, color: Color) {
        switch agent.status {
        case .active:
            return (L10n.k("agent.status.active", fallback: "运行中"), .green)
        case .idle:
            return (L10n.k("agent.status.idle", fallback: "空闲"), .secondary)
        case .uninitialized:
            return (L10n.k("agent.status.uninitialized", fallback: "未初始化"), .orange)
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
