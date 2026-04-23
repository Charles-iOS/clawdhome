import Foundation

struct ProfileTerminalLaunchContext {
    var executable: String
    var arguments: [String]
    var environment: [String: String]
}

enum ProfileCLIService {
    static func makeTerminalLaunchContext(
        profile: GatewayProfileResolution
    ) throws -> ProfileTerminalLaunchContext {
        let nodeURL = OpenClawRuntime.bundledNodeURL
        let entryURL = OpenClawRuntime.bundledOpenClawEntry

        guard FileManager.default.fileExists(atPath: nodeURL.path) else {
            throw NSError(domain: "ProfileCLIService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Node.js 未找到: \(nodeURL.path)"
            ])
        }
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            throw NSError(domain: "ProfileCLIService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "OpenClaw 入口未找到: \(entryURL.path)"
            ])
        }

        let shimDirectoryURL = try ensureOpenClawShim(
            profile: profile,
            nodeURL: nodeURL,
            entryURL: entryURL
        )

        var environment = OpenClawRuntime.buildEnvironment(profile: profile)
        let existingPath = environment["PATH"] ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "\(shimDirectoryURL.path):\(existingPath)"
        environment["TERM"] = environment["TERM"] ?? "xterm-256color"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? environment["LANG"]
        environment["EZRWORKER_PROFILE_ID"] = profile.profileID.uuidString
        environment["EZRWORKER_PROFILE_SLUG"] = profile.slug
        environment["EZRWORKER_PROFILE_DISPLAY_NAME"] = profile.displayName
        environment["EZRWORKER_PROFILE_WORKSPACE"] = profile.resolvedWorkspaceRoot
        environment["EZRWORKER_PROFILE_CONFIG"] = profile.resolvedConfigPath
        environment["EZRWORKER_PROFILE_STATE"] = profile.resolvedStateDir
        environment.removeValue(forKey: "OPENCLAW_PROFILE")

        let bootstrap = """
        unset OPENCLAW_PROFILE
        cd "$EZRWORKER_PROFILE_WORKSPACE" 2>/dev/null || cd "$HOME"
        printf 'EZRWorker OpenClaw Terminal\\n'
        printf 'Profile: %s (%s)\\n' "$EZRWORKER_PROFILE_DISPLAY_NAME" "$EZRWORKER_PROFILE_SLUG"
        printf 'Config:  %s\\n' "$EZRWORKER_PROFILE_CONFIG"
        printf 'State:   %s\\n' "$EZRWORKER_PROFILE_STATE"
        printf '\\nTry: openclaw agents list\\n'
        printf '     openclaw configure --section model\\n\\n'
        exec /bin/zsh -f -i
        """

        return ProfileTerminalLaunchContext(
            executable: "/bin/zsh",
            arguments: ["-f", "-c", bootstrap],
            environment: environment
        )
    }

    private static func ensureOpenClawShim(
        profile: GatewayProfileResolution,
        nodeURL: URL,
        entryURL: URL
    ) throws -> URL {
        let shimDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ezrworker-profile-terminal-shims", isDirectory: true)
            .appendingPathComponent(profile.profileID.uuidString, isDirectory: true)
        let shimURL = shimDirectoryURL.appendingPathComponent("openclaw")

        try FileManager.default.createDirectory(
            at: shimDirectoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )

        let script = """
        #!/bin/sh
        if [ "${1:-}" = "gateway" ]; then
          echo "Gateway 由 EZRWorker 管理，请在 App 中启动/停止，或使用状态页查看。" >&2
          exit 2
        fi
        exec \(shellSingleQuoted(nodeURL.path)) \(shellSingleQuoted(entryURL.path)) "$@"
        """

        let existing = try? String(contentsOf: shimURL, encoding: .utf8)
        if existing != script {
            try Data(script.utf8).write(to: shimURL, options: .atomic)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shimURL.path)

        return shimDirectoryURL
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
