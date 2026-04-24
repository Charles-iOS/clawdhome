// EZRWorkerApp/Views/ModelManager/AddProviderModelSheet.swift
// 新主线 Provider 编辑弹窗：选择 Provider、录入凭据、选模型并同步到当前 profile

import SwiftUI

private enum CompatibleProviderAPI: String, CaseIterable, Identifiable {
    case openAI = "openai-completions"
    case anthropic = "anthropic-messages"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .anthropic:
            return "Anthropic"
        }
    }

    static func from(apiType: String) -> CompatibleProviderAPI {
        Self.allCases.first(where: { $0.rawValue == apiType }) ?? .openAI
    }
}

struct AddProviderModelSheet: View {
    var editing: ProviderTemplate? = nil
    var onSave: ((ProviderTemplate) async throws -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(GlobalModelStore.self) private var modelStore
    @Environment(ProviderKeychainStore.self) private var keychainStore

    @State private var displayName: String = ""
    @State private var selectedProviderTypeId: String = ""
    @State private var providerIdInput: String = ""
    @State private var baseURLInput: String = ""
    @State private var compatibilityAPI: CompatibleProviderAPI = .openAI
    @State private var selectedModelIds: Set<String> = []
    @State private var modelLabels: [String: String] = [:]
    @State private var fetchedModels: [ModelEntry] = []
    @State private var modelSearch: String = ""
    @State private var manualModelInput: String = ""
    @State private var credentialInput: String = ""
    @State private var existingConfigured = false
    @State private var isFetchingModels = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var fetchMessage: String?

    private var isEditMode: Bool { editing != nil }

    private var providerChoices: [ProviderKeyConfig] { supportedProviderKeys }

    private var currentProviderConfig: ProviderKeyConfig? {
        supportedProviderKeys.first { $0.id == selectedProviderTypeId }
    }

    private var effectiveProviderGroupId: String {
        guard let cfg = currentProviderConfig else { return "" }
        if cfg.allowsCustomProviderID {
            return providerIdInput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return selectedProviderTypeId
    }

    private var trimmedBaseURL: String {
        baseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var credentialLabel: String {
        currentProviderConfig?.inputLabel ?? "API Key"
    }

    private var credentialPlaceholder: String {
        currentProviderConfig?.placeholder ?? "sk-..."
    }

    private var isUrlInput: Bool {
        currentProviderConfig?.isUrlConfig == true
    }

    private var showsCustomProviderIDInput: Bool {
        currentProviderConfig?.allowsCustomProviderID == true
    }

    private var showsBaseURLInput: Bool {
        currentProviderConfig?.requiresBaseURLInput == true
    }

    private var showsCompatibilityPicker: Bool {
        showsBaseURLInput
    }

    private var canFetchModels: Bool {
        guard let cfg = currentProviderConfig else { return false }
        guard cfg.supportsRemoteModelDiscovery else { return false }
        if cfg.requiresBaseURLInput {
            return !trimmedBaseURL.isEmpty && !effectiveProviderGroupId.isEmpty
        }
        return !isFetchingModels
    }

    private var availableModels: [ModelEntry] {
        guard !effectiveProviderGroupId.isEmpty else { return [] }

        var result: [ModelEntry] = []
        var seen = Set<String>()

        func append(_ entries: [ModelEntry]) {
            for entry in entries {
                let normalizedID = normalizedModelID(entry.id, providerId: effectiveProviderGroupId)
                guard !normalizedID.isEmpty else { continue }
                guard seen.insert(normalizedID).inserted else { continue }
                result.append(
                    ModelEntry(
                        id: normalizedID,
                        label: modelLabels[normalizedID] ?? entry.label
                    )
                )
            }
        }

        if let cfg = currentProviderConfig {
            append(cfg.suggestedModels)
        }
        append(fetchedModels)
        if let editing {
            append(editing.modelEntries())
        }

        for modelID in selectedModelIds {
            guard seen.insert(modelID).inserted else { continue }
            result.append(
                ModelEntry(
                    id: modelID,
                    label: modelLabels[modelID] ?? modelDisplayLabel(for: modelID)
                )
            )
        }

        return result
    }

    private var filteredModels: [ModelEntry] {
        guard !modelSearch.isEmpty else { return availableModels }
        return availableModels.filter {
            $0.label.localizedCaseInsensitiveContains(modelSearch)
            || $0.id.localizedCaseInsensitiveContains(modelSearch)
        }
    }

    private var canSave: Bool {
        !selectedProviderTypeId.isEmpty
            && !effectiveProviderGroupId.isEmpty
            && (!showsBaseURLInput || !trimmedBaseURL.isEmpty)
            && !selectedModelIds.isEmpty
            && !isSaving
    }

    private var shouldSyncOnSave: Bool {
        onSave != nil
    }

    private var headerSubtitle: String {
        shouldSyncOnSave
            ? "保存会先写入本机 Keychain，再同步到当前 Profile。"
            : "保存只写入本机，等 Gateway 连接后再同步到当前 Profile。"
    }

    private var modelSelectionSubtitle: String {
        shouldSyncOnSave
            ? "选择保存后要写入当前 Profile 的模型。"
            : "选择要先保存在本机的模型，稍后再同步到当前 Profile。"
    }

    private var credentialHelpText: String {
        if existingConfigured {
            return "如果不填写新值，将继续使用已保存的本机凭据。"
        }
        return shouldSyncOnSave
            ? "凭据会先保存到本机 Keychain，然后同步到当前 Profile。"
            : "凭据只会先保存到本机 Keychain。"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            if let errorMessage, !errorMessage.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(errorMessage)
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.08))
            }

            HSplitView {
                providerList
                modelSelectionPanel
            }

            Divider()
            credentialSection
        }
        .frame(width: 760, height: 680)
        .onAppear {
            configureInitialState()
        }
        .onChange(of: selectedProviderTypeId) { oldID, newID in
            guard oldID != newID else { return }
            handleProviderChanged()
        }
        .onChange(of: providerIdInput) { oldValue, newValue in
            guard oldValue != newValue else { return }
            handleProviderIdentifierChanged(oldValue: oldValue, newValue: newValue)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(isEditMode ? "编辑 Provider" : "添加 Provider")
                    .font(.headline)
                Text(headerSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("取消") {
                dismiss()
            }
            .keyboardShortcut(.escape)

            Button(isSaving ? "保存中…" : "保存") {
                Task { await commit() }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return)
            .disabled(!canSave)
        }
        .padding()
    }

    private var providerList: some View {
        VStack(spacing: 0) {
            if isEditMode {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                    Text("编辑时已锁定 Provider 类型；如需更换，请删除后重新添加。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.06))
            }

            List(providerChoices) { provider in
                let isSelected = provider.id == selectedProviderTypeId
                let isLockedOut = isEditMode && !isSelected
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.displayName)
                        Text(provider.id)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let count = configuredModelCount(for: provider), count > 0 {
                        Text("\(count)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12))
                            .clipShape(Capsule())
                    }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isEditMode else { return }
                    selectedProviderTypeId = provider.id
                }
                .foregroundStyle(isLockedOut ? Color.secondary.opacity(0.45) : .primary)
                .listRowBackground(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
            }
            .listStyle(.sidebar)
        }
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 260)
    }

    private var modelSelectionPanel: some View {
        VStack(spacing: 0) {
            if let cfg = currentProviderConfig {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(displayName.isEmpty ? cfg.displayName : displayName)
                                .font(.headline)
                            Text(modelSelectionSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if cfg.supportsRemoteModelDiscovery {
                            Button {
                                Task { await fetchRemoteModels() }
                            } label: {
                                if isFetchingModels {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Label("拉取模型列表", systemImage: "arrow.down.circle")
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(!canFetchModels || isFetchingModels)
                        }
                    }

                    if let fetchMessage, !fetchMessage.isEmpty {
                        Text(fetchMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if cfg.supportsRemoteModelDiscovery && cfg.requiresBaseURLInput && trimmedBaseURL.isEmpty {
                        Text("先填写 Base URL，才能拉取模型列表。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("搜索模型 ID 或名称", text: $modelSearch)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))

                    HStack(spacing: 8) {
                        TextField("手动添加模型 ID，如 gpt-4.1 或 MiniMax-M2.7", text: $manualModelInput)
                            .textFieldStyle(.roundedBorder)

                        Button("添加") {
                            addManualModel()
                        }
                        .buttonStyle(.bordered)
                        .disabled(manualModelInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveProviderGroupId.isEmpty)

                        let allSelected = !availableModels.isEmpty && availableModels.allSatisfy { selectedModelIds.contains($0.id) }
                        Button(allSelected ? "全不选" : "全选") {
                            if allSelected {
                                availableModels.forEach { selectedModelIds.remove($0.id) }
                            } else {
                                availableModels.forEach { selectedModelIds.insert($0.id) }
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                    }
                }
                .padding(16)

                Divider()

                List {
                    if filteredModels.isEmpty {
                        Text("当前没有可选模型。可以手动输入模型 ID，或在支持的 Provider 上点击“拉取模型列表”。")
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(filteredModels) { model in
                            let isSelected = selectedModelIds.contains(model.id)
                            HStack(spacing: 10) {
                                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.label)
                                    Text(model.id)
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                toggleModel(model.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            } else {
                ContentUnavailableView(
                    "选择左侧 Provider",
                    systemImage: "cpu",
                    description: Text("选择一个模型提供商，然后配置凭据并勾选需要保存的模型。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 420, maxWidth: .infinity)
    }

    private var credentialSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("显示名称")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)
                TextField("如「OpenAI / GPT」", text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }

            if showsCustomProviderIDInput {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Provider ID")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .trailing)
                    TextField("如 acme-openai", text: $providerIdInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isEditMode)
                }
            }

            if showsBaseURLInput {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Base URL")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .trailing)
                    TextField("https://api.example.com/v1", text: $baseURLInput)
                        .textFieldStyle(.roundedBorder)
                }
            }

            if showsCompatibilityPicker {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("兼容协议")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(width: 86, alignment: .trailing)
                    Picker("兼容协议", selection: $compatibilityAPI) {
                        ForEach(CompatibleProviderAPI.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(credentialLabel)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(width: 86, alignment: .trailing)

                if isUrlInput {
                    TextField(credentialPlaceholder, text: $credentialInput)
                        .textFieldStyle(.roundedBorder)
                } else {
                    SecureField(existingConfigured ? "输入新值可覆盖，留空保持现状" : credentialPlaceholder, text: $credentialInput)
                        .textFieldStyle(.roundedBorder)
                }

                if existingConfigured && credentialInput.isEmpty {
                    Label("已配置", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }

            if showsCustomProviderIDInput && isEditMode {
                Text("自定义 Provider 的 ID 在编辑态锁定；如需更换，请删除后重新添加。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(credentialHelpText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private func configureInitialState() {
        if let editing {
            displayName = editing.displayName
            selectedProviderTypeId = editing.editorProviderId
            providerIdInput = editing.providerGroupId
            baseURLInput = editing.baseURL
            compatibilityAPI = CompatibleProviderAPI.from(apiType: editing.apiType)
            selectedModelIds = Set(editing.normalizedModelIDs)
            modelLabels = editing.modelLabels
            fetchedModels = editing.modelEntries()
            existingConfigured = keychainStore.hasKey(forProvider: editing.providerGroupId)
        } else {
            selectedProviderTypeId = supportedProviderKeys.first?.id ?? ""
            displayName = currentProviderConfig?.displayName ?? ""
            providerIdInput = ""
            baseURLInput = ""
            compatibilityAPI = CompatibleProviderAPI.from(apiType: currentProviderConfig?.defaultAPIType ?? "")
            existingConfigured = keychainStore.hasKey(forProvider: effectiveProviderGroupId)
        }
    }

    private func handleProviderChanged() {
        errorMessage = nil
        fetchMessage = nil
        modelSearch = ""
        manualModelInput = ""
        fetchedModels = []
        selectedModelIds = isEditMode ? selectedModelIds : []

        guard let cfg = currentProviderConfig else {
            existingConfigured = false
            return
        }

        if !isEditMode {
            displayName = cfg.displayName
            providerIdInput = cfg.allowsCustomProviderID ? "" : cfg.id
            baseURLInput = cfg.requiresBaseURLInput ? "" : ""
            compatibilityAPI = CompatibleProviderAPI.from(apiType: cfg.defaultAPIType)
        }

        existingConfigured = keychainStore.hasKey(forProvider: effectiveProviderGroupId)
    }

    private func handleProviderIdentifierChanged(oldValue: String, newValue: String) {
        guard showsCustomProviderIDInput else {
            existingConfigured = keychainStore.hasKey(forProvider: effectiveProviderGroupId)
            return
        }

        let oldProviderId = oldValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let newProviderId = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard oldProviderId != newProviderId else {
            existingConfigured = keychainStore.hasKey(forProvider: effectiveProviderGroupId)
            return
        }

        remapCustomProviderModels(from: oldProviderId, to: newProviderId)
        existingConfigured = keychainStore.hasKey(forProvider: effectiveProviderGroupId)
    }

    private func configuredModelCount(for provider: ProviderKeyConfig) -> Int? {
        let total = modelStore.providers
            .filter { $0.editorProviderId == provider.id }
            .reduce(0) { partial, item in
                partial + item.modelIds.count
            }
        return total > 0 ? total : nil
    }

    private func toggleModel(_ modelID: String) {
        if selectedModelIds.contains(modelID) {
            selectedModelIds.remove(modelID)
        } else {
            selectedModelIds.insert(modelID)
        }
    }

    private func addManualModel() {
        let raw = manualModelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !effectiveProviderGroupId.isEmpty else { return }

        let normalized = normalizedModelID(raw, providerId: effectiveProviderGroupId)
        let label = raw.components(separatedBy: "/").last ?? raw

        if !fetchedModels.contains(where: { $0.id == normalized }) {
            fetchedModels.append(ModelEntry(id: normalized, label: label))
        }
        modelLabels[normalized] = label
        selectedModelIds.insert(normalized)
        manualModelInput = ""
    }

    private func fetchRemoteModels() async {
        guard let cfg = currentProviderConfig else { return }
        guard cfg.supportsRemoteModelDiscovery else { return }

        let apiKey = resolvedCredentialForFetch()
        guard let baseURL = resolvedDiscoveryBaseURL(for: cfg) else {
            errorMessage = cfg.requiresBaseURLInput ? "请先填写 Base URL。" : "当前 Provider 缺少可用的模型发现地址。"
            return
        }

        isFetchingModels = true
        errorMessage = nil
        fetchMessage = nil
        defer { isFetchingModels = false }

        do {
            let modelIDs = try await CustomModelConfigUtils.fetchModelIDs(
                baseURL: baseURL,
                apiKey: apiKey
            )

            let entries = modelIDs.map { rawID in
                let normalized = normalizedModelID(rawID, providerId: effectiveProviderGroupId)
                modelLabels[normalized] = rawID
                return ModelEntry(id: normalized, label: rawID)
            }
            fetchedModels = entries
            if entries.isEmpty {
                errorMessage = "远程接口可达，但没有返回可识别的模型列表。"
            } else {
                fetchMessage = "已拉取 \(entries.count) 个模型。"
            }
        } catch {
            errorMessage = friendlyFetchErrorMessage(for: error)
        }
    }

    private func resolvedDiscoveryBaseURL(for cfg: ProviderKeyConfig) -> String? {
        if cfg.requiresBaseURLInput {
            return trimmedBaseURL.isEmpty ? nil : trimmedBaseURL
        }

        let trimmedCredential = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if cfg.isUrlConfig, !trimmedCredential.isEmpty {
            return trimmedCredential
        }
        return cfg.defaultBaseURL
    }

    private func resolvedCredentialForFetch() -> String? {
        let trimmed = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return keychainStore.read(forProvider: effectiveProviderGroupId)
    }

    private func orderedSelectedModelIDs() -> [String] {
        let orderedFromAvailable = availableModels.map(\.id).filter { selectedModelIds.contains($0) }
        let leftovers = selectedModelIds.filter { !orderedFromAvailable.contains($0) }.sorted()
        return orderedFromAvailable + leftovers
    }

    private func remapCustomProviderModels(from oldProviderId: String, to newProviderId: String) {
        guard showsCustomProviderIDInput else { return }
        guard !oldProviderId.isEmpty || !newProviderId.isEmpty else { return }

        func remap(_ modelID: String) -> String {
            let rawID: String
            if !oldProviderId.isEmpty, modelID.hasPrefix("\(oldProviderId)/") {
                rawID = String(modelID.dropFirst(oldProviderId.count + 1))
            } else if let slashIndex = modelID.firstIndex(of: "/") {
                rawID = String(modelID[modelID.index(after: slashIndex)...])
            } else {
                rawID = modelID
            }

            guard !newProviderId.isEmpty else { return rawID }
            return normalizedModelID(rawID, providerId: newProviderId)
        }

        fetchedModels = fetchedModels.map { entry in
            ModelEntry(id: remap(entry.id), label: entry.label)
        }

        selectedModelIds = Set(selectedModelIds.map(remap))

        var remappedLabels: [String: String] = [:]
        for (modelID, label) in modelLabels {
            remappedLabels[remap(modelID)] = label
        }
        modelLabels = remappedLabels
    }

    private func friendlyFetchErrorMessage(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            return "模型列表请求失败，请稍后重试。"
        }

        if message.contains("HTTP 401") || message.contains("HTTP 403") {
            return "\(message)。请检查当前 Provider 的 API Key、账户权限，以及 Base URL 是否指向对应服务。"
        }

        if message.contains("HTTP 404") {
            return "\(message)。请检查 Base URL 是否为标准的 OpenAI-compatible `/v1` 地址。"
        }

        return message
    }

    private func validateProviderInput() -> String? {
        if effectiveProviderGroupId.isEmpty {
            return showsCustomProviderIDInput ? "请先填写 Provider ID。" : "请先选择 Provider。"
        }

        if showsCustomProviderIDInput && !isValidCustomProviderID(effectiveProviderGroupId) {
            return "Provider ID 只支持字母、数字、`-` 和 `_`，且需以字母或数字开头。"
        }

        if showsBaseURLInput && trimmedBaseURL.isEmpty {
            return "请先填写 Base URL。"
        }

        if selectedModelIds.isEmpty {
            return "请至少选择一个模型。"
        }

        return nil
    }

    private func isValidCustomProviderID(_ value: String) -> Bool {
        let pattern = #"^[A-Za-z0-9][A-Za-z0-9_-]*$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    @MainActor
    private func commit() async {
        guard let cfg = currentProviderConfig else { return }
        if let validationError = validateProviderInput() {
            errorMessage = validationError
            return
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        let orderedModelIDs = orderedSelectedModelIDs()
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let targetName = trimmedDisplayName.isEmpty ? cfg.displayName : trimmedDisplayName

        let existing = editing ?? modelStore.provider(for: effectiveProviderGroupId)
        let provider = ProviderTemplate(
            id: existing?.id ?? UUID(),
            name: targetName,
            providerGroupId: effectiveProviderGroupId,
            providerTypeId: selectedProviderTypeId,
            providerDisplayName: cfg.displayName,
            modelIds: orderedModelIDs,
            modelLabels: Dictionary(uniqueKeysWithValues: orderedModelIDs.map { modelID in
                (modelID, modelLabels[modelID] ?? modelDisplayLabel(for: modelID))
            }),
            baseURL: showsBaseURLInput ? trimmedBaseURL : "",
            apiType: showsCompatibilityPicker ? compatibilityAPI.rawValue : cfg.defaultAPIType
        )

        modelStore.addProvider(provider)

        let trimmedCredential = credentialInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedCredential.isEmpty {
            keychainStore.save(apiKey: trimmedCredential, forProvider: effectiveProviderGroupId)
        }

        if let onSave {
            do {
                try await onSave(provider)
            } catch {
                errorMessage = "本机已保存，但同步当前 Profile 失败：\(error.localizedDescription)"
                return
            }
        }

        dismiss()
    }
}
