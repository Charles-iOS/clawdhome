// EZRWorkerApp/Services/Gateway/GatewayService.swift
// 单实例 Gateway 连接管理（简化自 GatewayHub）

import Foundation
import Observation

@MainActor @Observable
final class GatewayService {

    private(set) var isConnected = false

    private var client: GatewayClient?
    private var connectionSyncTask: Task<Void, Never>?
    private(set) var cronStore = GatewayCronStore()
    private(set) var skillsStore = GatewaySkillsStore()

    private(set) var port: Int
    private var token: String

    init(port: Int = 18789, token: String = "") {
        self.port = port
        self.token = token
    }

    // MARK: - 连接管理

    func connect() async {
        if let existing = client {
            let connected = await existing.connected
            if connected { return }
            await existing.updateToken(token)
        } else {
            client = GatewayClient(port: port, token: token)
        }

        do {
            try await client!.connect()
            let connectedClient = client!
            await cronStore.start(client: connectedClient)
            await skillsStore.start(client: connectedClient)
            isConnected = true
            startConnectionSync()
            appLog("GatewayService: connected to port \(port)")
        } catch {
            isConnected = false
            appLog("GatewayService: connect failed: \(error.localizedDescription)", level: .error)
        }
    }

    func disconnect() async {
        stopConnectionSync()
        if let c = client { await c.disconnect() }
        client = nil
        isConnected = false
        cronStore.stop()
        skillsStore.stop()
    }

    func prepareForAppTermination() {
        stopConnectionSync()
        let existingClient = client
        client = nil
        isConnected = false
        cronStore.stop()
        skillsStore.stop()

        if let existingClient {
            Task {
                await existingClient.disconnect()
            }
        }
    }

    func updateToken(_ newToken: String) {
        token = newToken
    }

    func reconfigure(port newPort: Int, token newToken: String) async {
        let didChangePort = newPort != port
        let didChangeToken = newToken != token

        port = newPort
        token = newToken

        guard didChangePort || didChangeToken else { return }

        await disconnect()
    }

    // MARK: - 配置操作

    func configGet(path: String) async -> String? {
        guard let c = client else { return nil }
        guard let value = try? await c.configGet(path: path) else { return nil }
        switch value {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func configSet(path: String, value: Any) async throws {
        guard let c = client else { throw GatewayClientError.notConnected }
        try await c.configSet(path: path, value: value)
    }

    /// 将多条 dot-path 合并为一次 config.patch（同一 baseHash），满足 OpenClaw 对整块 provider 的校验
    func applyConfigLeafPatches(_ pathValuePairs: [(String, Any)]) async throws {
        guard let c = client else { throw GatewayClientError.notConnected }
        try await c.applyConfigLeafPatches(pathValuePairs)
    }

    func configGetFull() async throws -> (config: [String: Any], baseHash: String) {
        guard let c = client else { throw GatewayClientError.notConnected }
        return try await c.configGetFull()
    }

    @discardableResult
    func configPatch(
        patch: [String: Any],
        baseHash: String,
        note: String? = nil
    ) async throws -> (noop: Bool, config: [String: Any]) {
        guard let c = client else { throw GatewayClientError.notConnected }
        return try await c.configPatch(patch: patch, baseHash: baseHash, note: note)
    }

    // MARK: - 模型

    func modelsList() async -> [ModelGroup]? {
        guard let c = client else { return nil }
        do {
            let raw = try await c.modelsList()
            guard !raw.isEmpty else { return nil }
            return Self.groupModels(raw)
        } catch {
            return nil
        }
    }

    func request(method: String, params: [String: Any]? = nil) async throws -> [String: Any]? {
        guard let c = client else { throw GatewayClientError.notConnected }
        return try await c.request(method: method, params: params)
    }

    // MARK: - 探活

    func httpProbe() async -> (alive: Bool, ready: Bool) {
        await GatewayClient.httpProbe(port: port)
    }

    // MARK: - 私有

    private static func groupModels(_ raw: [[String: Any]]) -> [ModelGroup]? {
        var groupMap: [String: [ModelEntry]] = [:]
        var order: [String] = []
        for entry in raw {
            guard let id = entry["id"] as? String,
                  let provider = entry["provider"] as? String else { continue }
            let name = entry["name"] as? String ?? id
            if groupMap[provider] == nil {
                groupMap[provider] = []
                order.append(provider)
            }
            groupMap[provider]!.append(ModelEntry(id: id, label: name))
        }
        let groups = order.compactMap { key -> ModelGroup? in
            guard let models = groupMap[key] else { return nil }
            return ModelGroup(id: key, provider: key, models: models)
        }
        return groups.isEmpty ? nil : groups
    }

    private func startConnectionSync() {
        stopConnectionSync()
        connectionSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if let currentClient = self.client {
                    let connected = await currentClient.connected
                    if self.isConnected != connected {
                        self.isConnected = connected
                        if !connected {
                            self.cronStore.stop()
                            self.skillsStore.stop()
                        }
                    }
                } else if self.isConnected {
                    self.isConnected = false
                }
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private func stopConnectionSync() {
        connectionSyncTask?.cancel()
        connectionSyncTask = nil
    }
}
