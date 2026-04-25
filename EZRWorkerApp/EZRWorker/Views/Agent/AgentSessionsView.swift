// EZRWorkerApp/Views/Agent/AgentSessionsView.swift
// 浏览智能体的对话历史（sessions 目录）

import SwiftUI

private enum AgentSessionsFont {
    static let title: CGFloat = 20
    static let body: CGFloat = 16
    static let detail: CGFloat = 15
    static let meta: CGFloat = 14
    static let mono: CGFloat = 13
}

struct AgentSessionsView: View {
    let agentId: String

    private let autoRefreshIntervalNanoseconds: UInt64 = 15_000_000_000
    private let sessionListWidth: CGFloat = 360

    @Environment(AgentWorkspaceManager.self) private var workspaceManager

    @State private var sessions: [FileEntry] = []
    @State private var selectedSession: FileEntry?
    @State private var sessionContent = ""
    @State private var isLoadingSessions = false
    @State private var loadingSessionName: String?
    @State private var loadError: String?
    @State private var searchText = ""

    private var filteredSessions: [FileEntry] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sessions }
        return sessions.filter {
            $0.name.localizedCaseInsensitiveContains(trimmed)
                || ByteCountFormatter.string(fromByteCount: $0.size, countStyle: .file).localizedCaseInsensitiveContains(trimmed)
        }
    }

    private var isLoadingContent: Bool {
        loadingSessionName != nil
    }

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: sessionListWidth)

            Divider()

            sessionDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .transaction { transaction in
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
        .task(id: agentId) {
            await loadSessions()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: autoRefreshIntervalNanoseconds)
                await refreshSessionsIfNeeded()
            }
        }
        .onChange(of: selectedSession) { _, newValue in
            if let session = newValue {
                Task { await loadSessionContent(session) }
            } else {
                sessionContent = ""
            }
        }
    }

    // MARK: - 会话列表

    @ViewBuilder
    private var sessionList: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.k("agent.sessions.title", fallback: "会话历史"))
                        .font(.system(size: AgentSessionsFont.title, weight: .semibold))
                    Text(L10n.k("agent.sessions.count", fallback: "\(sessions.count) 个会话"))
                        .font(.system(size: AgentSessionsFont.detail))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await loadSessions() }
                } label: {
                    if isLoadingSessions {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 30, height: 30)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isLoadingSessions)
                .help(L10n.k("common.refresh", fallback: "刷新"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            if !sessions.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(L10n.k("agent.sessions.search", fallback: "搜索会话…"), text: $searchText)
                        .textFieldStyle(.plain)
                }
                .font(.system(size: AgentSessionsFont.detail))
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
                )
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            }

            Divider()

            if isLoadingSessions && sessions.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sessions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.k("agent.sessions.empty", fallback: "暂无会话"), systemImage: "bubble.left.and.bubble.right")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredSessions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.k("agent.sessions.no_results", fallback: "没有匹配的会话"), systemImage: "magnifyingglass")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredSessions, id: \.name) { entry in
                            Button {
                                selectedSession = entry
                            } label: {
                                sessionRow(entry)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())

                            Divider()
                                .padding(.leading, 16)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private func sessionRow(_ entry: FileEntry) -> some View {
        let isSelected = selectedSession?.name == entry.name
        VStack(alignment: .leading, spacing: 5) {
            Text(sessionDisplayName(entry.name))
                .font(.system(size: AgentSessionsFont.mono, weight: .medium, design: .monospaced))
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(entry.name)

            HStack(spacing: 8) {
                if let modifiedAt = entry.modifiedAt {
                    Text(modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
                if entry.size > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                }
            }
            .font(.system(size: AgentSessionsFont.meta))
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // MARK: - 会话详情

    @ViewBuilder
    private var sessionDetail: some View {
        if selectedSession == nil {
            ContentUnavailableView {
                Label(L10n.k("agent.sessions.select", fallback: "选择一个会话"), systemImage: "text.bubble")
            }
        } else {
            VStack(spacing: 0) {
                if let selectedSession {
                    HStack(alignment: .center, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedSession.name)
                                .font(.system(size: AgentSessionsFont.title, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(ByteCountFormatter.string(fromByteCount: selectedSession.size, countStyle: .file))
                                .font(.system(size: AgentSessionsFont.detail))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    Divider()
                }

                if isLoadingContent {
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
                            .font(.system(size: AgentSessionsFont.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(20)
                            .textSelection(.enabled)
                    }
                }
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - 数据加载

    private func loadSessions(showLoading: Bool = true) async {
        guard !isLoadingSessions else { return }
        if showLoading {
            isLoadingSessions = true
        }
        defer {
            if showLoading {
                isLoadingSessions = false
            }
        }
        do {
            let loadedSessions = try await workspaceManager.listSessions(agentId: agentId)
                .sorted(by: { $0.name > $1.name }) // 最新在前
            sessions = loadedSessions
            if let selectedSession,
               !loadedSessions.contains(where: { $0.name == selectedSession.name }) {
                self.selectedSession = nil
            }
        } catch {
            sessions = []
        }
    }

    private func loadSessionContent(_ entry: FileEntry) async {
        loadingSessionName = entry.name
        loadError = nil
        defer {
            if loadingSessionName == entry.name {
                loadingSessionName = nil
            }
        }
        do {
            let path = try workspaceManager.sessionsDirPath(for: agentId) + "/\(entry.name)"
            let data = try await workspaceManager.readRelativeFile(path)
            guard selectedSession?.name == entry.name else { return }
            sessionContent = String(data: data, encoding: .utf8) ?? ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func sessionDisplayName(_ name: String) -> String {
        name.replacingOccurrences(of: "-", with: "-\u{200B}")
    }

    private func refreshSessionsIfNeeded() async {
        do {
            let latest = try await workspaceManager.listSessions(agentId: agentId)
                .sorted(by: { $0.name > $1.name })
            let latestNames = latest.map(\.name)
            let currentNames = sessions.map(\.name)
            guard latestNames != currentNames else { return }
            sessions = latest
            if let current = selectedSession {
                selectedSession = latest.first(where: { $0.name == current.name })
            }
        } catch {
            appLog("[agent.sessions] 刷新会话列表失败: \(error)", level: .warn)
        }
    }
}
