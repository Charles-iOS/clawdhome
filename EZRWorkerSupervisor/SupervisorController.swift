import Darwin
import Foundation
import Security

final class SupervisorRecord {
    var profile: GatewayProfile
    var resolution: GatewayProfileResolution
    var process: Process?
    var isPrepared = false
    var isRunning = false
    var pid: Int32?
    var readyState: SupervisorReadyState = .stopped
    var ownership: SupervisorOwnership = .none
    var lastProbeAt: Date?
    var lastError: String?

    init(profile: GatewayProfile) {
        self.profile = profile
        self.resolution = GatewayProfileResolver.resolve(profile)
    }

    func apply(profile: GatewayProfile) {
        self.profile = profile
        self.resolution = GatewayProfileResolver.resolve(profile)
    }

    func snapshot() -> SupervisorProfileRuntime {
        SupervisorProfileRuntime(
            profileID: profile.id,
            slug: profile.slug,
            displayName: profile.displayName,
            resolvedConfigPath: resolution.resolvedConfigPath,
            resolvedStateDir: resolution.resolvedStateDir,
            resolvedWorkspaceRoot: resolution.resolvedWorkspaceRoot,
            resolvedPort: resolution.resolvedPort,
            isPrepared: isPrepared,
            isRunning: isRunning,
            pid: pid,
            readyState: readyState,
            ownership: ownership,
            lastProbeAt: lastProbeAt,
            lastError: lastError
        )
    }
}

actor EZRWorkerSupervisorController {
    private static let gatewayStartupProbeAttempts = 90
    private static let gatewayStartupProbeIntervalNanoseconds: UInt64 = 1_000_000_000

    private var profiles: [UUID: GatewayProfile] = [:]
    private var profileOrder: [UUID] = []
    private var records: [UUID: SupervisorRecord] = [:]
    private var inFlightStartTasks: [UUID: Task<(Bool, String?), Never>] = [:]
    private var isReconcilingAutoStart = false
    private var needsAutoStartReconcile = false

    init() {
        guard let document = Self.readProfilesDocumentFromDisk() else { return }
        let orderedProfiles = Self.sortedProfiles(from: document)
        profiles = Dictionary(uniqueKeysWithValues: orderedProfiles.map { ($0.id, $0) })
        profileOrder = orderedProfiles.map(\.id)
        for profile in orderedProfiles {
            records[profile.id] = SupervisorRecord(profile: profile)
        }
    }

    func ping() -> String {
        "pong"
    }

    func listProfilesRuntimeJSON() -> String {
        let snapshots = profileOrder.compactMap { profileID -> SupervisorProfileRuntime? in
            if let record = records[profileID] {
                return record.snapshot()
            }
            guard let profile = profiles[profileID] else { return nil }
            return SupervisorRecord(profile: profile).snapshot()
        }
        return SupervisorJSONCodec.encode(snapshots)
    }

    func reloadProfiles() async -> (Bool, String?) {
        loadProfilesFromDisk()
        return (true, nil)
    }

    func prepareProfile(profileID: UUID) async -> (Bool, String?) {
        guard let profile = profiles[profileID] else {
            return (false, "未找到 profile: \(profileID.uuidString)")
        }

        let record = recordForProfile(profile)
        record.readyState = .preparing
        record.lastError = nil

        do {
            try ensureProfileDirectories(record.resolution)

            if profile.sourceKind == .legacyReuse {
                guard FileManager.default.fileExists(atPath: record.resolution.resolvedConfigPath) else {
                    throw NSError(domain: "EZRWorkerSupervisor", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "legacy profile 缺少 openclaw.json"
                    ])
                }
            } else {
                let (ok, output) = await OpenClawRuntime.runOpenClaw(
                    arguments: ["setup", "--workspace", record.resolution.resolvedWorkspaceRoot],
                    profile: record.resolution
                )
                guard ok else {
                    throw NSError(domain: "EZRWorkerSupervisor", code: 10, userInfo: [
                        NSLocalizedDescriptionKey: output.isEmpty ? "openclaw setup 失败" : output
                    ])
                }
            }

            try normalizeConfig(for: record.resolution)

            record.isPrepared = true
            record.readyState = record.isRunning ? .ready : .stopped
            return (true, nil)
        } catch {
            record.isPrepared = false
            record.readyState = .failed
            record.lastError = error.localizedDescription
            return (false, error.localizedDescription)
        }
    }

    func startProfile(profileID: UUID) async -> (Bool, String?) {
        if let existing = inFlightStartTasks[profileID] {
            return await existing.value
        }

        let task = Task { [self] in
            await performStartProfile(profileID: profileID)
        }
        inFlightStartTasks[profileID] = task

        let result = await task.value
        inFlightStartTasks.removeValue(forKey: profileID)
        return result
    }

    private func performStartProfile(profileID: UUID) async -> (Bool, String?) {
        let prepareResult = await prepareProfile(profileID: profileID)
        guard prepareResult.0 else { return prepareResult }
        guard let record = records[profileID] else {
            return (false, "缺少运行时记录")
        }

        if let process = record.process, process.isRunning {
            record.isRunning = true
            record.pid = process.processIdentifier
            record.readyState = .ready
            record.ownership = .supervised
            return (true, nil)
        }

        let currentProbe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        if currentProbe.ready {
            let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            switch await existingGatewayDisposition(for: record, listeningPID: currentPID) {
            case .adopt(let pid):
                record.isRunning = true
                record.readyState = .ready
                record.ownership = .adopted
                record.pid = pid
                record.lastProbeAt = Date()
                return (true, nil)
            case .relaunch:
                break
            case .fail(let message):
                record.lastError = message
                record.readyState = .failed
                record.isRunning = false
                record.ownership = .none
                return (false, message)
            }
        }

        if let occupiedPID = gatewayPIDListening(onPort: record.resolution.resolvedPort),
           let commandLine = processCommandLine(pid: occupiedPID),
           !looksLikeGatewayProcess(commandLine) {
            let message = "端口 \(record.resolution.resolvedPort) 已被其他进程占用"
            record.lastError = message
            record.readyState = .failed
            return (false, message)
        }

        let process = Process()
        process.executableURL = OpenClawRuntime.bundledNodeURL
        process.arguments = [OpenClawRuntime.bundledOpenClawEntry.path, "gateway"]
        process.environment = OpenClawRuntime.buildEnvironment(profile: record.resolution)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let controller = self
        let recordID = profileID
        process.terminationHandler = { terminated in
            Task {
                await controller.handleProcessTermination(
                    profileID: recordID,
                    exitCode: terminated.terminationStatus
                )
            }
        }

        do {
            try process.run()
            record.process = process
            record.pid = process.processIdentifier
            record.isRunning = true
            record.readyState = .starting
            record.ownership = .supervised
            record.lastError = nil
        } catch {
            record.lastError = error.localizedDescription
            record.readyState = .failed
            record.isRunning = false
            record.ownership = .none
            return (false, error.localizedDescription)
        }

        for _ in 0..<Self.gatewayStartupProbeAttempts {
            if let process = record.process, !process.isRunning {
                let message = record.lastError ?? "Gateway 异常退出"
                record.readyState = .failed
                record.isRunning = false
                return (false, message)
            }

            let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
            record.lastProbeAt = Date()
            if probe.ready {
                record.readyState = .ready
                record.isRunning = true
                return (true, nil)
            }
            try? await Task.sleep(nanoseconds: Self.gatewayStartupProbeIntervalNanoseconds)
        }

        _ = await stopProfile(profileID: profileID)
        let message = "Gateway 启动超时（\(Self.gatewayStartupProbeAttempts)s）"
        record.lastError = message
        record.readyState = .failed
        return (false, message)
    }

    func stopProfile(profileID: UUID) async -> (Bool, String?) {
        guard let record = records[profileID] else {
            return (true, nil)
        }

        if let process = record.process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            for _ in 0..<20 {
                if !process.isRunning {
                    break
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        } else if let pid = gatewayPIDListening(onPort: record.resolution.resolvedPort),
                  let commandLine = processCommandLine(pid: pid),
                  looksLikeGatewayProcess(commandLine) {
            kill(pid, SIGTERM)
            for _ in 0..<12 {
                if gatewayPIDListening(onPort: record.resolution.resolvedPort) == nil {
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            if gatewayPIDListening(onPort: record.resolution.resolvedPort) != nil {
                kill(pid, SIGKILL)
            }
        }

        record.process = nil
        record.pid = nil
        record.isRunning = false
        record.ownership = .none
        record.readyState = .stopped
        record.lastProbeAt = Date()
        return (true, nil)
    }

    func restartProfile(profileID: UUID) async -> (Bool, String?) {
        let stopResult = await stopProfile(profileID: profileID)
        guard stopResult.0 else { return stopResult }
        return await startProfile(profileID: profileID)
    }

    func reconcileLaunchState() async {
        loadProfilesFromDisk()
        scheduleAutoStartReconcile()
    }

    private func scheduleAutoStartReconcile() {
        needsAutoStartReconcile = true
        guard !isReconcilingAutoStart else { return }

        Task {
            await self.processPendingAutoStartReconcile()
        }
    }

    private func processPendingAutoStartReconcile() async {
        guard !isReconcilingAutoStart else { return }
        isReconcilingAutoStart = true
        defer { isReconcilingAutoStart = false }

        while needsAutoStartReconcile {
            needsAutoStartReconcile = false
            await reconcileAutoStartProfiles()
        }
    }

    private func reconcileAutoStartProfiles() async {
        for profileID in profileOrder {
            guard let profile = profiles[profileID], profile.autoStart else { continue }
            _ = await startProfile(profileID: profileID)
        }
    }

    private func loadProfilesFromDisk() {
        guard let document = Self.readProfilesDocumentFromDisk() else {
            profiles = [:]
            profileOrder = []
            return
        }

        let orderedProfiles = Self.sortedProfiles(from: document)
        profiles = Dictionary(uniqueKeysWithValues: orderedProfiles.map { ($0.id, $0) })
        profileOrder = orderedProfiles.map(\.id)

        for profile in orderedProfiles {
            let record = records[profile.id] ?? SupervisorRecord(profile: profile)
            record.apply(profile: profile)
            records[profile.id] = record
        }

        let knownIDs = Set(orderedProfiles.map(\.id))
        for recordID in Array(records.keys) where !knownIDs.contains(recordID) {
            records.removeValue(forKey: recordID)
        }
    }

    private static func readProfilesDocumentFromDisk() -> GatewayProfilesDocument? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: EZRWorkerPaths.profilesDocumentURL),
              let document = try? decoder.decode(GatewayProfilesDocument.self, from: data)
        else {
            return nil
        }
        return document
    }

    private static func sortedProfiles(from document: GatewayProfilesDocument) -> [GatewayProfile] {
        document.profiles.sorted(by: { $0.createdAt < $1.createdAt })
    }

    private func recordForProfile(_ profile: GatewayProfile) -> SupervisorRecord {
        if let existing = records[profile.id] {
            existing.apply(profile: profile)
            return existing
        }
        let created = SupervisorRecord(profile: profile)
        records[profile.id] = created
        return created
    }

    private func handleProcessTermination(profileID: UUID, exitCode: Int32) {
        guard let record = records[profileID] else { return }
        record.process = nil
        record.pid = nil
        record.isRunning = false
        record.ownership = .none
        if record.readyState != .stopped {
            record.readyState = .failed
            record.lastError = "Gateway 异常退出 (exit \(exitCode))"
        }
        record.lastProbeAt = Date()
    }

    private func ensureProfileDirectories(_ resolution: GatewayProfileResolution) throws {
        let fm = FileManager.default
        let directories = [
            resolution.configURL.deletingLastPathComponent(),
            resolution.stateDirURL,
            resolution.workspaceRootURL,
            resolution.stateDirURL.appendingPathComponent("agents", isDirectory: true),
        ]
        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    private func normalizeConfig(for resolution: GatewayProfileResolution) throws {
        let url = resolution.configURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        var gateway = root["gateway"] as? [String: Any] ?? [:]
        gateway["port"] = resolution.resolvedPort
        gateway["mode"] = "local"

        var controlUI = gateway["controlUi"] as? [String: Any] ?? [:]
        controlUI["allowInsecureAuth"] = true
        gateway["controlUi"] = controlUI

        if resolution.sourceKind == .managed {
            var auth = gateway["auth"] as? [String: Any] ?? [:]
            auth["mode"] = "token"
            let existingToken = (auth["token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if existingToken?.isEmpty != false {
                auth["token"] = generateGatewayToken()
            }
            gateway["auth"] = auth

            var agents = root["agents"] as? [String: Any] ?? [:]
            var defaults = agents["defaults"] as? [String: Any] ?? [:]
            defaults["workspace"] = resolution.resolvedWorkspaceRoot
            agents["defaults"] = defaults
            root["agents"] = agents
        }

        root["gateway"] = gateway

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func generateGatewayToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
    }

    private func configToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.isEmpty
        else {
            return nil
        }
        return token
    }

    private func existingGatewayDisposition(
        for record: SupervisorRecord,
        listeningPID: Int32?
    ) async -> ExistingGatewayDisposition {
        guard record.profile.sourceKind == .managed else {
            return .adopt(listeningPID)
        }

        guard let listeningPID else {
            return .adopt(nil)
        }

        let ownedByRecord =
            (record.process?.isRunning == true && record.process?.processIdentifier == listeningPID)
            || record.pid == listeningPID
        if ownedByRecord {
            return .adopt(listeningPID)
        }

        guard let commandLine = processCommandLine(pid: listeningPID) else {
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
        }
        guard looksLikeGatewayProcess(commandLine) else {
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
        }

        clearRuntimeStateForGateway(
            pid: listeningPID,
            port: record.resolution.resolvedPort,
            excluding: record.profile.id
        )

        if await terminateGatewayProcess(pid: listeningPID, port: record.resolution.resolvedPort) {
            return .relaunch
        }

        return .fail("端口 \(record.resolution.resolvedPort) 上存在无法接管的旧 Gateway 进程")
    }

    private func clearRuntimeStateForGateway(pid: Int32, port: Int, excluding profileID: UUID) {
        for (recordID, candidate) in records where recordID != profileID {
            let samePID = candidate.pid == pid
            let samePort = candidate.resolution.resolvedPort == port
            guard samePID || samePort else { continue }
            candidate.process = nil
            candidate.pid = nil
            candidate.isRunning = false
            candidate.ownership = .none
            candidate.readyState = .stopped
            candidate.lastProbeAt = Date()
        }
    }

    private func terminateGatewayProcess(pid: Int32, port: Int) async -> Bool {
        kill(pid, SIGTERM)
        for _ in 0..<12 {
            let currentPID = gatewayPIDListening(onPort: port)
            if currentPID == nil || currentPID != pid {
                return true
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if gatewayPIDListening(onPort: port) == pid {
            kill(pid, SIGKILL)
        }

        for _ in 0..<8 {
            let currentPID = gatewayPIDListening(onPort: port)
            if currentPID == nil || currentPID != pid {
                return true
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }

        return gatewayPIDListening(onPort: port) != pid
    }

    private func gatewayPIDListening(onPort port: Int) -> Int32? {
        let output = runLocalCommand(
            "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN", "-nP"]
        )
        return output?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first(where: { $0 > 0 })
    }

    private func processCommandLine(pid: Int32) -> String? {
        runLocalCommand("/bin/ps", arguments: ["-o", "command=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeGatewayProcess(_ commandLine: String) -> Bool {
        let normalized = commandLine.lowercased()
        return normalized.contains("openclaw") && normalized.contains("gateway")
    }

    private func runLocalCommand(_ executable: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

private enum ExistingGatewayDisposition {
    case adopt(Int32?)
    case relaunch
    case fail(String)
}

final class EZRWorkerSupervisorService: NSObject, EZRWorkerSupervisorProtocol {
    private let controller = EZRWorkerSupervisorController()

    func reconcileLaunchState() async {
        await controller.reconcileLaunchState()
    }

    func ping(withReply reply: @escaping (String) -> Void) {
        Task {
            reply(await controller.ping())
        }
    }

    func listProfilesRuntime(withReply reply: @escaping (String) -> Void) {
        Task {
            reply(await controller.listProfilesRuntimeJSON())
        }
    }

    func prepareProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.prepareProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func startProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.startProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func stopProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.stopProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func restartProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void) {
        guard let uuid = UUID(uuidString: profileID) else {
            reply(false, "无效的 profileID")
            return
        }
        Task {
            let result = await controller.restartProfile(profileID: uuid)
            reply(result.0, result.1)
        }
    }

    func reloadProfiles(withReply reply: @escaping (Bool, String?) -> Void) {
        Task {
            let result = await controller.reloadProfiles()
            reply(result.0, result.1)
        }
    }
}
