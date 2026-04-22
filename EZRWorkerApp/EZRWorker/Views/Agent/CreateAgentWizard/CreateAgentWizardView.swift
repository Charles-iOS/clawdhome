// EZRWorkerApp/Views/Agent/CreateAgentWizard/CreateAgentWizardView.swift
// 创建智能体向导 — 顶层容器

import SwiftUI

struct CreateAgentWizardView: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var wizardState = CreateAgentWizardState()

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            wizardHeader

            Divider()

            // 步骤内容
            ScrollView {
                Group {
                    switch wizardState.currentStep {
                    case 0:
                        WizardStep0TemplateView(state: wizardState, store: store)
                    case 1:
                        WizardStep1IdentityView(state: wizardState)
                    case 2:
                        WizardStep4UserInfoView(state: wizardState)
                    default:
                        EmptyView()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Divider()

            // 底部导航
            wizardFooter
        }
        .frame(minWidth: 720, minHeight: 580)
    }

    // MARK: - 顶部标题

    private var wizardHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "diamond.fill")
                .font(.system(size: 16))
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(stepTitle)
                    .font(.system(size: 16, weight: .semibold))
                Text(stepBreadcrumb)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // 进度指示（配置步骤时显示）
            if wizardState.currentStep > 0 {
                HStack(spacing: 8) {
                    Text(L10n.k("wizard.progress", fallback: "完成 \(wizardState.progressPercent)%"))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    ProgressView(value: Double(wizardState.progressPercent), total: 100)
                        .progressViewStyle(.linear)
                        .frame(width: 80)
                }
            }

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - 底部导航

    private var wizardFooter: some View {
        HStack {
            // 左侧按钮
            if wizardState.currentStep == 0 {
                Button(L10n.k("common.cancel", fallback: "取消")) {
                    dismiss()
                }
                .buttonStyle(.bordered)
            } else {
                Button(L10n.k("wizard.back", fallback: "上一步")) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        wizardState.currentStep -= 1
                    }
                }
                .buttonStyle(.bordered)
            }

            Spacer()

            if let err = wizardState.errorMessage {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .frame(maxWidth: 280, alignment: .trailing)
            }

            // 右侧按钮
            if wizardState.currentStep < 2 {
                Button {
                    handleNext()
                } label: {
                    Text(nextButtonLabel)
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    handleFinish()
                } label: {
                    Text(
                        wizardState.isCreating
                            ? L10n.k("wizard.creating", fallback: "创建中…")
                            : L10n.k("wizard.finish", fallback: "完成并启动")
                    )
                    .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
                .disabled(wizardState.isCreating)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - 步骤标题

    private var stepTitle: String {
        switch wizardState.currentStep {
        case 0: return L10n.k("wizard.step0.title", fallback: "创建员工")
        case 1: return L10n.k("wizard.step1.title", fallback: "身份与模型")
        case 2: return L10n.k("wizard.step4.title", fallback: "用户信息")
        default: return ""
        }
    }

    private var stepBreadcrumb: String {
        switch wizardState.currentStep {
        case 0: return L10n.k("wizard.step0.breadcrumb", fallback: "第 0 步 > 选择模板")
        case 1: return L10n.k("wizard.step1.breadcrumb", fallback: "第 1 步 > 身份与模型")
        case 2: return L10n.k("wizard.step4.breadcrumb", fallback: "第 2 步 > 用户信息")
        default: return ""
        }
    }

    private var nextButtonLabel: String {
        switch wizardState.currentStep {
        case 0: return L10n.k("wizard.next.identity", fallback: "下一步：身份")
        case 1: return L10n.k("wizard.next.userinfo", fallback: "下一步：用户信息")
        default: return ""
        }
    }

    // MARK: - 导航逻辑

    private func handleNext() {
        wizardState.errorMessage = nil

        // Step 1 → 验证名称并自动生成 ID
        if wizardState.currentStep == 0 {
            // 无需验证，直接下一步
        } else if wizardState.currentStep == 1 {
            let trimmed = wizardState.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                wizardState.errorMessage = L10n.k("wizard.error.name_empty", fallback: "请填写员工名称")
                return
            }
            // 自动生成 agentId（如果还没手动填写）
            if wizardState.agentId.isEmpty {
                wizardState.generateAgentId()
            }
            // 检查 ID 冲突
            if store.agents.contains(where: { $0.id == wizardState.agentId }) {
                wizardState.errorMessage = L10n.k("wizard.error.id_exists", fallback: "该员工 ID 已被使用")
                return
            }
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            wizardState.currentStep += 1
        }
    }

    private func handleFinish() {
        guard !wizardState.isCreating else { return }
        wizardState.isCreating = true
        wizardState.errorMessage = nil

        // 确保有 agentId
        if wizardState.agentId.isEmpty {
            wizardState.generateAgentId()
        }

        Task {
            do {
                // 组装 seed content
                let seedContent = composeSeedContent()

                try await store.addAgent(
                    id: wizardState.agentId,
                    name: wizardState.name.isEmpty ? "新员工" : wizardState.name,
                    emoji: wizardState.emoji,
                    description: wizardState.description,
                    category: wizardState.category,
                    fromPresetId: wizardState.selectedTemplateId,
                    seedContent: seedContent,
                    preferredModel: wizardState.selectedProvider,
                    skills: Array(wizardState.enabledSkills)
                )
                dismiss()
            } catch {
                wizardState.isCreating = false
                wizardState.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 组装 Seed Content

    private func composeSeedContent() -> [PersonaFile: String] {
        var seed: [PersonaFile: String] = [:]
        let presetSeed = wizardState.templateSeedContent.isEmpty
            ? (wizardState.selectedTemplateId.map(AgentStore.extractPresetSeedContent) ?? [:])
            : wizardState.templateSeedContent
        let presetTemplate = wizardState.selectedTemplateId.flatMap { id in
            store.presetTemplates.first(where: { $0.id == id })
        }

        seed.merge(presetSeed) { _, new in new }

        // IDENTITY.md：保留模板原文，并把向导里的补充信息追加进去
        var identityExtras: [String] = []
        if let presetTemplate {
            if !wizardState.name.isEmpty && wizardState.name != presetTemplate.name {
                identityExtras.append("当前角色名：\(wizardState.name)")
            }
            if !wizardState.description.isEmpty && wizardState.description != presetTemplate.description {
                identityExtras.append("补充描述：\(wizardState.description)")
            }
        } else {
            identityExtras.append("角色名：\(wizardState.name)")
            if !wizardState.description.isEmpty {
                identityExtras.append(wizardState.description)
            }
        }

        if !wizardState.selectedStyles.isEmpty {
            let styleNames = wizardState.selectedStyles
                .compactMap { raw in AgentStyle(rawValue: raw)?.displayName }
                .joined(separator: "、")
            identityExtras.append("风格：\(styleNames)")
        }

        let presetIdentity = presetSeed[.identity]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extraIdentity = identityExtras.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !presetIdentity.isEmpty && !extraIdentity.isEmpty {
            seed[.identity] = "\(presetIdentity)\n\n## 当前配置补充\n\(extraIdentity)"
        } else if !extraIdentity.isEmpty {
            seed[.identity] = extraIdentity
        } else if !presetIdentity.isEmpty {
            seed[.identity] = presetIdentity
        }

        // USER.md：保留模板填写框架，并把用户在向导中输入的信息追加进去
        var userParts: [String] = []
        if !wizardState.userDisplayName.isEmpty {
            userParts.append("称呼：\(wizardState.userDisplayName)")
        }
        userParts.append("偏好语言：\(wizardState.preferredLanguage)")
        if !wizardState.userNotes.isEmpty {
            userParts.append("备注：\(wizardState.userNotes)")
        }
        if !wizardState.userBackground.isEmpty {
            userParts.append("## 补充背景\n\(wizardState.userBackground)")
        }

        let presetUser = presetSeed[.user]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let extraUser = userParts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !presetUser.isEmpty && !extraUser.isEmpty {
            seed[.user] = "\(presetUser)\n\n## 当前配置\n\(extraUser)"
        } else if !extraUser.isEmpty {
            seed[.user] = "# 关于你\n\n\(extraUser)"
        } else if !presetUser.isEmpty {
            seed[.user] = presetUser
        }

        return seed
    }
}
