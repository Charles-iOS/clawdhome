// EZRWorkerApp/Views/Agent/CreateAgentWizard/WizardStep2ToolsView.swift
// 第 2 步：工具分类开关（占位，不接后端）

import SwiftUI

struct WizardStep2ToolsView: View {
    let state: CreateAgentWizardState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Text(L10n.k("wizard.step2.heading", fallback: "工具"))
                    .font(.system(size: 21, weight: .semibold))

                Spacer()

                Text(L10n.k("wizard.step2.progress", fallback: "完成 40%"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text(L10n.k("wizard.step2.desc", fallback: "选择工具分类与工作区"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // 工具分类网格（2 列）
            let gridColumns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(AgentToolCategory.all) { category in
                    toolCategoryRow(category)
                }
            }

            // 默认工作区（可选）
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.k("wizard.step2.workspace", fallback: "默认工作区（可选）"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    TextField(
                        L10n.k("wizard.step2.workspace_placeholder", fallback: "未选择——将使用智能体的项目文件夹"),
                        text: .constant("")
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .disabled(true)

                    Button {
                        // 占位：后续接文件选择器
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 13))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 工具分类行

    private func toolCategoryRow(_ category: AgentToolCategory) -> some View {
        let isEnabled = state.enabledToolCategories.contains(category.id)

        return HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 14))
                .foregroundColor(isEnabled ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(isEnabled ? Color.accentColor.opacity(0.1) : Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)

                Text(category.tools.joined(separator: ", "))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { state.enabledToolCategories.contains(category.id) },
                set: { enabled in
                    if enabled {
                        state.enabledToolCategories.insert(category.id)
                    } else {
                        state.enabledToolCategories.remove(category.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}
