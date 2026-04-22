// EZRWorkerApp/Views/Settings/SettingsView.swift

import SwiftUI

struct AppSettingsView: View {
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(EnvironmentChecker.self) private var envChecker
    @Environment(GatewayService.self) private var gatewayService
    @Environment(AuthSessionStore.self) private var authStore
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(SupervisorClient.self) private var supervisorClient

    @State private var showCreateProfileSheet = false
    @State private var pendingDeletionProfile: GatewayProfile?
    @State private var isDeletingProfile = false
    @State private var profileDeletionError: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeroHeader(
                title: L10n.k("settings.title", fallback: "设置"),
                subtitle: L10n.k("settings.hero.subtitle", fallback: "Gateway、运行环境与版本信息。")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                accountSection
                profilesSection
                gatewaySection
                environmentSection
                aboutSection
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCreateProfileSheet) {
            CreateProfileSheet()
                .environment(profileStore)
        }
        .confirmationDialog(
            "删除当前 Profile？",
            isPresented: Binding(
                get: { pendingDeletionProfile != nil },
                set: { if !$0 { pendingDeletionProfile = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {
                pendingDeletionProfile = nil
            }

            if let profile = pendingDeletionProfile {
                Button("删除 \(profile.displayName)", role: .destructive) {
                    let targetProfile = profile
                    pendingDeletionProfile = nil
                    Task {
                        await deleteProfile(targetProfile)
                    }
                }
            }
        } message: {
            if let profile = pendingDeletionProfile {
                Text(deleteMessage(for: profile))
            }
        }
        .alert(
            "删除 Profile 失败",
            isPresented: Binding(
                get: { profileDeletionError != nil },
                set: { if !$0 { profileDeletionError = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                profileDeletionError = nil
            }
        } message: {
            Text(profileDeletionError ?? "未知错误")
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section(L10n.k("auth.settings.section", fallback: "账户")) {
            LabeledContent(
                L10n.k("auth.settings.phone", fallback: "当前登录手机号"),
                value: authStore.currentUser.map { displayMainlandChinaPhone($0.phone) } ?? "—"
            )
            LabeledContent(
                L10n.k("auth.settings.display_name", fallback: "显示名称"),
                value: authStore.currentUser?.displayName ?? "—"
            )

            Button(role: .destructive) {
                Task {
                    await authStore.signOut()
                }
            } label: {
                Text(L10n.k("auth.settings.sign_out", fallback: "退出登录"))
            }
        }
    }

    @ViewBuilder
    private var gatewaySection: some View {
        Section(L10n.k("settings.gateway", fallback: "Gateway")) {
            LabeledContent(
                L10n.k("settings.port", fallback: "端口"),
                value: "\(processManager.gatewayPort)"
            )
            LabeledContent(
                L10n.k("settings.state", fallback: "状态"),
                value: stateLabel
            )
            LabeledContent(
                L10n.k("dashboard.gateway_status", fallback: "WebSocket"),
                value: gatewayService.isConnected
                    ? L10n.k("dashboard.connected", fallback: "已连接")
                    : L10n.k("dashboard.disconnected", fallback: "未连接")
            )

            HStack(spacing: 12) {
                Button(L10n.k("user.detail.auto.start_action", fallback: "启动")) {
                    processManager.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(processManager.state == .starting || processManager.state == .running)

                Button(L10n.k("user.detail.auto.restart", fallback: "重启")) {
                    processManager.restart()
                }
                .buttonStyle(.bordered)
                .disabled(processManager.state == .starting || processManager.state == .stopping)

                Button(L10n.k("user.detail.auto.stop", fallback: "停止")) {
                    processManager.stop()
                }
                .buttonStyle(.bordered)
                .disabled(processManager.state == .stopped || processManager.state == .stopping)
            }

            Text(gatewayActionHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var profilesSection: some View {
        Section("Profiles") {
            if profileStore.profiles.isEmpty {
                Text("当前还没有可用 profile")
                    .foregroundStyle(.secondary)
            } else {
                Picker("当前 Profile", selection: Binding(
                    get: { profileStore.selectedProfileID ?? profileStore.profiles.first?.id ?? UUID() },
                    set: { profileStore.selectProfile(id: $0) }
                )) {
                    ForEach(profileStore.profiles) { profile in
                        Text("\(profile.displayName) (\(profile.slug))")
                            .tag(profile.id)
                    }
                }

                if let selected = profileStore.selectedProfile,
                   let resolution = profileStore.selectedResolution {
                    LabeledContent("来源", value: selected.sourceKind == .legacyReuse ? "legacyReuse" : "managed")
                    LabeledContent("Slug", value: selected.slug)
                    LabeledContent("Config", value: resolution.resolvedConfigPath)
                    LabeledContent("State", value: resolution.resolvedStateDir)
                    LabeledContent("Workspace", value: resolution.resolvedWorkspaceRoot)
                    LabeledContent("Port", value: "\(resolution.resolvedPort)")
                    Toggle("当前 Profile 自动启动", isOn: Binding(
                        get: { selected.autoStart },
                        set: { newValue in
                            try? profileStore.update(profileID: selected.id, autoStart: newValue)
                            Task { _ = await supervisorClient.reloadProfiles() }
                        }
                    ))
                }
            }

            HStack(spacing: 12) {
                Button("新建 Gateway/Profile") {
                    showCreateProfileSheet = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(isDeletingProfile)

                if !profileStore.hasImportedLegacyProfile &&
                    FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path) {
                    Button("导入 ~/.openclaw") {
                        do {
                            _ = try profileStore.importLegacyProfile()
                            Task { _ = await supervisorClient.reloadProfiles() }
                        } catch { }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeletingProfile)
                }

                if let selected = profileStore.selectedProfile {
                    Button(role: .destructive) {
                        pendingDeletionProfile = selected
                    } label: {
                        Text(isDeletingProfile ? "删除中…" : "删除当前 Profile")
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeletingProfile)
                }
            }
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        Section(L10n.k("settings.environment", fallback: "环境")) {
            LabeledContent(
                "Node.js",
                value: GatewayProcessManager.bundledNodeURL.path
            )
            LabeledContent(
                "OpenClaw",
                value: GatewayProcessManager.bundledOpenClawEntry.path
            )
            switch envChecker.status {
            case .ready:
                LabeledContent(
                    L10n.k("settings.env_status", fallback: "环境状态"),
                    value: L10n.k("settings.env_ready", fallback: "就绪")
                )
            case .missing(let msg):
                LabeledContent(
                    L10n.k("settings.env_status", fallback: "环境状态"),
                    value: msg
                )
            default:
                EmptyView()
            }
            Button(L10n.k("settings.recheck", fallback: "重新检查")) {
                Task { await envChecker.check() }
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section(L10n.k("settings.about", fallback: "关于")) {
            LabeledContent(
                L10n.k("settings.version", fallback: "版本"),
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
            )
            LabeledContent(
                L10n.k("settings.build", fallback: "构建号"),
                value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
            )
        }
    }

    private var stateLabel: String {
        switch processManager.state {
        case .running: return L10n.k("dashboard.running", fallback: "运行中")
        case .stopping: return L10n.k("dashboard.stopping", fallback: "正在停止…")
        case .starting: return L10n.k("dashboard.starting", fallback: "正在启动…")
        case .stopped: return L10n.k("dashboard.stopped", fallback: "已停止")
        case .failed(let msg): return msg
        }
    }

    private var gatewayActionHint: String {
        switch processManager.state {
        case .running:
            return gatewayService.isConnected
                ? "Gateway 正在运行，可在这里重启或停止。"
                : "Gateway 进程已启动，正在等待连接恢复。"
        case .starting:
            return "Gateway 正在启动中，请稍候。"
        case .stopping:
            return "Gateway 正在停止中，请稍候。"
        case .stopped:
            return "Gateway 当前已停止，可在这里重新启动。"
        case .failed:
            return "Gateway 当前处于异常状态，建议尝试重启。"
        }
    }

    private func deleteMessage(for profile: GatewayProfile) -> String {
        let cleanupMessage: String
        if profile.sourceKind == .managed {
            cleanupMessage = "这会删除当前 profile 记录，并清理 App Support 下该 profile 的托管数据目录。"
        } else {
            cleanupMessage = "这会删除当前 profile 记录，但不会删除 ~/.openclaw 原始数据。"
        }

        if profileStore.profiles.count == 1 {
            return "\(cleanupMessage) 删除后会自动创建新的默认 profile，避免应用落到无 profile 状态。"
        }

        return "\(cleanupMessage) 删除后会自动切换到其他 profile。"
    }

    @MainActor
    private func deleteProfile(_ profile: GatewayProfile) async {
        guard !isDeletingProfile else { return }
        isDeletingProfile = true
        defer { isDeletingProfile = false }

        do {
            if !supervisorClient.isConnected {
                supervisorClient.connect()
                guard await supervisorClient.waitUntilConnected() else {
                    throw NSError(domain: "AppSettingsView", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "EZRWorkerSupervisor 未就绪"
                    ])
                }
            }

            try await supervisorClient.stopProfile(profileID: profile.id)
            let result = try profileStore.deleteProfile(profileID: profile.id)

            if !result.deletedWasSelected {
                _ = await supervisorClient.reloadProfiles()
                await processManager.refreshRuntimeState()
            }
        } catch {
            profileDeletionError = error.localizedDescription
        }
    }
}
