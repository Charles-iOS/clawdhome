// EZRWorkerApp/Views/Capabilities/SkillsView.swift

import SwiftUI

struct SkillsView: View {
    @Environment(GatewayService.self) private var gateway

    private var store: GatewaySkillsStore { gateway.skillsStore }

    var body: some View {
        VStack(spacing: 0) {
            PageHeroHeader(
                title: L10n.k("skills.title", fallback: "技能"),
                subtitle: L10n.k("skills.hero.subtitle", fallback: "查看与管理 Gateway 已加载的技能列表。")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
