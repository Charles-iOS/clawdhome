// ClawdHome/Views/Capabilities/ChannelPairingSheet.swift
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
    let channelType: ChannelType

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

    // 手动添加配对
    @State private var showAddForm = false
    @State private var newPeerId = ""
    @State private var newPeerKind = "direct"
    @State private var isAdding = false

    // 移除确认
    @State private var peerToRemove: PairingPeer?

    // 自动刷新
    private let refreshTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

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
        HStack(spacing: 10) {
            Image(systemName: channelType.iconName)
                .font(.title2)
                .foregroundStyle(channelType.swiftUIColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(channelType.displayName) · 配对管理")
                    .font(.headline)
                Text("审批配对请求，管理已授权的用户和群组")
                    .font(.caption)
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
            .disabled(isLoading)
        }
        .padding(16)
    }

    // MARK: - 内容区

    @ViewBuilder
    private var contentArea: some View {
        if !hasLoadedOnce {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                // 消息提示
                messageSection

                // 手动输入配对码
                approveCodeSection

                // 待审批请求
                if !pendingRequests.isEmpty {
                    pendingSection
                }

                // 手动添加
                if showAddForm {
                    addPeerSection
                }

                // 已配对
                approvedSection
            }
            .listStyle(.inset)
        }
    }

    // MARK: - 消息提示

    @ViewBuilder
    private var messageSection: some View {
        if let successMessage {
            Section {
                Label(successMessage, systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
        }
        if let errorMessage {
            Section {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
        }
    }

    // MARK: - 手动输入配对码审批

    @ViewBuilder
    private var approveCodeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("用户给机器人发消息后会收到一个配对码，在此输入即可审批通过。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("输入配对码（如 LHSTVRP9）", text: $manualCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Button {
                        Task { await approveCode(manualCode) }
                    } label: {
                        Label("审批通过", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(manualCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isApproving)
                }
            }
        } header: {
            Label("配对审批", systemImage: "key.fill")
        }
    }

    // MARK: - 待审批请求列表

    @ViewBuilder
    private var pendingSection: some View {
        Section {
            ForEach(pendingRequests) { request in
                pendingRequestRow(request)
            }
        } header: {
            HStack {
                Label("待审批请求", systemImage: "bell.badge")
                Spacer()
                Text("\(pendingRequests.count)")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15))
                    .foregroundStyle(.orange)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func pendingRequestRow(_ request: PairingRequest) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    if let name = request.displayName {
                        Text(name)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    Text("ID: \(request.userId)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Text("配对码")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(request.code)
                        .font(.system(size: 12, design: .monospaced))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    if let ts = request.requestedAt {
                        Text(ts)
                            .font(.system(size: 10))
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
        .padding(.vertical, 4)
    }

    // MARK: - 已配对列表

    @ViewBuilder
    private var approvedSection: some View {
        Section {
            if approvedPeers.isEmpty {
                Text("暂无已配对的用户或群组")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(approvedPeers) { peer in
                    approvedPeerRow(peer)
                }
            }
        } header: {
            HStack {
                Label("已配对 (\(approvedPeers.count))", systemImage: "person.crop.circle.badge.checkmark")
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
                    .font(.subheadline)
                    .fontWeight(.medium)
                HStack(spacing: 6) {
                    Text(peer.kindLabel)
                        .font(.system(size: 10))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(peer.isGroup ? Color.purple.opacity(0.12) : Color.blue.opacity(0.12))
                        .foregroundStyle(peer.isGroup ? .purple : .blue)
                        .clipShape(Capsule())
                    Text("ID: \(peer.id)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let ts = peer.pairedAt {
                Text(ts)
                    .font(.system(size: 10))
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
        .padding(.vertical, 2)
    }

    // MARK: - 手动添加配对表单

    @ViewBuilder
    private var addPeerSection: some View {
        Section("手动添加配对") {
            Picker("类型", selection: $newPeerKind) {
                Text("私信用户").tag("direct")
                if channelType.supportsGroupChat {
                    Text("群组").tag("group")
                }
            }
            .pickerStyle(.segmented)

            TextField(
                newPeerKind == "group" ? "群组 ID" : "用户 ID（如 Telegram user ID、飞书 open_id）",
                text: $newPeerId
            )
            .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("取消") {
                    withAnimation { showAddForm = false }
                    newPeerId = ""
                }
                Button("确认添加") {
                    Task { await addPeer() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newPeerId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
            }
        }
    }

    // MARK: - 底栏

    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Button {
                withAnimation { showAddForm = true }
            } label: {
                Label("手动添加", systemImage: "plus")
            }
            .disabled(showAddForm)

            Spacer()

            if !pendingRequests.isEmpty {
                Text("\(pendingRequests.count) 个待审批")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Button("关闭") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: - 数据操作

    /// 直接读取本地 JSON 文件加载配对数据（无需启动 Node 进程）
    /// - 待审批：~/.openclaw/credentials/<channel>-pairing.json → { requests: [...] }
    /// - 已配对：~/.openclaw/credentials/<channel>-*-allowFrom.json → { allowFrom: ["id", ...] }
    private func loadAll() async {
        isLoading = true
        defer {
            isLoading = false
            hasLoadedOnce = true
        }

        let credDir = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("credentials")
        let fm = FileManager.default
        let channel = channelType.rawValue

        // 1. 读取待审批请求
        let pairingFile = credDir.appendingPathComponent("\(channel)-pairing.json")
        if let data = fm.contents(atPath: pairingFile.path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let requests = json["requests"] as? [[String: Any]],
           let reqData = try? JSONSerialization.data(withJSONObject: requests) {
            pendingRequests = (try? JSONDecoder().decode([PairingRequest].self, from: reqData)) ?? []
        } else {
            pendingRequests = []
        }

        // 2. 扫描 allowFrom 文件获取已配对用户
        var allPeers: [PairingPeer] = []
        let prefix = "\(channel)-"
        let suffix = "-allowFrom.json"
        if let entries = try? fm.contentsOfDirectory(atPath: credDir.path) {
            for entry in entries where entry.hasPrefix(prefix) && entry.hasSuffix(suffix) {
                let filePath = credDir.appendingPathComponent(entry)
                guard let data = fm.contents(atPath: filePath.path),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let allowFrom = json["allowFrom"] as? [String] else { continue }
                for peerId in allowFrom {
                    if !allPeers.contains(where: { $0.id == peerId }) {
                        allPeers.append(PairingPeer(id: peerId))
                    }
                }
            }
        }
        approvedPeers = allPeers
    }

    /// 审批通过配对码
    private func approveCode(_ code: String) async {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isApproving = true
        errorMessage = nil
        successMessage = nil
        defer { isApproving = false }

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(args: ["pairing"] + ["approve", channelType.rawValue, trimmed]
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

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(args: ["pairing"] + ["reject", channelType.rawValue, code]
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

    /// 手动添加配对
    private func addPeer() async {
        let id = newPeerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        isAdding = true
        errorMessage = nil
        successMessage = nil
        defer { isAdding = false }

        var args = ["add", channelType.rawValue, id]
        if newPeerKind == "group" {
            args += ["--kind", "group"]
        }

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(args: ["pairing"] + args
        )

        if ok {
            newPeerId = ""
            withAnimation { showAddForm = false }
            successMessage = "已添加配对"
            await loadAll()
        } else {
            errorMessage = "添加失败：\(output)"
        }
    }

    /// 移除已有配对
    private func removePeer(_ peer: PairingPeer) async {
        errorMessage = nil
        successMessage = nil

        let (ok, output) = await GatewayProcessManager.runOpenclawLocally(args: ["pairing"] + ["remove", channelType.rawValue, peer.id]
        )

        if ok {
            approvedPeers.removeAll { $0.id == peer.id }
            successMessage = "已移除 \(peer.displayName ?? peer.id) 的配对"
        } else {
            errorMessage = "移除失败：\(output)"
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

// MARK: - 已配对 Peer 模型

struct PairingPeer: Codable, Identifiable, Equatable {
    let id: String
    var kind: String?
    var displayName: String?
    var pairedAt: String?

    var isGroup: Bool {
        kind == "group"
    }

    var kindLabel: String {
        switch kind {
        case "group": return "群组"
        case "direct": return "私信"
        default: return "用户"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, displayName, pairedAt
    }
}
