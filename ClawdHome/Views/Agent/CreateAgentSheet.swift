// ClawdHome/Views/Agent/CreateAgentSheet.swift

import SwiftUI

struct CreateAgentSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var description = ""
    @State private var systemPrompt = ""
    @State private var identity = ""
    @State private var category: AgentCategory = .strategy

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.k("agent.create.basic", fallback: "基本信息")) {
                    HStack {
                        TextField("Emoji", text: $emoji)
                            .frame(width: 50)
                        TextField(L10n.k("agent.create.name", fallback: "智能体名称"), text: $name)
                    }
                    Picker(L10n.k("agent.create.category", fallback: "分类"), selection: $category) {
                        ForEach(AgentCategory.allCases) { cat in
                            Text(cat.displayName).tag(cat)
                        }
                    }
                    TextField(L10n.k("agent.create.desc", fallback: "一句话描述"), text: $description, axis: .vertical)
                        .lineLimit(2...4)
                }
                Section(L10n.k("agent.create.soul", fallback: "灵魂（System Prompt）")) {
                    TextEditor(text: $systemPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 100)
                }
                Section(L10n.k("agent.create.identity", fallback: "身份定义")) {
                    TextEditor(text: $identity)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.k("agent.create.title", fallback: "新建智能体"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.k("common.create", fallback: "创建")) { create() }
                        .disabled(name.isEmpty)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
    }

    private func create() {
        let agent = Agent(
            id: UUID().uuidString,
            name: name,
            emoji: emoji,
            description: description,
            systemPrompt: systemPrompt,
            identity: identity,
            userTemplate: "",
            preferredModel: nil,
            skills: [],
            category: category,
            isPreset: false,
            isActive: false,
            createdAt: Date()
        )
        store.add(agent)
        dismiss()
    }
}
