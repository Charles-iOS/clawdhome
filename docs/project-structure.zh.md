# EZRWorker 项目结构说明

本文只保留当前开发和维护真正需要关注的目录与文件，用来帮助快速理解这个仓库。构建产物、发布草稿、截图资源和内部计划类内容不在这里展开。

## 1. 项目定位

EZRWorker 现在的主要目标，是作为一个面向 macOS 的本地控制平面，管理当前用户正在运行的 OpenClaw gateway 实例，并围绕这个 gateway 创建、配置和维护多个 agent。它不是单一进程应用，而是由下面三部分共同组成：

- `EZRWorker` target：SwiftUI 管理应用，`project.yml` 里定义的产品名是 `EZRWorker`
- `EZRWorkerHelper` target：以 root 权限运行的特权 Helper / LaunchDaemon
- `Shared`：App 与 Helper 共用的 XPC 协议、数据模型和状态对象

运行时可以把它理解成：

```text
操作员
  -> EZRWorker.app / EZRWorker（SwiftUI）
      -> HelperClient（NSXPC）
          -> EZRWorkerHelper（root LaunchDaemon）
              -> Gateway 管理 / 文件与进程操作 / 必要的系统级能力
                  -> 当前用户下运行的 OpenClaw gateway
                      -> 该 gateway 下的多个 agent
```

当前主入口已经切到 `EZRWorkerApp/EZRWorker/` 这套以单 gateway、多 agent 为中心的新结构，但 `EZRWorkerApp/Views/` 里仍保留了一部分早期多用户管理时期的页面和辅助窗口，所以这个仓库目前属于“新主框架 + 存量旧模块并存”的状态。

## 2. 启动链路

如果你第一次接手这个项目，先理解启动链路会比先翻所有页面更有效：

1. `EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`
2. 环境检查与 Gateway 启动：`EnvironmentChecker`、`GatewayProcessManager`
3. Gateway 连接：`GatewayService`
4. Helper 连接：`HelperClient`
5. 智能体数据加载：`AgentStore`

这条链路基本决定了 App 启动后如何连上 gateway、如何连上 helper，以及界面里的 agent、技能、渠道等数据从哪里来。

## 3. 精简后的目录结构

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
    Views/
    Resources/
  Views/
  Localization/
  Stable.xcstrings
  Info.plist

EZRWorkerHelper/
  main.swift
  Operations/

Shared/
Resources/
scripts/
tests/
docs/
```

### 顶层文件

- [`../project.yml`](../project.yml)：XcodeGen 配置，是理解 target、依赖、脚本和构建方式的第一入口
- [`../Makefile`](../Makefile)：本地开发、打包、安装 Helper、i18n 检查等常用命令入口
- [`../README.zh.md`](../README.zh.md)：产品定位、快速开始、常用命令和基础架构说明

### `EZRWorkerApp/`

- `EZRWorker/App/`
  - 当前主应用入口与主导航壳层
  - 重点文件：
    - [`../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`](../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift)
    - [`../EZRWorkerApp/EZRWorker/App/MainView.swift`](../EZRWorkerApp/EZRWorker/App/MainView.swift)
    - [`../EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift`](../EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift)
- `EZRWorker/Models/`
  - agent、绑定、渠道、模型状态、密钥配置等核心模型
  - 重点文件：
    - [`../EZRWorkerApp/EZRWorker/Models/Agent.swift`](../EZRWorkerApp/EZRWorker/Models/Agent.swift)
    - [`../EZRWorkerApp/EZRWorker/Models/AgentBinding.swift`](../EZRWorkerApp/EZRWorker/Models/AgentBinding.swift)
    - [`../EZRWorkerApp/EZRWorker/Models/ChannelType.swift`](../EZRWorkerApp/EZRWorker/Models/ChannelType.swift)
- `EZRWorker/Services/`
  - 新架构的应用服务层，负责 Gateway、XPC、工作区、更新、环境检查、Provider Key 等
  - 重点文件：
    - [`../EZRWorkerApp/EZRWorker/Services/HelperClient.swift`](../EZRWorkerApp/EZRWorker/Services/HelperClient.swift)
    - [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift)
    - [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift)
    - [`../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift`](../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift)
    - [`../EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift`](../EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift)
- `EZRWorker/Views/`
  - 新主界面的页面实现
  - 子目录可以按业务理解：
    - `Views/Agent/`：agent 列表、详情、工作区、创建向导
    - `Views/Capabilities/`：技能、渠道、定时任务、Provider 配置
    - `Views/Settings/`：新设置页
- `EZRWorker/Resources/`
  - 新架构相关内置资源，例如预置智能体模板与 onboard/roles HTML
- `Views/`
  - 历史阶段留下的旧功能页与辅助窗口，部分仍被详情窗口、初始化向导、备份、克隆等流程复用
  - 这部分不是当前主导航壳层，且不少能力带有早期多用户管理背景，阅读时要和现有产品定位区分开
  - 重点文件：
    - [`../EZRWorkerApp/Views/UserDetailView.swift`](../EZRWorkerApp/Views/UserDetailView.swift)
    - [`../EZRWorkerApp/Views/UserInitWizardView.swift`](../EZRWorkerApp/Views/UserInitWizardView.swift)
    - [`../EZRWorkerApp/Views/CloneClawSheet.swift`](../EZRWorkerApp/Views/CloneClawSheet.swift)
    - [`../EZRWorkerApp/Views/ModelManager/ModelManagerView.swift`](../EZRWorkerApp/Views/ModelManager/ModelManagerView.swift)
- `Localization/`
  - 语言切换与本地化访问封装
  - 重点文件：
    - [`../EZRWorkerApp/Localization/L10n.swift`](../EZRWorkerApp/Localization/L10n.swift)
    - [`../EZRWorkerApp/Localization/AppLanguage.swift`](../EZRWorkerApp/Localization/AppLanguage.swift)
- `Stable.xcstrings`
  - 中英文字符串总表，整个仓库的 UI 文案应优先走这里
- `Info.plist`
  - App 基础信息与版本号来源

### `EZRWorkerHelper/`

- [`../EZRWorkerHelper/main.swift`](../EZRWorkerHelper/main.swift)
  - Helper 主入口
  - 负责 XPC listener、调用方校验、日志、状态维护和协议实现
- `Operations/`
  - 真正执行系统级操作的地方，基本都要求 root 权限
  - 重点文件：
    - [`../EZRWorkerHelper/Operations/UserManager.swift`](../EZRWorkerHelper/Operations/UserManager.swift)：创建/删除 macOS 用户、目录和群组清理
    - [`../EZRWorkerHelper/Operations/GatewayManager.swift`](../EZRWorkerHelper/Operations/GatewayManager.swift)：为每个用户安装、启动、停止 gateway
    - [`../EZRWorkerHelper/Operations/UserFileManager.swift`](../EZRWorkerHelper/Operations/UserFileManager.swift)：文件读写、目录管理、归档解压
    - [`../EZRWorkerHelper/Operations/ProcessManager.swift`](../EZRWorkerHelper/Operations/ProcessManager.swift)：进程列表、详情和 kill
    - [`../EZRWorkerHelper/Operations/InstallManager.swift`](../EZRWorkerHelper/Operations/InstallManager.swift)：Node/OpenClaw 等安装能力
    - [`../EZRWorkerHelper/Operations/DashboardCollector.swift`](../EZRWorkerHelper/Operations/DashboardCollector.swift)：仪表盘快照采集

### `Shared/`

- App 与 Helper 共享的数据结构与协议定义
- 这里是理解“前台怎么调用后端”的核心层
- 重点文件：
  - [`../Shared/HelperProtocol.swift`](../Shared/HelperProtocol.swift)：完整 XPC 接口定义
  - [`../Shared/AppUpdateState.swift`](../Shared/AppUpdateState.swift)
  - [`../Shared/DashboardModels.swift`](../Shared/DashboardModels.swift)
  - [`../Shared/FileModels.swift`](../Shared/FileModels.swift)
  - [`../Shared/ProcessModels.swift`](../Shared/ProcessModels.swift)

### `Resources/`

- 放 Helper 的 LaunchDaemon plist 这类运行时资源
- 重点文件：
  - [`../Resources/ai.ezrworker.mac.helper.plist`](../Resources/ai.ezrworker.mac.helper.plist)

### `scripts/`

- 构建、打包、版本、发布、本地化检查、安装 Helper 等脚本集合
- 常看文件：
  - [`../scripts/install-helper-dev.sh`](../scripts/install-helper-dev.sh)
  - [`../scripts/build-pkg.sh`](../scripts/build-pkg.sh)
  - [`../scripts/bundle-runtime.sh`](../scripts/bundle-runtime.sh)
  - [`../scripts/i18n_ci_check.py`](../scripts/i18n_ci_check.py)

### `tests/`

- 当前测试规模还比较小，主要覆盖状态对象与初始化展示路由
- 现有测试文件：
  - [`../tests/AppUpdateStateTests.swift`](../tests/AppUpdateStateTests.swift)
  - [`../tests/UpdateCheckPolicyTests.swift`](../tests/UpdateCheckPolicyTests.swift)
  - [`../tests/UserInitPresentationRoutingTests.swift`](../tests/UserInitPresentationRoutingTests.swift)

### `docs/`

- 项目内的说明文档目录
- 目前最值得看的文档：
  - [`XPC-SPEC.md`](./XPC-SPEC.md)
  - [`i18n.md`](./i18n.md)
  - [`project-structure.zh.md`](./project-structure.zh.md)

## 4. 关键入口文件清单

如果你不想一上来就把整个仓库翻完，下面这组文件最值得先读：

| 文件 | 作用 |
| --- | --- |
| [`../project.yml`](../project.yml) | 定义两个 target、依赖、脚本和打包方式 |
| [`../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`](../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift) | App 真正启动入口，负责 bootstrap |
| [`../EZRWorkerApp/EZRWorker/App/MainView.swift`](../EZRWorkerApp/EZRWorker/App/MainView.swift) | 当前主界面壳层 |
| [`../EZRWorkerApp/EZRWorker/Services/HelperClient.swift`](../EZRWorkerApp/EZRWorker/Services/HelperClient.swift) | App 侧 XPC 客户端封装 |
| [`../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift`](../EZRWorkerApp/EZRWorker/Services/Gateway/GatewayService.swift) | App 侧 Gateway 连接与配置访问 |
| [`../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift`](../EZRWorkerApp/EZRWorker/Services/Stores/AgentStore.swift) | agent 列表、绑定和工作区状态的主数据源 |
| [`../Shared/HelperProtocol.swift`](../Shared/HelperProtocol.swift) | App/Helper 协议边界 |
| [`../EZRWorkerHelper/main.swift`](../EZRWorkerHelper/main.swift) | Helper 主入口与 XPC 服务实现 |
| [`../EZRWorkerHelper/Operations/UserManager.swift`](../EZRWorkerHelper/Operations/UserManager.swift) | macOS 用户生命周期管理 |
| [`../EZRWorkerHelper/Operations/GatewayManager.swift`](../EZRWorkerHelper/Operations/GatewayManager.swift) | gateway 生命周期管理与启动收敛逻辑 |

## 5. 现在这套结构应该怎么理解

这套代码目前可以按“4 层”理解：

1. 界面层：`EZRWorkerApp/EZRWorker/Views` 和部分 `EZRWorkerApp/Views`
2. 应用服务层：`EZRWorkerApp/EZRWorker/Services`
3. 协议与共享模型层：`Shared`
4. 系统操作层：`EZRWorkerHelper/Operations`

其中最容易混淆的一点是：

- 当前主窗口导航在 `EZRWorker/App/MainView.swift`
- 但用户详情、初始化向导、克隆等窗口仍会复用 `EZRWorkerApp/Views/` 下的旧页面
- 所以 `EZRWorkerApp/Views/` 不能简单视为废弃目录，但也不能把它当成当前产品主模型的唯一依据

再直白一点说：

- 当前产品主线是“当前用户的 gateway + 多 agent 管理”
- 多用户隔离、用户生命周期管理、旧虾塘式页面更多是历史遗留能力或兼容性模块
- 看代码时应优先以 `EZRWorker/App`、`EZRWorker/Services`、`EZRWorker/Views/Agent` 这条主线理解项目

## 6. 开发说明

### 本地打开项目

如果已经有工程文件，直接：

```bash
open EZRWorker.xcodeproj
```

如果你修改了 [`../project.yml`](../project.yml)，建议先重新生成工程：

```bash
xcodegen generate
open EZRWorker.xcodeproj
```

### 常用命令

```bash
make build
make build-helper
make install-helper
make i18n-check
make clean
```

补充说明：

- `make install-helper` 会把 Helper 安装到系统里，调试 root 侧能力时很常用
- 打包、签名、公证相关流程主要看 [`../Makefile`](../Makefile) 和 `scripts/`
- 当前构建配置来自 `project.yml`，不要只改 `.xcodeproj` 而忘了同步源配置

### 阅读顺序建议

推荐按下面的顺序读代码：

1. [`../README.zh.md`](../README.zh.md)
2. [`../project.yml`](../project.yml)
3. [`../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`](../EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift)
4. [`../EZRWorkerApp/EZRWorker/Services/HelperClient.swift`](../EZRWorkerApp/EZRWorker/Services/HelperClient.swift)
5. [`../Shared/HelperProtocol.swift`](../Shared/HelperProtocol.swift)
6. [`../EZRWorkerHelper/main.swift`](../EZRWorkerHelper/main.swift)
7. `AgentStore` / `GatewayService` / `GatewayManager` 这三条主线

## 7. 相关说明文档索引

- 产品与开发总览：[`../README.zh.md`](../README.zh.md)
- 英文版说明：[`../README.md`](../README.md)
- XPC 设计与协议分析：[`XPC-SPEC.md`](./XPC-SPEC.md)
- 本地化规范：[`i18n.md`](./i18n.md)

如果你只是想尽快上手改代码，优先看第 4 节和第 6 节；如果你要改 Helper、权限边界或文件/进程操作，再深入看 `Shared/HelperProtocol.swift` 和 `docs/XPC-SPEC.md`。
