# EZRWorker 项目结构说明 v2

本文是 [`project-structure.zh.md`](./project-structure.zh.md) 的 v2 版，面向“多 OpenClaw Gateway/Profile + Global Supervisor” 这条新主线来重新理解当前仓库。

它的目标不是给出“理想中的未来目录图”，而是回答两个更实际的问题：

- 现在这个仓库真实长什么样
- 如果我要开始读代码，应该先把哪些目录当成主线，哪些当成兼容层

和旧版说明相比，v2 最重要的变化是：

- 不再把项目理解成“App + Helper 管一个单 Gateway”
- 而是把它理解成“App + Supervisor 管多个 Profile，其中 App 只完整接入当前选中的一个 Profile”

## 1. 项目定位

这个仓库现在更适合被理解为一个运行在 macOS 当前登录用户会话中的本地控制平面。它的核心职责不是单纯启动一个 OpenClaw，而是：

- 管理多个 `GatewayProfile`
- 用一个全局用户态 `EZRWorkerSupervisor` 托管这些 profile 的 prepare/start/stop/restart/autostart
- 让 `EZRWorker.app` 只对“当前选中的 profile”建立完整业务上下文
- 把旧的 root `EZRWorkerHelper` 收敛为兼容层和系统能力承载者，而不是新主线 runtime 的唯一后端

截至当前版本，品牌和工程名迁移已经基本收尾：

- Xcode application target 名称已经是 `EZRWorker`
- 产品名、bundle id、Mach service、App Support 目录、Helper/Supervisor plist 也都统一到了 `EZRWorker`
- 主应用源码根目录已经切到 `EZRWorkerApp/`

仍然处在“过渡态”的，主要不是运行时品牌，而是目录组织方式：

- 主应用主线代码仍放在 `EZRWorkerApp/EZRWorker/`
- 历史窗口和兼容 UI 仍放在 `EZRWorkerApp/Views/`

另外要特别区分两类“迁移”：

- 品牌迁移：
  指 `ClawdHome -> EZRWorker` 的本地状态/Keychain/目录迁移。这部分逻辑已经删除，不再保留 `BrandMigrationManager`。
- 旧单实例迁移：
  指把 `~/.openclaw/openclaw.json` 导入为新的 profile 模型。这部分仍然保留，所以启动链路里还会看到 `needsLegacyMigration` 和 `ProfileMigrationChoiceView`。

所以，今天这个项目可以概括成 4 条线：

1. `EZRWorker.app`
   当前主应用，负责 UI、认证、profile 选择、当前 profile 的 Gateway 连接和 agent 业务上下文。
2. `EZRWorkerSupervisor`
   用户态后台进程，负责多 profile 的生命周期与运行态维护。
3. `EZRWorkerHelper`
   旧特权 Helper，保留系统级能力和历史多用户兼容逻辑。
4. `Shared`
   App、Supervisor、Helper 共享的协议、模型、路径常量和 runtime 工具。

## 2. 运行时心智模型

如果只用一句话概括 v2 架构：

```text
操作员
  -> EZRWorker.app
      -> 选择当前 profile
      -> 通过 XPC 调 EZRWorkerSupervisor 管所有 profile 生命周期
      -> 只对当前 profile 建立 GatewayService / AgentStore / WorkspaceManager
  -> EZRWorkerSupervisor
      -> 管理 default / sales / test ... 多个 OpenClaw gateway 进程
  -> EZRWorkerHelper
      -> 承担旧系统级能力和兼容链路
```

把它展开以后，大致是这样：

```text
当前登录用户
  -> EZRWorker.app
      -> GatewayProfileStore
      -> AppBootstrapCoordinator
          -> SupervisorClient (XPC)
              -> EZRWorkerSupervisor
                  -> OpenClaw Gateway: default
                  -> OpenClaw Gateway: sales
                  -> OpenClaw Gateway: test
          -> GatewayService (仅连接当前选中的 profile)
          -> AgentStore / AgentWorkspaceManager / Channel / Skills / Settings
      -> HelperClient (仅旧兼容能力)
          -> EZRWorkerHelper
```

这里最关键的边界是：

- `Supervisor` 管“所有 profile 的进程生命周期和运行态”
- `App` 管“当前选中 profile 的完整业务上下文”
- `Helper` 管“仍需要系统级权限或旧多用户模型的兼容能力”

## 3. 启动与切换链路

如果你第一次接手这套 v2 结构，最值得先理解的是启动链路：

1. [`../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`](../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift)
   认证路由总入口，先决定显示启动页、登录页还是主应用壳层。
2. [`../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`](../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift)
   加载 `profiles.json`。如果不存在 profile 文档但检测到旧的 `~/.openclaw/openclaw.json`，则进入旧单实例迁移选择流。
3. [`../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift`](../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift)
   只负责旧单实例导入，不再承担品牌迁移。
4. [`../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`](../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift)
   新主线 bootstrap 中枢，串起环境检查、Supervisor 连接、当前 profile 启动、Gateway 建连和 agent 数据加载。
5. [`../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift`](../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift)
   通过 XPC 连接 `ai.ezrworker.mac.supervisor`，获取所有 profile 运行态并控制当前 profile 生命周期。
6. [`../EZRWorkerSupervisor/SupervisorController.swift`](../EZRWorkerSupervisor/SupervisorController.swift)
   真正执行 `prepare/start/stop/restart/reloadProfiles`，并负责进程 adopt、探活和 autostart reconcile。
7. [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift)
   对当前 profile 建立 WebSocket / JSON-RPC 控制连接。
8. [`../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift`](../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift)
   加载当前 profile 下的 agent、binding、workspace 等业务数据。

切换 profile 时，新的主线不是“切一个 UI tab”，而是：

1. `GatewayProfileStore` 更新当前选中项
2. `AppBootstrapCoordinator` 触发 restart
3. `SupervisorClient` 重新拿到当前 profile 运行态
4. `GatewayService` / `AgentStore` / `AgentWorkspaceManager` 重新绑定到新 profile

登出时则会走 `bootstrapCoordinator.resetForUnauthenticated()`，把当前 profile 的 runtime 连接状态复位。

## 4. 当前仓库的实际目录结构

下面这棵树描述的是“今天这个仓库真实长什么样”，不是目标态的理想结构：

```text
project.yml
Makefile
README.md
README.zh.md

EZRWorkerApp/
  EZRWorker/
    App/
    Models/
    Services/
      Gateway/
      Stores/
    Views/
      Agent/
      Auth/
      Capabilities/
      ChannelOnboarding/
      Settings/
    Resources/
    Utils/
  Views/
    ModelManager/
  Localization/
  Assets.xcassets/
  Stable.xcstrings
  Info.plist
  plans/

EZRWorkerHelper/
  main.swift
  Operations/

EZRWorkerSupervisor/
  main.swift
  SupervisorController.swift

Shared/
Resources/
scripts/
tests/
docs/
```

这份树有两个容易误读的点：

- `EZRWorkerApp/EZRWorker/` 不是“又一层 App”；它是当前主应用主线代码实际所在位置。
- `EZRWorkerApp/Views/` 不是当前主应用壳层的总入口；它主要是历史多用户时期遗留的窗口、sheet 和工具页。

## 5. 目录逐段说明

### `project.yml`

[`../project.yml`](../project.yml) 仍然是理解整个工程的第一入口。当前它定义了 3 个 target：

- `EZRWorker`
  application target，也是当前主应用 target
- `EZRWorkerHelper`
  特权 Helper
- `EZRWorkerSupervisor`
  用户态后台进程

这里还有几件值得特别注意的事：

- App target 的源码根已经指向 `EZRWorkerApp`
- `Info.plist` 和 entitlements 都已经改到 `EZRWorkerApp/*`
- post-build 会把 `EZRWorkerHelper` 与 `EZRWorkerSupervisor` 连同各自 plist 一起嵌入 App Bundle

也就是说，如果你想搞清楚“工程如何把三个 target 组合成一个可运行产物”，`project.yml` 是最先要看的文件。

### `EZRWorkerApp/EZRWorker/`

这是当前真正的主应用代码区，可以把它视作“未来更扁平的 `EZRWorkerApp/` 的现状形态”。

#### `App/`

应用入口、主壳层、认证路由和 sidebar 都在这里。

重点文件：

- [`../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`](../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift)
- [`../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`](../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift)
- [`../EZRWorkerApp/EZRWorker/App/MainView.swift`](../EZRWorkerApp/EZRWorker/App/MainView.swift)
- [`../EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift`](../EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift)

当前 `AppRootGateView` 的分层可以简单理解成：

- 外层决定是否进入已认证状态
- 已认证后，如果检测到旧单实例配置，则显示 `ProfileMigrationChoiceView`
- 否则进入 `MainView`，并由 `AppBootstrapCoordinator` 控制启动态/失败态遮罩

#### `Models/`

这里放的是当前主线的领域模型，包含 agent、auth、channel、provider key、cron、skills 等数据结构。

如果你在追一个业务对象“它是什么”“它如何被保存”“它如何在页面和服务之间传递”，通常会从这里和 `Shared/` 一起读起。

#### `Services/`

这是 v2 结构里最重要的一层。建议按职责分成 5 组理解：

- bootstrap/profile 组：
  [`../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`](../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift)、
  [`../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`](../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift)
- supervisor 接入组：
  [`../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift`](../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift)
- 当前 profile 业务上下文组：
  [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift)、
  [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift)、
  [`../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift`](../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift)、
  [`../EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift`](../EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift)
- App 级状态与基础设施组：
  `AuthSessionStore.swift`、
  `UpdateChecker.swift`、
  `AppLockStore.swift`、
  `GlobalModelStore.swift`、
  `GlobalSecretsStore.swift`
- 兼容/遗留桥接组：
  [`../EZRWorkerApp/EZRWorker/Services/HelperClient.swift`](../EZRWorkerApp/EZRWorker/Services/HelperClient.swift)、
  [`../EZRWorkerApp/EZRWorker/Services/GatewayHub.swift`](../EZRWorkerApp/EZRWorker/Services/GatewayHub.swift)、
  [`../EZRWorkerApp/EZRWorker/Services/ShrimpPool.swift`](../EZRWorkerApp/EZRWorker/Services/ShrimpPool.swift)

这里有一个现在已经发生的重要变化：

- 以前的品牌迁移管理器 `BrandMigrationManager.swift` 已经不存在
- `EZRWorkerApp.swift` 和 `AppBootstrapCoordinator.swift` 也不再依赖品牌迁移逻辑

保留下来的旧迁移，只剩 `~/.openclaw` 导入到 profile 模型这一条链路。

#### `Views/`

这是当前主导航下的新页面区。从 v2 的视角看，建议优先关注这些子域：

- `Views/Auth/`
  登录和认证 UI
- `Views/Agent/`
  当前 profile 的 agent 列表、详情、workspace、创建向导
- `Views/Capabilities/`
  skills、channels、cron、模型配置
- `Views/ChannelOnboarding/`
  新渠道绑定相关引导窗口
- `Views/Settings/`
  settings 和 profile 管理相关 UI

几个值得优先读的页面入口：

- [`../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift`](../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift)
- [`../EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`](../EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift)
- [`../EZRWorkerApp/EZRWorker/Views/Settings/CreateProfileSheet.swift`](../EZRWorkerApp/EZRWorker/Views/Settings/CreateProfileSheet.swift)

#### `Resources/`

新主线 UI 使用的内置资源，比如：

- `PresetAgents.json`
- `onboard.html`
- `roles.html`

#### `Utils/`

当前主线可复用的小工具，例如端口分配和格式化工具。

### `EZRWorkerApp/Views/`

这是最容易让新同学误判的目录。

它并不是当前产品主壳层的页面目录，而是历史多用户时期留下的一批窗口、sheet 和工具页面。它们现在仍可能被详情窗口、初始化流程、克隆流程、系统能力页或旧交互路径复用，但不应再作为 v2 主线产品模型的唯一依据。

这块目录大致可以分成几类：

- 系统级/多用户管理页：
  `UserListView.swift`、`UserDetailView.swift`、`AddUserSheet.swift`、`SecurityAuditView.swift`
- 历史工具页：
  `BackupView.swift`、`LogViewerSheet.swift`、`NetworkPolicyView.swift`、`RoleMarketView.swift`
- 旧模型配置页：
  `Views/ModelManager/*`

所以，理解它时要把握住两个判断：

- 它不是“可以直接删”的死代码区
- 但它也不是“项目现在主要长这样”的主线目录

### `EZRWorkerApp/Localization/`、`Stable.xcstrings`、`Info.plist`

这几部分仍然是主应用自己的基础设施：

- `Localization/`
  统一封装文案访问和语言切换
- `Stable.xcstrings`
  中英文 UI 字符串总表
- `Info.plist`
  App 基础信息与版本入口

### `EZRWorkerApp/plans/`

这里不是运行时代码，但对理解为什么会出现 `profile/supervisor/legacy migration` 这些模块非常重要。目录重组、品牌统一、兼容层收缩，基本都能在这里找到设计背景。

### `EZRWorkerSupervisor/`

这是 v2 新架构里最值得特别注意的目录，因为它代表“生命周期托管从 Helper 下沉到用户态 Supervisor”这件事已经落地。

目前这个 target 仍然比较扁平，核心只有两个文件：

- [`../EZRWorkerSupervisor/main.swift`](../EZRWorkerSupervisor/main.swift)
  XPC listener 入口
- [`../EZRWorkerSupervisor/SupervisorController.swift`](../EZRWorkerSupervisor/SupervisorController.swift)
  当前核心控制器，负责：
  - 读取 `profiles.json`
  - 解析每个 profile 的 config/state/workspace/port
  - 执行 `prepare/start/stop/restart/reloadProfiles`
  - 进行 HTTP probe、readyState 维护和已有进程 adopt
  - 对 `autoStart = true` 的 profile 做 reconcile

虽然方案文档里的目标态会把这里继续拆成 `Services/`、`Models/` 等子目录，但目前仓库里它还是一个相对扁平的小 target。

### `EZRWorkerHelper/`

[`../EZRWorkerHelper/main.swift`](../EZRWorkerHelper/main.swift) 和 `Operations/` 仍然是系统级能力的执行区。

它目前更适合被理解为：

- 旧多用户模型的兼容后端
- 文件操作、安装、进程管理、网络/统计采集等系统级能力承载者
- 新主线过渡期仍会被部分服务调用的兼容层

而不应该再被理解成：

- “所有新 gateway/profile 生命周期都必须经过它”

`Operations/` 下依然有几类重要能力：

- `GatewayManager.swift`
- `UserManager.swift`
- `UserFileManager.swift`
- `ProcessManager.swift`
- `InstallManager.swift`
- `AppUpdateHeartbeatService.swift`
- `NStatCollector.swift`

### `Shared/`

`Shared/` 在 v2 中的重要性明显上升了，因为它不再只是 App/Helper 的协议层，也开始承载 App/Supervisor 的新共享模型。

可以把它分成 3 组看：

- v2 主线共享协议和模型：
  - [`../Shared/GatewayProfiles.swift`](../Shared/GatewayProfiles.swift)
  - [`../Shared/SupervisorProtocol.swift`](../Shared/SupervisorProtocol.swift)
  - [`../Shared/OpenClawRuntime.swift`](../Shared/OpenClawRuntime.swift)
  - [`../Shared/GatewayHealthProbe.swift`](../Shared/GatewayHealthProbe.swift)
  - [`../Shared/EZRWorkerBranding.swift`](../Shared/EZRWorkerBranding.swift)
- 旧 Helper 共享协议和模型：
  - [`../Shared/HelperProtocol.swift`](../Shared/HelperProtocol.swift)
  - `FileModels.swift`
  - `ProcessModels.swift`
  - `DashboardModels.swift`
  - `UserAdoptionFlow.swift`
- 通用应用状态和 UI 支撑模型：
  - `AppUpdateState.swift`
  - `AppNotifications.swift`
  - `UserInitPresentationRouting.swift`
  - `HealthCheck.swift`
  - `ManagedUserDisplayName.swift`
  - `UserDetailWindowLayout.swift`

这里还有一个现在很值得记住的点：

- [`../Shared/EZRWorkerBranding.swift`](../Shared/EZRWorkerBranding.swift) 现在只保留新品牌常量、本地目录名和运行时标识
- 旧品牌回退常量已经被移除
- 但 `legacyOpenClawDirectory` / `legacyOpenClawConfigURL` 还在，用于旧单实例导入

### `Resources/`

这里主要放运行时安装资源，目前最关键的是两个 plist：

- [`../Resources/ai.ezrworker.mac.helper.plist`](../Resources/ai.ezrworker.mac.helper.plist)
- [`../Resources/ai.ezrworker.mac.supervisor.plist`](../Resources/ai.ezrworker.mac.supervisor.plist)

从 v2 视角看，最重要的新资源是 `ai.ezrworker.mac.supervisor.plist`，它对应全局用户态 LaunchAgent。

### `scripts/`

这里是构建、打包、runtime 打包、本地化检查和发布脚本集合。v2 主线下尤其常看的有：

- [`../scripts/bundle-runtime.sh`](../scripts/bundle-runtime.sh)
- [`../scripts/build-pkg.sh`](../scripts/build-pkg.sh)
- [`../scripts/install-helper-dev.sh`](../scripts/install-helper-dev.sh)
- [`../scripts/i18n_ci_check.py`](../scripts/i18n_ci_check.py)

需要注意的是：

- 脚本里的本地运行时身份已经切到 `EZRWorker`
- 但外部发布基础设施仍然保留 `clawdhome.app`、`clawdhome_website`、`clawdhome-release` 这些名字，这是发布链路而不是本地运行时身份

### `tests/`

测试规模仍不算大，但已经覆盖了几块关键主线：

- 认证路由：
  `AuthGateRoutingTests.swift`、`AuthSessionStoreTests.swift`
- bootstrap：
  `BootstrapCoordinatorTests.swift`
- 更新策略：
  `AppUpdateStateTests.swift`、`UpdateCheckPolicyTests.swift`
- 输入规范化：
  `PhoneNormalizationTests.swift`
- 旧初始化展示路由：
  `UserInitPresentationRoutingTests.swift`

### `docs/`

文档目录仍然很轻，但值得保留关注的文件有：

- [`./project-structure.zh.md`](./project-structure.zh.md)
- [`./project-structure-v2.zh.md`](./project-structure-v2.zh.md)
- [`./XPC-SPEC.md`](./XPC-SPEC.md)
- [`./i18n.md`](./i18n.md)

## 6. 哪些是主线，哪些是兼容层

如果你希望在脑中快速建立“优先级地图”，可以直接按下面这条线来判断。

### v2 主线

- `EZRWorkerApp/EZRWorker/App/*`
- `EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`
- `EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`
- `EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift`
- `EZRWorkerApp/EZRWorker/Services/Gateway/*`
- `EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift`
- `EZRWorkerSupervisor/*`
- `Shared/GatewayProfiles.swift`
- `Shared/SupervisorProtocol.swift`
- `Shared/OpenClawRuntime.swift`
- `Shared/EZRWorkerBranding.swift`
- `Resources/ai.ezrworker.mac.supervisor.plist`

### 主线中的过渡点

这些文件不属于“品牌兼容层”，但仍然服务于旧单实例导入或当前过渡态目录组织：

- `EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift`
- `GatewayProfileSourceKind.legacyReuse`
- `EZRWorkerPaths.legacyOpenClawDirectory`
- `EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift` 中对旧 `.openclaw` 路径的兼容

### 兼容层 / 遗留层

- `EZRWorkerHelper/*`
- `Shared/HelperProtocol.swift`
- `EZRWorkerApp/Views/*`
- `EZRWorkerApp/EZRWorker/Services/HelperClient.swift`
- `EZRWorkerApp/EZRWorker/Services/GatewayHub.swift`
- `EZRWorkerApp/EZRWorker/Services/ShrimpPool.swift`
- `Resources/ai.ezrworker.mac.helper.plist`

对阅读和改造工作来说，这意味着：

- 做新 profile/runtime/supervisor 相关需求时，优先在主线目录里找答案
- 只有涉及旧多用户窗口、系统级安装操作或兼容逻辑时，再深入 Helper 和旧 Views

## 7. 现在最容易混淆的几个事实

为了避免继续被过渡态结构带偏，建议先把下面几件事记住：

1. `EZRWorkerApp/EZRWorker/` 才是当前主应用主线代码区。
2. `EZRWorkerApp/Views/` 不是主壳层，而是历史窗口/工具页集合。
3. 品牌迁移逻辑已经删除，不要再去找 `BrandMigrationManager`。
4. 旧单实例 `.openclaw` 导入仍然保留，所以看到 `legacyReuse` 并不代表还有品牌兼容逻辑。
5. 外部 URL 仍然可能是 `clawdhome.app`，这不表示本地运行时身份还是旧品牌；它只是发布基础设施还没改名。

## 8. 关键入口文件清单

如果你不想一上来就读完整个仓库，下面这组文件最值得先读：

| 文件 | 为什么先读 |
| --- | --- |
| [`../project.yml`](../project.yml) | 看 3 个 target、依赖、嵌入脚本和源码根 |
| [`../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`](../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift) | App 入口和环境注入 |
| [`../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`](../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift) | 登录态、旧单实例迁移和主壳层的总路由 |
| [`../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`](../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift) | profile 持久化、选择和旧单实例导入入口 |
| [`../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift`](../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift) | 旧 `~/.openclaw` 升级到 profile 模型的 UI 入口 |
| [`../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`](../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift) | v2 bootstrap 主链路 |
| [`../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift`](../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift) | App 和 Supervisor 的 XPC 桥 |
| [`../EZRWorkerSupervisor/SupervisorController.swift`](../EZRWorkerSupervisor/SupervisorController.swift) | 所有 profile 运行时控制的核心 |
| [`../Shared/GatewayProfiles.swift`](../Shared/GatewayProfiles.swift) | profile、resolution、runtime 这些新主线模型都在这里 |
| [`../Shared/SupervisorProtocol.swift`](../Shared/SupervisorProtocol.swift) | App 和 Supervisor 的正式协议边界 |
| [`../Shared/OpenClawRuntime.swift`](../Shared/OpenClawRuntime.swift) | bundled runtime 路径和环境变量注入逻辑 |
| [`../EZRWorkerHelper/main.swift`](../EZRWorkerHelper/main.swift) | 理解兼容层还在承担什么 |

## 9. 推荐阅读顺序

如果你是第一次看这套 v2 结构，推荐按下面顺序读：

1. 先看 [`../project.yml`](../project.yml)，确认 target、源码根和嵌入关系
2. 再看 [`../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`](../EZRWorkerApp/EZRWorker/App/AppRootGateView.swift) 和 [`../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`](../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift)，理解 App 外壳
3. 接着看 [`../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`](../EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift) 和 [`../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift`](../EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift)，理解 profile 和旧单实例导入
4. 然后看 [`../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`](../EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift) 和 [`../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift`](../EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift)，理解 App 如何接入 Supervisor
5. 再看 [`../EZRWorkerSupervisor/SupervisorController.swift`](../EZRWorkerSupervisor/SupervisorController.swift)，理解 profile runtime 真正如何被托管
6. 最后回到 [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift)、[`../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift`](../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift)、[`../EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift`](../EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift)，理解当前选中 profile 的业务上下文

只有当你确实需要处理这些问题时，再继续深入：

- 旧多用户窗口和历史交互流程
- root Helper 的系统级实现
- 老的 `GatewayHub` / `ShrimpPool` 兼容模型

## 10. 一句话总结

v2 之后，这个仓库最推荐的阅读姿势不再是“一个 App 连一个 Helper 管一个 Gateway”，而是：

```text
EZRWorker.app 负责当前 profile 的业务上下文
EZRWorkerSupervisor 负责所有 profile 的生命周期
EZRWorkerHelper 负责旧兼容和系统级能力
Shared 负责把三者之间的协议、模型和运行时路径统一起来
```

只要先抓住这条主线，再回头看 `EZRWorkerApp/EZRWorker/`、`EZRWorkerApp/Views/` 和 `.openclaw` 相关兼容点，就不会太容易被当前过渡态结构带偏。
