import Foundation

enum OpenClawRuntime {
    private static let inheritedSupervisorMarkerKeys = [
        "LAUNCH_JOB_LABEL",
        "LAUNCH_JOB_NAME",
        "XPC_SERVICE_NAME",
        "OPENCLAW_LAUNCHD_LABEL",
        "OPENCLAW_SYSTEMD_UNIT",
        "INVOCATION_ID",
        "SYSTEMD_EXEC_PID",
        "JOURNAL_STREAM",
        "OPENCLAW_WINDOWS_TASK_NAME",
        "OPENCLAW_SERVICE_MARKER",
        "OPENCLAW_SERVICE_KIND",
    ]

    static var bundledNodeURL: URL {
        runtimeRootURL.appendingPathComponent("node/bin/node")
    }

    static var bundledOpenClawEntry: URL {
        runtimeRootURL.appendingPathComponent("openclaw/lib/node_modules/openclaw/openclaw.mjs")
    }

    static var bundledNpxURL: URL {
        runtimeRootURL.appendingPathComponent("node/bin/npx")
    }

    static func buildEnvironment(profile: GatewayProfileResolution? = nil) -> [String: String] {
        let home = NSHomeDirectory()
        let nodeBin = bundledNodeURL.deletingLastPathComponent().path
        let openClawBin = runtimeRootURL.appendingPathComponent("openclaw/bin").path
        let npmGlobalBin = "\(home)/.npm-global/bin"
        let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"

        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home
        environment["PATH"] = "\(nodeBin):\(openClawBin):\(npmGlobalBin):\(existingPath)"
        environment["NODE_ENV"] = "production"
        // Our multi-profile isolation is driven by explicit config/state paths.
        // Letting an inherited OPENCLAW_PROFILE leak through makes OpenClaw
        // derive legacy ~/.openclaw/workspace-<profile> defaults again.
        environment.removeValue(forKey: "OPENCLAW_PROFILE")
        for key in inheritedSupervisorMarkerKeys {
            environment.removeValue(forKey: key)
        }
        environment["EZRWORKER_SUPERVISOR_CHILD"] = "1"
        environment["OPENCLAW_NO_RESPAWN"] = "1"
        // Avoid blocking gateway readiness on Codex app-server live model discovery.
        environment["OPENCLAW_CODEX_DISCOVERY_LIVE"] = "0"

        if let profile {
            environment["OPENCLAW_CONFIG_PATH"] = profile.resolvedConfigPath
            environment["OPENCLAW_STATE_DIR"] = profile.resolvedStateDir
        }

        return environment
    }

    static func runOpenClaw(
        arguments: [String],
        profile: GatewayProfileResolution? = nil,
        currentDirectoryURL: URL? = nil
    ) async -> (Bool, String) {
        let nodeURL = bundledNodeURL
        let entryURL = bundledOpenClawEntry

        guard FileManager.default.fileExists(atPath: nodeURL.path) else {
            return (false, "Node.js 未找到: \(nodeURL.path)")
        }
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            return (false, "OpenClaw 入口未找到: \(entryURL.path)")
        }

        let process = Process()
        process.executableURL = nodeURL
        process.arguments = [entryURL.path] + arguments
        process.environment = buildEnvironment(profile: profile)
        process.currentDirectoryURL = currentDirectoryURL ?? FileManager.default.homeDirectoryForCurrentUser

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
        } catch {
            return (false, error.localizedDescription)
        }

        return await withCheckedContinuation { continuation in
            process.terminationHandler = { terminated in
                let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                continuation.resume(returning: (terminated.terminationStatus == 0, output))
            }
        }
    }

    private static var runtimeRootURL: URL {
        if let custom = runtimeOverrideDirectory() {
            return custom
        }

        if let bundled = bundledRuntimeDirectory() {
            return bundled
        }

        return Bundle.main.bundleURL
    }

    private static func runtimeOverrideDirectory() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        for key in ["EZRWORKER_DEV_RUNTIME_DIR", "CLAWDHOME_DEV_RUNTIME_DIR"] {
            if let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }

        #if DEBUG
        if let repoRoot = debugRepoRootURL() {
            return repoRoot.appendingPathComponent("build/dev-runtime", isDirectory: true)
        }
        #endif

        return nil
    }

    private static func bundledRuntimeDirectory() -> URL? {
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("node/bin/node").path) {
            return resourceURL
        }

        var current = Bundle.main.bundleURL
        let fm = FileManager.default
        for _ in 0..<8 {
            let contentsResources = current.appendingPathComponent("Contents/Resources", isDirectory: true)
            let nodePath = contentsResources.appendingPathComponent("node/bin/node").path
            if fm.fileExists(atPath: nodePath) {
                return contentsResources
            }
            let parent = current.deletingLastPathComponent()
            if parent == current { break }
            current = parent
        }
        return nil
    }

    #if DEBUG
    private static func debugRepoRootURL() -> URL? {
        let fm = FileManager.default
        var current = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while true {
            let projectYML = current.appendingPathComponent("project.yml").path
            let runtimeScript = current.appendingPathComponent("scripts/bundle-runtime.sh").path
            if fm.fileExists(atPath: projectYML), fm.fileExists(atPath: runtimeScript) {
                return current
            }

            let parent = current.deletingLastPathComponent()
            if parent == current {
                return nil
            }
            current = parent
        }
    }
    #endif
}
