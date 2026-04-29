// EZRWorkerApp/Views/Settings/SettingsView.swift

import AppKit
import SwiftUI

struct AppSettingsView: View {
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(EnvironmentChecker.self) private var envChecker
    @Environment(GatewayService.self) private var gatewayService
    @Environment(AuthSessionStore.self) private var authStore
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(SupervisorClient.self) private var supervisorClient
    @Environment(UpdateChecker.self) private var updater
    @Environment(\.openWindow) private var openWindow

    @State private var showCreateProfileSheet = false
    @State private var showAppUpdateSheet = false
    @State private var pendingDeletionProfile: GatewayProfile?
    @State private var isDeletingProfile = false
    @State private var isRefreshingProfiles = false
    @State private var isScanningExistingOpenClaw = false
    @State private var showExistingOpenClawImportSheet = false
    @State private var existingOpenClawImportCandidates: [OpenClawInstanceCandidate] = []
    @State private var profileActionProfileID: UUID?
    @State private var profileErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                statusOverviewGrid
                profilesSection
                gatewayDiagnosticsSection
                toolGrid
                systemInfoGrid
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showCreateProfileSheet) {
            CreateProfileSheet()
                .environment(profileStore)
        }
        .sheet(isPresented: $showAppUpdateSheet) {
            AppUpdateSheet()
                .environment(updater)
        }
        .sheet(isPresented: $showExistingOpenClawImportSheet) {
            ExistingOpenClawImportView(candidates: existingOpenClawImportCandidates)
                .environment(profileStore)
                .environment(supervisorClient)
                .environment(processManager)
                .frame(minWidth: 860, minHeight: 640)
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
    private var heroSection: some View {
        PageHeroHeader(
            title: L10n.k("settings.title", fallback: "设置"),
            subtitle: L10n.k("settings.hero.subtitle", fallback: "Profile、运行环境与版本信息。")
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var statusOverviewGrid: some View {
        LazyVGrid(columns: overviewColumns, alignment: .leading, spacing: 16) {
            SettingsOverviewCard(
                icon: "person.crop.circle",
                title: "当前 Profile",
                value: profileStore.selectedProfile?.displayName ?? "未选择",
                subtitle: profileStore.selectedProfile?.slug ?? "等待 profile 准备",
                tint: .accentColor
            )
            SettingsOverviewCard(
                icon: "wave.3.right.circle.fill",
                title: L10n.k("dashboard.gateway_status", fallback: "WebSocket"),
                value: gatewayService.isConnected
                    ? L10n.k("dashboard.connected", fallback: "已连接")
                    : L10n.k("dashboard.disconnected", fallback: "未连接"),
                subtitle: gatewayService.isConnected ? "业务通道可用" : "等待连接恢复",
                tint: gatewayService.isConnected ? .green : .secondary
            )
            SettingsOverviewCard(
                icon: "shippingbox.circle.fill",
                title: L10n.k("settings.environment", fallback: "环境"),
                value: environmentStatusValue,
                subtitle: environmentStatusSubtitle,
                tint: environmentStatusColor
            )
        }
    }

    @ViewBuilder
    private var toolGrid: some View {
        HStack(alignment: .top, spacing: 20) {
            terminalSection
                .frame(maxWidth: .infinity, alignment: .topLeading)
            environmentSection
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var systemInfoGrid: some View {
        responsiveTwoColumnRow {
            accountSection
        } trailing: {
            aboutSection
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        SettingsSectionCard(
            L10n.k("auth.settings.section", fallback: "账户"),
            minHeight: SettingsLayout.systemCardMinHeight
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsInfoRow(
                    L10n.k("auth.settings.phone", fallback: "当前登录手机号"),
                    value: authStore.currentUser.map { displayMainlandChinaPhone($0.phone) } ?? "—"
                )
                SettingsInfoRow(
                    L10n.k("auth.settings.display_name", fallback: "显示名称"),
                    value: authStore.currentUser?.displayName ?? "—"
                )

                Divider()
                    .padding(.vertical, 2)

                Button(role: .destructive) {
                    Task {
                        await authStore.signOut()
                    }
                } label: {
                    Text(L10n.k("auth.settings.sign_out", fallback: "退出登录"))
                        .font(.system(size: SettingsFont.action, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var terminalSection: some View {
        SettingsSectionCard(
            "OpenClaw 终端",
            subtitle: "进入当前 Profile 的命令行环境。",
            minHeight: SettingsLayout.systemCardMinHeight
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let selectedProfile = profileStore.selectedProfile,
                   let selectedResolution = profileStore.selectedResolution {
                    SettingsInfoRow("当前 Profile", value: "\(selectedProfile.displayName) (\(selectedProfile.slug))")
                    SettingsPathBlock(title: "工作目录", path: selectedResolution.resolvedWorkspaceRoot)

                    Button {
                        openWindow(id: "profile-terminal", value: selectedProfile.id.uuidString)
                    } label: {
                        Label("打开内嵌终端", systemImage: "terminal")
                            .font(.system(size: SettingsFont.action, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Text("终端会自动进入当前 profile 环境，可执行 openclaw configure --section model、openclaw agents list 等命令。openclaw gateway 会被保护，避免重复启动 Gateway。")
                        .font(.system(size: SettingsFont.detail))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("当前没有可用 profile，暂时无法打开 OpenClaw 终端。")
                        .font(.system(size: SettingsFont.body))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Label("打开内嵌终端", systemImage: "terminal")
                        .font(.system(size: SettingsFont.action, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Color.secondary.opacity(0.08), in: Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private var profilesSection: some View {
        SettingsSectionCard(
            "Profiles",
            subtitle: "管理当前 App 可用的 Gateway/Profile 与轻量运行态。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                if profileStore.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("当前还没有可用 profile")
                            .font(.system(size: SettingsFont.body))
                            .foregroundStyle(.secondary)

                        profileToolbarActions
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            profileToolbarActions
                        }

                        VStack(alignment: .leading, spacing: 10) {
                            profileToolbarActions
                        }
                    }

                    Text("当前：\(profileStore.selectedProfile?.displayName ?? "未选择")。左右滑动查看更多 Profile；点击卡片里的“切换到此 Profile”切换上下文。")
                        .font(.system(size: SettingsFont.detail))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isRefreshingProfiles {
                        HStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在同步 Profiles 运行态…")
                                .font(.system(size: SettingsFont.detail))
                                .foregroundStyle(.secondary)
                        }
                    }

                    profileGrid
                }
            }
        }
    }

    @ViewBuilder
    private var profileGrid: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(profileStore.profiles) { profile in
                    profileCard(for: profile)
                        .frame(width: SettingsLayout.profileCardWidth)
                }
            }
            .padding(.vertical, 2)
        }
        .scrollIndicators(.visible)
        .frame(height: SettingsLayout.profileCarouselHeight)
    }

    @ViewBuilder
    private var profileToolbarActions: some View {
        Button("新建 Gateway/Profile") {
            showCreateProfileSheet = true
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isAnyProfileOperationInFlight)

        if !profileStore.hasImportedLegacyProfile &&
            FileManager.default.fileExists(atPath: EZRWorkerPaths.legacyOpenClawConfigURL.path) {
            Button("导入 ~/.openclaw") {
                importLegacyProfile()
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isAnyProfileOperationInFlight)
        }

        Button {
            Task {
                await scanExistingOpenClaw()
            }
        } label: {
            if isScanningExistingOpenClaw {
                Text("扫描中...")
            } else {
                Text("扫描已有 OpenClaw")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isAnyProfileOperationInFlight)

        Button("导入配置文件") {
            importOpenClawConfigFile()
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isAnyProfileOperationInFlight)

        Button("刷新运行态") {
            Task {
                await refreshProfilesRuntime(reloadProfiles: true)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isAnyProfileOperationInFlight)
    }

    @ViewBuilder
    private func profileCard(for profile: GatewayProfile) -> some View {
        let resolution = GatewayProfileResolver.resolve(profile)
        let runtime = runtime(for: profile)
        let isSelected = profileStore.selectedProfile?.id == profile.id
        let isBusy = isAnyProfileOperationInFlight

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(profile.displayName)
                            .font(.system(size: SettingsFont.cardTitle, weight: .semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isSelected {
                            profileBadge("当前", tint: .accentColor)
                        }

                        profileBadge(profileSourceLabel(for: profile), tint: profileSourceColor(for: profile))
                        if profile.managementMode == .observeOnly {
                            profileBadge("仅观察", tint: .purple)
                        }
                        profileBadge(
                            profileRuntimeLabel(for: profile, runtime: runtime, resolution: resolution),
                            tint: profileRuntimeColor(for: profile, runtime: runtime, resolution: resolution)
                        )
                    }

                    Text(profile.slug)
                        .font(.system(size: SettingsFont.meta, design: .monospaced))
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
            .font(.system(size: SettingsFont.body))
            .controlSize(.large)
            .disabled(isBusy || profile.managementMode == .observeOnly)

            LazyVGrid(columns: profileMetricColumns, alignment: .leading, spacing: 6) {
                profileMetric("端口", "\(runtime?.resolvedPort ?? resolution.resolvedPort)")
                profileMetric("配置", profileConfigurationLabel(for: profile, runtime: runtime, resolution: resolution))
                profileMetric("PID", runtime?.pid.map(String.init) ?? "—")
                profileMetric("探测", probeTimeLabel(for: runtime?.lastProbeAt))
            }

            profileRuntimeStatusRow(for: profile, runtime: runtime, resolution: resolution)

            VStack(alignment: .leading, spacing: 6) {
                profileCompactPathRow(title: "Config", path: resolution.resolvedConfigPath)
                profileCompactPathRow(title: "Workspace", path: resolution.resolvedWorkspaceRoot)
            }

            profileActionButtons(
                profile: profile,
                runtime: runtime,
                isSelected: isSelected,
                isBusy: isBusy
            )
        }
        .padding(14)
        .frame(
            maxWidth: .infinity,
            minHeight: SettingsLayout.profileCardHeight,
            maxHeight: SettingsLayout.profileCardHeight,
            alignment: .topLeading
        )
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.42) : Color.primary.opacity(0.08),
                    lineWidth: isSelected ? 1.4 : 1
                )
        )
        .shadow(color: Color.black.opacity(isSelected ? 0.06 : 0.03), radius: 12, y: 4)
    }

    @ViewBuilder
    private func profileMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: SettingsFont.badge, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: SettingsFont.detail, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.54))
        )
    }

    @ViewBuilder
    private func profileRuntimeStatusRow(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> some View {
        let message = profileRuntimeStatusMessage(for: profile, runtime: runtime, resolution: resolution)
        let color = profileRuntimeStatusColor(for: profile, runtime: runtime, resolution: resolution)
        let icon = profileRuntimeStatusIcon(for: profile, runtime: runtime, resolution: resolution)

        Label(message, systemImage: icon)
            .font(.system(size: SettingsFont.detail, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(color.opacity(0.10))
            )
            .help(message)
    }

    @ViewBuilder
    private func profileCompactPathRow(title: String, path: String) -> some View {
        SettingsCompactPathRow(title: title, path: path)
    }

    @ViewBuilder
    private func profileActionButtons(
        profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        isSelected: Bool,
        isBusy: Bool
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                profileActionButtonGroup(profile: profile, runtime: runtime, isSelected: isSelected, isBusy: isBusy)
            }

            VStack(alignment: .leading, spacing: 10) {
                profileActionButtonGroup(profile: profile, runtime: runtime, isSelected: isSelected, isBusy: isBusy)
            }
        }
    }

    @ViewBuilder
    private func profileActionButtonGroup(
        profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        isSelected: Bool,
        isBusy: Bool
    ) -> some View {
        let lifecycleDisabled = isBusy
            || profileRuntimeIsTransitional(runtime)
            || profile.managementMode == .observeOnly

        if !isSelected {
            Button("切换到此 Profile") {
                profileStore.selectProfile(id: profile.id)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isBusy)
        }

        if shouldShowPrepareAction(for: profile, runtime: runtime) {
            Button(prepareActionTitle(for: profile, runtime: runtime)) {
                Task {
                    await runProfileAction(.prepare, profile: profile)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(lifecycleDisabled)
        }

        if runtime?.isRunning == true {
            Button("停止") {
                Task {
                    await runProfileAction(.stop, profile: profile)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(lifecycleDisabled)

            Button("重启") {
                Task {
                    await runProfileAction(.restart, profile: profile)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(lifecycleDisabled)
        } else {
            Button("启动") {
                Task {
                    await runProfileAction(.start, profile: profile)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(lifecycleDisabled)
        }

        Button(role: .destructive) {
            pendingDeletionProfile = profile
        } label: {
            Text("删除")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isBusy)
    }

    @ViewBuilder
    private var environmentSection: some View {
        SettingsSectionCard(
            L10n.k("settings.environment", fallback: "环境"),
            subtitle: "检查 App 内置 Node.js 与 OpenClaw 运行文件。",
            minHeight: SettingsLayout.systemCardMinHeight
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsPathBlock(title: "Node.js", path: GatewayProcessManager.bundledNodeURL.path)
                SettingsPathBlock(title: bundledOpenClawPathTitle, path: GatewayProcessManager.bundledOpenClawEntry.path)

                switch envChecker.status {
                case .ready:
                    SettingsInfoRow(
                        L10n.k("settings.env_status", fallback: "环境状态"),
                        value: L10n.k("settings.env_ready", fallback: "就绪")
                    )
                case .missing(let msg):
                    SettingsInfoRow(
                        L10n.k("settings.env_status", fallback: "环境状态"),
                        value: msg,
                        allowsWrapping: true
                    )
                case .checking:
                    SettingsInfoRow(L10n.k("settings.env_status", fallback: "环境状态"), value: "检查中")
                case .unchecked:
                    SettingsInfoRow(L10n.k("settings.env_status", fallback: "环境状态"), value: "未检查")
                }

                Button(L10n.k("settings.recheck", fallback: "重新检查")) {
                    Task { await envChecker.check() }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
        }
    }

    @ViewBuilder
    private var gatewayDiagnosticsSection: some View {
        let info = LegacyGatewayLaunchAgentInfo.load()
        let diagnostic = legacyLaunchAgentDiagnostic(
            info: info,
            profile: profileStore.selectedProfile,
            resolution: profileStore.selectedResolution
        )

        SettingsSectionCard(
            "Gateway 诊断",
            subtitle: "区分当前 Profile Gateway 与旧 OpenClaw launch agent。"
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsInfoRow(
                    "当前 Profile",
                    value: profileStore.selectedProfile.map { "\($0.displayName) (\($0.slug))" } ?? "未选择"
                )
                SettingsInfoRow(
                    "当前端口",
                    value: profileStore.selectedResolution.map { String($0.resolvedPort) } ?? "—"
                )
                SettingsInfoRow(
                    "旧 LaunchAgent",
                    value: info.exists ? "已发现" : "未发现"
                )
                if info.exists {
                    SettingsInfoRow(
                        "旧端口",
                        value: info.port.map(String.init) ?? "未识别"
                    )
                    SettingsCompactPathRow(title: "Plist", path: info.path)
                }

                Label(diagnostic.message, systemImage: diagnostic.icon)
                    .font(.system(size: SettingsFont.detail, weight: .medium))
                    .foregroundStyle(diagnostic.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        SettingsSectionCard(
            L10n.k("settings.about", fallback: "关于"),
            minHeight: SettingsLayout.systemCardMinHeight
        ) {
            VStack(alignment: .leading, spacing: 14) {
                SettingsInfoRow(
                    L10n.k("settings.version", fallback: "版本"),
                    value: updater.currentAppVersion
                )
                SettingsInfoRow(
                    L10n.k("settings.build", fallback: "构建号"),
                    value: updater.currentAppBuild
                )
                if EZRWorkerBuildFlavor.isDev {
                    SettingsInfoRow(
                        "运行身份",
                        value: "Debug / Dev"
                    )
                }

                Divider()
                    .padding(.vertical, 2)

                SettingsInfoRow(
                    "更新源",
                    value: updater.appUpdateManifestIsConfigured ? "已配置" : "未配置"
                )
                SettingsInfoRow(
                    "最新版本",
                    value: latestAppVersionLabel
                )
                SettingsInfoRow(
                    "最近检查",
                    value: lastAppUpdateCheckLabel
                )

                if let error = updater.appCheckError ?? updater.appUpdateError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: SettingsFont.detail, weight: .medium))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label(appUpdateStatusLabel, systemImage: appUpdateStatusIcon)
                        .font(.system(size: SettingsFont.detail, weight: .medium))
                        .foregroundStyle(appUpdateStatusColor)
                }

                appUpdateControls
            }
        }
    }

    @ViewBuilder
    private var appUpdateControls: some View {
        if updater.isAwaitingAppRelaunch {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("安装器已打开，完成安装后会自动重启。")
                    .font(.system(size: SettingsFont.detail))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let progress = updater.appUpdateProgress {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(updater.appMustUpdate ? .red : .orange)
                HStack(spacing: 10) {
                    Text(downloadProgressLabel(progress))
                        .font(.system(size: SettingsFont.detail))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button("取消") {
                        updater.cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                }
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    appUpdateButtonGroup
                }
                VStack(alignment: .leading, spacing: 10) {
                    appUpdateButtonGroup
                }
            }
        }
    }

    @ViewBuilder
    private var appUpdateButtonGroup: some View {
        Button {
            Task { await updater.checkApp() }
        } label: {
            if updater.isCheckingAppUpdate {
                Text("检查中...")
            } else {
                Text("检查更新")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(updater.isCheckingAppUpdate || !updater.appUpdateManifestIsConfigured)

        if updater.appNeedsUpdate || updater.appMustUpdate {
            Button {
                showAppUpdateSheet = true
            } label: {
                Label("立即更新", systemImage: "arrow.down.circle.fill")
                    .font(.system(size: SettingsFont.action, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(updater.appMustUpdate ? .red : .orange)
            .disabled(updater.appSelectedPackageURL == nil && updater.appDownloadURL == nil)
        }
    }

    private var overviewColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]
    }

    private var profileMetricColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ]
    }

    private var environmentStatusValue: String {
        switch envChecker.status {
        case .unchecked:
            return "未检查"
        case .checking:
            return "检查中"
        case .ready:
            return L10n.k("settings.env_ready", fallback: "就绪")
        case .missing:
            return "异常"
        }
    }

    private var environmentStatusSubtitle: String {
        switch envChecker.status {
        case .unchecked:
            return "等待环境检查"
        case .checking:
            return "正在检查运行文件"
        case .ready:
            return "内置运行环境可用"
        case .missing(let msg):
            return msg
        }
    }

    private var environmentStatusColor: Color {
        switch envChecker.status {
        case .ready:
            return .green
        case .checking:
            return .orange
        case .missing:
            return .red
        case .unchecked:
            return .secondary
        }
    }

    private var latestAppVersionLabel: String {
        guard let version = updater.appLatestVersion else { return "—" }
        if let build = updater.appLatestBuild, !build.isEmpty {
            return "v\(version) (\(build))"
        }
        return "v\(version)"
    }

    private var bundledOpenClawPathTitle: String {
        guard let version = OpenClawRuntime.bundledOpenClawVersion else { return "OpenClaw" }
        return "OpenClaw · v\(version)"
    }

    private func legacyLaunchAgentDiagnostic(
        info: LegacyGatewayLaunchAgentInfo,
        profile: GatewayProfile?,
        resolution: GatewayProfileResolution?
    ) -> LegacyGatewayLaunchAgentDiagnostic {
        guard info.exists else {
            return LegacyGatewayLaunchAgentDiagnostic(
                message: "未检测到旧 OpenClaw launch agent，当前 Profile 生命周期由 EZRWorker 管理。",
                icon: "checkmark.circle.fill",
                color: .green
            )
        }

        guard let profile, let resolution else {
            return LegacyGatewayLaunchAgentDiagnostic(
                message: "检测到旧 OpenClaw launch agent，但当前尚未选择 Profile。",
                icon: "info.circle.fill",
                color: .orange
            )
        }

        if profile.sourceKind == .legacyReuse {
            return LegacyGatewayLaunchAgentDiagnostic(
                message: "当前 Profile 正在复用旧 ~/.openclaw；如旧 launch agent 仍 KeepAlive，它会继续管理该旧实例。",
                icon: "arrow.triangle.2.circlepath",
                color: .orange
            )
        }

        if info.port == resolution.resolvedPort {
            return LegacyGatewayLaunchAgentDiagnostic(
                message: "旧 launch agent 与当前 Profile 使用同一端口 \(resolution.resolvedPort)，可能造成端口抢占或重启误判。",
                icon: "exclamationmark.triangle.fill",
                color: .red
            )
        }

        if let legacyPort = info.port {
            return LegacyGatewayLaunchAgentDiagnostic(
                message: "检测到旧 OpenClaw launch agent 正在配置端口 \(legacyPort)，它不属于当前 Profile 端口 \(resolution.resolvedPort)。",
                icon: "info.circle.fill",
                color: .orange
            )
        }

        return LegacyGatewayLaunchAgentDiagnostic(
            message: "检测到旧 OpenClaw launch agent，但无法识别端口；如 Web UI 指向旧实例，可能与当前 Profile 不一致。",
            icon: "info.circle.fill",
            color: .orange
        )
    }

    private var lastAppUpdateCheckLabel: String {
        guard let timestamp = updater.appLastSuccessfulCheckAt else { return "—" }
        let date = Date(timeIntervalSinceReferenceDate: timestamp)
        return Self.appUpdateDateFormatter.string(from: date)
    }

    private var appUpdateStatusLabel: String {
        if updater.isCheckingAppUpdate {
            return "正在检查更新"
        }
        if updater.appMustUpdate {
            return "需要更新后继续使用"
        }
        if updater.appNeedsUpdate {
            return "有可用更新"
        }
        if updater.appLatestVersion != nil {
            return "当前已是最新版本"
        }
        if updater.appUpdateManifestIsConfigured {
            return "尚未检查"
        }
        return "App 更新源未配置"
    }

    private var appUpdateStatusIcon: String {
        if updater.isCheckingAppUpdate {
            return "arrow.triangle.2.circlepath"
        }
        if updater.appMustUpdate {
            return "exclamationmark.triangle.fill"
        }
        if updater.appNeedsUpdate {
            return "arrow.down.circle.fill"
        }
        if updater.appLatestVersion != nil {
            return "checkmark.circle.fill"
        }
        return "info.circle"
    }

    private var appUpdateStatusColor: Color {
        if updater.appMustUpdate { return .red }
        if updater.appNeedsUpdate || updater.isCheckingAppUpdate { return .orange }
        if updater.appLatestVersion != nil { return .green }
        return .secondary
    }

    private func downloadProgressLabel(_ progress: Double) -> String {
        let percentage = "\(Int(progress * 100))%"
        guard updater.appTotalBytes > 0 else { return "正在下载 \(percentage)" }
        let size = "\(UpdateChecker.formatBytes(updater.appDownloadedBytes)) / \(UpdateChecker.formatBytes(updater.appTotalBytes))"
        if updater.appDownloadSpeed > 0 {
            return "正在下载 \(percentage) · \(size) · \(UpdateChecker.formatSpeed(updater.appDownloadSpeed))"
        }
        return "正在下载 \(percentage) · \(size)"
    }

    private static let appUpdateDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var isAnyProfileOperationInFlight: Bool {
        isDeletingProfile || isRefreshingProfiles || isScanningExistingOpenClaw || profileActionProfileID != nil
    }

    private func runtime(for profile: GatewayProfile) -> SupervisorProfileRuntime? {
        supervisorClient.runtimes.first(where: { $0.profileID == profile.id })
    }

    @ViewBuilder
    private func responsiveTwoColumnRow<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                leading()
                    .frame(
                        minWidth: SettingsLayout.twoColumnCardMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
                trailing()
                    .frame(
                        minWidth: SettingsLayout.twoColumnCardMinimumWidth,
                        maxWidth: .infinity,
                        alignment: .topLeading
                    )
            }

            VStack(alignment: .leading, spacing: 20) {
                leading()
                trailing()
            }
        }
    }

    private func profileSourceLabel(for profile: GatewayProfile) -> String {
        switch profile.sourceKind {
        case .managed:
            return "托管"
        case .legacyReuse:
            return "复用旧实例"
        case .externalReuse:
            return "外部复用"
        }
    }

    private func profileSourceColor(for profile: GatewayProfile) -> Color {
        switch profile.sourceKind {
        case .managed:
            return .blue
        case .legacyReuse:
            return .orange
        case .externalReuse:
            return .purple
        }
    }

    private func profileConfigurationLabel(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> String {
        if profile.sourceKind == .legacyReuse || profile.sourceKind == .externalReuse {
            return legacyConfigExists(for: resolution) ? "可复用" : "缺配置"
        }

        return runtime?.isPrepared == true ? "已准备" : "未准备"
    }

    private func profileRuntimeLabel(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> String {
        let externalConfigIsReusable = profile.sourceKind != .managed && legacyConfigExists(for: resolution)
        guard let runtime else { return "未同步" }

        switch runtime.readyState {
        case .unknown:
            return runtime.isRunning ? "运行中" : "未知"
        case .stopped:
            if externalConfigIsReusable { return profile.managementMode == .observeOnly ? "仅观察" : "可复用" }
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

    private func profileRuntimeColor(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> Color {
        let externalConfigIsReusable = profile.sourceKind != .managed && legacyConfigExists(for: resolution)
        guard let runtime else { return .secondary }

        switch runtime.readyState {
        case .ready:
            return runtime.isRunning ? .green : .blue
        case .preparing, .starting:
            return .orange
        case .failed:
            return .red
        case .stopped:
            return externalConfigIsReusable && !runtime.isPrepared ? .blue : .secondary
        case .unknown:
            return .secondary
        }
    }

    private func profileRuntimeStatusMessage(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> String {
        guard let runtime else {
            return "运行态未同步，点击刷新运行态获取最新状态。"
        }

        if let lastError = runtime.lastError,
           !lastError.isEmpty {
            return "运行异常：\(lastError)"
        }

        return "运行态：\(profileRuntimeLabel(for: profile, runtime: runtime, resolution: resolution))"
    }

    private func profileRuntimeStatusColor(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> Color {
        guard let runtime else { return .secondary }

        if let lastError = runtime.lastError,
           !lastError.isEmpty {
            return .red
        }

        return profileRuntimeColor(for: profile, runtime: runtime, resolution: resolution)
    }

    private func profileRuntimeStatusIcon(
        for profile: GatewayProfile,
        runtime: SupervisorProfileRuntime?,
        resolution: GatewayProfileResolution
    ) -> String {
        guard let runtime else { return "clock" }

        if let lastError = runtime.lastError,
           !lastError.isEmpty {
            return "exclamationmark.triangle.fill"
        }

        if profile.sourceKind != .managed,
           legacyConfigExists(for: resolution),
           runtime.readyState == .stopped,
           !runtime.isPrepared {
            return "checkmark.circle"
        }

        switch runtime.readyState {
        case .ready:
            return runtime.isRunning ? "checkmark.circle.fill" : "checkmark.circle"
        case .preparing, .starting:
            return "arrow.triangle.2.circlepath"
        case .failed:
            return "exclamationmark.triangle.fill"
        case .stopped:
            return "pause.circle"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private func legacyConfigExists(for resolution: GatewayProfileResolution) -> Bool {
        FileManager.default.fileExists(atPath: resolution.resolvedConfigPath)
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

    private func shouldShowPrepareAction(for _: GatewayProfile, runtime: SupervisorProfileRuntime?) -> Bool {
        runtime?.isRunning != true
    }

    private func prepareActionTitle(for profile: GatewayProfile, runtime: SupervisorProfileRuntime?) -> String {
        if profile.sourceKind == .legacyReuse {
            return runtime?.isPrepared == true ? "重新检查配置" : "检查配置"
        }
        if profile.sourceKind == .externalReuse {
            return runtime?.isPrepared == true ? "重新检查配置" : "检查配置"
        }

        return runtime?.isPrepared == true ? "重新准备配置" : "准备配置"
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

    @MainActor
    private func scanExistingOpenClaw() async {
        guard !isScanningExistingOpenClaw else { return }
        isScanningExistingOpenClaw = true
        defer { isScanningExistingOpenClaw = false }

        let candidates = OpenClawInstanceDiscoveryService.scanLightweightCandidates()
        guard !candidates.isEmpty else {
            profileErrorMessage = "未发现可导入的既有 OpenClaw 实例"
            return
        }

        existingOpenClawImportCandidates = candidates
        showExistingOpenClawImportSheet = true
    }

    private func importOpenClawConfigFile() {
        let panel = NSOpenPanel()
        panel.title = "选择 openclaw.json 或包含它的目录"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let candidate = try OpenClawInstanceDiscoveryService.candidateFromManualSelection(url)
            existingOpenClawImportCandidates = [candidate]
            showExistingOpenClawImportSheet = true
        } catch {
            profileErrorMessage = error.localizedDescription
        }
    }

    private func deleteMessage(for profile: GatewayProfile) -> String {
        let cleanupMessage: String
        if profile.sourceKind == .managed {
            cleanupMessage = "这会删除当前 profile 记录，并清理 App Support 下该 profile 的托管数据目录。"
        } else {
            cleanupMessage = "这会删除当前 profile 记录，但不会删除原始 OpenClaw 数据。"
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
            if profile.managementMode == .managedByEZRWorker {
                try await supervisorClient.stopProfile(profileID: profile.id)
            }
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

private struct LegacyGatewayLaunchAgentInfo {
    let exists: Bool
    let path: String
    let port: Int?

    static func load() -> LegacyGatewayLaunchAgentInfo {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("ai.openclaw.gateway.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return LegacyGatewayLaunchAgentInfo(exists: false, path: plistURL.path, port: nil)
        }

        return LegacyGatewayLaunchAgentInfo(
            exists: true,
            path: plistURL.path,
            port: port(from: plist)
        )
    }

    private static func port(from plist: [String: Any]) -> Int? {
        if let environment = plist["EnvironmentVariables"] as? [String: Any],
           let rawPort = environment["OPENCLAW_GATEWAY_PORT"] {
            if let string = rawPort as? String, let port = Int(string) {
                return port
            }
            if let number = rawPort as? NSNumber {
                return number.intValue
            }
        }

        guard let arguments = plist["ProgramArguments"] as? [String],
              let portFlagIndex = arguments.firstIndex(of: "--port"),
              arguments.indices.contains(arguments.index(after: portFlagIndex))
        else {
            return nil
        }

        return Int(arguments[arguments.index(after: portFlagIndex)])
    }
}

private struct LegacyGatewayLaunchAgentDiagnostic {
    let message: String
    let icon: String
    let color: Color
}

private enum SettingsFont {
    static let cardTitle: CGFloat = 20
    static let cardSubtitle: CGFloat = 15
    static let body: CGFloat = 16
    static let detail: CGFloat = 15
    static let meta: CGFloat = 14
    static let badge: CGFloat = 13
    static let path: CGFloat = 13
    static let action: CGFloat = 16
}

private enum SettingsLayout {
    static let systemCardMinHeight: CGFloat = 360
    static let twoColumnCardMinimumWidth: CGFloat = 360
    static let profileCardWidth: CGFloat = 420
    static let profileCardHeight: CGFloat = 392
    static let profileCarouselHeight: CGFloat = 408
    static let pathBlockHeight: CGFloat = 60
    static let pathTextBoxMinHeight: CGFloat = 34
    static let pathLineLimit = 1
}

private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let minHeight: CGFloat?
    let content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        minHeight: CGFloat? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.minHeight = minHeight
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: SettingsFont.cardTitle, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: SettingsFont.cardSubtitle))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            content
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 14, y: 6)
        )
    }
}

private struct SettingsOverviewCard: View {
    let icon: String
    let title: String
    let value: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: SettingsFont.meta, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }

            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(tint)
                .lineLimit(1)
                .truncationMode(.middle)

            Text(subtitle)
                .font(.system(size: SettingsFont.meta))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(tint.opacity(0.16), lineWidth: 1)
                )
        )
    }
}

private struct SettingsInfoRow: View {
    let title: String
    let value: String
    let isMonospaced: Bool
    let allowsWrapping: Bool

    init(
        _ title: String,
        value: String,
        isMonospaced: Bool = false,
        allowsWrapping: Bool = false
    ) {
        self.title = title
        self.value = value
        self.isMonospaced = isMonospaced
        self.allowsWrapping = allowsWrapping
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(title)
                .font(.system(size: SettingsFont.detail))
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)

            valueText

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var valueText: some View {
        if allowsWrapping {
            Text(value)
                .font(valueFont)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(value)
                .font(valueFont)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private var valueFont: Font {
        isMonospaced
            ? .system(size: SettingsFont.path, design: .monospaced)
            : .system(size: SettingsFont.body, weight: .medium)
    }
}

private struct SettingsPathBlock: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: SettingsFont.meta, weight: .semibold))
                .foregroundStyle(.secondary)

            SettingsPathDisclosure(
                path: path,
                fill: Color(nsColor: .windowBackgroundColor).opacity(0.72),
                height: SettingsLayout.pathTextBoxMinHeight
            )
        }
        .frame(maxWidth: .infinity, minHeight: SettingsLayout.pathBlockHeight, alignment: .topLeading)
    }
}

private struct SettingsCompactPathRow: View {
    let title: String
    let path: String
    @State private var isShowingFullPath = false

    var body: some View {
        Button {
            isShowingFullPath.toggle()
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Text(title)
                    .font(.system(size: SettingsFont.meta, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 76, alignment: .leading)

                Text(displayPath)
                    .font(.system(size: SettingsFont.path, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(SettingsLayout.pathLineLimit)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.54))
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .popover(isPresented: $isShowingFullPath, arrowEdge: .bottom) {
            SettingsFullPathPopover(title: title, path: path)
        }
        .help("点击查看完整路径：\(path)")
    }

    private var displayPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }
}

private struct SettingsPathDisclosure: View {
    let path: String
    let fill: Color
    let height: CGFloat
    @State private var isShowingFullPath = false

    var body: some View {
        Button {
            isShowingFullPath.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(displayPath)
                    .font(.system(size: SettingsFont.path, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(SettingsLayout.pathLineLimit)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .clipped()

                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(fill)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .popover(isPresented: $isShowingFullPath, arrowEdge: .bottom) {
            SettingsFullPathPopover(title: "完整路径", path: path)
        }
        .help("点击查看完整路径：\(path)")
    }

    private var displayPath: String {
        NSString(string: path).abbreviatingWithTildeInPath
    }
}

private struct SettingsFullPathPopover: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: SettingsFont.body, weight: .semibold))

            Text(path)
                .font(.system(size: SettingsFont.path, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.70))
                )

            Button("复制路径") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
        .padding(16)
        .frame(width: 560, alignment: .leading)
    }
}

private struct SettingsStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.system(size: SettingsFont.badge, weight: .semibold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
}

private extension AppSettingsView {
    func profileBadge(_ title: String, tint: Color) -> some View {
        SettingsStatusPill(title: title, tint: tint)
    }

    func profileInfoRow(_ title: String, _ value: String) -> some View {
        SettingsInfoRow(title, value: value)
    }

    func profilePathBlock(title: String, path: String) -> some View {
        SettingsPathBlock(title: title, path: path)
    }
}
