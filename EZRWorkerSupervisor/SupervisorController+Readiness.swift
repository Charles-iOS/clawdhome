import Foundation

extension EZRWorkerSupervisorController {
    func refreshRuntimeSnapshotsBeforeListing() async {
        for profileID in profileOrder {
            guard let record = records[profileID] else { continue }

            switch record.profile.sourceKind {
            case .legacyReuse:
                await refreshLegacyRuntimeSnapshot(record)
            case .externalReuse:
                await refreshExternalRuntimeSnapshot(record)
            case .managed:
                await refreshManagedRuntimeSnapshot(record)
            }
        }
    }

    private func refreshLegacyRuntimeSnapshot(_ record: SupervisorRecord) async {
        let now = Date()
        let configExists = FileManager.default.fileExists(atPath: record.resolution.resolvedConfigPath)
        let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        let listeningPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
        record.lastProbeAt = now
        record.portListeningPID = listeningPID
        record.httpResponding = probe.alive

        if probe.alive {
            record.isPrepared = configExists
            record.isRunning = true
            record.pid = listeningPID
            if record.process?.isRunning == true,
               record.process?.processIdentifier == listeningPID {
                record.ownership = .supervised
            } else {
                record.process = nil
                record.ownership = .adopted
            }
            record.adoptionKind = adoptionKind(for: record, ownership: record.ownership)
            if probe.ready {
                record.markHealthy(now: now)
            } else {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: listeningPID,
                    ownership: record.ownership,
                    pendingHealthState: .portListening,
                    reason: "legacy gateway health check is not ready",
                    pendingMessage: "Gateway 已启动，正在等待健康检查",
                    now: now
                )
            }
            return
        }

        if let listeningPID,
           let commandLine = processCommandLine(pid: listeningPID),
           looksLikeGatewayProcess(commandLine) {
            record.process = nil
            applyUnhealthyRunningSnapshot(
                record,
                pid: listeningPID,
                ownership: .adopted,
                pendingHealthState: .portListening,
                reason: "legacy gateway port is listening but health check is not responding",
                pendingMessage: "Gateway 进程运行中，等待健康检查",
                now: now
            )
            return
        }

        record.isPrepared = configExists

        if record.process?.isRunning == true,
           record.readyState == .starting || record.readyState == .preparing {
            applyUnhealthyRunningSnapshot(
                record,
                pid: record.process?.processIdentifier,
                ownership: .supervised,
                pendingHealthState: .launching,
                reason: "legacy gateway process is running but port is unavailable",
                pendingMessage: "Gateway 进程运行中，正在等待端口 \(record.resolution.resolvedPort)",
                now: now
            )
            return
        }

        if record.process?.isRunning != true {
            record.process = nil
        }

        if configExists {
            record.markNoProcess(now: now)
            record.lastError = nil
        } else if record.readyState != .failed {
            record.markNoProcess(now: now)
        }
    }

    private func refreshManagedRuntimeSnapshot(_ record: SupervisorRecord) async {
        let now = Date()
        let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        let listeningPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
        record.lastProbeAt = now
        record.portListeningPID = listeningPID
        record.httpResponding = probe.alive

        let ownsProcess = listeningPID.map { pid in
            guard let process = record.process, process.isRunning else {
                return false
            }
            return listeningGatewayProcessBelongsToRecord(
                pid: pid,
                record: record,
                expectedRootPID: process.processIdentifier
            )
        } ?? false
        let matchesProfile = listeningPID.map { gatewayProcessMatches(record: record, pid: $0) } ?? false
        let ownsOrMatchesProfile = ownsProcess || matchesProfile

        guard probe.alive, ownsOrMatchesProfile else {
            if let listeningPID, ownsOrMatchesProfile {
                if !ownsProcess {
                    record.process = nil
                }
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: listeningPID,
                    ownership: ownsProcess ? .supervised : .adopted,
                    pendingHealthState: .portListening,
                    reason: ownsProcess
                        ? "gateway port is listening but health check is not responding"
                        : "adopted gateway health check is not responding",
                    pendingMessage: "Gateway 已监听端口 \(record.resolution.resolvedPort)，但健康检查暂未响应",
                    now: now
                )
                return
            }

            if let process = record.process, process.isRunning {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: process.processIdentifier,
                    ownership: .supervised,
                    pendingHealthState: .launching,
                    reason: "gateway process is running but port is unavailable",
                    pendingMessage: "Gateway 进程运行中，正在等待端口 \(record.resolution.resolvedPort)",
                    now: now
                )
                return
            }

            if record.process?.isRunning != true,
               record.isRunning,
               record.readyState != .failed {
                record.process = nil
                record.markNoProcess(now: now)
            }
            return
        }

        record.isPrepared = true
        record.isRunning = true
        record.pid = listeningPID
        record.ownership = ownsProcess ? .supervised : .adopted
        record.adoptionKind = adoptionKind(for: record, ownership: record.ownership)
        if probe.ready {
            record.markHealthy(now: now)
        } else {
            applyUnhealthyRunningSnapshot(
                record,
                pid: listeningPID,
                ownership: record.ownership,
                pendingHealthState: .portListening,
                reason: "gateway health check is not ready",
                pendingMessage: "Gateway 已监听端口 \(record.resolution.resolvedPort)，正在等待健康检查",
                now: now
            )
        }
    }

    private func refreshExternalRuntimeSnapshot(_ record: SupervisorRecord) async {
        let now = Date()
        let configExists = FileManager.default.fileExists(atPath: record.resolution.resolvedConfigPath)
        let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        let listeningPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
        record.lastProbeAt = now
        record.portListeningPID = listeningPID
        record.httpResponding = probe.alive
        record.isPrepared = configExists

        guard probe.alive else {
            if let listeningPID,
               let commandLine = processCommandLine(pid: listeningPID),
               looksLikeGatewayProcess(commandLine),
               externalGatewayProcessMatches(record: record, pid: listeningPID, commandLine: commandLine) {
                record.process = nil
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: listeningPID,
                    ownership: .adopted,
                    pendingHealthState: .portListening,
                    reason: "external gateway port is listening but health check is not responding",
                    pendingMessage: "外部 Gateway 已接入，但健康检查暂未响应",
                    now: now
                )
                return
            }

            if record.process?.isRunning != true {
                record.process = nil
            }
            if !configExists {
                record.markFailed("外部 OpenClaw 配置缺失", now: now)
            } else {
                record.markNoProcess(message: "外部 Gateway 未运行", now: now)
                record.lastError = nil
            }
            return
        }

        guard let listeningPID,
              let commandLine = processCommandLine(pid: listeningPID),
              looksLikeGatewayProcess(commandLine),
              externalGatewayProcessMatches(record: record, pid: listeningPID, commandLine: commandLine) else {
            record.markFailed("端口 \(record.resolution.resolvedPort) 已被其他进程占用，未接管", now: now)
            return
        }

        record.process = nil
        record.isRunning = true
        record.pid = listeningPID
        record.ownership = .adopted
        record.adoptionKind = adoptionKind(for: record, ownership: .adopted)
        if probe.ready {
            record.markHealthy(now: now)
            record.lastLifecycleMessage = record.profile.managementMode == .observeOnly
                ? "外部 Gateway 已接入（仅观察）"
                : "外部 Gateway 已接入"
        } else {
            applyUnhealthyRunningSnapshot(
                record,
                pid: listeningPID,
                ownership: .adopted,
                pendingHealthState: .portListening,
                reason: "external gateway health check is not ready",
                pendingMessage: "外部 Gateway 已接入，正在等待健康检查",
                now: now
            )
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
                record.ownership = .adopted
                record.pid = pid
                record.portListeningPID = pid
                record.httpResponding = currentProbe.alive
                record.adoptionKind = adoptionKind(for: record, ownership: .adopted)
                record.markHealthy()
                return (true, nil)
            }
                return await waitForGatewayReady(
                    record: record,
                    pid: pid,
                    ownership: .adopted,
                    requireSameListeningPID: record.profile.sourceKind != .legacyReuse && pid != nil
                )
        case .relaunch:
            return nil
        case .fail(let message):
            record.markFailed(message)
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
        record.healthState = .launching
        record.ownership = ownership
        record.adoptionKind = adoptionKind(for: record, ownership: ownership)
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
                record.markFailed(message)
                record.ownership = .none
                return (false, message)
            }

            if ownership == .supervised,
               let process = record.process,
               !process.isRunning {
                let message =
                    record.lastError
                    ?? extractStartupFailureMessage(from: startupOutput?.output)
                    ?? "Gateway 异常退出"
                record.markFailed(message)
                record.ownership = .none
                return (false, message)
            }

            if ownership == .supervised,
               Self.isTerminalStartupFailureOutput(startupOutput?.output) {
                let capturedOutput = startupOutput?.output
                let message =
                    extractStartupFailureMessage(from: capturedOutput)
                    ?? "Gateway 启动失败"
                _ = await stopRecord(record)
                record.markFailed(message)
                record.ownership = .none
                return (false, message)
            }

            if ownership == .supervised,
               startupOutputIndicatesGatewayReady(startupOutput?.output) {
                let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
                if requireSameListeningPID,
                   let currentPID,
                   !listeningGatewayProcessBelongsToRecord(
                       pid: currentPID,
                       record: record,
                       expectedRootPID: pid
                   ) {
                    let message = "端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程占用"
                    if ownership == .supervised {
                        _ = await stopRecord(record)
                    }
                    record.markFailed(message)
                    record.ownership = .none
                    return (false, message)
                }

                record.isPrepared = true
                record.isRunning = true
                let resolvedPID = currentPID ?? pid
                record.pid = resolvedPID
                record.portListeningPID = currentPID
                record.httpResponding = true
                record.adoptionKind = adoptionKind(for: record, ownership: ownership)
                record.markHealthy()
                return (true, nil)
            }

            let probe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
            let probeAt = Date()
            record.lastProbeAt = probeAt
            let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            record.portListeningPID = currentPID
            record.httpResponding = probe.alive
            let currentPIDBelongsToRecord = currentPID.map {
                listeningGatewayProcessBelongsToRecord(
                    pid: $0,
                    record: record,
                    expectedRootPID: pid
                )
            } ?? false
            if requireSameListeningPID,
               currentPID != nil,
               !currentPIDBelongsToRecord {
                let message = "端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程占用"
                if ownership == .supervised {
                    _ = await stopRecord(record)
                }
                record.markFailed(message)
                record.ownership = .none
                return (false, message)
            }

            if probe.ready {
                record.isPrepared = true
                record.isRunning = true
                record.pid = currentPID ?? pid
                record.portListeningPID = currentPID
                record.httpResponding = probe.alive
                record.adoptionKind = adoptionKind(for: record, ownership: ownership)
                record.markHealthy(now: probeAt)
                return (true, nil)
            }
            let elapsedSeconds = max(
                1,
                Int(Date().timeIntervalSince(startupStartedAt).rounded(.down))
            )
            if probe.alive {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: currentPID ?? pid,
                    ownership: ownership,
                    pendingHealthState: .portListening,
                    reason: "gateway health check is not ready during startup",
                    pendingMessage: "Gateway 已监听端口 \(record.resolution.resolvedPort)，正在等待健康检查",
                    now: probeAt
                )
            } else if currentPIDBelongsToRecord {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: currentPID,
                    ownership: ownership,
                    pendingHealthState: .portListening,
                    reason: "gateway port is listening but health check is not responding during startup",
                    pendingMessage: "Gateway 已监听端口 \(record.resolution.resolvedPort)，但健康检查暂未响应",
                    now: probeAt
                )
            } else if elapsedSeconds >= 30 {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: pid,
                    ownership: ownership,
                    pendingHealthState: .launching,
                    reason: "gateway startup port is unavailable",
                    pendingMessage: "仍在初始化插件运行依赖和本地缓存，已等待 \(elapsedSeconds) 秒",
                    now: probeAt
                )
            } else if elapsedSeconds >= 8 {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: pid,
                    ownership: ownership,
                    pendingHealthState: .launching,
                    reason: "gateway startup port is unavailable",
                    pendingMessage: "Gateway 正在初始化本地运行依赖，首次启动可能较久",
                    now: probeAt
                )
            } else {
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: pid,
                    ownership: ownership,
                    pendingHealthState: .launching,
                    reason: "gateway startup port is unavailable",
                    pendingMessage: "正在等待 Gateway 打开本地端口 \(record.resolution.resolvedPort)",
                    now: probeAt
                )
            }
            try? await Task.sleep(nanoseconds: Self.gatewayStartupProbeIntervalNanoseconds)
        }

        let finalProbe = await GatewayHealthProbe.httpProbe(port: record.resolution.resolvedPort)
        let finalProbeAt = Date()
        record.lastProbeAt = finalProbeAt
        if finalProbe.ready {
            let finalPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            if requireSameListeningPID,
               let finalPID,
               !listeningGatewayProcessBelongsToRecord(
                   pid: finalPID,
                   record: record,
                   expectedRootPID: pid
               ) {
                let message = "端口 \(record.resolution.resolvedPort) 已被其他 Gateway 进程占用"
                if ownership == .supervised {
                    _ = await stopRecord(record)
                }
                record.markFailed(message, now: finalProbeAt)
                record.ownership = .none
                return (false, message)
            }
            record.isPrepared = true
            record.isRunning = true
            record.pid = finalPID ?? pid
            record.portListeningPID = record.pid
            record.httpResponding = finalProbe.alive
            record.adoptionKind = adoptionKind(for: record, ownership: ownership)
            record.markHealthy(now: finalProbeAt)
            return (true, nil)
        }

        if ownership == .supervised, record.process?.isRunning == true {
            let capturedOutput = startupOutput?.output
            _ = await stopRecord(record, markUserStopped: false)
            let message =
                extractStartupFailureMessage(from: capturedOutput)
                ?? "Gateway 启动超时（\(Self.gatewayStartupProbeAttempts)s）"
            record.markFailed(message, now: finalProbeAt)
            return (false, message)
        }

        let message = "Gateway 启动超时（\(Self.gatewayStartupProbeAttempts)s）"
        record.markFailed(message, now: finalProbeAt)
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
        let probeAt = Date()
        record.lastProbeAt = probeAt
        if probe.ready {
            let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort)
            switch await healthyGatewayDisposition(for: record, listeningPID: currentPID) {
            case .adopt(let pid):
                record.pid = pid
                record.isPrepared = true
                record.isRunning = true
                record.ownership = .adopted
                record.portListeningPID = pid
                record.httpResponding = probe.alive
                record.adoptionKind = adoptionKind(for: record, ownership: .adopted)
                record.markHealthy(now: probeAt)
                return
            case .relaunch:
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .starting
                record.healthState = .launching
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 请求重启，正在重新拉起"
                Task { [profileID] in
                    _ = await self.startProfile(profileID: profileID)
                }
                return
            case .fail(let message):
                record.markFailed(message, now: probeAt)
                record.ownership = .none
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
                record.portListeningPID = pid
                record.httpResponding = probe.alive
                record.adoptionKind = adoptionKind(for: record, ownership: .adopted)
                applyUnhealthyRunningSnapshot(
                    record,
                    pid: pid,
                    ownership: .adopted,
                    pendingHealthState: .portListening,
                    reason: "gateway process terminated but adopted gateway is not ready",
                    pendingMessage: "正在接管已有 Gateway 并等待就绪",
                    now: probeAt
                )
                Task { [profileID] in
                    _ = await self.startProfile(profileID: profileID)
                }
            case .relaunch:
                record.pid = nil
                record.isRunning = false
                record.ownership = .none
                record.readyState = .starting
                record.healthState = .launching
                record.lastError = nil
                record.lastLifecycleMessage = "Gateway 已退出，正在重新启动"
                Task { [profileID] in
                    _ = await self.startProfile(profileID: profileID)
                }
            case .fail(let message):
                record.markFailed(message, now: probeAt)
                record.ownership = .none
            }
            return
        }

        if let currentPID = gatewayPIDListening(onPort: record.resolution.resolvedPort),
           listeningGatewayProcessBelongsToRecord(
               pid: currentPID,
               record: record,
               expectedRootPID: terminatedPID
           ) {
            _ = await terminateGatewayProcess(
                pid: currentPID,
                port: record.resolution.resolvedPort
            )
            record.portListeningPID = nil
            record.httpResponding = false
        }

        if record.readyState != .stopped,
           isSupervisorRestartHandoff(exitCode: exitCode, output: capturedOutput) {
            guard recordRestartHandoff(for: profileID) else {
                record.markFailed(Self.gatewayRestartHandoffLimitMessage)
                record.ownership = .none
                return
            }

            record.pid = nil
            record.isRunning = false
            record.ownership = .none
            record.readyState = .starting
            record.healthState = .launching
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
            let message = extractStartupFailureMessage(from: capturedOutput)
                ?? "Gateway 异常退出 (exit \(exitCode))"
            record.markFailed(message)
            record.ownership = .none
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

    private func applyUnhealthyRunningSnapshot(
        _ record: SupervisorRecord,
        pid: Int32?,
        ownership: SupervisorOwnership,
        pendingHealthState: SupervisorHealthState,
        reason: String,
        pendingMessage: String,
        now: Date
    ) {
        record.isPrepared = true
        record.isRunning = true
        record.pid = pid
        record.ownership = ownership
        record.adoptionKind = adoptionKind(for: record, ownership: ownership)
        record.readyState = .starting
        record.lastError = nil
        record.markUnhealthy(now: now, reason: reason)

        let threshold = unresponsiveThreshold(for: record)
        let duration = record.unhealthyDuration(now: now) ?? 0
        if duration >= threshold {
            record.healthState = .unresponsive
            let seconds = Int(duration.rounded(.down))
            record.lastLifecycleMessage = "Gateway 进程运行中，但健康检查已连续 \(seconds) 秒无响应"
        } else {
            record.healthState = pendingHealthState
            record.lastLifecycleMessage = pendingMessage
        }
    }

    private func unresponsiveThreshold(for record: SupervisorRecord) -> TimeInterval {
        record.lastReadyAt == nil
            ? Self.gatewayFreshLaunchGracePeriod
            : Self.gatewayUnresponsiveThreshold
    }

    private func adoptionKind(
        for record: SupervisorRecord,
        ownership: SupervisorOwnership
    ) -> SupervisorAdoptionKind {
        switch ownership {
        case .none:
            return .none
        case .supervised:
            return .supervised
        case .adopted:
            switch record.profile.sourceKind {
            case .managed:
                return .managedAdopted
            case .legacyReuse:
                return .legacyAdopted
            case .externalReuse:
                return .externalAdopted
            }
        }
    }
}
