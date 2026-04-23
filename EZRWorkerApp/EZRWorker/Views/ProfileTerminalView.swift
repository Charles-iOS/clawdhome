import SwiftUI
import SwiftTerm

private final class ProfileTerminalControl: ObservableObject {
    fileprivate weak var terminalView: LocalProcessTerminalView?

    fileprivate func attach(_ terminalView: LocalProcessTerminalView) {
        self.terminalView = terminalView
    }

    func sendInterrupt() {
        terminalView?.process.send(data: ArraySlice([0x03]))
    }

    func terminate() {
        terminalView?.terminate()
    }
}

struct ProfileTerminalWindow: View {
    let profileIDString: String

    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(GatewayService.self) private var gatewayService
    @Environment(SupervisorClient.self) private var supervisorClient

    @State private var refreshError: String?

    private var profile: GatewayProfile? {
        if let id = UUID(uuidString: profileIDString),
           let profile = profileStore.profiles.first(where: { $0.id == id }) {
            return profile
        }
        return profileStore.selectedProfile
    }

    var body: some View {
        Group {
            if let profile {
                let resolution = GatewayProfileResolver.resolve(profile)
                ProfileTerminalPanel(
                    profile: profile,
                    resolution: resolution,
                    runtime: runtime(for: profile)
                )
                .environment(processManager)
                .environment(gatewayService)
                .safeAreaInset(edge: .top, spacing: 0) {
                    terminalHeader(profile: profile, resolution: resolution)
                }
            } else {
                ContentUnavailableView(
                    "当前没有可用 Profile",
                    systemImage: "terminal",
                    description: Text("请先在设置中创建或导入 Gateway/Profile。")
                )
                .padding()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
        .task {
            await refreshRuntime()
        }
    }

    @ViewBuilder
    private func terminalHeader(
        profile: GatewayProfile,
        resolution: GatewayProfileResolution
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label("OpenClaw 终端", systemImage: "terminal")
                    .font(.headline)

                Text(profile.displayName)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(SwiftUI.Color.accentColor.opacity(0.12), in: Capsule())
                    .foregroundStyle(SwiftUI.Color.accentColor)

                Text(profile.slug)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)

                Spacer()

                Button("刷新状态") {
                    Task {
                        await refreshRuntime()
                    }
                }
                .buttonStyle(.bordered)
            }

            HStack(spacing: 16) {
                headerItem("Gateway", gatewayStateLabel)
                headerItem("端口", "\(processManager.gatewayPort)")
                headerItem("WebSocket", gatewayService.isConnected ? "已连接" : "未连接")
                headerItem("Workspace", resolution.resolvedWorkspaceRoot)
            }

            if let refreshError {
                Text(refreshError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private func headerItem(_ title: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
    }

    private var gatewayStateLabel: String {
        switch processManager.state {
        case .running:
            "运行中"
        case .stopping:
            "停止中"
        case .starting:
            "启动中"
        case .stopped:
            "已停止"
        case .failed(let message):
            message
        }
    }

    private func runtime(for profile: GatewayProfile) -> SupervisorProfileRuntime? {
        supervisorClient.runtimes.first(where: { $0.profileID == profile.id })
    }

    @MainActor
    private func refreshRuntime() async {
        refreshError = nil
        if !supervisorClient.isConnected {
            supervisorClient.connect()
            guard await supervisorClient.waitUntilConnected() else {
                refreshError = "EZRWorkerSupervisor 未就绪，暂时无法刷新运行态。"
                return
            }
        }

        _ = await supervisorClient.refreshRuntimes()
        await processManager.refreshRuntimeState()
    }
}

private struct ProfileTerminalPanel: View {
    let profile: GatewayProfile
    let resolution: GatewayProfileResolution
    let runtime: SupervisorProfileRuntime?

    @StateObject private var terminalControl = ProfileTerminalControl()
    @State private var launchID = UUID()
    @State private var exitCode: Int32?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor)

                Spacer()

                Button("中断") {
                    terminalControl.sendInterrupt()
                }
                .buttonStyle(.bordered)

                Button("重启终端") {
                    terminalControl.terminate()
                    exitCode = nil
                    launchID = UUID()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)

            Divider()

            ProfileTerminalNSView(
                resolution: resolution,
                control: terminalControl
            ) { code in
                exitCode = code
            }
            .id(launchID)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SwiftUI.Color(nsColor: .textBackgroundColor))
        .onDisappear {
            terminalControl.terminate()
        }
    }

    private var statusText: String {
        if let exitCode {
            return "终端已退出（exit \(exitCode)）"
        }
        if runtime?.isRunning == true {
            return "已进入当前 profile。可执行 openclaw configure --section model 等命令。"
        }
        return "Gateway 未运行；本地配置命令仍可执行，依赖 Gateway 的命令可能不可用。"
    }

    private var statusColor: SwiftUI.Color {
        if let exitCode, exitCode != 0 {
            return .red
        }
        if runtime?.isRunning == true {
            return .secondary
        }
        return .orange
    }
}

private struct ProfileTerminalNSView: NSViewRepresentable {
    let resolution: GatewayProfileResolution
    let control: ProfileTerminalControl
    let onExit: (Int32?) -> Void

    func makeCoordinator() -> LocalProcessCoordinator {
        LocalProcessCoordinator(onExit: onExit)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let terminal = OutputObservingLocalProcessTerminalView(frame: .zero)
        terminal.processDelegate = context.coordinator
        terminal.allowMouseReporting = false
        terminal.nativeForegroundColor = NSColor.labelColor
        terminal.nativeBackgroundColor = NSColor.textBackgroundColor
        terminal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        terminal.onOutputBytes = { bytes in
            let chunk = String(decoding: Array(bytes), as: UTF8.self)
            context.coordinator.handleOutputChunk(chunk)
        }

        do {
            let launchContext = try ProfileCLIService.makeTerminalLaunchContext(profile: resolution)
            terminal.startProcess(
                executable: launchContext.executable,
                args: launchContext.arguments,
                environment: launchContext.environment.map { "\($0.key)=\($0.value)" }
            )
        } catch {
            terminal.startProcess(
                executable: "/bin/sh",
                args: ["-lc", "printf '%s\\n' \(shellSingleQuoted("终端启动失败：\(error.localizedDescription)")); exit 1"],
                environment: nil
            )
        }

        control.attach(terminal)
        return terminal
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: LocalProcessCoordinator) {
        nsView.terminate()
    }

    private func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
