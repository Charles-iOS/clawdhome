// ClawdHome/Views/Agent/AgentBindingsView.swift
// 管理单个智能体的渠道绑定

import SwiftUI

struct AgentBindingsView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @State private var showAddSheet = false

    private var agentBindings: [AgentBinding] {
        store.bindings(for: agentId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Text(L10n.k("agent.bindings.title", fallback: "渠道绑定"))
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.k("agent.bindings.add", fallback: "添加绑定"), systemImage: "plus")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if agentBindings.isEmpty {
                ContentUnavailableView {
                    Label(L10n.k("agent.bindings.empty", fallback: "暂无绑定"), systemImage: "arrow.triangle.branch")
                } description: {
                    Text(L10n.k("agent.bindings.empty_desc", fallback: "添加渠道绑定后，入站消息将路由到此智能体"))
                }
            } else {
                List {
                    ForEach(agentBindings) { binding in
                        bindingRow(binding)
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                try? await store.removeBinding(agentBindings[index])
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddBindingSheet(agentId: agentId)
        }
    }

    @ViewBuilder
    private func bindingRow(_ binding: AgentBinding) -> some View {
        HStack(spacing: 10) {
            Image(systemName: binding.channelIcon)
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(binding.channel.capitalized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(binding.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                Task { try? await store.removeBinding(binding) }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 添加绑定 Sheet

private struct AddBindingSheet: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var channel = "whatsapp"
    @State private var accountId = ""
    @State private var peerId = ""
    @State private var peerKind = ""
    @State private var guildId = ""
    @State private var isAdding = false

    private let channels = ["whatsapp", "telegram", "discord", "slack", "signal", "imessage", "line"]

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.k("agent.binding.channel", fallback: "渠道")) {
                    Picker(L10n.k("agent.binding.channel_select", fallback: "选择渠道"), selection: $channel) {
                        ForEach(channels, id: \.self) { ch in
                            Text(ch.capitalized).tag(ch)
                        }
                    }
                }

                Section(L10n.k("agent.binding.account", fallback: "账号（可选）")) {
                    TextField(
                        L10n.k("agent.binding.account_placeholder", fallback: "账号 ID（留空使用默认账号）"),
                        text: $accountId
                    )
                }

                Section(L10n.k("agent.binding.peer", fallback: "Peer 匹配（可选）")) {
                    TextField(
                        L10n.k("agent.binding.peer_id", fallback: "Peer ID（如电话号码、群组 ID）"),
                        text: $peerId
                    )
                    Picker(L10n.k("agent.binding.peer_kind", fallback: "Peer 类型"), selection: $peerKind) {
                        Text(L10n.k("agent.binding.peer_any", fallback: "不限")).tag("")
                        Text(L10n.k("agent.binding.peer_direct", fallback: "私信")).tag("direct")
                        Text(L10n.k("agent.binding.peer_group", fallback: "群组")).tag("group")
                    }
                }

                if channel == "discord" {
                    Section("Discord") {
                        TextField("Guild ID", text: $guildId)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.k("agent.binding.add_title", fallback: "添加渠道绑定"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.k("agent.binding.add_confirm", fallback: "添加")) { addBinding() }
                        .disabled(isAdding)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }

    private func addBinding() {
        isAdding = true
        let binding = AgentBinding(
            agentId: agentId,
            channel: channel,
            accountId: accountId.isEmpty ? nil : accountId,
            peerId: peerId.isEmpty ? nil : peerId,
            peerKind: peerKind.isEmpty ? nil : peerKind,
            guildId: guildId.isEmpty ? nil : guildId
        )
        Task {
            do {
                try await store.addBinding(binding)
                dismiss()
            } catch {
                appLog("添加绑定失败: \(error)", level: .error)
                isAdding = false
            }
        }
    }
}
