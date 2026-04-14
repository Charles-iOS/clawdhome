// ClawdHome/Views/Agent/CreateAgentWizard/WizardStep4UserInfoView.swift
// 第 4 步：用户信息

import SwiftUI

struct WizardStep4UserInfoView: View {
    let state: CreateAgentWizardState

    private let languages = ["中文", "English", "日本語"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.k("wizard.step4.step_label", fallback: "第 4 / 4 步"))
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)

                    Text(L10n.k("wizard.step4.heading", fallback: "用户信息"))
                        .font(.system(size: 21, weight: .semibold))
                }

                Spacer()

                Text(L10n.k("wizard.step4.progress", fallback: "完成 80%"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            // 进度条
            ProgressView(value: 0.8)
                .progressViewStyle(.linear)
                .tint(.accentColor)

            Text(L10n.k("wizard.step4.desc", fallback: "告诉智能体关于用户的信息，包括称呼、偏好和背景"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            // 表单
            VStack(alignment: .leading, spacing: 16) {
                // 如何称呼你 + 偏好语言
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.k("wizard.step4.name_label", fallback: "如何称呼你"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        TextField(
                            L10n.k("wizard.step4.name_placeholder", fallback: "例如：小明、或昵称"),
                            text: Binding(get: { state.userDisplayName }, set: { state.userDisplayName = $0 })
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.k("wizard.step4.lang_label", fallback: "偏好语言"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)

                        Picker("", selection: Binding(get: { state.preferredLanguage }, set: { state.preferredLanguage = $0 })) {
                            ForEach(languages, id: \.self) { lang in
                                Text(lang).tag(lang)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                    }
                }

                // 备注
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("wizard.step4.notes_label", fallback: "备注"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    TextField(
                        L10n.k("wizard.step4.notes_placeholder", fallback: "简短补充，例如所在城市、职业等"),
                        text: Binding(get: { state.userNotes }, set: { state.userNotes = $0 })
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 13))
                }

                // 补充背景
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.k("wizard.step4.bg_label", fallback: "补充背景"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    TextEditor(text: Binding(get: { state.userBackground }, set: { state.userBackground = $0 }))
                        .font(.system(size: 13))
                        .lineSpacing(3)
                        .frame(minHeight: 100, maxHeight: 160)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                        )
                        .overlay(alignment: .topLeading) {
                            if state.userBackground.isEmpty {
                                Text(L10n.k("wizard.step4.bg_placeholder", fallback: "你的职业、项目、偏好等..."))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.tertiary)
                                    .padding(.leading, 12)
                                    .padding(.top, 14)
                                    .allowsHitTesting(false)
                            }
                        }
                }
            }
        }
    }
}
