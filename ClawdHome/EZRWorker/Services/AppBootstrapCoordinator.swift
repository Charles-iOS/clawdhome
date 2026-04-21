import AppKit
import Foundation
import Observation

private let bootstrapMiniMaxAPIKeyCoordinator = "sk-cp-fpa22Na3FtFB33pyJq99D5vpTrGDxsX6PwA2HXp2Ro1p3HycWv-oXl5kb0tIq6xVWq5xQgI3QmIySPU4gWTtNSb7-wrXg6tjgNhP-gMM182Dz0K4kiXeko4"

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

    @ObservationIgnored
    private let startWork: @MainActor () async throws -> Void
    @ObservationIgnored
    private let resetWork: @MainActor () async -> Void
    @ObservationIgnored
    private let terminationWork: @MainActor () -> Void
    @ObservationIgnored
    private let reconnectShouldRun: @MainActor () -> Bool
    @ObservationIgnored
    private let reconnectWork: @MainActor () async -> Void

    @ObservationIgnored
    private var reconnectTask: Task<Void, Never>?

    init(
        startWork: @escaping @MainActor () async throws -> Void,
        resetWork: @escaping @MainActor () async -> Void,
        terminationWork: @escaping @MainActor () -> Void,
        reconnectShouldRun: @escaping @MainActor () -> Bool = { false },
        reconnectWork: @escaping @MainActor () async -> Void = {}
    ) {
        self.startWork = startWork
        self.resetWork = resetWork
        self.terminationWork = terminationWork
        self.reconnectShouldRun = reconnectShouldRun
        self.reconnectWork = reconnectWork
    }

    convenience init(
        processManager: GatewayProcessManager,
        envChecker: EnvironmentChecker,
        gatewayService: GatewayService,
        agentStore: AgentStore,
        workspaceManager: AgentWorkspaceManager,
        keychainStore: ProviderKeychainStore,
        helperClient: HelperClient,
        shrimpPool: ShrimpPool,
        modelStore: GlobalModelStore
    ) {
        self.init(
            startWork: {
                try await Self.performBootstrap(
                    processManager: processManager,
                    envChecker: envChecker,
                    gatewayService: gatewayService,
                    agentStore: agentStore,
                    workspaceManager: workspaceManager,
                    keychainStore: keychainStore,
                    helperClient: helperClient,
                    shrimpPool: shrimpPool,
                    modelStore: modelStore
                )
            },
            resetWork: {
                await gatewayService.disconnect()
                helperClient.disconnect()
                processManager.prepareForAppTermination()
                shrimpPool.stop()
                agentStore.markGatewayDisconnected()
            },
            terminationWork: {
                processManager.prepareForAppTermination()
                helperClient.disconnect()
                gatewayService.prepareForAppTermination()
                shrimpPool.stop()
                agentStore.markGatewayDisconnected()
            },
            reconnectShouldRun: {
                processManager.isRunning && !gatewayService.isConnected
            },
            reconnectWork: {
                await Self.connectGatewayService(
                    gatewayService: gatewayService,
                    configURL: GatewayProcessManager.openClawConfigDir.appendingPathComponent("openclaw.json")
                )
            }
        )
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
            try await startWork()
            state = .started
            startReconnectLoop()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func resetForUnauthenticated() async {
        stopReconnectLoop()
        await resetWork()
        state = .idle
    }

    func prepareForAppTermination() {
        stopReconnectLoop()
        terminationWork()
        state = .idle
    }

    private func startReconnectLoop() {
        stopReconnectLoop()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                if self.reconnectShouldRun() {
                    appLog("bootstrap: reconnect loop detected disconnected gateway, retrying...")
                    await self.reconnectWork()
                }
            }
        }
    }

    private func stopReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private static func performBootstrap(
        processManager: GatewayProcessManager,
        envChecker: EnvironmentChecker,
        gatewayService: GatewayService,
        agentStore: AgentStore,
        workspaceManager: AgentWorkspaceManager,
        keychainStore: ProviderKeychainStore,
        helperClient: HelperClient,
        shrimpPool: ShrimpPool,
        modelStore: GlobalModelStore
    ) async throws {
        let currentUsername = NSUserName()
        workspaceManager.configure(helperClient: helperClient, username: currentUsername)

        await envChecker.check()

        if envChecker.isReady {
            processManager.start()

            for _ in 0..<30 {
                if processManager.isRunning { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        let gatewayReady: Bool
        if processManager.isRunning {
            appLog("bootstrap: processManager already running")
            gatewayReady = true
        } else {
            appLog("bootstrap: processManager not running, probing port \(processManager.gatewayPort)...")
            let (alive, ready) = await GatewayClient.httpProbe(port: processManager.gatewayPort)
            appLog("bootstrap: probe result alive=\(alive) ready=\(ready)")
            gatewayReady = ready
        }

        if gatewayReady {
            await connectGatewayService(
                gatewayService: gatewayService,
                configURL: GatewayProcessManager.openClawConfigDir.appendingPathComponent("openclaw.json")
            )
            await provisionDefaultMiniMaxModelIfNeeded(
                gatewayService: gatewayService,
                keychainStore: keychainStore
            )
        } else {
            appLog("bootstrap: gateway not ready, skipping WebSocket connect", level: .warn)
        }

        helperClient.connect()
        let helperReady = await helperClient.waitUntilConnected()
        if !helperReady {
            appLog("bootstrap: helper 连接未在预期时间内就绪，后续 workspace 探测将采用保守模式", level: .warn)
        }

        await agentStore.load(
            gateway: gatewayService,
            workspaceManager: workspaceManager,
            username: currentUsername
        )
        await agentStore.migrateIfNeeded()

        shrimpPool.start()
        modelStore.load()
    }

    private static func connectGatewayService(
        gatewayService: GatewayService,
        configURL: URL
    ) async {
        for attempt in 1...3 {
            if let token = readGatewayToken(configURL: configURL) {
                appLog("bootstrap: token=\(token.prefix(8))... attempt=\(attempt)")
                gatewayService.updateToken(token)
            } else {
                appLog("bootstrap: no token in config", level: .error)
            }
            await gatewayService.connect()
            if gatewayService.isConnected {
                appLog("bootstrap: connected on attempt \(attempt)")
                return
            }
            appLog("bootstrap: attempt \(attempt) failed", level: .warn)
            if attempt < 3 {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
        appLog("bootstrap: connect failed after retries", level: .error)
    }

    private static func readGatewayToken(configURL: URL) -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String else {
            return nil
        }
        return token
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
            let existingMiniMaxAPIKey = minimax?["apiKey"] as? String

            let currentPrimaryModel = ((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])
                .flatMap { $0["model"] as? [String: Any] }?["primary"] as? String

            let keychainMiniMaxAPIKey = keychainStore
                .read(forProvider: "minimax")?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let effectiveMiniMaxAPIKey: String
            if let keychainMiniMaxAPIKey, !keychainMiniMaxAPIKey.isEmpty {
                effectiveMiniMaxAPIKey = keychainMiniMaxAPIKey
            } else {
                effectiveMiniMaxAPIKey = bootstrapMiniMaxAPIKeyCoordinator
            }

            let minimaxProviderPatch: [String: Any] = [
                "api": "anthropic-messages",
                "baseUrl": "https://api.minimaxi.com/anthropic",
                "authHeader": true,
                "models": minimaxOpenClawModelCatalog,
                "apiKey": effectiveMiniMaxAPIKey
            ]

            var patch: [String: Any] = [:]

            if minimax == nil || existingMiniMaxAPIKey?.isEmpty != false {
                patch["models"] = [
                    "mode": "merge",
                    "providers": [
                        "minimax": minimaxProviderPatch
                    ]
                ]
            }

            if currentPrimaryModel == nil || currentPrimaryModel?.isEmpty == true {
                let existingFallbacks = (((config["agents"] as? [String: Any])?["defaults"] as? [String: Any])?["model"] as? [String: Any])?["fallbacks"]
                var modelPatch: [String: Any] = ["primary": defaultMiniMaxModelId]
                if let existingFallbacks {
                    modelPatch["fallbacks"] = existingFallbacks
                }

                var agentsPatch = (patch["agents"] as? [String: Any]) ?? [:]
                var defaultsPatch = (agentsPatch["defaults"] as? [String: Any]) ?? [:]
                defaultsPatch["model"] = modelPatch
                defaultsPatch["models"] = [
                    defaultMiniMaxModelId: ["alias": "Minimax"]
                ]
                agentsPatch["defaults"] = defaultsPatch
                patch["agents"] = agentsPatch
            }

            guard !patch.isEmpty else { return }

            _ = try await gatewayService.configPatch(
                patch: patch,
                baseHash: baseHash,
                note: "ClawdHome: auto provision default MiniMax model"
            )
        } catch {
            appLog("bootstrap: auto provision default MiniMax model failed: \(error)", level: .warn)
        }
    }
}
