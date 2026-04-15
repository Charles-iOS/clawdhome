// ClawdHome/Views/Capabilities/CronTaskView.swift

import SwiftUI

struct CronTaskView: View {
    @Environment(GatewayService.self) private var gateway

    private var store: GatewayCronStore { gateway.cronStore }

    @State private var showAddSheet = false
    @State private var detailJob: GatewayCronJob?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                contentSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label(L10n.k("common.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .disabled(!gateway.isConnected)
            }
        }
        .task { await gateway.cronStore.refresh() }
        .sheet(isPresented: $showAddSheet) {
            CronAddSheet()
                .presentationBackground(.clear)
        }
        .sheet(item: $detailJob) { job in
            CronJobDetailView(job: job)
                .frame(minWidth: 680, minHeight: 560)
        }
    }

    @ViewBuilder
    private var heroSection: some View {
        HStack(alignment: .top, spacing: 20) {
            PageHeroHeader(
                title: L10n.k("cron.title", fallback: "定时任务"),
                subtitle: L10n.k(
                    "cron.hero.subtitle",
                    fallback: "这里汇总当前账号下的任务：包括你手动新建的，以及在聊天中由智能体创建的定时任务。"
                ),
                subtitleLineLimit: 3
            )

            Spacer(minLength: 16)

            Button {
                showAddSheet = true
            } label: {
                Label(L10n.k("cron.add", fallback: "新建任务"), systemImage: "plus")
                    .font(.system(size: 16, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 22)
                    .frame(height: 56)
                    .foregroundStyle(Color.white)
                    .background(
                        Capsule()
                            .fill(Color.black)
                    )
            }
            .buttonStyle(.plain)
            .disabled(!gateway.isConnected)
            .opacity(gateway.isConnected ? 1 : 0.5)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if let error = store.error, store.jobs.isEmpty {
            ContentUnavailableView(error, systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if store.isLoading && store.jobs.isEmpty {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text(L10n.k("cron.loading", fallback: "正在加载任务…"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 240)
        } else if store.jobs.isEmpty {
            ContentUnavailableView(
                L10n.k("cron.empty", fallback: "暂无定时任务"),
                systemImage: "clock.badge.questionmark",
                description: Text(L10n.k("cron.empty_hint", fallback: "点击右上角“新建任务”创建第一个定时任务。"))
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        } else {
            let columns = [
                GridItem(.flexible(minimum: 360, maximum: 640), spacing: 20),
                GridItem(.flexible(minimum: 360, maximum: 640), spacing: 20)
            ]

            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(store.jobs) { job in
                    CronTaskCard(
                        job: job,
                        onOpen: {
                            store.selectedJobId = job.id
                            detailJob = job
                        },
                        onToggle: {
                            try? await store.toggleEnabled(job: job)
                        }
                    )
                }
            }
        }
    }
}

private struct CronTaskCard: View {
    let job: GatewayCronJob
    let onOpen: () -> Void
    let onToggle: () async -> Void

    @State private var isToggling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(job.displayName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)

                    Text(summaryText)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 12)

                Button {
                    guard !isToggling else { return }
                    isToggling = true
                    Task {
                        await onToggle()
                        isToggling = false
                    }
                } label: {
                    statusSwitch(isOn: job.enabled)
                }
                .buttonStyle(.plain)
                .disabled(isToggling)
            }

            VStack(alignment: .leading, spacing: 10) {
                detailLine(systemImage: "clock", text: scheduleText)
                detailLine(systemImage: "hourglass", text: stateText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 220, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 14, y: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .onTapGesture(perform: onOpen)
    }

    @ViewBuilder
    private func detailLine(systemImage: String, text: String) -> some View {
        Label {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
        }
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

    private var summaryText: String {
        let raw: String
        switch job.payload {
        case let .systemEvent(text):
            raw = text
        case let .agentTurn(message, _, _, _, _, _, _):
            raw = message
        }

        let normalized = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? L10n.k("cron.card.no_summary", fallback: "暂无任务描述") : normalized
    }

    private var scheduleText: String {
        switch job.schedule {
        case let .cron(expr, _):
            return friendlyCronText(expr)
        case let .every(ms, _):
            let seconds = ms / 1000
            if seconds < 60 { return "每 \(seconds) 秒执行一次" }
            if seconds % 3600 == 0 { return "每 \(seconds / 3600) 小时执行一次" }
            return "每 \(seconds / 60) 分钟执行一次"
        case let .at(at):
            if let date = GatewayCronSchedule.parseAtDate(at) {
                return "单次 · \(date.formatted(.dateTime.year().month().day().hour().minute()))"
            }
            return "单次 · \(at)"
        }
    }

    private var stateText: String {
        if let next = job.nextRunDate {
            return "下次执行：\(next.formatted(.dateTime.year().month().day().hour().minute()))"
        }
        if let last = job.lastRunDate {
            return "最近执行：\(last.formatted(.dateTime.year().month().day().hour().minute()))"
        }
        let created = Date(timeIntervalSince1970: TimeInterval(job.createdAtMs) / 1000)
        return "创建于：\(created.formatted(.dateTime.year().month().day().hour().minute()))"
    }

    private func friendlyCronText(_ expr: String) -> String {
        let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count == 5 else { return trimmed }

        let minute = parts[0]
        let hour = parts[1]
        let dayOfMonth = parts[2]
        let month = parts[3]
        let weekday = parts[4]

        if dayOfMonth == "*", month == "*", weekday == "*" {
            return "每天 \(formatTime(hour: hour, minute: minute))"
        }

        let weekdayMap: [String: String] = [
            "1": "周一", "2": "周二", "3": "周三", "4": "周四", "5": "周五", "6": "周六", "0": "周日", "7": "周日"
        ]
        if dayOfMonth == "*", month == "*",
           weekday.contains(",") || weekdayMap[weekday] != nil
        {
            let labels = weekday
                .split(separator: ",")
                .compactMap { weekdayMap[String($0)] }
            if !labels.isEmpty {
                return "\(labels.joined(separator: " ")) \(formatTime(hour: hour, minute: minute))"
            }
        }

        return trimmed
    }

    private func formatTime(hour: String, minute: String) -> String {
        guard let hourInt = Int(hour), let minuteInt = Int(minute) else {
            return "\(hour):\(minute)"
        }
        return String(format: "%02d:%02d", hourInt, minuteInt)
    }
}
