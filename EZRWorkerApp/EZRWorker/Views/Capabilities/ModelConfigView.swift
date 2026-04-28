import SwiftUI

private struct ModelSectionCard<Content: View, Accessory: View>: View {
    let title: String
    let subtitle: String?
    let content: Content
    let accessory: Accessory

    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 24, weight: .semibold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 12)
                accessory
            }

            content
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.03), radius: 14, y: 6)
        )
    }
}

private extension ModelSectionCard where Accessory == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(title: title, subtitle: subtitle, accessory: { EmptyView() }, content: content)
    }
}

struct ModelConfigView: View {
    @Environment(GatewayService.self) private var gateway
    @Environment(ProviderKeychainStore.self) private var keychainStore
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(AgentStore.self) private var agentStore
    @Environment(GatewayProfileStore.self) private var profileStore

    @State private var gatewayModelGroups: [ModelGroup]?
    @State private var gatewayProviderIDs: Set<String> = []
    @State private var isLoading = false
    @State private var isSavingRouting = false
    @State private var syncingProviderId: String?
    @State private var defaultPrimaryModel = ""
    @State private var savedPrimaryModel = ""
    @State private var fallbackModels: [String] = []
    @State private var savedFallbackModels: [String] = []
    @State private var pendingFallbackModel = ""
    @State private var loadError: String?
    @State private var saveError: String?
    @State private var showAddProviderSheet = false
    @State private var editingProvider: ProviderTemplate?
    @State private var pendingDeletionProvider: ProviderTemplate?

    private let summaryColumns = [
        GridItem(.flexible(minimum: 220), spacing: 16),
        GridItem(.flexible(minimum: 220), spacing: 16),
    ]

    private var availableModels: [ModelEntry] {
        var seen = Set<String>()
        var output: [ModelEntry] = []

        func append(id: String, label: String? = nil) {
            guard !id.isEmpty, seen.insert(id).inserted else { return }
            output.append(
                ModelEntry(
                    id: id,
                    label: label ?? modelDisplayLabel(for: id)
                )
            )
        }

        for entry in modelStore.allTemplateModels {
            append(id: entry.id, label: entry.label)
        }

        for entry in (gatewayModelGroups ?? []).flatMap(\.models) {
            append(id: entry.id, label: entry.label.isEmpty ? nil : entry.label)
        }

        append(id: defaultPrimaryModel)
        for modelID in fallbackModels {
            append(id: modelID)
        }
        for modelID in agentStore.agents.compactMap(\.preferredModel) {
            append(id: modelID)
        }

        return output
    }

    private var routingDirty: Bool {
        defaultPrimaryModel != savedPrimaryModel || fallbackModels != savedFallbackModels
    }

    private var fallbackCandidates: [ModelEntry] {
        availableModels.filter { entry in
            entry.id != defaultPrimaryModel && !fallbackModels.contains(entry.id)
        }
    }

    private var currentDefaultLabel: String {
        guard !defaultPrimaryModel.isEmpty else { return "未设置" }
        return availableModels.first(where: { $0.id == defaultPrimaryModel })?.label
            ?? modelDisplayLabel(for: defaultPrimaryModel)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                heroSection
                summarySection
                providersSection
                routingSection
                agentOverridesSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await loadData() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
        }
        .sheet(isPresented: $showAddProviderSheet, onDismiss: {
            Task { await loadData() }
        }) {
            AddProviderModelSheet(onSave: gateway.isConnected ? syncClosure : nil)
        }
        .sheet(item: $editingProvider, onDismiss: {
            Task { await loadData() }
        }) { provider in
            AddProviderModelSheet(editing: provider, onSave: gateway.isConnected ? syncClosure : nil)
        }
        .confirmationDialog(
            "删除这个 Provider？",
            isPresented: Binding(
                get: { pendingDeletionProvider != nil },
                set: { if !$0 { pendingDeletionProvider = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("取消", role: .cancel) {
                pendingDeletionProvider = nil
            }

            if let provider = pendingDeletionProvider {
                Button("删除 \(provider.displayName)", role: .destructive) {
                    let target = provider
                    pendingDeletionProvider = nil
                    Task { await deleteProvider(target) }
                }
            }
        } message: {
            if let provider = pendingDeletionProvider {
                Text(deletionMessage(for: provider))
            }
        }
        .task {
            await loadData()
        }
    }

    @ViewBuilder
    private var heroSection: some View {
        HStack(alignment: .top, spacing: 20) {
            PageHeroHeader(
                title: "模型",
                subtitle: "管理当前 Profile 的 Provider、默认模型和智能体模型覆盖。",
                subtitleLineLimit: 3
            )

            Spacer(minLength: 16)

            VStack(alignment: .trailing, spacing: 10) {
                Button {
                    showAddProviderSheet = true
                } label: {
                    Label("添加 Provider", systemImage: "plus")
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

                Text("添加 MiniMax、OpenAI 或兼容网关，然后再设置默认模型。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    @ViewBuilder
    private var summarySection: some View {
        ModelSectionCard(
            title: "概览",
            subtitle: "当前 Profile 的模型配置状态。"
        ) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            LazyVGrid(columns: summaryColumns, spacing: 16) {
                summaryItem(title: "当前 Profile", value: profileStore.selectedProfile?.displayName ?? "未选择")
                summaryItem(title: "Gateway", value: gateway.isConnected ? "已连接" : "未连接")
                summaryItem(title: "全局默认模型", value: currentDefaultLabel)
                summaryItem(title: "已配置 Provider", value: "\(modelStore.providers.count)")
            }

            if let loadError, !loadError.isEmpty {
                statusMessage(loadError, color: .orange)
            }
        }
    }

    @ViewBuilder
    private var providersSection: some View {
        ModelSectionCard(
            title: "Provider 账户",
            subtitle: "Provider 会先保存在本机；写入当前 Profile 后，当前 Gateway 才会实际使用。"
        ) {
            if modelStore.providers.isEmpty {
                ContentUnavailableView {
                    Label("还没有配置模型 Provider", systemImage: "cpu")
                } description: {
                    Text("先添加 MiniMax、OpenAI / GPT 等 Provider，随后再设置默认模型。")
                } actions: {
                    Button("添加 Provider") {
                        showAddProviderSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                VStack(spacing: 16) {
                    ForEach(Array(modelStore.providers.enumerated()), id: \.element.id) { index, provider in
                        providerRow(provider)
                        if index < modelStore.providers.count - 1 {
                            Divider()
                        }
                    }
                }
            }

            if let saveError, !saveError.isEmpty {
                statusMessage(saveError, color: .red)
            }
        }
    }

    @ViewBuilder
    private func providerRow(_ provider: ProviderTemplate) -> some View {
        let hasCredential = keychainStore.hasKey(forProvider: provider.providerGroupId)
        let inGateway = gatewayProviderIDs.contains(provider.providerGroupId)
        let isSyncing = syncingProviderId == provider.providerGroupId
        let inUse = providerIsInUse(provider)
        let labels = provider.modelEntries().map(\.label).prefix(3).joined(separator: "、")

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(.system(size: 18, weight: .semibold))
                    Text(provider.providerGroupId)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 6) {
                    statusBadge(
                        title: hasCredential ? "已配置凭据" : "未配置凭据",
                        systemImage: hasCredential ? "key.fill" : "key",
                        foreground: hasCredential ? .green : .secondary,
                        background: hasCredential ? Color.green.opacity(0.12) : Color.secondary.opacity(0.10)
                    )

                    statusBadge(
                        title: inGateway ? "已写入当前 Profile" : "仅保存在本机",
                        systemImage: inGateway ? "checkmark.circle.fill" : "externaldrive",
                        foreground: inGateway ? .green : .orange,
                        background: inGateway ? Color.green.opacity(0.12) : Color.orange.opacity(0.12)
                    )
                }
            }

            if !labels.isEmpty {
                Text("模型：\(labels)\(provider.modelIds.count > 3 ? " 等 \(provider.modelIds.count) 个" : "")")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("编辑") {
                    editingProvider = provider
                }
                .buttonStyle(.bordered)

                Button {
                    Task { await syncProvider(provider) }
                } label: {
                    if isSyncing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(inGateway ? "重新同步到当前 Profile" : "写入当前 Profile")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!gateway.isConnected || isSyncing || !hasCredential)

                Button("删除", role: .destructive) {
                    if inUse {
                        saveError = "Provider \(provider.displayName) 当前正被默认模型或智能体覆盖使用，请先切换后再删除。"
                    } else {
                        pendingDeletionProvider = provider
                    }
                }
                .buttonStyle(.bordered)
            }

            if inUse {
                statusMessage("当前 Provider 正在被默认模型或智能体模型覆盖使用，删除前请先切换。", color: .orange)
            } else if !inGateway {
                statusMessage("当前只保存在本机，写入当前 Profile 后 Gateway 才能实际使用。", color: .secondary)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var routingSection: some View {
        ModelSectionCard(
            title: "默认模型与降级链",
            subtitle: "在这里设置主模型和备用模型。"
        ) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("主模型")
                        .font(.system(size: 15, weight: .medium))
                    Picker("主模型", selection: $defaultPrimaryModel) {
                        Text("未设置").tag("")
                        ForEach(availableModels) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    .labelsHidden()
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("添加备用模型")
                        .font(.system(size: 15, weight: .medium))

                    HStack(spacing: 10) {
                        Picker("添加备用模型", selection: $pendingFallbackModel) {
                            Text("选择模型").tag("")
                            ForEach(fallbackCandidates) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        .labelsHidden()

                        Button("添加") {
                            guard !pendingFallbackModel.isEmpty else { return }
                            fallbackModels.append(pendingFallbackModel)
                            pendingFallbackModel = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(pendingFallbackModel.isEmpty)
                    }
                }

                if fallbackModels.isEmpty {
                    Text("还没有设置备用模型。")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 12) {
                        ForEach(Array(fallbackModels.enumerated()), id: \.element) { index, modelID in
                            fallbackRow(index: index, modelID: modelID)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(isSavingRouting ? "保存中…" : "保存默认模型") {
                        Task { await saveRouting() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!gateway.isConnected || isSavingRouting || !routingDirty)

                    if !gateway.isConnected {
                        statusMessage("Gateway 未连接时无法写入当前 Profile。", color: .orange)
                    } else if routingDirty {
                        statusMessage("有未保存的模型路由变更。", color: .secondary)
                    }
                }

                if let saveError, !saveError.isEmpty, isSavingRouting == false {
                    statusMessage(saveError, color: .red)
                }
            }
        }
    }

    @ViewBuilder
    private func fallbackRow(index: Int, modelID: String) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(availableModels.first(where: { $0.id == modelID })?.label ?? modelDisplayLabel(for: modelID))
                    .font(.system(size: 15, weight: .medium))
                Text(modelID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                moveFallbackUp(at: index)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .disabled(index == 0)

            Button {
                moveFallbackDown(at: index)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .disabled(index == fallbackModels.count - 1)

            Button(role: .destructive) {
                fallbackModels.remove(at: index)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private var agentOverridesSection: some View {
        ModelSectionCard(
            title: "智能体模型覆盖",
            subtitle: "为单个智能体指定独立模型，未设置时继承全局默认。"
        ) {
            if agentStore.agents.isEmpty {
                Text("当前还没有可配置的智能体。")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 12) {
                    ForEach(agentStore.agents) { agent in
                        agentOverrideRow(agent)
                    }
                }
            }

            if !gateway.isConnected {
                statusMessage("Gateway 未连接时，智能体模型覆盖不可修改。", color: .orange)
            }
        }
    }

    @ViewBuilder
    private func agentOverrideRow(_ agent: Agent) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(agent.emoji) \(agent.name)")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                if agent.preferredModel == nil || agent.preferredModel?.isEmpty == true {
                    Text("继承全局")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Picker(
                "模型",
                selection: Binding(
                    get: { agent.preferredModel ?? "" },
                    set: { newValue in
                        Task { await setAgentModel(agentID: agent.id, modelID: newValue) }
                    }
                )
            ) {
                Text("使用全局默认").tag("")
                ForEach(availableModels) { model in
                    Text(model.label).tag(model.id)
                }
            }
            .labelsHidden()
            .disabled(!gateway.isConnected)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func summaryItem(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    @ViewBuilder
    private func statusBadge(
        title: String,
        systemImage: String,
        foreground: Color,
        background: Color
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(background)
            .clipShape(Capsule())
    }

    @ViewBuilder
    private func statusMessage(_ message: String, color: Color) -> some View {
        Text(message)
            .font(.caption)
            .foregroundStyle(color)
    }

    private func loadData() async {
        isLoading = true
        defer { isLoading = false }

        loadError = nil
        saveError = nil
        modelStore.load()

        guard gateway.isConnected else {
            gatewayModelGroups = nil
            gatewayProviderIDs = []
            if pendingFallbackModel.isEmpty {
                pendingFallbackModel = fallbackCandidates.first?.id ?? ""
            }
            return
        }

        do {
            let (config, _) = try await gateway.configGetFull()
            let defaults = ((config["agents"] as? [String: Any])?["defaults"] as? [String: Any]) ?? [:]
            let modelConfig = defaults["model"] as? [String: Any]
            let primary = (modelConfig?["primary"] as? String) ?? ""
            let fallbackArray = modelConfig?["fallbacks"] as? [String]
            let fallbackSingle = modelConfig?["fallbacks"] as? String

            defaultPrimaryModel = primary
            savedPrimaryModel = primary

            if let fallbackArray {
                fallbackModels = fallbackArray
            } else if let fallbackSingle, !fallbackSingle.isEmpty {
                fallbackModels = [fallbackSingle]
            } else {
                fallbackModels = []
            }
            savedFallbackModels = fallbackModels

            let providers = ((config["models"] as? [String: Any])?["providers"] as? [String: Any]) ?? [:]
            gatewayModelGroups = Self.modelGroups(from: providers)
            gatewayProviderIDs = Set(providers.keys)
            pendingFallbackModel = fallbackCandidates.first?.id ?? ""
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func moveFallbackUp(at index: Int) {
        guard index > 0 else { return }
        fallbackModels.swapAt(index, index - 1)
    }

    private func moveFallbackDown(at index: Int) {
        guard index < fallbackModels.count - 1 else { return }
        fallbackModels.swapAt(index, index + 1)
    }

    private func saveRouting() async {
        guard gateway.isConnected else { return }

        isSavingRouting = true
        saveError = nil
        defer { isSavingRouting = false }

        do {
            let (config, baseHash) = try await gateway.configGetFull()
            var agents = config["agents"] as? [String: Any] ?? [:]
            var defaults = agents["defaults"] as? [String: Any] ?? [:]

            if defaultPrimaryModel.isEmpty {
                defaults.removeValue(forKey: "model")
            } else {
                var model: [String: Any] = ["primary": defaultPrimaryModel]
                if !fallbackModels.isEmpty {
                    model["fallbacks"] = fallbackModels
                }
                defaults["model"] = model
            }

            agents["defaults"] = defaults
            try await gateway.configPatch(
                patch: ["agents": agents],
                baseHash: baseHash,
                note: "更新默认模型与降级链"
            )

            savedPrimaryModel = defaultPrimaryModel
            savedFallbackModels = fallbackModels
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func syncProvider(_ provider: ProviderTemplate) async {
        guard gateway.isConnected else { return }
        syncingProviderId = provider.providerGroupId
        saveError = nil
        defer { syncingProviderId = nil }

        do {
            try await OpenClawProviderKeySync.syncProvider(
                gateway: gateway,
                provider: provider,
                secret: keychainStore.read(forProvider: provider.providerGroupId)
            )
            await loadData()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func deleteProvider(_ provider: ProviderTemplate) async {
        if providerIsInUse(provider) {
            saveError = "Provider \(provider.displayName) 当前正在使用中，无法直接删除。"
            return
        }

        saveError = nil
        do {
            if gateway.isConnected {
                try await OpenClawProviderKeySync.removeProvider(
                    gateway: gateway,
                    providerId: provider.providerGroupId
                )
            }
            keychainStore.delete(forProvider: provider.providerGroupId)
            modelStore.removeProvider(id: provider.id)
            await loadData()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func setAgentModel(agentID: String, modelID: String) async {
        guard gateway.isConnected else { return }
        do {
            try await agentStore.setAgentModel(
                agentId: agentID,
                modelId: modelID.isEmpty ? nil : modelID
            )
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func providerIsInUse(_ provider: ProviderTemplate) -> Bool {
        let prefix = "\(provider.providerGroupId)/"
        if defaultPrimaryModel.hasPrefix(prefix) {
            return true
        }
        if fallbackModels.contains(where: { $0.hasPrefix(prefix) }) {
            return true
        }
        return agentStore.agents.contains { agent in
            guard let model = agent.preferredModel, !model.isEmpty else { return false }
            return model.hasPrefix(prefix)
        }
    }

    private func deletionMessage(for provider: ProviderTemplate) -> String {
        "会从本机移除 \(provider.displayName) 的模型配置和凭据；如果当前 Gateway 已连接，也会同步从当前 Profile 删除对应 provider。"
    }

    private static func modelGroups(from providers: [String: Any]) -> [ModelGroup] {
        providers.keys.sorted().compactMap { providerID in
            guard let provider = providers[providerID] as? [String: Any] else { return nil }
            let rows = provider["models"] as? [[String: Any]] ?? []
            let models = rows.compactMap { row -> ModelEntry? in
                guard let rawID = row["id"] as? String else { return nil }
                let id = normalizedModelID(rawID, providerId: providerID)
                guard !id.isEmpty else { return nil }
                let label = (row["name"] as? String)
                    ?? (row["label"] as? String)
                    ?? modelDisplayLabel(for: id)
                return ModelEntry(id: id, label: label)
            }
            guard !models.isEmpty else { return nil }
            return ModelGroup(
                id: providerID,
                provider: OpenClawProviderKeySync.staticConfig(for: providerID)?.displayName ?? providerID,
                models: models
            )
        }
    }

    private var syncClosure: (ProviderTemplate) async throws -> Void {
        { provider in
            try await OpenClawProviderKeySync.syncProvider(
                gateway: gateway,
                provider: provider,
                secret: keychainStore.read(forProvider: provider.providerGroupId)
            )
        }
    }
}
