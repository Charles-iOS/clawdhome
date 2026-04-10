// ClawdHome/Views/Capabilities/SkillItemRow.swift

import SwiftUI

struct SkillListItemRow: View {
    let skill: GatewaySkillStatus

    @Environment(GatewayService.self) private var gateway
    @State private var errorText: String?

    private var store: GatewaySkillsStore { gateway.skillsStore }
    private var isPending: Bool { store.pendingOps[skill.skillKey] != nil }

    var body: some View {
        HStack(spacing: 12) {
            Text(skill.emoji ?? "🔧")
                .font(.title2)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.name)
                    .fontWeight(.medium)
                Text(skill.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let err = errorText {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }

            Spacer()

            statusBadge

            actionButtons
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let op = store.pendingOps[skill.skillKey] {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small)
                Text(op).font(.caption)
            }
        } else if skill.disabled {
            Text(L10n.k("skills.disabled", fallback: "已禁用"))
                .font(.caption)
                .foregroundStyle(.orange)
        } else if skill.eligible {
            Text(L10n.k("skills.active", fallback: "可用"))
                .font(.caption)
                .foregroundStyle(.green)
        } else if !skill.missing.isEmpty {
            Text(L10n.k("skills.missing_deps", fallback: "缺少依赖"))
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if !isPending {
            HStack(spacing: 4) {
                if skill.eligible {
                    Button(L10n.k("skills.update", fallback: "更新")) {
                        Task { await update() }
                    }
                    .controlSize(.small)
                    Button(L10n.k("skills.remove", fallback: "卸载")) {
                        Task { await remove() }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func update() async {
        errorText = nil
        do {
            try await store.update(skillKey: skill.skillKey)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func remove() async {
        errorText = nil
        do {
            try await store.remove(skillKey: skill.skillKey)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
