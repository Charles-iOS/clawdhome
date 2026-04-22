import SwiftUI

struct CreateProfileSheet: View {
    @Environment(GatewayProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = ""
    @State private var slug = ""
    @State private var autoStart = true
    @State private var showAdvanced = false
    @State private var configPathOverride = ""
    @State private var stateDirOverride = ""
    @State private var workspaceRootOverride = ""
    @State private var portOverride = ""
    @State private var errorMessage: String?
    @State private var isSaving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("基础信息") {
                    TextField("显示名称", text: $displayName)
                    TextField("slug（可选）", text: $slug)
                    Toggle("自动启动", isOn: $autoStart)
                }

                Section {
                    Toggle("高级路径/端口覆盖", isOn: $showAdvanced)
                }

                if showAdvanced {
                    Section("高级设置") {
                        TextField("OPENCLAW_CONFIG_PATH（绝对路径）", text: $configPathOverride)
                        TextField("OPENCLAW_STATE_DIR（绝对路径）", text: $stateDirOverride)
                        TextField("workspaceRoot（绝对路径）", text: $workspaceRootOverride)
                        TextField("端口（可选）", text: $portOverride)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建 Gateway/Profile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        createProfile()
                    }
                    .disabled(isSaving)
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
    }

    private func createProfile() {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil

        do {
            _ = try profileStore.createManagedProfile(
                displayName: displayName.isEmpty ? "Gateway \(profileStore.profiles.count + 1)" : displayName,
                slug: slug.isEmpty ? nil : slug,
                autoStart: autoStart,
                configPathOverride: configPathOverride.nilIfBlank,
                stateDirOverride: stateDirOverride.nilIfBlank,
                workspaceRootOverride: workspaceRootOverride.nilIfBlank,
                portOverride: Int(portOverride)
            )
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
