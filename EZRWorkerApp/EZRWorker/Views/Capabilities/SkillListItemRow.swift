// EZRWorkerApp/Views/Capabilities/SkillItemRow.swift

import SwiftUI

struct SkillListItemRow: View {
    let skill: GatewaySkillStatus

    @Environment(GatewayService.self) private var gateway
    @State private var errorText: String?

    private var store: GatewaySkillsStore { gateway.skillsStore }
    private var isPending: Bool { store.pendingOps[skill.skillKey] != nil }

    var body: some View {
        HStack(spacing: 16) {
            Text(skill.emoji ?? "🔧")
                .font(.system(size: 28))

            VStack(alignment: .leading, spacing: 6) {
                Text(skill.name)
                    .font(.system(size: 17, weight: .semibold))
                Text(skill.description)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let err = errorText {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            statusBadge
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let op = store.pendingOps[skill.skillKey] {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(op)
                    .font(.system(size: 13, weight: .medium))
            }
        } else if skill.disabled {
            Text(L10n.k("skills.disabled", fallback: "已禁用"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.orange)
        } else if skill.eligible {
            Text(L10n.k("skills.active", fallback: "可用"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.green)
        } else if !skill.missing.isEmpty {
            Text(L10n.k("skills.missing_deps", fallback: "缺少依赖"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.red)
        }
    }

}
