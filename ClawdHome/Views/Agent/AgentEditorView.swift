// ClawdHome/Views/Agent/AgentEditorView.swift

import SwiftUI

struct AgentEditorView: View {
    @Environment(AgentStore.self) private var store
    @Environment(GatewayService.self) private var gateway
    @Environment(\.dismiss) private var dismiss

    let agent: Agent

    @State private var name: String
    @State private var emoji: String
    @State private var description: String
    @State private var systemPrompt: String
    @State private var identity: String
    @State private var category: AgentCategory
    @State private var isSaving = false
    @State private var isActivating = false

    init(agent: Agent) {
        self.agent = agent
        _name = State(initialValue: agent.name)
        _emoji = State(initialValue: agent.emoji)
        _description = State(initialValue: agent.description)
        _systemPrompt = State(initialValue: agent.systemPrompt)
        _identity = State(initialValue: agent.identity)
        _category = State(initialValue: agent.category)
    }

    var body: some View {
        NavigationStack {
            Form {
                basicInfoSection
                promptSection
                identitySection
                actionSection
            }
            .formStyle(.grouped)
            .navigationTitle(agent.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.k("common.save", fallback: "保存")) { save() }
                        .disabled(isSaving || name.isEmpty)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    @ViewBuilder
    private var basicInfoSection: some View {
        Section(L10n.k("agent.editor.basic", fallback: "基本信息")) {
            HStack {
                TextField("Emoji", text: $emoji)
                    .frame(width: 50)
                TextField(L10n.k("agent.editor.name", fallback: "名称"), text: $name)
            }
            Picker(L10n.k("agent.editor.category", fallback: "分类"), selection: $category) {
                ForEach(AgentCategory.allCases) { cat in
                    Text(cat.displayName).tag(cat)
                }
            }
            TextField(L10n.k("agent.editor.desc", fallback: "简短描述"), text: $description, axis: .vertical)
                .lineLimit(2...4)
        }
    }

    @ViewBuilder
    private var promptSection: some View {
        Section(L10n.k("agent.editor.soul", fallback: "灵魂（System Prompt）")) {
            TextEditor(text: $systemPrompt)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 120)
        }
    }

    @ViewBuilder
    private var identitySection: some View {
        Section(L10n.k("agent.editor.identity", fallback: "身份定义")) {
            TextEditor(text: $identity)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        Section {
            Button {
                Task { await activateAgent() }
            } label: {
                HStack {
                    if isActivating {
                        ProgressView().controlSize(.small)
                    }
                    Text(agent.isActive
                         ? L10n.k("agent.editor.activated", fallback: "当前已激活")
                         : L10n.k("agent.editor.activate", fallback: "激活此角色"))
                }
            }
            .disabled(agent.isActive || isActivating)

            if !agent.isPreset {
                Button(role: .destructive) {
                    store.delete(id: agent.id)
                    dismiss()
                } label: {
                    Text(L10n.k("agent.editor.delete", fallback: "删除此智能体"))
                }
            }
        }
    }

    private func save() {
        isSaving = true
        var updated = agent
        updated.name = name
        updated.emoji = emoji
        updated.description = description
        updated.systemPrompt = systemPrompt
        updated.identity = identity
        updated.category = category
        store.update(updated)
        isSaving = false
        dismiss()
    }

    private func activateAgent() async {
        isActivating = true
        defer { isActivating = false }

        store.activate(id: agent.id)

        do {
            let (_, baseHash) = try await gateway.configGetFull()
            let patch: [String: Any] = [
                "soul": ["content": agent.systemPrompt],
                "identity": ["content": agent.identity],
            ]
            try await gateway.configPatch(patch: patch, baseHash: baseHash, note: "Activate agent: \(agent.name)")
            appLog("Activated agent: \(agent.name)")
        } catch {
            appLog("Failed to activate agent \(agent.name): \(error)", level: .error)
        }
    }
}
