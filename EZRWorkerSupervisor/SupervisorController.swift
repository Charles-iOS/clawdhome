import Foundation

actor EZRWorkerSupervisorController {
    static let gatewayStartupProbeAttempts = 240
    static let gatewayStartupProbeIntervalNanoseconds: UInt64 = 1_000_000_000
    static let gatewayRestartHandoffWindow: TimeInterval = 60
    static let maxGatewayRestartHandoffsInWindow = 3
    static let gatewayRestartHandoffLimitMessage =
        "Gateway 连续请求 supervisor restart，已停止自动重启以避免循环"
    static let meaningfulLegacyConfigKeys: Set<String> = [
        "agents",
        "bindings",
        "channels",
        "models",
        "secrets",
    ]

    var profiles: [UUID: GatewayProfile] = [:]
    var profileOrder: [UUID] = []
    var records: [UUID: SupervisorRecord] = [:]
    var inFlightStartTasks: [UUID: Task<(Bool, String?), Never>] = [:]
    var restartHandoffTimestamps: [UUID: [Date]] = [:]
    var isReconcilingAutoStart = false
    var needsAutoStartReconcile = false

    init() {
        guard let document = Self.readProfilesDocumentFromDisk() else { return }
        let orderedProfiles = Self.sortedProfiles(from: document)
        profiles = Dictionary(uniqueKeysWithValues: orderedProfiles.map { ($0.id, $0) })
        profileOrder = orderedProfiles.map(\.id)
        for profile in orderedProfiles {
            records[profile.id] = SupervisorRecord(profile: profile)
        }
    }

    func ping() -> String {
        "pong"
    }

    func listProfilesRuntimeJSON() async -> String {
        await refreshRuntimeSnapshotsBeforeListing()
        let snapshots = profileOrder.compactMap { profileID -> SupervisorProfileRuntime? in
            if let record = records[profileID] {
                return record.snapshot()
            }
            guard let profile = profiles[profileID] else { return nil }
            return SupervisorRecord(profile: profile).snapshot()
        }
        return SupervisorJSONCodec.encode(snapshots)
    }
}
