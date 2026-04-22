// EZRWorkerApp/Views/Capabilities/ChannelPairingSheet.swift
// 渠道配对管理：审批待配对请求、查看已配对用户/群组、手动添加/移除配对
//
// 配对流程：
//   1. 用户给 bot 发消息 → bot 返回 pairing code
//   2. bot owner 在此界面审批（approve）或拒绝（reject）
//   3. 审批通过后用户即可正常对话
//
// 底层命令：
//   openclaw pairing list <channel> --json
//   openclaw pairing approve <channel> <code>
//   openclaw pairing reject <channel> <code>
//   openclaw pairing add <channel> <peerId> [--kind group]
//   openclaw pairing remove <channel> <peerId>

import SwiftUI

struct ChannelPairingSheet: View {
    private enum SheetFont {
        static let title: CGFloat = 20
        static let subtitle: CGFloat = 15
        static let section: CGFloat = 15
        static let body: CGFloat = 15
        static let meta: CGFloat = 13
        static let mono: CGFloat = 13
        static let action: CGFloat = 16
    }

    let channelType: ChannelType

    @Environment(GatewayService.self) private var gateway
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @State private var pendingRequests: [PairingRequest] = []
    @State private var approvedPeers: [PairingPeer] = []
    @State private var isLoading = false
    @State private var hasLoadedOnce = false
    @State private var errorMessage: String?
    @State private var successMessage: String?

    // 手动审批码输入
    @State private var manualCode = ""
    @State private var isApproving = false

    // 移除确认
    @State private var peerToRemove: PairingPeer?

    // 自动刷新
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    private var selectedResolution: GatewayProfileResolution? { profileStore.selectedResolution }
    private var selectedLocalPaths: GatewayProfileLocalPaths? { profileStore.selectedLocalPaths }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            contentArea
            Divider()
            bottomBar
        }
        .frame(minWidth: 520, minHeight: 440)
        .task { await loadAll() }
        .onReceive(refreshTimer) { _ in
            Task { await loadAll() }
        }
        .alert(
            "确认移除",
            isPresented: Binding(
                get: { peerToRemove != nil },
                set: { if !$0 { peerToRemove = nil } }
            ),
            presenting: peerToRemove
        ) { peer in
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                Task { await removePeer(peer) }
            }
        } message: { peer in
            Text("将移除 \(peer.displayName ?? peer.id) 的配对关系，该用户将无法继续与机器人对话。")
        }
    }

    // MARK: - 标题

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            channelType.iconView(size: 24, weight: .medium)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(channelType.displayName) · 配对管理")
                    .font(.system(size: SheetFont.title, weight: .semibold))
                Text("审批配对请求，管理已授权的用户和群组")
                    .font(.system(size: SheetFont.subtitle))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            }
            Button {
                Task { await loadAll() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .disabled(isLoading)
        }
        .padding(20)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        if !hasLoadedOnce {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    messageSection
                    approveCodeSection
                    if !pendingRequests.isEmpty {
                        pendingSection
                    }
                    approvedSection
                }
                .padding(20)
            }
        }
    }

    // MARK: - 消息提示

    @ViewBuilder
    private var messageSection: some View {
        if let successMessage {
            sectionCard {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: SheetFont.body, weight: .medium))
                    .foregroundStyle(.green)
            }
        }
        if let errorMessage {
            sectionCard {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: SheetFont.body, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 手动输入配对码审批

    @ViewBuilder
    private var approveCodeSection: some View {
        sectionBlock(
            title: "配对审批",
            systemImage: "key.fill"
        ) {
            VStack(alignment: .leading, spacing: 8) {
                Text("用户给机器人发消息后会收到一个配对码，在此输入即可审批通过。")
                    .font(.system(size: SheetFont.body))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("输入配对码（如 LHSTVRP9）", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: SheetFont.body, design: .monospaced))
                    Button {
                        Task { await approveCode(manualCode) }
                    } label: {
                        Label("审批通过", systemImage: "checkmark.circle")
                    }
                    .font(.system(size: SheetFont.action, weight: .semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApproving)
                }
            }
        }
    }

    // MARK: - 待审批请求列表

    @ViewBuilder
    private var pendingSection: some View {
        sectionBlock(
            title: "待审批请求",
            systemImage: "bell.badge",
            trailing: {
                Text("\(pendingRequests.count)")
                    .font(.system(size: SheetFont.meta, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        ) {
            VStack(spacing: 10) {
                ForEach(pendingRequests) { request in
                    pendingRequestRow(request)
                }
            }
        }
    }

    @ViewBuilder
    private func pendingRequestRow(_ request: PairingRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let name = request.displayName {
                        Text(name)
                            .font(.system(size: SheetFont.body, weight: .semibold))
                            .fontWeight(.medium)
                    }
                    Text("ID: \(request.userId)")
                        .font(.system(size: SheetFont.mono, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("配对码")
                        .font(.system(size: SheetFont.meta))
                        .foregroundStyle(.secondary)
                    Text(request.code)
                        .font(.system(size: SheetFont.mono, design: .monospaced))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let ts = request.requestedAt {
                        Text(ts)
                            .font(.system(size: SheetFont.meta))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Spacer()

            // 审批 / 拒绝按钮
            Button {
                Task { await approveCode(request.code) }
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .help("审批通过")

            Button {
                Task { await rejectCode(request.code) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red.opacity(0.7))
            .help("拒绝")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 已配对列表

    @ViewBuilder
    private var approvedSection: some View {
        sectionBlock(
            title: "已配对 (\(approvedPeers.count))",
            systemImage: "person.crop.circle.badge.checkmark"
        ) {
            if approvedPeers.isEmpty {
                Text("暂无已配对的用户")
                    .font(.system(size: SheetFont.body))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 10) {
                    ForEach(approvedPeers) { peer in
                        approvedPeerRow(peer)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func approvedPeerRow(_ peer: PairingPeer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: peer.isGroup ? "person.3.fill" : "person.fill")
                .foregroundStyle(.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(peer.displayName ?? peer.id)
                    .font(.system(size: SheetFont.body, weight: .semibold))
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(peer.kindLabel)
                        .font(.system(size: SheetFont.meta))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(peer.isGroup ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
                        .foregroundStyle(peer.isGroup ? .purple : .blue)
                        .clipShape(Capsule())
                    Text("ID: \(peer.id)")
                        .font(.system(size: SheetFont.mono, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ts = peer.pairedAt {
                Text(ts)
                    .font(.system(size: SheetFont.meta))
                    .foregroundStyle(.tertiary)
            }

            Button(role: .destructive) {
                peerToRemove = peer
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 底栏

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            if !pendingRequests.isEmpty {
                Text("\(pendingRequests.count) 个待审批")
                    .font(.system(size: SheetFont.meta, weight: .medium))
                    .foregroundStyle(.orange)
            }

            Spacer()

            Button("关闭") { dismiss() }
                .font(.system(size: SheetFont.action, weight: .semibold))
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func sectionCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func sectionBlock<Trailing: View, Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() },
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage)
                    .font(.system(size: SheetFont.section, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            sectionCard {
                content()
            }
        }
    }

    // MARK: - 数据操作

    /// 直接读取当前 profile 的本地 JSON 文件加载配对数据（无需启动 Node 进程）
    /// - 待审批：`<profile>/credentials/<channel>-pairing.json` → `{ requests: [...] }`
    /// - 已配对：合并 allowFrom store 与 `channels.<channel>.allowFrom`
    private func loadAll() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        pendingRequests = ChannelPairingDataLoader.pendingRequests(
            for: channelType,
            localPaths: selectedLocalPaths
        )
        approvedPeers = ChannelPairingDataLoader.approvedPeers(
            for: channelType,
            localPaths: selectedLocalPaths
        )
    }

    /// 审批通过配对码
    private func approveCode(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isApproving = true
        errorMessage = nil
        successMessage = nil
        defer { isApproving = false }

        guard let selectedResolution else {
            errorMessage = "当前未选择 profile，无法执行配对审批"
            return
        }

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(
            args: ["pairing"] + ["approve", channelType.rawValue, trimmed],
            profile: selectedResolution
        )

        if ok {
            successMessage = "已审批通过配对码 \(trimmed)"
            manualCode = ""
            // 刷新列表
            await loadAll()
            // 几秒后清除成功提示
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if successMessage?.contains(trimmed) == true {
                    successMessage = nil
                }
            }
        } else {
            errorMessage = "审批失败：\(output)"
        }
    }

    /// 拒绝配对码
    private func rejectCode(_ code: String) async {
        errorMessage = nil
        successMessage = nil

        guard let selectedResolution else {
            errorMessage = "当前未选择 profile，无法执行配对拒绝"
            return
        }

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(
            args: ["pairing"] + ["reject", channelType.rawValue, code],
            profile: selectedResolution
        )

        if ok {
            pendingRequests.removeAll { $0.code == code }
            successMessage = "已拒绝配对码 \(code)"
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                if successMessage?.contains(code) == true {
                    successMessage = nil
                }
            }
        } else {
            errorMessage = "拒绝失败：\(output)"
        }
    }

    /// 移除已有配对
    private func removePeer(_ peer: PairingPeer) async {
        errorMessage = nil
        successMessage = nil

        do {
            let changed = try await ChannelPairingMutationSupport.removeApprovedPeer(
                peer,
                channel: channelType,
                gateway: gateway,
                profile: selectedResolution,
                localPaths: selectedLocalPaths
            )
            if changed {
                await loadAll()
                successMessage = "已移除 \(peer.displayName ?? peer.id) 的私信授权"
            } else {
                errorMessage = "\(peer.displayName ?? peer.id) 不在当前白名单中"
            }
        } catch {
            errorMessage = "移除失败：\(error.localizedDescription)"
        }
    }
}

// MARK: - 待审批请求模型

struct PairingRequest: Codable, Identifiable {
    let code: String
    var userId: String
    var displayName: String?
    var requestedAt: String?

    var id: String { code }

    enum CodingKeys: String, CodingKey {
        case code, userId, displayName, requestedAt
    }
}

enum PairingPeerSource: String, Codable, Hashable {
    case storeAllowFrom
    case configAllowFrom
}

// MARK: - 已配对 Peer 模型

struct PairingPeer: Codable, Identifiable, Equatable {
    let id: String
    var kind: String?
    var displayName: String?
    var pairedAt: String?
    var sources: [PairingPeerSource] = [.storeAllowFrom]

    var isGroup: Bool {
        kind == "group"
    }

    var isStoreBacked: Bool {
        sources.contains(.storeAllowFrom)
    }

    var isConfigBacked: Bool {
        sources.contains(.configAllowFrom)
    }

    var kindLabel: String {
        switch kind {
        case "group": return "群组"
        case "direct": return "私信"
        default: return "用户"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, displayName, pairedAt, sources
    }
}
