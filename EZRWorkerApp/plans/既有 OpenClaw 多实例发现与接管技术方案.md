---
name: Existing OpenClaw Multi Instance Discovery and Adoption
overview: 在已经安装过 OpenClaw、且可能存在多个未知目录实例的机器上安装 EZRWorker.app 后，自动发现、确认并接管这些既有实例，让 App/Supervisor 直接托管其生命周期与业务上下文。
todos:
  - id: phase1-discovery-model
    content: "Phase 1: 定义既有 OpenClaw 实例发现模型、风险分级与 Profile 来源类型"
    status: pending
  - id: phase2-scanner
    content: "Phase 2: 实现本机扫描器，覆盖运行中进程、launchd、常见目录、用户手动选择"
    status: pending
  - id: phase3-import-flow
    content: "Phase 3: 改造首启迁移与设置页导入流程，支持批量预览、冲突处理和确认接管"
    status: pending
  - id: phase4-supervisor-adoption
    content: "Phase 4: 强化 Supervisor 对外部复用实例的进程识别、启动、停止与保护逻辑"
    status: pending
  - id: phase5-observability
    content: "Phase 5: 增加接管报告、回滚能力、日志与验收用例"
    status: pending
isProject: false
---

# 既有 OpenClaw 多实例发现与接管技术方案

## 一、背景

现在的 `EZRWorker` 已经具备多 `GatewayProfile` 与全局用户态 `EZRWorkerSupervisor`：

- `GatewayProfileStore` 负责 `profiles.json`、当前 profile 选择、创建 profile、导入固定的 `~/.openclaw`
- `GatewayProfileResolver` 根据 profile 解析 `OPENCLAW_CONFIG_PATH`、`OPENCLAW_STATE_DIR`、workspace、端口
- `EZRWorkerSupervisor` 负责 prepare/start/stop/restart、探活、adopt 已有 gateway
- App 内置 Node.js/OpenClaw runtime，启动 gateway 时会显式注入 profile 环境变量

但当前导入能力只覆盖一个历史目录：

```text
~/.openclaw/openclaw.json
```

用户的新场景是：

- 机器以前已经安装过 OpenClaw
- 机器上可能存在多个 OpenClaw 实例
- 每个实例目录不固定，可能来自不同版本、不同启动脚本、不同 `OPENCLAW_CONFIG_PATH` / `OPENCLAW_STATE_DIR`
- 安装 `EZRWorker.app` 后，希望 App 直接托管这些既有实例，而不是要求用户重新创建或手动搬目录

因此需要新增一条“既有 OpenClaw 多实例发现与接管”链路。

## 二、目标

1. 安装 App 后能发现本机当前用户可访问的多个 OpenClaw 实例。
2. 对每个实例生成可解释的候选项：名称、路径、端口、状态、风险、是否正在运行。
3. 用户确认后，把候选项导入为 `GatewayProfile`，并写入 `profiles.json`。
4. Supervisor 可以直接托管这些 profile：
   - 已在运行的 gateway：优先 adopt，不抢杀。
   - 未运行但配置完整：用 App 内置 runtime 启动。
   - 被旧 launchd/脚本托管的 gateway：提示用户交接，避免双 supervisor。
5. 导入过程不复制、不删除既有数据；只在用户确认“由 EZRWorker 托管”时写入必要 gateway 字段。
6. 保留回滚能力：删除 profile 只删除 EZRWorker 的 profile 记录，不删除外部 OpenClaw 原始目录。

## 三、非目标

- 不迁移或重写 OpenClaw 自身的数据格式。
- 不默认扫描其他 macOS 用户的 Home 目录；当前主线仍是当前登录用户会话。
- 不用 root helper 强行接管系统级 daemon。
- 不把外部 OpenClaw 二进制作为默认 runtime。托管启动统一使用 App 内置 Node/OpenClaw，以保证版本、环境变量和 supervisor 行为一致。
- 不自动停止用户已有的 launchd job、shell 脚本、第三方进程管理器；只能检测并给出交接建议，实际变更需要用户确认。

## 四、核心设计

### 4.1 新增来源类型

当前来源只有：

```swift
enum GatewayProfileSourceKind {
    case managed
    case legacyReuse
}
```

建议扩展为：

```swift
enum GatewayProfileSourceKind: String, Codable, CaseIterable {
    case managed
    case legacyReuse
    case externalReuse
}
```

语义：

| sourceKind | 含义 | 数据目录归属 | 删除 profile 时 |
| --- | --- | --- | --- |
| `managed` | EZRWorker 创建和管理的新 profile | `~/Library/Application Support/EZRWorker/profiles/<slug>/` | 可清理托管目录 |
| `legacyReuse` | 固定复用 `~/.openclaw` | 用户原有目录 | 只删 profile 记录 |
| `externalReuse` | 复用被发现/手动选择的任意 OpenClaw 目录 | 用户原有目录 | 只删 profile 记录 |

`externalReuse` 与 `legacyReuse` 都是“引用外部数据”，区别是：

- `legacyReuse` 是历史兼容固定路径
- `externalReuse` 是新的泛化接管模型

### 4.2 候选实例模型

新增扫描结果模型，不直接等同于 profile：

```swift
struct OpenClawInstanceCandidate: Codable, Identifiable, Hashable {
    var id: UUID
    var displayNameSuggestion: String
    var slugSuggestion: String
    var source: DiscoverySource
    var confidence: DiscoveryConfidence
    var riskLevel: DiscoveryRiskLevel
    var configPath: String
    var stateDir: String
    var workspaceRoot: String?
    var port: Int?
    var pid: Int32?
    var commandLine: String?
    var launchdLabel: String?
    var openClawVersion: String?
    var detectedAt: Date
    var warnings: [String]
}

enum DiscoverySource: String, Codable {
    case runningProcess
    case launchd
    case knownDirectory
    case manualSelection
}

enum DiscoveryConfidence: String, Codable {
    case high
    case medium
    case low
}

enum DiscoveryRiskLevel: String, Codable {
    case safe
    case needsReview
    case blocked
}
```

候选项要保留“发现依据”，这样 UI 可以解释为什么它认为这是一个实例。

## 五、发现策略

发现顺序按可信度从高到低执行，并对候选项去重。

### 5.1 运行中 gateway 进程

使用现有 supervisor 工具思路扩展：

- `ps -axo pid=,command=`
- `lsof -Fn -p <pid>`
- `lsof -tiTCP:<port> -sTCP:LISTEN -nP`

识别条件：

1. command line 同时包含 `openclaw` 与 `gateway`
2. 或进程打开了可识别的 `openclaw.json`
3. 或进程环境/命令行中带有 `OPENCLAW_CONFIG_PATH` / `OPENCLAW_STATE_DIR`

可提取信息：

- pid
- commandLine
- configPath
- stateDir
- port
- 进程是否由 `launchd` 拉起

端口提取优先级：

1. `openclaw.json` 的 `gateway.port`
2. 进程监听端口反查
3. 默认端口 `18789`

### 5.2 launchd 配置

扫描当前用户可读 launchd 配置：

```text
~/Library/LaunchAgents/*.plist
/Library/LaunchAgents/*.plist
```

识别条件：

- `ProgramArguments` 中包含 `openclaw` / `openclaw.mjs` / `gateway`
- `EnvironmentVariables` 中包含 `OPENCLAW_CONFIG_PATH` 或 `OPENCLAW_STATE_DIR`

launchd 候选项风险默认不低于 `needsReview`，因为这意味着已有外部 supervisor。导入后应提示：

- 保持旧 launchd：EZRWorker 只观察/adopt，不建议同时启用 autoStart
- 交给 EZRWorker：需要用户手动或由授权流程停用旧 LaunchAgent

### 5.3 常见目录扫描

在当前用户可访问范围内扫描有限白名单目录，不做全盘递归。

建议候选根：

```text
~/.openclaw
~/Library/Application Support/OpenClaw
~/Library/Application Support/EZRWorker/profiles
~/openclaw
~/OpenClaw
~/Documents/openclaw
~/Projects/openclaw
```

匹配文件：

```text
openclaw.json
**/.openclaw/openclaw.json
**/openclaw.json
```

限制：

- 默认最大深度 4
- 默认最大候选数 100
- 跳过 `node_modules`、`.git`、`Library/Caches`、`Downloads` 中超过阈值的大目录
- App 首启只做轻量扫描；深度扫描放到设置页手动触发

### 5.4 手动选择

设置页新增“导入已有 OpenClaw 目录/配置”：

- 选择 `openclaw.json`
- 或选择包含 `openclaw.json` 的目录
- App 解析后生成 `manualSelection` 候选项

手动选择的候选项 confidence 为 `high`，但仍要做端口、权限、配置合法性检查。

## 六、候选项归一化与去重

同一个实例可能从进程、launchd、目录扫描同时被发现，需要归一化。

唯一键建议按以下优先级生成：

1. 标准化后的 `configPath`
2. 标准化后的 `stateDir`
3. `pid`
4. `port + commandLine fingerprint`

路径标准化规则：

- 展开 `~`
- 解析相对路径为绝对路径
- 使用 `standardizedFileURL.path`
- 去掉尾部 `/`

合并规则：

- 多来源合并为一个候选项
- 保留最高 confidence
- warnings 合并去重
- 若一个来源提供 pid，另一个来源提供 launchdLabel，最终候选项同时展示

## 七、导入为 GatewayProfile

### 7.1 新增 Store API

建议新增：

```swift
func importExternalProfile(
    candidate: OpenClawInstanceCandidate,
    displayName: String?,
    slug: String?,
    autoStart: Bool,
    takeoverMode: ExternalTakeoverMode
) throws -> GatewayProfile

enum ExternalTakeoverMode: String, Codable {
    case observeOnly
    case supervised
}
```

`observeOnly`：

- 写入 profile
- 不主动 stop/start 外部进程
- autoStart 默认 false
- App 可连接、探活、展示状态

`supervised`：

- 写入 profile
- 允许 Supervisor 用 App 内置 runtime 启动/停止该实例
- autoStart 可由用户选择
- 若检测到旧 launchd job，必须先完成交接确认

### 7.2 Profile 字段映射

```swift
GatewayProfile(
    id: UUID(),
    slug: uniqueSlug,
    displayName: displayName,
    autoStart: takeoverMode == .supervised ? userChoice : false,
    sourceKind: .externalReuse,
    configPathOverride: candidate.configPath,
    stateDirOverride: candidate.stateDir,
    workspaceRootOverride: candidate.workspaceRoot ?? inferWorkspaceRoot(candidate),
    portOverride: candidate.port ?? readPort(candidate.configPath),
    createdAt: Date()
)
```

workspace 推导规则：

1. `openclaw.json` 中 agent defaults workspace
2. `stateDir/workspace`
3. `configDir/workspace`
4. 用户在 UI 中手动指定

### 7.3 权限校验

导入前必须检查：

- `configPath` 存在且可读
- `stateDir` 存在或父目录可写
- `workspaceRoot` 存在或父目录可写
- `configPath` 父目录可写；如果不可写，只能 `observeOnly`
- 端口在 `1...65535`
- 与现有 profile 的端口保留区间不冲突

外部目录不可写时，不阻塞“观察”，但阻塞“托管启动”，因为托管启动需要写入 gateway 端口、mode、control UI 等字段。

## 八、Supervisor 接管策略

### 8.1 外部实例不能无条件 adopt

当前 `legacyReuse` 的逻辑偏宽松：

```swift
guard record.profile.sourceKind == .managed else {
    return .adopt(listeningPID)
}
```

新增 `externalReuse` 后需要收紧：

- 只有端口上的进程看起来像 OpenClaw gateway 才能 adopt
- 若有 pid，必须满足任一条件：
  - 进程打开了该 profile 的 `configPath`
  - 进程打开了该 profile 的 `stateDir` 下文件
  - command line / environment 明确包含该 config/state 路径
- 否则标记 failed：端口被其他进程占用，不能接管

### 8.2 observeOnly 与 supervised 的行为差异

如果只在 `GatewayProfile` 中加 `sourceKind` 不足以表达托管模式，建议增加：

```swift
enum GatewayProfileManagementMode: String, Codable {
    case managedByEZRWorker
    case observeOnly
}
```

短期也可以用 `autoStart = false + sourceKind = externalReuse` 表达观察模式，但长期建议显式建模。

行为：

| 操作 | observeOnly | supervised |
| --- | --- | --- |
| 探活 | 允许 | 允许 |
| 连接 Gateway | 允许 | 允许 |
| prepare | 只校验，不写配置 | 可写入必要字段 |
| start | 禁止，提示切换为托管模式 | 允许 |
| stop | 禁止，除非明确确认 | 允许 |
| restart | 禁止，除非明确确认 | 允许 |
| autoStart | 强制 false | 可开启 |

### 8.3 配置写入策略

`normalizeConfig(for:)` 目前会对所有 profile 写入：

- `gateway.port`
- `gateway.mode = local`
- `gateway.controlUi.allowInsecureAuth = true`

对 `externalReuse` 建议拆分为两步：

1. `validateExternalConfig(for:)`
   - 只读解析
   - 检查端口、workspace、credentials
   - 生成 warnings

2. `normalizeConfig(for:)`
   - 仅在 `managed` 或 `externalReuse + supervised` 时执行
   - 执行前做备份：

```text
openclaw.json.ezrworker-backup-YYYYMMDD-HHMMSS
```

这样可避免安装 App 后在用户未确认时静默修改外部配置。

## 九、首启体验

### 9.1 启动分流

`GatewayProfileStore.reloadFromDiskOrBootstrap()` 建议改为：

1. 如果已有 `profiles.json`：直接加载。
2. 如果没有 `profiles.json`：
   - 运行轻量发现。
   - 如果发现多个候选项：进入 `ExistingOpenClawImportView`。
   - 如果只发现 `~/.openclaw`：仍可复用现有 `ProfileMigrationChoiceView`，也可以统一到新导入页。
   - 如果没有发现候选项：创建默认 managed profile。

### 9.2 批量导入页

新增 UI：`ExistingOpenClawImportView`

页面能力：

- 展示候选实例列表
- 每项展示：
  - 名称建议
  - config/state/workspace
  - 端口
  - 是否运行中
  - 发现来源
  - 风险提示
- 用户勾选要导入的实例
- 每项选择接管模式：
  - 仅观察
  - 交给 EZRWorker 托管
- 冲突项要求用户处理：
  - 修改端口
  - 跳过
  - 仅观察
- 完成后写入 `profiles.json`，并调用 `SupervisorClient.reloadProfiles()`

默认建议：

- 运行中且被旧 launchd 管理：仅观察
- 运行中但没有外部 supervisor：交给 EZRWorker 托管，可 autoStart
- 未运行但配置完整：交给 EZRWorker 托管，可 autoStart
- 路径不可写：仅观察

## 十、设置页后续管理

`AppSettingsView` 的 Profiles 区域新增：

- “扫描已有 OpenClaw”
- “导入配置文件”
- “接管模式”标识
- “切换为 EZRWorker 托管”
- “放弃托管，仅保留记录”

删除文案区分：

- managed：删除 profile 并清理 App Support 托管数据
- legacyReuse/externalReuse：只删除 EZRWorker profile 记录，不删除原始 OpenClaw 数据

## 十一、冲突与风险处理

### 11.1 端口冲突

分三类：

1. 候选项之间端口冲突
2. 候选项与已有 profile 端口冲突
3. 端口被非 OpenClaw 进程占用

处理：

- 已运行实例：不自动改端口，优先 observeOnly
- 未运行实例：允许用户在导入前指定新端口
- 非 OpenClaw 占用：禁止 supervised start

### 11.2 版本差异

托管启动统一使用 App 内置 OpenClaw。外部目录可能来自旧版 OpenClaw。

策略：

- 导入时读取候选版本，仅展示与记录
- prepare 时做配置兼容检查
- 首次 supervised 启动前提示“将使用 EZRWorker 内置 OpenClaw 运行该配置”
- 如果 OpenClaw 后续有迁移命令，应在 prepare 阶段显式运行并备份

### 11.3 外部 supervisor 冲突

检测到 launchd/system job 时：

- 默认 observeOnly
- 如果用户选择 supervised，必须显示交接确认
- 交接动作需要独立授权，不在普通导入过程中偷偷执行

### 11.4 配置写入回滚

任何写外部 `openclaw.json` 的动作都必须：

1. 写前备份
2. 原子写入
3. 写后解析校验
4. 失败时恢复备份

## 十二、实施拆分

### Phase 1: 模型与文档边界

- 新增 `externalReuse`
- 新增候选实例模型
- 明确 `observeOnly` / `supervised` 管理模式
- 更新删除/prepare/start/stop 的语义

涉及文件：

- `Shared/GatewayProfiles.swift`
- `EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`
- `EZRWorkerSupervisor/SupervisorRecord.swift`

### Phase 2: 本机扫描器

新增服务：

```text
EZRWorkerApp/EZRWorker/Services/OpenClawInstanceDiscoveryService.swift
```

职责：

- 运行中进程扫描
- launchd plist 扫描
- 常见目录扫描
- 手动选择归一化
- 候选项去重和风险评级

### Phase 3: 导入流程

- 新增 `ExistingOpenClawImportView`
- 首启从 `ProfileMigrationChoiceView` 扩展为多实例导入
- 设置页新增“扫描已有 OpenClaw / 导入配置文件”
- `GatewayProfileStore` 新增 `importExternalProfile`

### Phase 4: Supervisor 强化

- `existingGatewayDisposition` 支持 `externalReuse` 严格校验
- `healthyGatewayDisposition` 支持 `externalReuse` 严格校验
- `prepareProfile` 区分 validate-only 与 normalize
- `stopProfile` 对 observeOnly 默认禁止
- 运行态 snapshot 增加更清晰的 ownership/management mode 文案

涉及文件：

- `EZRWorkerSupervisor/SupervisorController+GatewayProcess.swift`
- `EZRWorkerSupervisor/SupervisorController+Lifecycle.swift`
- `EZRWorkerSupervisor/SupervisorController+Readiness.swift`
- `EZRWorkerSupervisor/SupervisorController+Config.swift`

### Phase 5: 验收与回滚

增加测试与手动验收脚本：

- 单个 `~/.openclaw` 仍可导入
- 多个任意目录 `openclaw.json` 可被扫描
- 运行中 gateway 可 adopt
- 非 OpenClaw 端口占用不会被误接管
- 外部 launchd 托管实例默认 observeOnly
- 删除 externalReuse profile 不删除原始目录
- supervised 写配置失败可恢复备份

## 十三、验收标准

1. 全新机器无 OpenClaw：仍自动创建默认 managed profile。
2. 只有旧 `~/.openclaw`：用户可以一键复用，行为不倒退。
3. 多个目录：

```text
~/work/a/openclaw.json
~/work/b/.openclaw/openclaw.json
~/Library/Application Support/OpenClaw/foo/openclaw.json
```

App 能展示多个候选项，并允许分别导入。

4. 已运行 gateway：导入后 profile 卡片显示 `adopted`，App 可以连接业务通道。
5. 端口冲突：导入页明确提示，不会 silent 覆盖。
6. 切换 profile 后，Channel/Agent/Workspace 仍严格走当前 profile 的 resolved paths。
7. 删除 externalReuse profile 后，原始 `openclaw.json`、state、workspace 文件仍存在。

## 十四、建议的最小可交付版本

第一版不必做全量深度扫描，可以先交付：

1. 运行中 gateway 扫描
2. `~/.openclaw` + 用户手动选择任意 `openclaw.json`
3. 导入为 `externalReuse`
4. 默认 observeOnly
5. 用户手动切换为 supervised 后，Supervisor 才允许 start/stop/restart

这样能覆盖“安装 App 后接管当前正在跑的多个 OpenClaw”和“目录不固定但用户知道位置”的核心需求，同时把误扫、误改、误杀风险压到最低。
