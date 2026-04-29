import SwiftUI

struct ExistingOpenClawImportView: View {
    let candidates: [OpenClawInstanceCandidate]

    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(SupervisorClient.self) private var supervisorClient
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIDs: Set<UUID>
    @State private var managementModes: [UUID: GatewayProfileManagementMode]
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(candidates: [OpenClawInstanceCandidate]) {
        self.candidates = candidates
        let selected = Set(candidates.filter { $0.riskLevel != .blocked }.map(\.id))
        _selectedIDs = State(initialValue: selected)
        _managementModes = State(initialValue: Dictionary(
            uniqueKeysWithValues: candidates.map { candidate in
                let defaultMode = Self.defaultManagementMode(for: candidate)
                return (candidate.id, defaultMode)
            }
        ))
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 18) {
                header

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(candidates) { candidate in
                            candidateRow(candidate)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(maxHeight: 520)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                footer
            }
            .padding(28)
            .frame(maxWidth: 940, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("发现已有 OpenClaw")
                .font(.title2.weight(.semibold))
            Text("选择要接入 EZRWorker 的实例。仅观察不会停止、重启或改写原配置；交给 EZRWorker 托管后才允许 App 启动和停止该实例。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("跳过，创建新的默认 Profile") {
                skipImport()
            }
            .disabled(isSubmitting)

            Spacer()

            Button("刷新") {
                profileStore.reloadFromDiskOrBootstrap()
            }
            .disabled(isSubmitting)

            Button {
                importSelected()
            } label: {
                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("导入选中项")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || selectedImportableCandidates.isEmpty)
        }
    }

    private func candidateRow(_ candidate: OpenClawInstanceCandidate) -> some View {
        let isBlocked = candidate.riskLevel == .blocked
        let isSelected = selectedIDs.contains(candidate.id)
        let managementMode = managementModes[candidate.id] ?? .observeOnly

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Toggle("", isOn: Binding(
                    get: { selectedIDs.contains(candidate.id) },
                    set: { selected in
                        if selected {
                            selectedIDs.insert(candidate.id)
                        } else {
                            selectedIDs.remove(candidate.id)
                        }
                    }
                ))
                .labelsHidden()
                .disabled(isBlocked || isSubmitting)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(candidate.displayNameSuggestion)
                            .font(.headline)
                            .lineLimit(1)

                        statusPill(sourceLabel(candidate.source), color: .blue)
                        statusPill(riskLabel(candidate.riskLevel), color: riskColor(candidate.riskLevel))

                        if let pid = candidate.pid {
                            statusPill("PID \(pid)", color: .green)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        pathLine("Config", candidate.configPath)
                        pathLine("State", candidate.stateDir)
                        if let workspaceRoot = candidate.workspaceRoot {
                            pathLine("Workspace", workspaceRoot)
                        }
                    }

                    HStack(spacing: 14) {
                        Text("端口：\(candidate.port.map(String.init) ?? "待确认")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("slug：\(candidate.slugSuggestion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !candidate.warnings.isEmpty {
                        Text(candidate.warnings.joined(separator: "；"))
                            .font(.caption)
                            .foregroundStyle(candidate.riskLevel == .blocked ? .red : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if EZRWorkerBuildFlavor.isDev && managementMode == .managedByEZRWorker {
                        Label(
                            "Debug 版托管外部 OpenClaw 会写入该实例的 openclaw.json；仅观察不会写入配置。",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 12)

                Picker("接管模式", selection: Binding(
                    get: { managementModes[candidate.id] ?? .observeOnly },
                    set: { managementModes[candidate.id] = $0 }
                )) {
                    Text("仅观察").tag(GatewayProfileManagementMode.observeOnly)
                    Text("托管").tag(GatewayProfileManagementMode.managedByEZRWorker)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .disabled(isBlocked || !isSelected || isSubmitting)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.56))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.08))
        )
    }

    private func pathLine(_ title: String, _ path: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(path)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func statusPill(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }

    private var selectedImportableCandidates: [OpenClawInstanceCandidate] {
        candidates.filter { selectedIDs.contains($0.id) && $0.riskLevel != .blocked }
    }

    private static func defaultManagementMode(for candidate: OpenClawInstanceCandidate) -> GatewayProfileManagementMode {
        if EZRWorkerBuildFlavor.isDev {
            return .observeOnly
        }
        return candidate.pid == nil && candidate.riskLevel == .safe
            ? .managedByEZRWorker
            : .observeOnly
    }

    private func importSelected() {
        guard !isSubmitting else { return }
        guard !selectedImportableCandidates.isEmpty else {
            errorMessage = "请选择至少一个可导入的 OpenClaw 实例"
            return
        }

        isSubmitting = true
        errorMessage = nil

        do {
            for candidate in selectedImportableCandidates {
                let mode = managementModes[candidate.id] ?? .observeOnly
                _ = try profileStore.importExternalProfile(
                    candidate: candidate,
                    autoStart: mode == .managedByEZRWorker,
                    managementMode: mode
                )
            }
            Task {
                var isSupervisorConnected = supervisorClient.isConnected
                if !isSupervisorConnected {
                    isSupervisorConnected = await connectSupervisorIfPossible()
                }
                if isSupervisorConnected {
                    _ = await supervisorClient.reloadProfiles()
                    await processManager.refreshRuntimeState()
                }
                dismiss()
            }
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }

    private func skipImport() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil

        do {
            try profileStore.skipExistingOpenClawImportAndCreateManagedProfile()
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }

    private func connectSupervisorIfPossible() async -> Bool {
        supervisorClient.connect()
        return await supervisorClient.waitUntilConnected()
    }

    private func sourceLabel(_ source: OpenClawDiscoverySource) -> String {
        switch source {
        case .runningProcess:
            return "运行中"
        case .launchAgent:
            return "LaunchAgent"
        case .knownDirectory:
            return "本地目录"
        case .manualSelection:
            return "手动选择"
        }
    }

    private func riskLabel(_ risk: OpenClawDiscoveryRiskLevel) -> String {
        switch risk {
        case .safe:
            return "可导入"
        case .needsReview:
            return "需确认"
        case .blocked:
            return "不可导入"
        }
    }

    private func riskColor(_ risk: OpenClawDiscoveryRiskLevel) -> Color {
        switch risk {
        case .safe:
            return .green
        case .needsReview:
            return .orange
        case .blocked:
            return .red
        }
    }
}
