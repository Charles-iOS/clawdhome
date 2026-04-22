import AppKit
import SwiftUI

final class EZRWorkerAppDelegate: NSObject, NSApplicationDelegate {
    var onWillTerminate: (() -> Void)?

    func application(_ app: NSApplication, shouldSaveApplicationState coder: NSCoder) -> Bool {
        false
    }

    func application(_ app: NSApplication, shouldRestoreApplicationState coder: NSCoder) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        onWillTerminate?()
    }
}

@main
struct EZRWorkerApp: App {
    @NSApplicationDelegateAdaptor(EZRWorkerAppDelegate.self) private var appDelegate

    @State private var processManager: GatewayProcessManager
    @State private var envChecker: EnvironmentChecker
    @State private var gatewayService: GatewayService
    @State private var agentStore: AgentStore
    @State private var workspaceManager: AgentWorkspaceManager
    @State private var keychainStore: ProviderKeychainStore
    @State private var legacyCompatibility: LegacyCompatibilityContainer
    @State private var updater: UpdateChecker
    @State private var modelStore: GlobalModelStore
    @State private var lockStore: AppLockStore
    @State private var maintenanceWindowRegistry: MaintenanceWindowRegistry
    @State private var authStore: AuthSessionStore
    @State private var profileStore: GatewayProfileStore
    @State private var supervisorClient: SupervisorClient
    @State private var bootstrapCoordinator: AppBootstrapCoordinator

    @AppStorage("appLanguage") private var appLanguageRaw = AppLanguage.system.rawValue

    init() {
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")

        let processManager = GatewayProcessManager()
        let envChecker = EnvironmentChecker()
        let gatewayService = GatewayService()
        let agentStore = AgentStore()
        let workspaceManager = AgentWorkspaceManager()
        let keychainStore = ProviderKeychainStore()
        let legacyCompatibility = LegacyCompatibilityContainer()
        let updater = UpdateChecker()
        let modelStore = GlobalModelStore()
        let lockStore = AppLockStore()
        let maintenanceWindowRegistry = MaintenanceWindowRegistry()
        let authStore = AuthSessionStore(apiClient: BackendAuthClient())
        let profileStore = GatewayProfileStore()
        let supervisorClient = SupervisorClient()
        let bootstrapCoordinator = AppBootstrapCoordinator(
            processManager: processManager,
            envChecker: envChecker,
            gatewayService: gatewayService,
            agentStore: agentStore,
            workspaceManager: workspaceManager,
            keychainStore: keychainStore,
            modelStore: modelStore,
            profileStore: profileStore,
            supervisorClient: supervisorClient
        )

        _processManager = State(initialValue: processManager)
        _envChecker = State(initialValue: envChecker)
        _gatewayService = State(initialValue: gatewayService)
        _agentStore = State(initialValue: agentStore)
        _workspaceManager = State(initialValue: workspaceManager)
        _keychainStore = State(initialValue: keychainStore)
        _legacyCompatibility = State(initialValue: legacyCompatibility)
        _updater = State(initialValue: updater)
        _modelStore = State(initialValue: modelStore)
        _lockStore = State(initialValue: lockStore)
        _maintenanceWindowRegistry = State(initialValue: maintenanceWindowRegistry)
        _authStore = State(initialValue: authStore)
        _profileStore = State(initialValue: profileStore)
        _supervisorClient = State(initialValue: supervisorClient)
        _bootstrapCoordinator = State(initialValue: bootstrapCoordinator)
    }

    var body: some Scene {
        let appLanguage = AppLanguage(rawValue: appLanguageRaw) ?? .system

        WindowGroup {
            AppRootGateView()
                .environment(processManager)
                .environment(envChecker)
                .environment(gatewayService)
                .environment(agentStore)
                .environment(workspaceManager)
                .environment(keychainStore)
                .environment(authStore)
                .environment(profileStore)
                .environment(supervisorClient)
                .environment(bootstrapCoordinator)
                .environment(\.locale, appLanguage.locale)
                .environment(updater)
                .environment(modelStore)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .task {
                    appDelegate.onWillTerminate = {
                        bootstrapCoordinator.prepareForAppTermination()
                        legacyCompatibility.prepareForAppTermination()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1280, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        WindowGroup(id: "claw-detail", for: String.self) { $username in
            if let name = username {
                AuthenticatedSceneGate {
                    LegacyCompatibilityScene(
                        container: legacyCompatibility,
                        includeGatewayHub: true
                    ) {
                        ClawDetailWindow(username: name)
                    }
                }
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(authStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
                .background(ClawDetailWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(
            width: UserDetailWindowLayout.mainWindowDefaultWidth,
            height: UserDetailWindowLayout.detailWindowDefaultHeight
        )

        WindowGroup(id: "user-init-wizard", for: String.self) { $username in
            if let name = username {
                AuthenticatedSceneGate {
                    LegacyCompatibilityScene(
                        container: legacyCompatibility,
                        includeGatewayHub: true
                    ) {
                        UserInitWizardWindow(username: name)
                    }
                }
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(authStore)
                .environment(maintenanceWindowRegistry)
                .environment(\.locale, appLanguage.locale)
                .background(UserInitWizardWindowPositioner())
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 720)

        WindowGroup(id: "channel-onboarding", for: String.self) { $payload in
            AuthenticatedSceneGate {
                LegacyCompatibilityScene(container: legacyCompatibility) {
                    ChannelOnboardingWindow(payload: payload)
                }
            }
            .environment(updater)
            .environment(modelStore)
            .environment(keychainStore)
            .environment(lockStore)
            .environment(authStore)
            .environment(maintenanceWindowRegistry)
            .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 980, height: 520)

        WindowGroup(id: "maintenance-terminal", for: String.self) { $payload in
            AuthenticatedSceneGate {
                LegacyCompatibilityScene(container: legacyCompatibility) {
                    MaintenanceTerminalWindow(payload: payload)
                }
            }
            .environment(authStore)
            .environment(maintenanceWindowRegistry)
            .environment(\.locale, appLanguage.locale)
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 860, height: 560)

        WindowGroup(id: "clone-claw", for: String.self) { $sourceUsername in
            if let username = sourceUsername {
                AuthenticatedSceneGate {
                    LegacyCompatibilityScene(container: legacyCompatibility) {
                        CloneClawSheet(sourceUsername: username)
                    }
                }
                .environment(authStore)
                .environment(\.locale, appLanguage.locale)
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 640, height: 560)
    }
}
