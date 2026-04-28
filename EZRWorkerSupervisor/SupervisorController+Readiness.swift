import Foundation

extension EZRWorkerSupervisorController {
    func refreshLegacyRuntimeSnapshotsBeforeListing() async {
        for profileID in profileOrder {
            guard let record = records[profileID],
                  record.profile.sourceKind == .legacyReuse
            else {
                continue
            }

            await refreshLegacyRuntimeSnapshot(record)
        }
    }

    private func refreshLegacyRuntimeSnapshot(_ record: SupervisorRecord) async {
        let configExists = FileManager.default.fileExists(atPath: record.resolution.resolvedConfigPath)
        let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        let listeningPID = probe.alive ? gatewayPIDListening(onPort: record.resolution.resolvedPort) : nil
        record.lastProbeAt = Date()

        if probe.alive {
            record.isPrepared = configExists
            record.isRunning = true
            record.pid = listeningPID
            record.readyState = probe.ready ? .ready : .starting
            record.lastLifecycleMessage = probe.ready ? "Gateway 已就绪" : "Gateway 已启动，正在等待健康检查"
            if record.process?.isRunning == true,
               record.process?.processIdentifier == listeningPID {
                record.ownership = .supervised
            } else {
                record.process = nil
                record.ownership = .adopted
            }
            record.lastError = nil
            return
        }

        record.isPrepared = configExists

        if record.process?.isRunning == true,
           record.readyState == .starting || record.readyState == .preparing {
            return
        }

        if record.process?.isRunning != true {
            record.process = nil
        }

        record.isRunning = false
        record.pid = nil
        record.ownership = .none
        if configExists {
            record.readyState = .stopped
            record.lastError = nil
        } else if record.readyState != .failed {
            record.readyState = .stopped
        }
    }

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
                record.lastLifecycleMessage = "Gateway 已就绪"
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
            record.lastLifecycleMessage = message
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
        record.lastLifecycleMessage = "正在等待 Gateway 打开本地端口 \(record.resolution.resolvedPort)"
        let startupStartedAt = Date()
        let startupDeadline = startupStartedAt.addingTimeInterval(TimeInterval(Self.gatewayStartupProbeAttempts))

        for _ in 0..<Self.gatewayStartupProbeAttempts {
            if Date() >= startupDeadline {
                break
            }

            if Task.isCancelled {
                _ = await stopRecord(record)
                return (false, "Gateway 启动已取消")
            }

            if ownership == .supervised,
               record.process == nil {
                let message =
                    record.lastError
                    ?? extractStartupFailureMessage(from: startupOutput?.output)
                    ?? "Gateway 异常退出"
                record.readyState = .failed
                record.isRunning = false
                record.ownership = .none
                record.lastError = message
                record.lastLifecycleMessage = message
                return (false, message)
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
                record.lastLifecycleMessage = message
                return (false, message)
            }

            if ownership == .supervised,
               Self.isTerminalStartupFailureOutput(startupOutput?.output) {
                let capturedOutput = startupOutput?.output
                let message =
                    extractStartupFailureMessage(from: capturedOutput)
                    ?? "Gateway 启动失败"
                _ = await stopRecord(record)
                record.readyState = .failed
                record.isRunning = false
                record.ownership = .none
                record.lastError = message
                record.lastLifecycleMessage = message
                return (false, message)
            }

            if ownership == .supervised,
               startupOutputIndicatesGatewayReady(startupOutput?.output) {
                let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
                if requireSameListeningPID,
                   let pid,
                   let currentPID,
                   currentPID != pid {
                    let message = "端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程占用"
                    record.readyState = .failed
                    record.isRunning = false
                    record.ownership = .none
                    record.lastError = message
                    record.lastLifecycleMessage = message
                    return (false, message)
                }

                record.isPrepared = true
                record.readyState = .ready
                record.isRunning = true
                record.pid = currentPID ?? pid
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 已就绪"
                return (true, nil)
            }

            let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
            record.lastProbeAt = Date()
            let currentPID: Int32?
            if probe.alive {
                currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            } else {
                currentPID = nil
            }
            if probe.alive,
               requireSameListeningPID,
               let pid,
               let currentPID,
               currentPID != pid {
                let message = "端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程占用"
                record.readyState = .failed
                record.isRunning = false
                record.ownership = .none
                record.lastError = message
                record.lastLifecycleMessage = message
                return (false, message)
            }

            if probe.ready {
                record.isPrepared = true
                record.readyState = .ready
                record.isRunning = true
                record.pid = currentPID ?? pid
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 已就绪"
                return (true, nil)
            }
            let elapsedSeconds = max(
                1,
                Int(Date().timeIntervalSince(startupStartedAt).rounded(.down))
            )
            if probe.alive {
                record.lastLifecycleMessage = "Gateway 已监听端口 \(record.resolution.resolvedPort)，正在等待健康检查"
            } else if elapsedSeconds >= 30 {
                record.lastLifecycleMessage = "仍在初始化插件运行依赖和本地缓存，已等待 \(elapsedSeconds) 秒"
            } else if elapsedSeconds >= 8 {
                record.lastLifecycleMessage = "Gateway 正在初始化本地运行依赖，首次启动可能较久"
            } else {
                record.lastLifecycleMessage = "正在等待 Gateway 打开本地端口 \(record.resolution.resolvedPort)"
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
            record.lastLifecycleMessage = "Gateway 已就绪"
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
            record.lastLifecycleMessage = message
            return (false, message)
        }

        let message = "Gateway 启动超时（\(Self.gatewayStartupProbeAttempts)s）"
        record.lastError = message
        record.readyState = .failed
        record.isRunning = false
        record.ownership = .none
        record.lastLifecycleMessage = message
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
            let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            switch await healthyGatewayDisposition(for: record, listeningPID: currentPID) {
            case .adopt(let pid):
                record.pid = pid
                record.isPrepared = true
                record.isRunning = true
                record.ownership = .adopted
                record.readyState = .ready
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 已就绪"
                return
            case .relaunch:
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .starting
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 请求重启，正在重新拉起"
                Task { [profileID] in
                    _ = await self.startProfile(profileID: profileID)
                }
                return
            case .fail(let message):
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .failed
                record.lastError = message
                record.lastLifecycleMessage = message
                return
            }
        }
        if probe.alive {
            let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            switch await healthyGatewayDisposition(for: record, listeningPID: currentPID) {
            case .adopt(let pid):
                record.pid = pid
                record.isRunning = true
                record.ownership = .adopted
                record.readyState = .starting
                record.lastError = nil
                record.lastLifecycleMessage = "正在接管已有 Gateway 并等待就绪"
                Task { [profileID] in
                    _ = await self.startProfile(profileID: profileID)
                }
            case .relaunch:
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .starting
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 已退出，正在重新启动"
                Task { [profileID] in
                    _ = await self.startProfile(profileID: profileID)
                }
            case .fail(let message):
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .failed
                record.lastError = message
                record.lastLifecycleMessage = message
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
                record.lastLifecycleMessage = Self.gatewayRestartHandoffLimitMessage
                return
            }

            record.pid = nil
            record.isRunning = false
            record.ownership = .none
            record.readyState = .starting
            record.lastError = nil
            record.lastLifecycleMessage = "Gateway 请求重启，正在重新拉起"

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
            record.lastLifecycleMessage = record.lastError
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
