import Foundation
import Observation

@MainActor
@Observable
final class AppBootstrapCoordinator {
    enum State: Equatable {
        case idle
        case starting
        case started
        case failed(String)
    }

    private(set) var state: State = .idle

    @ObservationIgnored private let processManager: GatewayProcessManager
    @ObservationIgnored private let envChecker: EnvironmentChecker
    @ObservationIgnored private let gatewayService: GatewayService
    @ObservationIgnored private let agentStore: AgentStore
    @ObservationIgnored private let workspaceManager: AgentWorkspaceManager
    @ObservationIgnored private let keychainStore: ProviderKeychainStore
    @ObservationIgnored private let modelStore: GlobalModelStore
    @ObservationIgnored private let profileStore: GatewayProfileStore
    @ObservationIgnored private let supervisorClient: SupervisorClient

    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored
    private var gatewayDependentStartupCompleted = false

    init(
        processManager: GatewayProcessManager,
        envChecker: EnvironmentChecker,
        gatewayService: GatewayService,
        agentStore: AgentStore,
        workspaceManager: AgentWorkspaceManager,
        keychainStore: ProviderKeychainStore,
        modelStore: GlobalModelStore,
        profileStore: GatewayProfileStore,
        supervisorClient: SupervisorClient
    ) {
        self.processManager = processManager
        self.envChecker = envChecker
        self.gatewayService = gatewayService
        self.agentStore = agentStore
        self.workspaceManager = workspaceManager
        self.keychainStore = keychainStore
        self.modelStore = modelStore
        self.profileStore = profileStore
        self.supervisorClient = supervisorClient
    }

    func startIfNeeded() async {
        switch state {
        case .starting, .started:
            return
        case .idle, .failed:
            break
        }

        state = .starting
        do {
            try await performBootstrap()
            state = .started
            startReconnectLoop()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func restartForProfileSwitch() async {
        stopReconnectLoop()
        await resetRuntimeState()
        state = .idle
        await startIfNeeded()
    }

    func resetForUnauthenticated() async {
        stopReconnectLoop()
        await resetRuntimeState()
        state = .idle
    }

    func prepareForAppTermination() {
        stopReconnectLoop()
        processManager.prepareForAppTermination()
        gatewayService.prepareForAppTermination()
        agentStore.markGatewayDisconnected()
        workspaceManager.resetConfiguration()
        state = .idle
    }

    private func performBootstrap() async throws {
        await profileStore.loadIfNeeded()

        switch profileStore.status {
        case .ready:
            break
        case .needsLegacyMigration:
            throw NSError(domain: "AppBootstrapCoordinator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "请先完成旧单实例迁移选择"
            ])
        case .loading:
            throw NSError(domain: "AppBootstrapCoordinator", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Profile 正在加载中"
            ])
        case .failed(let message):
            throw NSError(domain: "AppBootstrapCoordinator", code: 3, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }

        guard let selectedProfile = profileStore.selectedProfile,
              let selectedResolution = profileStore.selectedResolution else {
            throw NSError(domain: "AppBootstrapCoordinator", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "未找到当前 profile"
            ])
        }

        await envChecker.check()
        if case .missing(let reason) = envChecker.status {
            throw NSError(domain: "AppBootstrapCoordinator", code: 5, userInfo: [
                NSLocalizedDescriptionKey: reason
            ])
        }

        supervisorClient.connect()
        guard await supervisorClient.waitUntilConnected() else {
            throw NSError(domain: "AppBootstrapCoordinator", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "EZRWorkerSupervisor 未就绪"
            ])
        }

        processManager.bind(profileStore: profileStore, supervisorClient: supervisorClient)

        _ = await supervisorClient.reloadProfiles()

        var runtimes = try await supervisorClient.listProfilesRuntime()
        var runtime = runtimes.first(where: { $0.profileID == selectedProfile.id })

        if runtime?.readyState != .ready {
            try await supervisorClient.startProfile(profileID: selectedProfile.id)
            runtimes = try await supervisorClient.listProfilesRuntime()
            runtime = runtimes.first(where: { $0.profileID == selectedProfile.id })
        }

        guard let runtime else {
            throw NSError(domain: "AppBootstrapCoordinator", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Supervisor 未返回当前 profile 运行态"
            ])
        }

        let currentUsername = NSUserName()
        workspaceManager.configure(profile: selectedResolution)

        let configURLs = selectedResolution.localPaths.configSnapshotURLs
        guard let token = await Self.waitForGatewayToken(configURLs: configURLs) else {
            throw NSError(domain: "AppBootstrapCoordinator", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Gateway 已启动，但当前 profile 的 gateway token 尚未写入配置"
            ])
        }

        await gatewayService.reconfigure(port: runtime.resolvedPort, token: token)
        if await Self.connectGatewayService(gatewayService: gatewayService) {
            await completeGatewayDependentStartup(currentUsername: currentUsername)
        } else {
            appLog("bootstrap: gateway control connection deferred; reconnect loop will continue", level: .warn)
        }
        await processManager.refreshRuntimeState()
    }

    private func resetRuntimeState() async {
        await gatewayService.disconnect()
        processManager.prepareForAppTermination()
        agentStore.markGatewayDisconnected()
        workspaceManager.resetConfiguration()
        gatewayDependentStartupCompleted = false
    }

    private func startReconnectLoop() {
        stopReconnectLoop()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                if self.processManager.isRunning && !self.gatewayService.isConnected {
                    await self.processManager.refreshRuntimeState()
                    if await Self.connectGatewayService(gatewayService: self.gatewayService) {
                        await self.completeGatewayDependentStartup(currentUsername: NSUserName())
                    }
                } else if self.gatewayService.isConnected {
                    await self.completeGatewayDependentStartup(currentUsername: NSUserName())
                }
            }
        }
    }

    private func stopReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func completeGatewayDependentStartup(currentUsername: String) async {
        guard gatewayService.isConnected, !gatewayDependentStartupCompleted else { return }
        gatewayDependentStartupCompleted = true

        await Self.provisionDefaultMiniMaxModelIfNeeded(
            gatewayService: gatewayService,
            keychainStore: keychainStore
        )

        await agentStore.load(
            gateway: gatewayService,
            workspaceManager: workspaceManager,
            username: currentUsername
        )
        await agentStore.migrateIfNeeded()

        modelStore.load()
    }

    private static func connectGatewayService(
        gatewayService: GatewayService
    ) async -> Bool {
        for attempt in 1...3 {
            await gatewayService.connect()
            if gatewayService.isConnected {
                appLog("bootstrap: connected to current profile gateway on attempt \(attempt)")
                return true
            }
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        appLog("bootstrap: failed to connect current profile gateway", level: .error)
        return false
    }

    private static func readGatewayToken(configURL: URL) -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private static func waitForGatewayToken(configURLs: [URL]) async -> String? {
        for configURL in configURLs {
            if let token = readGatewayToken(configURL: configURL) {
                return token
            }
        }

        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            for configURL in configURLs {
                if let token = readGatewayToken(configURL: configURL) {
                    return token
                }
            }
        }

        let paths = configURLs.map(\.path).joined(separator: ", ")
        appLog("bootstrap: gateway token did not appear in \(paths)", level: .error)
        return nil
    }

    private static func provisionDefaultMiniMaxModelIfNeeded(
        gatewayService: GatewayService,
        keychainStore: ProviderKeychainStore
    ) async {
        guard gatewayService.isConnected else { return }

        do {
            let (config, baseHash) = try await gatewayService.configGetFull()

            let models = config["models"] as? [String: Any]
            let providers = models?["providers"] as? [String: Any]
            let minimax = providers?["minimax"] as? [String: Any]
            let existingModels = minimax?["models"] as? [[String: Any]] ?? []

            let hasDefaultModel = existingModels.contains { entry in
                (entry["id"] as? String) == "MiniMax-Text-01"
            }

            if !hasDefaultModel {
                var updatedProviders = providers ?? [:]
                updatedProviders["minimax"] = [
                    "enabled": true,
                    "apiKey": keychainStore.read(forProvider: "minimax") ?? "",
                    "models": [
                        [
                            "id": "MiniMax-Text-01",
                            "name": "MiniMax-Text-01",
                        ]
                    ]
                ]

                let patch: [String: Any] = [
                    "models": [
                        "providers": updatedProviders
                    ]
                ]
                _ = try await gatewayService.configPatch(
                    patch: patch,
                    baseHash: baseHash,
                    note: "初始化默认 MiniMax 模型"
                )
            }
        } catch {
            appLog("bootstrap: provision default model failed: \(error)", level: .warn)
        }
    }
}
