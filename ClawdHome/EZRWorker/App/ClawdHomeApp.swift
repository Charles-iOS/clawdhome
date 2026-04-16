// ClawdHome/ClawdHomeApp.swift

import AppKit
import Observation
import SwiftUI

private let bootstrapMiniMaxAPIKey = "sk-cp-fpa22Na3FtFB33pyJq99D5vpTrGDxsX6PwA2HXp2Ro1p3HycWv-oXl5kb0tIq6xVWq5xQgI3QmIySPU4gWTtNSb7-wrXg6tjgNhP-gMM182Dz0K4kiXeko4"

final class ClawdHomeAppDelegate: NSObject, NSApplicationDelegate {
    var onWillTerminate: (() -> Void)?

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
    }
}

@main
struct ClawdHomeApp: App {
    @NSApplicationDelegateAdaptor(ClawdHomeAppDelegate.self) private var appDelegate

    // 新单实例架构服务
    @State private var processManager = GatewayProcessManager()
    @State private var envChecker = EnvironmentChecker()
    @State private var gatewayService = GatewayService()
    @State private var agentStore = AgentStore()
    @State private var workspaceManager = AgentWorkspaceManager()
    @State private var keychainStore = ProviderKeychainStore()

    // 旧服务（Phase 5 清理时移除）
    @State private var helperClient: HelperClient
    @State private var shrimpPool: ShrimpPool
    @State private var updater = UpdateChecker()
    @State private var modelStore = GlobalModelStore()
    @State private var gatewayHub = GatewayHub()
    @State private var lockStore = AppLockStore()
    @State private var maintenanceWindowRegistry = MaintenanceWindowRegistry()
    @State private var gatewayReconnectTask: Task<Void, Never>?
    @State private var didPrepareForTermination = false

    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue

    init() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        let client = HelperClient()
        _helperClient = State(initialValue: client)
        _shrimpPool   = State(initialValue: ShrimpPool(helperClient: client))
    }

    var body: some Scene {
        let appLanguage = AppLanguage(rawValue: appLanguageRaw) ?? .system
        WindowGroup {
            MainView()
                .environment(processManager)
                .environment(envChecker)
                .environment(gatewayService)
                .environment(agentStore)
                .environment(workspaceManager)
                .environment(keychainStore)
                .environment(\.locale, appLanguage.locale)
                // 旧服务注入（Phase 5 移除）
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .task {
                    appDelegate.onWillTerminate = handleAppTermination
                    await bootstrap()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1280, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        // 旧窗口组（Phase 5 移除）
        WindowGroup(id: "claw-detail", for: String.self) { $username in
            if let name = username {
                ClawDetailWindow(username: name)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(updater)
                    .environment(modelStore)
                    .environment(keychainStore)
                    .environment(gatewayHub)
                    .environment(maintenanceWindowRegistry)
                    .environment(\.locale, appLanguage.locale)
                    .background(ClawDetailWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(
            width: UserDetailWindowLayout.mainWindowDefaultWidth,
            height: UserDetailWindowLayout.detailWindowDefaultHeight
        )

        WindowGroup(id: "user-init-wizard", for: String.self) { $username in
            if let name = username {
                UserInitWizardWindow(username: name)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(updater)
                    .environment(modelStore)
                    .environment(keychainStore)
                    .environment(gatewayHub)
                    .environment(maintenanceWindowRegistry)
                    .environment(\.locale, appLanguage.locale)
                    .background(UserInitWizardWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 720)

        WindowGroup(id: "channel-onboarding", for: String.self) { $payload in
            ChannelOnboardingWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 520)

        WindowGroup(id: "maintenance-terminal", for: String.self) { $payload in
            MaintenanceTerminalWindow(payload: payload)
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 860, height: 560)

        WindowGroup(id: "clone-claw", for: String.self) { $sourceUsername in
            if let username = sourceUsername {
                CloneClawSheet(sourceUsername: username)
                    .environment(helperClient)
                    .environment(shrimpPool)
                    .environment(\.locale, appLanguage.locale)
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 640, height: 560)
    }

    /// 应用启动流程：环境检查 → 启动 Gateway → 连接 WebSocket → 加载智能体
    private func bootstrap() async {
        // 配置 workspace manager（使用当前用户名）
        let currentUsername = NSUserName()
        workspaceManager.configure(helperClient: helperClient, username: currentUsername)

        await envChecker.check()

        if envChecker.isReady {
            processManager.start()

            // 等待 Gateway 就绪后再连接 WebSocket
            for _ in 0..<30 {
                if processManager.isRunning { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        // 无论是 App 自己拉起的还是外部已有的 gateway，都尝试连接
        let gatewayReady: Bool
        if processManager.isRunning {
            appLog("bootstrap: processManager already running")
            gatewayReady = true
        } else {
            appLog("bootstrap: processManager not running, probing port \(processManager.gatewayPort)...")
            let (alive, ready) = await GatewayClient.httpProbe(port: processManager.gatewayPort)
            appLog("bootstrap: probe result alive=\(alive) ready=\(ready)")
            gatewayReady = ready
        }

        if gatewayReady {
            await connectGatewayService()
            await provisionDefaultMiniMaxModelIfNeeded()
        } else {
            appLog("bootstrap: gateway not ready, skipping WebSocket connect", level: .warn)
        }
        startGatewayReconnectLoop()

        // 先建立 XPC 连接，agentStore/workspaceManager 依赖 helperClient 读写文件
        helperClient.connect()
        let helperReady = await helperClient.waitUntilConnected()
        if !helperReady {
            appLog("bootstrap: helper 连接未在预期时间内就绪，后续 workspace 探测将采用保守模式", level: .warn)
        }

        // 加载智能体（从 gateway 配置 + workspace 扫描）
        await agentStore.load(
            gateway: gatewayService,
            workspaceManager: workspaceManager,
            username: currentUsername
        )
        // 执行一次性迁移（旧 agents.json → 新架构）
        await agentStore.migrateIfNeeded()

        await MainActor.run { shrimpPool.start() }
        modelStore.load()
    }

    private func startGatewayReconnectLoop() {
        gatewayReconnectTask?.cancel()
        gatewayReconnectTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                if processManager.isRunning, !gatewayService.isConnected {
                    appLog("bootstrap: reconnect loop detected disconnected gateway, retrying...")
                    await connectGatewayService()
                }
            }
        }
    }

    private func handleAppTermination() {
        guard !didPrepareForTermination else { return }
        didPrepareForTermination = true

        gatewayReconnectTask?.cancel()
        gatewayReconnectTask = nil
        processManager.prepareForAppTermination()
        helperClient.disconnect()
        gatewayService.prepareForAppTermination()
    }

    private func readGatewayToken() -> String? {
        let url = GatewayProcessManager.openClawConfigDir.appendingPathComponent("openclaw.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gw = json["gateway"] as? [String: Any],
              let auth = gw["auth"] as? [String: Any],
              let token = auth["token"] as? String else { return nil }
        return token
    }

    /// 读取 token 并连接 WebSocket（带重试，应对 gateway 启动后刷新 token）
    private func connectGatewayService() async {
        for attempt in 1...3 {
            if let token = readGatewayToken() {
                appLog("bootstrap: token=\(token.prefix(8))... attempt=\(attempt)")
                gatewayService.updateToken(token)
            } else {
                appLog("bootstrap: no token in config", level: .error)
            }
            await gatewayService.connect()
            if gatewayService.isConnected {
                appLog("bootstrap: connected on attempt \(attempt)")
                return
            }
            appLog("bootstrap: attempt \(attempt) failed", level: .warn)
            if attempt < 3 { try? await Task.sleep(nanoseconds: 3_000_000_000) }
        }
        appLog("bootstrap: connect failed after retries", level: .error)
    }

    private func provisionDefaultMiniMaxModelIfNeeded() async {
        guard gatewayService.isConnected else { return }

        do {
            let (config, baseHash) = try await gatewayService.configGetFull()

            let models = config["models"] as? [String: Any]
            let providers = models?["providers"] as? [String: Any]
            let minimax = providers?["minimax"] as? [String: Any]
            let existingMiniMaxAPIKey = minimax?["apiKey"] as? String

            let currentPrimaryModel = ((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])
                .flatMap { $0["model"] as? [String: Any] }?["primary"] as? String

            let keychainMiniMaxAPIKey = keychainStore.read(forProvider: "minimax")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveMiniMaxAPIKey: String
            if let keychainMiniMaxAPIKey, !keychainMiniMaxAPIKey.isEmpty {
                effectiveMiniMaxAPIKey = keychainMiniMaxAPIKey
            } else {
                effectiveMiniMaxAPIKey = bootstrapMiniMaxAPIKey
            }
            var minimaxProviderPatch: [String: Any] = [
                "api": "anthropic-messages",
                "baseUrl": "https://api.minimaxi.com/anthropic",
                "authHeader": true,
                "models": minimaxOpenClawModelCatalog,
                "apiKey": effectiveMiniMaxAPIKey,
            ]

            var patch: [String: Any] = [:]

            if minimax == nil || existingMiniMaxAPIKey?.isEmpty != false {
                patch["models"] = [
                    "mode": "merge",
                    "providers": [
                        "minimax": minimaxProviderPatch
                    ]
                ]
            }

            if currentPrimaryModel == nil || currentPrimaryModel?.isEmpty == true {
                let existingFallbacks = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any])?["fallbacks"]
                var modelPatch: [String: Any] = ["primary": defaultMiniMaxModelId]
                if let fallbacks = existingFallbacks {
                    modelPatch["fallbacks"] = fallbacks
                }

                var agentsPatch = (patch["agents"] as? [String: Any]) ?? [:]
                var defaultsPatch = (agentsPatch["defaults"] as? [String: Any]) ?? [:]
                defaultsPatch["model"] = modelPatch
                defaultsPatch["models"] = [
                    defaultMiniMaxModelId: ["alias": "Minimax"]
                ]
                agentsPatch["defaults"] = defaultsPatch
                patch["agents"] = agentsPatch
            }

            guard !patch.isEmpty else { return }

            _ = try await gatewayService.configPatch(
                patch: patch,
                baseHash: baseHash,
                note: "ClawdHome: auto provision default MiniMax model"
            )
        } catch {
            appLog("bootstrap: auto provision default MiniMax model failed: \(error)", level: .warn)
        }
    }
}

// MARK: - 通用维护终端窗口模型

@MainActor
@Observable
final class MaintenanceWindowRegistry {
    private var nextIndexByUser: [String: Int] = [:]

    func makePayload(
        username: String,
        title: String,
        command: [String],
        completionToken: String? = nil,
        completionContext: String? = nil
    ) -> String {
        let next = (nextIndexByUser[username] ?? 0) + 1
        nextIndexByUser[username] = next
        let req = MaintenanceTerminalWindowRequest(
            token: UUID().uuidString,
            username: username,
            title: title,
            command: command,
            index: next,
            completionToken: completionToken,
            completionContext: completionContext
        )
        return req.payload
    }
}

struct MaintenanceTerminalWindowRequest: Codable {
    let token: String
    let username: String
    let title: String
    let command: [String]
    let index: Int
    let completionToken: String?
    let completionContext: String?

    var payload: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return data.base64EncodedString()
    }

    init(
        token: String,
        username: String,
        title: String,
        command: [String],
        index: Int,
        completionToken: String? = nil,
        completionContext: String? = nil
    ) {
        self.token = token
        self.username = username
        self.title = title
        self.command = command
        self.index = index
        self.completionToken = completionToken
        self.completionContext = completionContext
    }

    init?(payload: String?) {
        guard let payload,
              let data = Data(base64Encoded: payload),
              let req = try? JSONDecoder().decode(MaintenanceTerminalWindowRequest.self, from: data) else {
            return nil
        }
        self = req
    }
}

extension Notification.Name {
    static let maintenanceTerminalWindowClosed = Notification.Name("MaintenanceTerminalWindowClosed")
    static let channelOnboardingAutoDetected = Notification.Name("ChannelOnboardingAutoDetected")
}

// MARK: - 维护终端快捷命令

private struct OpenClawQuickCommand: Identifiable {
    let id = UUID()
    let label: String
    let command: String
}

private let openClawQuickCommandSections: [(section: String, items: [OpenClawQuickCommand])] = [
    (L10n.k("app.maintenance.quick.section.query_diagnose", fallback: "查询 / 诊断"), [
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.version", fallback: "版本查询"), command: "openclaw --version"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.status_overview", fallback: "状态概览"), command: "openclaw status"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.model_status", fallback: "模型状态"), command: "openclaw models status --probe"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.connected_devices", fallback: "已连设备"), command: "openclaw devices list"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.system_check", fallback: "系统体检"), command: "openclaw doctor"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.security_audit", fallback: "安全审计"), command: "openclaw security audit"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.live_logs", fallback: "实时日志"), command: "openclaw logs --follow"),
    ]),
    (L10n.k("app.maintenance.quick.section.config_control", fallback: "配置 / 控制"), [
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.configure", fallback: "交互配置"), command: "openclaw configure"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.auto_fix", fallback: "自动修复"), command: "openclaw doctor --fix"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.channel_login", fallback: "频道登录"), command: "openclaw channels login"),
        OpenClawQuickCommand(label: L10n.k("app.maintenance.quick.command.restart_service", fallback: "重启服务"), command: "openclaw gateway restart"),
    ]),
]

// MARK: - 通用维护终端窗口

private struct MaintenanceTerminalWindow: View {
    let payload: String?

    var body: some View {
        if let request = MaintenanceTerminalWindowRequest(payload: payload) {
            MaintenanceTerminalWindowContent(request: request)
        } else {
            ContentUnavailableView(
                L10n.k("app.maintenance.invalid_params", fallback: "维护终端参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.maintenance.invalid_params.desc", fallback: "请从虾详情页或初始化向导重新打开维护终端。"))
            )
        }
    }
}

private struct MaintenanceTerminalWindowContent: View {
    let request: MaintenanceTerminalWindowRequest

    @Environment(\.dismiss) private var dismiss
    @Environment(ShrimpPool.self) private var pool
    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var terminalRunID = 0
    @State private var exitCode: Int32? = nil
    @State private var statusText: String? = nil
    @State private var runStartedAt: Date? = nil
    @State private var lastOutputAt: Date? = nil
    @State private var now = Date()
    @State private var outputBuffer = ""
    @State private var didStart = false
    @State private var didPostCloseNotification = false
    @State private var didAutoCloseOnConfigureComplete = false

    private let waitingThreshold: TimeInterval = 8
    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var windowTitle: String {
        L10n.f(
            "app.maintenance.window.title",
            fallback: L10n.k("clawd_home_app.arg_num", fallback: "@%@ · 维护窗口 #%d"),
            request.username,
            request.index
        )
    }
    private var isRunning: Bool { didStart && exitCode == nil }
    private var isWaitingInput: Bool {
        guard isRunning, let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= waitingThreshold
    }
    private var elapsedText: String {
        guard let runStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        return String(format: "%02d:%02d", elapsed / 60, elapsed % 60)
    }
    private var isModelConfigureCommand: Bool {
        request.command.count >= 4
            && request.command[0] == "openclaw"
            && request.command[1] == "configure"
            && (request.command[2] == "--section" || request.command[2] == "--selection")
            && request.command[3] == "model"
    }
    private var sanitizedOutput: String {
        stripANSIEscapeSequences(outputBuffer)
    }
    private var latestAuthorizeURL: URL? {
        extractURLs(from: sanitizedOutput).last(where: { url in
            let abs = url.absoluteString.lowercased()
            return abs.contains("github.com/login/device") || abs.contains("/oauth/authorize")
        })
    }
    private var latestDeviceCode: String? {
        let pattern = #"(?mi)^\s*Code:\s*([A-Z0-9-]{4,})\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = sanitizedOutput as NSString
        let all = regex.matches(in: sanitizedOutput, range: NSRange(location: 0, length: ns.length))
        guard let last = all.last, last.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: last.range(at: 1))
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 10) {
            if isRunning {
                Label(
                    isWaitingInput
                        ? L10n.k("app.maintenance.status.running_waiting", fallback: "运行中（等待输入）")
                        : L10n.k("app.maintenance.status.running", fallback: "运行中"),
                    systemImage: isWaitingInput ? "hourglass" : "play.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Label(L10n.k("app.maintenance.status.exited", fallback: "已退出"), systemImage: "stop.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(L10n.f("app.maintenance.elapsed", fallback: "耗时 %@", elapsedText))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(L10n.k("common.action.interrupt", fallback: "中断")) { terminalControl.sendInterrupt() }
                .disabled(!isRunning)
            Button(L10n.k("common.action.rerun", fallback: "重跑")) { startRun() }
            Button(L10n.k("common.action.copy_output", fallback: "复制输出")) { copyTerminalOutput() }
                .disabled(outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Spacer(minLength: 0)

            quickCommandMenu
        }
    }

    @ViewBuilder
    private var quickCommandMenu: some View {
        Menu {
            ForEach(openClawQuickCommandSections, id: \.section) { group in
                Section(group.section) {
                    ForEach(group.items) { cmd in
                        Button {
                            terminalControl.sendLine(cmd.command)
                        } label: {
                            Text(cmd.label)
                        }
                    }
                }
            }
        } label: {
            Text(L10n.k("app.maintenance.quick.menu_title", fallback: "🦞openclaw 指令"))
        }
        .menuIndicator(.visible)
        .fixedSize()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            topBar
            authAssistBar
            terminalPanel
            statusBar
            resourceUsageBar
        }
        .padding(10)
        .background(WindowTitleBinder(title: windowTitle))
        .onAppear {
            if !didStart {
                didStart = true
                startRun()
            }
        }
        .onReceive(uiTimer) { tick in
            now = tick
        }
        .onDisappear {
            postCloseNotificationIfNeeded()
            terminalControl.terminate()
            appLog("[maintenance-window] closed user=\(request.username) index=\(request.index) title=\(request.title)")
        }
        .frame(minWidth: isModelConfigureCommand ? 900 : 760, minHeight: isModelConfigureCommand ? 640 : 480)
    }

    @ViewBuilder
    private var authAssistBar: some View {
        if latestAuthorizeURL != nil || latestDeviceCode != nil {
            HStack(spacing: 10) {
                Label(L10n.k("clawd_home_app.auth_assist", fallback: "授权辅助"), systemImage: "key.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let url = latestAuthorizeURL {
                    Button(L10n.k("clawd_home_app.open_auth_page", fallback: "打开授权页")) { _ = NSWorkspace.shared.open(url) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Text(url.absoluteString)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                if let code = latestDeviceCode {
                    Button(L10n.k("clawd_home_app.copy_device_code", fallback: "复制验证码")) {
                        copyText(code, success: L10n.k("clawd_home_app.device_code_copied", fallback: "验证码已复制。"))
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder
    private var terminalPanel: some View {
        HelperMaintenanceTerminalPanel(
            username: request.username,
            command: request.command,
            minHeight: isModelConfigureCommand ? 420 : 280,
            onOutput: { chunk in
                handleTerminalOutput(chunk)
            },
            control: terminalControl,
            onExit: { code in
                handleCommandExit(code)
            }
        )
        .id(terminalRunID)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var statusBar: some View {
        if let st = statusText {
            Text(st)
                .font(.caption)
                .foregroundStyle(exitCode == 0 ? Color.secondary : Color.red)
        }
    }


    private func startRun() {
        exitCode = nil
        statusText = nil
        runStartedAt = Date()
        lastOutputAt = Date()
        now = Date()
        outputBuffer = ""
        terminalRunID += 1
    }

    private func handleTerminalOutput(_ chunk: String) {
        lastOutputAt = Date()
        outputBuffer += chunk
        let maxChars = 300_000
        if outputBuffer.count > maxChars {
            outputBuffer.removeFirst(outputBuffer.count - maxChars)
        }
        autoCloseIfConfigureCompleted(chunk)
    }

    private func autoCloseIfConfigureCompleted(_ chunk: String) {
        guard isModelConfigureCommand, !didAutoCloseOnConfigureComplete else { return }
        let normalized = stripANSIEscapeSequences(chunk).lowercased()
        guard normalized.contains("configure complete.") else { return }
        didAutoCloseOnConfigureComplete = true
        statusText = "检测到 Configure complete.，正在关闭窗口并刷新调用方…"
        postCloseNotificationIfNeeded()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            dismiss()
        }
    }

    private func handleCommandExit(_ code: Int32?) {
        exitCode = code
        let normalized = code ?? -999
        if normalized == 0 {
            statusText = L10n.k("app.clawd_home_app.done", fallback: "维护命令执行完成。")
            appLog("[maintenance-window] command success user=\(request.username) index=\(request.index)")
        } else {
            statusText = String(format: L10n.k("app.clawd_home_app.command_exit_code", fallback: "命令已退出（exit %d）。请查看终端输出。"), normalized)
            appLog(
                "[maintenance-window] command failed user=\(request.username) index=\(request.index) exit=\(normalized)",
                level: .error
            )
        }
    }

    private func copyTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = L10n.k("app.clawd_home_app.no_output_to_copy", fallback: "暂无可复制的命令输出。")
            return
        }
        copyText(text, success: L10n.k("app.clawd_home_app.output_copied", fallback: "命令输出已复制。"))
    }

    private func copyText(_ text: String, success: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = success
    }

    private func stripANSIEscapeSequences(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#) else { return text }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    private func extractURLs(from text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s"'<>)]+"#) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { match in
            let raw = ns.substring(with: match.range)
                .trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            return URL(string: raw)
        }
    }

    @ViewBuilder
    private var resourceUsageBar: some View {
        if let shrimp = pool.snapshot?.shrimps.first(where: { $0.username == request.username }) {
            HStack(spacing: 10) {
                resourceChip(icon: "cpu", title: "CPU", value: shrimp.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "—")
                resourceChip(icon: "memorychip", title: L10n.k("common.resource.memory", fallback: "内存"), value: shrimp.memRssMB.map { formatMem($0) } ?? "—")
                resourceChip(icon: "arrow.down.circle", title: L10n.k("common.resource.net_in", fallback: "入网"), value: FormatUtils.formatBps(shrimp.netRateInBps))
                resourceChip(icon: "arrow.up.circle", title: L10n.k("common.resource.net_out", fallback: "出网"), value: FormatUtils.formatBps(shrimp.netRateOutBps))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.7))
            .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func postCloseNotificationIfNeeded() {
        guard !didPostCloseNotification, let completionToken = request.completionToken else { return }
        didPostCloseNotification = true
        NotificationCenter.default.post(
            name: .maintenanceTerminalWindowClosed,
            object: nil,
            userInfo: [
                "token": completionToken,
                "username": request.username,
                "title": request.title,
                "context": request.completionContext ?? "",
                "exitCode": (exitCode.map(NSNumber.init(value:)) ?? NSNull()) as Any
            ]
        )
    }

    @ViewBuilder
    private func resourceChip(icon: String, title: String, value: String) -> some View {
        Label("\(title) \(value)", systemImage: icon)
            .lineLimit(1)
    }

    private func formatMem(_ memMB: Double) -> String {
        if memMB < 1024 {
            return String(format: "%.0f MB", memMB)
        }
        return String(format: "%.2f GB", memMB / 1024)
    }

private struct WindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            view.window?.title = title
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
}

// MARK: - 通道配置窗口

private struct ChannelOnboardingWindow: View {
    let payload: String?
    @Environment(ShrimpPool.self) private var pool

    var body: some View {
        if let payload, let req = ChannelOnboardingRequest(payload: payload) {
            let displayName = pool.users.first(where: { $0.username == req.username })?.fullName ?? ""
            switch req.flow {
            case .feishu:
                FeishuChannelOnboardingSheet(flow: .feishu, displayName: displayName, username: req.username)
            case .weixin:
                FeishuChannelOnboardingSheet(flow: .weixin, displayName: displayName, username: req.username)
            }
        } else {
            ContentUnavailableView(
                L10n.k("app.channel.invalid_params", fallback: "通道参数无效"),
                systemImage: "exclamationmark.triangle",
                description: Text(L10n.k("app.channel.invalid_params.desc", fallback: "请从虾详情页重新打开通道配置窗口。"))
            )
        }
    }
}

private struct ChannelOnboardingRequest {
    let flow: ChannelOnboardingFlow
    let username: String

    init?(payload: String) {
        let parts = payload.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              let flow = ChannelOnboardingFlow(rawValue: parts[0]),
              !parts[1].isEmpty else { return nil }
        self.flow = flow
        self.username = parts[1]
    }
}

// MARK: - 龙虾详情窗口定位器

/// 首次出现时把 claw-detail 窗口定位到主窗口右侧区域（侧栏宽度 idealSidebar）
private struct ClawDetailWindowPositioner: NSViewRepresentable {
    private let idealSidebar: CGFloat = 200
    private let preferredSize = NSSize(
        width: UserDetailWindowLayout.mainWindowDefaultWidth,
        height: UserDetailWindowLayout.detailWindowDefaultHeight
    )
    private let minimumSize = NSSize(
        width: UserDetailWindowLayout.detailWindowMinimumWidth,
        height: UserDetailWindowLayout.detailWindowMinimumHeight
    )

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(
                view: view,
                sidebar: idealSidebar,
                preferredSize: preferredSize,
                minimumSize: minimumSize
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(
        view: NSView,
        sidebar: CGFloat,
        preferredSize: NSSize,
        minimumSize: NSSize
    ) {
        guard let detailWindow = view.window else { return }
        detailWindow.contentMinSize = minimumSize
        // 找到主窗口（同进程、可见、非 claw-detail 自身）
        let mainWindow = NSApp.windows.first {
            $0 !== detailWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }
        let visibleFrame = main.screen?.visibleFrame ?? detailWindow.screen?.visibleFrame ?? main.frame

        // 首开时继承主窗口当前宽度，只在屏幕可见范围内钳制，避免详情窗口首开偏窄。
        let originX = min(main.frame.minX + sidebar, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let visibleWidth = visibleFrame.maxX - originX
        let width = resolvedUserDetailWindowWidth(
            mainWindowWidth: main.frame.width,
            visibleWidth: visibleWidth
        )
        let height = min(preferredSize.height, visibleFrame.maxY - originY)
        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: width,
            height: max(minimumSize.height, height)
        )
        detailWindow.setFrame(frame, display: true)
    }
}

// MARK: - 初始化窗口定位器

/// 首次出现时将初始化窗口高度对齐主窗口高度，避免与主窗口尺寸不一致。
private struct UserInitWizardWindowPositioner: NSViewRepresentable {
    private let preferredWidth: CGFloat = 980
    private let minimumSize = NSSize(width: 860, height: 560)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(view: view, preferredWidth: preferredWidth, minimumSize: minimumSize)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(view: NSView, preferredWidth: CGFloat, minimumSize: NSSize) {
        guard let wizardWindow = view.window else { return }
        wizardWindow.contentMinSize = minimumSize

        let mainWindow = NSApp.windows.first {
            $0 !== wizardWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }

        let visibleFrame = main.screen?.visibleFrame ?? wizardWindow.screen?.visibleFrame ?? main.frame
        let originX = min(main.frame.minX, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let targetHeight = min(main.frame.height, visibleFrame.maxY - originY)
        let targetWidth = min(preferredWidth, visibleFrame.maxX - originX)

        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: max(minimumSize.width, targetWidth),
            height: max(minimumSize.height, targetHeight)
        )
        wizardWindow.setFrame(frame, display: true)
    }
}

// MARK: - 龙虾详情窗口容器

/// 通过 username 从 ShrimpPool 查找用户并展示 UserDetailView。
/// 同一 username 的窗口由 SwiftUI 去重：再次 openWindow 只会置前已有窗口。
private struct ClawDetailWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var pool
    @Environment(\.dismiss)       private var dismiss

    private var user: ManagedUser? {
        pool.users.first { $0.username == username }
    }

    var body: some View {
        NavigationStack {
            if let user {
                UserDetailView(user: user, onDeleted: {
                    dismiss()
                    Task { @MainActor in
                        pool.removeUser(username: username)
                    }
                })
            } else {
                ContentUnavailableView(
                    "@\(username)",
                    systemImage: "person.slash",
                    description: Text(L10n.k("app.claw_detail.user_missing", fallback: "该用户已被删除或尚未加载"))
                )
                .navigationTitle("@\(username)")
            }
        }
    }
}

private struct UserInitWizardWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var pool
    @Environment(\.dismiss) private var dismiss

    private var user: ManagedUser? {
        pool.users.first { $0.username == username }
    }

    var body: some View {
        if let user {
            UserInitWizardView(user: user) { sessionVisible in
                if !sessionVisible {
                    dismiss()
                }
            }
        } else {
            ContentUnavailableView(
                "@\(username)",
                systemImage: "person.slash",
                description: Text(L10n.k("app.user_init_wizard.user_missing", fallback: "该用户已被删除或尚未加载"))
            )
        }
    }
}
