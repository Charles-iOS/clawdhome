// ClawdHome/Views/Agent/AgentGridView.swift

import SwiftUI

struct AgentGridView: View {
    @Environment(AgentStore.self) private var store
    @State private var searchText = ""
    @State private var selectedCategory: AgentCategory?
    @State private var selectedAgentId: String?
    @State private var showCreateSheet = false

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
        }
        .navigationTitle(L10n.k("agent.grid.title", fallback: "智能体"))
        .sheet(isPresented: $showCreateSheet) {
            CreateAgentSheet()
        }
        .sheet(item: $selectedAgentId) { agentId in
            if let agent = store.agents.first(where: { $0.id == agentId }) {
                AgentEditorView(agent: agent)
            }
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
                    AgentCardView(agent: agent) {
                        selectedAgentId = agent.id
                    }
                }
            }
            .padding(16)
        }
    }
}

extension String: @retroactive Identifiable {
    public var id: String { self }
}
