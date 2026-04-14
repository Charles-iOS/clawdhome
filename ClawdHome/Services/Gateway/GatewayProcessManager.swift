// ClawdHome/Services/Gateway/GatewayProcessManager.swift
// 管理本地 OpenClaw Gateway 进程的生命周期

import Darwin
import Foundation
import Observation

@MainActor @Observable
final class GatewayProcessManager {

    enum State: Equatable {
        case stopped
        case stopping
        case starting
        case running
        case failed(String)
    }

    enum Ownership: Equatable {
        case none
        case managed
        case reused
    }

    private(set) var state: State = .stopped
    private(set) var ownership: Ownership = .none
    private(set) var gatewayPort: Int = 18789

    var isRunning: Bool { state == .running }

    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var restartCount = 0
    private let maxAutoRestarts = 5

    // MARK: - 生命周期

    func start() {
        guard state != .starting, state != .stopping, process == nil, stopTask == nil else { return }
        state = .starting
        restartCount = 0

        // 先检测是否已有 gateway 实例在运行（如 LaunchAgent 拉起的）
        Task {
            let (_, ready) = await GatewayClient.httpProbe(port: gatewayPort)
            if ready {
                appLog("GatewayProcessManager: existing gateway detected on port \(gatewayPort), reusing")
                ownership = .reused
                state = .running
                startHealthMonitor()
            } else {
                launchProcess()
            }
        }
    }

    func stop() {
        requestStop(startAfterStop: false)
    }

    func restart() {
        requestStop(startAfterStop: true)
    }

    func prepareForAppTermination() {
        monitorTask?.cancel()
        monitorTask = nil
        stopTask?.cancel()
        stopTask = nil
    }

    private func requestStop(startAfterStop: Bool) {
        monitorTask?.cancel()
        monitorTask = nil
        stopTask?.cancel()

        let stopOwnership = ownership
        let managedProcess = process

        state = .stopping
        ownership = .none
        restartCount = 0
        process = nil

        if let managedProcess, managedProcess.isRunning {
            managedProcess.terminationHandler = nil
            managedProcess.terminate()
            appLog("GatewayProcessManager: requested terminate for managed pid=\(managedProcess.processIdentifier)")
        }

        stopTask = Task { [gatewayPort] in
            let (stopped, message) = await Self.stopGateway(
                onPort: gatewayPort,
                ownership: stopOwnership,
                managedPID: managedProcess?.processIdentifier
            )
            await MainActor.run {
                self.stopTask = nil
                guard !Task.isCancelled else { return }
                if stopped {
                    if startAfterStop {
                        self.start()
                    } else {
                        self.state = .stopped
                    }
                    return
                }
                self.state = .failed(message ?? "Gateway 停止失败")
            }
        }
    }

    // MARK: - 内部

    private func launchProcess() {
        let nodeURL = Self.bundledNodeURL
        let openclawEntry = Self.bundledOpenClawEntry

        guard FileManager.default.fileExists(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: openclawEntry.path) else {
            state = .failed("Bundled Node.js 或 OpenClaw 不存在")
            appLog("GatewayProcessManager: bundled binaries not found", level: .error)
            return
        }

        let proc = Process()
        proc.executableURL = nodeURL
        proc.arguments = [openclawEntry.path, "gateway"]
        proc.environment = Self.buildEnvironment()
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.handleTermination(exitCode: p.terminationStatus)
            }
        }

        do {
            try proc.run()
            self.process = proc
            self.ownership = .managed
            appLog("GatewayProcessManager: launched pid=\(proc.processIdentifier)")
            startHealthMonitor()
        } catch {
            state = .failed(error.localizedDescription)
            ownership = .none
            appLog("GatewayProcessManager: launch failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func handleTermination(exitCode: Int32) {
        process = nil
        guard state != .stopped else { return }

        if restartCount < maxAutoRestarts {
            restartCount += 1
            let delay = min(Double(restartCount) * 2, 10)
            appLog("GatewayProcessManager: exited(\(exitCode)), auto-restart #\(restartCount) in \(delay)s")
            state = .starting
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard state == .starting else { return }
                launchProcess()
            }
        } else {
            ownership = .none
            state = .failed("进程多次异常退出 (exit \(exitCode))")
            appLog("GatewayProcessManager: max restarts reached", level: .error)
        }
    }

    private func startHealthMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self, port = gatewayPort] in
            // 启动后等待 gateway 就绪
            var didBecomeReady = false
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let (_, ready) = await GatewayClient.httpProbe(port: port)
                if ready {
                    didBecomeReady = true
                    await MainActor.run { self?.state = .running }
                    break
                }
            }
            if !didBecomeReady {
                await MainActor.run {
                    guard let self else { return }
                    if self.state == .starting {
                        self.state = .failed("Gateway 启动超时")
                        self.ownership = .none
                        if let proc = self.process, proc.isRunning {
                            proc.terminationHandler = nil
                            proc.terminate()
                            self.process = nil
                        }
                    }
                }
                return
            }
            // 持续探活
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { return }
                let (alive, _) = await GatewayClient.httpProbe(port: port)
                if !alive {
                    await MainActor.run {
                        if self?.state == .running { self?.state = .starting }
                    }
                }
            }
        }
    }

    private static func stopGateway(
        onPort port: Int,
        ownership: Ownership,
        managedPID: Int32?
    ) async -> (Bool, String?) {
        let initialStopWindow: UInt64 = ownership == .managed ? 4_000_000_000 : 2_000_000_000
        if await waitForGatewayStopped(onPort: port, timeoutNanoseconds: initialStopWindow) {
            return (true, nil)
        }

        guard let pid = gatewayPIDListening(onPort: port) else {
            return (true, nil)
        }

        guard let cmdline = processCommandLine(pid: pid), looksLikeGatewayProcess(cmdline: cmdline) else {
            let message = "端口 \(port) 当前由非 OpenClaw Gateway 进程占用，已拒绝停止"
            appLog("GatewayProcessManager: refuse stopping pid=\(pid) on port \(port)", level: .error)
            return (false, message)
        }

        if kill(pid, SIGTERM) != 0 {
            let message = "向 Gateway 进程发送 SIGTERM 失败 (pid \(pid))"
            appLog("GatewayProcessManager: SIGTERM failed pid=\(pid) errno=\(errno)", level: .error)
            return (false, message)
        }
        let managedPIDText = managedPID.map { String($0) } ?? "nil"
        appLog("GatewayProcessManager: sent SIGTERM to pid=\(pid) ownership=\(String(describing: ownership)) managedPID=\(managedPIDText)")

        if await waitForGatewayStopped(onPort: port, timeoutNanoseconds: 4_000_000_000) {
            return (true, nil)
        }

        if kill(pid, SIGKILL) != 0 {
            let message = "Gateway 进程未响应 SIGTERM，且 SIGKILL 失败 (pid \(pid))"
            appLog("GatewayProcessManager: SIGKILL failed pid=\(pid) errno=\(errno)", level: .error)
            return (false, message)
        }
        appLog("GatewayProcessManager: escalated to SIGKILL for pid=\(pid)")

        if await waitForGatewayStopped(onPort: port, timeoutNanoseconds: 2_000_000_000) {
            return (true, nil)
        }

        return (false, "Gateway 停止后端口 \(port) 仍然存活")
    }

    private static func waitForGatewayStopped(
        onPort port: Int,
        timeoutNanoseconds: UInt64
    ) async -> Bool {
        let interval: UInt64 = 250_000_000
        let attempts = max(1, Int(timeoutNanoseconds / interval))
        for _ in 0..<attempts {
            let (alive, _) = await GatewayClient.httpProbe(port: port)
            if !alive, gatewayPIDListening(onPort: port) == nil {
                return true
            }
            try? await Task.sleep(nanoseconds: interval)
        }
        return false
    }

    private static func gatewayPIDListening(onPort port: Int) -> Int32? {
        let output = runLocalCommand(
            "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN", "-nP"]
        )
        return output?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first(where: { $0 > 0 })
    }

    private static func processCommandLine(pid: Int32) -> String? {
        runLocalCommand("/bin/ps", arguments: ["-o", "command=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeGatewayProcess(cmdline: String) -> Bool {
        if GatewayProcessCommandMatcher.isGatewayCommand(cmdline) {
            return true
        }

        let normalized = cmdline.lowercased()
        return normalized.contains("openclaw") && normalized.contains("gateway")
    }

    private static func runLocalCommand(_ executable: String, arguments: [String]) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()

        do {
            try proc.run()
        } catch {
            appLog("GatewayProcessManager: command failed \(executable) \(arguments.joined(separator: " ")): \(error.localizedDescription)", level: .error)
            return nil
        }

        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - 路径

    /// Node.js 可执行路径（Debug 优先开发目录，回退 App Resources）
    static var bundledNodeURL: URL {
        runtimeRootURL
            .appendingPathComponent("node/bin/node")
    }

    /// OpenClaw 入口（Debug 优先开发目录，回退 App Resources）
    static var bundledOpenClawEntry: URL {
        runtimeRootURL
            .appendingPathComponent("openclaw/lib/node_modules/openclaw/openclaw.mjs")
    }

    /// npx 路径（用于渠道绑定等）
    static var bundledNpxURL: URL {
        runtimeRootURL
            .appendingPathComponent("node/bin/npx")
    }

    /// OpenClaw 用户配置目录
    static var openClawConfigDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".openclaw")
    }

    static func buildEnvironment() -> [String: String] {
        let home = NSHomeDirectory()
        let nodeBin = bundledNodeURL.deletingLastPathComponent().path
        let openclawBin = runtimeRootURL
            .appendingPathComponent("openclaw/bin").path
        let npmGlobalBin = "\(home)/.npm-global/bin"
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
        return [
            "HOME": home,
            "PATH": "\(nodeBin):\(openclawBin):\(npmGlobalBin):\(existingPath)",
            "NODE_ENV": "production",
        ]
    }

    /// 运行时根目录：
    /// - Debug: 优先 `CLAWDHOME_DEV_RUNTIME_DIR`，其次 `<repo>/build/dev-runtime`
    /// - 其它构建：使用 App bundle Resources
    private static var runtimeRootURL: URL {
        #if DEBUG
        if let custom = ProcessInfo.processInfo.environment["CLAWDHOME_DEV_RUNTIME_DIR"],
           !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        if let repoRoot = debugRepoRootURL {
            return repoRoot.appendingPathComponent("build/dev-runtime", isDirectory: true)
        }
        #endif
        return Bundle.main.resourceURL!
    }

    // MARK: - 本地命令执行

    /// 在 app 进程内直接执行 openclaw 子命令（如 pairing approve），
    /// 避免走 helper daemon 的 sudo -u 导致 TCC EPERM。
    /// 返回 (success, output)
    static func runOpenclawLocally(args: [String]) async -> (Bool, String) {
        let nodeURL = bundledNodeURL
        let entry = bundledOpenClawEntry

        guard FileManager.default.fileExists(atPath: nodeURL.path),
              FileManager.default.fileExists(atPath: entry.path) else {
            return (false, "Bundled Node.js 或 OpenClaw 不存在")
        }

        let proc = Process()
        proc.executableURL = nodeURL
        proc.arguments = [entry.path] + args
        proc.environment = buildEnvironment()
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        do {
            try proc.run()
        } catch {
            return (false, error.localizedDescription)
        }

        return await withCheckedContinuation { continuation in
            proc.terminationHandler = { p in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (p.terminationStatus == 0, output))
            }
        }
    }

    /// 创建智能体（CLI 主路径）：`openclaw agents add <id>`
    /// - Returns: (success, output)
    static func addAgentLocally(agentId: String) async -> (Bool, String) {
        let trimmedId = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            return (false, "agentId 不能为空")
        }
        let workspace = ".openclaw/workspace-\(trimmedId)"
        let agentDir = ".openclaw/agents/\(trimmedId)/agent"
        return await runOpenclawLocally(args: [
            "agents", "add", trimmedId,
            "--non-interactive",
            "--workspace", workspace,
            "--agent-dir", agentDir,
            "--json"
        ])
    }

    #if DEBUG
    /// 通过源码绝对路径推导仓库根目录（.../clawdhome）
    private static var debugRepoRootURL: URL? {
        let sourceURL = URL(fileURLWithPath: #filePath)
        // GatewayProcessManager.swift -> Gateway -> Services -> ClawdHome -> repoRoot
        return sourceURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
    #endif
}
