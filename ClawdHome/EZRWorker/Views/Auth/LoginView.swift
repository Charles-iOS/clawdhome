import SwiftUI

struct LoginView: View {
    @Environment(AuthSessionStore.self) private var authStore

    @State private var phone = ""
    @State private var password = ""
    @FocusState private var focusedField: Field?

    private enum Field {
        case phone
        case password
    }

    private var isLoading: Bool {
        if case .authenticating = authStore.phase {
            return true
        }
        return false
    }

    private var currentErrorMessage: String? {
        if case .failed(let error) = authStore.phase {
            return error.localizedDescription
        }
        return nil
    }

    var body: some View {
        ZStack {
            backgroundLayer

            HStack(spacing: 28) {
                heroSection
                loginCard
            }
            .padding(36)
            .frame(maxWidth: 980)
        }
        .onAppear {
            if phone.isEmpty {
                phone = authStore.lastLoginPhone
            }
            focusedField = .phone
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(red: 0.90, green: 0.95, blue: 0.93),
                    Color(red: 0.96, green: 0.92, blue: 0.88)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 320, height: 320)
                .blur(radius: 24)
                .offset(x: -280, y: -120)

            RoundedRectangle(cornerRadius: 42, style: .continuous)
                .fill(Color.white.opacity(0.20))
                .frame(width: 420, height: 260)
                .blur(radius: 18)
                .offset(x: 260, y: 160)
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("EZRWorker")
                .font(.system(size: 42, weight: .black, design: .rounded))
                .foregroundStyle(.primary)

            // Text(L10n.k("auth.login.hero_title", fallback: "登录后进入你的智能体控制台"))
            //     .font(.system(size: 30, weight: .bold))
            //     .fixedSize(horizontal: false, vertical: true)

            // Text(L10n.k("auth.login.hero_subtitle", fallback: "先完成手机号与密码验证，再进入现有 App 页面和所有业务窗口。"))
            //     .font(.title3)
            //     .foregroundStyle(.secondary)
            //     .fixedSize(horizontal: false, vertical: true)

            // HStack(spacing: 10) {
            //     featurePill(icon: "lock.shield", text: L10n.k("auth.login.feature.window_guard", fallback: "多窗口统一门禁"))
            //     featurePill(icon: "iphone.gen3", text: L10n.k("auth.login.feature.phone_password", fallback: "手机号 + 密码"))
            // }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loginCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.k("auth.login.card_title", fallback: "登录"))
                .font(.title2.weight(.semibold))

            Text(L10n.k("auth.login.card_subtitle", fallback: "请输入中国大陆手机号和密码"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("auth.login.phone_label", fallback: "手机号"))
                    .font(.headline)

                HStack(spacing: 0) {
                    Text("+86")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 64)
                        .padding(.vertical, 10)
                        .background(Color.black.opacity(0.04))
                    Divider()
                    TextField(
                        L10n.k("auth.login.phone_placeholder", fallback: "13800138000"),
                        text: $phone
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .focused($focusedField, equals: .phone)
                    .onChange(of: phone) { _, _ in
                        authStore.clearError()
                    }
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .frame(height: 44)

                Text(L10n.k("auth.login.phone_hint", fallback: "支持粘贴带空格或短横线的手机号，提交时会自动规范化。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.k("auth.login.password_label", fallback: "密码"))
                    .font(.headline)

                HStack(spacing: 0) {
                    SecureField(
                        L10n.k("auth.login.password_placeholder", fallback: "请输入密码"),
                        text: $password
                    )
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
                )
                .frame(height: 44)
                .focused($focusedField, equals: .password)
                .onChange(of: password) { _, _ in
                    authStore.clearError()
                }
                .onSubmit {
                    submit()
                }
            }

            if let currentErrorMessage {
                Label(currentErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: submit) {
                HStack(spacing: 10) {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(isLoading
                         ? L10n.k("auth.login.submitting", fallback: "登录中…")
                         : L10n.k("auth.login.submit", fallback: "登录"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isLoading)

#if DEBUG
            if authStore.canUseDebugTemporaryLogin {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        L10n.k(
                            "auth.login.debug_hint",
                            fallback: "Debug 构建且未配置认证服务时，可临时跳过服务端认证直接进入 App。"
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Button(action: signInWithDebugBypass) {
                        Text(L10n.k("auth.login.debug_bypass", fallback: "开发模式进入"))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isLoading)
                }
            }
#endif
        }
        .padding(24)
        .frame(width: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.65), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 30, x: 0, y: 16)
    }

    private func featurePill(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.65), in: Capsule())
    }

    private func submit() {
        guard !isLoading else { return }
        Task {
            await authStore.signIn(phone: phone, password: password)
            if case .authenticated = authStore.phase {
                password = ""
            }
        }
    }

#if DEBUG
    private func signInWithDebugBypass() {
        guard !isLoading else { return }
        authStore.signInWithDebugBypass(phone: phone)
        if case .authenticated = authStore.phase {
            password = ""
        }
    }
#endif
}
