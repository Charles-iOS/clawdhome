// ClawdHome/Views/Capabilities/CronTaskView.swift

import SwiftUI

struct CronTaskView: View {
    @Environment(GatewayService.self) private var gateway

    private var store: GatewayCronStore { gateway.cronStore }

    @State private var showAddSheet = false

    var body: some View {
        VStack(spacing: 0) {
            PageHeroHeader(
                title: L10n.k("cron.title", fallback: "定时任务"),
                subtitle: L10n.k("cron.hero.subtitle", fallback: "管理 Gateway 定时任务与执行计划。")
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            HSplitView {
                jobList
                    .frame(minWidth: 240, idealWidth: 280)
                jobDetail
                    .frame(minWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.k("cron.add", fallback: "新建任务"), systemImage: "plus")
                }
                .disabled(!gateway.isConnected)
            }
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
        }
    }

    @ViewBuilder
    private var jobList: some View {
        @Bindable var s = store
        List(selection: $s.selectedJobId) {
            if store.isLoading && store.jobs.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if store.jobs.isEmpty {
                Text(L10n.k("cron.empty", fallback: "暂无定时任务"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                ForEach(store.jobs) { job in
                    CronJobRow(job: job)
                        .tag(job.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var jobDetail: some View {
        if let jobId = store.selectedJobId,
           let job = store.jobs.first(where: { $0.id == jobId }) {
            CronJobDetailView(job: job)
        } else {
            ContentUnavailableView(
                L10n.k("cron.select_job", fallback: "选择一个任务"),
                systemImage: "clock.badge.questionmark"
            )
        }
    }
}

// MARK: - Job Row

private struct CronJobRow: View {
    let job: GatewayCronJob

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayName)
                    .lineLimit(1)
                Text(scheduleLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Circle()
                .fill(job.enabled ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 2)
    }

    private var scheduleLabel: String {
        switch job.schedule {
        case .cron(let expr, _): return expr
        case .every(let ms, _): return "every \(ms / 1000)s"
        case .at(let at): return at
        }
    }
}
