import Foundation

actor EZRWorkerSupervisorController {
    static let gatewayStartupProbeAttempts = 120
    static let gatewayStartupProbeIntervalNanoseconds: UInt64 = 1_000_000_000
    static let gatewayUnresponsiveThreshold: TimeInterval = 30
    static let gatewayFreshLaunchGracePeriod: TimeInterval = 90
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
    var runtimeState = SupervisorRuntimeStateDocument()
    var isReconcilingAutoStart = false
    var needsAutoStartReconcile = false

    init() {
        runtimeState = EZRWorkerSupervisorController.readRuntimeStateFromDisk()
        guard let document = Self.readProfilesDocumentFromDisk() else { return }
        let orderedProfiles = Self.sortedProfiles(from: document)
        profiles = Dictionary(uniqueKeysWithValues: orderedProfiles.map { ($0.id, $0) })
        profileOrder = orderedProfiles.map(\.id)
        for profile in orderedProfiles {
            let record = SupervisorRecord(profile: profile)
            if let state = runtimeState.profiles[profile.id.uuidString] {
                record.userStoppedAt = state.userStoppedAt
            }
            records[profile.id] = record
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

    func applyPersistentRuntimeState(to record: SupervisorRecord) {
        guard let state = runtimeState.profiles[record.profile.id.uuidString] else { return }
        record.userStoppedAt = state.userStoppedAt
    }

    func persistentDesiredState(for profileID: UUID) -> SupervisorDesiredRuntimeState? {
        runtimeState.profiles[profileID.uuidString]?.desiredState
    }

    func setPersistentDesiredState(
        profileID: UUID,
        desiredState: SupervisorDesiredRuntimeState,
        userStoppedAt: Date?,
        lastManagedPID: Int32? = nil,
        lastLaunchNonce: String? = nil,
        upgradeHandoffAt: Date? = nil
    ) {
        var state = runtimeState.profiles[profileID.uuidString] ?? SupervisorRuntimeProfileState()
        state.desiredState = desiredState
        state.userStoppedAt = userStoppedAt
        if let lastManagedPID {
            state.lastManagedPID = lastManagedPID
        }
        if let lastLaunchNonce {
            state.lastLaunchNonce = lastLaunchNonce
        }
        if let upgradeHandoffAt {
            state.upgradeHandoffAt = upgradeHandoffAt
        }
        runtimeState.profiles[profileID.uuidString] = state
        persistRuntimeState()
    }

    func recordUpgradeHandoff(profileID: UUID, pid: Int32?) {
        var state = runtimeState.profiles[profileID.uuidString] ?? SupervisorRuntimeProfileState()
        state.lastManagedPID = pid
        state.upgradeHandoffAt = Date()
        runtimeState.profiles[profileID.uuidString] = state
        persistRuntimeState()
    }

    func removePersistentRuntimeState(for profileID: UUID) {
        runtimeState.profiles.removeValue(forKey: profileID.uuidString)
        persistRuntimeState()
    }

    func persistRuntimeState() {
        do {
            EZRWorkerPaths.ensureApplicationSupportDirectories()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(runtimeState)
            try data.write(to: Self.runtimeStateURL, options: [.atomic])
        } catch {
            // Runtime state should never block lifecycle operations; logs still surface through runtime snapshots.
        }
    }

    static var runtimeStateURL: URL {
        EZRWorkerPaths.applicationSupportDirectory
            .appendingPathComponent("supervisor-state.json")
    }

    static func readRuntimeStateFromDisk() -> SupervisorRuntimeStateDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: runtimeStateURL),
              let document = try? decoder.decode(SupervisorRuntimeStateDocument.self, from: data)
        else {
            return SupervisorRuntimeStateDocument()
        }
        return document
    }
}

enum SupervisorDesiredRuntimeState: String, Codable {
    case running
    case stopped
}

struct SupervisorRuntimeProfileState: Codable {
    var desiredState: SupervisorDesiredRuntimeState?
    var userStoppedAt: Date?
    var lastManagedPID: Int32?
    var lastLaunchNonce: String?
    var upgradeHandoffAt: Date?
}

struct SupervisorRuntimeStateDocument: Codable {
    var version = 1
    var profiles: [String: SupervisorRuntimeProfileState] = [:]
}
