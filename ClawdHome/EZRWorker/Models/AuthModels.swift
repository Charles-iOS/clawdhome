import Foundation

enum AuthPhase: Equatable {
    case launching
    case unauthenticated
    case authenticating
    case authenticated
    case failed(AuthError)
}

struct AuthUser: Codable, Equatable, Sendable {
    let id: String
    let phone: String
    let displayName: String
}

struct AuthSessionPayload: Equatable, Sendable {
    let accessToken: String
    let user: AuthUser
}

enum SessionInvalidationReason: Equatable, Sendable {
    case logout
    case expired
    case unauthorized
    case bootstrapFailure
}

enum AuthError: LocalizedError, Equatable {
    case serviceNotConfigured
    case invalidPhoneFormat
    case emptyPassword
    case invalidCredentials
    case unauthorized
    case networkUnavailable
    case server(statusCode: Int)
    case serverMessage(String)
    case transport(String)
    case sessionInvalidated(SessionInvalidationReason)

    var errorDescription: String? {
        switch self {
        case .serviceNotConfigured:
            return L10n.k("auth.error.service_not_configured", fallback: "认证服务未配置，请联系管理员。")
        case .invalidPhoneFormat:
            return L10n.k("auth.error.invalid_phone_format", fallback: "请输入正确的中国大陆手机号。")
        case .emptyPassword:
            return L10n.k("auth.error.empty_password", fallback: "请输入密码。")
        case .invalidCredentials:
            return L10n.k("auth.error.invalid_credentials", fallback: "手机号或密码错误。")
        case .unauthorized:
            return L10n.k("auth.error.unauthorized", fallback: "登录状态已失效，请重新登录。")
        case .networkUnavailable:
            return L10n.k("auth.error.network_unavailable", fallback: "网络不可用，请检查连接后重试。")
        case .server(let statusCode):
            return String(
                format: L10n.k("auth.error.server", fallback: "认证服务异常（HTTP %d）。"),
                statusCode
            )
        case .serverMessage(let message):
            return message
        case .transport(let message):
            return message
        case .sessionInvalidated(let reason):
            switch reason {
            case .logout:
                return L10n.k("auth.error.logged_out", fallback: "已退出登录。")
            case .expired:
                return L10n.k("auth.error.session_expired", fallback: "登录状态已过期，请重新登录。")
            case .unauthorized:
                return L10n.k("auth.error.session_unauthorized", fallback: "登录状态无效，请重新登录。")
            case .bootstrapFailure:
                return L10n.k("auth.error.bootstrap_failure", fallback: "应用初始化失败，请重新登录后再试。")
            }
        }
    }
}

enum AppRootRoute: Equatable {
    case launching
    case login
    case app
}

enum ProtectedSceneRoute: Equatable {
    case loading
    case blocked
    case content
}

func resolveAppRootRoute(for phase: AuthPhase) -> AppRootRoute {
    switch phase {
    case .launching:
        return .launching
    case .authenticated:
        return .app
    case .unauthenticated, .authenticating, .failed:
        return .login
    }
}

func resolveProtectedSceneRoute(for phase: AuthPhase) -> ProtectedSceneRoute {
    switch phase {
    case .launching, .authenticating:
        return .loading
    case .authenticated:
        return .content
    case .unauthenticated, .failed:
        return .blocked
    }
}

func normalizeMainlandChinaPhone(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    let normalized = trimmed.replacingOccurrences(
        of: #"[\s-]"#,
        with: "",
        options: .regularExpression
    )

    let localDigits: String
    if normalized.hasPrefix("+86") {
        localDigits = String(normalized.dropFirst(3))
    } else if normalized.hasPrefix("86"), normalized.count == 13 {
        localDigits = String(normalized.dropFirst(2))
    } else {
        localDigits = normalized
    }

    guard localDigits.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil else {
        return nil
    }
    return localDigits
}

func mainlandChinaLocalDigits(from phone: String) -> String? {
    let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil {
        return trimmed
    }

    if trimmed.hasPrefix("+86") {
        let localDigits = String(trimmed.dropFirst(3))
        guard localDigits.range(of: #"^1\d{10}$"#, options: .regularExpression) != nil else {
            return nil
        }
        return localDigits
    }

    return nil
}

func displayMainlandChinaPhone(_ phone: String) -> String {
    mainlandChinaLocalDigits(from: phone) ?? phone
}
