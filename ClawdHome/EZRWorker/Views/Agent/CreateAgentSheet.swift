// ClawdHome/Views/Agent/CreateAgentSheet.swift
// 创建新智能体：薄包装层，呈现多步向导

import SwiftUI

struct CreateAgentSheet: View {
    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        CreateAgentWizardView()
            .environment(store)
    }
}
