// EZRWorkerApp/Views/Capabilities/ChannelBindSheet.swift
// 渠道绑定终端面板：直接在当前用户下运行 npx 命令

import SwiftUI

struct ChannelBindSheet: View {
    let skill: GatewaySkillStatus
    @Environment(\.dismiss) private var dismiss

    @State private var output = ""
    @State private var isRunning = false
    @State private var exitCode: Int32?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(skill.emoji ?? "💬")
                    .font(.title)
                Text(String(format: L10n.k("channel.bind.title", fallback: "绑定 %@"), skill.name))
                    .font(.title3)
                    .fontWeight(.semibold)
                Spacer()
                if isRunning {
                    ProgressView().controlSize(.small)
                    Text(L10n.k("channel.bind.running", fallback: "安装中…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(output.isEmpty ? L10n.k("channel.bind.waiting", fallback: "等待启动…") : output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                if let code = exitCode {
                    Text(code == 0
                         ? L10n.k("channel.bind.success", fallback: "绑定完成")
                         : String(format: L10n.k("channel.bind.failed", fallback: "退出码: %d"), code))
                        .font(.caption)
                        .foregroundStyle(code == 0 ? .green : .red)
                }
                Spacer()
                Button(L10n.k("common.close", fallback: "关闭")) { dismiss() }
            }
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 400)
        .task { await runInstall() }
    }

    private func runInstall() async {
        isRunning = true
        defer { isRunning = false }

        let npxURL = GatewayProcessManager.bundledNpxURL

        let proc = Process()
        proc.executableURL = npxURL
        proc.arguments = ["-y", skill.source, "install"]
        proc.environment = GatewayProcessManager.buildEnvironment()
        proc.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in output += chunk }
        }

        do {
            try proc.run()
            proc.waitUntilExit()
            exitCode = proc.terminationStatus
        } catch {
            output += "\nError: \(error.localizedDescription)"
            exitCode = -1
        }

        pipe.fileHandleForReading.readabilityHandler = nil
    }
}
