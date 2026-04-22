import Foundation
import Observation

@MainActor
@Observable
final class AuthSessionStore {
    private(set) var phase: AuthPhase = .launching
    private(set) var currentUser: AuthUser?
    private(set) var accessToken: String?
    private(set) var isDebugSession = false

    @ObservationIgnored
    private let apiClient: AuthAPIClient
    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private var didRestoreInitialState = false

    private static let lastLoginPhoneDefaultsKey = "auth.lastLoginPhone"

    init(apiClient: AuthAPIClient, defaults: UserDefaults = .standard) {
        self.apiClient = apiClient
        self.defaults = defaults
    }

    var lastLoginPhone: String {
        defaults.string(forKey: Self.lastLoginPhoneDefaultsKey) ?? ""
    }

    var isServiceConfigured: Bool {
        apiClient.isConfigured
    }

#if DEBUG
    var canUseDebugTemporaryLogin: Bool {
        !apiClient.isConfigured
    }
#else
    var canUseDebugTemporaryLogin: Bool {
        false
    }
#endif

    func restoreInitialState() async {
        guard !didRestoreInitialState else { return }
        didRestoreInitialState = true

        if apiClient.isConfigured || canUseDebugTemporaryLogin {
            phase = .unauthenticated
        } else {
            phase = .failed(.serviceNotConfigured)
        }
    }

    func clearError() {
        if case .failed = phase {
            phase = .unauthenticated
        }
    }

    func signIn(phone: String, password: String) async {
        guard apiClient.isConfigured else {
            phase = .failed(.serviceNotConfigured)
            return
        }

        guard let normalizedPhone = normalizeMainlandChinaPhone(phone) else {
            phase = .failed(.invalidPhoneFormat)
            return
        }

        guard !password.isEmpty else {
            phase = .failed(.emptyPassword)
            return
        }

        defaults.set(normalizedPhone, forKey: Self.lastLoginPhoneDefaultsKey)

        phase = .authenticating

        do {
            let payload = try await apiClient.login(phoneNumber: normalizedPhone, password: password)
            accessToken = payload.accessToken
            currentUser = payload.user
            isDebugSession = false
            phase = .authenticated
        } catch let error as AuthError {
            clearSession()
            phase = .failed(error)
        } catch {
            clearSession()
            phase = .failed(.transport(error.localizedDescription))
        }
    }

    func signOut() async {
        let token = accessToken
        let wasDebugSession = isDebugSession
        clearSession()
        phase = .failed(.sessionInvalidated(.logout))

        guard !wasDebugSession else { return }
        guard let token, !token.isEmpty else { return }
        await apiClient.logout(accessToken: token)
    }

    func invalidateSession(reason: SessionInvalidationReason) {
        clearSession()
        phase = .failed(.sessionInvalidated(reason))
    }

    private func clearSession() {
        accessToken = nil
        currentUser = nil
        isDebugSession = false
    }

#if DEBUG
    func signInWithDebugBypass(phone rawPhone: String) {
        guard canUseDebugTemporaryLogin else { return }

        let normalizedPhone = normalizeMainlandChinaPhone(rawPhone)
            ?? normalizeMainlandChinaPhone(lastLoginPhone)
            ?? "13800138000"

        defaults.set(normalizedPhone, forKey: Self.lastLoginPhoneDefaultsKey)

        accessToken = "debug-bypass"
        currentUser = AuthUser(
            id: "debug-user",
            phone: normalizedPhone,
            displayName: L10n.k("auth.debug.display_name", fallback: "开发模式账号")
        )
        isDebugSession = true
        phase = .authenticated
    }
#endif
}
