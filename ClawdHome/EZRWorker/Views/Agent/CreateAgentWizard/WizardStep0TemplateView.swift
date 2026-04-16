// ClawdHome/Views/Agent/CreateAgentWizard/WizardStep0TemplateView.swift
// 第 0 步：选择起点（模板网格）

import SwiftUI

struct WizardStep0TemplateView: View {
    let state: CreateAgentWizardState
    let store: AgentStore

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.k("wizard.step0.heading", fallback: "选择起点"))
                .font(.system(size: 21, weight: .semibold))

            Text(L10n.k("wizard.step0.desc", fallback: "选择一个模板以快速开始，或者从头开始构建你的智能体。"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            LazyVGrid(columns: columns, spacing: 14) {
                // 空白智能体
                templateCard(
                    id: nil,
                    emoji: nil,
                    name: L10n.k("wizard.template.blank", fallback: "空白智能体"),
                    description: L10n.k("wizard.template.blank_desc", fallback: "从一个完全空白的画布开始。")
                )

                // 预置模板
                ForEach(store.presetTemplates) { template in
                    templateCard(
                        id: template.id,
                        emoji: template.emoji,
                        name: template.name,
                        description: template.description
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func templateCard(id: String?, emoji: String?, name: String, description: String) -> some View {
        let isSelected = (id == nil && state.selectedTemplateId == nil && state.name.isEmpty)
            || (id != nil && state.selectedTemplateId == id)

        Button {
            if let id, let template = store.presetTemplates.first(where: { $0.id == id }) {
                state.selectedTemplateId = id
                state.applyTemplate(template)
            } else {
                state.selectedTemplateId = nil
                state.name = ""
                state.emoji = "🤖"
                state.description = ""
                state.category = .strategy
                state.enabledSkills = []
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                if let emoji {
                    Text(emoji)
                        .font(.system(size: 28))
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.accentColor)
                        .frame(width: 34, height: 34)
                }

                Text(name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text(description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        isSelected ? Color.accentColor : Color.secondary.opacity(0.15),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
