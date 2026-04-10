// ClawdHome/Views/Capabilities/ModelConfigView.swift

import SwiftUI

struct ModelConfigView: View {
    @Environment(GatewayService.self) private var gateway
    @Environment(ProviderKeychainStore.self) private var keychainStore

    @State private var modelGroups: [ModelGroup]?
    @State private var isLoading = false

    /// 从动态模型列表提取去重的 provider id 列表
    private var providerIds: [String] {
        guard let groups = modelGroups else { return [] }
        return groups.map(\.provider)
    }

    var body: some View {
        List {
            providerKeysSection
            availableModelsSection
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .navigationTitle(L10n.k("models.title", fallback: "模型配置"))
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await loadModels() }
                } label: {
                    Label(L10n.k("common.refresh", fallback: "刷新"), systemImage: "arrow.clockwise")
                }
                .disabled(!gateway.isConnected)
            }
        }
        .task { await loadModels() }
    }

    @ViewBuilder
    private var providerKeysSection: some View {
        Section(L10n.k("models.api_keys", fallback: "API 密钥")) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if providerIds.isEmpty {
                Text(L10n.k("models.not_connected", fallback: "Gateway 未连接"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(providerIds, id: \.self) { providerId in
                    DynamicProviderKeyRow(providerId: providerId)
                }
            }
        }
    }

    @ViewBuilder
    private var availableModelsSection: some View {
        Section(L10n.k("models.available", fallback: "可用模型")) {
            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity)
            } else if let groups = modelGroups {
                ForEach(groups) { group in
                    DisclosureGroup {
                        ForEach(group.models) { model in
                            LabeledContent(model.label, value: model.id)
                                .font(.caption)
                        }
                    } label: {
                        HStack {
                            Text(group.provider)
                                .fontWeight(.medium)
                            Text("\(group.models.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(L10n.k("models.not_connected", fallback: "Gateway 未连接"))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func loadModels() async {
        isLoading = true
        modelGroups = await gateway.modelsList()
        isLoading = false
    }
}
