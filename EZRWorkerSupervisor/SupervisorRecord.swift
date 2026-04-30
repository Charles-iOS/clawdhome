import Foundation

final class SupervisorRecord {
    var profile: GatewayProfile
    var resolution: GatewayProfileResolution
    var process: Process?
    var isPrepared = false
    var isRunning = false
    var pid: Int32?
    var readyState: SupervisorReadyState = .stopped
    var ownership: SupervisorOwnership = .none
    var portListeningPID: Int32?
    var httpResponding: Bool?
    var adoptionKind: SupervisorAdoptionKind = .none
    var lastProbeAt: Date?
    var healthState: SupervisorHealthState = .unknown
    var lastReadyAt: Date?
    var unhealthySince: Date?
    var lastHealthyProbeAt: Date?
    var lastUnhealthyReason: String?
    var userStoppedAt: Date?
    var lastError: String?
    var lastLifecycleMessage: String?

    init(profile: GatewayProfile) {
        self.profile = profile
        self.resolution = GatewayProfileResolver.resolve(profile)
        syncLegacyPreparationState()
    }

    func apply(profile: GatewayProfile) {
        self.profile = profile
        self.resolution = GatewayProfileResolver.resolve(profile)
        syncLegacyPreparationState()
    }

    private func syncLegacyPreparationState() {
        guard profile.sourceKind == .legacyReuse,
              readyState == .stopped
        else {
            return
        }

        isPrepared = FileManager.default.fileExists(atPath: resolution.resolvedConfigPath)
    }

    func markHealthy(now: Date = Date()) {
        healthState = .healthy
        readyState = .ready
        lastReadyAt = now
        lastHealthyProbeAt = now
        unhealthySince = nil
        lastUnhealthyReason = nil
        lastError = nil
        lastLifecycleMessage = "Gateway 已就绪"
    }

    func markUnhealthy(now: Date = Date(), reason: String) {
        if unhealthySince == nil {
            unhealthySince = now
        }
        lastUnhealthyReason = reason
    }

    func markNoProcess(message: String = "Gateway 已停止", now: Date = Date()) {
        healthState = .noProcess
        readyState = .stopped
        isRunning = false
        pid = nil
        ownership = .none
        portListeningPID = nil
        httpResponding = false
        adoptionKind = .none
        unhealthySince = nil
        lastUnhealthyReason = nil
        lastProbeAt = now
        lastError = nil
        lastLifecycleMessage = message
    }

    func markFailed(_ message: String, now: Date = Date()) {
        healthState = .failed
        readyState = .failed
        isRunning = false
        pid = nil
        ownership = .none
        adoptionKind = .none
        unhealthySince = unhealthySince ?? now
        lastUnhealthyReason = message
        lastError = message
        lastLifecycleMessage = message
    }

    func markManuallyStopped(now: Date = Date()) {
        userStoppedAt = now
        markNoProcess(now: now)
    }

    func clearManualStopMarker() {
        userStoppedAt = nil
    }

    func unhealthyDuration(now: Date = Date()) -> TimeInterval? {
        guard let unhealthySince else { return nil }
        return now.timeIntervalSince(unhealthySince)
    }

    func snapshot() -> SupervisorProfileRuntime {
        SupervisorProfileRuntime(
            profileID: profile.id,
            slug: profile.slug,
            displayName: profile.displayName,
            sourceKind: profile.sourceKind,
            managementMode: profile.managementMode,
            resolvedConfigPath: resolution.resolvedConfigPath,
            resolvedStateDir: resolution.resolvedStateDir,
            resolvedWorkspaceRoot: resolution.resolvedWorkspaceRoot,
            resolvedPort: resolution.resolvedPort,
            isPrepared: isPrepared,
            isRunning: isRunning,
            pid: pid,
            readyState: readyState,
            ownership: ownership,
            portListeningPID: portListeningPID,
            httpResponding: httpResponding,
            adoptionKind: adoptionKind,
            lastProbeAt: lastProbeAt,
            healthState: healthState,
            lastReadyAt: lastReadyAt,
            unhealthySince: unhealthySince,
            lastHealthyProbeAt: lastHealthyProbeAt,
            lastUnhealthyReason: lastUnhealthyReason,
            userStoppedAt: userStoppedAt,
            lastError: lastError,
            lastLifecycleMessage: lastLifecycleMessage
        )
    }
}
