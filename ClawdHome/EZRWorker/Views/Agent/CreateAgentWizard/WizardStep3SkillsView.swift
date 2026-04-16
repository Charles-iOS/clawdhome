// ClawdHome/Views/Agent/CreateAgentWizard/WizardStep3SkillsView.swift
// 第 3 步：技能列表开关

import SwiftUI

struct WizardStep3SkillsView: View {
    let state: CreateAgentWizardState

    /// 静态技能列表（当网关不可用时使用）
    private static let defaultSkills: [(id: String, emoji: String, name: String, description: String)] = [
        ("skill-search", "🔍", "技能搜索", "一站式搜索和安装技能：覆盖 skills.sh、ClawHub 和 SkillMP 三大平台。"),
        ("skill-create", "🛠️", "技能创建", "创建新技能、修改现有技能、运行评测和性能基准测试。"),
        ("self-evolve", "🧬", "自我进化", "通过实时跟踪执行错误、用户偏好与实战经验，持续优化 Agent 的逻辑模型与执行工具。"),
        ("gmail", "📧", "Gmail 助手", "收发、搜索和管理 Gmail 邮件，支持发送回复和智能检索。"),
        ("mcp", "🔌", "MCP 工具", "通过 MCP 网关发现和调用远程工具（Google, Notion, Square, Twitter, GitHub 等）。"),
        ("pptx", "📊", "演示文稿", "创建、编辑和分析 PowerPoint 演示文稿。"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // 标题
            HStack {
                Text(L10n.k("wizard.step3.heading", fallback: "技能"))
                    .font(.system(size: 21, weight: .semibold))

                Spacer()

                Text(L10n.k("wizard.step3.progress", fallback: "完成 60%"))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }

            Text(L10n.k("wizard.step3.desc", fallback: "配置预装技能并从目录添加"))
                .font(.system(size: 13))
                .foregroundColor(.secondary)

            Text(L10n.k("wizard.step3.hint", fallback: "基于此模板预装的预装技能。创建时会自动安装，可用开关来控制默认启用。"))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)

            // 技能列表
            VStack(spacing: 1) {
                ForEach(Self.defaultSkills, id: \.id) { skill in
                    skillRow(skill)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - 技能行

    private func skillRow(_ skill: (id: String, emoji: String, name: String, description: String)) -> some View {
        let isEnabled = state.enabledSkills.contains(skill.id)

        return HStack(spacing: 12) {
            // 图标
            Text(skill.emoji)
                .font(.system(size: 20))
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))

            // 名称与描述
            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .font(.system(size: 13, weight: .semibold))

                Text(skill.description)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            // 开关
            Toggle("", isOn: Binding(
                get: { state.enabledSkills.contains(skill.id) },
                set: { enabled in
                    if enabled {
                        state.enabledSkills.insert(skill.id)
                    } else {
                        state.enabledSkills.remove(skill.id)
                    }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}
