import Darwin
import Foundation

extension EZRWorkerSupervisorController {
    func prepareProfile(profileID: UUID) async -> (Bool, String?) {
        guard let profile = profiles[profileID] else {
            return (false, "未找到 profile: \(profileID.uuidString)")
        }

        let record = recordForProfile(profile)
        record.readyState = .preparing
        record.healthState = .launching
        record.lastError = nil
        record.lastLifecycleMessage = "正在检查 Profile 目录和 Gateway 配置"

        do {
            if let handoffMessage = unresolvedLaunchAgentHandoffMessage(for: profile) {
                throw NSError(domain: "EZRWorkerSupervisor", code: 41, userInfo: [
                    NSLocalizedDescriptionKey: handoffMessage
                ])
            }

            if profile.sourceKind == .externalReuse,
               profile.managementMode == .observeOnly {
                let configExists = FileManager.default.fileExists(
                    atPath: record.resolution.resolvedConfigPath
                )
                guard configExists else {
                    throw NSError(domain: "EZRWorkerSupervisor", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "external profile 缺少 openclaw.json"
                    ])
                }

                record.isPrepared = true
                if record.isRunning {
                    record.markHealthy()
                    record.lastLifecycleMessage = "外部 Gateway 已接入（仅观察）"
                } else {
                    record.healthState = .noProcess
                    record.readyState = .stopped
                    record.lastLifecycleMessage = "外部 Profile 已验证，等待外部 Gateway 启动"
                }
                return (true, nil)
            }

            try ensureProfileDirectories(record.resolution)
            record.lastLifecycleMessage = "正在准备 Profile 目录"
            try reconcileManagedConfigLayoutIfNeeded(record.resolution)
            let configExists = FileManager.default.fileExists(
                atPath: record.resolution.resolvedConfigPath
            )

            if profile.sourceKind == .legacyReuse {
                record.lastLifecycleMessage = "正在检查旧版 OpenClaw 配置"
                guard configExists else {
                    throw NSError(domain: "EZRWorkerSupervisor", code: 404, userInfo: [
                        NSLocalizedDescriptionKey: "legacy profile 缺少 openclaw.json"
                    ])
                }
            } else if !configExists {
                record.lastLifecycleMessage = "首次创建 OpenClaw 配置和工作区"
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

            record.lastLifecycleMessage = "正在写入 Gateway 端口和认证配置"
            try normalizeConfig(for: record.resolution)

            record.isPrepared = true
            if record.isRunning {
                record.markHealthy()
            } else {
                record.healthState = .noProcess
                record.readyState = .stopped
                record.unhealthySince = nil
                record.lastUnhealthyReason = nil
                record.lastLifecycleMessage = "Profile 已准备，等待启动 Gateway"
            }
            return (true, nil)
        } catch {
            record.isPrepared = false
            record.markFailed(error.localizedDescription)
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
        record.clearManualStopMarker()
        if let handoffMessage = unresolvedLaunchAgentHandoffMessage(for: profile) {
            record.markFailed(handoffMessage)
            record.ownership = .none
            return (false, handoffMessage)
        }
        record.lastLifecycleMessage = "正在检查是否已有可复用 Gateway"
        if let existingGatewayResult = await adoptExistingHealthyGatewayIfAvailable(for: record) {
            return existingGatewayResult
        }

        guard profile.managementMode == .managedByEZRWorker else {
            let message = "该 Profile 当前为仅观察模式，不会由 EZRWorker 启动 Gateway"
            if record.isPrepared {
                record.markNoProcess(message: message)
                record.lastError = message
            } else {
                record.markFailed(message)
            }
            record.ownership = .none
            return (false, message)
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
            record.lastLifecycleMessage = "Gateway 进程已存在，正在等待就绪"
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

        record.lastLifecycleMessage = "正在检查 Gateway 端口 \(record.resolution.resolvedPort)"
        if let occupiedPID = gatewayPIDListening(onPort: record.resolution.resolvedPort) {
            switch await existingGatewayDisposition(for: record, listeningPID: occupiedPID) {
            case .adopt(let pid):
                record.lastLifecycleMessage = "正在接管已有 Gateway 进程"
                return await waitForGatewayReady(
                    record: record,
                    pid: pid,
                    ownership: .adopted,
                    requireSameListeningPID: record.profile.sourceKind != .legacyReuse && pid != nil
                )
            case .relaunch:
                break
            case .fail(let message):
                record.markFailed(message)
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
        startupOutput.attach(
            to: outputPipe,
            teeTo: prepareGatewayOutputLog(for: record.resolution)
        )
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
            record.lastLifecycleMessage = "正在启动 Gateway 进程"
            try process.run()
            record.process = process
            record.pid = process.processIdentifier
            record.isRunning = true
            record.readyState = .starting
            record.healthState = .launching
            record.markUnhealthy(reason: "gateway process has started and is waiting for health check")
            record.ownership = .supervised
            record.lastError = nil
            record.lastLifecycleMessage = "Gateway 进程已启动，正在等待本地服务响应"
        } catch {
            record.markFailed(error.localizedDescription)
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

    private func prepareGatewayOutputLog(for resolution: GatewayProfileResolution) -> URL? {
        let logsURL = resolution.stateDirURL.appendingPathComponent("logs", isDirectory: true)
        let currentURL = logsURL.appendingPathComponent("gateway-current.log")
        let previousURL = logsURL.appendingPathComponent("gateway-previous.log")
        do {
            try FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: previousURL.path) {
                try? FileManager.default.removeItem(at: previousURL)
            }
            if FileManager.default.fileExists(atPath: currentURL.path) {
                try? FileManager.default.moveItem(at: currentURL, to: previousURL)
            }
            return currentURL
        } catch {
            return nil
        }
    }

    func stopProfile(profileID: UUID) async -> (Bool, String?) {
        guard let record = records[profileID] else {
            return (true, nil)
        }

        return await stopRecord(record, markUserStopped: true)
    }

    func stopRecord(_ record: SupervisorRecord, markUserStopped: Bool = false) async -> (Bool, String?) {
        guard record.profile.managementMode == .managedByEZRWorker else {
            let message = "该 Profile 当前为仅观察模式，不会由 EZRWorker 停止 Gateway"
            record.lastLifecycleMessage = message
            return (false, message)
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
                  looksLikeGatewayProcess(commandLine),
                  record.profile.sourceKind == .legacyReuse
                    || record.pid == pid
                    || gatewayProcessMatches(record: record, pid: pid)
                    || (record.profile.sourceKind == .externalReuse
                        && externalGatewayProcessMatches(record: record, pid: pid, commandLine: commandLine)) {
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
        if markUserStopped {
            record.markManuallyStopped()
        } else {
            record.markNoProcess()
        }
        return (true, nil)
    }

    func restartProfile(profileID: UUID) async -> (Bool, String?) {
        guard let record = records[profileID] else {
            return await startProfile(profileID: profileID)
        }
        let stopResult = await stopRecord(record, markUserStopped: false)
        guard stopResult.0 else { return stopResult }
        return await startProfile(profileID: profileID)
    }

    private func unresolvedLaunchAgentHandoffMessage(for profile: GatewayProfile) -> String? {
        guard (profile.sourceKind == .externalReuse || profile.sourceKind == .legacyReuse),
              profile.managementMode == .managedByEZRWorker,
              let handoff = profile.launchAgentHandoff else {
            return nil
        }

        let originalPlistExists = FileManager.default.fileExists(atPath: handoff.originalPlistPath)
        switch handoff.status {
        case .disabled:
            if originalPlistExists {
                return "检测到旧 LaunchAgent 仍在原路径启用：\(handoff.originalLabel)。请先交接或禁用旧自启项。"
            }
            return nil
        case .notRequired:
            return nil
        case .pending, .manualRequired, .failed:
            if originalPlistExists {
                return "旧 LaunchAgent 尚未交接：\(handoff.originalLabel)。请先交接或改为仅观察模式。"
            }
            return nil
        }
    }
}
