import Foundation

protocol AuthAPIClient {
    var isConfigured: Bool { get }

    func login(phoneNumber: String, password: String) async throws -> AuthSessionPayload
    func logout(accessToken: String) async
}

final class BackendAuthClient: AuthAPIClient {
    private let baseURL: URL?
    private let session: URLSession
    private let bundle: Bundle

    var isConfigured: Bool { baseURL != nil }

    init(bundle: Bundle = .main, session: URLSession? = nil) {
        self.bundle = bundle
        if let raw = bundle.object(forInfoDictionaryKey: "AuthAPIBaseURL") as? String {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            self.baseURL = trimmed.isEmpty ? nil : URL(string: trimmed)
        } else {
            self.baseURL = nil
        }

        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 20
            configuration.timeoutIntervalForResource = 30
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func login(phoneNumber: String, password: String) async throws -> AuthSessionPayload {
        let request = try makeJSONRequest(
            path: "auth/login",
            method: "POST",
            body: LoginRequest(
                phone: phoneNumber,
                password: password
            ),
            accessToken: nil
        )

        let (data, response) = try await perform(request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.transport(L10n.k("auth.error.invalid_response", fallback: "认证服务返回了无效响应。"))
        }

        switch httpResponse.statusCode {
        case 200...299:
            do {
                let payload = try JSONDecoder().decode(Envelope<LoginEnvelope>.self, from: data)
                guard payload.success, let loginData = payload.data else {
                    throw AuthError.serverMessage(
                        payload.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                            ?? L10n.k("auth.error.invalid_response", fallback: "认证服务返回了无效响应。")
                    )
                }
                return AuthSessionPayload(
                    accessToken: loginData.accessToken,
                    user: AuthUser(
                        id: loginData.user.id,
                        phone: loginData.user.phone,
                        displayName: loginData.user.name ?? displayMainlandChinaPhone(loginData.user.phone)
                    )
                )
            } catch let error as AuthError {
                throw error
            } catch {
                throw AuthError.transport(L10n.k("auth.error.decode_failed", fallback: "无法解析登录响应，请稍后再试。"))
            }
        case 401:
            throw AuthError.invalidCredentials
        default:
            throw mapServerError(statusCode: httpResponse.statusCode, data: data)
        }
    }

    func logout(accessToken: String) async {
        _ = accessToken
        // ezrworker 当前没有用户态 /auth/logout，Web 端退出登录也是本地清 token。
        return
    }

    private func makeJSONRequest<Body: Encodable>(
        path: String,
        method: String,
        body: Body,
        accessToken: String?
    ) throws -> URLRequest {
        guard let baseURL else { throw AuthError.serviceNotConfigured }

        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost:
                throw AuthError.networkUnavailable
            default:
                throw AuthError.transport(error.localizedDescription)
            }
        } catch {
            throw AuthError.transport(error.localizedDescription)
        }
    }

    private func mapServerError(statusCode: Int, data: Data) -> AuthError {
        if let decoded = try? JSONDecoder().decode(Envelope<EmptyPayload>.self, from: data),
           let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            return AuthError.serverMessage(message)
        }

        if let decoded = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
            if let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
                return AuthError.serverMessage(message)
            }
            if let error = decoded.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
                return AuthError.serverMessage(error)
            }
        }
        return AuthError.server(statusCode: statusCode)
    }
}

private struct LoginRequest: Encodable {
    let phone: String
    let password: String
}

private struct Envelope<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let message: String?
}

private struct LoginEnvelope: Decodable {
    let accessToken: String
    let user: AuthUserResponse
    let refreshToken: String?
}

private struct AuthUserResponse: Decodable {
    let id: String
    let phone: String
    let name: String?
}

private struct ErrorResponse: Decodable {
    let message: String?
    let error: String?
}

private struct EmptyPayload: Decodable {}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
