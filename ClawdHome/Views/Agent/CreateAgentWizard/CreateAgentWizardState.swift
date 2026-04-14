// ClawdHome/Views/Agent/CreateAgentWizard/CreateAgentWizardState.swift
// 创建智能体向导的全局状态

import Foundation
import Observation

@Observable
final class CreateAgentWizardState {

    // MARK: - 导航

    var currentStep: Int = 0  // 0 = 模板, 1 = 身份, 2 = 工具, 3 = 技能, 4 = 用户信息

    static let totalConfigSteps = 4  // Step 1-4 对应"第 1/4 步 ~ 第 4/4 步"

    /// 当前配置步骤编号（1-based），Step 0 不算
    var configStepNumber: Int { currentStep }

    /// 进度百分比（0-100），Step 0 = 0，Step 4 = 80，完成 = 100
    var progressPercent: Int {
        guard currentStep > 0 else { return 0 }
        return currentStep * 100 / (Self.totalConfigSteps + 1)
    }

    // MARK: - Step 0: 模板选择

    var selectedTemplateId: String?

    // MARK: - Step 1: 身份与模型

    var agentId: String = ""
    var name: String = ""
    var emoji: String = "🤖"
    var description: String = ""
    var category: AgentCategory = .strategy
    var selectedStyles: Set<String> = []
    var selectedProvider: String?  // nil = 自动

    // MARK: - Step 2: 工具（UI 占位）

    var enabledToolCategories: Set<String> = Set(AgentToolCategory.all.map(\.id))

    // MARK: - Step 3: 技能

    var enabledSkills: Set<String> = []

    // MARK: - Step 4: 用户信息

    var userDisplayName: String = ""
    var preferredLanguage: String = "中文"
    var userNotes: String = ""
    var userBackground: String = ""

    // MARK: - 提交状态

    var isCreating = false
    var errorMessage: String?

    // MARK: - 从模板预填

    func applyTemplate(_ template: Agent) {
        name = template.name
        emoji = template.emoji
        description = template.description
        category = template.category
        enabledSkills = Set(template.skills)
    }

    /// 自动生成 agentId（仅 ASCII 小写字母 + 数字 + 连字符）
    func generateAgentId() {
        // 只保留 ASCII 字母、数字和连字符，剔除中文等非 ASCII 字符
        let slug = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))   // 去掉首尾多余连字符
            .replacingOccurrences(of: "--", with: "-")                 // 合并连续连字符

        if slug.isEmpty {
            // 纯中文名或无有效字符 → 使用 UUID 短码
            agentId = "agent-\(UUID().uuidString.prefix(6).lowercased())"
        } else {
            agentId = String(slug.prefix(20))
        }
    }
}
