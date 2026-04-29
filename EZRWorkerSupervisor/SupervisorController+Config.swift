import Foundation
import Security

extension EZRWorkerSupervisorController {
    func ensureProfileDirectories(_ resolution: GatewayProfileResolution) throws {
        let fm = FileManager.default
        let directories = [
            resolution.configURL.deletingLastPathComponent(),
            resolution.stateDirURL,
            resolution.workspaceRootURL,
            resolution.stateDirURL.appendingPathComponent("agents", isDirectory: true),
        ]
        for directory in directories {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        }
    }

    func reconcileManagedConfigLayoutIfNeeded(_ resolution: GatewayProfileResolution) throws {
        guard resolution.sourceKind == .managed,
              let legacyConfigURL = resolution.legacyManagedConfigURL,
              legacyConfigURL.standardizedFileURL.path != resolution.configURL.standardizedFileURL.path
        else {
            return
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyConfigURL.path) else { return }

        let canonicalConfigURL = resolution.configURL
        guard let migratedLegacyRoot = migratedLegacyConfigRoot(from: legacyConfigURL) else {
            return
        }

        if !fm.fileExists(atPath: canonicalConfigURL.path) {
            try writeJSONObject(migratedLegacyRoot, to: canonicalConfigURL)
            return
        }

        guard let canonicalRoot = loadJSONObject(at: canonicalConfigURL) else {
            try writeJSONObject(migratedLegacyRoot, to: canonicalConfigURL)
            return
        }

        guard shouldPromoteLegacyConfig(
            migratedLegacyRoot,
            over: canonicalRoot,
            legacyConfigURL: legacyConfigURL,
            canonicalConfigURL: canonicalConfigURL
        ) else {
            return
        }

        var mergedRoot = canonicalRoot
        for (key, value) in migratedLegacyRoot where key != "gateway" {
            mergedRoot[key] = value
        }

        guard !jsonObjectsEqual(mergedRoot, canonicalRoot) else { return }
        try writeJSONObject(mergedRoot, to: canonicalConfigURL)
    }

    private func migratedLegacyConfigRoot(
        from legacyConfigURL: URL
    ) -> [String: Any]? {
        guard var root = loadJSONObject(at: legacyConfigURL) else { return nil }
        root = rewriteRelativeSecretProviderPaths(
            in: root,
            from: legacyConfigURL.deletingLastPathComponent()
        )
        return root
    }

    private func rewriteRelativeSecretProviderPaths(
        in root: [String: Any],
        from sourceDirectoryURL: URL
    ) -> [String: Any] {
        guard var secrets = root["secrets"] as? [String: Any],
              var providers = secrets["providers"] as? [String: Any]
        else {
            return root
        }

        for (providerID, rawProvider) in providers {
            guard var provider = rawProvider as? [String: Any],
                  let rawPath = provider["path"] as? String
            else {
                continue
            }

            let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            let expandedPath = NSString(string: trimmedPath).expandingTildeInPath
            guard !expandedPath.isEmpty, !expandedPath.hasPrefix("/") else { continue }

            let absoluteSourceURL = sourceDirectoryURL
                .appendingPathComponent(expandedPath)
                .standardizedFileURL
            provider["path"] = absoluteSourceURL.path
            providers[providerID] = provider
        }

        var updatedRoot = root
        secrets["providers"] = providers
        updatedRoot["secrets"] = secrets
        return updatedRoot
    }

    private func shouldPromoteLegacyConfig(
        _ legacyRoot: [String: Any],
        over canonicalRoot: [String: Any],
        legacyConfigURL: URL,
        canonicalConfigURL: URL
    ) -> Bool {
        if meaningfulConfigSectionCount(in: canonicalRoot) == 0,
           meaningfulConfigSectionCount(in: legacyRoot) > 0 {
            return true
        }

        guard let legacyModifiedAt = modificationDate(for: legacyConfigURL),
              let canonicalModifiedAt = modificationDate(for: canonicalConfigURL) else {
            return false
        }
        return legacyModifiedAt > canonicalModifiedAt
    }

    private func meaningfulConfigSectionCount(in root: [String: Any]) -> Int {
        Self.meaningfulLegacyConfigKeys.reduce(into: 0) { count, key in
            if isMeaningfulJSONObjectValue(root[key]) {
                count += 1
            }
        }
    }

    private func isMeaningfulJSONObjectValue(_ value: Any?) -> Bool {
        switch value {
        case let string as String:
            return !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let dictionary as [String: Any]:
            return !dictionary.isEmpty
        case let array as [Any]:
            return !array.isEmpty
        case nil, is NSNull:
            return false
        default:
            return true
        }
    }

    private func loadJSONObject(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private func writeJSONObject(_ root: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    private func jsonObjectsEqual(_ lhs: [String: Any], _ rhs: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(lhs),
              JSONSerialization.isValidJSONObject(rhs),
              let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
              let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys])
        else {
            return false
        }
        return lhsData == rhsData
    }

    private func modificationDate(for url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }

    func normalizeConfig(for resolution: GatewayProfileResolution) throws {
        let url = resolution.configURL
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = json
        }

        var gateway = root["gateway"] as? [String: Any] ?? [:]
        gateway["port"] = resolution.resolvedPort
        gateway["mode"] = "local"

        var controlUI = gateway["controlUi"] as? [String: Any] ?? [:]
        controlUI["allowInsecureAuth"] = true
        gateway["controlUi"] = controlUI

        if resolution.sourceKind == .managed || resolution.sourceKind == .externalReuse {
            var auth = gateway["auth"] as? [String: Any] ?? [:]
            auth["mode"] = "token"
            let existingToken = (auth["token"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if existingToken?.isEmpty != false {
                auth["token"] = generateGatewayToken()
            }
            gateway["auth"] = auth

            var agents = root["agents"] as? [String: Any] ?? [:]
            var defaults = agents["defaults"] as? [String: Any] ?? [:]
            defaults["workspace"] = resolution.resolvedWorkspaceRoot
            agents["defaults"] = defaults
            root["agents"] = agents
        }

        root["gateway"] = gateway

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let backupURL = try backupExternalConfigIfNeeded(resolution)
        do {
            try data.write(to: url, options: .atomic)
            if resolution.sourceKind == .externalReuse,
               loadJSONObject(at: url) == nil,
               let backupURL {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: backupURL, to: url)
                throw NSError(domain: "EZRWorkerSupervisor", code: 30, userInfo: [
                    NSLocalizedDescriptionKey: "写入外部 openclaw.json 后校验失败，已恢复备份"
                ])
            }
        } catch {
            if resolution.sourceKind == .externalReuse,
               let backupURL,
               FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.copyItem(at: backupURL, to: url)
            }
            throw error
        }
    }

    private func backupExternalConfigIfNeeded(_ resolution: GatewayProfileResolution) throws -> URL? {
        guard resolution.sourceKind == .externalReuse,
              FileManager.default.fileExists(atPath: resolution.configURL.path) else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        var backupURL = resolution.configURL
            .deletingLastPathComponent()
            .appendingPathComponent(
                "openclaw.json.ezrworker-backup-\(formatter.string(from: Date()))"
            )
        if FileManager.default.fileExists(atPath: backupURL.path) {
            backupURL = resolution.configURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    "openclaw.json.ezrworker-backup-\(formatter.string(from: Date()))-\(UUID().uuidString.prefix(8))"
                )
        }
        try FileManager.default.copyItem(at: resolution.configURL, to: backupURL)
        return backupURL
    }

    private func generateGatewayToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }

        return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
    }

    private func configToken(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gateway = json["gateway"] as? [String: Any],
              let auth = gateway["auth"] as? [String: Any],
              let token = auth["token"] as? String,
              !token.isEmpty
        else {
            return nil
        }
        return token
    }
}
