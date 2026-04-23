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
    private static let meaningfulLegacyConfigKeys: Set<String> = [
        "agents",
        "bindings",
        "channels",
        "models",
        "secrets",
    ]

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
        let removedRecords = loadProfilesFromDisk()
        for record in removedRecords {
            inFlightStartTasks[record.profile.id]?.cancel()
            inFlightStartTasks.removeValue(forKey: record.profile.id)
            _ = await stopRecord(record)
        }
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
            try reconcileManagedConfigLayoutIfNeeded(record.resolution)

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
        guard !Task.isCancelled else {
            return (false, "Gateway 启动已取消")
        }

        let prepareResult = await prepareProfile(profileID: profileID)
        guard prepareResult.0 else { return prepareResult }
        guard !Task.isCancelled else {
            if let record = records[profileID] {
                _ = await stopRecord(record)
            }
            return (false, "Gateway 启动已取消")
        }
        guard let record = records[profileID] else {
            return (false, "缺少运行时记录")
        }

        if let process = record.process, process.isRunning {
            return await waitForGatewayReady(
                record: record,
                pid: process.processIdentifier,
                ownership: .supervised,
                requireSameListeningPID: false
            )
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
                record.lastError = nil
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

        if let occupiedPID = gatewayPIDListening(onPort: record.resolution.resolvedPort) {
            switch await existingGatewayDisposition(for: record, listeningPID: occupiedPID) {
            case .adopt(let pid):
                return await waitForGatewayReady(
                    record: record,
                    pid: pid,
                    ownership: .adopted,
                    requireSameListeningPID: true
                )
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

        let process = Process()
        process.executableURL = OpenClawRuntime.bundledNodeURL
        process.arguments = [OpenClawRuntime.bundledOpenClawEntry.path, "gateway"]
        process.environment = OpenClawRuntime.buildEnvironment(profile: record.resolution)
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let startupOutput = ProcessOutputCollector()
        let outputPipe = Pipe()
        startupOutput.attach(to: outputPipe)
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        let controller = self
        let recordID = profileID
        process.terminationHandler = { terminated in
            startupOutput.finishReading(from: outputPipe)
            let terminatedPID = terminated.processIdentifier
            Task {
                await controller.handleProcessTermination(
                    profileID: recordID,
                    pid: terminatedPID,
                    exitCode: terminated.terminationStatus,
                    capturedOutput: startupOutput.output
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

        return await waitForGatewayReady(
            record: record,
            pid: process.processIdentifier,
            ownership: .supervised,
            requireSameListeningPID: false,
            startupOutput: startupOutput
        )
    }

    private func waitForGatewayReady(
        record: SupervisorRecord,
        pid: Int32?,
        ownership: SupervisorOwnership,
        requireSameListeningPID: Bool,
        startupOutput: ProcessOutputCollector? = nil
    ) async -> (Bool, String?) {
        record.isRunning = true
        record.pid = pid
        record.readyState = .starting
        record.ownership = ownership
        record.lastError = nil

        for _ in 0..<Self.gatewayStartupProbeAttempts {
            if Task.isCancelled {
                _ = await stopRecord(record)
                return (false, "Gateway 启动已取消")
            }

            if ownership == .supervised,
               record.process == nil,
               record.readyState == .failed {
                return (false, record.lastError ?? "Gateway 异常退出")
            }

            if ownership == .supervised,
               let process = record.process,
               !process.isRunning {
                let message =
                    record.lastError
                    ?? extractStartupFailureMessage(from: startupOutput?.output)
                    ?? "Gateway 异常退出"
                record.readyState = .failed
                record.isRunning = false
                record.ownership = .none
                record.lastError = message
                return (false, message)
            }

            if requireSameListeningPID,
               let pid,
               let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort),
               currentPID != pid {
                let message = "端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程占用"
                record.readyState = .failed
                record.isRunning = false
                record.ownership = .none
                record.lastError = message
                return (false, message)
            }

            let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
            record.lastProbeAt = Date()
            if probe.ready {
                record.readyState = .ready
                record.isRunning = true
                record.pid = gatewayPIDListening(onPort: record.resolution.resolvedPort) ?? pid
                record.lastError = nil
                return (true, nil)
            }
            try? await Task.sleep(nanoseconds: Self.gatewayStartupProbeIntervalNanoseconds)
        }

        let finalProbe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        record.lastProbeAt = Date()
        if finalProbe.ready {
            record.readyState = .ready
            record.isRunning = true
            record.pid = gatewayPIDListening(onPort: record.resolution.resolvedPort) ?? pid
            record.lastError = nil
            return (true, nil)
        }

        if ownership == .supervised, record.process?.isRunning == true {
            let capturedOutput = startupOutput?.output
            _ = await stopProfile(profileID: record.profile.id)
            let message =
                extractStartupFailureMessage(from: capturedOutput)
                ?? "Gateway 启动超时（\(Self.gatewayStartupProbeAttempts)s）"
            record.lastError = message
            record.readyState = .failed
            return (false, message)
        }

        let message = "Gateway 启动超时（\(Self.gatewayStartupProbeAttempts)s）"
        record.lastError = message
        record.readyState = .failed
        record.isRunning = false
        record.ownership = .none
        return (false, message)
    }

    func stopProfile(profileID: UUID) async -> (Bool, String?) {
        guard let record = records[profileID] else {
            return (true, nil)
        }

        return await stopRecord(record)
    }

    private func stopRecord(_ record: SupervisorRecord) async -> (Bool, String?) {
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
        let removedRecords = loadProfilesFromDisk()
        for record in removedRecords {
            inFlightStartTasks[record.profile.id]?.cancel()
            inFlightStartTasks.removeValue(forKey: record.profile.id)
            _ = await stopRecord(record)
        }
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

    @discardableResult
    private func loadProfilesFromDisk() -> [SupervisorRecord] {
        guard let document = Self.readProfilesDocumentFromDisk() else {
            let removedRecords = Array(records.values)
            profiles = [:]
            profileOrder = []
            records = [:]
            return removedRecords
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
        var removedRecords: [SupervisorRecord] = []
        for recordID in Array(records.keys) where !knownIDs.contains(recordID) {
            if let record = records.removeValue(forKey: recordID) {
                removedRecords.append(record)
            }
        }
        return removedRecords
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

    private func handleProcessTermination(
        profileID: UUID,
        pid terminatedPID: Int32,
        exitCode: Int32,
        capturedOutput: String?
    ) async {
        guard let record = records[profileID] else { return }

        let terminatedWasCurrent =
            record.process?.processIdentifier == terminatedPID
            || record.pid == terminatedPID

        if record.process?.processIdentifier == terminatedPID {
            record.process = nil
        }

        if !terminatedWasCurrent {
            record.lastProbeAt = Date()
            return
        }

        let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        record.lastProbeAt = Date()
        if probe.ready {
            record.pid = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            record.isRunning = true
            record.ownership = .adopted
            record.readyState = .ready
            record.lastError = nil
            return
        }

        record.pid = nil
        record.isRunning = false
        record.ownership = .none
        if record.readyState != .stopped {
            record.readyState = .failed
            record.lastError =
                extractStartupFailureMessage(from: capturedOutput)
                ?? "Gateway 异常退出 (exit \(exitCode))"
        }
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

    private func reconcileManagedConfigLayoutIfNeeded(_ resolution: GatewayProfileResolution) throws {
        guard resolution.sourceKind == .managed,
              let legacyConfigURL = resolution.legacyManagedConfigURL,
              legacyConfigURL.standardizedFileURL.path != resolution.configURL.standardizedFileURL.path
        else {
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyConfigURL.path) else { return }

        let canonicalConfigURL = resolution.configURL
        guard let migratedLegacyRoot = migratedLegacyConfigRoot(from: legacyConfigURL) else {
            return
        }

        if !fm.fileExists(atPath: canonicalConfigURL.path) {
            try writeJSONObject(migratedLegacyRoot, to: canonicalConfigURL)
            return
        }

        guard let canonicalRoot = loadJSONObject(at: canonicalConfigURL) else {
            try writeJSONObject(migratedLegacyRoot, to: canonicalConfigURL)
            return
        }

        guard shouldPromoteLegacyConfig(
            migratedLegacyRoot,
            over: canonicalRoot,
            legacyConfigURL: legacyConfigURL,
            canonicalConfigURL: canonicalConfigURL
        ) else {
            return
        }

        var mergedRoot = canonicalRoot
        for (key, value) in migratedLegacyRoot where key != "gateway" {
            mergedRoot[key] = value
        }

        guard !jsonObjectsEqual(mergedRoot, canonicalRoot) else { return }
        try writeJSONObject(mergedRoot, to: canonicalConfigURL)
    }

    private func migratedLegacyConfigRoot(
        from legacyConfigURL: URL
    ) -> [String: Any]? {
        guard var root = loadJSONObject(at: legacyConfigURL) else { return nil }
        root = rewriteRelativeSecretProviderPaths(
            in: root,
            from: legacyConfigURL.deletingLastPathComponent()
        )
        return root
    }

    private func rewriteRelativeSecretProviderPaths(
        in root: [String: Any],
        from sourceDirectoryURL: URL
    ) -> [String: Any] {
        guard var secrets = root["secrets"] as? [String: Any],
              var providers = secrets["providers"] as? [String: Any]
        else {
            return root
        }

        for (providerID, rawProvider) in providers {
            guard var provider = rawProvider as? [String: Any],
                  let rawPath = provider["path"] as? String
            else {
                continue
            }

            let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
            guard !expandedPath.isEmpty, !expandedPath.hasPrefix("/") else { continue }

            let absoluteSourceURL = sourceDirectoryURL
                .appendingPathComponent(expandedPath)
                .standardizedFileURL
            provider["path"] = absoluteSourceURL.path
            providers[providerID] = provider
        }

        var updatedRoot = root
        secrets["providers"] = providers
        updatedRoot["secrets"] = secrets
        return updatedRoot
    }

    private func shouldPromoteLegacyConfig(
        _ legacyRoot: [String: Any],
        over canonicalRoot: [String: Any],
        legacyConfigURL: URL,
        canonicalConfigURL: URL
    ) -> Bool {
        if meaningfulConfigSectionCount(in: canonicalRoot) == 0,
           meaningfulConfigSectionCount(in: legacyRoot) > 0 {
            return true
        }

        guard let legacyModifiedAt = modificationDate(for: legacyConfigURL),
              let canonicalModifiedAt = modificationDate(for: canonicalConfigURL) else {
            return false
        }
        return legacyModifiedAt > canonicalModifiedAt
    }

    private func meaningfulConfigSectionCount(in root: [String: Any]) -> Int {
        Self.meaningfulLegacyConfigKeys.reduce(into: 0) { count, key in
            if isMeaningfulJSONObjectValue(root[key]) {
                count += 1
            }
        }
    }

    private func isMeaningfulJSONObjectValue(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case nil, is NSNull:
            return false
        default:
            return true
        }
    }

    private func loadJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private func writeJSONObject(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs),
              JSONSerialization.isValidJSONObject(rhs),
              let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return lhsData == rhsData
    }

    private func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
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

    private func extractStartupFailureMessage(from output: String?) -> String? {
        guard let output else { return nil }

        let lines = output
            .components(separatedBy: .newlines)
            .map(Self.stripANSIEscapeCodes)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for line in lines.reversed() where !line.localizedCaseInsensitiveContains("OpenClaw") {
            if line.localizedCaseInsensitiveContains("Gateway failed to start:") {
                return line
            }
            if line.localizedCaseInsensitiveContains("error:") {
                return line
            }
        }

        return lines.last
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

    private static func stripANSIEscapeCodes(from text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
                options: []
            )
        else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}

private enum ExistingGatewayDisposition {
    case adopt(Int32?)
    case relaunch
    case fail(String)
}

private final class ProcessOutputCollector {
    private let lock = NSLock()
    private var data = Data()

    func attach(to pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.append(chunk)
        }
    }

    func finishReading(from pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = nil
        let remaining = pipe.fileHandleForReading.readDataToEndOfFile()
        append(remaining)
    }

    var output: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }
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
