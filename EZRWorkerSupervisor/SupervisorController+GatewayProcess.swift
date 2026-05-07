import Darwin
import Foundation

extension EZRWorkerSupervisorController {
    func existingGatewayDisposition(
        for record: SupervisorRecord,
        listeningPID: Int32?
    ) async -> ExistingGatewayDisposition {
        switch record.profile.sourceKind {
        case .legacyReuse:
            guard let listeningPID else { return .adopt(nil) }
            guard let commandLine = processCommandLine(pid: listeningPID),
                  looksLikeGatewayProcess(commandLine) else {
                return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
            }
            return .adopt(listeningPID)
        case .externalReuse:
            guard let listeningPID else {
                return .fail("端口 \(record.resolution.resolvedPort) 已被占用，但无法确认进程归属")
            }
            guard let commandLine = processCommandLine(pid: listeningPID),
                  looksLikeGatewayProcess(commandLine),
                  externalGatewayProcessMatches(record: record, pid: listeningPID, commandLine: commandLine) else {
                return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用，未接管")
            }
            return .adopt(listeningPID)
        case .managed:
            break
        }

        guard let listeningPID else {
            return .adopt(nil)
        }

        let ownedByRecord = listeningGatewayProcessBelongsToRecord(
            pid: listeningPID,
            record: record,
            expectedRootPID: record.process?.processIdentifier ?? record.pid
        )
        if ownedByRecord {
            if await terminateGatewayProcess(pid: listeningPID, port: record.resolution.resolvedPort) {
                clearRuntimeStateForGateway(
                    pid: listeningPID,
                    port: record.resolution.resolvedPort,
                    excluding: record.profile.id
                )
                return .relaunch
            }
            return .fail("端口 \(record.resolution.resolvedPort) 上存在无法接管的旧 Gateway 进程")
        }

        guard let commandLine = processCommandLine(pid: listeningPID) else {
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
        }
        guard looksLikeGatewayProcess(commandLine) else {
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
        }

        let matchingProfileID = managedProfileIDForGatewayProcess(pid: listeningPID)
        guard matchingProfileID == record.profile.id else {
            let suffix = matchingProfileID.flatMap { profiles[$0]?.displayName }
                .map { "（\($0)）" } ?? ""
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程\(suffix)占用")
        }

        if await terminateGatewayProcess(pid: listeningPID, port: record.resolution.resolvedPort) {
            clearRuntimeStateForGateway(
                pid: listeningPID,
                port: record.resolution.resolvedPort,
                excluding: record.profile.id
            )
            return .relaunch
        }

        return .fail("端口 \(record.resolution.resolvedPort) 上存在无法接管的旧 Gateway 进程")
    }

    func healthyGatewayDisposition(
        for record: SupervisorRecord,
        listeningPID: Int32?
    ) async -> ExistingGatewayDisposition {
        switch record.profile.sourceKind {
        case .legacyReuse:
            guard let listeningPID else { return .adopt(nil) }
            guard let commandLine = processCommandLine(pid: listeningPID),
                  looksLikeGatewayProcess(commandLine) else {
                return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
            }
            return .adopt(listeningPID)
        case .externalReuse:
            guard let listeningPID else {
                return .fail("端口 \(record.resolution.resolvedPort) 已被占用，但无法确认进程归属")
            }
            guard let commandLine = processCommandLine(pid: listeningPID),
                  looksLikeGatewayProcess(commandLine),
                  externalGatewayProcessMatches(record: record, pid: listeningPID, commandLine: commandLine) else {
                return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用，未接管")
            }
            return .adopt(listeningPID)
        case .managed:
            break
        }

        guard let listeningPID else {
            return .adopt(nil)
        }

        let ownedByRecord = listeningGatewayProcessBelongsToRecord(
            pid: listeningPID,
            record: record,
            expectedRootPID: record.process?.processIdentifier ?? record.pid
        )
        if ownedByRecord {
            return .adopt(listeningPID)
        }

        guard let commandLine = processCommandLine(pid: listeningPID),
              looksLikeGatewayProcess(commandLine)
        else {
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
        }

        let matchingProfileID = managedProfileIDForGatewayProcess(pid: listeningPID)
        guard matchingProfileID == record.profile.id else {
            let suffix = matchingProfileID.flatMap { profiles[$0]?.displayName }
                .map { "（\($0)）" } ?? ""
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程\(suffix)占用")
        }

        clearRuntimeStateForGateway(
            pid: listeningPID,
            port: record.resolution.resolvedPort,
            excluding: record.profile.id
        )
        return .adopt(listeningPID)
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

    func terminateGatewayProcess(pid: Int32, port: Int) async -> Bool {
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

    func gatewayPIDListening(onPort port: Int) -> Int32? {
        let output = runLocalCommand(
            "/usr/sbin/lsof",
            arguments: ["-tiTCP:\(port)", "-sTCP:LISTEN", "-nP"]
        )
        return output?
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .first(where: { $0 > 0 })
    }

    func processCommandLine(pid: Int32) -> String? {
        runLocalCommand("/bin/ps", arguments: ["-o", "command=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func looksLikeGatewayProcess(_ commandLine: String) -> Bool {
        let normalized = commandLine.lowercased()
        return normalized.contains("openclaw") && normalized.contains("gateway")
    }

    func gatewayProcessMatches(record: SupervisorRecord, pid: Int32) -> Bool {
        gatewayProcessOpenFileNames(pid: pid)
            .contains(where: { gatewayOpenFile($0, matches: record.resolution) })
    }

    func listeningGatewayProcessBelongsToRecord(
        pid listeningPID: Int32,
        record: SupervisorRecord,
        expectedRootPID: Int32?
    ) -> Bool {
        if let expectedRootPID, listeningPID == expectedRootPID {
            return true
        }
        if record.pid == listeningPID {
            return true
        }
        if gatewayProcessMatches(record: record, pid: listeningPID) {
            return true
        }
        if let expectedRootPID,
           processIsDescendant(pid: listeningPID, of: expectedRootPID) {
            return true
        }
        return false
    }

    func externalGatewayProcessMatches(
        record: SupervisorRecord,
        pid: Int32,
        commandLine: String? = nil
    ) -> Bool {
        let commandLine = commandLine ?? processCommandLine(pid: pid)
        if let commandLine,
           commandLineReferences(commandLine, resolution: record.resolution) {
            return true
        }
        return gatewayProcessMatches(record: record, pid: pid)
    }

    private func commandLineReferences(
        _ commandLine: String,
        resolution: GatewayProfileResolution
    ) -> Bool {
        let normalizedCommand = normalizedPathLikeText(commandLine)
        let configPath = normalizedPath(resolution.resolvedConfigPath)
        let runtimeConfigPath = normalizedPath(resolution.runtimeConfigURL.path)
        let stateDir = normalizedPath(resolution.resolvedStateDir)
        return normalizedCommand.contains(configPath)
            || normalizedCommand.contains(runtimeConfigPath)
            || normalizedCommand.contains(stateDir)
    }

    private func managedProfileIDForGatewayProcess(pid: Int32) -> UUID? {
        let openFileNames = gatewayProcessOpenFileNames(pid: pid)
        for profileID in profileOrder {
            guard let record = records[profileID],
                  record.profile.sourceKind == .managed,
                  openFileNames.contains(where: { gatewayOpenFile($0, matches: record.resolution) })
            else {
                continue
            }
            return profileID
        }
        return nil
    }

    private func gatewayOpenFile(_ rawPath: String, matches resolution: GatewayProfileResolution) -> Bool {
        let path = normalizedPath(rawPath)
        let configPath = normalizedPath(resolution.resolvedConfigPath)
        let runtimeConfigPath = normalizedPath(resolution.runtimeConfigURL.path)
        let stateDir = normalizedPath(resolution.resolvedStateDir)

        return path == configPath
            || path == runtimeConfigPath
            || path.hasPrefix(stateDir + "/")
    }

    private func gatewayProcessOpenFileNames(pid: Int32) -> [String] {
        guard let output = runLocalCommand("/usr/sbin/lsof", arguments: ["-Fn", "-p", "\(pid)"]) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard line.first == "n" else { return nil }
                let path = String(line.dropFirst())
                guard path.hasPrefix("/") else { return nil }
                return path
            }
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private func normalizedPathLikeText(_ text: String) -> String {
        NSString(string: text).expandingTildeInPath
    }

    private func processIsDescendant(pid: Int32, of ancestorPID: Int32) -> Bool {
        guard pid > 1, ancestorPID > 1 else {
            return false
        }
        if pid == ancestorPID {
            return true
        }

        var currentPID = pid
        var seen = Set<Int32>()
        for _ in 0..<32 {
            guard let parentPID = parentProcessID(pid: currentPID),
                  parentPID > 1,
                  seen.insert(parentPID).inserted
            else {
                return false
            }
            if parentPID == ancestorPID {
                return true
            }
            currentPID = parentPID
        }
        return false
    }

    private func parentProcessID(pid: Int32) -> Int32? {
        guard let output = runLocalCommand("/bin/ps", arguments: ["-o", "ppid=", "-p", "\(pid)"]) else {
            return nil
        }
        return Int32(output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func runLocalCommand(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 1.5
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            if finished.wait(timeout: .now() + 0.2) == .timedOut,
               process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + 0.2)
            }
            process.terminationHandler = nil
            return nil
        }

        process.terminationHandler = nil
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}

enum ExistingGatewayDisposition {
    case adopt(Int32?)
    case relaunch
    case fail(String)
}
