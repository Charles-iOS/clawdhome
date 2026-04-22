import AppKit
import Observation
import SwiftUI

@MainActor
final class LegacyCompatibilityContainer {
    private var helperClientStorage: HelperClient?
    private var shrimpPoolStorage: ShrimpPool?
    private var gatewayHubStorage: GatewayHub?
    private var didStartLegacyRuntime = false
    private var startupTask: Task<Bool, Never>?

    var helperClient: HelperClient {
        resolveHelperClient()
    }

    var shrimpPool: ShrimpPool {
        resolveShrimpPool()
    }

    var gatewayHub: GatewayHub {
        resolveGatewayHub()
    }

    func prepareForLegacyWindowPresentation() async -> Bool {
        if didStartLegacyRuntime {
            return true
        }
        if let startupTask {
            return await startupTask.value
        }

        let helperClient = resolveHelperClient()
        let shrimpPool = resolveShrimpPool()
        let task = Task<Bool, Never> { @MainActor [weak self] in
            helperClient.connect()
            let connected = await helperClient.waitUntilConnected()
            guard connected, !Task.isCancelled else {
                self?.startupTask = nil
                return false
            }

            shrimpPool.start()
            self?.didStartLegacyRuntime = true
            self?.startupTask = nil
            return true
        }

        startupTask = task
        return await task.value
    }

    func prepareForAppTermination() {
        startupTask?.cancel()
        startupTask = nil
        didStartLegacyRuntime = false
        helperClientStorage?.disconnect()
        shrimpPoolStorage?.stop()

        let gatewayHub = gatewayHubStorage
        helperClientStorage = nil
        shrimpPoolStorage = nil
        gatewayHubStorage = nil

        if let gatewayHub {
            Task { @MainActor in
                await gatewayHub.disconnectAll()
            }
        }
    }

    private func resolveHelperClient() -> HelperClient {
        if let helperClientStorage {
            return helperClientStorage
        }
        let helperClient = HelperClient()
        helperClientStorage = helperClient
        return helperClient
    }

    private func resolveShrimpPool() -> ShrimpPool {
        if let shrimpPoolStorage {
            return shrimpPoolStorage
        }
        let shrimpPool = ShrimpPool(helperClient: resolveHelperClient())
        shrimpPoolStorage = shrimpPool
        return shrimpPool
    }

    private func resolveGatewayHub() -> GatewayHub {
        if let gatewayHubStorage {
            return gatewayHubStorage
        }
        let gatewayHub = GatewayHub()
        gatewayHubStorage = gatewayHub
        return gatewayHub
    }
}

struct LegacyCompatibilityScene<Content: View>: View {
    let container: LegacyCompatibilityContainer
    let includeGatewayHub: Bool
    private let content: () -> Content

    @State private var isReady = false
    @State private var startupError: String?

    init(
        container: LegacyCompatibilityContainer,
        includeGatewayHub: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.container = container
        self.includeGatewayHub = includeGatewayHub
        self.content = content
    }

    var body: some View {
        Group {
            if isReady {
                preparedContent
            } else if let startupError {
                CompatibilityRuntimeStatusView(
                    title: "旧版兼容运行时未就绪",
                    message: startupError,
                    showProgress: false
                )
            } else {
                CompatibilityRuntimeStatusView(
                    title: "正在准备旧版兼容运行时",
                    message: "正在连接 Helper 并恢复旧窗口所需依赖，请稍候。",
                    showProgress: true
                )
            }
        }
        .task {
            guard !isReady, startupError == nil else { return }
            let ready = await container.prepareForLegacyWindowPresentation()
            if ready {
                isReady = true
            } else {
                startupError = "Helper 连接失败，请确认旧版兼容环境已安装后重试。"
            }
        }
    }

    @ViewBuilder
    private var preparedContent: some View {
        if includeGatewayHub {
            content()
                .environment(container.helperClient)
                .environment(container.shrimpPool)
                .environment(container.gatewayHub)
        } else {
            content()
                .environment(container.helperClient)
                .environment(container.shrimpPool)
        }
    }
}

private struct CompatibilityRuntimeStatusView: View {
    let title: String
    let message: String
    let showProgress: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showProgress {
                ProgressView()
                    .controlSize(.large)
            }
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}

@MainActor
@Observable
final class MaintenanceWindowRegistry {
    struct Payload: Codable, Hashable {
        let username: String
        let title: String
        let command: [String]
        let completionToken: String?
        let completionContext: String?
    }

    private(set) var generatedPayloadCount = 0

    func makePayload(
        username: String,
        title: String,
        command: [String],
        completionToken: String? = nil,
        completionContext: String? = nil
    ) -> String {
        generatedPayloadCount += 1
        return Self.encode(
            Payload(
                username: username,
                title: title,
                command: command,
                completionToken: completionToken,
                completionContext: completionContext
            )
        )
    }

    static func decode(_ rawPayload: String?) -> Payload? {
        guard let rawPayload,
              let data = rawPayload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(Payload.self, from: data)
    }

    private static func encode(_ payload: Payload) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(payload),
              let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}

struct ClawDetailWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var shrimpPool

    var body: some View {
        ResolvedManagedUserView(username: username) { user in
            UserDetailView(user: user)
        }
        .task {
            if !shrimpPool.didFinishInitialUserLoad {
                shrimpPool.loadUsers()
            }
        }
    }
}

struct UserInitWizardWindow: View {
    let username: String

    @Environment(ShrimpPool.self) private var shrimpPool

    var body: some View {
        ResolvedManagedUserView(username: username) { user in
            UserInitWizardView(user: user)
        }
        .task {
            if !shrimpPool.didFinishInitialUserLoad {
                shrimpPool.loadUsers()
            }
        }
    }
}

struct ChannelOnboardingWindow: View {
    private let rawPayload: String?

    @Environment(ShrimpPool.self) private var shrimpPool

    init(payload: String?) {
        self.rawPayload = payload
    }

    init(payload: Binding<String?>) {
        self.rawPayload = payload.wrappedValue
    }

    var body: some View {
        if let payload = decodedPayload {
            let displayName = shrimpPool.users
                .first(where: { $0.username == payload.username })?
                .fullName ?? payload.username

            FeishuChannelOnboardingSheet(
                flow: payload.flow,
                displayName: displayName,
                username: payload.username
            )
        } else {
            MissingSecondaryWindowView(
                title: "无法打开通道配置窗口",
                message: "窗口参数无效，请返回上一页后重试。"
            )
        }
    }

    private var decodedPayload: ChannelOnboardingPayload? {
        guard let rawPayload else { return nil }
        let components = rawPayload.split(separator: ":", maxSplits: 1).map(String.init)
        guard components.count == 2,
              let flow = ChannelOnboardingFlow(rawValue: components[0]),
              !components[1].isEmpty else {
            return nil
        }
        return ChannelOnboardingPayload(flow: flow, username: components[1])
    }
}

struct MaintenanceTerminalWindow: View {
    private let rawPayload: String?

    @StateObject private var terminalControl = LocalTerminalControl()
    @State private var exitCode: Int32?

    init(payload: String?) {
        self.rawPayload = payload
    }

    init(payload: Binding<String?>) {
        self.rawPayload = payload.wrappedValue
    }

    var body: some View {
        if let payload = MaintenanceWindowRegistry.decode(rawPayload) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(payload.title)
                            .font(.headline)
                        Text("@\(payload.username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let exitCode {
                        Label(
                            exitCode == 0 ? "已退出" : "退出码 \(exitCode)",
                            systemImage: exitCode == 0 ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .foregroundStyle(exitCode == 0 ? .green : .red)
                    } else {
                        Button("终止") {
                            terminalControl.terminate()
                        }
                    }
                }

                HelperMaintenanceTerminalPanel(
                    username: payload.username,
                    command: payload.command,
                    control: terminalControl
                ) { code in
                    exitCode = code
                    postCompletionNotificationIfNeeded(payload: payload, exitCode: code)
                }
                .frame(minHeight: 360)
            }
            .padding(16)
            .background(WindowTitleBinder(title: payload.title))
        } else {
            MissingSecondaryWindowView(
                title: "无法打开维护终端",
                message: "窗口参数无效，请关闭后从业务页面重新打开。"
            )
        }
    }

    private func postCompletionNotificationIfNeeded(
        payload: MaintenanceWindowRegistry.Payload,
        exitCode: Int32?
    ) {
        guard payload.completionToken != nil || payload.completionContext != nil else { return }
        var userInfo: [String: Any] = [
            "username": payload.username,
            "title": payload.title,
            "command": payload.command
        ]
        if let completionToken = payload.completionToken {
            userInfo["token"] = completionToken
        }
        if let completionContext = payload.completionContext {
            userInfo["context"] = completionContext
        }
        if let exitCode {
            userInfo["exitCode"] = NSNumber(value: exitCode)
        }
        NotificationCenter.default.post(
            name: .maintenanceTerminalWindowClosed,
            object: nil,
            userInfo: userInfo
        )
    }
}

struct ClawDetailWindowPositioner: NSViewRepresentable {
    private let idealSidebar: CGFloat = 200
    private let preferredSize = NSSize(
        width: UserDetailWindowLayout.mainWindowDefaultWidth,
        height: UserDetailWindowLayout.detailWindowDefaultHeight
    )
    private let minimumSize = NSSize(
        width: UserDetailWindowLayout.detailWindowMinimumWidth,
        height: UserDetailWindowLayout.detailWindowMinimumHeight
    )

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(
                view: view,
                sidebar: idealSidebar,
                preferredSize: preferredSize,
                minimumSize: minimumSize
            )
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(
        view: NSView,
        sidebar: CGFloat,
        preferredSize: NSSize,
        minimumSize: NSSize
    ) {
        guard let detailWindow = view.window else { return }
        detailWindow.contentMinSize = minimumSize

        let mainWindow = NSApp.windows.first {
            $0 !== detailWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }

        let visibleFrame = main.screen?.visibleFrame ?? detailWindow.screen?.visibleFrame ?? main.frame
        let originX = min(main.frame.minX + sidebar, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let visibleWidth = visibleFrame.maxX - originX
        let width = resolvedUserDetailWindowWidth(
            mainWindowWidth: main.frame.width,
            visibleWidth: visibleWidth
        )
        let height = min(preferredSize.height, visibleFrame.maxY - originY)
        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: width,
            height: max(minimumSize.height, height)
        )
        detailWindow.setFrame(frame, display: true)
    }
}

struct UserInitWizardWindowPositioner: NSViewRepresentable {
    private let preferredWidth: CGFloat = 980
    private let minimumSize = NSSize(width: 860, height: 560)

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            Self.align(view: view, preferredWidth: preferredWidth, minimumSize: minimumSize)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private static func align(view: NSView, preferredWidth: CGFloat, minimumSize: NSSize) {
        guard let wizardWindow = view.window else { return }
        wizardWindow.contentMinSize = minimumSize

        let mainWindow = NSApp.windows.first {
            $0 !== wizardWindow && $0.isVisible && $0.contentViewController != nil
        }
        guard let main = mainWindow else { return }

        let visibleFrame = main.screen?.visibleFrame ?? wizardWindow.screen?.visibleFrame ?? main.frame
        let originX = min(main.frame.minX, visibleFrame.maxX - minimumSize.width)
        let originY = max(main.frame.minY, visibleFrame.minY)
        let targetHeight = min(main.frame.height, visibleFrame.maxY - originY)
        let targetWidth = min(preferredWidth, visibleFrame.maxX - originX)

        let frame = NSRect(
            x: max(visibleFrame.minX, originX),
            y: originY,
            width: max(minimumSize.width, targetWidth),
            height: max(minimumSize.height, targetHeight)
        )
        wizardWindow.setFrame(frame, display: true)
    }
}

private struct ChannelOnboardingPayload {
    let flow: ChannelOnboardingFlow
    let username: String
}

private struct ResolvedManagedUserView<Content: View>: View {
    let username: String
    @ViewBuilder let content: (ManagedUser) -> Content

    @Environment(ShrimpPool.self) private var shrimpPool

    var body: some View {
        if let user = shrimpPool.users.first(where: { $0.username == username }) {
            content(user)
        } else {
            MissingSecondaryWindowView(
                title: "找不到用户 \(username)",
                message: shrimpPool.didFinishInitialUserLoad
                    ? "用户列表里没有这个账号，可能已经被删除。"
                    : "正在加载用户列表，请稍候。"
            )
        }
    }
}

private struct MissingSecondaryWindowView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(message)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }
}

private struct WindowTitleBinder: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.title = title
        }
    }
}
