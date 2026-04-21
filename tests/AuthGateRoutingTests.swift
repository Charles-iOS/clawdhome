import Foundation

private func expect<T: Equatable>(_ value: T, equals expected: T, _ message: String) {
    guard value == expected else {
        fputs("FAIL: \(message)\nexpected: \(expected)\nactual: \(value)\n", stderr)
        exit(1)
    }
}

@main
struct AuthGateRoutingTests {
    static func main() {
        expect(
            resolveAppRootRoute(for: .launching),
            equals: .launching,
            "launching phase should keep splash route"
        )
        expect(
            resolveAppRootRoute(for: .unauthenticated),
            equals: .login,
            "unauthenticated phase should route to login"
        )
        expect(
            resolveAppRootRoute(for: .failed(.invalidCredentials)),
            equals: .login,
            "failed login should still render login route"
        )
        expect(
            resolveAppRootRoute(for: .authenticated),
            equals: .app,
            "authenticated phase should route to app shell"
        )

        expect(
            resolveProtectedSceneRoute(for: .launching),
            equals: .loading,
            "protected scenes should stay loading during launch"
        )
        expect(
            resolveProtectedSceneRoute(for: .authenticating),
            equals: .loading,
            "protected scenes should stay loading while authenticating"
        )
        expect(
            resolveProtectedSceneRoute(for: .unauthenticated),
            equals: .blocked,
            "protected scenes should block access before login"
        )
        expect(
            resolveProtectedSceneRoute(for: .authenticated),
            equals: .content,
            "protected scenes should show content after login"
        )

        print("Auth gate routing tests passed.")
    }
}
