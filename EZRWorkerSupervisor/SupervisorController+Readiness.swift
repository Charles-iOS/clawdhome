import Foundation

extension EZRWorkerSupervisorController {
    func adoptExistingHealthyGatewayIfAvailable(
        for record: SupervisorRecord
    ) async -> (Bool, String?)? {
        let currentProbe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        guard currentProbe.alive else { return nil }

        let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
        switch await healthyGatewayDisposition(for: record, listeningPID: currentPID) {
        case .adopt(let pid):
            record.lastProbeAt = Date()
            if currentProbe.ready {
                record.isPrepared = true
                record.isRunning = true
                record.readyState = .ready
                record.ownership = .adopted
                record.pid = pid
                record.lastError = nil
                return (true, nil)
            }
            return await waitForGatewayReady(
                record: record,
                pid: pid,
                ownership: .adopted,
                requireSameListeningPID: pid != nil
            )
        case .relaunch:
            return nil
        case .fail(let message):
            record.lastError = message
            record.readyState = .failed
            record.isRunning = false
            record.ownership = .none
            return (false, message)
        }
    }

    func waitForGatewayReady(
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
                record.isPrepared = true
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
            record.isPrepared = true
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

    func handleProcessTermination(
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
            record.isPrepared = true
            record.isRunning = true
            record.ownership = .adopted
            record.readyState = .ready
            record.lastError = nil
            return
        }
        if probe.alive {
            record.pid = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            record.isRunning = true
            record.ownership = .adopted
            record.readyState = .starting
            record.lastError = nil

            Task { [profileID] in
                _ = await self.startProfile(profileID: profileID)
            }
            return
        }

        if record.readyState != .stopped,
           isSupervisorRestartHandoff(exitCode: exitCode, output: capturedOutput) {
            guard recordRestartHandoff(for: profileID) else {
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .failed
                record.lastError = Self.gatewayRestartHandoffLimitMessage
                return
            }

            record.pid = nil
            record.isRunning = false
            record.ownership = .none
            record.readyState = .starting
            record.lastError = nil

            Task { [profileID] in
                _ = await self.startProfile(profileID: profileID)
            }
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

    func recordRestartHandoff(for profileID: UUID, now: Date = Date()) -> Bool {
        let cutoff = now.addingTimeInterval(-Self.gatewayRestartHandoffWindow)
        let recent = (restartHandoffTimestamps[profileID] ?? []).filter { $0 >= cutoff }
        guard recent.count < Self.maxGatewayRestartHandoffsInWindow else {
            restartHandoffTimestamps[profileID] = recent
            return false
        }
        restartHandoffTimestamps[profileID] = recent + [now]
        return true
    }
}
