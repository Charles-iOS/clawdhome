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

        for line in lines.reversed() where !line.localizedCaseInsensitiveContains("OpenClaw") {
            if line.localizedCaseInsensitiveContains("Gateway failed to start:") {
                return line
            }
            if line.localizedCaseInsensitiveContains("error:") {
                return line
            }
        }

        return lines.reversed().first(where: { !Self.isBenignStartupProgressLine($0) })
    }

    static func isSupervisorRestartHandoffMessage(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains("restart mode:")
            && text.localizedCaseInsensitiveContains("full process restart")
            && text.localizedCaseInsensitiveContains("supervisor restart")
    }

    static func isBenignStartupProgressLine(_ text: String) -> Bool {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return true }
        return normalized.contains("[gateway] loading configuration")
            || normalized.contains("[gateway] resolving authentication")
            || normalized.contains("[gateway] starting")
            || normalized.contains("[gateway] log file:")
            || normalized.contains("[canvas] host mounted")
            || normalized.contains("[health-monitor] started")
            || normalized.contains("[heartbeat] started")
            || normalized.hasPrefix("config ok:")
            || normalized.hasPrefix("workspace ok:")
            || normalized.hasPrefix("sessions ok:")
            || normalized.hasPrefix("wrote ")
            || normalized.hasPrefix("config overwrite:")
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
