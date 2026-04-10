// ClawdHome/Services/Gateway/GatewayProcessManager.swift
// 管理本地 OpenClaw Gateway 进程的生命周期

import Foundation
import Observation

@MainActor @Observable
final class GatewayProcessManager {

    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    private(set) var state: State = .stopped
    private(set) var gatewayPort: Int = 18789

    var isRunning: Bool { state == .running }

    private var process: Process?
    private var monitorTask: Task<Void, Never>?
    private var restartCount = 0
    private let maxAutoRestarts = 5

    // MARK: - 生命周期

    func start() {
        guard state != .starting, process == nil else { return }
        state = .starting
        restartCount = 0

        // 先检测是否已有 gateway 实例在运行（如 LaunchAgent 拉起的）
        Task {
            let (_, ready) = await GatewayClient.httpProbe(port: gatewayPort)
            if ready {
                appLog("GatewayProcessManager: existing gateway detected on port \(gatewayPort), reusing")
                state = .running
                startHealthMonitor()
            } else {
                launchProcess()
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        monitorTask = nil
        terminateProcess()
        state = .stopped
        restartCount = 0
    }

    func restart() {
        stop()
        start()
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
            appLog("GatewayProcessManager: launched pid=\(proc.processIdentifier)")
            startHealthMonitor()
        } catch {
            state = .failed(error.localizedDescription)
            appLog("GatewayProcessManager: launch failed: \(error.localizedDescription)", level: .error)
        }
    }

    private func terminateProcess() {
        guard let proc = process, proc.isRunning else {
            process = nil
            return
        }
        proc.terminate()
        process = nil
        appLog("GatewayProcessManager: terminated")
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
            state = .failed("进程多次异常退出 (exit \(exitCode))")
            appLog("GatewayProcessManager: max restarts reached", level: .error)
        }
    }

    private func startHealthMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self, port = gatewayPort] in
            // 启动后等待 gateway 就绪
            for _ in 0..<30 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let (_, ready) = await GatewayClient.httpProbe(port: port)
                if ready {
                    await MainActor.run { self?.state = .running }
                    break
                }
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
