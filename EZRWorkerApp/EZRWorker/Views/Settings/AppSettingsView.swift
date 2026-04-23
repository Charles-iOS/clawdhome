// EZRWorkerApp/Views/Settings/SettingsView.swift

import SwiftUI

struct AppSettingsView: View {
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(EnvironmentChecker.self) private var envChecker
    @Environment(GatewayService.self) private var gatewayService
    @Environment(AuthSessionStore.self) private var authStore
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(SupervisorClient.self) private var supervisorClient
    @Environment(\.openWindow) private var openWindow

    @State private var showCreateProfileSheet = false
    @State private var pendingDeletionProfile: GatewayProfile?
    @State private var isDeletingProfile = false
    @State private var isRefreshingProfiles = false
    @State private var profileActionProfileID: UUID?
    @State private var profileErrorMessage: String?

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
                terminalSection
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
        .task {
            await refreshProfilesRuntime(reloadProfiles: true)
        }
        .onChange(of: profileStore.profiles) { _, _ in
            Task {
                await refreshProfilesRuntime(reloadProfiles: true)
            }
        }
        .confirmationDialog(
            "删除这个 Profile？",
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
            "Profile 操作失败",
            isPresented: Binding(
                get: { profileErrorMessage != nil },
                set: { if !$0 { profileErrorMessage = nil } }
            )
        ) {
            Button("好", role: .cancel) {
                profileErrorMessage = nil
            }
        } message: {
            Text(profileErrorMessage ?? "未知错误")
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
            if let selectedProfile = profileStore.selectedProfile {
                LabeledContent("当前 Profile", value: selectedProfile.displayName)
            }

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
    private var terminalSection: some View {
        Section("OpenClaw 终端") {
            if let selectedProfile = profileStore.selectedProfile,
               let selectedResolution = profileStore.selectedResolution {
                LabeledContent("当前 Profile", value: "\(selectedProfile.displayName) (\(selectedProfile.slug))")
                LabeledContent("工作目录", value: selectedResolution.resolvedWorkspaceRoot)

                Button {
                    openWindow(id: "profile-terminal", value: selectedProfile.id.uuidString)
                } label: {
                    Label("打开内嵌终端", systemImage: "terminal")
                }
                .buttonStyle(.borderedProminent)

                Text("终端会自动进入当前 profile 环境，可执行 openclaw configure --section model、openclaw agents list 等命令。openclaw gateway 会被保护，避免重复启动 Gateway。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("当前没有可用 profile，暂时无法打开 OpenClaw 终端。")
                    .foregroundStyle(.secondary)
            }
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

                Text("当前选中的 profile 会接入完整业务上下文；其他 profile 只展示 Supervisor 提供的轻量运行态。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("新建 Gateway/Profile") {
                        showCreateProfileSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isAnyProfileOperationInFlight)

                    if !profileStore.hasImportedLegacyProfile &&
                        FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path) {
                        Button("导入 ~/.openclaw") {
                            importLegacyProfile()
                        }
                        .buttonStyle(.bordered)
                        .disabled(isAnyProfileOperationInFlight)
                    }

                    Button("刷新运行态") {
                        Task {
                            await refreshProfilesRuntime(reloadProfiles: true)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isAnyProfileOperationInFlight)
                }

                if isRefreshingProfiles {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在同步 Profiles 运行态…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                ForEach(profileStore.profiles) { profile in
                    profileCard(for: profile)
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                }
            }
        }
    }

    @ViewBuilder
    private func profileCard(for profile: GatewayProfile) -> some View {
        let resolution = GatewayProfileResolver.resolve(profile)
        let runtime = runtime(for: profile)
        let isSelected = profileStore.selectedProfile?.id == profile.id
        let isBusy = isAnyProfileOperationInFlight

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.headline)

                        if isSelected {
                            profileBadge("当前", tint: .accentColor)
                        }

                        profileBadge(profileSourceLabel(for: profile), tint: profileSourceColor(for: profile))
                        profileBadge(profileRuntimeLabel(for: runtime), tint: profileRuntimeColor(for: runtime))
                    }

                    Text(profile.slug)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                if profileActionProfileID == profile.id {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Toggle("登录后自动恢复", isOn: Binding(
                get: {
                    profileStore.profiles.first(where: { $0.id == profile.id })?.autoStart ?? profile.autoStart
                },
                set: { newValue in
                    updateAutoStart(enabled: newValue, for: profile.id)
                }
            ))
            .disabled(isBusy)

            VStack(alignment: .leading, spacing: 6) {
                profileInfoRow("端口", "\(runtime?.resolvedPort ?? resolution.resolvedPort)")
                profileInfoRow("配置已准备", runtime?.isPrepared == true ? "是" : "否")
                profileInfoRow("运行权属", profileOwnershipLabel(for: runtime))
                profileInfoRow("PID", runtime?.pid.map(String.init) ?? "—")
                profileInfoRow("最近探测", probeTimeLabel(for: runtime?.lastProbeAt))
            }

            if let runtime,
               let lastError = runtime.lastError,
               !lastError.isEmpty {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            profilePathBlock(title: "Config", path: resolution.resolvedConfigPath)
            profilePathBlock(title: "State", path: resolution.resolvedStateDir)
            profilePathBlock(title: "Workspace", path: resolution.resolvedWorkspaceRoot)

            HStack(spacing: 8) {
                if !isSelected {
                    Button("切换到此 Profile") {
                        profileStore.selectProfile(id: profile.id)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy)
                }

                if shouldShowPrepareAction(for: runtime) {
                    Button(prepareActionTitle(for: runtime)) {
                        Task {
                            await runProfileAction(.prepare, profile: profile)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || profileRuntimeIsTransitional(runtime))
                }

                if runtime?.isRunning == true {
                    Button("停止") {
                        Task {
                            await runProfileAction(.stop, profile: profile)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || profileRuntimeIsTransitional(runtime))

                    Button("重启") {
                        Task {
                            await runProfileAction(.restart, profile: profile)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isBusy || profileRuntimeIsTransitional(runtime))
                } else {
                    Button("启动") {
                        Task {
                            await runProfileAction(.start, profile: profile)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy || profileRuntimeIsTransitional(runtime))
                }

                Button(role: .destructive) {
                    pendingDeletionProfile = profile
                } label: {
                    Text("删除")
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.7))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08),
                    lineWidth: 1
                )
        )
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

    private var isAnyProfileOperationInFlight: Bool {
        isDeletingProfile || isRefreshingProfiles || profileActionProfileID != nil
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

    private func runtime(for profile: GatewayProfile) -> SupervisorProfileRuntime? {
        supervisorClient.runtimes.first(where: { $0.profileID == profile.id })
    }

    private func profileSourceLabel(for profile: GatewayProfile) -> String {
        switch profile.sourceKind {
        case .managed:
            return "托管"
        case .legacyReuse:
            return "复用旧实例"
        }
    }

    private func profileSourceColor(for profile: GatewayProfile) -> Color {
        switch profile.sourceKind {
        case .managed:
            return .blue
        case .legacyReuse:
            return .orange
        }
    }

    private func profileRuntimeLabel(for runtime: SupervisorProfileRuntime?) -> String {
        guard let runtime else { return "未同步" }

        switch runtime.readyState {
        case .unknown:
            return runtime.isRunning ? "运行中" : "未知"
        case .stopped:
            return runtime.isPrepared ? "已停止" : "未准备"
        case .preparing:
            return "准备中"
        case .starting:
            return "启动中"
        case .ready:
            return runtime.isRunning ? "运行中" : "已准备"
        case .failed:
            return "异常"
        }
    }

    private func profileRuntimeColor(for runtime: SupervisorProfileRuntime?) -> Color {
        guard let runtime else { return .secondary }

        switch runtime.readyState {
        case .ready:
            return runtime.isRunning ? .green : .blue
        case .preparing, .starting:
            return .orange
        case .failed:
            return .red
        case .stopped, .unknown:
            return .secondary
        }
    }

    private func profileOwnershipLabel(for runtime: SupervisorProfileRuntime?) -> String {
        guard let runtime else { return "—" }

        switch runtime.ownership {
        case .none:
            return "无"
        case .supervised:
            return "supervised"
        case .adopted:
            return "adopted"
        }
    }

    private func probeTimeLabel(for date: Date?) -> String {
        guard let date else { return "—" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func profileRuntimeIsTransitional(_ runtime: SupervisorProfileRuntime?) -> Bool {
        guard let runtime else { return false }
        switch runtime.readyState {
        case .preparing, .starting:
            return true
        default:
            return false
        }
    }

    private func shouldShowPrepareAction(for runtime: SupervisorProfileRuntime?) -> Bool {
        runtime?.isRunning != true
    }

    private func prepareActionTitle(for runtime: SupervisorProfileRuntime?) -> String {
        runtime?.isPrepared == true ? "重新准备配置" : "准备配置"
    }

    private func updateAutoStart(enabled: Bool, for profileID: UUID) {
        do {
            try profileStore.update(profileID: profileID, autoStart: enabled)
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func importLegacyProfile() {
        do {
            _ = try profileStore.importLegacyProfile()
        } catch {
            profileErrorMessage = error.localizedDescription
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
    private func ensureSupervisorReady() async throws {
        if supervisorClient.isConnected {
            return
        }

        supervisorClient.connect()
        guard await supervisorClient.waitUntilConnected() else {
            throw NSError(domain: "AppSettingsView", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "EZRWorkerSupervisor 未就绪"
            ])
        }
    }

    @MainActor
    private func refreshProfilesRuntime(reloadProfiles: Bool) async {
        guard !isRefreshingProfiles else { return }

        isRefreshingProfiles = true
        defer { isRefreshingProfiles = false }

        do {
            try await ensureSupervisorReady()
            if reloadProfiles {
                guard await supervisorClient.reloadProfiles() else {
                    throw NSError(domain: "AppSettingsView", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Profiles 运行态刷新失败"
                    ])
                }
            } else {
                _ = await supervisorClient.refreshRuntimes()
            }

            await processManager.refreshRuntimeState()
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func runProfileAction(_ action: ProfileLifecycleAction, profile: GatewayProfile) async {
        guard profileActionProfileID == nil else { return }

        profileActionProfileID = profile.id
        defer { profileActionProfileID = nil }

        do {
            try await ensureSupervisorReady()

            switch action {
            case .prepare:
                try await supervisorClient.prepareProfile(profileID: profile.id)
            case .start:
                try await supervisorClient.startProfile(profileID: profile.id)
            case .stop:
                try await supervisorClient.stopProfile(profileID: profile.id)
            case .restart:
                try await supervisorClient.restartProfile(profileID: profile.id)
            }

            await processManager.refreshRuntimeState()
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deleteProfile(_ profile: GatewayProfile) async {
        guard !isDeletingProfile else { return }
        isDeletingProfile = true
        defer { isDeletingProfile = false }

        do {
            try await ensureSupervisorReady()
            try await supervisorClient.stopProfile(profileID: profile.id)
            _ = try profileStore.deleteProfile(profileID: profile.id)
            guard await supervisorClient.reloadProfiles() else {
                throw NSError(domain: "AppSettingsView", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Profile 已删除，但 Supervisor 同步新列表失败"
                ])
            }
            await processManager.refreshRuntimeState()
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }
}

private enum ProfileLifecycleAction {
    case prepare
    case start
    case stop
    case restart
}

private struct ProfileBadge: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

private extension AppSettingsView {
    func profileBadge(_ title: String, tint: Color) -> some View {
        ProfileBadge(title: title, tint: tint)
    }

    func profileInfoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption)
        }
    }

    func profilePathBlock(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
