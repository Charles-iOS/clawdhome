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

    init(profile: GatewayProfile) {
        self.profile = profile
        self.resolution = GatewayProfileResolver.resolve(profile)
    }

    func apply(profile: GatewayProfile) {
        self.profile = profile
        self.resolution = GatewayProfileResolver.resolve(profile)
    }

    func snapshot() -> SupervisorProfileRuntime {
        SupervisorProfileRuntime(
            profileID: profile.id,
            slug: profile.slug,
            displayName: profile.displayName,
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
            lastError: lastError
        )
    }
}
