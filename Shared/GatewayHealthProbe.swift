import Foundation

enum GatewayHealthProbe {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 2
        return URLSession(configuration: configuration)
    }()

    static func httpProbe(port: Int) async -> (alive: Bool, ready: Bool) {
        let baseURL = "http://127.0.0.1:\(port)"
        if await check("\(baseURL)/readyz") {
            return (true, true)
        }
        return (await check("\(baseURL)/healthz"), false)
    }

    private static func check(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
