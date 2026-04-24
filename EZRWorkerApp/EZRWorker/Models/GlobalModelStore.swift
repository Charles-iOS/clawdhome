// EZRWorkerApp/Models/GlobalModelStore.swift
import Foundation
import Observation

/// 当前新主线按 provider 粒度管理模型配置。
/// `name` 仍保留作为展示名，便于兼容旧数据。
struct ProviderTemplate: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var providerGroupId: String
    var providerTypeId: String
    var providerDisplayName: String
    var modelIds: [String]
    var modelLabels: [String: String]
    var baseURL: String
    var apiType: String

    init(
        id: UUID = UUID(),
        name: String,
        providerGroupId: String,
        providerTypeId: String? = nil,
        providerDisplayName: String,
        modelIds: [String],
        modelLabels: [String: String] = [:],
        baseURL: String = "",
        apiType: String = ""
    ) {
        self.id = id
        self.name = name
        self.providerGroupId = providerGroupId
        self.providerTypeId = providerTypeId ?? providerGroupId
        self.providerDisplayName = providerDisplayName
        self.modelIds = modelIds
        self.modelLabels = modelLabels
        self.baseURL = baseURL
        self.apiType = apiType
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case providerGroupId
        case providerTypeId
        case providerDisplayName
        case modelIds
        case modelLabels
        case baseURL
        case apiType
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        providerGroupId = try c.decode(String.self, forKey: .providerGroupId)
        providerTypeId = try c.decodeIfPresent(String.self, forKey: .providerTypeId) ?? providerGroupId
        providerDisplayName = try c.decodeIfPresent(String.self, forKey: .providerDisplayName)
            ?? providerDisplayNameForID(providerTypeId)
        modelIds = try c.decodeIfPresent([String].self, forKey: .modelIds) ?? []
        modelLabels = try c.decodeIfPresent([String: String].self, forKey: .modelLabels) ?? [:]
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiType = try c.decodeIfPresent(String.self, forKey: .apiType) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(providerGroupId, forKey: .providerGroupId)
        try c.encode(providerTypeId, forKey: .providerTypeId)
        try c.encode(providerDisplayName, forKey: .providerDisplayName)
        try c.encode(modelIds, forKey: .modelIds)
        try c.encode(modelLabels, forKey: .modelLabels)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(apiType, forKey: .apiType)
    }

    var displayName: String {
        name.isEmpty ? providerDisplayName : name
    }

    var editorProviderId: String {
        providerTypeId.isEmpty ? providerGroupId : providerTypeId
    }

    var normalizedModelIDs: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for rawID in modelIds {
            let normalized = normalizedModelID(rawID, providerId: providerGroupId)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            ordered.append(normalized)
        }
        return ordered
    }

    func modelEntries() -> [ModelEntry] {
        normalizedModelIDs.map { modelID in
            ModelEntry(
                id: modelID,
                label: modelDisplayLabel(for: modelID, labels: modelLabels)
            )
        }
    }
}

private struct PersistedState: Codable {
    var providers: [ProviderTemplate] = []
}

/// 全局模型池
@Observable
final class GlobalModelStore {
    private(set) var providers: [ProviderTemplate] = []

    var hasTemplate: Bool { providers.contains { !$0.modelIds.isEmpty } }

    /// 所有账户下已选模型的平铺列表
    var allTemplateModels: [ModelEntry] {
        var seen = Set<String>()
        var output: [ModelEntry] = []
        for provider in providers {
            for entry in provider.modelEntries() where seen.insert(entry.id).inserted {
                output.append(entry)
            }
        }
        return output
    }

    func provider(for providerId: String) -> ProviderTemplate? {
        providers.first(where: { $0.providerGroupId == providerId })
    }

    func modelEntries(for providerId: String) -> [ModelEntry] {
        provider(for: providerId)?.modelEntries() ?? []
    }

    // MARK: - 编辑

    func addProvider(_ entry: ProviderTemplate) {
        if let idx = providers.firstIndex(where: { $0.providerGroupId == entry.providerGroupId }) {
            providers[idx] = entry
        } else {
            providers.append(entry)
        }
        save()
    }

    func updateProvider(_ entry: ProviderTemplate) {
        guard let idx = providers.firstIndex(where: { $0.id == entry.id }) else { return }
        providers[idx] = entry
        save()
    }

    func removeProvider(id: UUID) {
        providers.removeAll { $0.id == id }
        save()
    }

    func moveProviders(from source: IndexSet, to destination: Int) {
        providers.move(fromOffsets: source, toOffset: destination)
        save()
    }

    // MARK: - 兼容（UserDetailView 应用模版）

    var templateDefault: String? { allTemplateModels.first?.id }
    var templateFallbacks: [String] { allTemplateModels.dropFirst().map(\.id) }

    // MARK: - 持久化

    private static var storeURL: URL {
        EZRWorkerPaths.ensureApplicationSupportDirectories()
        return EZRWorkerPaths.applicationSupportDirectory.appendingPathComponent("global-models.json")
    }

    func load() {
        if let data = try? Data(contentsOf: Self.storeURL),
           let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
            providers = state.providers
            return
        }
    }

    func save() {
        let state = PersistedState(providers: providers)
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.storeURL)
        }
    }
}
