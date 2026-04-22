import Foundation

@objc protocol EZRWorkerSupervisorProtocol: NSObjectProtocol {
    func ping(withReply reply: @escaping (String) -> Void)
    func listProfilesRuntime(withReply reply: @escaping (String) -> Void)
    func prepareProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void)
    func startProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void)
    func stopProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void)
    func restartProfile(profileID: String, withReply reply: @escaping (Bool, String?) -> Void)
    func reloadProfiles(withReply reply: @escaping (Bool, String?) -> Void)
}

enum SupervisorJSONCodec {
    static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return "null"
    }

    static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = string.data(using: .utf8) else {
            throw NSError(domain: "EZRWorkerSupervisorProtocol", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无效的 JSON 字符串"
            ])
        }
        return try decoder.decode(type, from: data)
    }
}
