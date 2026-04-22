import SwiftUI
import AppKit
import Foundation

enum ChannelOnboardingFlow: String, Identifiable, CaseIterable {
    case feishu
    case weixin
    case wecom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .feishu: return L10n.k("channel.flow.feishu.title", fallback: "飞书")
        case .weixin: return L10n.k("channel.flow.weixin.title", fallback: "微信")
        case .wecom:  return L10n.k("channel.flow.wecom.title", fallback: "企微")
        }
    }

    var commandArgs: [String] {
        switch self {
        case .feishu:
            return ["-y", "@larksuite/openclaw-lark-tools", "install"]
        case .weixin:
            return ["-y", "@tencent-weixin/openclaw-weixin-cli@latest", "install"]
        case .wecom:
            return ["-y", "@wecom/wecom-openclaw-cli", "install"]
        }
    }

    var channelTypeForVerification: ChannelType? {
        switch self {
        case .feishu: return .feishu
        case .weixin: return .weixin
        case .wecom:  return .wecom
        }
    }
}

private struct ChannelConfigVerificationSnapshot {
    let connected: Bool
    let enabled: Bool?
    let localConnected: Bool
    let gatewayConnected: Bool
}

struct FeishuChannelOnboardingSheet: View {
    let flow: ChannelOnboardingFlow
    let displayName: String
    let username: String

    @Environment(GatewayService.self) private var gateway
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var showTerminal = false
    @State private var terminalRunID = 0
    @State private var exitCode: Int32? = nil
    @State private var statusText: String? = nil
    @State private var runStartedAt: Date? = nil
    @State private var lastOutputAt: Date? = nil
    @State private var now = Date()
    @State private var outputBuffer = ""
    @State private var didDetectPairingDone = false
    @State private var didScheduleAutoClose = false
    @State private var verificationTask: Task<Void, Never>? = nil
    @State private var didPostAutoDetectedNotification = false
    @State private var didLogCompletionMarker = false
    @State private var didConfirmConfiguredState = false
    @State private var wasConfiguredBeforeRun = false

    private let commandExecutable = GatewayProcessManager.bundledNpxURL.path
    private let waitingThreshold: TimeInterval = 8
    private let verificationTimeout: TimeInterval = 15
    private let verificationPollInterval: UInt64 = 1_000_000_000
    private let uiTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var commandArgs: [String] { flow.commandArgs }
    private var logPrefix: String { flow.rawValue }
    private var selectedResolution: GatewayProfileResolution? { profileStore.selectedResolution }
    private var selectedLocalPaths: GatewayProfileLocalPaths? { profileStore.selectedLocalPaths }
    private var commandEnvironment: [String: String] {
        var environment = GatewayProcessManager.buildEnvironment(profile: selectedResolution)
        let home = environment["HOME"] ?? "/Users/\(username)"
        let nodeBin = GatewayProcessManager.bundledNodeURL.deletingLastPathComponent().path
        let openclawBin = GatewayProcessManager.bundledOpenClawEntry
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("bin")
            .path
        let npmGlobalBin = "\(home)/.npm-global/bin"
        let existingPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        environment["PATH"] = "\(nodeBin):\(openclawBin):\(npmGlobalBin):\(existingPath)"
        environment["NODE_ENV"] = "production"
        return environment
    }

    private var commandSummary: String {
        ([commandExecutable] + commandArgs).joined(separator: " ")
    }

    private var completionMarkers: [String] {
        switch flow {
        case .feishu:
            return [
                "success! bot configured",
                "bot configured",
                "机器人配置成功",
                "openclaw is all set"
            ]
        case .weixin:
            return [
                "与微信连接成功",
                "微信连接成功",
                "config overwrite:",
                "正在重启 openclaw gateway"
            ]
        case .wecom:
            return [
                "接入成功",
                "绑定成功",
                "配置成功",
                "机器人配置成功",
                "正在重启 openclaw gateway",
                "gateway restart"
            ]
        }
    }

    private var usesStrictConfigVerification: Bool {
        flow == .wecom
    }

    private var isRunning: Bool {
        showTerminal && exitCode == nil
    }

    private var isWaitingInput: Bool {
        guard isRunning, let lastOutputAt else { return false }
        return now.timeIntervalSince(lastOutputAt) >= waitingThreshold
    }

    private var stageTitle: String {
        if !showTerminal { return L10n.k("channel.stage.idle", fallback: "待开始") }
        if isRunning {
            return isWaitingInput
                ? L10n.k("channel.stage.running_waiting", fallback: "运行中（等待输入）")
                : L10n.k("channel.stage.running", fallback: "运行中")
        }
        if exitCode == 0 { return L10n.k("channel.stage.done", fallback: "已完成") }
        return L10n.k("channel.stage.exited", fallback: "已退出")
    }

    private enum PairingButtonState {
        case idle
        case running
        case succeeded
        case failed
    }

    private var pairingButtonState: PairingButtonState {
        if isRunning { return .running }
        guard showTerminal else { return .idle }
        if exitCode == 0 { return .succeeded }
        return .failed
    }

    private var pairingButtonTitle: String {
        switch pairingButtonState {
        case .idle:
            return flow == .wecom
                ? L10n.k("channel.pairing.button.wecom.start", fallback: "开始扫码接入")
                : L10n.k("channel.pairing.button.generate", fallback: "生成配对二维码")
        case .running:
            return flow == .wecom
                ? L10n.k("channel.pairing.button.wecom.running", fallback: "接入中…")
                : L10n.k("channel.pairing.button.generating", fallback: "生成中…")
        case .succeeded:
            return flow == .wecom
                ? L10n.k("channel.pairing.button.wecom.retry", fallback: "重新扫码接入")
                : L10n.k("channel.pairing.button.regenerate", fallback: "重新生成二维码")
        case .failed:
            return flow == .wecom
                ? L10n.k("channel.pairing.button.wecom.retry", fallback: "重试扫码接入")
                : L10n.k("channel.pairing.button.retry", fallback: "重试生成二维码")
        }
    }

    private var pairingButtonIcon: String {
        switch pairingButtonState {
        case .idle: return "qrcode.viewfinder"
        case .running: return "hourglass"
        case .succeeded: return "arrow.clockwise.circle"
        case .failed: return "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
        }
    }

    private var pairingStatusLabelText: String {
        switch pairingButtonState {
        case .idle: return L10n.k("channel.pairing.status.idle", fallback: "未开始")
        case .running:
            return isWaitingInput
                ? L10n.k("channel.pairing.status.waiting_input", fallback: "等待扫码/输入")
                : L10n.k("channel.pairing.status.running", fallback: "命令执行中")
        case .succeeded: return L10n.k("channel.pairing.status.succeeded", fallback: "已完成，可再次生成")
        case .failed: return L10n.k("channel.pairing.status.failed", fallback: "生成失败，可重试")
        }
    }

    private var elapsedText: String {
        guard let runStartedAt else { return "00:00" }
        let elapsed = max(0, Int(now.timeIntervalSince(runStartedAt)))
        let min = elapsed / 60
        let sec = elapsed % 60
        return String(format: "%02d:%02d", min, sec)
    }

    private var shrimpIdentityTitle: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == username {
            return "@\(username)"
        }
        return "\(trimmed) - @\(username)"
    }

    private var windowTitle: String {
        "\(shrimpIdentityTitle) · \(flow.title) 通道配置 · \(stageTitle)"
    }

    private var pairingHintText: String {
        switch flow {
        case .wecom:
            return L10n.k(
                "channel.pairing.hint.wecom",
                fallback: "请点击按钮启动企微接入流程，在终端中选择“扫码接入”，完成授权后系统会自动检查是否已成功接入。"
            )
        case .feishu, .weixin:
            return L10n.k(
                "channel.pairing.hint",
                fallback: "请点击按钮生成二维码，扫码配对后给龙虾发消息测试，正常即可关闭窗口。"
            )
        }
    }

    private var statusTextColor: Color {
        if let exitCode, exitCode != 0 {
            return .red
        }
        return .secondary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pairingHintText)
                .font(.callout)
                .foregroundStyle(.secondary)
            actionRow
            if let statusText {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusTextColor)
            }
            if showTerminal {
                runtimeToolbar
                UserCommandTerminalPanel(
                    username: username,
                    executable: commandExecutable,
                    args: commandArgs,
                    minHeight: 360,
                    environmentOverrides: commandEnvironment,
                    onOutput: handleTerminalOutput,
                    control: terminalControl
                ) { code in
                    handleCommandExit(code)
                }
                .id(terminalRunID)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(uiTimer) { tick in
            now = tick
        }
        .onDisappear {
            verificationTask?.cancel()
            verificationTask = nil
            terminalControl.terminate()
            if usesStrictConfigVerification && showTerminal && !didDetectPairingDone {
                appLog("[\(logPrefix)] ui onboarding window closed before strict verification confirmed @\(username)", level: .warn)
            }
            appLog("[\(logPrefix)] ui onboarding window disappeared; terminate active terminal session @\(username)")
        }
        .background(ChannelOnboardingWindowTitleBinder(title: windowTitle))
        .background(ChannelOnboardingWindowLevelBinder())
        .frame(minWidth: 900, minHeight: 560)
    }


    @ViewBuilder
    private var actionRow: some View {
        HStack(spacing: 10) {
            Button {
                startInteractiveRun()
            }
            label: {
                Label(pairingButtonTitle, systemImage: pairingButtonIcon)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pairingButtonState == .running)

            if pairingButtonState == .running {
                Button(L10n.k("channel.pairing.button.interrupt_generation", fallback: "中断生成")) {
                    terminalControl.sendInterrupt()
                    appLog("[\(logPrefix)] ui interactive interrupt from action row @\(username)")
                }
            }

            Text(L10n.f("channel.pairing.status_label", fallback: "状态：%@", pairingStatusLabelText))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(L10n.k("common.close", fallback: "关闭")) {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var runtimeToolbar: some View {
        HStack(spacing: 10) {
            Label(
                isRunning
                ? (isWaitingInput
                   ? L10n.k("channel.stage.running_waiting", fallback: "运行中（等待输入）")
                   : L10n.k("channel.stage.running", fallback: "运行中"))
                : L10n.k("channel.stage.exited", fallback: "已退出"),
                systemImage: isRunning ? (isWaitingInput ? "hourglass" : "play.circle.fill") : "stop.circle"
            )
            .font(.caption)
            .foregroundStyle(isRunning ? .secondary : .secondary)

            Text(L10n.f("channel.runtime.elapsed", fallback: "耗时 %@", elapsedText))
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Button(L10n.k("common.action.interrupt", fallback: "中断")) {
                terminalControl.sendInterrupt()
                appLog("[\(logPrefix)] ui interactive interrupt @\(username)")
            }
            .disabled(!isRunning)

            Button(L10n.k("common.action.rerun", fallback: "重跑")) {
                startInteractiveRun()
            }

            Button(L10n.k("common.action.copy_output", fallback: "复制输出")) {
                copyTerminalOutput()
            }
            .disabled(outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button(L10n.k("common.close", fallback: "关闭")) {
                dismiss()
            }
            .buttonStyle(.bordered)
        }
    }

    private func startInteractiveRun() {
        verificationTask?.cancel()
        verificationTask = nil
        wasConfiguredBeforeRun = localChannelConfigSnapshot().connected
        appLog("[\(logPrefix)] ui interactive run start @\(username) cmd=\(commandSummary) preConfiguredLocal=\(wasConfiguredBeforeRun)")
        exitCode = nil
        statusText = nil
        runStartedAt = Date()
        lastOutputAt = Date()
        now = Date()
        outputBuffer = ""
        didDetectPairingDone = false
        didScheduleAutoClose = false
        didPostAutoDetectedNotification = false
        didLogCompletionMarker = false
        didConfirmConfiguredState = false
        showTerminal = true
        terminalRunID += 1
    }

    private func handleTerminalOutput(_ chunk: String) {
        lastOutputAt = Date()
        outputBuffer += chunk
        // 控制内存占用：仅保留最近 300KB 文本
        let maxChars = 300_000
        if outputBuffer.count > maxChars {
            outputBuffer.removeFirst(outputBuffer.count - maxChars)
        }
        evaluatePairingCompletion(from: chunk)
    }

    private func copyTerminalOutput() {
        let text = outputBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            statusText = L10n.k("channel.runtime.no_output_to_copy", fallback: "暂无可复制的命令输出。")
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusText = L10n.k("channel.runtime.output_copied", fallback: "命令输出已复制。")
        appLog("[\(logPrefix)] ui interactive output copied @\(username) bytes=\(text.utf8.count)")
    }

    private func handleCommandExit(_ code: Int32?) {
        exitCode = code
        let normalized = code ?? -999
        appLog("[\(logPrefix)] ui interactive run exited @\(username) exit=\(normalized)")

        if usesStrictConfigVerification {
            if normalized == 0 {
                if didConfirmConfiguredState {
                    finalizeStrictCompletion(reason: "process_exit_after_verified_config", snapshot: nil)
                } else {
                    statusText = L10n.k(
                        "channel.runtime.exit.success.wecom_verifying",
                        fallback: "命令执行完成，正在确认企微接入状态…"
                    )
                    requestStrictConfigVerification(
                        reason: "process_exit_0",
                        userVisibleStatus: L10n.k(
                            "channel.runtime.exit.success.wecom_verifying",
                            fallback: "命令执行完成，正在确认企微接入状态…"
                        ),
                        forceRestart: true
                    )
                }
                appLog("[\(logPrefix)] strict verification pending after successful exit @\(username) preConfiguredLocal=\(wasConfiguredBeforeRun)")
            } else {
                verificationTask?.cancel()
                verificationTask = nil
                statusText = L10n.f(
                    "channel.runtime.exit.failed",
                    fallback: L10n.k("views.channel_onboarding.feishu_channel_onboarding_sheet.exit_num_retry", fallback: "命令已退出（exit %d）。请查看上方终端输出并重试。"),
                    normalized
                )
                appLog("[\(logPrefix)] ui interactive run failed @\(username) exit=\(normalized)", level: .error)
            }
            return
        }

        evaluatePairingCompletion(from: outputBuffer)
        if normalized == 0 {
            if didDetectPairingDone {
                statusText = L10n.k("channel.runtime.exit.success_autoclose", fallback: "检测到配对已完成，窗口将自动关闭。")
                scheduleAutoCloseIfNeeded(reason: "process_exit_after_completion_marker")
            } else {
                statusText = L10n.k("channel.runtime.exit.success", fallback: "命令执行完成。若已扫码完成配对，可直接关闭窗口。")
            }
            appLog("[\(logPrefix)] ui interactive run success @\(username)")
        } else {
            statusText = L10n.f(
                "channel.runtime.exit.failed",
                fallback: L10n.k("views.channel_onboarding.feishu_channel_onboarding_sheet.exit_num_retry", fallback: "命令已退出（exit %d）。请查看上方终端输出并重试。"),
                normalized
            )
            appLog("[\(logPrefix)] ui interactive run failed @\(username) exit=\(normalized)", level: .error)
        }
    }

    private func evaluatePairingCompletion(from text: String) {
        let normalized = normalizedOutput(text)
        guard let matchedMarker = completionMarkers.first(where: { normalized.contains($0.lowercased()) }) else {
            return
        }

        if usesStrictConfigVerification {
            if !didLogCompletionMarker {
                didLogCompletionMarker = true
                appLog("[\(logPrefix)] potential completion marker observed @\(username) marker=\(matchedMarker)")
            }
            requestStrictConfigVerification(
                reason: "completion_marker",
                userVisibleStatus: L10n.k(
                    "channel.runtime.pairing.detected.wecom_verifying",
                    fallback: "已检测到接入完成提示，正在确认企微接入状态…"
                )
            )
            return
        }

        guard !didDetectPairingDone else { return }

        didDetectPairingDone = true
        statusText = L10n.k("channel.runtime.pairing.detected_autoclose", fallback: "已检测到“配置成功/完成”提示，窗口将在 2 秒后自动关闭。")
        postAutoDetectedNotificationIfNeeded()
        appLog("[\(logPrefix)] completion marker detected; schedule auto close @\(username)")
        scheduleAutoCloseIfNeeded(reason: "completion_marker")
    }

    private func normalizedOutput(_ text: String) -> String {
        // 终端输出可能带 ANSI 控制符，先清理再做关键词匹配，避免漏判。
        let ansiPattern = #"\u{001B}\[[0-9;?]*[ -/]*[@-~]"#
        let stripped = text.replacingOccurrences(of: ansiPattern, with: "", options: .regularExpression)
        return stripped.lowercased()
    }

    private func requestStrictConfigVerification(
        reason: String,
        userVisibleStatus: String,
        forceRestart: Bool = false
    ) {
        guard usesStrictConfigVerification, !didDetectPairingDone, !didConfirmConfiguredState else { return }

        if forceRestart {
            verificationTask?.cancel()
            verificationTask = nil
        } else if verificationTask != nil {
            return
        }

        statusText = userVisibleStatus
        let runID = terminalRunID
        let reasonLabel = reason
        verificationTask = Task {
            appLog("[\(logPrefix)] strict verification started @\(username) reason=\(reasonLabel)")
            let deadline = Date().addingTimeInterval(verificationTimeout)

            while !Task.isCancelled, Date() < deadline {
                let snapshot = await channelConfigSnapshot()
                if snapshot.connected {
                    await MainActor.run {
                        guard self.terminalRunID == runID else { return }
                        self.verificationTask = nil
                        self.didConfirmConfiguredState = true
                        if self.exitCode == nil {
                            self.statusText = L10n.k(
                                "channel.runtime.pairing.detected.wecom_waiting_exit",
                                fallback: "已确认企微接入配置，等待命令完成后将自动关闭窗口。"
                            )
                        } else {
                            self.finalizeStrictCompletion(
                                reason: "strict_verification_\(reasonLabel)",
                                snapshot: snapshot
                            )
                        }
                    }
                    if snapshot.enabled != nil {
                        appLog(
                            "[\(logPrefix)] strict verification confirmed config @\(username) reason=\(reasonLabel) local=\(snapshot.localConnected) gateway=\(snapshot.gatewayConnected) enabled=\(String(describing: snapshot.enabled))"
                        )
                    } else {
                        appLog(
                            "[\(logPrefix)] strict verification confirmed config @\(username) reason=\(reasonLabel) local=\(snapshot.localConnected) gateway=\(snapshot.gatewayConnected)"
                        )
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: verificationPollInterval)
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.terminalRunID == runID else { return }
                self.verificationTask = nil
                if self.exitCode == 0 && !self.didConfirmConfiguredState {
                    self.statusText = L10n.k(
                        "channel.runtime.exit.success.wecom_unverified",
                        fallback: "尚未确认企微接入完成，请检查终端输出或稍后重试。"
                    )
                }
            }
            appLog(
                "[\(logPrefix)] strict verification not confirmed @\(username) reason=\(reasonLabel) exit=\(String(describing: codeForLog()))",
                level: .warn
            )
        }
    }

    private func finalizeStrictCompletion(
        reason: String,
        snapshot: ChannelConfigVerificationSnapshot?
    ) {
        guard !didDetectPairingDone else { return }
        didDetectPairingDone = true
        statusText = L10n.k(
            "channel.runtime.exit.success.wecom_autoclose",
            fallback: "已确认企微接入完成，窗口将在 2 秒后自动关闭。"
        )
        postAutoDetectedNotificationIfNeeded()
        if let snapshot {
            appLog(
                "[\(logPrefix)] strict completion confirmed @\(username) reason=\(reason) local=\(snapshot.localConnected) gateway=\(snapshot.gatewayConnected) enabled=\(String(describing: snapshot.enabled))"
            )
        } else {
            appLog("[\(logPrefix)] strict completion confirmed @\(username) reason=\(reason)")
        }
        scheduleAutoCloseIfNeeded(reason: reason)
    }

    private func postAutoDetectedNotificationIfNeeded() {
        guard !didPostAutoDetectedNotification else { return }
        didPostAutoDetectedNotification = true
        NotificationCenter.default.post(
            name: .channelOnboardingAutoDetected,
            object: nil,
            userInfo: [
                "username": username,
                "flow": flow.rawValue
            ]
        )
    }

    private func scheduleAutoCloseIfNeeded(reason: String) {
        guard !didScheduleAutoClose else { return }
        didScheduleAutoClose = true
        appLog("[\(logPrefix)] auto close scheduled @\(username) reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            dismiss()
        }
    }

    private func channelConfigSnapshot() async -> ChannelConfigVerificationSnapshot {
        guard let channel = flow.channelTypeForVerification else {
            return ChannelConfigVerificationSnapshot(
                connected: false,
                enabled: nil,
                localConnected: false,
                gatewayConnected: false
            )
        }

        let localSnapshot = loadChannelConfigSnapshot(for: channel)
        var enabled = localSnapshot.enabled
        var gatewayConnected = false

        if gateway.isConnected {
            do {
                let (config, _) = try await gateway.configGetFull()
                let channels = config["channels"] as? [String: Any] ?? [:]
                let gatewayConfig = channels[channel.rawValue] as? [String: Any] ?? [:]
                gatewayConnected = !gatewayConfig.isEmpty
                if let gatewayEnabled = gatewayConfig["enabled"] as? Bool {
                    enabled = gatewayEnabled
                }
            } catch {
                // gateway 在扫码接入成功前后可能短暂重启，这里静默回退到本地配置快照。
            }
        }

        return ChannelConfigVerificationSnapshot(
            connected: localSnapshot.connected || gatewayConnected,
            enabled: enabled,
            localConnected: localSnapshot.connected,
            gatewayConnected: gatewayConnected
        )
    }

    private func loadChannelConfigSnapshot(for channel: ChannelType) -> (connected: Bool, enabled: Bool?) {
        guard let configURL = selectedLocalPaths?.configURL else {
            return (false, nil)
        }
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (false, nil)
        }

        let channels = json["channels"] as? [String: Any] ?? [:]
        let channelConfig = channels[channel.rawValue] as? [String: Any] ?? [:]
        return (!channelConfig.isEmpty, channelConfig["enabled"] as? Bool)
    }

    private func localChannelConfigSnapshot() -> (connected: Bool, enabled: Bool?) {
        guard let channel = flow.channelTypeForVerification else {
            return (false, nil)
        }
        return loadChannelConfigSnapshot(for: channel)
    }

    private func codeForLog() -> Int32 {
        exitCode ?? -999
    }
}

private struct ChannelOnboardingWindowTitleBinder: NSViewRepresentable {
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

private struct ChannelOnboardingWindowLevelBinder: NSViewRepresentable {
    final class Coordinator {
        var didActivate = false
        var didScheduleUnpin = false
        var didUnpin = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            apply(window: view.window, context: context)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            apply(window: nsView.window, context: context)
        }
    }

    private func apply(window: NSWindow?, context: Context) {
        guard let window else { return }
        if context.coordinator.didUnpin {
            if window.level != .normal {
                window.level = .normal
            }
        } else if window.level != .floating {
            window.level = .floating
        }
        if !context.coordinator.didScheduleUnpin {
            context.coordinator.didScheduleUnpin = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak window] in
                guard let window else { return }
                context.coordinator.didUnpin = true
                if window.level == .floating {
                    window.level = .normal
                }
            }
        }
        guard !context.coordinator.didActivate else { return }
        context.coordinator.didActivate = true
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
