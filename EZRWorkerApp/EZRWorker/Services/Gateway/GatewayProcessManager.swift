import Foundation
import Observation

@MainActor
@Observable
final class GatewayProcessManager {

    enum State: Equatable {
        case stopped
        case stopping
        case starting
        case waitingForHealthCheck(String)
        case running
        case unresponsive(String)
        case failed(String)
    }

    enum Ownership: Equatable {
        case none
        case managed
        case reused
    }

    private(set) var state: State = .stopped
    private(set) var ownership: Ownership = .none
    private(set) var gatewayPort: Int = GatewayProfileResolver.defaultGatewayPort

    @ObservationIgnored
    private var supervisorClient: SupervisorClient?
    @ObservationIgnored
    private var profileStore: GatewayProfileStore?
    @ObservationIgnored
    private var monitorTask: Task<Void, Never>?

    var isRunning: Bool {
        switch state {
        case .running, .waitingForHealthCheck, .unresponsive:
            return true
        case .stopped, .stopping, .starting, .failed:
            return false
        }
    }

    func bind(profileStore: GatewayProfileStore, supervisorClient: SupervisorClient) {
        self.profileStore = profileStore
        self.supervisorClient = supervisorClient
        gatewayPort = profileStore.selectedResolution?.resolvedPort ?? GatewayProfileResolver.defaultGatewayPort
        startMonitoring()
    }

    func start() {
        Task {
            await performLifecycleOperation(start: true, stop: false)
        }
    }

    func stop() {
        Task {
            await performLifecycleOperation(start: false, stop: true)
        }
    }

    func restart() {
        Task {
            await performRestart()
        }
    }

    func refreshRuntimeState() async {
        guard let supervisorClient, let profileStore else { return }
        if !supervisorClient.isConnected {
            supervisorClient.connect()
            guard await supervisorClient.waitUntilConnected() else { return }
        }

        let runtimes: [SupervisorProfileRuntime]
        do {
            runtimes = try await supervisorClient.listProfilesRuntime()
        } catch {
            return
        }

        guard let selectedProfile = profileStore.selectedProfile else {
            applyRuntime(nil, fallbackPort: profileStore.selectedResolution?.resolvedPort)
            return
        }
        let runtime = runtimes.first(where: { $0.profileID == selectedProfile.id })
        applyRuntime(runtime, fallbackPort: GatewayProfileResolver.resolve(selectedProfile).resolvedPort)
    }

    func prepareForAppTermination() {
        monitorTask?.cancel()
        monitorTask = nil
    }

    private func performLifecycleOperation(start: Bool, stop: Bool) async {
        guard let supervisorClient, let profileStore, let profileID = profileStore.selectedProfile?.id else { return }

        if start {
            state = .starting
            do {
                try await supervisorClient.startProfile(profileID: profileID)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }

        if stop {
            state = .stopping
            do {
                try await supervisorClient.stopProfile(profileID: profileID)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }

        await refreshRuntimeState()
    }

    private func performRestart() async {
        guard let supervisorClient, let profileStore, let profileID = profileStore.selectedProfile?.id else { return }
        state = .starting
        do {
            try await supervisorClient.restartProfile(profileID: profileID)
        } catch {
            state = .failed(error.localizedDescription)
        }
        await refreshRuntimeState()
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refreshRuntimeState()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func applyRuntime(_ runtime: SupervisorProfileRuntime?, fallbackPort: Int?) {
        gatewayPort = runtime?.resolvedPort ?? fallbackPort ?? GatewayProfileResolver.defaultGatewayPort

        guard let runtime else {
            ownership = .none
            state = .stopped
            return
        }

        ownership = switch runtime.ownership {
        case .supervised:
            .managed
        case .adopted:
            .reused
        case .none:
            .none
        }

        state = switch runtime.healthState {
        case .healthy:
            runtime.isRunning ? .running : .stopped
        case .launching:
            .starting
        case .portListening:
            .waitingForHealthCheck(runtime.lastLifecycleMessage ?? "Gateway 已监听端口，正在等待健康检查")
        case .unresponsive:
            .unresponsive(runtime.lastLifecycleMessage ?? "Gateway 健康检查未响应")
        case .noProcess:
            .stopped
        case .failed:
            .failed(runtime.lastError ?? runtime.lastLifecycleMessage ?? "Gateway 运行失败")
        case .unknown:
            switch runtime.readyState {
            case .ready:
                runtime.isRunning ? .running : .stopped
            case .preparing, .starting:
                .starting
            case .failed:
                .failed(runtime.lastError ?? "Gateway 运行失败")
            case .stopped, .unknown:
                runtime.isRunning ? .running : .stopped
            }
        }
    }

    static var bundledNodeURL: URL { OpenClawRuntime.bundledNodeURL }
    static var bundledOpenClawEntry: URL { OpenClawRuntime.bundledOpenClawEntry }
    static var bundledNpxURL: URL { OpenClawRuntime.bundledNpxURL }

    static func buildEnvironment(profile: GatewayProfileResolution? = nil) -> [String: String] {
        OpenClawRuntime.buildEnvironment(profile: profile)
    }

    static func runOpenclawLocally(
        args: [String],
        profile: GatewayProfileResolution? = nil
    ) async -> (Bool, String) {
        await OpenClawRuntime.runOpenClaw(arguments: args, profile: profile)
    }

    static func addAgentLocally(
        agentId: String,
        profile: GatewayProfileResolution
    ) async -> (Bool, String) {
        let trimmedID = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return (false, "agentId 不能为空")
        }

        return await runOpenclawLocally(
            args: [
                "agents", "add", trimmedID,
                "--non-interactive",
                "--workspace", profile.workspacePath(for: trimmedID),
                "--agent-dir", profile.agentDirPath(for: trimmedID),
                "--json",
            ],
            profile: profile
        )
    }

    static func deleteAgentLocally(
        agentId: String,
        profile: GatewayProfileResolution
    ) async -> (Bool, String) {
        let trimmedID = agentId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty else {
            return (false, "agentId 不能为空")
        }

        return await runOpenclawLocally(
            args: [
                "agents", "delete", trimmedID,
                "--force",
                "--json",
            ],
            profile: profile
        )
    }
}
