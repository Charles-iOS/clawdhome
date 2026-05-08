# EZRWorker 手机号登录门禁方案

## Summary
- 目标是把现有“进入 App 前登录”方案改为 `中国大陆手机号 + 密码` 登录：冷启动先显示登录页，登录成功后才进入当前 `MainView` 和所有现有业务窗口。
- 已锁定的产品决策：`已有后端接口`、`仅中国大陆手机号`、`只做登录`、`全部窗口受保护`、`仅启动时登录`、`Bearer Token`、`token 失效后直接回登录页`。
- 已确认直接复用 `/Users/charles/Desktop/WORK/ezrworker` 的用户认证接口，不新建独立 auth 服务。
- 本次只改 App 侧登录门禁，不改 `EZRWorkerHelper`，也不接入旧 `AppLockStore` / `AppLockScreen`。

## Implementation Changes
- `EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`
  - 注入新的 `AuthSessionStore` 和 `AppBootstrapCoordinator`。
  - 主窗口统一先进入 `AppRootGateView`，认证成功后才进入现有 `MainView`。
  - `claw-detail`、`user-init-wizard`、`channel-onboarding`、`maintenance-terminal`、`clone-claw` 五个 `WindowGroup` 全部包一层 `AuthenticatedSceneGate`；未登录不渲染业务内容。
  - 现有 `bootstrap()`、gateway 连接、重连循环和终止清理逻辑迁入 `AppBootstrapCoordinator`，只在认证成功后执行一次。
- 新增 `AppRootGateView` / `AuthenticatedAppShell` / `AuthenticatedSceneGate`
  - `AppRootGateView` 负责在 `launching / unauthenticated / authenticating / authenticated / failed` 间切换。
  - `AuthenticatedAppShell` 承载现有 App 并在首次进入时触发 bootstrap。
  - `AuthenticatedSceneGate` 负责所有子窗口统一登录守卫，不在各处拦 `openWindow`。
- 新增 `AuthSessionStore`
  - 暴露 `signIn(phone:password:)`、`signOut()`、`invalidateSession(reason:)`、`restoreInitialState()`。
  - 仅在内存保存 `accessToken` 和用户信息；App 退出后不保留登录态，确保下次启动必须重新登录。
  - `UserDefaults` 只保存 `lastLoginPhone` 和轻量 UI 状态；敏感信息不落盘。
  - 任一鉴权请求收到 `401` 时直接清空会话并回登录页，不做 refresh。
- 新增 `AuthAPIClient` / `BackendAuthClient`
  - 登录接口改为 `login(phoneNumber:password:)`。
  - 前端提交前仍统一校验大陆手机号，但发送给后端的是 `11 位本地手机号字符串`，不是 `+86` E.164。
  - 后端契约切换为 `ezrworker` 当前真实实现：
    - `POST /auth/login`
    - 请求体：`phone`, `password`
    - 其中 `phone` 传 `13800138000` 这类 11 位手机号
    - 返回统一 envelope：`{ success, message, code, version, data }`
    - `data` 内字段为：`user { id, phone, name, company, role, credits, maxBots, planId }`, `accessToken`, `refreshToken`
    - `GET /users/me` 使用 `Authorization: Bearer <accessToken>` 校验登录态
    - `POST /auth/refresh` 当前后端已提供，但 App 首版暂不接入 refresh
    - 当前没有用户态 `POST /auth/logout`；App 退出登录仅本地清除会话
  - `BackendAuthClient` 负责把 `user.name` 映射为 App 内部的 `displayName`，其余多余字段不透传到 UI 状态层。
  - 网络层继续使用 `URLSessionConfiguration.ephemeral`，避免 cookie 与凭证缓存落盘。
- 新增 `LoginView`
  - 登录卡片固定为：`+86` 前缀展示、11 位手机号输入框、密码输入框、登录按钮、加载态、错误提示。
  - 手机号输入规则固定：
    - 允许用户粘贴带空格或短横线的内容
    - 提交前去掉空格和 `-`
    - 校验必须是 11 位数字且首位为 `1`
    - 不支持国际号码、区号切换、短信验证码
  - 成功后立即切换到 `AuthenticatedAppShell`；失败留在登录页显示错误。
- `AppSettingsView`
  - 新增 `账户` 区域，展示当前登录手机号和 `退出登录` 按钮。
  - 退出登录后主窗口回登录页，所有已打开的受保护窗口自动转为占位态。
- `EZRWorkerApp/Info.plist` 与 `project.yml`
  - 新增 `AuthAPIBaseURL` 配置项，统一从 `Bundle.main` 读取认证服务地址。
  - 若未配置，启动后停在登录错误态并提示“认证服务未配置”。
- `Stable.xcstrings`
  - 补齐手机号登录相关文案，包括：手机号占位、格式错误、密码错误、会话失效、退出登录、窗口受保护提示。

## Public APIs / Interfaces
- 新增环境对象：
  - `AuthSessionStore`
  - `AppBootstrapCoordinator`
- 新增模型：
  - `enum AuthPhase { launching, unauthenticated, authenticating, authenticated, failed(AuthError) }`
  - `struct AuthUser { id, phone, displayName }`
  - `struct AuthSessionPayload { accessToken, user }`
  - `enum SessionInvalidationReason { logout, expired, unauthorized, bootstrapFailure }`
- 新增认证接口：
  - `protocol AuthAPIClient`
  - `func login(phoneNumber: String, password: String) async throws -> AuthSessionPayload`
  - `func logout(accessToken: String) async`
- 新增输入规范化接口：
  - `normalizeMainlandChinaPhone(_ raw: String) -> String?`
  - 成功时返回 `11 位本地手机号字符串`，失败返回 `nil`

## Test Plan
- 纯逻辑测试放入 `tests/`：
  - `AuthSessionStoreTests.swift`：覆盖初始未登录、登录成功、登录失败、退出登录、配置缺失、401 回登录页。
  - `PhoneNormalizationTests.swift`：覆盖纯 11 位手机号、带空格/短横线输入、位数错误、非法前缀、空输入。
  - `AuthGateRoutingTests.swift`：覆盖主窗口和子窗口在不同认证相位下的路由行为。
  - `BootstrapCoordinatorTests.swift`：覆盖未认证不启动、认证成功仅启动一次、退出登录后清理连接与重连任务。
- 手动验收：
  - 冷启动先看到手机号+密码登录页。
  - 输入合法大陆手机号和正确密码后进入现有主界面。
  - 输入非法手机号格式时前端直接拦截，不发请求。
  - 登录失败时显示明确错误，不进入业务页。
  - 登录请求体应与 `ezrworker` 一致，`phone` 发 11 位手机号而不是 `+86` E.164。
  - 登录前无法访问任何 `WindowGroup` 的业务内容；登录后所有窗口都可正常打开。
  - 退出登录后主窗口回登录页，子窗口转为受保护占位。
  - App 运行中任一认证请求收到 `401`，立即清空会话并回登录页。
  - 退出 App 再启动，必须重新登录。
  - `AuthAPIBaseURL` 缺失或后端不可达时，页面能明确报错。
- 构建验证：
  - 至少执行一次 `make build`，确认新增场景包装、环境注入和配置读取无编译错误。
  - 执行一次本地化检查，确认新增登录字符串齐全。

## Assumptions
- 首版仅支持中国大陆手机号，不支持国际号码、区号切换、短信登录、注册、忘记密码、多账号切换。
- 后端直接复用 `ezrworker` 现有用户认证接口：登录请求发 11 位手机号，返回 `accessToken + refreshToken` envelope；App 当前仅消费 `accessToken`。
- 登录门禁只负责“进入 App 前鉴权”，不改现有 gateway/helper 的本地权限体系。
- 旧 `AppLockStore`、`AppLockScreen` 和本地锁屏设置暂不接入新主入口；如后续需要“联网登录 + 本地二次解锁”，再单独规划。
