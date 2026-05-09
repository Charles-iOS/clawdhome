import Foundation
import Observation

private let appBootstrapGatewayReadyWaitAttempts = 180
private let appBootstrapGatewayUnavailableConfirmAttempts = 3
private let appBootstrapGatewayProbeIntervalNanoseconds: UInt64 = 1_000_000_000

@MainActor
@Observable
final class AppBootstrapCoordinator {
    enum State: Equatable {
        case idle
        case starting
        case started
        case failed(String)
    }

    enum RecoveryTrigger: String {
        case reconnectLoop = "reconnect-loop"
        case appActivated = "app-activated"
        case systemWake = "system-wake"
        case screenUnlocked = "screen-unlocked"
    }

    private enum GatewayRecoveryMode: Equatable {
        case reconnectOnly
        case conservativeStart
    }

    enum ProgressStepID: String, CaseIterable {
        case profile
        case environment
        case supervisor
        case runtime
        case gateway
        case token
        case connection
        case workspace
    }

    enum ProgressStepStatus: Equatable {
        case pending
        case active
        case completed
        case failed
    }

    struct ProgressStep: Identifiable, Equatable {
        let id: ProgressStepID
        let title: String
        var status: ProgressStepStatus
        var detail: String?
    }

    struct ProgressSnapshot: Equatable {
        var steps: [ProgressStep]
        var currentStepID: ProgressStepID?
        var currentDetail: String

        static func initial() -> ProgressSnapshot {
            ProgressSnapshot(
                steps: [
                    ProgressStep(id: .profile, title: "读取员工配置", status: .pending),
                    ProgressStep(id: .environment, title: "检查运行环境", status: .pending),
                    ProgressStep(id: .supervisor, title: "连接本地守护进程", status: .pending),
                    ProgressStep(id: .runtime, title: "同步运行状态", status: .pending),
                    ProgressStep(id: .gateway, title: "检查 Gateway", status: .pending),
                    ProgressStep(id: .token, title: "读取认证令牌", status: .pending),
                    ProgressStep(id: .connection, title: "连接本地服务", status: .pending),
                    ProgressStep(id: .workspace, title: "加载工作区数据", status: .pending),
                ],
                currentStepID: nil,
                currentDetail: "准备开始初始化。"
            )
        }

        func activating(_ id: ProgressStepID, detail: String) -> ProgressSnapshot {
            var copy = self
            let activeIndex = copy.steps.firstIndex(where: { $0.id == id })
            for index in copy.steps.indices {
                let status: ProgressStepStatus
                if let activeIndex {
                    if index < activeIndex {
                        status = .completed
                    } else if index == activeIndex {
                        status = .active
                    } else {
                        status = .pending
                    }
                } else {
                    status = copy.steps[index].status
                }
                copy.steps[index].status = status
                copy.steps[index].detail = status == .active ? detail : nil
            }
            copy.currentStepID = id
            copy.currentDetail = detail
            return copy
        }

        func completingAll(detail: String) -> ProgressSnapshot {
            var copy = self
            for index in copy.steps.indices {
                copy.steps[index].status = .completed
                copy.steps[index].detail = nil
            }
            copy.currentStepID = nil
            copy.currentDetail = detail
            return copy
        }

        func failing(detail: String) -> ProgressSnapshot {
            var copy = self
            var failedIndex = copy.currentStepID.flatMap { id in
                copy.steps.firstIndex(where: { $0.id == id })
            }
            if failedIndex == nil {
                failedIndex = copy.steps.firstIndex(where: { $0.status == .active })
            }
            if let failedIndex {
                copy.steps[failedIndex].status = .failed
                copy.steps[failedIndex].detail = detail
            }
            copy.currentDetail = detail
            return copy
        }
    }

    private(set) var state: State = .idle
    private(set) var progress = ProgressSnapshot.initial()

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
    private var recoveryTask: Task<Void, Never>?
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

        progress = ProgressSnapshot.initial()
        state = .starting
        do {
            try await performBootstrap()
            progress = progress.completingAll(detail: "初始化完成。")
            state = .started
            startReconnectLoop()
        } catch {
            progress = progress.failing(detail: error.localizedDescription)
            state = .failed(error.localizedDescription)
        }
    }

    func restartForProfileSwitch() async {
        stopReconnectLoop()
        await resetRuntimeState()
        state = .idle
        progress = ProgressSnapshot.initial()
        await startIfNeeded()
    }

    func resetForUnauthenticated() async {
        stopReconnectLoop()
        await resetRuntimeState()
        state = .idle
        progress = ProgressSnapshot.initial()
    }

    func prepareForAppTermination() {
        stopReconnectLoop()
        recoveryTask?.cancel()
        recoveryTask = nil
        processManager.prepareForAppTermination()
        gatewayService.prepareForAppTermination()
        agentStore.markGatewayDisconnected()
        workspaceManager.resetConfiguration()
        state = .idle
        progress = ProgressSnapshot.initial()
    }

    private func performBootstrap() async throws {
        updateProgress(.profile, detail: "正在读取当前员工 Profile 和本地配置。")
        await profileStore.loadIfNeeded()

        switch profileStore.status {
        case .ready:
            break
        case .needsLegacyMigration:
            throw NSError(domain: "AppBootstrapCoordinator", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "请先完成旧单实例迁移选择"
            ])
        case .needsExistingOpenClawImport:
            throw NSError(domain: "AppBootstrapCoordinator", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "请先选择要导入的既有 OpenClaw 实例"
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

        updateProgress(.environment, detail: "正在检查内置 Node/OpenClaw 运行环境。")
        await envChecker.check()
        if case .missing(let reason) = envChecker.status {
            throw NSError(domain: "AppBootstrapCoordinator", code: 5, userInfo: [
                NSLocalizedDescriptionKey: reason
            ])
        }

        updateProgress(.supervisor, detail: "正在连接 EZRWorkerSupervisor 本地守护进程。")
        supervisorClient.connect()
        let supervisorConnected = await supervisorClient.waitUntilConnected()

        processManager.bind(profileStore: profileStore, supervisorClient: supervisorClient)

        updateProgress(.runtime, detail: "正在同步员工 Profile 和 Gateway 运行状态。")
        let runtime: SupervisorProfileRuntime
        if supervisorConnected {
            _ = await supervisorClient.reloadProfiles()

            let runtimes = try await supervisorClient.listProfilesRuntime()
            let initialRuntime = runtimes.first(where: { $0.profileID == selectedProfile.id })
            runtime = try await resolveBootstrapRuntime(
                profile: selectedProfile,
                resolution: selectedResolution,
                initialRuntime: initialRuntime
            )
        } else {
            updateProgress(.runtime, detail: "Supervisor 暂未就绪，先尝试直连当前 Gateway。")
            appLog("bootstrap: supervisor unavailable during login; trying direct gateway connection", level: .warn)
            runtime = syntheticRuntime(
                profile: selectedProfile,
                resolution: selectedResolution,
                readyState: .unknown,
                healthState: .unknown
            )
        }

        let currentUsername = NSUserName()
        workspaceManager.configure(profile: selectedResolution)

        updateProgress(.token, detail: "正在读取当前 Gateway 的本地认证令牌。")
        let configURLs = selectedResolution.localPaths.configSnapshotURLs
        guard let token = await Self.waitForGatewayToken(configURLs: configURLs) else {
            throw NSError(domain: "AppBootstrapCoordinator", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Gateway 已启动，但当前 profile 的 gateway token 尚未写入配置"
            ])
        }

        updateProgress(.connection, detail: "正在连接 Gateway 控制接口 \(runtime.resolvedPort)。")
        await gatewayService.reconfigure(port: runtime.resolvedPort, token: token)
        if await Self.connectGatewayService(gatewayService: gatewayService) {
            updateProgress(.workspace, detail: "正在加载员工、模型和工作区数据。")
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

    private func updateProgress(_ stepID: ProgressStepID, detail: String) {
        progress = progress.activating(stepID, detail: detail)
    }

    private func startProfileWithProgressTracking(profileID: UUID) async throws {
        let operationTask = Task { [supervisorClient] in
            try await supervisorClient.startProfile(profileID: profileID)
        }
        let progressTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let runtime = await self.selectedRuntime(profileID: profileID)
                await self.applySupervisorRuntimeProgress(runtime)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        do {
            try await operationTask.value
        } catch {
            progressTask.cancel()
            throw error
        }

        progressTask.cancel()
        let runtime = await selectedRuntime(profileID: profileID)
        applySupervisorRuntimeProgress(runtime)
    }

    private func resolveBootstrapRuntime(
        profile: GatewayProfile,
        resolution: GatewayProfileResolution,
        initialRuntime: SupervisorProfileRuntime?
    ) async throws -> SupervisorProfileRuntime {
        let profileID = profile.id

        guard let initialRuntime else {
            updateProgress(.gateway, detail: "正在确认当前 Gateway 是否已在后台运行。")
            return try await startGatewayIfConfirmedUnavailable(
                profile: profile,
                resolution: resolution,
                lastKnownRuntime: nil
            )
        }

        if initialRuntime.healthState == .unresponsive {
            appLog(
                "bootstrap: initial runtime unresponsive deferred to supervisor profile=\(profile.slug) port=\(initialRuntime.resolvedPort)",
                level: .warn
            )
            updateProgress(
                .gateway,
                detail: runtimeProgressDetail(initialRuntime) ?? "Gateway 健康检查无响应，Supervisor 正在自动恢复。"
            )
            if let recoveredRuntime = await waitForGatewayRuntimeReady(profileID: profileID),
               recoveredRuntime.readyState != .failed,
               recoveredRuntime.healthState != .failed {
                return recoveredRuntime
            }
            return await selectedRuntime(profileID: profileID) ?? initialRuntime
        }

        switch initialRuntime.readyState {
        case .ready:
            updateProgress(.gateway, detail: "Gateway 已在后台运行，准备连接本地服务。")
            return initialRuntime

        case .preparing, .starting:
            updateProgress(
                .gateway,
                detail: runtimeProgressDetail(initialRuntime) ?? "Gateway 正在启动，等待本地服务就绪。"
            )
            if let refreshedRuntime = await waitForGatewayRuntimeReady(profileID: profileID) {
                if refreshedRuntime.readyState == .failed {
                    let message = refreshedRuntime.lastError ?? "Gateway 启动失败。"
                    throw NSError(domain: "AppBootstrapCoordinator", code: 11, userInfo: [
                        NSLocalizedDescriptionKey: message
                    ])
                }
                return refreshedRuntime
            }
            return await selectedRuntime(profileID: profileID) ?? initialRuntime

        case .stopped, .unknown:
            return try await startGatewayIfConfirmedUnavailable(
                profile: profile,
                resolution: resolution,
                lastKnownRuntime: initialRuntime
            )

        case .failed:
            let probe = await GatewayClient.httpProbe(port: initialRuntime.resolvedPort)
            if probe.alive {
                updateProgress(.gateway, detail: "Gateway 端口仍有响应，先尝试重新连接控制接口。")
                return initialRuntime
            }

            let message = initialRuntime.lastError ?? "Gateway 运行态异常，请在设置页检查后手动启动或重启。"
            updateProgress(.gateway, detail: message)
            throw NSError(domain: "AppBootstrapCoordinator", code: 10, userInfo: [
                NSLocalizedDescriptionKey: message
            ])
        }
    }

    private func startGatewayIfConfirmedUnavailable(
        profile: GatewayProfile,
        resolution: GatewayProfileResolution,
        lastKnownRuntime: SupervisorProfileRuntime?
    ) async throws -> SupervisorProfileRuntime {
        let port = lastKnownRuntime?.resolvedPort ?? resolution.resolvedPort

        if lastKnownRuntime?.userStoppedAt != nil {
            updateProgress(.gateway, detail: "当前 Gateway 已由用户手动停止，本次登录不会自动启动。")
            return lastKnownRuntime ?? syntheticRuntime(
                profile: profile,
                resolution: resolution,
                readyState: .stopped,
                healthState: .noProcess
            )
        }

        if profile.managementMode != .managedByEZRWorker {
            updateProgress(.gateway, detail: "当前 Profile 为仅观察模式，等待外部 Gateway 在端口 \(port) 上运行。")
            return lastKnownRuntime ?? syntheticRuntime(
                profile: profile,
                resolution: resolution,
                readyState: .stopped,
                healthState: .noProcess
            )
        }

        updateProgress(.gateway, detail: "正在确认端口 \(port) 是否已有 Gateway 响应。")
        let unavailable = await Self.confirmGatewayUnavailable(port: port)
        if !unavailable {
            updateProgress(.gateway, detail: "Gateway 端口已有响应，准备重新连接控制接口。")
            if let readyRuntime = await waitForGatewayRuntimeReady(profileID: profile.id, attempts: 8) {
                return readyRuntime
            }
            return await selectedRuntime(profileID: profile.id) ?? lastKnownRuntime ?? syntheticRuntime(
                profile: profile,
                resolution: resolution,
                readyState: .starting,
                healthState: .portListening,
                isPrepared: true,
                isRunning: true,
                ownership: .adopted,
                lastProbeAt: Date()
            )
        }

        updateProgress(.gateway, detail: "Gateway 未运行，正在由 Supervisor 拉起本地服务。")
        try await startProfileWithProgressTracking(profileID: profile.id)
        guard let runtime = await selectedRuntime(profileID: profile.id) else {
            throw NSError(domain: "AppBootstrapCoordinator", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Supervisor 未返回当前 profile 运行态"
            ])
        }
        return runtime
    }

    private func syntheticRuntime(
        profile: GatewayProfile,
        resolution: GatewayProfileResolution,
        readyState: SupervisorReadyState,
        healthState: SupervisorHealthState,
        isPrepared: Bool = false,
        isRunning: Bool = false,
        pid: Int32? = nil,
        ownership: SupervisorOwnership = .none,
        lastProbeAt: Date? = nil,
        lastError: String? = nil,
        lastLifecycleMessage: String? = nil
    ) -> SupervisorProfileRuntime {
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
            healthState: healthState,
            lastError: lastError,
            lastLifecycleMessage: lastLifecycleMessage
        )
    }

    private func waitForGatewayRuntimeReady(
        profileID: UUID,
        attempts: Int = appBootstrapGatewayReadyWaitAttempts
    ) async -> SupervisorProfileRuntime? {
        for _ in 0..<attempts {
            if Task.isCancelled { return nil }
            if let runtime = await selectedRuntime(profileID: profileID) {
                applySupervisorRuntimeProgress(runtime)
                if runtime.readyState == .ready || runtime.healthState == .healthy {
                    return runtime
                }
                if runtime.readyState == .failed || runtime.healthState == .failed || runtime.healthState == .unresponsive {
                    return runtime
                }
            } else {
                updateProgress(.gateway, detail: "正在等待 Supervisor 返回当前 Gateway 状态。")
            }
            try? await Task.sleep(nanoseconds: appBootstrapGatewayProbeIntervalNanoseconds)
        }
        return await selectedRuntime(profileID: profileID)
    }

    private func applySupervisorRuntimeProgress(_ runtime: SupervisorProfileRuntime?) {
        guard let runtime else {
            updateProgress(.gateway, detail: "正在等待 Supervisor 返回当前 Gateway 状态。")
            return
        }
        updateProgress(.gateway, detail: runtimeProgressDetail(runtime) ?? "正在启动当前员工的 Gateway。")
    }

    private func runtimeProgressDetail(_ runtime: SupervisorProfileRuntime?) -> String? {
        guard let runtime else { return nil }
        if let message = runtime.lastLifecycleMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        switch runtime.healthState {
        case .healthy:
            return "Gateway 已就绪。"
        case .unresponsive:
            return runtime.lastUnhealthyReason == nil
                ? "Gateway 进程运行中，但健康检查无响应。"
                : "Gateway 进程运行中，但健康检查无响应：\(runtime.lastUnhealthyReason ?? "")"
        case .portListening:
            return "Gateway 已监听端口 \(runtime.resolvedPort)，正在等待健康检查。"
        case .launching:
            if let pid = runtime.pid {
                return "Gateway 进程 PID \(pid) 已启动，正在等待端口 \(runtime.resolvedPort) 就绪。"
            }
            return "正在等待 Gateway 打开本地端口 \(runtime.resolvedPort)。"
        case .noProcess, .failed, .unknown:
            break
        }

        switch runtime.readyState {
        case .unknown:
            return "正在读取 Gateway 运行状态。"
        case .stopped:
            return "Gateway 尚未启动，准备拉起本地服务。"
        case .preparing:
            return "正在准备 Gateway 配置和工作区。"
        case .starting:
            if let pid = runtime.pid {
                return "Gateway 进程 PID \(pid) 已启动，正在等待端口 \(runtime.resolvedPort) 就绪。"
            }
            return "正在等待 Gateway 打开本地端口 \(runtime.resolvedPort)。"
        case .ready:
            return "Gateway 已就绪。"
        case .failed:
            return runtime.lastError ?? "Gateway 启动失败。"
        }
    }

    private func startReconnectLoop() {
        stopReconnectLoop()
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                if !self.gatewayService.isConnected {
                    await self.recoverGatewayAfterInterruption(trigger: .reconnectLoop)
                } else {
                    await self.completeGatewayDependentStartup(currentUsername: NSUserName())
                }
            }
        }
    }

    private func stopReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func recoverGatewayAfterInterruption(trigger: RecoveryTrigger) async {
        if let recoveryTask {
            await recoveryTask.value
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performGatewayRecovery(trigger: trigger)
        }
        recoveryTask = task
        await task.value
        recoveryTask = nil
    }

    private func performGatewayRecovery(trigger: RecoveryTrigger) async {
        if trigger != .reconnectLoop {
            appLog("bootstrap: recovery triggered by \(trigger.rawValue)")
        }
        let mode = recoveryMode(for: trigger)

        await profileStore.loadIfNeeded()
        guard profileStore.canBootstrap else {
            if trigger != .reconnectLoop {
                appLog("bootstrap: recovery skipped; profile store is not bootstrappable", level: .warn)
            }
            return
        }

        switch state {
        case .idle, .failed:
            if state != .idle, mode == .reconnectOnly {
                appLog("bootstrap: recovery skipped startIfNeeded for reconnect-only trigger \(trigger.rawValue)")
                return
            }
            await startIfNeeded()
            return
        case .starting:
            return
        case .started:
            break
        }

        guard let selectedProfile = profileStore.selectedProfile,
              let selectedResolution = profileStore.selectedResolution else {
            return
        }

        guard await ensureSupervisorConnected() else {
            let fallbackPort = gatewayService.port
            appLog(
                "bootstrap: supervisor unavailable; trying direct gateway reconnect on port \(fallbackPort)",
                level: .warn
            )
            if await reconnectGatewayService(
                resolution: selectedResolution,
                port: fallbackPort,
                logFailure: trigger != .reconnectLoop
            ) {
                await completeGatewayDependentStartup(currentUsername: NSUserName())
                return
            }
            appLog("bootstrap: recovery failed; supervisor is not connected", level: .error)
            return
        }

        _ = await supervisorClient.reloadProfiles()
        var runtime = await selectedRuntime(profileID: selectedProfile.id)
        var resolvedPort = runtime?.resolvedPort ?? selectedResolution.resolvedPort

        if let runtime, runtimeIsPendingStartup(runtime) {
            appLog(
                "bootstrap: recovery waiting for current gateway startup profile=\(selectedProfile.slug) port=\(resolvedPort)"
            )
            await processManager.refreshRuntimeState()
            return
        }

        if await reconnectGatewayService(
            resolution: selectedResolution,
            port: resolvedPort,
            logFailure: trigger != .reconnectLoop
        ) {
            await completeGatewayDependentStartup(currentUsername: NSUserName())
            await processManager.refreshRuntimeState()
            return
        }

        await gatewayService.disconnect()
        agentStore.markGatewayDisconnected()
        gatewayDependentStartupCompleted = false

        if mode == .reconnectOnly {
            appLog(
                "bootstrap: reconnect-only recovery left gateway disconnected profile=\(selectedProfile.slug) port=\(resolvedPort)",
                level: .warn
            )
            await processManager.refreshRuntimeState()
            return
        }

        guard await Self.confirmGatewayUnavailable(
            port: resolvedPort,
            attempts: appBootstrapGatewayUnavailableConfirmAttempts
        ) else {
            appLog(
                "bootstrap: recovery skipped lifecycle operation; port still responds profile=\(selectedProfile.slug) port=\(resolvedPort)",
                level: .warn
            )
            await processManager.refreshRuntimeState()
            return
        }

        runtime = await selectedRuntime(profileID: selectedProfile.id)
        resolvedPort = runtime?.resolvedPort ?? resolvedPort

        guard selectedProfile.managementMode == .managedByEZRWorker else {
            appLog(
                "bootstrap: recovery skipped start; profile is observe-only profile=\(selectedProfile.slug) port=\(resolvedPort)",
                level: .warn
            )
            await processManager.refreshRuntimeState()
            return
        }

        if runtime?.userStoppedAt != nil {
            appLog(
                "bootstrap: recovery skipped lifecycle operation; gateway was manually stopped profile=\(selectedProfile.slug) port=\(resolvedPort)",
                level: .warn
            )
            await processManager.refreshRuntimeState()
            return
        }

        switch runtime?.healthState {
        case .noProcess:
            do {
                appLog(
                    "bootstrap: recovery starting current gateway profile=\(selectedProfile.slug) port=\(resolvedPort)"
                )
                try await supervisorClient.startProfile(profileID: selectedProfile.id)
            } catch {
                appLog("bootstrap: recovery start failed: \(error.localizedDescription)", level: .error)
            }
        case .unresponsive:
            appLog(
                "bootstrap: recovery deferred to supervisor for unresponsive runtime profile=\(selectedProfile.slug) port=\(resolvedPort)",
                level: .warn
            )
        case .launching, .portListening:
            appLog(
                "bootstrap: recovery skipped lifecycle operation; gateway is still \(runtime?.healthState.rawValue ?? "starting") profile=\(selectedProfile.slug) port=\(resolvedPort)"
            )
        case .healthy:
            appLog(
                "bootstrap: recovery skipped restart for healthy runtime on unavailable port profile=\(selectedProfile.slug) port=\(resolvedPort)",
                level: .warn
            )
        case .failed:
            let message = runtime?.lastError ?? "unknown"
            appLog(
                "bootstrap: recovery deferred to supervisor for failed runtime profile=\(selectedProfile.slug) port=\(resolvedPort) message=\(message)",
                level: .warn
            )
        case .unknown, nil:
            switch runtime?.readyState {
            case .stopped, .unknown, nil:
                do {
                    appLog(
                        "bootstrap: recovery starting current gateway profile=\(selectedProfile.slug) port=\(resolvedPort)"
                    )
                    try await supervisorClient.startProfile(profileID: selectedProfile.id)
                } catch {
                    appLog("bootstrap: recovery start failed: \(error.localizedDescription)", level: .error)
                }
            case .preparing, .starting:
                appLog(
                    "bootstrap: recovery skipped start; gateway is already \(runtime?.readyState.rawValue ?? "starting") profile=\(selectedProfile.slug) port=\(resolvedPort)"
                )
            case .ready:
                appLog(
                    "bootstrap: recovery skipped restart for ready runtime profile=\(selectedProfile.slug) port=\(resolvedPort)",
                    level: .warn
                )
            case .failed:
                let message = runtime?.lastError ?? "unknown"
                appLog(
                    "bootstrap: recovery deferred to supervisor for failed runtime profile=\(selectedProfile.slug) port=\(resolvedPort) message=\(message)",
                    level: .warn
                )
            }
        }

        await processManager.refreshRuntimeState()
    }

    private func runtimeIsPendingStartup(_ runtime: SupervisorProfileRuntime) -> Bool {
        switch runtime.healthState {
        case .launching, .portListening:
            return true
        case .unresponsive:
            return false
        case .healthy, .failed, .noProcess, .unknown:
            break
        }

        return runtime.readyState == .preparing || runtime.readyState == .starting
    }

    private func recoveryMode(for trigger: RecoveryTrigger) -> GatewayRecoveryMode {
        switch trigger {
        case .appActivated, .screenUnlocked:
            return .reconnectOnly
        case .systemWake, .reconnectLoop:
            return .conservativeStart
        }
    }

    private func reconnectGatewayService(
        resolution: GatewayProfileResolution,
        port: Int,
        logFailure: Bool
    ) async -> Bool {
        guard let token = await Self.waitForGatewayToken(configURLs: resolution.localPaths.configSnapshotURLs) else {
            if logFailure {
                appLog("bootstrap: recovery failed; gateway token is unavailable", level: .error)
            }
            return false
        }

        await gatewayService.reconfigure(port: port, token: token)

        if gatewayService.isConnected {
            do {
                _ = try await gatewayService.request(method: "health")
                return true
            } catch {
                appLog("bootstrap: recovery detected stale gateway socket: \(error.localizedDescription)", level: .warn)
                await gatewayService.disconnect()
            }
        }

        return await Self.connectGatewayService(
            gatewayService: gatewayService,
            logFailure: logFailure
        )
    }

    private func ensureSupervisorConnected() async -> Bool {
        if supervisorClient.isConnected, await supervisorClient.ping() {
            return true
        }

        supervisorClient.connect()
        return await supervisorClient.waitUntilConnected()
    }

    private func selectedRuntime(profileID: UUID) async -> SupervisorProfileRuntime? {
        let runtimes = (try? await supervisorClient.listProfilesRuntime()) ?? []
        return runtimes.first(where: { $0.profileID == profileID })
    }

    private func completeGatewayDependentStartup(currentUsername: String) async {
        guard gatewayService.isConnected, !gatewayDependentStartupCompleted else { return }
        gatewayDependentStartupCompleted = true

        await Self.provisionMiniMaxCatalogIfNeeded(
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
        gatewayService: GatewayService,
        logFailure: Bool = true
    ) async -> Bool {
        for attempt in 1...6 {
            let probe = await gatewayService.httpProbe()
            guard probe.ready else {
                if logFailure {
                    appLog(
                        "bootstrap: gateway http not ready before websocket connect attempt \(attempt) alive=\(probe.alive) ready=\(probe.ready)",
                        level: .debug
                    )
                }
                if attempt < 6 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
                continue
            }

            await gatewayService.connect()
            if gatewayService.isConnected {
                appLog("bootstrap: connected to current profile gateway on attempt \(attempt)")
                return true
            }
            if attempt < 6 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        if logFailure {
            appLog("bootstrap: failed to connect current profile gateway", level: .error)
        }
        return false
    }

    private static func confirmGatewayUnavailable(
        port: Int,
        attempts: Int = appBootstrapGatewayUnavailableConfirmAttempts,
        intervalNanoseconds: UInt64 = appBootstrapGatewayProbeIntervalNanoseconds
    ) async -> Bool {
        for attempt in 1...max(1, attempts) {
            let probe = await GatewayClient.httpProbe(port: port)
            appLog(
                "bootstrap: probe \(attempt)/\(attempts) port \(port) alive=\(probe.alive) ready=\(probe.ready)",
                level: .debug
            )
            if probe.alive {
                return false
            }
            if attempt < attempts {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
        }
        return true
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

    private static func provisionMiniMaxCatalogIfNeeded(
        gatewayService: GatewayService,
        keychainStore: ProviderKeychainStore
    ) async {
        guard gatewayService.isConnected else { return }

        do {
            let (config, baseHash) = try await gatewayService.configGetFull()

            let models = config["models"] as? [String: Any]
            let providers = models?["providers"] as? [String: Any]
            let candidateProviderIds = ["minimax-cn", "minimax"]
            var providerPatches: [String: Any] = [:]

            for providerId in candidateProviderIds {
                guard let provider = providers?[providerId] as? [String: Any] else { continue }
                guard miniMaxCatalogNeedsProvisioning(provider) else { continue }
                guard let providerConfig = OpenClawProviderKeySync.staticConfig(for: providerId) else { continue }

                let modelIds = suggestedModelsForProvider(providerId).map(\.id)
                guard !modelIds.isEmpty else { continue }

                providerPatches[providerId] = providerConfig.makeProviderPayload(
                    secret: keychainStore.read(forProvider: providerId),
                    modelIds: modelIds
                )
            }

            if !providerPatches.isEmpty {
                _ = try await gatewayService.configPatch(
                    patch: [
                        "models": [
                            "mode": "merge",
                            "providers": providerPatches
                        ]
                    ],
                    baseHash: baseHash,
                    note: "补齐 MiniMax provider 模型目录"
                )
            }
        } catch {
            appLog("bootstrap: provision MiniMax catalog failed: \(error)", level: .warn)
        }
    }

    private static func miniMaxCatalogNeedsProvisioning(_ provider: [String: Any]) -> Bool {
        let existingModels = provider["models"] as? [[String: Any]] ?? []
        if existingModels.isEmpty {
            return true
        }

        let ids = Set(existingModels.compactMap { $0["id"] as? String })
        return ids == Set(["MiniMax-Text-01"])
    }
}
