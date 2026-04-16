// ClawdHome/Views/Agent/CreateAgentWizard/WizardAgentPreviewCard.swift
// 第 1 步右侧实时预览卡片

import SwiftUI

struct WizardAgentPreviewCard: View {
    let state: CreateAgentWizardState

    var body: some View {
        VStack(spacing: 0) {
            // 标题
            Text(L10n.k("wizard.preview.title", fallback: "智能体预览"))
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.bottom, 8)

            Text(L10n.k("wizard.preview.subtitle", fallback: "预览智能体效果"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.bottom, 16)

            // 预览卡
            VStack(spacing: 14) {
                // 头像
                Text(state.emoji)
                    .font(.system(size: 44))
                    .frame(width: 64, height: 64)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                // 名称
                Text(state.name.isEmpty
                    ? L10n.k("wizard.preview.placeholder_name", fallback: "未命名智能体")
                    : state.name)
                    .font(.system(size: 16, weight: .bold))

                // 身份验证徽章
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundColor(.green)
                    Text(L10n.k("wizard.preview.verified", fallback: "身份已验证"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }

                // 描述
                if !state.description.isEmpty {
                    Text("\u{201C}\(state.description)\u{201D}")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 8)
                }

                // 风格标签
                if !state.selectedStyles.isEmpty {
                    HStack(spacing: 0) {
                        Text(L10n.k("wizard.preview.style_label", fallback: "风格"))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)

                        Text("  ")

                        let styleNames = state.selectedStyles
                            .compactMap { AgentStyle(rawValue: $0)?.displayName }
                        Text(styleNames.joined(separator: "、"))
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .padding(.horizontal, 16)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            )

            Spacer()
        }
    }
}
