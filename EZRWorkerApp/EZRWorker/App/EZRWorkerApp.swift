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
    @State private var helperClient: HelperClient
    @State private var shrimpPool: ShrimpPool
    @State private var updater: UpdateChecker
    @State private var modelStore: GlobalModelStore
    @State private var gatewayHub: GatewayHub
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
        let helperClient = HelperClient()
        let shrimpPool = ShrimpPool(helperClient: helperClient)
        let updater = UpdateChecker()
        let modelStore = GlobalModelStore()
        let gatewayHub = GatewayHub()
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
            helperClient: helperClient,
            shrimpPool: shrimpPool,
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
        _helperClient = State(initialValue: helperClient)
        _shrimpPool = State(initialValue: shrimpPool)
        _updater = State(initialValue: updater)
        _modelStore = State(initialValue: modelStore)
        _gatewayHub = State(initialValue: gatewayHub)
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
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(gatewayHub)
                .environment(lockStore)
                .environment(maintenanceWindowRegistry)
                .task {
                    appDelegate.onWillTerminate = {
                        bootstrapCoordinator.prepareForAppTermination()
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
                    ClawDetailWindow(username: name)
                }
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
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
                    UserInitWizardWindow(username: name)
                }
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(updater)
                .environment(modelStore)
                .environment(keychainStore)
                .environment(gatewayHub)
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
                ChannelOnboardingWindow(payload: payload)
            }
            .environment(helperClient)
            .environment(shrimpPool)
            .environment(updater)
            .environment(modelStore)
            .environment(keychainStore)
            .environment(gatewayHub)
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
                MaintenanceTerminalWindow(payload: payload)
            }
            .environment(helperClient)
            .environment(shrimpPool)
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
                    CloneClawSheet(sourceUsername: username)
                }
                .environment(helperClient)
                .environment(shrimpPool)
                .environment(authStore)
                .environment(\.locale, appLanguage.locale)
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 640, height: 560)
    }
}
