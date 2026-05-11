import Foundation

extension EZRWorkerSupervisorController {
    enum LifecycleRecoveryReason: String {
        case unresponsive
        case terminationRelaunch
        case terminationHandoff
        case terminationAdoptStartup
        case terminationLauncherExited
    }

    enum LifecycleRecoveryOperation: String {
        case start
        case restart
    }

    @discardableResult
    func requestLifecycleRecovery(
        profileID: UUID,
        reason: LifecycleRecoveryReason,
        operation: LifecycleRecoveryOperation
    ) -> Bool {
        guard let record = records[profileID] else {
            logLifecycle(
                "lifecycle recovery dropped reason=\(reason.rawValue) op=\(operation.rawValue) detail=missing-record id=\(profileID.uuidString)"
            )
            return false
        }

        let now = Date()
        let slug = record.profile.slug
        let port = record.resolution.resolvedPort

        var shouldCapturePseudoLiveSample = false
        if reason == .unresponsive {
            // 把 unresponsive 自动重启与任意一次 lifecycle 恢复共用冷却窗口；
            // 这样 handoff/relaunch 之后至少 cooldown 才会再次被 unresponsive 判死。
            if let last = pseudoLiveRecoveryTimestamps[profileID],
               now.timeIntervalSince(last) < Self.pseudoLiveAutoRestartCooldown {
                logLifecycle(
                    "lifecycle recovery skipped reason=\(reason.rawValue) detail=cooldown profile=\(slug) port=\(port)"
                )
                return false
            }
            // 重启完成后还在 settle 窗口内（lastReadyAt 还未达成），先不要再触发自动重启；
            // 给新进程足够的时间完成 plugins.bootstrap。
            if record.lastReadyAt == nil,
               let healthyAt = record.unhealthySince ?? record.lastProbeAt,
               now.timeIntervalSince(healthyAt) < Self.postRestartSettleWindow {
                logLifecycle(
                    "lifecycle recovery skipped reason=\(reason.rawValue) detail=post-restart-settle profile=\(slug) port=\(port)"
                )
                return false
            }
            // 强保护：端口仍在 LISTEN 且当前窗口内已经触发过至少一次 handoff 时，
            // 倾向于"只抓样本不重启"。真实场景里 /readyz 慢但端口还在监听，
            // 多半是 LLM 长任务或插件 backfill，重启反而会打断用户操作。
            let recentHandoffCount = restartHandoffTimestamps[profileID]?
                .filter { now.timeIntervalSince($0) < Self.gatewayRestartHandoffWindow }
                .count ?? 0
            if record.portListeningPID != nil, recentHandoffCount >= 1 {
                logLifecycle(
                    "lifecycle recovery skipped reason=\(reason.rawValue) detail=port-still-listening profile=\(slug) port=\(port) recentHandoffs=\(recentHandoffCount)"
                )
                pseudoLiveRecoveryTimestamps[profileID] = now
                Task { [profileID] in
                    await self.capturePseudoLiveSampleIfNeeded(profileID: profileID)
                }
                record.lastLifecycleMessage = "Gateway 健康检查无响应但端口仍在监听，已暂停自动重启并抓取诊断样本"
                return false
            }
            guard recordRestartHandoff(for: profileID, now: now) else {
                logLifecycle(
                    "lifecycle recovery throttled reason=\(reason.rawValue) detail=handoff-limit profile=\(slug) port=\(port)"
                )
                record.lastLifecycleMessage = "Gateway 自动重启过于频繁，已暂停自动重启，请稍后重试"
                return false
            }
            shouldCapturePseudoLiveSample = true
        }

        if reason == .terminationHandoff {
            guard recordRestartHandoff(for: profileID, now: now) else {
                logLifecycle(
                    "lifecycle recovery throttled reason=\(reason.rawValue) detail=handoff-limit profile=\(slug) port=\(port)"
                )
                record.markFailed(Self.gatewayRestartHandoffLimitMessage)
                record.ownership = .none
                return false
            }
        }

        // 任何一次成功决定的 recovery 都更新冷却时间戳，作为下一轮 unresponsive 判定的基线。
        pseudoLiveRecoveryTimestamps[profileID] = now

        logLifecycle(
            "lifecycle recovery decided reason=\(reason.rawValue) op=\(operation.rawValue) profile=\(slug) port=\(port)"
        )

        Task { [profileID, operation, shouldCapturePseudoLiveSample] in
            if shouldCapturePseudoLiveSample {
                await self.capturePseudoLiveSampleIfNeeded(profileID: profileID)
            }
            switch operation {
            case .start:
                _ = await self.startProfile(profileID: profileID)
            case .restart:
                _ = await self.restartProfile(profileID: profileID)
            }
        }
        return true
    }

    func capturePseudoLiveSampleIfNeeded(profileID: UUID) async {
        guard let record = records[profileID] else { return }
        let now = Date()
        guard let pid = record.portListeningPID ?? record.pid, pid > 0 else {
            return
        }

        if let last = pseudoLiveSampleCaptureTimestamps[record.profile.id],
           now.timeIntervalSince(last) < Self.pseudoLiveSampleCaptureCooldown {
            return
        }
        pseudoLiveSampleCaptureTimestamps[record.profile.id] = now

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: now)
        let baseName = "sample-\(record.profile.slug)-\(record.resolution.resolvedPort)-\(pid)-\(timestamp)"
        let captureDir = EZRWorkerPaths.applicationSupportDirectory
            .appendingPathComponent("diagnostics", isDirectory: true)
            .appendingPathComponent("pseudo-live-samples", isDirectory: true)
        let outputURL = captureDir.appendingPathComponent("\(baseName).txt")
        let metaURL = captureDir.appendingPathComponent("\(baseName).meta.json")

        let meta = PseudoLiveSampleMeta(
            capturedAt: now,
            profileSlug: record.profile.slug,
            profileID: record.profile.id.uuidString,
            sourceKind: record.profile.sourceKind.rawValue,
            managementMode: record.profile.managementMode.rawValue,
            port: record.resolution.resolvedPort,
            pid: Int(pid),
            ownership: record.ownership.rawValue,
            adoptionKind: record.adoptionKind.rawValue,
            healthState: record.healthState.rawValue,
            readyState: record.readyState.rawValue,
            isRunning: record.isRunning,
            httpResponding: record.httpResponding,
            lastReadyAt: record.lastReadyAt,
            unhealthySince: record.unhealthySince,
            lastProbeAt: record.lastProbeAt,
            lastHealthyProbeAt: record.lastHealthyProbeAt,
            lastUnhealthyReason: record.lastUnhealthyReason,
            lastLifecycleMessage: record.lastLifecycleMessage,
            lastError: record.lastError,
            sampleFile: outputURL.lastPathComponent
        )

        logLifecycle(
            "pseudo-live sample capture start profile=\(record.profile.slug) port=\(record.resolution.resolvedPort) pid=\(pid) file=\(outputURL.path)"
        )

        await Task.detached {
            let fm = FileManager.default
            do {
                try fm.createDirectory(
                    at: captureDir,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                Self.writePseudoLiveSampleMeta(meta, to: metaURL)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
                process.arguments = [String(pid), "3", "-file", outputURL.path]
                try process.run()
                process.waitUntilExit()
                await self.logLifecycle(
                    "pseudo-live sample capture done profile=\(record.profile.slug) port=\(record.resolution.resolvedPort) pid=\(pid) exit=\(process.terminationStatus) file=\(outputURL.path) meta=\(metaURL.lastPathComponent)"
                )
            } catch {
                await self.logLifecycle(
                    "pseudo-live sample capture failed profile=\(record.profile.slug) port=\(record.resolution.resolvedPort) pid=\(pid) error=\(error.localizedDescription)"
                )
            }
        }.value
    }

    private static func writePseudoLiveSampleMeta(
        _ meta: PseudoLiveSampleMeta,
        to url: URL
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: url, options: [.atomic])
    }
}

private struct PseudoLiveSampleMeta: Codable {
    let capturedAt: Date
    let profileSlug: String
    let profileID: String
    let sourceKind: String
    let managementMode: String
    let port: Int
    let pid: Int
    let ownership: String
    let adoptionKind: String
    let healthState: String
    let readyState: String
    let isRunning: Bool
    let httpResponding: Bool?
    let lastReadyAt: Date?
    let unhealthySince: Date?
    let lastProbeAt: Date?
    let lastHealthyProbeAt: Date?
    let lastUnhealthyReason: String?
    let lastLifecycleMessage: String?
    let lastError: String?
    let sampleFile: String
}
