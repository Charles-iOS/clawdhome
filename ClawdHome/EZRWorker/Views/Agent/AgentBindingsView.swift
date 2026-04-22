// ClawdHome/Views/Agent/AgentBindingsView.swift
// 管理单个智能体的渠道绑定（Agent 入口：智能体 → 选渠道）

import SwiftUI

struct AgentBindingsView: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayProcessManager.self) private var processManager
    @State private var showAddSheet = false

    private var agentBindings: [AgentBinding] {
        store.bindings(for: agentId)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 工具栏
            HStack {
                Text(L10n.k("agent.bindings.title", fallback: "渠道绑定"))
                    .font(.headline)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label(L10n.k("agent.bindings.add", fallback: "添加绑定"), systemImage: "plus")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            if agentBindings.isEmpty {
                ContentUnavailableView {
                    Label(L10n.k("agent.bindings.empty", fallback: "暂无绑定"), systemImage: "arrow.triangle.branch")
                } description: {
                    Text(L10n.k("agent.bindings.empty_desc", fallback: "添加渠道绑定后，入站消息将路由到此智能体"))
                }
            } else {
                List {
                    ForEach(agentBindings) { binding in
                        bindingRow(binding)
                    }
                    .onDelete { indexSet in
                        Task {
                            for index in indexSet {
                                do {
                                    try await store.removeBinding(agentBindings[index])
                                    await restartGatewayAfterBindingMutation()
                                } catch {
                                    appLog("[binding] 移除绑定失败: \(error)", level: .error)
                                }
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddBindingSheet(agentId: agentId)
        }
    }

    @ViewBuilder
    private func bindingRow(_ binding: AgentBinding) -> some View {
        HStack(spacing: 10) {
            // 使用 ChannelType 元数据获取正确图标和颜色
            Image(systemName: binding.channelIcon)
                .font(.title3)
                .foregroundStyle(binding.channelType?.swiftUIColor ?? Color.accentColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(binding.channelType?.displayName ?? binding.channel.capitalized)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(binding.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                Task {
                    do {
                        try await store.removeBinding(binding)
                        await restartGatewayAfterBindingMutation()
                    } catch {
                        appLog("[binding] 移除绑定失败: \(error)", level: .error)
                    }
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func restartGatewayAfterBindingMutation() async {
        processManager.restart()
    }
}

// MARK: - 添加绑定 Sheet（三步流程）

private struct AddBindingSheet: View {
    let agentId: String

    @Environment(AgentStore.self) private var store
    @Environment(GatewayService.self) private var gateway
    @Environment(GatewayProcessManager.self) private var processManager
    @Environment(\.dismiss) private var dismiss

    @State private var step: AddBindingStep = .selectChannel
    @State private var selectedChannel: ChannelType?
    @State private var channelConfigs: [ChannelType: Bool] = [:]
    @State private var isLoadingConfigs = true

    @State private var isAdding = false

    // 凭据配置 / QR 子 sheet
    @State private var showCredentialSheet = false
    @State private var showQRSheet = false

    var body: some View {
        NavigationStack {
            Group {
                switch step {
                case .selectChannel:
                    channelSelectionStep
                case .configureCredentials:
                    credentialConfigStep
                case .bindingMatch:
                    bindingMatchStep
                }
            }
            .navigationTitle(stepTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.k("common.cancel", fallback: "取消")) { dismiss() }
                }
            }
        }
        .frame(minWidth: 500, minHeight: 420)
        .task(id: gateway.isConnected) { await loadChannelConfigs() }
    }

    private var stepTitle: String {
        switch step {
        case .selectChannel: return L10n.k("agent.binding.step.select", fallback: "选择渠道")
        case .configureCredentials: return L10n.k("agent.binding.step.config", fallback: "配置渠道")
        case .bindingMatch: return L10n.k("agent.binding.step.match", fallback: "绑定条件")
        }
    }

    // MARK: - Step 1: 选择渠道

    @ViewBuilder
    private var channelSelectionStep: some View {
        if isLoadingConfigs {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.k("agent.binding.select_hint", fallback: "选择要绑定的消息渠道"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        ForEach(ChannelType.enabledCases) { channel in
                            channelCard(channel)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 16)
            }
        }
    }

    @ViewBuilder
    private func channelCard(_ channel: ChannelType) -> some View {
        let isConfigured = channelConfigs[channel] ?? false
        Button {
            selectedChannel = channel
            if isConfigured {
                // 渠道已配置，跳过凭据步骤，直接进入绑定匹配
                step = .bindingMatch
            } else if channel.supportsSetupMethodPicker {
                // 飞书：进入配置步骤（提供双路径选择）
                step = .configureCredentials
            } else if channel.usesInteractiveOnboarding {
                // 纯扫码渠道：弹交互式 onboarding 终端
                showQRSheet = true
            } else {
                // Telegram/Discord 等：弹凭据表单
                showCredentialSheet = true
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    channel.iconView(size: 20, weight: .medium)
                    Spacer()
                    // 配置状态徽章
                    Text(isConfigured
                         ? L10n.k("channel.status.connected", fallback: "已配置")
                         : L10n.k("channel.status.disconnected", fallback: "未配置"))
                        .font(.system(size: 10))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(isConfigured ? Color.green.opacity(0.12) : Color.secondary.opacity(0.1))
                        .foregroundStyle(isConfigured ? .green : .secondary)
                        .clipShape(Capsule())
                }
                Text(channel.displayName)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(channel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showCredentialSheet) {
            if let ch = selectedChannel {
                ChannelBotConfigSheet(channelType: ch) {
                    // 凭据保存成功后进入绑定匹配步骤
                    channelConfigs[ch] = true
                    step = .bindingMatch
                }
                .environment(gateway)
            }
        }
        .sheet(isPresented: $showQRSheet) {
            if let ch = selectedChannel {
                FeishuChannelOnboardingSheet(
                    flow: ch.onboardingFlow,
                    displayName: "",
                    username: store.username
                )
                .frame(minWidth: 900, minHeight: 560)
                .onDisappear {
                    // QR 窗口关闭后，刷新配置状态并进入绑定步骤
                    Task {
                        await refreshAfterChannelOnboardingClosed()
                        if channelConfigs[ch] == true {
                            step = .bindingMatch
                        }
                    }
                }
            }
        }
    }

    // MARK: - Step 2: 配置凭据（飞书双路径）

    @ViewBuilder
    private var credentialConfigStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let channel = selectedChannel, channel == .feishu {
                Text(L10n.k("agent.binding.feishu.choose", fallback: "飞书支持两种接入方式，请选择："))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                VStack(spacing: 12) {
                    // 方式一：QR 扫码
                    Button {
                        showQRSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3)
                                .foregroundStyle(.blue)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.k("agent.binding.feishu.qr", fallback: "扫码配对"))
                                    .font(.subheadline).fontWeight(.medium)
                                Text(L10n.k("agent.binding.feishu.qr_desc", fallback: "通过飞书官方工具生成 QR 码，扫码完成配对"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)

                    // 方式二：手动填凭据
                    Button {
                        showCredentialSheet = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "key.fill")
                                .font(.title3)
                                .foregroundStyle(.orange)
                                .frame(width: 32)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(L10n.k("agent.binding.feishu.manual", fallback: "手动填写凭据"))
                                    .font(.subheadline).fontWeight(.medium)
                                Text(L10n.k("agent.binding.feishu.manual_desc", fallback: "输入 App ID 和 App Secret（适用于自建应用）"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)

                Spacer()

                HStack {
                    Button(L10n.k("common.back", fallback: "上一步")) {
                        step = .selectChannel
                        selectedChannel = nil
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
        }
        .padding(.top, 16)
        .sheet(isPresented: $showCredentialSheet) {
            if let ch = selectedChannel {
                ChannelBotConfigSheet(channelType: ch) {
                    channelConfigs[ch] = true
                    step = .bindingMatch
                }
                .environment(gateway)
            }
        }
        .sheet(isPresented: $showQRSheet) {
            FeishuChannelOnboardingSheet(
                flow: .feishu,
                displayName: "",
                username: store.username
            )
            .frame(minWidth: 900, minHeight: 560)
            .onDisappear {
                Task {
                    await refreshAfterChannelOnboardingClosed()
                    if let ch = selectedChannel, channelConfigs[ch] == true {
                        step = .bindingMatch
                    }
                }
            }
        }
    }

    // MARK: - Step 3: 绑定匹配条件

    @ViewBuilder
    private var bindingMatchStep: some View {
        Form {
            if let channel = selectedChannel {
                Section {
                    HStack(spacing: 10) {
                        channel.iconView(size: 18, weight: .medium)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(channel.displayName)
                                .font(.subheadline).fontWeight(.medium)
                            Text("此绑定将处理该渠道的默认消息")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(L10n.k("common.back", fallback: "上一步")) {
                    step = .selectChannel
                }
                .buttonStyle(.bordered)
                Spacer()
                Button(L10n.k("agent.binding.add_confirm", fallback: "添加绑定")) {
                    addBinding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAdding)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    // MARK: - 数据操作

    private func loadChannelConfigs() async {
        let channelsDict = await loadChannelConfigDictionary()
        let hasFeishuQRCodeCredentials = hasFeishuQRCodeCredentials()
        var result: [ChannelType: Bool] = [:]
        for channel in ChannelType.enabledCases {
            if channel == .feishu, hasFeishuQRCodeCredentials {
                result[channel] = true
                continue
            }
            if let chConfig = channelsDict[channel.rawValue] as? [String: Any] {
                // 纯扫码渠道无 configFields，有配置即视为已配置
                if channel.configFields.isEmpty {
                    result[channel] = !chConfig.isEmpty
                } else {
                    result[channel] = channel.configFields.contains { field in
                        guard let value = chConfig[field.id] as? String else { return false }
                        return !value.isEmpty
                    }
                }
            } else {
                result[channel] = false
            }
        }
        channelConfigs = result
        isLoadingConfigs = false
    }

    private func refreshAfterChannelOnboardingClosed() async {
        await loadChannelConfigs()
        try? await Task.sleep(nanoseconds: 800_000_000)
        await loadChannelConfigs()
    }

    private func hasFeishuQRCodeCredentials() -> Bool {
        let credFile = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("credentials")
            .appendingPathComponent("lark.secrets.json")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: credFile.path),
              let fileSize = attrs[.size] as? NSNumber else {
            return false
        }
        return fileSize.intValue > 0
    }

    private func loadLocalChannelConfigDictionary() -> [String: Any] {
        let configURL = GatewayProcessManager.openClawConfigDir
            .appendingPathComponent("openclaw.json")
        guard let data = FileManager.default.contents(atPath: configURL.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json["channels"] as? [String: Any] ?? [:]
    }

    private func loadChannelConfigDictionary() async -> [String: Any] {
        let localChannels = loadLocalChannelConfigDictionary()
        guard gateway.isConnected else { return localChannels }
        do {
            let (config, _) = try await gateway.configGetFull()
            return (config["channels"] as? [String: Any]) ?? localChannels
        } catch {
            appLog("[binding] 读取 gateway 配置失败，回退本地配置: \(error)", level: .warn)
            return localChannels
        }
    }

    private func addBinding() {
        guard let channel = selectedChannel else { return }
        isAdding = true
        let binding = AgentBinding(
            agentId: agentId,
            channel: channel.rawValue,
            accountId: channel == .wecom ? "default" : nil
        )
        Task {
            do {
                try await store.addBinding(binding)
                await restartGatewayAfterBindingMutation()
                dismiss()
            } catch {
                appLog("添加绑定失败: \(error)", level: .error)
                isAdding = false
            }
        }
    }

    private func restartGatewayAfterBindingMutation() async {
        processManager.restart()
    }
}

// MARK: - 步骤枚举

private enum AddBindingStep {
    case selectChannel
    case configureCredentials
    case bindingMatch
}
