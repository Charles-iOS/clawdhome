// ClawdHome/Views/Agent/AgentCardView.swift

import SwiftUI

struct AgentCardView: View {
    let agent: Agent
    var onTap: () -> Void = {}

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(agent.emoji)
                        .font(.title)
                    if agent.isActive {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.caption)
                    }
                    Spacer()
                    if !agent.isPreset {
                        Image(systemName: "person.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Text(agent.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(agent.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                HStack(spacing: 4) {
                    ForEach(agent.skills.prefix(3), id: \.self) { skill in
                        Text("#\(skill)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.1))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(agent.isActive ? Color.green : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}
