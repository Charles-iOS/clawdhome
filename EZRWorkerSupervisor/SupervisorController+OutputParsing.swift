import Foundation

extension EZRWorkerSupervisorController {
    func isSupervisorRestartHandoff(exitCode: Int32, output: String?) -> Bool {
        guard exitCode == 0, let output else { return false }
        return Self.isSupervisorRestartHandoffMessage(Self.stripANSIEscapeCodes(from: output))
    }

    func extractStartupFailureMessage(from output: String?) -> String? {
        guard let output else { return nil }

        let lines = output
            .components(separatedBy: .newlines)
            .map(Self.stripANSIEscapeCodes)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { !Self.isSupervisorRestartHandoffMessage($0) }

        if let configInvalidIndex = lines.firstIndex(where: {
            $0.localizedCaseInsensitiveContains("Config invalid")
        }) {
            let problem = lines[(configInvalidIndex + 1)...]
                .first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ") })
            if let problem {
                return "Config invalid: \(problem)"
            }
            return "Config invalid"
        }

        for line in lines.reversed() where !line.localizedCaseInsensitiveContains("OpenClaw") {
            if line.localizedCaseInsensitiveContains("Gateway failed to start:") {
                return line
            }
            if line.localizedCaseInsensitiveContains("gateway startup failed:") {
                return line
            }
            if line.localizedCaseInsensitiveContains("error:") {
                return line
            }
        }

        // 没有匹配到明确的错误指示就返回 nil，由上层自行决定超时/未就绪文案；
        // 避免把 startup trace、plugin 加载日志等正常行误当成失败原因。
        return nil
    }

    func startupOutputIndicatesGatewayReady(_ output: String?) -> Bool {
        guard let output else { return false }
        return Self.stripANSIEscapeCodes(from: output)
            .components(separatedBy: .newlines)
            .contains(where: Self.isGatewayReadyLine)
    }

    static func isTerminalStartupFailureOutput(_ output: String?) -> Bool {
        guard let output else { return false }
        let normalized = stripANSIEscapeCodes(from: output).lowercased()
        return normalized.contains("config invalid")
            || normalized.contains("gateway failed to start:")
            || normalized.contains("gateway startup failed:")
            || normalized.contains("process will stay alive; fix the issue and restart")
            || normalized.contains("refusing to bind gateway")
    }

    static func isSupervisorRestartHandoffMessage(_ text: String) -> Bool {
        let normalized = text.lowercased()
        guard normalized.contains("restart mode:") else { return false }

        let fullSupervisorRestart =
            normalized.contains("full process restart")
            && normalized.contains("supervisor restart")
        let inProcessNoRespawnRestart =
            normalized.contains("in-process restart")
            && normalized.contains("openclaw_no_respawn")

        return fullSupervisorRestart || inProcessNoRespawnRestart
    }

    static func isBenignStartupProgressLine(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized.contains("[gateway] loading configuration")
            || normalized.contains("[gateway] resolving authentication")
            || normalized.contains("[gateway] starting")
            || isGatewayReadyLine(normalized)
            || normalized.contains("[gateway] log file:")
            || normalized.contains("[gateway] startup trace")
            || normalized.contains("[gateway] startup phase")
            || normalized.contains("[plugins]")
            || normalized.contains("[plugin]")
            || normalized.contains("[browser/")
            || normalized.contains("[ws]")
            || normalized.contains("[canvas] host mounted")
            || normalized.contains("[health-monitor] started")
            || normalized.contains("[heartbeat] started")
            || normalized.hasPrefix("config ok:")
            || normalized.hasPrefix("workspace ok:")
            || normalized.hasPrefix("sessions ok:")
            || normalized.hasPrefix("wrote ")
            || normalized.hasPrefix("config overwrite:")
            || normalized.hasPrefix("listening on ")
            || normalized.hasPrefix("info ")
            || normalized.hasPrefix("warn ")
            || normalized.hasPrefix("debug ")
    }

    static func isGatewayReadyLine(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("[gateway] ready")
            || normalized.contains("\"message\":\"gateway ready\"")
            || normalized.hasSuffix("gateway ready")
    }

    static func stripANSIEscapeCodes(from text: String) -> String {
        guard
            let regex = try? NSRegularExpression(
                pattern: #"\u{001B}\[[0-?]*[ -/]*[@-~]"#,
                options: []
            )
        else {
            return text
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }
}
