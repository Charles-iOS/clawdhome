// ClawdHome/Views/Settings/SettingsView.swift

import SwiftUI

struct AppSettingsView: View {
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(EnvironmentChecker.self) private var envChecker
    @Environment(GatewayService.self) private var gatewayService
    @Environment(AuthSessionStore.self) private var authStore

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
                accountSection
                gatewaySection
                environmentSection
                aboutSection
            }
            .formStyle(.grouped)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var accountSection: some View {
        Section(L10n.k("auth.settings.section", fallback: "账户")) {
            LabeledContent(
                L10n.k("auth.settings.phone", fallback: "当前登录手机号"),
                value: authStore.currentUser.map { displayMainlandChinaPhone($0.phone) } ?? "—"
            )
            LabeledContent(
                L10n.k("auth.settings.display_name", fallback: "显示名称"),
                value: authStore.currentUser?.displayName ?? "—"
            )

            Button(role: .destructive) {
                Task {
                    await authStore.signOut()
                }
            } label: {
                Text(L10n.k("auth.settings.sign_out", fallback: "退出登录"))
            }
        }
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
            LabeledContent(
                L10n.k("dashboard.gateway_status", fallback: "WebSocket"),
                value: gatewayService.isConnected
                    ? L10n.k("dashboard.connected", fallback: "已连接")
                    : L10n.k("dashboard.disconnected", fallback: "未连接")
            )

            HStack(spacing: 12) {
                Button(L10n.k("user.detail.auto.start_action", fallback: "启动")) {
                    processManager.start()
                }
                .buttonStyle(.borderedProminent)
                .disabled(processManager.state == .starting || processManager.state == .running)

                Button(L10n.k("user.detail.auto.restart", fallback: "重启")) {
                    processManager.restart()
                }
                .buttonStyle(.bordered)
                .disabled(processManager.state == .starting || processManager.state == .stopping)

                Button(L10n.k("user.detail.auto.stop", fallback: "停止")) {
                    processManager.stop()
                }
                .buttonStyle(.bordered)
                .disabled(processManager.state == .stopped || processManager.state == .stopping)
            }

            Text(gatewayActionHint)
                .font(.caption)
                .foregroundStyle(.secondary)
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

    private var gatewayActionHint: String {
        switch processManager.state {
        case .running:
            return gatewayService.isConnected
                ? "Gateway 正在运行，可在这里重启或停止。"
                : "Gateway 进程已启动，正在等待连接恢复。"
        case .starting:
            return "Gateway 正在启动中，请稍候。"
        case .stopping:
            return "Gateway 正在停止中，请稍候。"
        case .stopped:
            return "Gateway 当前已停止，可在这里重新启动。"
        case .failed:
            return "Gateway 当前处于异常状态，建议尝试重启。"
        }
    }
}
