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
    var lastProbeAt: Date?
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
            lastProbeAt: lastProbeAt,
            lastError: lastError,
            lastLifecycleMessage: lastLifecycleMessage
        )
    }
}
