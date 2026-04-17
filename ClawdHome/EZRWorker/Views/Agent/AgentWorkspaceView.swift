// ClawdHome/Views/Agent/AgentWorkspaceView.swift
// 智能体 Workspace 详情视图 — Tab 结构：Persona | Bindings | Sessions | Settings
//
// Persona Tab 实现分栏式多文件编辑器（复用 PersonaFile 枚举和 HelperClient 文件读写）

import SwiftUI

struct AgentWorkspaceView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(AgentWorkspaceManager.self) private var workspaceManager
    @Environment(HelperClient.self) private var helperClient

    @State private var selectedTab: WorkspaceTab = .persona
    @State private var showEditorSheet = false

    private var agent: Agent? {
        store.agents.first(where: { $0.id == agentId })
    }

    var body: some View {
        VStack(spacing: 0) {
            agentHeader
            tabPicker
            tabContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle(agent?.name ?? agentId)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showEditorSheet = true
                } label: {
                    Label(L10n.k("agent.workspace.edit", fallback: "编辑信息"), systemImage: "pencil")
                }
            }
        }
        .sheet(isPresented: $showEditorSheet) {
            if let agent {
                AgentEditorView(agent: agent)
            }
        }
        .task(id: agentId) {
            await store.refreshRuntimeState()
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var agentHeader: some View {
        if let agent {
            HStack(spacing: 12) {
                Text(agent.emoji).font(.largeTitle)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(agent.name).font(.title2).fontWeight(.semibold)
                        statusBadge(agent.status)
                    }
                    if !agent.description.isEmpty {
                        Text(agent.description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    // 绑定渠道 tags
                    if !agent.boundBindings.isEmpty {
                        HStack(spacing: 4) {
                            ForEach(agent.boundBindings) { binding in
                                Label(binding.channel, systemImage: binding.channelIcon)
                                    .font(.system(size: 10))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.1))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    @ViewBuilder
    private func statusBadge(_ status: AgentStatus) -> some View {
        switch status {
        case .active, .idle:
            EmptyView()
        case .uninitialized:
            Text(L10n.k("agent.status.uninitialized", fallback: "未初始化"))
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.orange.opacity(0.1))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        }
    }

    // MARK: - Tab Picker

    @ViewBuilder
    private var tabPicker: some View {
        Picker("", selection: $selectedTab) {
            ForEach(WorkspaceTab.allCases) { tab in
                Label(tab.label, systemImage: tab.icon).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        Group {
            switch selectedTab {
            case .persona:
                AgentPersonaEditorView(agentId: agentId)
            case .bindings:
                AgentBindingsView(agentId: agentId)
            case .sessions:
                AgentSessionsView(agentId: agentId)
            case .settings:
                AgentSettingsView(agentId: agentId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - WorkspaceTab

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case persona
    case bindings
    case sessions
    case settings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .persona:  return L10n.k("agent.tab.persona", fallback: "角色定义")
        case .bindings: return L10n.k("agent.tab.bindings", fallback: "渠道绑定")
        case .sessions: return L10n.k("agent.tab.sessions", fallback: "会话历史")
        case .settings: return L10n.k("agent.tab.settings", fallback: "设置")
        }
    }

    var icon: String {
        switch self {
        case .persona:  return "person.text.rectangle"
        case .bindings: return "arrow.triangle.branch"
        case .sessions: return "bubble.left.and.bubble.right"
        case .settings: return "gearshape"
        }
    }
}

// MARK: - Persona 编辑器 Tab

/// 分栏式 persona 文件编辑器（复用 CharacterDefTabView 的交互模式）
private struct AgentPersonaEditorView: View {
    let agentId: String

    @Environment(AgentWorkspaceManager.self) private var workspaceManager

    @State private var selectedFile: PersonaFile = .soul
    @State private var editorContents: [PersonaFile: String] = [:]
    @State private var savedContents: [PersonaFile: String] = [:]
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var loadError: String?
    @State private var saveToast: String?

    var body: some View {
        HSplitView {
            // 左侧文件列表
            fileSidebar
                .frame(minWidth: 150, idealWidth: 180, maxWidth: 210)

            // 右侧编辑器
            editorArea
        }
        .task {
            await loadFile(.soul)
        }
    }

    // MARK: - 左侧文件列表

    @ViewBuilder
    private var fileSidebar: some View {
        List(PersonaFile.allCases, selection: $selectedFile) { file in
            HStack(spacing: 8) {
                Text(file.icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.rawValue)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                    Text(file.description)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isDirty(file) {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .tag(file)
        }
        .listStyle(.sidebar)
        .onChange(of: selectedFile) { _, newFile in
            Task { await loadFile(newFile) }
        }
    }

    // MARK: - 右侧编辑器

    @ViewBuilder
    private var editorArea: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Text("\(selectedFile.icon) \(selectedFile.rawValue)")
                    .font(.headline)
                Spacer()
                if isDirty(selectedFile) {
                    Text(L10n.k("agent.persona.unsaved", fallback: "未保存"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(L10n.k("common.save", fallback: "保存")) {
                    Task { await saveCurrentFile() }
                }
                .disabled(!isDirty(selectedFile) || isSaving)
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            // 编辑器
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = loadError {
                ContentUnavailableView {
                    Label(L10n.k("agent.persona.load_error", fallback: "加载失败"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(err)
                }
            } else {
                TextEditor(text: Binding(
                    get: { editorContents[selectedFile] ?? "" },
                    set: { editorContents[selectedFile] = $0 }
                ))
                .font(.system(.body, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(8)
            }
        }
        .overlay(alignment: .bottom) {
            if let msg = saveToast {
                Text(msg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.thinMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .padding(.bottom, 16)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: saveToast)
    }

    // MARK: - 方法

    private func isDirty(_ file: PersonaFile) -> Bool {
        (editorContents[file] ?? "") != (savedContents[file] ?? "")
    }

    private func loadFile(_ file: PersonaFile) async {
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let content = try await workspaceManager.readPersonaFile(agentId: agentId, file: file)
            editorContents[file] = content
            savedContents[file] = content
        } catch {
            let msg = error.localizedDescription
            if isMissingFileError(msg) {
                editorContents[file] = editorContents[file] ?? ""
                savedContents[file] = savedContents[file] ?? ""
                loadError = nil
            } else {
                loadError = msg
            }
        }
    }

    private func saveCurrentFile() async {
        isSaving = true
        defer { isSaving = false }
        let content = editorContents[selectedFile] ?? ""
        do {
            try await workspaceManager.writePersonaFile(agentId: agentId, file: selectedFile, content: content)
            savedContents[selectedFile] = content
            saveToast = L10n.f("persona.save.toast.saved", fallback: "已保存 %@", selectedFile.rawValue)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                saveToast = nil
            }
        } catch {
            appLog("保存 persona 文件失败: \(error)", level: .error)
        }
    }

    private func isMissingFileError(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("no such file")
            || normalized.contains("not found")
            || normalized.contains("doesn't exist")
            || normalized.contains("doesn’t exist")
            || normalized.contains("couldn’t be opened")
            || normalized.contains("could not be opened")
            || normalized.contains("不存在")
    }
}

// MARK: - Settings Tab（智能体配置）

private struct AgentSettingsView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayService.self) private var gateway
    @Environment(GlobalModelStore.self) private var modelStore

    @State private var preferredModel = ""
    @State private var skillsAllowList = ""
    @State private var isSavingModel = false
    @State private var modelSaveError: String?

    private var agent: Agent? {
        store.agents.first(where: { $0.id == agentId })
    }

    var body: some View {
        Form {
            Section(L10n.k("agent.settings.model", fallback: "模型配置")) {
                Picker(
                    L10n.k("agent.settings.model_picker", fallback: "首选模型"),
                    selection: $preferredModel
                ) {
                    Text(L10n.k("agent.settings.model_default", fallback: "使用全局默认"))
                        .tag("")
                    Divider()
                    ForEach(modelStore.allTemplateModels) { model in
                        Text(model.label).tag(model.id)
                    }
                }
                .disabled(!gateway.isConnected || isSavingModel)
                .onChange(of: preferredModel) { _, newValue in
                    guard !isSavingModel else { return }
                    Task { await saveModel(newValue) }
                }

                if !gateway.isConnected {
                    Text(L10n.k("agent.settings.model_gateway_disconnected", fallback: "Gateway 未连接，无法修改模型"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let error = modelSaveError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section(L10n.k("agent.settings.skills", fallback: "Skills 允许列表")) {
                TextField(
                    L10n.k("agent.settings.skills_placeholder", fallback: "逗号分隔的 skill 名称（留空继承全局）"),
                    text: $skillsAllowList,
                    axis: .vertical
                )
                .lineLimit(3...6)
                Text(L10n.k("agent.settings.skills_hint", fallback: "对应 agents.list[].skills 配置"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(L10n.k("agent.settings.info", fallback: "信息")) {
                LabeledContent("Agent ID", value: agentId)
                if let agent {
                    LabeledContent(L10n.k("agent.settings.workspace_path", fallback: "Workspace 路径"),
                                   value: agent.workspace ?? "~/.openclaw/workspace\(agentId == "main" ? "" : "-\(agentId)")")
                    LabeledContent(L10n.k("agent.settings.bindings_count", fallback: "绑定数"),
                                   value: "\(agent.boundBindings.count)")
                    LabeledContent(L10n.k("agent.settings.sessions_count", fallback: "会话数"),
                                   value: "\(agent.sessionCount)")
                    if let lastActiveAt = agent.lastActiveAt {
                        LabeledContent(
                            L10n.k("agent.settings.last_active_at", fallback: "最近活跃"),
                            value: lastActiveAt.formatted(date: .abbreviated, time: .shortened)
                        )
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            preferredModel = agent?.preferredModel ?? ""
        }
    }

    private func saveModel(_ modelId: String) async {
        isSavingModel = true
        modelSaveError = nil
        do {
            try await store.setAgentModel(
                agentId: agentId,
                modelId: modelId.isEmpty ? nil : modelId
            )
        } catch {
            modelSaveError = error.localizedDescription
            // 回滚选择
            preferredModel = agent?.preferredModel ?? ""
        }
        isSavingModel = false
    }
}
