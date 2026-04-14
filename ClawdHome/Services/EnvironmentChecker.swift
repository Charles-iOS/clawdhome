// ClawdHome/Services/EnvironmentChecker.swift
// 检查 bundled OpenClaw 环境是否就绪

import Foundation
import Observation

@MainActor @Observable
final class EnvironmentChecker {

    enum Status: Equatable {
        case unchecked
        case checking
        case ready
        case missing(String)
    }

    private(set) var status: Status = .unchecked

    var isReady: Bool { status == .ready }

    /// 执行一次完整的环境检查
    func check() async {
        status = .checking

        let nodePath = GatewayProcessManager.bundledNodeURL.path
        let openclawPath = GatewayProcessManager.bundledOpenClawEntry.path

        guard FileManager.default.fileExists(atPath: nodePath) else {
            status = .missing("Node.js 未找到: \(nodePath)")
            return
        }

        guard FileManager.default.isExecutableFile(atPath: nodePath) else {
            status = .missing("Node.js 不可执行: \(nodePath)")
            return
        }

        guard FileManager.default.fileExists(atPath: openclawPath) else {
            status = .missing("OpenClaw 未找到: \(openclawPath)")
            return
        }

        ensureOpenClawDir()
        let setupReady = await ensureOpenClawSetupIfNeeded()
        guard setupReady else { return }
        status = .ready
        appLog("EnvironmentChecker: environment ready")
    }

    /// 确保 ~/.openclaw/ 目录及子目录存在
    private func ensureOpenClawDir() {
        let base = GatewayProcessManager.openClawConfigDir.path
        let fm = FileManager.default
        for dir in [base, "\(base)/data", "\(base)/logs"] {
            var isDir: ObjCBool = false
            if !fm.fileExists(atPath: dir, isDirectory: &isDir) {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
        }
        appLog("EnvironmentChecker: ensured ~/.openclaw/ structure")
    }

    /// 在首次安装后补齐 openclaw 初始化，确保 openclaw.json 已生成
    private func ensureOpenClawSetupIfNeeded() async -> Bool {
        let configFile = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("openclaw.json")
        if FileManager.default.fileExists(atPath: configFile.path) {
            return true
        }

        appLog("EnvironmentChecker: openclaw.json missing, running `openclaw setup`")
        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(args: ["setup"])
        guard ok else {
            let reason = output.isEmpty ? "openclaw setup 执行失败" : output
            status = .missing("OpenClaw 初始化失败：\(reason)")
            appLog("EnvironmentChecker: openclaw setup failed: \(reason)", level: .error)
            return false
        }

        guard FileManager.default.fileExists(atPath: configFile.path) else {
            status = .missing("OpenClaw 初始化后未生成配置文件: \(configFile.path)")
            appLog("EnvironmentChecker: setup finished but openclaw.json not found", level: .error)
            return false
        }

        appLog("EnvironmentChecker: openclaw setup complete")
        return true
    }
}
