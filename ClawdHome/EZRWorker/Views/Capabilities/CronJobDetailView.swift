// ClawdHome/Views/Capabilities/CronJobDetailView.swift

import SwiftUI

struct CronJobDetailView: View {
    let job: GatewayCronJob

    @Environment(GatewayService.self) private var gateway
    @Environment(AgentStore.self) private var agentStore
    @Environment(\.dismiss) private var dismiss

    @State private var isToggling = false
    @State private var isRunning = false
    @State private var showDeleteConfirm = false
    @State private var runFeedback: String?
    @State private var runErrorText: String?
    @State private var toggleErrorText: String?
    @State private var isAutoRefreshing = false

    private var store: GatewayCronStore { gateway.cronStore }
    private var currentJob: GatewayCronJob {
        store.jobs.first(where: { $0.id == job.id }) ?? job
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                if let toggleErrorText, !toggleErrorText.isEmpty {
                    feedbackBanner(text: toggleErrorText, color: .red)
                }
                if let runErrorText, !runErrorText.isEmpty {
                    feedbackBanner(text: runErrorText, color: .red)
                } else if let runFeedback, !runFeedback.isEmpty {
                    feedbackBanner(text: runFeedback, color: .green)
                }
                overviewSection
                payloadSection
                stateSection
                runHistorySection
            }
            .padding(28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .background(Color.white)
        .overlay(alignment: .topTrailing) {
            floatingHeaderActions
                .padding(.top, 20)
                .padding(.trailing, 20)
        }
        .task {
            await refreshDetail()
            await startAutoRefreshLoop()
        }
        .alert(L10n.k("cron.delete.title", fallback: "删除任务"), isPresented: $showDeleteConfirm) {
            Button(L10n.k("common.delete", fallback: "删除"), role: .destructive) {
                Task {
                    try? await store.remove(jobId: job.id)
                    dismiss()
                }
            }
            Button(L10n.k("common.cancel", fallback: "取消"), role: .cancel) {}
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(currentJob.displayName)
                        .font(.system(size: 30, weight: .bold))

                    Text(jobStatusSummary)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            if let descriptionText = detailDescription {
                Text(descriptionText)
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                Button {
                    Task { await runJob() }
                } label: {
                    Label(isRunning ? "执行中..." : L10n.k("cron.run_now", fallback: "立即执行"), systemImage: isRunning ? "hourglass" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(height: 48)
                        .padding(.horizontal, 18)
                }
                .buttonStyle(.plain)
                .background(
                    Capsule()
                        .fill(Color.black)
                )
                .foregroundStyle(.white)
                .disabled(isRunning)
            }
        }
    }

    private var floatingHeaderActions: some View {
        HStack(spacing: 10) {
            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.red)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.98))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.red.opacity(0.12), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.98))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.black.opacity(0.08), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 4)
    }

    private func feedbackBanner(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(color.opacity(0.08))
            )
    }

    private func statusSwitch(isOn: Bool) -> some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule()
                .fill(isOn ? Color.green : Color.black.opacity(0.10))
                .frame(width: 52, height: 32)

            Circle()
                .fill(Color.white)
                .frame(width: 28, height: 28)
                .padding(2)
                .shadow(color: Color.black.opacity(0.12), radius: 3, y: 1)
        }
        .opacity(isToggling ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.18), value: isOn)
    }

    private func refreshDetail() async {
        await store.refresh()
        await store.refreshRuns(jobId: job.id)
    }

    private func startAutoRefreshLoop() async {
        guard !isAutoRefreshing else { return }
        isAutoRefreshing = true
        defer { isAutoRefreshing = false }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { break }
            await refreshDetail()
        }
    }

    private var overviewSection: some View {
        detailCard(title: "任务信息") {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("启用状态")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(currentJob.enabled ? "当前任务已启用" : "当前任务已禁用")
                        .font(.system(size: 18))
                }
                Spacer()
                Button {
                    toggleEnabled()
                } label: {
                    HStack(spacing: 12) {
                        Text(currentJob.enabled
                             ? L10n.k("cron.enabled", fallback: "已启用")
                             : L10n.k("cron.disabled", fallback: "已禁用"))
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        statusSwitch(isOn: currentJob.enabled)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isToggling)
            }

            Divider()
            detailRow("任务 ID", currentJob.id)
            detailRow("调度类型", scheduleKindLabel)
            detailRow("调度规则", scheduleDescription)
            detailRow("消息类型", payloadKindLabel)
            detailRow("目标智能体", displayAgentTarget)
            detailRow("发送目标", displaySessionTarget, multiline: true)
            detailRow("唤醒方式", currentJob.wakeMode)
            detailRow("执行后删除", yesNo(currentJob.deleteAfterRun ?? false))
            detailRow("创建时间", formatDate(ms: currentJob.createdAtMs))
            detailRow("更新时间", formatDate(ms: currentJob.updatedAtMs))
        }
    }

    private var payloadSection: some View {
        detailCard(title: "消息内容") {
            detailRow("摘要", summaryText, multiline: true)
            switch currentJob.payload {
            case let .systemEvent(text):
                detailRow("系统事件文本", text, multiline: true)
            case let .agentTurn(message, thinking, timeoutSeconds, deliver, channel, to, bestEffortDeliver):
                detailRow("消息内容", message, multiline: true)
                if let thinking, !thinking.isEmpty {
                    detailRow("思考提示", thinking, multiline: true)
                }
                if let timeoutSeconds {
                    detailRow("超时时间", "\(timeoutSeconds) 秒")
                }
                if let deliver {
                    detailRow("允许投递", yesNo(deliver))
                }
                if let bestEffortDeliver {
                    detailRow("尽力投递", yesNo(bestEffortDeliver))
                }
                if let channel, !channel.isEmpty {
                    detailRow("渠道", channel)
                }
                if let to, !to.isEmpty {
                    detailRow("目标", to)
                }
            }
        }
    }

    private var displaySessionTarget: String {
        formatCronSessionTarget(currentJob.sessionTarget)
    }

    private var displayAgentTarget: String {
        let explicit = currentJob.agentId?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, !explicit.isEmpty {
            return displayName(forAgentID: explicit)
        }
        if let derived = agentIDFromSessionTarget(currentJob.sessionTarget) {
            return "\(displayName(forAgentID: derived))（由会话推断）"
        }
        return "默认智能体"
    }

    private func formatCronSessionTarget(_ target: String) -> String {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未设置" }

        switch trimmed {
        case "main":
            return "主会话"
        case "isolated":
            return "隔离会话"
        case "current":
            return "当前会话"
        default:
            break
        }

        if trimmed.hasPrefix("session:") {
            let sessionID = String(trimmed.dropFirst("session:".count))
            if let agentID = agentIDFromSessionIdentifier(sessionID) {
                return "指定会话 · \(displayName(forAgentID: agentID))\n\(sessionID)"
            }
            return "指定会话\n\(sessionID)"
        }

        return trimmed
    }

    private func agentIDFromSessionTarget(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("session:") else { return nil }
        let sessionID = String(trimmed.dropFirst("session:".count))
        return agentIDFromSessionIdentifier(sessionID)
    }

    private func agentIDFromSessionIdentifier(_ sessionID: String) -> String? {
        let parts = sessionID.split(separator: ":").map(String.init)
        guard parts.count >= 2, parts[0] == "agent" else { return nil }
        return parts[1]
    }

    private func displayName(forAgentID agentID: String) -> String {
        guard let agent = agentStore.agents.first(where: { $0.id == agentID }) else { return agentID }
        return displayName(for: agent)
    }

    private func displayName(for agent: Agent) -> String {
        let emoji = agent.emoji.trimmingCharacters(in: .whitespacesAndNewlines)
        return emoji.isEmpty ? agent.name : "\(emoji) \(agent.name)"
    }

    private var stateSection: some View {
        detailCard(title: "运行状态") {
            if let next = currentJob.state.nextRunAtMs {
                detailRow("下次执行", formatDate(ms: next))
            }
            if let running = currentJob.state.runningAtMs {
                detailRow("当前运行中", formatDate(ms: running))
            }
            if let last = currentJob.state.lastRunAtMs {
                detailRow("上次执行", formatDate(ms: last))
            }
            if let status = currentJob.state.lastStatus, !status.isEmpty {
                detailRow("上次状态", status)
            }
            if let duration = currentJob.state.lastDurationMs {
                detailRow("上次耗时", formatDuration(ms: duration))
            }
            if let error = currentJob.state.lastError, !error.isEmpty {
                detailRow("上次错误", error, multiline: true, valueColor: .red)
            }
            if currentJob.state.nextRunAtMs == nil,
               currentJob.state.runningAtMs == nil,
               currentJob.state.lastRunAtMs == nil,
               currentJob.state.lastStatus == nil,
               currentJob.state.lastError == nil {
                Text("这条任务还没有产生可展示的状态信息。")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var runHistorySection: some View {
        detailCard(title: "执行历史") {
            if store.runEntries.isEmpty {
                Text(L10n.k("cron.no_history", fallback: "暂无执行记录"))
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.runEntries.prefix(20)) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(entry.date.formatted(.dateTime.year().month().day().hour().minute().second()))
                                .font(.system(size: 15, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)

                            Text(entry.action)
                                .font(.system(size: 17, weight: .semibold))

                            Spacer()

                            if let status = entry.status {
                                Text(status)
                                    .font(.system(size: 14, weight: .semibold))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(status == "ok" ? Color.green.opacity(0.12) : Color.red.opacity(0.12))
                                    )
                                    .foregroundStyle(status == "ok" ? .green : .red)
                            }
                        }

                        if let summary = entry.summary, !summary.isEmpty {
                            Text(summary)
                                .font(.system(size: 16))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let error = entry.error, !error.isEmpty {
                            Text(error)
                                .font(.system(size: 15))
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if let duration = entry.durationMs {
                            Text("耗时：\(formatDuration(ms: duration))")
                                .font(.system(size: 15))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 12)

                    if entry.id != store.runEntries.prefix(20).last?.id {
                        Divider()
                    }
                }
            }
        }
    }

    private func detailCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.system(size: 22, weight: .bold))

            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func detailRow(
        _ title: String,
        _ value: String,
        multiline: Bool = false,
        valueColor: Color? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(value.isEmpty ? "-" : value)
                .font(.system(size: 18))
                .foregroundStyle(valueColor ?? .primary)
                .fixedSize(horizontal: false, vertical: multiline)
        }
    }

    private var detailDescription: String? {
        let raw = currentJob.description?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let raw, !raw.isEmpty { return raw }
        return summaryText
    }

    private var summaryText: String {
        switch currentJob.payload {
        case let .systemEvent(text):
            return normalizedText(text)
        case let .agentTurn(message, _, _, _, _, _, _):
            return normalizedText(message)
        }
    }

    private var scheduleKindLabel: String {
        switch currentJob.schedule {
        case .at: return "单次"
        case .every: return "间隔"
        case .cron: return "Cron"
        }
    }

    private var scheduleDescription: String {
        switch currentJob.schedule {
        case let .at(at):
            if let date = GatewayCronSchedule.parseAtDate(at) {
                return date.formatted(.dateTime.year().month().day().hour().minute())
            }
            return at
        case let .every(everyMs, anchorMs):
            let base = "每 \(formatDuration(ms: everyMs)) 执行一次"
            guard let anchorMs else { return base }
            return "\(base) · 锚点 \(formatDate(ms: anchorMs))"
        case let .cron(expr, tz):
            return tz.map { "\(expr) (\($0))" } ?? expr
        }
    }

    private var payloadKindLabel: String {
        switch currentJob.payload {
        case .systemEvent: return "系统事件"
        case .agentTurn: return "智能体消息"
        }
    }

    private var jobStatusSummary: String {
        if let running = currentJob.state.runningAtMs {
            return "正在执行中，自 \(formatDate(ms: running)) 开始"
        }
        if let next = currentJob.state.nextRunAtMs {
            return "下次执行：\(formatDate(ms: next))"
        }
        if let last = currentJob.state.lastRunAtMs {
            return "最近执行：\(formatDate(ms: last))"
        }
        return "等待首次执行"
    }

    private func normalizedText(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "暂无内容" : trimmed
    }

    private func yesNo(_ value: Bool) -> String {
        value ? "是" : "否"
    }

    private func formatDate(ms: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            .formatted(.dateTime.year().month().day().hour().minute().second())
    }

    private func formatDuration(ms: Int) -> String {
        if ms < 1000 { return "\(ms) 毫秒" }
        let seconds = ms / 1000
        if seconds < 60 { return "\(seconds) 秒" }
        if seconds % 3600 == 0 { return "\(seconds / 3600) 小时" }
        if seconds % 60 == 0 { return "\(seconds / 60) 分钟" }
        return "\(seconds) 秒"
    }

    private func toggleEnabled() {
        isToggling = true
        toggleErrorText = nil
        Task {
            do {
                try await store.toggleEnabled(job: currentJob)
                await refreshDetail()
            } catch {
                toggleErrorText = error.localizedDescription
            }
            isToggling = false
        }
    }

    private func runJob() async {
        isRunning = true
        runFeedback = nil
        runErrorText = nil

        do {
            try await store.run(jobId: job.id)
            for _ in 0..<6 {
                await refreshDetail()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            runFeedback = "已触发立即执行，正在刷新状态。"
        } catch {
            runErrorText = error.localizedDescription
        }
        isRunning = false
    }
}
