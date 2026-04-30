---
name: Gateway Profile Runtime Source Visibility
overview: 为 Gateway/Profile 增加 runtime 来源展示能力，区分 App 接管前既有 Gateway 自带 runtime、EZRWorker 计划 runtime、以及当前进程实际 runtime，避免用户误以为导入或接管后已经完成 runtime 切换。
todos:
  - id: phase1-runtime-descriptor
    content: "Phase 1: 新增 runtime 描述模型，暴露 EZRWorker 计划 runtime 的来源、路径和版本"
    status: pending
  - id: phase2-process-runtime-detection
    content: "Phase 2: 在 Supervisor/Discovery 中识别运行中 Gateway 进程实际使用的 runtime"
    status: pending
  - id: phase3-snapshot-candidate-fields
    content: "Phase 3: 扩展 SupervisorProfileRuntime 和 OpenClawInstanceCandidate，透传 planned/active runtime"
    status: pending
  - id: phase4-ui-display
    content: "Phase 4: 设置页 Profile 卡片、导入页、Profile 终端展示 runtime 来源与差异提示"
    status: pending
  - id: phase5-tests-acceptance
    content: "Phase 5: 补齐 Codable 兼容、进程解析和手动接管场景验收"
    status: pending
isProject: false
---

# Gateway/Profile Runtime 来源展示技术方案

## 一、结论

需要把 profile 的 runtime 展示拆成两个概念：

1. **计划 runtime**：如果由 EZRWorker 启动或重启 Gateway，会使用哪里的 Node/OpenClaw。当前主线对应 `OpenClawRuntime`，通常是 App bundle `Contents/Resources`，Debug 下可能是 `build/dev-runtime`，也可能被 `EZRWORKER_DEV_RUNTIME_DIR` 或 `CLAWDHOME_DEV_RUNTIME_DIR` 覆盖。
2. **当前进程 runtime**：现在端口上那个 Gateway 进程实际是从哪里启动的。App 接管前，它可能来自旧全局 npm、旧 LaunchAgent、外部 Node、另一个 App bundle 或用户自己启动的 openclaw。

UI 必须同时展示这两件事，尤其是在 `legacyReuse`、`externalReuse`、`adopted` 这几类状态下，不能只显示“托管/运行中”，否则用户会误以为 Gateway 已经切到了 App 内置 runtime。

推荐用户文案：

```text
Runtime：当前 旧全局 npm / 接管后 App 内置
```

或者：

```text
当前 Gateway 使用旧 runtime；重启后将切换到 EZRWorker 内置 runtime。
```

## 二、背景

当前代码里 runtime 相关信息已经存在，但没有作为 profile 状态展示出来：

- `Shared/OpenClawRuntime.swift`
  - 决定 EZRWorker 启动 Gateway/CLI 时使用的 Node、OpenClaw entry、npx、PATH。
  - runtime 解析优先级是 env override、Debug `build/dev-runtime`、App bundle resources。
- `Shared/GatewayProfiles.swift`
  - `GatewayProfileResolution` 只表达 config/state/workspace/port，不表达 runtime。
  - `SupervisorProfileRuntime` 只表达 profile 路径、端口、pid、health、ownership，不表达 runtime。
- `EZRWorkerSupervisor/SupervisorController+Lifecycle.swift`
  - `managedByEZRWorker` 启动时使用 `OpenClawRuntime.bundledNodeURL` + `OpenClawRuntime.bundledOpenClawEntry`。
- `EZRWorkerSupervisor/SupervisorController+GatewayProcess.swift`
  - 已经会用 `ps`/`lsof` 判断进程是否是 Gateway，以及是否匹配当前 profile 的 config/state。
  - 但目前只判断“是不是这个 profile 的 Gateway”，没有解析“这个 Gateway 是从哪个 runtime 启动的”。
- `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`
  - Profile 卡片已展示端口、配置、PID、探测、运行态。
  - 还没有展示 `runtime root/node/openclaw/version`。
- `EZRWorkerApp/EZRWorker/Views/ExistingOpenClawImportView.swift`
  - 导入候选会展示 config/state/workspace/LaunchAgent，但没有展示候选 Gateway 当前 runtime。

这导致一个产品语义缺口：

```text
Profile 被 App 接入/托管了
!=
当前 Gateway 进程已经使用 App runtime
```

尤其是 App 接管前已有 Gateway 正在运行时，Supervisor 可能先 `adopt` 这个健康进程。此时 profile 已经可用，但 active runtime 仍然是旧 runtime。只有 App 重启该 Gateway 后，active runtime 才会切换到 planned runtime。

## 三、目标

1. 设置页每个 Profile 都能看出：
   - 当前运行进程使用哪里的 runtime。
   - 如果由 EZRWorker 启动/重启，将使用哪里的 runtime。
   - 两者是否一致。
2. 导入已有 OpenClaw 时，候选项展示：
   - 运行中进程 runtime。
   - LaunchAgent/命令行推断出的 runtime。
   - 导入为托管后计划使用的 EZRWorker runtime。
3. `legacyReuse` / `externalReuse` / `managed adopted` 状态下，不把“adopted 进程”误写成“App 内置 runtime”。
4. 不改变现有生命周期策略；本方案只增加可观测性和解释性。
5. Codable 兼容旧 runtime snapshot，老 Supervisor/新 App 或新 Supervisor/老 App 不应因为缺字段崩溃。

## 四、非目标

- 不在本轮自动迁移外部 OpenClaw 安装。
- 不因为 runtime 不一致自动 kill/restart 用户进程。
- 不读取或展示 token、secret、完整环境变量。
- 不要求用户卸载全局 npm openclaw。
- 不把 `observeOnly` 变成托管。

## 五、核心语义

### 5.1 Runtime 状态矩阵

| Profile 类型 | managementMode | ownership | planned runtime | active runtime |
| --- | --- | --- | --- | --- |
| managed | managedByEZRWorker | supervised | EZRWorker runtime | EZRWorker runtime |
| managed | managedByEZRWorker | adopted | EZRWorker runtime | 端口上已有进程 runtime |
| legacyReuse | managedByEZRWorker | supervised | EZRWorker runtime | EZRWorker runtime |
| legacyReuse | managedByEZRWorker | adopted | EZRWorker runtime | 旧 `~/.openclaw` Gateway runtime |
| externalReuse | observeOnly | adopted/none | 不适用或外部 runtime | 外部进程 runtime |
| externalReuse | managedByEZRWorker | supervised | EZRWorker runtime | EZRWorker runtime |
| externalReuse | managedByEZRWorker | adopted | EZRWorker runtime | 接管前外部进程 runtime |

展示规则：

- `activeRuntime == nil`：显示“未运行；启动后使用 <plannedRuntime>”。
- `activeRuntime == plannedRuntime`：显示“App 内置 / Dev Runtime / 自定义 Runtime”。
- `activeRuntime != plannedRuntime` 且 profile 可托管：显示“当前 <active>；重启后 <planned>”。
- `observeOnly`：显示“外部管理：<active>”，不要显示“重启后切换”。

### 5.2 接管状态不是 runtime 状态

现有 `ownership` 表示生命周期归属：

- `supervised`：当前进程由 EZRWorkerSupervisor 启动。
- `adopted`：当前进程由 Supervisor 识别并接入，但不是这次由 Supervisor 创建。
- `none`：当前没有可用进程。

runtime 展示要建立在这个基础上：

```text
supervised 通常可以认为 active runtime = planned runtime。
adopted 必须从 pid/commandLine/lsof/LaunchAgent 重新识别 active runtime。
```

## 六、数据模型设计

### 6.1 新增 runtime 描述模型

建议放在 `Shared/OpenClawRuntime.swift` 或 `Shared/GatewayProfiles.swift`，App 和 Supervisor 都要能 Codable。

```swift
enum OpenClawRuntimeSourceKind: String, Codable, CaseIterable {
    case ezrWorkerBundle
    case devRuntime
    case environmentOverride
    case userGlobalNpm
    case externalNode
    case launchAgent
    case unknown
}

enum OpenClawRuntimeDetectionKind: String, Codable, CaseIterable {
    case plannedByEZRWorker
    case supervisedProcess
    case processCommandLine
    case processOpenFiles
    case launchAgentPlist
    case discoveryCandidate
    case unknown
}

struct OpenClawRuntimeDescriptor: Codable, Hashable {
    var sourceKind: OpenClawRuntimeSourceKind
    var detectionKind: OpenClawRuntimeDetectionKind
    var displayName: String
    var runtimeRootPath: String?
    var nodePath: String?
    var openClawEntryPath: String?
    var openClawBinaryPath: String?
    var openClawVersion: String?
    var nodeVersion: String?
    var commandSummary: String?
    var isManagedByEZRWorker: Bool
}
```

字段说明：

- `displayName` 用于 UI：`App 内置`、`Dev Runtime`、`自定义 Runtime`、`旧全局 npm`、`外部 Node`。
- `runtimeRootPath` 用于路径展示和比较。
- `nodePath` / `openClawEntryPath` 用于诊断。
- `openClawVersion` 读取 `package.json`；无法读取则为 nil。
- `nodeVersion` 第一阶段可以为空，避免每次刷新 runtime 都启动 node 子进程。
- `commandSummary` 必须脱敏，只保留命令入口和关键路径，不展示 env 全量内容。

### 6.2 扩展 OpenClawRuntime

当前 `runtimeRootURL` 是 private。需要新增公开描述接口，而不是让 UI 自己重复解析路径：

```swift
extension OpenClawRuntime {
    static var plannedRuntimeDescriptor: OpenClawRuntimeDescriptor { get }
}
```

内部解析时顺便记录来源：

| 来源 | sourceKind | displayName |
| --- | --- | --- |
| `EZRWORKER_DEV_RUNTIME_DIR` / `CLAWDHOME_DEV_RUNTIME_DIR` | `environmentOverride` | `自定义 Runtime` |
| Debug repo `build/dev-runtime` | `devRuntime` | `Dev Runtime` |
| App bundle `Contents/Resources` | `ezrWorkerBundle` | `App 内置` |
| fallback 到 bundleURL 但缺 Node/OpenClaw | `unknown` | `未知 Runtime` |

### 6.3 扩展 SupervisorProfileRuntime

给 snapshot 增加两个 optional 字段，保持旧 JSON 兼容：

```swift
struct SupervisorProfileRuntime: Codable, Identifiable, Equatable {
    var plannedRuntime: OpenClawRuntimeDescriptor?
    var activeRuntime: OpenClawRuntimeDescriptor?
    var runtimeMismatchReason: String?
}
```

兼容策略：

- 解码缺字段时为 nil。
- `snapshot()` 默认填入 `plannedRuntime = OpenClawRuntime.plannedRuntimeDescriptor`。
- `activeRuntime` 只有确认到 pid 或 supervised process 时填写。
- 老 App 收到新字段会忽略；新 App 收到老字段显示“Runtime 未同步”。

### 6.4 扩展 OpenClawInstanceCandidate

导入页需要展示 App 接管前候选自带 runtime：

```swift
struct OpenClawInstanceCandidate {
    var activeRuntime: OpenClawRuntimeDescriptor?
    var launchAgentRuntime: OpenClawRuntimeDescriptor?
}
```

来源优先级：

1. 运行中 pid 的 command line / open files。
2. LaunchAgent `ProgramArguments` 和 `EnvironmentVariables`。
3. config/state 目录只能说明 profile 数据位置，不能说明 runtime；不要用 config 路径假装 runtime。

## 七、Runtime 识别策略

### 7.1 EZRWorker planned runtime

由 `OpenClawRuntime` 自己返回，最可靠：

```text
nodePath = OpenClawRuntime.bundledNodeURL.path
openClawEntryPath = OpenClawRuntime.bundledOpenClawEntry.path
openClawVersion = OpenClawRuntime.bundledOpenClawVersion
```

这表示“如果现在由 App 启动，会用这个 runtime”。

### 7.2 supervised process

当 `record.process?.isRunning == true` 且 pid 匹配监听端口：

```text
activeRuntime = plannedRuntime
detectionKind = supervisedProcess
```

同时仍可用 `ps` 做一次轻量校验，若发现命令行不含 planned node/entry，记录 `runtimeMismatchReason`，但不要影响健康状态。

### 7.3 adopted process

对 `ownership == adopted` 或刷新时发现端口上已有 Gateway：

1. 用现有 `processCommandLine(pid:)` 读取命令行。
2. 用现有 `gatewayProcessOpenFileNames(pid:)` 读取打开文件。
3. 按以下规则归类：

| 识别依据 | sourceKind | 示例 |
| --- | --- | --- |
| 命令行/打开文件包含 planned node 或 planned openclaw entry | `ezrWorkerBundle` / `devRuntime` / `environmentOverride` | `/Applications/EZRWorker.app/.../node/bin/node .../openclaw.mjs gateway` |
| 命令行包含 `~/.npm-global/bin/openclaw` | `userGlobalNpm` | `/Users/a/.npm-global/bin/openclaw gateway` |
| 命令行包含 `openclaw/lib/node_modules/openclaw/openclaw.mjs` 但 root 不等于 planned root | `externalNode` | `/usr/local/bin/node /opt/openclaw/.../openclaw.mjs gateway` |
| LaunchAgent ProgramArguments 指向 openclaw/node | `launchAgent` 或更具体分类 | `~/Library/LaunchAgents/com.openclaw.gateway.plist` |
| 只能确认是 Gateway，不能确认 runtime | `unknown` | `openclaw gateway` |

### 7.4 LaunchAgent 候选

发现阶段已有 `OpenClawLaunchAgentInfo.programArguments` 和 `environment`。新增解析：

- `ProgramArguments[0]` 是 node：尝试找到后续 `openclaw.mjs`。
- `ProgramArguments[0]` 是 openclaw wrapper：记录 `openClawBinaryPath`。
- `EnvironmentVariables.PATH` 只作为弱线索，不展示全量 PATH。
- 如果 plist 中有 `OPENCLAW_CONFIG_PATH` / `OPENCLAW_STATE_DIR`，继续用于匹配 profile，不作为 runtime。

## 八、UI 设计

### 8.1 设置页 Profile 卡片

当前卡片已有：

```text
端口 / 配置 / PID / 探测
Config / Workspace
运行态状态条
```

建议新增或替换为：

```text
端口 / Runtime / PID / 探测
Config / State / Workspace
```

卡片展示示例：

```text
Runtime  App 内置 1.2.3
```

runtime 不一致时：

```text
Runtime  当前旧全局 npm
状态条   当前 Gateway 使用旧 runtime；重启后将切换到 App 内置 1.2.3。
```

observeOnly：

```text
Runtime  外部 Node
状态条   仅观察：Gateway 由外部启动链路管理。
```

未运行：

```text
Runtime  App 内置 1.2.3
状态条   Gateway 未运行；启动后使用 App 内置 runtime。
```

交互建议：

- runtime 文本支持 hover/help，展示 node path、openclaw entry path、runtime root。
- 不在卡片正文展示超长 path，避免挤压现有操作按钮。
- 如需详细诊断，后续可加“复制诊断信息”。

### 8.2 导入已有 OpenClaw 页面

在 `ExistingOpenClawImportView` 的候选项里增加：

```text
Runtime：旧全局 npm / 外部 Node / 未知
接管后：App 内置 1.2.3
```

当用户选择“托管”且候选正在运行旧 runtime：

```text
当前运行的 Gateway 使用旧 runtime。导入并交接旧自启后，EZRWorker 会重启该 Gateway，重启后使用 App 内置 runtime。
```

当用户选择“仅观察”：

```text
仅观察不会切换 runtime，仍由原启动链路继续管理。
```

### 8.3 Profile 终端

`ProfileTerminalView` header 当前展示 Gateway、端口、WebSocket、Workspace。建议补充：

```text
Runtime App 内置 1.2.3
```

终端本身是 App 启动的 CLI，因此终端命令 runtime 应显示 planned runtime；如果 Gateway active runtime 不同，可在状态条补一句：

```text
终端使用 App runtime；当前 Gateway 进程仍使用旧 runtime。
```

## 九、生命周期规则

### 9.1 prepare

`prepareProfile` 不启动 Gateway，只准备 config/state。

展示：

```text
未运行；启动后使用 <plannedRuntime>
```

### 9.2 start

如果 start 时没有可复用 Gateway：

```text
ownership = supervised
activeRuntime = plannedRuntime
```

如果 start 时 adopt 了已有健康 Gateway：

```text
ownership = adopted
activeRuntime = processRuntime(pid)
plannedRuntime = OpenClawRuntime.plannedRuntimeDescriptor
```

此时如两者不一致，UI 提示“重启后切换”。

### 9.3 restart

托管 profile 的 restart 应把 active runtime 收敛到 planned runtime。验收时需要确认：

```text
restart 前：ownership = adopted, active = 旧 runtime
restart 后：ownership = supervised, active = App runtime
```

### 9.4 stop

停止后：

```text
activeRuntime = nil
plannedRuntime 保留
```

UI 显示“未运行；启动后使用 <plannedRuntime>”。

### 9.5 observeOnly

observeOnly 不显示“重启后切换”，因为 EZRWorker 不应该重启这个 profile。

```text
activeRuntime = 外部 runtime 或 nil
plannedRuntime = nil 或只作为 App CLI runtime 展示
```

建议 UI 文案：

```text
外部管理：当前 runtime <activeRuntime>
```

## 十、实现步骤

### Phase 1: runtime descriptor

修改文件：

- `Shared/OpenClawRuntime.swift`
- `Shared/GatewayProfiles.swift`
- `tests/GatewayRuntimeCodableTests.swift`

动作：

1. 新增 `OpenClawRuntimeDescriptor` 及相关 enum。
2. `OpenClawRuntime` 暴露 `plannedRuntimeDescriptor`。
3. 调整 runtime resolver，让它返回来源而不是只返回 URL。
4. Codable 测试覆盖旧 JSON 缺字段和新 JSON 保留字段。

### Phase 2: process runtime detection

修改文件：

- `EZRWorkerSupervisor/SupervisorController+GatewayProcess.swift`
- `EZRWorkerSupervisor/SupervisorController+Readiness.swift`
- `EZRWorkerApp/EZRWorker/Services/OpenClawInstanceDiscoveryService.swift`

动作：

1. 新增 `runtimeDescriptorForGatewayProcess(pid:)`。
2. 从 command line / open files 解析 Node/OpenClaw 路径。
3. 从 LaunchAgent `ProgramArguments` 解析 runtime。
4. 只做 best-effort，不因识别失败影响 profile health。

### Phase 3: snapshot/candidate 透传

修改文件：

- `Shared/GatewayProfiles.swift`
- `EZRWorkerSupervisor/SupervisorRecord.swift`
- `EZRWorkerSupervisor/SupervisorController+Readiness.swift`
- `EZRWorkerApp/EZRWorker/Services/OpenClawInstanceDiscoveryService.swift`

动作：

1. `SupervisorRecord` 增加 `plannedRuntime`、`activeRuntime`、`runtimeMismatchReason`。
2. `snapshot()` 透传字段。
3. running/adopted/supervised 刷新时更新 active runtime。
4. discovery candidate 记录 active/launchAgent runtime。

### Phase 4: UI 展示

修改文件：

- `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`
- `EZRWorkerApp/EZRWorker/Views/ExistingOpenClawImportView.swift`
- `EZRWorkerApp/EZRWorker/Views/ProfileTerminalView.swift`

动作：

1. Profile 卡片增加 Runtime metric。
2. runtime mismatch 时在状态条给出解释。
3. 导入候选展示当前 runtime 与接管后 runtime。
4. Profile 终端 header 展示 CLI runtime，并在 Gateway runtime 不一致时提示。

### Phase 5: 测试与验收

测试：

- `GatewayRuntimeCodableTests`：缺字段兼容、新字段 round trip。
- 新增 process parser 单元测试：
  - App bundle node + openclaw.mjs。
  - Debug `build/dev-runtime`。
  - `~/.npm-global/bin/openclaw gateway`。
  - 外部 node + 外部 openclaw.mjs。
  - unknown command line。

手动验收：

1. Debug 运行，确认 planned runtime 显示 `Dev Runtime`。
2. Release 包运行，确认 planned runtime 显示 `App 内置`。
3. 启动一个旧 `~/.npm-global/bin/openclaw gateway`，导入为 observeOnly，确认显示旧全局 npm。
4. 同一旧进程导入为托管但尚未重启，确认显示“当前旧 runtime；重启后 App runtime”。
5. 点击重启后，确认 active runtime 变为 App runtime。
6. LaunchAgent 候选导入页显示 plist runtime 线索。

## 十一、风险与边界

### 11.1 command line 解析不完整

macOS 上 `ps` 输出可能被截断，或者 wrapper 命令隐藏了真实 node/openclaw 路径。

处理：

- 解析失败显示“未知 runtime”。
- 不影响 profile 运行态。
- hover 中提示“无法从进程命令行确认 runtime”。

### 11.2 lsof 权限不足

有些外部进程可能无法读取完整 open files。

处理：

- 降级到 command line。
- 再降级到 LaunchAgent 信息。
- 最后显示 unknown。

### 11.3 runtime 版本读取成本

读取 `package.json` 成本低，可以做。`node --version` 需要启动子进程，建议第一阶段不做或缓存。

### 11.4 路径泄露

路径属于诊断信息，可以展示，但不要展示完整环境变量、token、Authorization header、secrets provider 内容。

### 11.5 “托管”与“切换 runtime”的误解

托管 profile 如果采用已有健康进程，会先进入 adopted。UI 必须明确：

```text
已接入 Gateway，但当前进程仍使用旧 runtime。
```

不要把 `managementMode == managedByEZRWorker` 直接翻译成 `activeRuntime == App 内置`。

## 十二、推荐交付顺序

建议按以下顺序实现，保证每一步都能独立验证：

1. 先只展示 planned runtime：让用户知道“这个 profile 启动后会用哪里”。
2. 再识别 supervised/adopted active runtime：解决“当前进程到底从哪里来”。
3. 最后接入导入页和 mismatch 文案：解决 App 接管前后的用户解释。

最小可交付版本：

- `SupervisorProfileRuntime.plannedRuntime`
- `SupervisorProfileRuntime.activeRuntime`
- 设置页 Profile 卡片展示 Runtime
- adopted mismatch 文案

导入页和 Profile 终端可以作为第二批补齐。
