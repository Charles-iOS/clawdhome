// ClawdHome/Views/Agent/CreateAgentSheet.swift
// 创建新智能体：空白创建或从预置模板创建

import SwiftUI

struct CreateAgentSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var agentId = ""
    @State private var name = ""
    @State private var emoji = "🤖"
    @State private var description = ""
    @State private var category: AgentCategory = .strategy
    @State private var selectedPresetId: String?
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                templateSection
                agentIdSection
                basicInfoSection

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundStyle(.red)
                            .font(.caption)
                    }
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
                        .disabled(agentId.isEmpty || name.isEmpty || isCreating)
                }
            }
        }
        .frame(minWidth: 480, minHeight: 440)
    }

    // MARK: - 预置模板选择

    @ViewBuilder
    private var templateSection: some View {
        if !store.presetTemplates.isEmpty {
            Section(L10n.k("agent.create.template", fallback: "从模板创建（可选）")) {
                Picker(L10n.k("agent.create.template_select", fallback: "选择模板"), selection: $selectedPresetId) {
                    Text(L10n.k("agent.create.blank", fallback: "空白创建")).tag(nil as String?)
                    ForEach(store.presetTemplates) { preset in
                        Text("\(preset.emoji) \(preset.name)").tag(preset.id as String?)
                    }
                }
                .onChange(of: selectedPresetId) { _, newValue in
                    if let presetId = newValue,
                       let preset = store.presetTemplates.first(where: { $0.id == presetId }) {
                        if name.isEmpty { name = preset.name }
                        if agentId.isEmpty { agentId = presetId }
                        emoji = preset.emoji
                        description = preset.description
                        category = preset.category
                    }
                }
            }
        }
    }

    // MARK: - Agent ID

    @ViewBuilder
    private var agentIdSection: some View {
        Section(L10n.k("agent.create.id_section", fallback: "智能体标识")) {
            TextField(
                L10n.k("agent.create.id_placeholder", fallback: "如 work, social, coding（仅英文小写+连字符）"),
                text: $agentId
            )
            .onChange(of: agentId) { _, newValue in
                // 限制为小写字母、数字和连字符
                agentId = newValue
                    .lowercased()
                    .filter { $0.isLetter || $0.isNumber || $0 == "-" }
            }

            if store.agents.contains(where: { $0.id == agentId }) && !agentId.isEmpty {
                Text(L10n.k("agent.create.id_exists", fallback: "该 ID 已被使用"))
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    // MARK: - 基本信息

    @ViewBuilder
    private var basicInfoSection: some View {
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
    }

    // MARK: - 创建

    private func create() {
        guard !agentId.isEmpty, !name.isEmpty else { return }
        guard !store.agents.contains(where: { $0.id == agentId }) else {
            errorMessage = L10n.k("agent.create.id_exists", fallback: "该 ID 已被使用")
            return
        }

        isCreating = true
        errorMessage = nil

        Task {
            do {
                try await store.addAgent(
                    id: agentId,
                    name: name,
                    emoji: emoji,
                    description: description,
                    category: category,
                    fromPresetId: selectedPresetId
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                isCreating = false
            }
        }
    }
}
