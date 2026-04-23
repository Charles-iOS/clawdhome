import Darwin
import Foundation
import Observation
import os.log

@MainActor
@Observable
final class SupervisorClient {
    private var connection: NSXPCConnection?
    private(set) var isConnected = false
    private(set) var runtimes: [SupervisorProfileRuntime] = []

    private static let xpcTimeout: Duration = .seconds(20)
    private static let profilePrepareTimeout: Duration = .seconds(30)
    private static let profileStopTimeout: Duration = .seconds(30)
    private static let profileStartTimeout: Duration = .seconds(300)
    private static let pingTimeoutNanoseconds: UInt64 = 1_000_000_000

    func connect() {
        connection?.invalidate()
        let connection = NSXPCConnection(machServiceName: EZRWorkerBranding.supervisorMachServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: EZRWorkerSupervisorProtocol.self)
        connection.invalidationHandler = { [weak self] in
            os_log(.error, "[SupervisorClient] connection invalidated")
            DispatchQueue.main.async {
                self?.isConnected = false
            }
        }
        connection.interruptionHandler = { [weak self] in
            os_log(.info, "[SupervisorClient] connection interrupted")
            DispatchQueue.main.async {
                self?.isConnected = false
            }
        }
        connection.resume()
        self.connection = connection
    }

    func disconnect() {
        connection?.invalidate()
        connection = nil
        isConnected = false
    }

    @discardableResult
    func waitUntilConnected(
        timeoutNanoseconds: UInt64 = 15_000_000_000,
        pollIntervalNanoseconds: UInt64 = 250_000_000
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        var attemptedBootstrap = false

        if Self.shouldRefreshEmbeddedSupervisor() {
            attemptedBootstrap = true
            await bootstrapEmbeddedSupervisorIfNeeded()
        }

        while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
            if await ping() {
                return true
            }

            if !attemptedBootstrap {
                attemptedBootstrap = true
                await bootstrapEmbeddedSupervisorIfNeeded()
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        return false
    }

    func ping() async -> Bool {
        guard let connection else { return false }
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var resumed = false

            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                DispatchQueue.main.async {
                    self.isConnected = value
                }
                continuation.resume(returning: value)
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                os_log(.error, "[SupervisorClient] ping proxy error: %{public}@", error.localizedDescription)
                resumeOnce(false)
            } as? any EZRWorkerSupervisorProtocol

            guard let proxy else {
                resumeOnce(false)
                return
            }

            DispatchQueue.global(qos: .utility).asyncAfter(
                deadline: .now() + .nanoseconds(Int(Self.pingTimeoutNanoseconds))
            ) {
                resumeOnce(false)
            }

            proxy.ping { payload in
                resumeOnce(payload == "pong")
            }
        }
    }

    func listProfilesRuntime() async throws -> [SupervisorProfileRuntime] {
        let payload: String = try await request(
            operationName: "listProfilesRuntime",
            timeout: Self.xpcTimeout
        ) { proxy, done in
            proxy.listProfilesRuntime { json in
                done(json)
            }
        }
        let decoded = try SupervisorJSONCodec.decode([SupervisorProfileRuntime].self, from: payload)
        runtimes = decoded
        isConnected = true
        return decoded
    }

    @discardableResult
    func refreshRuntimes() async -> [SupervisorProfileRuntime] {
        (try? await listProfilesRuntime()) ?? []
    }

    func prepareProfile(profileID: UUID) async throws {
        try await runLifecycleOperation(
            "prepareProfile",
            profileID: profileID,
            timeout: Self.profilePrepareTimeout
        ) { proxy, done in
            proxy.prepareProfile(profileID: profileID.uuidString, withReply: done)
        }
    }

    func startProfile(profileID: UUID) async throws {
        try await runLifecycleOperation(
            "startProfile",
            profileID: profileID,
            timeout: Self.profileStartTimeout
        ) { proxy, done in
            proxy.startProfile(profileID: profileID.uuidString, withReply: done)
        }
    }

    func stopProfile(profileID: UUID) async throws {
        try await runLifecycleOperation(
            "stopProfile",
            profileID: profileID,
            timeout: Self.profileStopTimeout
        ) { proxy, done in
            proxy.stopProfile(profileID: profileID.uuidString, withReply: done)
        }
    }

    func restartProfile(profileID: UUID) async throws {
        try await runLifecycleOperation(
            "restartProfile",
            profileID: profileID,
            timeout: Self.profileStartTimeout
        ) { proxy, done in
            proxy.restartProfile(profileID: profileID.uuidString, withReply: done)
        }
    }

    @discardableResult
    func reloadProfiles() async -> Bool {
        do {
            let (ok, _): (Bool, String?) = try await request(
                operationName: "reloadProfiles",
                timeout: Self.xpcTimeout
            ) { proxy, done in
                proxy.reloadProfiles { ok, message in
                    done((ok, message))
                }
            }
            if ok {
                _ = await refreshRuntimes()
            }
            return ok
        } catch {
            return false
        }
    }

    private func runLifecycleOperation(
        _ name: String,
        profileID: UUID,
        timeout: Duration,
        operation: @escaping ((any EZRWorkerSupervisorProtocol, @escaping (Bool, String?) -> Void) -> Void)
    ) async throws {
        let operationName = "\(name)(\(profileID.uuidString))"
        let (ok, message): (Bool, String?) = try await request(
            operationName: operationName,
            timeout: timeout
        ) { proxy, done in
            operation(proxy) { ok, message in
                done((ok, message))
            }
        }
        guard ok else {
            throw SupervisorClientError.operationFailed(
                "\(operationName): \(message ?? "未知错误")"
            )
        }
        _ = await refreshRuntimes()
    }

    private func request<T>(
        operationName: String,
        timeout: Duration,
        operation: @escaping ((any EZRWorkerSupervisorProtocol, @escaping (T) -> Void) -> Void)
    ) async throws -> T {
        guard let connection else {
            throw SupervisorClientError.notConnected
        }

        return try await withUnsafeThrowingContinuation { (continuation: UnsafeContinuation<T, Error>) in
            let lock = NSLock()
            var resumed = false

            func resumeOnce(with result: Result<T, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }

            let proxy = connection.remoteObjectProxyWithErrorHandler { [weak self] error in
                os_log(
                    .error,
                    "[SupervisorClient] %{public}@ proxy error: %{public}@",
                    operationName,
                    error.localizedDescription
                )
                DispatchQueue.main.async {
                    self?.isConnected = false
                }
                resumeOnce(
                    with: .failure(
                        SupervisorClientError.operationFailed(
                            "\(operationName): \(error.localizedDescription)"
                        )
                    )
                )
            } as? any EZRWorkerSupervisorProtocol

            guard let proxy else {
                resumeOnce(with: .failure(SupervisorClientError.notConnected))
                return
            }

            let timeoutSeconds = max(1, Int(timeout.components.seconds))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(timeoutSeconds)) {
                resumeOnce(
                    with: .failure(
                        SupervisorClientError.operationFailed(
                            "\(operationName) 超时（\(timeoutSeconds)s）"
                        )
                    )
                )
            }

            operation(proxy) { value in
                DispatchQueue.main.async {
                    self.isConnected = true
                }
                resumeOnce(with: .success(value))
            }
        }
    }

    private func bootstrapEmbeddedSupervisorIfNeeded() async {
        guard let context = Self.runtimeLaunchAgentContext() else {
            os_log(.error, "[SupervisorClient] failed to prepare runtime supervisor launch agent")
            return
        }

        _ = await Self.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", context.serviceTarget]
        )

        let bootstrap = await Self.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootstrap", context.domain, context.plistURL.path]
        )
        if bootstrap.exitCode != 0,
           !bootstrap.output.localizedCaseInsensitiveContains("service already loaded") {
            os_log(
                .error,
                "[SupervisorClient] bootstrap failed (%{public}d): %{public}@",
                bootstrap.exitCode,
                bootstrap.output
            )
            return
        }

        _ = await Self.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["enable", context.serviceTarget]
        )
        let kickstart = await Self.runProcess(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["kickstart", "-k", context.serviceTarget]
        )
        if kickstart.exitCode != 0 {
            os_log(
                .error,
                "[SupervisorClient] kickstart failed (%{public}d): %{public}@",
                kickstart.exitCode,
                kickstart.output
            )
            return
        }

        os_log(.info, "[SupervisorClient] bootstrapped supervisor from %{public}@", context.plistURL.path)
        connect()
    }

    private static var shouldAlwaysRefreshEmbeddedSupervisor: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    private static func shouldRefreshEmbeddedSupervisor() -> Bool {
        guard let current = currentEmbeddedSupervisorFingerprint() else {
            return false
        }
        if shouldAlwaysRefreshEmbeddedSupervisor {
            return true
        }
        guard let installed = installedEmbeddedSupervisorFingerprint() else {
            return true
        }
        return installed.executablePath != current.executablePath
            || installed.versionStamp != current.versionStamp
    }

    private static func currentEmbeddedSupervisorFingerprint() -> EmbeddedSupervisorFingerprint? {
        let executableURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent("EZRWorkerSupervisor")
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        return EmbeddedSupervisorFingerprint(
            executablePath: executableURL.path,
            versionStamp: embeddedSupervisorVersionStamp()
        )
    }

    private static func installedEmbeddedSupervisorFingerprint() -> EmbeddedSupervisorFingerprint? {
        let plistURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(EZRWorkerBranding.supervisorLaunchAgentLabel).plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        let executablePath = (plist["ProgramArguments"] as? [String])?.first
        let environment = plist["EnvironmentVariables"] as? [String: Any]
        let versionStamp = environment?["EZRWORKER_SUPERVISOR_VERSION"] as? String
        guard let executablePath, !executablePath.isEmpty else {
            return nil
        }

        return EmbeddedSupervisorFingerprint(
            executablePath: executablePath,
            versionStamp: versionStamp
        )
    }

    private static func embeddedSupervisorVersionStamp() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let shortVersion = info["CFBundleShortVersionString"] as? String ?? "0"
        let buildVersion = info["CFBundleVersion"] as? String ?? "0"
        return "\(shortVersion) (\(buildVersion))"
    }

    private static func runtimeLaunchAgentContext() -> EmbeddedLaunchAgentContext? {
        guard let fingerprint = currentEmbeddedSupervisorFingerprint() else {
            return nil
        }
        let executableURL = URL(fileURLWithPath: fingerprint.executablePath)

        let launchAgentsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: launchAgentsDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o755]
            )
        } catch {
            os_log(
                .error,
                "[SupervisorClient] failed to create launch agents directory %{public}@: %{public}@",
                launchAgentsDirectory.path,
                error.localizedDescription
            )
            return nil
        }

        let plistURL = launchAgentsDirectory
            .appendingPathComponent("\(EZRWorkerBranding.supervisorLaunchAgentLabel).plist")
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(EZRWorkerBranding.supervisorLaunchAgentLabel)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(executableURL.path)</string>
            </array>
            <key>EnvironmentVariables</key>
            <dict>
                <key>EZRWORKER_SUPERVISOR_VERSION</key>
                <string>\(fingerprint.versionStamp ?? embeddedSupervisorVersionStamp())</string>
            </dict>
            <key>MachServices</key>
            <dict>
                <key>\(EZRWorkerBranding.supervisorMachServiceName)</key>
                <true/>
            </dict>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>ProcessType</key>
            <string>Background</string>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
        </dict>
        </plist>
        """
        do {
            try plist.write(to: plistURL, atomically: true, encoding: .utf8)
        } catch {
            os_log(
                .error,
                "[SupervisorClient] failed to write runtime launch agent %{public}@: %{public}@",
                plistURL.path,
                error.localizedDescription
            )
            return nil
        }

        let uid = getuid()
        let domain = "gui/\(uid)"
        let serviceTarget = "\(domain)/\(EZRWorkerBranding.supervisorLaunchAgentLabel)"
        return EmbeddedLaunchAgentContext(
            plistURL: plistURL,
            domain: domain,
            serviceTarget: serviceTarget
        )
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async -> ProcessResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr

                do {
                    try process.run()
                    process.waitUntilExit()

                    let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
                        + stderr.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: outputData, encoding: .utf8) ?? ""
                    continuation.resume(
                        returning: ProcessResult(
                            exitCode: process.terminationStatus,
                            output: output.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    )
                } catch {
                    continuation.resume(
                        returning: ProcessResult(
                            exitCode: -1,
                            output: error.localizedDescription
                        )
                    )
                }
            }
        }
    }
}

enum SupervisorClientError: LocalizedError {
    case notConnected
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "EZRWorkerSupervisor 未连接"
        case .operationFailed(let message):
            return message
        }
    }
}

private struct EmbeddedLaunchAgentContext {
    let plistURL: URL
    let domain: String
    let serviceTarget: String
}

private struct EmbeddedSupervisorFingerprint {
    let executablePath: String
    let versionStamp: String?
}

private struct ProcessResult {
    let exitCode: Int32
    let output: String
}
