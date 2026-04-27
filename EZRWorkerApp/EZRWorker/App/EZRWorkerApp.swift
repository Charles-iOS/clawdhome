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
                    }
                    await updater.bootstrapAppUpdates()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 1280, height: 960)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }

        WindowGroup(id: "profile-terminal", for: String.self) { $profileID in
            if let profileID {
                AuthenticatedSceneGate {
                    ProfileTerminalWindow(profileIDString: profileID)
                }
                .environment(processManager)
                .environment(gatewayService)
                .environment(profileStore)
                .environment(supervisorClient)
                .environment(authStore)
                .environment(\.locale, appLanguage.locale)
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.automatic)
        .defaultSize(width: 940, height: 620)
    }
}
