import AppKit
import SwiftUI

struct AppRootGateView: View {
    @Environment(AuthSessionStore.self) private var authStore
    @Environment(AppBootstrapCoordinator.self) private var bootstrapCoordinator

    var body: some View {
        Group {
            switch resolveAppRootRoute(for: authStore.phase) {
            case .launching:
                LaunchSplashView()
            case .login:
                LoginView()
            case .app:
                AuthenticatedAppShell()
            }
        }
        .task {
            await authStore.restoreInitialState()
        }
        .onChange(of: authStore.phase) { oldValue, newValue in
            if resolveAppRootRoute(for: oldValue) == .app,
               resolveAppRootRoute(for: newValue) != .app {
                Task {
                    await bootstrapCoordinator.resetForUnauthenticated()
                }
            }
        }
    }
}

struct AuthenticatedAppShell: View {
    @Environment(AppBootstrapCoordinator.self) private var bootstrapCoordinator
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(UpdateChecker.self) private var updater

    var body: some View {
        ZStack {
            if case .needsLegacyMigration(let legacyPort) = profileStore.status {
                ProfileMigrationChoiceView(legacyPort: legacyPort)
            } else {
                MainView()

                switch bootstrapCoordinator.state {
                case .idle, .starting:
                    LoadingOverlayView(
                        title: L10n.k("auth.bootstrap.loading_title", fallback: "正在进入 EZRWorker"),
                        subtitle: L10n.k("auth.bootstrap.loading_subtitle", fallback: "正在连接当前 Gateway/Profile 并准备工作区，请稍候。")
                    )
                case .failed(let message):
                    LoadingOverlayView(
                        title: L10n.k("auth.bootstrap.failed_title", fallback: "应用初始化失败"),
                        subtitle: message
                    )
                case .started:
                    EmptyView()
                }
            }

            if updater.appMustUpdate {
                ForceAppUpdateOverlay()
                    .environment(updater)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .task {
            await profileStore.loadIfNeeded()
            if profileStore.canBootstrap {
                await bootstrapCoordinator.startIfNeeded()
            }
        }
        .onChange(of: profileStore.selectedProfileID) { oldValue, newValue in
            guard oldValue != nil, newValue != nil, oldValue != newValue else { return }
            Task {
                await bootstrapCoordinator.restartForProfileSwitch()
            }
        }
        .onChange(of: profileStore.status) { _, newValue in
            guard newValue == .ready else { return }
            Task {
                await bootstrapCoordinator.startIfNeeded()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            recoverGateway(trigger: .appActivated)
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
            recoverGateway(trigger: .systemWake)
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: NSNotification.Name("com.apple.screenIsUnlocked")
            )
        ) { _ in
            recoverGateway(trigger: .screenUnlocked)
        }
    }

    private func recoverGateway(trigger: AppBootstrapCoordinator.RecoveryTrigger) {
        guard profileStore.canBootstrap else { return }
        Task {
            await bootstrapCoordinator.recoverGatewayAfterInterruption(trigger: trigger)
        }
    }
}

struct AuthenticatedSceneGate<Content: View>: View {
    @Environment(AuthSessionStore.self) private var authStore
    private let content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        switch resolveProtectedSceneRoute(for: authStore.phase) {
        case .content:
            content()
        case .loading:
            LoadingOverlayView(
                title: L10n.k("auth.scene.loading_title", fallback: "正在验证登录状态"),
                subtitle: L10n.k("auth.scene.loading_subtitle", fallback: "请稍候，窗口内容准备中。")
            )
        case .blocked:
            ProtectedWindowPlaceholder()
        }
    }
}

private struct ForceAppUpdateOverlay: View {
    @Environment(UpdateChecker.self) private var updater

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .opacity(0.94)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.k("app_update.force.title", fallback: "需要更新后继续使用"))
                            .font(.title2.weight(.semibold))
                        Text(versionSummary)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }

                if let notes = updater.appReleaseNotes {
                    ScrollView {
                        Text(notes)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 190)
                }

                if let progress = updater.appUpdateProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: progress)
                            .progressViewStyle(.linear)
                            .tint(.red)
                        Text(downloadProgressLabel(progress))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = updater.appUpdateError, !error.isEmpty {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(role: .destructive) {
                        NSApp.terminate(nil)
                    } label: {
                        Text(L10n.k("app_update.force.quit", fallback: "退出 EZRWorker"))
                    }
                    .keyboardShortcut(.cancelAction)

                    Spacer()

                    Button {
                        Task { await updater.downloadAndInstall() }
                    } label: {
                        if updater.appUpdateProgress != nil || updater.isAwaitingAppRelaunch {
                            Text(L10n.k("app_update.force.updating", fallback: "正在更新..."))
                        } else {
                            Text(L10n.k("app_update.force.update_now", fallback: "立即更新"))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(
                        updater.appUpdateProgress != nil
                            || updater.isAwaitingAppRelaunch
                            || (updater.appSelectedPackageURL == nil && updater.appDownloadURL == nil)
                    )
                }
            }
            .padding(28)
            .frame(width: 480, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Color.black.opacity(0.16), radius: 24, y: 10)
        }
    }

    private var versionSummary: String {
        let current = updater.currentAppVersion
        let minimum = updater.appMinVersion ?? "—"
        let latest = updater.appLatestVersion ?? "—"
        return "当前 v\(current) · 最低要求 v\(minimum) · 最新 v\(latest)"
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
}

private struct ProtectedWindowPlaceholder: View {
    var body: some View {
        ContentUnavailableView(
            L10n.k("auth.scene.protected_title", fallback: "该窗口需要先登录"),
            systemImage: "lock.shield",
            description: Text(L10n.k("auth.scene.protected_subtitle", fallback: "请先在主窗口完成登录，然后再打开此窗口。"))
        )
        .frame(minWidth: 420, minHeight: 260)
    }
}

private struct LaunchSplashView: View {
    var body: some View {
        LoadingOverlayView(
            title: L10n.k("auth.launch.title", fallback: "正在启动 EZRWorker"),
            subtitle: L10n.k("auth.launch.subtitle", fallback: "正在检查认证配置，请稍候。")
        )
    }
}

private struct LoadingOverlayView: View {
    let title: String
    let subtitle: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.08),
                    Color(nsColor: .underPageBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}
