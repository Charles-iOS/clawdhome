// ClawdHome/Views/Agent/AgentSessionsView.swift
// 浏览智能体的对话历史（sessions 目录）

import SwiftUI

struct AgentSessionsView: View {
    let agentId: String

    @Environment(AgentWorkspaceManager.self) private var workspaceManager
    @Environment(HelperClient.self) private var helperClient

    @State private var sessions: [FileEntry] = []
    @State private var selectedSession: FileEntry?
    @State private var sessionContent = ""
    @State private var isLoading = false
    @State private var loadError: String?

    var body: some View {
        HSplitView {
            // 左侧会话列表
            sessionList
                .frame(minWidth: 200, idealWidth: 250, maxWidth: 300)

            // 右侧会话内容
            sessionDetail
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            await loadSessions()
        }
    }

    // MARK: - 会话列表

    @ViewBuilder
    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.k("agent.sessions.title", fallback: "会话历史"))
                    .font(.headline)
                Spacer()
                Button {
                    Task { await loadSessions() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if sessions.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label(L10n.k("agent.sessions.empty", fallback: "暂无会话"), systemImage: "bubble.left.and.bubble.right")
                }
            } else {
                List(sessions, id: \.name, selection: $selectedSession) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        if entry.size > 0 {
                            Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(entry)
                }
                .listStyle(.sidebar)
                .onChange(of: selectedSession) { _, newValue in
                    if let session = newValue {
                        Task { await loadSessionContent(session) }
                    }
                }
            }
        }
    }

    // MARK: - 会话详情

    @ViewBuilder
    private var sessionDetail: some View {
        if selectedSession == nil {
            ContentUnavailableView {
                Label(L10n.k("agent.sessions.select", fallback: "选择一个会话"), systemImage: "text.bubble")
            }
        } else if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let err = loadError {
            ContentUnavailableView {
                Label(L10n.k("agent.sessions.error", fallback: "加载失败"), systemImage: "exclamationmark.triangle")
            } description: {
                Text(err)
            }
        } else {
            ScrollView {
                Text(sessionContent)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 数据加载

    private func loadSessions() async {
        isLoading = true
        defer { isLoading = false }
        do {
            sessions = try await workspaceManager.listSessions(agentId: agentId)
                .sorted(by: { $0.name > $1.name }) // 最新在前
        } catch {
            sessions = []
        }
    }

    private func loadSessionContent(_ entry: FileEntry) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let path = workspaceManager.sessionsDirPath(for: agentId) + "/\(entry.name)"
            let data = try await helperClient.readFile(
                username: workspaceManager.username,
                relativePath: path
            )
            sessionContent = String(data: data, encoding: .utf8) ?? ""
        } catch {
            loadError = error.localizedDescription
        }
    }
}
