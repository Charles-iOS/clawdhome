// ClawdHome/Views/Capabilities/CronAddSheet.swift

import SwiftUI

struct CronAddSheet: View {
    @Environment(GatewayService.self) private var gateway
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var cronExpr = "0 9 * * *"
    @State private var message = ""
    @State private var isSaving = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.k("cron.add.basic", fallback: "基本信息")) {
                    TextField(L10n.k("cron.add.name", fallback: "任务名称"), text: $name)
                }
                Section(L10n.k("cron.add.schedule_section", fallback: "调度")) {
                    TextField(L10n.k("cron.add.cron_expr", fallback: "Cron 表达式"), text: $cronExpr)
                        .font(.system(.body, design: .monospaced))
                    Text(L10n.k("cron.add.cron_hint", fallback: "例如 '0 9 * * *' = 每天上午 9 点"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section(L10n.k("cron.add.payload_section", fallback: "消息内容")) {
                    TextEditor(text: $message)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 80)
                }
                if let err = errorText {
                    Text(err).foregroundStyle(.red).font(.caption)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(L10n.k("cron.add.title", fallback: "新建定时任务"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.k("common.create", fallback: "创建")) { Task { await create() } }
                        .disabled(name.isEmpty || message.isEmpty || isSaving)
                }
            }
        }
        .frame(minWidth: 440, minHeight: 380)
    }

    private func create() async {
        isSaving = true
        defer { isSaving = false }

        let params = GatewayCronAddParams(
            name: name,
            description: nil,
            enabled: true,
            deleteAfterRun: nil,
            schedule: .cron(expr: cronExpr, tz: nil),
            sessionTarget: "main",
            wakeMode: "now",
            payload: .agentTurn(
                message: message,
                thinking: nil,
                timeoutSeconds: nil,
                deliver: true,
                channel: nil,
                to: nil,
                bestEffortDeliver: true
            )
        )

        do {
            try await gateway.cronStore.add(params)
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
