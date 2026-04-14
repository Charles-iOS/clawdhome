// ClawdHome/Views/Agent/AgentEditorView.swift
// 智能体元数据编辑（名称、emoji、分类、描述、首选模型、技能）
// persona 文件（SOUL.md/IDENTITY.md 等）在 AgentWorkspaceView 中编辑

import SwiftUI

struct AgentEditorView: View {
    @Environment(AgentStore.self) private var store
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(GatewayService.self) private var gateway
    @Environment(\.dismiss) private var dismiss

    let agent: Agent

    @State private var name: String
    @State private var emoji: String
    @State private var description: String
    @State private var category: AgentCategory
    @State private var preferredModel: String
    @State private var skillsText: String
    @State private var isDeleting = false

    init(agent: Agent) {
        self.agent = agent
        _name = State(initialValue: agent.name)
        _emoji = State(initialValue: agent.emoji)
        _description = State(initialValue: agent.description)
        _category = State(initialValue: agent.category)
        _preferredModel = State(initialValue: agent.preferredModel ?? "")
        _skillsText = State(initialValue: agent.skills.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                basicInfoSection
                modelSection
                skillsSection
                dangerSection
            }
            .formStyle(.grouped)
            .navigationTitle(agent.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.k("common.save", fallback: "保存")) { save() }
                        .disabled(name.isEmpty || isDeleting)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
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
    private var modelSection: some View {
        Section(L10n.k("agent.editor.model", fallback: "首选模型")) {
            Picker(
                L10n.k("agent.editor.model_picker", fallback: "模型"),
                selection: $preferredModel
            ) {
                Text(L10n.k("agent.editor.model_default", fallback: "使用全局默认"))
                    .tag("")
                Divider()
                ForEach(modelStore.allTemplateModels) { model in
                    Text(model.label).tag(model.id)
                }
            }
            if !gateway.isConnected {
                Text(L10n.k("agent.editor.model_gateway_hint", fallback: "Gateway 未连接，模型变更将在保存时写入"))
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        Section(L10n.k("agent.editor.skills", fallback: "技能标签")) {
            TextField(
                L10n.k("agent.editor.skills_placeholder", fallback: "逗号分隔，如：战略规划, 需求拆解"),
                text: $skillsText,
                axis: .vertical
            )
            .lineLimit(2...3)
        }
    }

    @ViewBuilder
    private var dangerSection: some View {
        if !agent.isPreset && agent.id != "main" {
            Section {
                Button(role: .destructive) {
                    Task {
                        isDeleting = true
                        defer { isDeleting = false }
                        do {
                            try await store.removeAgent(id: agent.id)
                            dismiss()
                        } catch {
                            appLog("删除智能体失败: \(error)", level: .error)
                        }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(
                            isDeleting
                                ? L10n.k("agent.delete.loading", fallback: "删除中…")
                                : L10n.k("agent.editor.delete", fallback: "删除此智能体")
                        )
                    }
                }
                .disabled(isDeleting)
            }
        }
    }

    private func save() {
        var updated = agent
        updated.name = name
        updated.emoji = emoji
        updated.description = description
        updated.category = category
        updated.preferredModel = preferredModel.isEmpty ? nil : preferredModel
        updated.skills = skillsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        store.updateAgent(updated)

        // 模型变更写入 gateway 配置
        let newModel = preferredModel.isEmpty ? nil : preferredModel
        if newModel != agent.preferredModel {
            Task {
                try? await store.setAgentModel(
                    agentId: agent.id,
                    modelId: newModel
                )
            }
        }

        dismiss()
    }
}
