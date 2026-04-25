import Darwin
import Foundation

extension EZRWorkerSupervisorController {
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
            let configExists = FileManager.default.fileExists(
                atPath: record.resolution.resolvedConfigPath
            )

            if profile.sourceKind == .legacyReuse {
                guard configExists else {
                    throw NSError(domain: "EZRWorkerSupervisor", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "legacy profile 缺少 openclaw.json"
                    ])
                }
            } else if !configExists {
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

        guard let profile = profiles[profileID] else {
            return (false, "未找到 profile: \(profileID.uuidString)")
        }
        let record = recordForProfile(profile)
        if let existingGatewayResult = await adoptExistingHealthyGatewayIfAvailable(for: record) {
            return existingGatewayResult
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
                requireSameListeningPID: true
            )
        }

        if let existingGatewayResult = await adoptExistingHealthyGatewayIfAvailable(for: record) {
            return existingGatewayResult
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
            requireSameListeningPID: true,
            startupOutput: startupOutput
        )
    }

    func stopProfile(profileID: UUID) async -> (Bool, String?) {
        guard let record = records[profileID] else {
            return (true, nil)
        }

        return await stopRecord(record)
    }

    func stopRecord(_ record: SupervisorRecord) async -> (Bool, String?) {
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
                  looksLikeGatewayProcess(commandLine),
                  record.profile.sourceKind != .managed || record.pid == pid || gatewayProcessMatches(record: record, pid: pid) {
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
}
