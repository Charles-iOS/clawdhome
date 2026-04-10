// ClawdHome/Views/Capabilities/CronJobDetailPane.swift

import SwiftUI

struct CronJobDetailView: View {
    let job: GatewayCronJob

    @Environment(GatewayService.self) private var gateway
    @State private var isToggling = false
    @State private var isRunning = false
    @State private var showDeleteConfirm = false

    private var store: GatewayCronStore { gateway.cronStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection
                scheduleSection
                stateSection
                runHistorySection
            }
            .padding(16)
        }
        .task { await store.refreshRuns(jobId: job.id) }
        .alert(L10n.k("cron.delete.title", fallback: "删除任务"), isPresented: $showDeleteConfirm) {
            Button(L10n.k("common.delete", fallback: "删除"), role: .destructive) {
                Task { try? await store.remove(jobId: job.id) }
            }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
        }
    }

    @ViewBuilder
    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.displayName).font(.title2).fontWeight(.semibold)
                if let desc = job.description {
                    Text(desc).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle(isOn: Binding(
                get: { job.enabled },
                set: { _ in toggleEnabled() }
            )) {
                Text(job.enabled
                     ? L10n.k("cron.enabled", fallback: "已启用")
                     : L10n.k("cron.disabled", fallback: "已禁用"))
            }
            .toggleStyle(.switch)
            .disabled(isToggling)
        }

        HStack(spacing: 8) {
            Button {
                Task { await runJob() }
            } label: {
                Label(L10n.k("cron.run_now", fallback: "立即执行"), systemImage: "play.fill")
            }
            .disabled(isRunning)

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(L10n.k("common.delete", fallback: "删除"), systemImage: "trash")
            }
        }
    }

    @ViewBuilder
    private var scheduleSection: some View {
        GroupBox(L10n.k("cron.schedule", fallback: "调度")) {
            LabeledContent(L10n.k("cron.type", fallback: "类型"), value: job.schedule.kind)
            LabeledContent(L10n.k("cron.payload", fallback: "载荷"), value: job.payload.kind)
            LabeledContent(L10n.k("cron.session_target", fallback: "会话目标"), value: job.sessionTarget)
        }
    }

    @ViewBuilder
    private var stateSection: some View {
        GroupBox(L10n.k("cron.state", fallback: "状态")) {
            if let next = job.nextRunDate {
                LabeledContent(L10n.k("cron.next_run", fallback: "下次执行"), value: next.formatted())
            }
            if let last = job.lastRunDate {
                LabeledContent(L10n.k("cron.last_run", fallback: "上次执行"), value: last.formatted())
            }
            if let status = job.state.lastStatus {
                LabeledContent(L10n.k("cron.last_status", fallback: "上次状态"), value: status)
            }
        }
    }

    @ViewBuilder
    private var runHistorySection: some View {
        GroupBox(L10n.k("cron.history", fallback: "执行历史")) {
            if store.runEntries.isEmpty {
                Text(L10n.k("cron.no_history", fallback: "暂无执行记录"))
                    .foregroundStyle(.secondary)
                    .font(.caption)
            } else {
                ForEach(store.runEntries.prefix(20)) { entry in
                    HStack {
                        Text(entry.date.formatted(.dateTime.hour().minute().second()))
                            .font(.caption.monospacedDigit())
                        Text(entry.action)
                            .font(.caption)
                        Spacer()
                        if let status = entry.status {
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(status == "ok" ? .green : .red)
                        }
                    }
                }
            }
        }
    }

    private func toggleEnabled() {
        isToggling = true
        Task {
            try? await store.toggleEnabled(job: job)
            isToggling = false
        }
    }

    private func runJob() async {
        isRunning = true
        try? await store.run(jobId: job.id)
        await store.refreshRuns(jobId: job.id)
        isRunning = false
    }
}
