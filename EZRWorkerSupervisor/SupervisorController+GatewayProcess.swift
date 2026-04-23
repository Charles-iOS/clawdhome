import Darwin
import Foundation

extension EZRWorkerSupervisorController {
    func existingGatewayDisposition(
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

    func healthyGatewayDisposition(
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

        guard let commandLine = processCommandLine(pid: listeningPID),
              looksLikeGatewayProcess(commandLine)
        else {
            return .fail("端口 \(record.resolution.resolvedPort) 已被其他进程占用")
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

enum ExistingGatewayDisposition {
    case adopt(Int32?)
    case relaunch
    case fail(String)
}
