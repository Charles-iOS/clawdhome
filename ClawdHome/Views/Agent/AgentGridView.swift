// ClawdHome/Views/Agent/AgentGridView.swift

import SwiftUI

struct AgentGridView: View {
    @Environment(AgentStore.self) private var store
    @State private var searchText = ""
    @State private var selectedCategory: AgentCategory?
    @State private var showCreateSheet = false
    @State private var showTemplates = false

    private var filteredAgents: [Agent] {
        var results = store.agents
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

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            categoryTags
            agentGrid

            if !store.presetTemplates.isEmpty {
                templateSection
            }
        }
        .navigationTitle(L10n.k("agent.grid.title", fallback: "智能体"))
        .sheet(isPresented: $showCreateSheet) {
            CreateAgentSheet()
        }
    }

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            TextField(L10n.k("agent.grid.search", fallback: "搜索智能体…"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 300)
            Spacer()
            Button {
                showCreateSheet = true
            } label: {
                Label(L10n.k("agent.grid.create", fallback: "新建智能体"), systemImage: "plus")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var categoryTags: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                categoryTag(nil, label: L10n.k("agent.grid.all", fallback: "全部"))
                ForEach(AgentCategory.allCases) { cat in
                    categoryTag(cat, label: cat.displayName)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private func categoryTag(_ category: AgentCategory?, label: String) -> some View {
        let isSelected = selectedCategory == category
        Button(label) {
            selectedCategory = category
        }
        .buttonStyle(.plain)
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.08))
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .clipShape(Capsule())
    }

    @ViewBuilder
    private var agentGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 12)]
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(filteredAgents) { agent in
                    NavigationLink(value: agent.id) {
                        AgentCardView(agent: agent)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        agentContextMenu(agent)
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 预置模板区域

    @ViewBuilder
    private var templateSection: some View {
        Divider()
        DisclosureGroup(isExpanded: $showTemplates) {
            let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 8)]
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(store.presetTemplates.filter { preset in
                    !store.agents.contains(where: { $0.id == preset.id })
                }) { preset in
                    presetTemplateCard(preset)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } label: {
            Text(L10n.k("agent.grid.templates", fallback: "预置模板"))
                .font(.subheadline)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func presetTemplateCard(_ preset: Agent) -> some View {
        Button {
            // 从预置模板创建新智能体
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
                    appLog("从模板创建智能体失败: \(error)", level: .error)
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(preset.emoji).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preset.name).font(.caption).fontWeight(.medium).lineLimit(1)
                    Text(preset.description).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus.circle")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                Task {
                    try? await store.removeAgent(id: agent.id)
                }
            } label: {
                Label(L10n.k("agent.menu.delete", fallback: "删除智能体"), systemImage: "trash")
            }
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
