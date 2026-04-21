import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private final class MockAuthAPIClient: AuthAPIClient {
    var isConfigured: Bool = true
    var loginResult: Result<AuthSessionPayload, Error> = .failure(AuthError.invalidCredentials)
    var logoutCallCount = 0

    func login(phoneNumber: String, password: String) async throws -> AuthSessionPayload {
        try loginResult.get()
    }

    func logout(accessToken: String) async {
        logoutCallCount += 1
    }
}

@main
struct AuthSessionStoreTests {
    @MainActor
    static func main() async {
        let defaults = UserDefaults(suiteName: "AuthSessionStoreTests")!
        defaults.removePersistentDomain(forName: "AuthSessionStoreTests")

        let client = MockAuthAPIClient()
        let store = AuthSessionStore(apiClient: client, defaults: defaults)

        await store.restoreInitialState()
        expect(store.phase == .unauthenticated, "configured client should restore to unauthenticated")

        client.loginResult = .success(
            AuthSessionPayload(
                accessToken: "token-123",
                user: AuthUser(id: "u1", phone: "13800138000", displayName: "测试账号")
            )
        )
        await store.signIn(phone: "13800138000", password: "secret")
        expect(store.phase == .authenticated, "successful sign-in should enter authenticated phase")
        expect(store.currentUser?.phone == "13800138000", "successful sign-in should store current user")

        await store.signOut()
        expect(store.phase == .failed(.sessionInvalidated(.logout)), "sign-out should return to logged-out failed state")
        expect(client.logoutCallCount == 1, "sign-out should call logout once")

        client.loginResult = .failure(AuthError.invalidCredentials)
        await store.signIn(phone: "13800138000", password: "wrong")
        expect(store.phase == .failed(.invalidCredentials), "invalid credentials should stay on login with error")

        store.invalidateSession(reason: .unauthorized)
        expect(store.phase == .failed(.sessionInvalidated(.unauthorized)), "session invalidation should surface the correct reason")

        let unconfiguredClient = MockAuthAPIClient()
        unconfiguredClient.isConfigured = false
        let unconfiguredStore = AuthSessionStore(apiClient: unconfiguredClient, defaults: defaults)
        await unconfiguredStore.restoreInitialState()
        expect(unconfiguredStore.phase == .failed(.serviceNotConfigured), "missing base URL should fail during restore")

        print("Auth session store tests passed.")
    }
}
