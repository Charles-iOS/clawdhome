// ClawdHome/Views/Agent/CreateAgentWizard/WizardStep1IdentityView.swift
// 第 1 步：身份与模型（左表单 + 右预览）

import SwiftUI

struct WizardStep1IdentityView: View {
    let state: CreateAgentWizardState

    /// 预设头像 emoji 列表
    private let presetAvatars = ["🤖", "🧭", "🦞", "🐙", "🎯", "🧠", "💻", "📈", "🌿", "🎨", "📚", "🔮", "🛠️", "🌐", "💡", "⚖️"]

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            // 左面板：表单
            leftPanel
                .frame(maxWidth: .infinity)

            // 右面板：预览
            WizardAgentPreviewCard(state: state)
                .frame(width: 240)
        }
    }

    // MARK: - 左面板

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 18) {
            // 名称
            VStack(alignment: .leading, spacing: 6) {
                TextField(
                    L10n.k("wizard.step1.name_placeholder", fallback: "日常助手"),
                    text: Binding(get: { state.name }, set: { state.name = $0 })
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14))
            }

            // 头像选择
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.k("wizard.step1.avatar", fallback: "员工头像"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(presetAvatars, id: \.self) { avatar in
                            Button {
                                state.emoji = avatar
                            } label: {
                                Text(avatar)
                                    .font(.system(size: 22))
                                    .frame(width: 40, height: 40)
                                    .background(
                                        state.emoji == avatar
                                            ? Color.accentColor.opacity(0.15)
                                            : Color(nsColor: .controlBackgroundColor)
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(
                                                state.emoji == avatar ? Color.accentColor : Color.clear,
                                                lineWidth: 1.5
                                            )
                                    )
                            }
                            .buttonStyle(.plain)
                        }

                        // More 按钮
                        Button {} label: {
                            VStack(spacing: 2) {
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 14))
                                Text("More")
                                    .font(.system(size: 9))
                            }
                            .foregroundColor(.secondary)
                            .frame(width: 40, height: 40)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // 描述
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.k("wizard.step1.desc_label", fallback: "描述"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                TextEditor(text: Binding(get: { state.description }, set: { state.description = $0 }))
                    .font(.system(size: 13))
                    .lineSpacing(3)
                    .frame(minHeight: 60, maxHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
            }

            // 风格标签
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.k("wizard.step1.style_label", fallback: "风格"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)

                FlowLayout(spacing: 8) {
                    ForEach(AgentStyle.allCases) { style in
                        styleChip(style)
                    }
                }
            }
        }
    }

    // MARK: - 风格 Chip

    private func styleChip(_ style: AgentStyle) -> some View {
        let isSelected = state.selectedStyles.contains(style.rawValue)
        return Button {
            if isSelected {
                state.selectedStyles.remove(style.rawValue)
            } else {
                state.selectedStyles.insert(style.rawValue)
            }
        } label: {
            Text(style.displayName)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.primary.opacity(0.1) : Color(nsColor: .controlBackgroundColor))
                .foregroundColor(isSelected ? .primary : .secondary)
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.primary.opacity(0.3) : Color.secondary.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - FlowLayout（自动换行布局）

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            positions.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            x += size.width + spacing
            totalHeight = y + rowHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), positions)
    }
}
