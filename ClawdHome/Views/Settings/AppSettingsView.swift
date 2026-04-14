// ClawdHome/Views/Settings/SettingsView.swift

import SwiftUI

struct AppSettingsView: View {
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(EnvironmentChecker.self) private var envChecker

    var body: some View {
        VStack(spacing: 0) {
            PageHeroHeader(
                title: L10n.k("settings.title", fallback: "设置"),
                subtitle: L10n.k("settings.hero.subtitle", fallback: "Gateway、运行环境与版本信息。")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            Form {
                gatewaySection
                environmentSection
                aboutSection
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var gatewaySection: some View {
        Section(L10n.k("settings.gateway", fallback: "Gateway")) {
            LabeledContent(
                L10n.k("settings.port", fallback: "端口"),
                value: "\(processManager.gatewayPort)"
            )
            LabeledContent(
                L10n.k("settings.state", fallback: "状态"),
                value: stateLabel
            )
        }
    }

    @ViewBuilder
    private var environmentSection: some View {
        Section(L10n.k("settings.environment", fallback: "环境")) {
            LabeledContent(
                "Node.js",
                value: GatewayProcessManager.bundledNodeURL.path
            )
            LabeledContent(
                "OpenClaw",
                value: GatewayProcessManager.bundledOpenClawEntry.path
            )
            switch envChecker.status {
            case .ready:
                LabeledContent(
                    L10n.k("settings.env_status", fallback: "环境状态"),
                    value: L10n.k("settings.env_ready", fallback: "就绪")
                )
            case .missing(let msg):
                LabeledContent(
                    L10n.k("settings.env_status", fallback: "环境状态"),
                    value: msg
                )
            default:
                EmptyView()
            }
            Button(L10n.k("settings.recheck", fallback: "重新检查")) {
                Task { await envChecker.check() }
            }
        }
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section(L10n.k("settings.about", fallback: "关于")) {
            LabeledContent(
                L10n.k("settings.version", fallback: "版本"),
                value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
            )
            LabeledContent(
                L10n.k("settings.build", fallback: "构建号"),
                value: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
            )
        }
    }

    private var stateLabel: String {
        switch processManager.state {
        case .running: return L10n.k("dashboard.running", fallback: "运行中")
        case .stopping: return L10n.k("dashboard.stopping", fallback: "正在停止…")
        case .starting: return L10n.k("dashboard.starting", fallback: "正在启动…")
        case .stopped: return L10n.k("dashboard.stopped", fallback: "已停止")
        case .failed(let msg): return msg
        }
    }
}
