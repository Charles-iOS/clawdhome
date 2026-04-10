// ClawdHome/Views/Capabilities/SkillsView.swift

import SwiftUI

struct SkillsView: View {
    @Environment(GatewayService.self) private var gateway

    private var store: GatewaySkillsStore { gateway.skillsStore }

    var body: some View {
        List {
            if store.isLoading && store.skills.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if store.skills.isEmpty {
                Text(L10n.k("skills.empty", fallback: "暂无技能"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(store.skills) { skill in
                    SkillListItemRow(skill: skill)
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle(L10n.k("skills.title", fallback: "技能"))
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(L10n.k("common.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .disabled(!gateway.isConnected)
            }
        }
        .task { await store.refresh() }
    }
}
