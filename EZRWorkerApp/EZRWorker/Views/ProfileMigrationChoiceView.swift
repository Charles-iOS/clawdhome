import SwiftUI

struct ProfileMigrationChoiceView: View {
    let legacyPort: Int?

    @Environment(GatewayProfileStore.self) private var profileStore
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.08),
                    Color(nsColor: .underPageBackgroundColor),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("检测到旧单实例数据")
                            .font(.title2.weight(.semibold))
                        Text("已发现 `~/.openclaw/openclaw.json`。请选择本次升级后的默认 Gateway/Profile 方案。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        migrationCard(
                            title: "复用老的",
                            subtitle: "直接把现有 `~/.openclaw` 接成默认 profile，保留旧 token、旧 agent、旧渠道数据。",
                            buttonTitle: "复用老的（推荐）",
                            action: useLegacyProfile
                        )

                        migrationCard(
                            title: "创建新的",
                            subtitle: freshProfileSubtitle,
                            buttonTitle: "创建新的",
                            action: createFreshProfile
                        )

                        if let legacyPort {
                            Text("检测到旧 gateway 端口：\(legacyPort)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(28)
                    .frame(maxWidth: 720, alignment: .leading)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.black.opacity(0.08), radius: 18, y: 10)
                }
                .frame(maxWidth: .infinity, minHeight: 0)
                .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func migrationCard(
        title: String,
        subtitle: String,
        buttonTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            Text(subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var freshProfileSubtitle: String {
        let defaultProfilePath = EZRWorkerPaths.profilesDirectory
            .appendingPathComponent("default", isDirectory: true)
            .path
        return "在 `\(defaultProfilePath)/` 下创建全新的默认 profile，不改动旧 `~/.openclaw`。"
    }

    private func useLegacyProfile() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try profileStore.completeLegacyReuseMigration()
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }

    private func createFreshProfile() {
        guard !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        do {
            try profileStore.completeCreateNewMigration()
        } catch {
            errorMessage = error.localizedDescription
            isSubmitting = false
        }
    }
}
