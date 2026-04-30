import Foundation

enum LaunchAgentHandoffService {
    static func disable(
        _ launchAgent: OpenClawLaunchAgentInfo,
        expectedConfigPath: String,
        expectedStateDir: String
    ) async throws -> GatewayProfileLaunchAgentHandoff {
        let originalURL = URL(fileURLWithPath: launchAgent.plistPath).standardizedFileURL
        guard launchAgentPlistPathIsAllowed(originalURL) else {
            throw handoffError("LaunchAgent 路径不在允许范围内：\(originalURL.path)")
        }

        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            return GatewayProfileLaunchAgentHandoff(
                originalLabel: launchAgent.label,
                originalPlistPath: originalURL.path,
                disabledPlistPath: nil,
                disabledAt: Date(),
                status: .disabled,
                message: "旧 LaunchAgent plist 已不存在，视为已交接"
            )
        }

        guard let freshInfo = OpenClawInstanceDiscoveryService.launchAgentInfo(at: originalURL) else {
            throw handoffError("无法重新解析旧 LaunchAgent，已取消交接：\(originalURL.path)")
        }
        guard matches(freshInfo, expectedConfigPath: expectedConfigPath, expectedStateDir: expectedStateDir) else {
            throw handoffError("旧 LaunchAgent 与当前 OpenClaw 实例不再匹配，已取消交接：\(freshInfo.label)")
        }
        guard freshInfo.label == launchAgent.label else {
            throw handoffError("旧 LaunchAgent label 已变化，已取消交接：\(freshInfo.label)")
        }

        guard !freshInfo.requiresAdminForDisable else {
            throw handoffError(
                """
                该 LaunchAgent 需要管理员权限才能禁用：\(originalURL.path)
                请先手动执行：
                \(manualDisableCommands(for: freshInfo).joined(separator: "\n"))
                """
            )
        }

        let serviceTarget = "gui/\(getuid())/\(freshInfo.label)"
        _ = await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", "gui/\(getuid())", originalURL.path]
        )
        _ = await runProcess(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["disable", serviceTarget]
        )

        let disabledURL = uniqueDisabledURL(for: originalURL)
        do {
            try FileManager.default.moveItem(at: originalURL, to: disabledURL)
        } catch {
            throw handoffError("旧 LaunchAgent 已尝试停止，但 plist 改名失败：\(error.localizedDescription)")
        }

        return GatewayProfileLaunchAgentHandoff(
            originalLabel: freshInfo.label,
            originalPlistPath: originalURL.path,
            disabledPlistPath: disabledURL.path,
            disabledAt: Date(),
            status: .disabled,
            message: "旧 LaunchAgent 已交接并禁用"
        )
    }

    static func manualDisableCommands(for launchAgent: OpenClawLaunchAgentInfo) -> [String] {
        let plistPath = shellEscaped(launchAgent.plistPath)
        let label = shellEscaped(launchAgent.label)
        let disabledPath = shellEscaped("\(launchAgent.plistPath).disabled")
        if launchAgent.domain == .systemLaunchAgent || launchAgent.requiresAdminForDisable {
            return [
                "sudo launchctl bootout gui/$(id -u) \(plistPath)",
                "sudo mv \(plistPath) \(disabledPath)",
            ]
        }
        return [
            "launchctl bootout gui/$(id -u) \(plistPath)",
            "launchctl disable gui/$(id -u)/\(label)",
            "mv \(plistPath) \(disabledPath)",
        ]
    }

    private static func matches(
        _ launchAgent: OpenClawLaunchAgentInfo,
        expectedConfigPath: String,
        expectedStateDir: String
    ) -> Bool {
        if let matchedConfigPath = launchAgent.matchedConfigPath,
           standardizedPath(matchedConfigPath) == standardizedPath(expectedConfigPath) {
            return true
        }
        if let matchedStateDir = launchAgent.matchedStateDir,
           standardizedPath(matchedStateDir) == standardizedPath(expectedStateDir) {
            return true
        }
        return false
    }

    private static func launchAgentPlistPathIsAllowed(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let userLaunchAgentsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL
            .path
        return path.hasPrefix(userLaunchAgentsPath + "/")
            || path.hasPrefix("/Library/LaunchAgents/")
    }

    private static func uniqueDisabledURL(for originalURL: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = originalURL.path + ".disabled-\(formatter.string(from: Date()))"
        var candidate = URL(fileURLWithPath: base)
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        candidate = URL(fileURLWithPath: "\(base)-\(UUID().uuidString.prefix(8))")
        return candidate
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func shellEscaped(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func handoffError(_ message: String) -> NSError {
        NSError(domain: "LaunchAgentHandoffService", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private static func runProcess(
        executableURL: URL,
        arguments: [String]
    ) async -> (exitCode: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executableURL
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe

                do {
                    try process.run()
                    process.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    let output = String(data: data, encoding: .utf8) ?? ""
                    continuation.resume(returning: (process.terminationStatus, output))
                } catch {
                    continuation.resume(returning: (127, error.localizedDescription))
                }
            }
        }
    }
}
