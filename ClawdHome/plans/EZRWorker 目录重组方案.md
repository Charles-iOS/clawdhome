# EZRWorker 目录重组方案

## Summary
本次整理以“`主线 + 仍会被打开的旧窗口链路`”为范围，把当前实际在用的 `ClawdHome` App 侧代码按技术层归拢到现有 `ClawdHome/EZRWorker` 目录下；不删除旧文件，也不处理 `Shared` / `ClawdHomeHelper` 这类跨 target 代码。

当前已确认的事实：
- `ClawdHomeApp` 真实入口已切到 `MainView`。
- `EZRWorker` 目录目前为空。
- 旧窗口链路仍在被调用，至少包括 `claw-detail`、`user-init-wizard`、`channel-onboarding`、`maintenance-terminal`、`clone-claw`。
- `ContentView` 和一批旧页面不再是主入口，但本次按你的选择“先不碰”。

建议目标结构：

```text
ClawdHome/EZRWorker/
  App/
  Views/
  Services/
  Models/
  Resources/
  Utils/
```

## Key Changes
- 把 App 主线文件移入 `EZRWorker/App`：
  - `ClawdHomeApp.swift`
  - `MainView.swift`
  - `Views/Sidebar/*`
  - 保留 `ClawdHomeApp.swift` 里现有旧窗口包装类型在同文件内，不额外拆分，避免无意义访问级别调整。

- 把当前在用的页面移入 `EZRWorker/Views`，按现有二级分类继续保留：
  - `Views/Agent/*`
  - `Views/Capabilities/*`
  - `Views/Settings/*`
  - `Views/ChannelOnboarding/*`
  - 旧窗口链路相关视图：`UserListView.swift`、`UserDetailView.swift`、`UserInitWizardView.swift`、`UserFilesView.swift`、`CloneClawSheet.swift`、`TerminalLogView.swift`
  - 与主线直接相关的公共视图：如 `PageHeroHeader.swift`、`CommandOutputPanel.swift`、`ConfigEditorSheet.swift`、`ApplyCredentialSheet.swift`、`HealthCheckSheet.swift`、`GatewayProviderKeySheet.swift`、`ModelPickerSheet.swift`、`ModelPrioritySheet.swift`、`FallbackManagerSheet.swift`、`CLIConfigStep.swift`

- 把 App 侧业务层一并移入 `EZRWorker/Services`、`EZRWorker/Models`、`EZRWorker/Utils`：
  - `ClawdHome/Services/*` 整体迁入 `EZRWorker/Services`
  - `ClawdHome/Models/*` 整体迁入 `EZRWorker/Models`
  - `ClawdHome/Utils/*` 整体迁入 `EZRWorker/Utils`
  - 原因：主线与旧窗口混用这些服务/模型，整体迁移比只搬一部分更稳，避免新旧目录交叉引用继续恶化。

- 把 App 自有资源迁入 `EZRWorker/Resources`：
  - `ClawdHome/Resources/*`
  - 不移动 `Info.plist`、`Assets.xcassets`、`Stable.xcstrings`、`Localization/*`、`AppIcon.icns`，这些继续留在 `ClawdHome/` 根层作为包级资源。

- 保持以下内容原位不动：
  - `Shared/*`
  - `ClawdHomeHelper/*`
  - 当前未纳入主线范围的旧页面，例如 `ContentView.swift`、`DashboardView.swift`、`BackupView.swift`、`SecurityAuditView.swift`、`AILabView.swift`、`RoleMarketView.swift`、`NetworkPolicyView.swift`、`SettingsView.swift` 等
  - `ClawPoolView.swift` 这个已废弃占位文件，先保留不删

- 更新 `ClawdHome.xcodeproj/project.pbxproj`：
  - 调整 group 层级，让 `EZRWorker` 成为 App 侧源码主分组
  - 同步所有被移动文件的路径引用
  - 保持 target membership、Build Phases、资源拷贝行为不变
  - 不改 bundle id、不改 target 结构、不改编译设置

## Public APIs / Interfaces
- 不引入新的对外 API、数据模型或协议。
- 仅发生源码物理路径和 Xcode group 结构变化。
- 代码符号名、窗口 ID、环境注入方式、现有 SwiftUI 导航行为保持不变。

## Test Plan
- 构建验证：
  - `xcodebuild` 构建 `ClawdHome` target，确认路径迁移后项目仍可编译。
  - 如有独立 helper 依赖，一并确认 `ClawdHomeHelper` 未受 `Shared` 保持原位策略影响。

- 行为回归：
  - App 启动后默认进入 `MainView`。
  - Sidebar 的 `agents / cron / skills / channels / settings` 均可进入。
  - 从 `UserListView` 能继续打开 `claw-detail`、`user-init-wizard`、`clone-claw`。
  - 从 `UserDetailView` / `UserInitWizardView` 能继续打开 `channel-onboarding`、`maintenance-terminal`。
  - `FeishuChannelOnboardingSheet`、`AgentBindingsView` 相关调用编译通过。

- 现有测试：
  - 跑 `tests/UserInitPresentationRoutingTests.swift`
  - 跑 `tests/AppUpdateStateTests.swift`
  - 跑 `tests/UpdateCheckPolicyTests.swift`

## Assumptions
- 使用现有目录名 `ClawdHome/EZRWorker`，不按你消息里的拼写另建 `EZRWroker`。
- “把用到的文件移动到 EZRWorker 下”默认解释为：`ClawdHome` App target 内当前主线和旧窗口链路所依赖的源码迁入；跨 target 的 `Shared` 与 `ClawdHomeHelper` 不迁。
- 本次不删除任何旧文件，不做二轮“清废页”；只是先把在用代码收拢，后续再基于新目录做精简。
