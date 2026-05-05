import Foundation

enum OpenClawInstanceDiscoveryService {
    static func scanLightweightCandidates() -> [OpenClawInstanceCandidate] {
        mergeCandidates(
            scanRunningGatewayProcesses()
                + scanLaunchAgents()
                + scanCommonOpenClawDirectories()
                + scanLegacyOpenClawDirectory()
        )
    }

    static func candidateFromManualSelection(_ url: URL) throws -> OpenClawInstanceCandidate {
        let configURL: URL
        var isDirectory = ObjCBool(false)
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            configURL = url.appendingPathComponent("openclaw.json")
        } else {
            configURL = url
        }

        guard configURL.lastPathComponent == "openclaw.json" else {
            throw NSError(domain: "OpenClawInstanceDiscoveryService", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "请选择 openclaw.json，或选择包含 openclaw.json 的目录"
            ])
        }
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw NSError(domain: "OpenClawInstanceDiscoveryService", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "未找到 openclaw.json：\(configURL.path)"
            ])
        }

        return makeCandidate(
            configURL: configURL,
            source: .manualSelection,
            confidence: .high,
            pid: nil,
            commandLine: nil
        )
    }

    private static func scanLegacyOpenClawDirectory() -> [OpenClawInstanceCandidate] {
        let configURL = EZRWorkerPaths.legacyOpenClawConfigURL
        guard FileManager.default.fileExists(atPath: configURL.path) else { return [] }

        return [
            makeCandidate(
                configURL: configURL,
                source: .knownDirectory,
                confidence: .high,
                pid: nil,
                commandLine: nil
            )
        ]
    }

    private static func scanRunningGatewayProcesses() -> [OpenClawInstanceCandidate] {
        guard let output = runCommand("/bin/ps", arguments: ["-axo", "pid=,command="]) else {
            return []
        }

        var candidates: [OpenClawInstanceCandidate] = []
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let pieces = trimmedLine.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard pieces.count == 2,
                  let pid = Int32(pieces[0]),
                  pid > 0 else {
                continue
            }

            let commandLine = String(pieces[1])
            guard looksLikeOpenClawGateway(commandLine) else { continue }

            let openFiles = openFileNames(pid: pid)
            let configPath =
                extractEnvironmentPath(named: "OPENCLAW_CONFIG_PATH", from: commandLine)
                ?? configPathFromHints([commandLine] + openFiles)
            guard let configPath else { continue }

            let stateDir =
                extractEnvironmentPath(named: "OPENCLAW_STATE_DIR", from: commandLine)
                ?? stateDirFromHints([commandLine] + openFiles)
                ?? inferStateDir(configPath: configPath)

            let candidate = makeCandidate(
                configURL: URL(fileURLWithPath: configPath),
                source: .runningProcess,
                confidence: .high,
                pid: pid,
                commandLine: commandLine,
                stateDirOverride: stateDir
            )
            candidates.append(candidate)
        }
        return candidates
    }

    private static func scanLaunchAgents() -> [OpenClawInstanceCandidate] {
        let homeLaunchAgents = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let systemLaunchAgents = URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)

        return [homeLaunchAgents, systemLaunchAgents].flatMap { directory -> [OpenClawInstanceCandidate] in
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }

            return urls.compactMap { url -> OpenClawInstanceCandidate? in
                guard url.pathExtension == "plist" else { return nil }
                return candidateFromLaunchAgent(url)
            }
        }
    }

    static func launchAgentInfo(at url: URL) -> OpenClawLaunchAgentInfo? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            return nil
        }

        let label = (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
        let program = plist["Program"] as? String
        let arguments = plist["ProgramArguments"] as? [String] ?? []
        let rawEnvironment = plist["EnvironmentVariables"] as? [String: Any] ?? [:]
        let environment = rawEnvironment.reduce(into: [String: String]()) { result, entry in
            result[entry.key] = "\(entry.value)"
        }
        let workingDirectory = (plist["WorkingDirectory"] as? String).flatMap(nonEmptyPath(_:))
        let standardOutputPath = (plist["StandardOutPath"] as? String).flatMap(nonEmptyPath(_:))
        let standardErrorPath = (plist["StandardErrorPath"] as? String).flatMap(nonEmptyPath(_:))
        let commandLine = ([program].compactMap { $0 } + arguments).joined(separator: " ")
        let searchableText = ([label, commandLine] + environment.map { "\($0.key)=\($0.value)" })
            .joined(separator: " ")

        guard looksLikeOpenClawGateway(searchableText) else { return nil }

        let pathHints = [commandLine, workingDirectory, standardOutputPath, standardErrorPath].compactMap { $0 }
        let stateDir = environmentPath(named: "OPENCLAW_STATE_DIR", in: environment)
            ?? stateDirFromHints(pathHints)
        let configPath =
            environmentPath(named: "OPENCLAW_CONFIG_PATH", in: environment)
            ?? configPathFromArguments(arguments)
            ?? stateDir.flatMap(configPathFromStateDir(_:))
            ?? workingDirectory.flatMap(configPathFromDirectory(_:))
            ?? configPathFromHints(pathHints)
            ?? implicitLegacyConfigPathForLaunchAgent(
                label: label,
                standardOutputPath: standardOutputPath,
                standardErrorPath: standardErrorPath
            )

        guard let configPath else { return nil }
        let domain = launchAgentDomain(for: url)
        let isWritable = FileManager.default.isWritableFile(atPath: url.path)
        let requiresAdmin = domain == .systemLaunchAgent || !isWritable

        return OpenClawLaunchAgentInfo(
            label: label,
            plistPath: url.standardizedFileURL.path,
            domain: domain,
            programArguments: arguments.isEmpty ? [program].compactMap { $0 } : arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            keepAlive: launchAgentBoolean(plist["KeepAlive"]),
            runAtLoad: launchAgentBoolean(plist["RunAtLoad"]),
            isLoaded: isLaunchAgentLoaded(label: label),
            isWritableByCurrentUser: isWritable,
            requiresAdminForDisable: requiresAdmin,
            matchedConfigPath: configPath,
            matchedStateDir: stateDir,
            matchReason: launchAgentMatchReason(
                configPath: configPath,
                stateDir: stateDir,
                environment: environment,
                arguments: arguments,
                workingDirectory: workingDirectory
            )
        )
    }

    private static func candidateFromLaunchAgent(_ url: URL) -> OpenClawInstanceCandidate? {
        guard let launchAgent = launchAgentInfo(at: url),
              let configPath = launchAgent.matchedConfigPath else { return nil }

        return makeCandidate(
            configURL: URL(fileURLWithPath: configPath),
            source: .launchAgent,
            confidence: FileManager.default.isReadableFile(atPath: configPath) ? .high : .medium,
            pid: nil,
            commandLine: launchAgent.programArguments.joined(separator: " "),
            stateDirOverride: launchAgent.matchedStateDir,
            launchdLabel: launchAgent.label,
            launchAgent: launchAgent,
            additionalWarnings: launchAgentWarnings(launchAgent)
        )
    }

    private static func scanCommonOpenClawDirectories() -> [OpenClawInstanceCandidate] {
        let fm = FileManager.default
        let homeURL = fm.homeDirectoryForCurrentUser
        var roots: [URL] = [
            homeURL.appendingPathComponent(".openclaw", isDirectory: true),
            homeURL
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("OpenClaw", isDirectory: true),
        ]

        if let homeEntries = try? fm.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ) {
            for entry in homeEntries {
                let name = entry.lastPathComponent.lowercased()
                guard name.contains("openclaw") else { continue }
                roots.append(entry)
                roots.append(entry.appendingPathComponent(".openclaw", isDirectory: true))
            }
        }

        var configURLs: [URL] = []
        for root in roots {
            configURLs.append(contentsOf: candidateConfigURLs(under: root))
        }

        return Array(Set(configURLs.map { $0.standardizedFileURL.path }))
            .sorted()
            .map { configPath in
                makeCandidate(
                    configURL: URL(fileURLWithPath: configPath),
                    source: .knownDirectory,
                    confidence: .high,
                    pid: nil,
                    commandLine: nil
                )
            }
    }

    private static func candidateConfigURLs(under root: URL) -> [URL] {
        let fm = FileManager.default
        var urls: [URL] = []
        for candidate in [
            root.appendingPathComponent("openclaw.json"),
            root.appendingPathComponent(".openclaw", isDirectory: true).appendingPathComponent("openclaw.json"),
        ] where fm.isReadableFile(atPath: candidate.path) {
            urls.append(candidate)
        }

        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return urls
        }

        for child in children.prefix(200) {
            for candidate in [
                child.appendingPathComponent("openclaw.json"),
                child.appendingPathComponent(".openclaw", isDirectory: true).appendingPathComponent("openclaw.json"),
            ] where fm.isReadableFile(atPath: candidate.path) {
                urls.append(candidate)
            }
        }

        return urls
    }

    private static func launchAgentWarnings(_ launchAgent: OpenClawLaunchAgentInfo) -> [String] {
        var warnings = [
            "检测到旧 LaunchAgent：\(launchAgent.label)，托管前需要交接旧自启项，避免双重拉起"
        ]
        if launchAgent.keepAlive {
            warnings.append("旧 LaunchAgent 启用了 KeepAlive")
        }
        if launchAgent.runAtLoad {
            warnings.append("旧 LaunchAgent 启用了 RunAtLoad")
        }
        if launchAgent.requiresAdminForDisable {
            warnings.append("该 LaunchAgent 位于系统目录或当前用户不可写，需要管理员权限或手动禁用")
        }
        return warnings
    }

    private static func launchAgentDomain(for url: URL) -> OpenClawLaunchAgentDomain {
        let standardizedPath = url.standardizedFileURL.path
        let userLaunchAgentsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .standardizedFileURL
            .path
        if standardizedPath.hasPrefix(userLaunchAgentsPath + "/") {
            return .user
        }
        return .systemLaunchAgent
    }

    private static func launchAgentBoolean(_ value: Any?) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let dictionary = value as? [String: Any] {
            return !dictionary.isEmpty
        }
        return false
    }

    private static func isLaunchAgentLoaded(label: String) -> Bool? {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let serviceTarget = "gui/\(getuid())/\(label)"
        guard let output = runCommand(
            "/bin/launchctl",
            arguments: ["print", serviceTarget],
            timeout: 0.8
        ) else {
            return false
        }
        return output.localizedCaseInsensitiveContains(label)
            || output.localizedCaseInsensitiveContains("state =")
            || output.localizedCaseInsensitiveContains("pid =")
    }

    private static func launchAgentMatchReason(
        configPath: String,
        stateDir: String?,
        environment: [String: String],
        arguments: [String],
        workingDirectory: String?
    ) -> String {
        if let environmentConfigPath = environment["OPENCLAW_CONFIG_PATH"],
           standardizedPath(environmentConfigPath) == standardizedPath(configPath) {
            return "EnvironmentVariables.OPENCLAW_CONFIG_PATH"
        }
        if let stateDir,
           let environmentStateDir = environment["OPENCLAW_STATE_DIR"],
           standardizedPath(environmentStateDir) == standardizedPath(stateDir) {
            return "EnvironmentVariables.OPENCLAW_STATE_DIR"
        }
        if arguments.contains(where: { standardizedPath($0) == standardizedPath(configPath) || $0.contains(configPath) }) {
            return "ProgramArguments"
        }
        if let workingDirectory,
           let stateDir,
           standardizedPath(workingDirectory) == standardizedPath(stateDir) {
            return "WorkingDirectory"
        }
        return "OpenClaw path inference"
    }

    private static func implicitLegacyConfigPathForLaunchAgent(
        label: String,
        standardOutputPath: String?,
        standardErrorPath: String?
    ) -> String? {
        let legacyConfigPath = EZRWorkerPaths.legacyOpenClawConfigURL.standardizedFileURL.path
        guard FileManager.default.isReadableFile(atPath: legacyConfigPath) else {
            return nil
        }

        let normalizedLabel = label.lowercased()
        let defaultLabels = [
            "ai.openclaw.gateway",
            "com.openclaw.gateway",
            "openclaw.gateway",
        ]
        if defaultLabels.contains(normalizedLabel) {
            return legacyConfigPath
        }

        let legacyStateDir = EZRWorkerPaths.legacyOpenClawDirectory.standardizedFileURL.path
        let outputPaths = [standardOutputPath, standardErrorPath].compactMap { $0 }
        if outputPaths.contains(where: { standardizedPath($0).hasPrefix(legacyStateDir + "/") }) {
            return legacyConfigPath
        }

        return nil
    }

    private static func makeCandidate(
        configURL rawConfigURL: URL,
        source: OpenClawDiscoverySource,
        confidence: OpenClawDiscoveryConfidence,
        pid: Int32?,
        commandLine: String?,
        stateDirOverride: String? = nil,
        launchdLabel: String? = nil,
        launchAgent: OpenClawLaunchAgentInfo? = nil,
        additionalWarnings: [String] = []
    ) -> OpenClawInstanceCandidate {
        let configURL = rawConfigURL.standardizedFileURL
        let configPath = configURL.path
        let stateDir = URL(fileURLWithPath: stateDirOverride ?? inferStateDir(configPath: configPath), isDirectory: true)
            .standardizedFileURL
            .path
        let port = readGatewayPort(configPath: configPath)
            ?? launchAgent.flatMap(gatewayPort(from:))
            ?? commandLine.flatMap(gatewayPort(fromCommandLine:))
        let workspace = inferWorkspaceRoot(configPath: configPath, stateDir: stateDir)
        let warnings = Array(Set(warningsForCandidate(
            configPath: configPath,
            stateDir: stateDir,
            port: port,
            pid: pid
        ) + additionalWarnings)).sorted()
        let risk = riskLevel(warnings: warnings, port: port)
        let displayName = displayNameSuggestion(configURL: configURL, source: source)

        return OpenClawInstanceCandidate(
            id: UUID(),
            displayNameSuggestion: displayName,
            slugSuggestion: GatewayProfileResolver.normalizedSlug(displayName),
            source: source,
            confidence: confidence,
            riskLevel: risk,
            configPath: configPath,
            stateDir: stateDir,
            workspaceRoot: workspace,
            port: port,
            pid: pid,
            commandLine: commandLine,
            launchdLabel: launchdLabel,
            launchAgent: launchAgent,
            warnings: warnings,
            detectedAt: Date()
        )
    }

    private static func mergeCandidates(
        _ candidates: [OpenClawInstanceCandidate]
    ) -> [OpenClawInstanceCandidate] {
        var mergedByKey: [String: OpenClawInstanceCandidate] = [:]

        for candidate in candidates {
            let key = candidateKey(candidate)
            guard var existing = mergedByKey[key] else {
                mergedByKey[key] = candidate
                continue
            }

            if sourceRank(candidate.source) > sourceRank(existing.source) {
                existing.source = candidate.source
            }
            if confidenceRank(candidate.confidence) > confidenceRank(existing.confidence) {
                existing.confidence = candidate.confidence
            }
            if riskRank(candidate.riskLevel) > riskRank(existing.riskLevel) {
                existing.riskLevel = candidate.riskLevel
            }
            existing.pid = existing.pid ?? candidate.pid
            existing.commandLine = existing.commandLine ?? candidate.commandLine
            existing.launchdLabel = existing.launchdLabel ?? candidate.launchdLabel
            existing.launchAgent = existing.launchAgent ?? candidate.launchAgent
            existing.port = existing.port ?? candidate.port
            existing.workspaceRoot = existing.workspaceRoot ?? candidate.workspaceRoot
            existing.warnings = Array(Set(existing.warnings + candidate.warnings)).sorted()
            mergedByKey[key] = existing
        }

        return mergedByKey.values.sorted {
            if riskRank($0.riskLevel) != riskRank($1.riskLevel) {
                return riskRank($0.riskLevel) < riskRank($1.riskLevel)
            }
            return $0.displayNameSuggestion.localizedStandardCompare($1.displayNameSuggestion) == .orderedAscending
        }
    }

    private static func candidateKey(_ candidate: OpenClawInstanceCandidate) -> String {
        if !candidate.configPath.isEmpty {
            return "config:\(standardizedPath(candidate.configPath))"
        }
        if !candidate.stateDir.isEmpty {
            return "state:\(standardizedPath(candidate.stateDir))"
        }
        if let pid = candidate.pid {
            return "pid:\(pid)"
        }
        return candidate.id.uuidString
    }

    private static func sourceRank(_ source: OpenClawDiscoverySource) -> Int {
        switch source {
        case .manualSelection:
            return 3
        case .launchAgent:
            return 3
        case .runningProcess:
            return 2
        case .knownDirectory:
            return 1
        }
    }

    private static func confidenceRank(_ confidence: OpenClawDiscoveryConfidence) -> Int {
        switch confidence {
        case .high:
            return 3
        case .medium:
            return 2
        case .low:
            return 1
        }
    }

    private static func riskRank(_ risk: OpenClawDiscoveryRiskLevel) -> Int {
        switch risk {
        case .safe:
            return 1
        case .needsReview:
            return 2
        case .blocked:
            return 3
        }
    }

    private static func warningsForCandidate(
        configPath: String,
        stateDir: String,
        port: Int?,
        pid: Int32?
    ) -> [String] {
        var warnings: [String] = []
        let fm = FileManager.default

        if !fm.isReadableFile(atPath: configPath) {
            warnings.append("openclaw.json 不可读")
        }
        if !fm.fileExists(atPath: stateDir) {
            warnings.append("状态目录不存在，托管启动前需要创建")
        }
        if port == nil {
            warnings.append("未能从配置中读取 gateway.port，将使用默认端口")
        } else if let port, !(1...65535).contains(port) {
            warnings.append("gateway.port 不在 1-65535 范围内")
        }
        if pid != nil, port == nil {
            warnings.append("已发现运行中进程，但端口需要确认")
        }

        return warnings
    }

    private static func riskLevel(
        warnings: [String],
        port: Int?
    ) -> OpenClawDiscoveryRiskLevel {
        if let port, !(1...65535).contains(port) {
            return .blocked
        }
        if warnings.contains(where: { $0.contains("不可读") }) {
            return .blocked
        }
        return warnings.isEmpty ? .safe : .needsReview
    }

    private static func displayNameSuggestion(
        configURL: URL,
        source: OpenClawDiscoverySource
    ) -> String {
        if standardizedPath(configURL.path) == standardizedPath(EZRWorkerPaths.legacyOpenClawConfigURL.path) {
            return "Default"
        }

        let directory = configURL.deletingLastPathComponent()
        let lastComponent = directory.lastPathComponent
        if lastComponent == ".openclaw" {
            let parentName = directory.deletingLastPathComponent().lastPathComponent
            return parentName.isEmpty ? "Imported OpenClaw" : parentName
        }

        if !lastComponent.isEmpty {
            return lastComponent
        }

        switch source {
        case .runningProcess:
            return "Running OpenClaw"
        case .launchAgent:
            return "LaunchAgent OpenClaw"
        case .knownDirectory:
            return "Existing OpenClaw"
        case .manualSelection:
            return "Imported OpenClaw"
        }
    }

    private static func looksLikeOpenClawGateway(_ commandLine: String) -> Bool {
        let normalized = commandLine.lowercased()
        return normalized.contains("openclaw") && normalized.contains("gateway")
    }

    private static func openFileNames(pid: Int32) -> [String] {
        guard let output = runCommand("/usr/sbin/lsof", arguments: ["-Fn", "-p", "\(pid)"]) else {
            return []
        }

        return output
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> String? in
                guard line.first == "n" else { return nil }
                let path = String(line.dropFirst())
                guard path.hasPrefix("/") else { return nil }
                return path
            }
    }

    private static func environmentPath(named name: String, in environment: [String: Any]) -> String? {
        guard let rawValue = environment[name] as? String else { return nil }
        return nonEmptyPath(rawValue)
    }

    private static func environmentPath(named name: String, in environment: [String: String]) -> String? {
        guard let rawValue = environment[name] else { return nil }
        return nonEmptyPath(rawValue)
    }

    private static func configPathFromArguments(_ arguments: [String]) -> String? {
        let names = ["--config", "--config-path", "--openclaw-config", "--openclaw-config-path"]
        for index in arguments.indices {
            let argument = arguments[index]
            if names.contains(argument),
               arguments.indices.contains(index + 1),
               let path = nonEmptyPath(arguments[index + 1]) {
                return path
            }

            for name in names {
                if argument.hasPrefix("\(name)=") {
                    return nonEmptyPath(String(argument.dropFirst(name.count + 1)))
                }
            }

            if argument.hasPrefix("OPENCLAW_CONFIG_PATH=") {
                return nonEmptyPath(String(argument.dropFirst("OPENCLAW_CONFIG_PATH=".count)))
            }
        }
        return nil
    }

    private static func configPathFromHints(_ hints: [String]) -> String? {
        for hint in hints {
            if let directPath = firstOpenClawConfigPath(in: hint) {
                return directPath
            }
            if let stateDir = inferredOpenClawStateDir(from: hint),
               let configPath = configPathFromStateDir(stateDir) {
                return configPath
            }
        }
        return nil
    }

    private static func stateDirFromHints(_ hints: [String]) -> String? {
        for hint in hints {
            if let stateDir = inferredOpenClawStateDir(from: hint) {
                return stateDir
            }
        }
        return nil
    }

    private static func firstOpenClawConfigPath(in text: String) -> String? {
        let pattern = #"(/[^\s"'<>]+/openclaw\.json)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let pathRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return nonEmptyPath(String(text[pathRange]))
    }

    private static func inferredOpenClawStateDir(from pathLikeText: String) -> String? {
        let expanded = NSString(string: pathLikeText).expandingTildeInPath
        guard expanded.contains(".openclaw") else { return nil }

        let path: String
        if let browserRange = expanded.range(of: "/browser/openclaw/user-data") {
            path = String(expanded[..<browserRange.lowerBound])
        } else {
            path = expanded
        }

        let components = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard let openClawIndex = components.lastIndex(of: ".openclaw") else {
            return nil
        }
        if openClawIndex == 0 {
            return nil
        }
        let prefix = components[...openClawIndex]
        return NSString.path(withComponents: Array(prefix))
    }

    private static func configPathFromStateDir(_ stateDir: String) -> String? {
        configPathFromDirectory(stateDir)
    }

    private static func configPathFromDirectory(_ directory: String) -> String? {
        let configURL = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent("openclaw.json")
            .standardizedFileURL
        guard FileManager.default.isReadableFile(atPath: configURL.path) else {
            return nil
        }
        return configURL.path
    }

    private static func extractEnvironmentPath(named name: String, from commandLine: String) -> String? {
        guard let range = commandLine.range(of: "\(name)=") else { return nil }
        var value = String(commandLine[range.upperBound...])
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if value.first == "\"" {
            value.removeFirst()
            return value.split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)
                .flatMap(nonEmptyPath(_:))
        }

        if value.first == "'" {
            value.removeFirst()
            return value.split(separator: "'", maxSplits: 1, omittingEmptySubsequences: false)
                .first
                .map(String.init)
                .flatMap(nonEmptyPath(_:))
        }

        return value.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init)
            .flatMap(nonEmptyPath(_:))
    }

    private static func nonEmptyPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: NSString(string: trimmed).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func inferStateDir(configPath: String) -> String {
        URL(fileURLWithPath: configPath)
            .deletingLastPathComponent()
            .standardizedFileURL
            .path
    }

    static func gatewayPort(from launchAgent: OpenClawLaunchAgentInfo) -> Int? {
        gatewayPort(fromEnvironment: launchAgent.environment)
            ?? gatewayPort(fromArguments: launchAgent.programArguments)
    }

    private static func readGatewayPort(configPath: String) -> Int? {
        guard let root = loadJSONObject(configPath: configPath),
              let gateway = root["gateway"] as? [String: Any]
        else {
            return nil
        }
        if let number = gateway["port"] as? NSNumber {
            return number.intValue
        }
        if let intValue = gateway["port"] as? Int {
            return intValue
        }
        if let stringValue = gateway["port"] as? String {
            return normalizedPort(stringValue)
        }
        return nil
    }

    private static func gatewayPort(fromEnvironment environment: [String: String]) -> Int? {
        for name in ["OPENCLAW_GATEWAY_PORT", "OPENCLAW_PORT"] {
            if let port = normalizedPort(environment[name]) {
                return port
            }
        }
        return nil
    }

    private static func gatewayPort(fromArguments arguments: [String]) -> Int? {
        let names = ["--port", "--gateway-port", "--openclaw-gateway-port"]
        for index in arguments.indices {
            let argument = arguments[index]
            if names.contains(argument),
               arguments.indices.contains(index + 1),
               let port = normalizedPort(arguments[index + 1]) {
                return port
            }
            for name in names where argument.hasPrefix("\(name)=") {
                return normalizedPort(String(argument.dropFirst(name.count + 1)))
            }
        }
        return nil
    }

    private static func gatewayPort(fromCommandLine commandLine: String) -> Int? {
        let patterns = [
            #"(?:(?:^|\s)(?:OPENCLAW_GATEWAY_PORT|OPENCLAW_PORT)=)(\d{1,5})(?:\s|$)"#,
            #"(?:(?:^|\s)--(?:port|gateway-port|openclaw-gateway-port)(?:=|\s+))(\d{1,5})(?:\s|$)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(commandLine.startIndex..<commandLine.endIndex, in: commandLine)
            guard let match = regex.firstMatch(in: commandLine, range: range),
                  let portRange = Range(match.range(at: 1), in: commandLine),
                  let port = normalizedPort(String(commandLine[portRange]))
            else {
                continue
            }
            return port
        }
        return nil
    }

    private static func normalizedPort(_ raw: String?) -> Int? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), (1...65535).contains(port) else { return nil }
        return port
    }

    private static func inferWorkspaceRoot(configPath: String, stateDir: String) -> String? {
        guard let root = loadJSONObject(configPath: configPath),
              let agents = root["agents"] as? [String: Any],
              let defaults = agents["defaults"] as? [String: Any],
              let rawWorkspace = defaults["workspace"] as? String,
              !rawWorkspace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return URL(fileURLWithPath: stateDir, isDirectory: true)
                .appendingPathComponent("workspace", isDirectory: true)
                .standardizedFileURL
                .path
        }

        let expandedWorkspace = NSString(string: rawWorkspace).expandingTildeInPath
        if expandedWorkspace.hasPrefix("/") {
            return URL(fileURLWithPath: expandedWorkspace).standardizedFileURL.path
        }
        return URL(fileURLWithPath: stateDir, isDirectory: true)
            .appendingPathComponent(expandedWorkspace)
            .standardizedFileURL
            .path
    }

    private static func loadJSONObject(configPath: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        return json
    }

    private static func standardizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .standardizedFileURL
            .path
    }

    private static func runCommand(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval = 1.5
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            finished.signal()
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning {
                process.terminate()
            }
            _ = finished.wait(timeout: .now() + 0.2)
            process.terminationHandler = nil
            return nil
        }

        process.terminationHandler = nil
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
