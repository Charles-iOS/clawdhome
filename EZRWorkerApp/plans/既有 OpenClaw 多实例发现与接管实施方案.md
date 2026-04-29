---
name: Existing OpenClaw Multi Instance Adoption Implementation Plan
overview: 将“既有 OpenClaw 多实例发现与接管”拆成可落地的工程实施步骤，覆盖模型迁移、扫描器、导入 UI、Supervisor 接管、测试验收与分阶段发布。
todos:
  - id: mvp-scope
    content: "确定 MVP 范围：运行中进程 + ~/.openclaw + 手动选择 openclaw.json，默认 observeOnly"
    status: pending
  - id: model-store
    content: "落地数据模型、旧 profiles.json 兼容解码、externalReuse 导入 API"
    status: pending
  - id: discovery
    content: "实现 OpenClawInstanceDiscoveryService 与候选项归一化/去重/风险评级"
    status: pending
  - id: ui
    content: "新增首启导入页和设置页导入入口"
    status: pending
  - id: supervisor
    content: "强化 Supervisor 对 externalReuse/observeOnly 的接管和生命周期保护"
    status: pending
  - id: tests
    content: "补齐单元测试、手动验收脚本和回滚路径"
    status: pending
isProject: false
---

# 既有 OpenClaw 多实例发现与接管实施方案

## 一、实施原则

本轮实现按“先不伤害用户已有实例，再逐步托管”的原则推进。

第一版默认只做安全接入：

- 能发现已有 OpenClaw。
- 能导入为 profile。
- 能让 App 连接、展示、切换这些 profile。
- 默认不停止、不重启、不改写外部配置。
- 用户明确选择“交给 EZRWorker 托管”后，Supervisor 才允许 start/stop/restart 和必要配置写入。

这样可以先解决“机器上已有多个 OpenClaw，目录不固定，App 要能直接看到并接上”的核心问题，同时把误杀进程、误改配置、误接管端口的风险压到最低。

## 二、MVP 范围

### 2.1 必做

1. 数据模型新增 `externalReuse`。
2. 数据模型新增显式管理模式：

```swift
enum GatewayProfileManagementMode: String, Codable, CaseIterable {
    case managedByEZRWorker
    case observeOnly
}
```

3. 新增发现候选项模型 `OpenClawInstanceCandidate`。
4. 新增扫描器，MVP 覆盖：
   - 当前运行中的 OpenClaw gateway 进程
   - `~/.openclaw/openclaw.json`
   - 用户手动选择任意 `openclaw.json`
5. 新增 `GatewayProfileStore.importExternalProfile(...)`。
6. 新增首启导入页：无 `profiles.json` 且发现候选项时展示。
7. 设置页新增“扫描已有 OpenClaw”和“导入配置文件”。
8. Supervisor 对 `externalReuse + observeOnly` 只探活/adopt，禁止 start/stop/restart。
9. 删除 `externalReuse` profile 时只删除 profile 记录，不删除原目录。

### 2.2 暂缓

1. 深度目录扫描。
2. launchd 自动停用与交接。
3. 跨 macOS 用户扫描。
4. 外部 OpenClaw 版本自动迁移。
5. 自动修复端口冲突。

这些能力可以在 MVP 稳定后作为 Phase 2 增量补齐。

## 三、实施顺序

建议按 6 个 PR 或 6 个连续提交推进。每一步都保持可编译，避免半套模型流入 UI 或 Supervisor。

| 阶段 | 目标 | 结果 |
| --- | --- | --- |
| Step 1 | 模型与兼容解码 | 老 `profiles.json` 继续可读，新 profile 可表达外部实例 |
| Step 2 | Store 导入能力 | 可以从候选项写入 `profiles.json` |
| Step 3 | 发现服务 | 可以列出运行中/默认目录/手动选择的候选项 |
| Step 4 | 首启与设置页 UI | 用户能看到候选项并确认导入 |
| Step 5 | Supervisor 接管保护 | observeOnly 不会被启动/停止，externalReuse 严格匹配进程 |
| Step 6 | 测试与验收 | 覆盖旧数据兼容、导入、冲突、删除、adopt |

## 四、Step 1：模型与兼容解码

### 4.1 修改文件

- `Shared/GatewayProfiles.swift`
- `Shared/SupervisorProtocol.swift` 如 snapshot 字段需要透传
- `EZRWorkerSupervisor/SupervisorRecord.swift`
- `tests/GatewayProfileResolverTests.swift` 或新增测试文件

### 4.2 具体改动

扩展来源类型：

```swift
enum GatewayProfileSourceKind: String, Codable, CaseIterable {
    case managed
    case legacyReuse
    case externalReuse
}
```

扩展 profile：

```swift
struct GatewayProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var slug: String
    var displayName: String
    var autoStart: Bool
    var sourceKind: GatewayProfileSourceKind
    var managementMode: GatewayProfileManagementMode
    var configPathOverride: String?
    var stateDirOverride: String?
    var workspaceRootOverride: String?
    var portOverride: Int?
    var createdAt: Date
}
```

兼容旧数据：

- 旧 `profiles.json` 没有 `managementMode` 时，解码默认：
  - `managed` -> `.managedByEZRWorker`
  - `legacyReuse` -> `.managedByEZRWorker`
  - `externalReuse` -> `.observeOnly`
- 如果未来出现未知 `sourceKind`，不要崩溃；至少能报出可读错误。

`GatewayProfileResolver.resolve(_:)` 增加 `externalReuse` 规则：

- `externalReuse` 必须有 `configPathOverride`。
- `stateDirOverride` 优先使用候选项提供值。
- 如果缺少 `stateDirOverride`，临时回落到 `configPath` 所在目录。
- `workspaceRootOverride` 缺失时回落到 `stateDir/workspace`。
- `portOverride` 缺失时回落到 `defaultGatewayPort`，但 UI 要标记需要确认。

### 4.3 验收

- 现有 `profiles.json` 可以正常加载。
- 新增字段写入后 JSON 稳定、可读。
- `managed` profile 行为不变。
- `legacyReuse` profile 行为不变。
- `externalReuse` 缺 `configPathOverride` 时不能被创建。

## 五、Step 2：Store 导入能力

### 5.1 修改文件

- `Shared/GatewayProfiles.swift`
- `EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`
- `tests/GatewayProfileStoreTests.swift` 或新增测试文件

### 5.2 新增模型

建议放在 `Shared/GatewayProfiles.swift`，避免 App/Supervisor 后续都要用时再搬家。

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
    var warnings: [String]
    var detectedAt: Date
}
```

### 5.3 新增 Store API

```swift
@discardableResult
func importExternalProfile(
    candidate: OpenClawInstanceCandidate,
    displayName: String? = nil,
    slug: String? = nil,
    autoStart: Bool = false,
    managementMode: GatewayProfileManagementMode = .observeOnly
) throws -> GatewayProfile
```

实现规则：

- `managementMode == .observeOnly` 时强制 `autoStart = false`。
- `managementMode == .managedByEZRWorker` 时允许 `autoStart`，但必须通过写权限和端口校验。
- `sourceKind = .externalReuse`。
- `configPathOverride = candidate.configPath`。
- `stateDirOverride = candidate.stateDir`。
- `workspaceRootOverride = candidate.workspaceRoot ?? inferredWorkspaceRoot`。
- `portOverride = candidate.port ?? readPort(configPath)`。
- slug 使用 `GatewayProfileResolver.makeUniqueSlug`。

### 5.4 校验规则

导入前校验：

- `configPath` 是绝对路径。
- `configPath` 存在且不是目录。
- `configPath` 可读。
- `stateDir` 是绝对路径。
- `workspaceRoot` 如存在必须是绝对路径。
- 端口必须在 `1...65535`。
- 与已有 profile 的基础端口间距满足 `managedPortSpacing`。

observeOnly 特例：

- 如果 config 父目录不可写，可以导入。
- 如果端口已被同一个候选 pid 占用，可以导入。
- 如果端口冲突但不是同一个候选 pid，导入页必须提示，只允许用户跳过或改端口后导入。

### 5.5 删除规则

更新 `cleanupManagedProfileData(for:)`：

- 只有 `sourceKind == .managed` 才删除 `EZRWorkerPaths.managedProfileRoot(slug:)`。
- `legacyReuse` 和 `externalReuse` 永远不删除用户原目录。

### 5.6 验收

- 从候选项导入后 `profiles.json` 包含 externalReuse profile。
- observeOnly 导入后 `autoStart` 一定为 false。
- 删除 externalReuse profile 不动原始文件。
- 旧 `importLegacyProfile()` 仍可用。

## 六、Step 3：发现服务

### 6.1 新增文件

```text
EZRWorkerApp/EZRWorker/Services/OpenClawInstanceDiscoveryService.swift
```

如测试需要纯逻辑拆分，可再加：

```text
Shared/OpenClawInstanceDiscoveryModels.swift
tests/OpenClawInstanceDiscoveryTests.swift
```

### 6.2 服务接口

```swift
@MainActor
@Observable
final class OpenClawInstanceDiscoveryService {
    private(set) var isScanning = false
    private(set) var candidates: [OpenClawInstanceCandidate] = []
    private(set) var lastError: String?

    func scanLightweight() async
    func candidateFromManualSelection(_ url: URL) throws -> OpenClawInstanceCandidate
}
```

MVP 的 `scanLightweight()` 只做：

1. `scanRunningGatewayProcesses()`
2. `scanLegacyOpenClawDirectory()`
3. 合并去重

### 6.3 运行中进程扫描

使用 `Process` 直接执行系统工具，不通过 shell：

```text
/bin/ps -axo pid=,command=
/usr/sbin/lsof -Fn -p <pid>
/usr/sbin/lsof -Pan -p <pid> -iTCP -sTCP:LISTEN
```

识别条件：

- command line 包含 `openclaw` 和 `gateway`
- 或打开文件里包含 `openclaw.json`
- 或打开文件路径落在 `.openclaw` / `Application Support/OpenClaw` 下

提取路径优先级：

1. command line 中的 `OPENCLAW_CONFIG_PATH=...`
2. 打开文件中的 `openclaw.json`
3. 已知目录扫描结果补全

提取 stateDir 优先级：

1. command line 中的 `OPENCLAW_STATE_DIR=...`
2. `openclaw.json` 所在目录
3. `~/.openclaw`

### 6.4 默认目录扫描

MVP 只检查：

```text
~/.openclaw/openclaw.json
```

后续 Phase 2 再加有限深度目录扫描。

### 6.5 候选项构造

读取 `openclaw.json`：

- `gateway.port`
- `agents.defaults.workspace`
- 可选读取版本字段，如果配置里没有则为空

风险评级：

- `safe`：config 可读、端口可解析、没有明显冲突。
- `needsReview`：端口缺失、路径不可写、运行中但无法确认 stateDir。
- `blocked`：config 不可读、端口非法、端口被非 OpenClaw 占用。

### 6.6 去重

去重 key：

1. 标准化 `configPath`
2. 标准化 `stateDir`
3. `pid`

合并时：

- `runningProcess` 优先于 `knownDirectory`
- `high` confidence 优先
- warnings 合并去重
- pid/commandLine 优先保留非空值

### 6.7 验收

- 没有 OpenClaw 时返回空数组。
- 有 `~/.openclaw/openclaw.json` 时返回一个候选项。
- 运行中 gateway 可以识别 pid 和端口。
- 同一个 `~/.openclaw` 被进程和目录同时发现时只出现一次。

## 七、Step 4：首启与设置页 UI

### 7.1 修改文件

- `EZRWorkerApp/EZRWorker/Services/GatewayProfileStore.swift`
- `EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`
- `EZRWorkerApp/EZRWorker/Views/ProfileMigrationChoiceView.swift`
- 新增 `EZRWorkerApp/EZRWorker/Views/ExistingOpenClawImportView.swift`
- `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`

### 7.2 Store 状态

新增状态：

```swift
enum Status: Equatable {
    case loading
    case needsLegacyMigration(legacyPort: Int?)
    case needsExistingOpenClawImport([OpenClawInstanceCandidate])
    case ready
    case failed(String)
}
```

加载流程调整：

1. 有 `profiles.json`：直接 ready。
2. 无 `profiles.json`：
   - 执行轻量扫描。
   - 多个候选项：`needsExistingOpenClawImport`。
   - 一个 `~/.openclaw` 候选项：可继续走 `needsLegacyMigration`，降低首版 UI 改动。
   - 一个非 `~/.openclaw` 候选项：`needsExistingOpenClawImport`。
   - 无候选项：创建默认 managed profile。

### 7.3 首启导入页

`ExistingOpenClawImportView` 内容：

- 候选项列表。
- 勾选是否导入。
- 显示 config/state/workspace/port/pid。
- 显示风险提示。
- 管理模式选择：
  - 仅观察
  - 交给 EZRWorker 托管
- “导入选中项”按钮。
- “跳过并创建新 profile”按钮。

默认值：

- `riskLevel == safe` 且未检测到外部 supervisor：可默认选中。
- 运行中实例默认 observeOnly。
- 路径不可写默认 observeOnly。
- blocked 不可导入，只能跳过。

### 7.4 设置页入口

Profiles 区域新增按钮：

- “扫描已有 OpenClaw”
- “导入配置文件”

交互：

- “扫描已有 OpenClaw”弹出导入 sheet。
- “导入配置文件”打开 `NSOpenPanel`，允许选择文件或目录。
- 导入完成后：
  - `profileStore` 持久化。
  - `supervisorClient.reloadProfiles()`。
  - `processManager.refreshRuntimeState()`。

### 7.5 验收

- 首启发现多个候选项时不会直接创建新 profile。
- 用户可跳过导入并创建新 managed profile。
- 设置页能手动导入任意 `openclaw.json`。
- 导入后 profile 卡片显示为“外部复用/仅观察”。

## 八、Step 5：Supervisor 接管保护

### 8.1 修改文件

- `EZRWorkerSupervisor/SupervisorController+GatewayProcess.swift`
- `EZRWorkerSupervisor/SupervisorController+Lifecycle.swift`
- `EZRWorkerSupervisor/SupervisorController+Readiness.swift`
- `EZRWorkerSupervisor/SupervisorController+Config.swift`
- `Shared/GatewayProfiles.swift`

### 8.2 strict adopt

把“非 managed 一律 adopt”改成按来源处理：

```swift
switch record.profile.sourceKind {
case .managed:
    // 现有严格 managed 匹配逻辑
case .legacyReuse:
    // 保持兼容，但至少确认 looksLikeGatewayProcess
case .externalReuse:
    // 必须确认端口进程属于当前 config/state
}
```

externalReuse 匹配条件：

- command line 包含 profile 的 configPath 或 stateDir。
- 或 `lsof -Fn -p <pid>` 打开了 profile 的 configPath。
- 或打开了 stateDir 下文件。

否则：

- 不 adopt。
- 不 kill。
- runtime 标记 failed，并提示端口被其他进程占用。

### 8.3 observeOnly 生命周期限制

新增 guard：

```swift
guard record.profile.managementMode == .managedByEZRWorker else {
    return (false, "该 Profile 当前为仅观察模式，请先切换为 EZRWorker 托管")
}
```

应用位置：

- `prepareProfile` 中写配置前。
- `startProfile` 中启动新进程前。
- `stopProfile` 中停止外部 pid 前。
- `restartProfile` 中。

observeOnly 仍允许：

- `refreshRuntimeSnapshotsBeforeListing`
- `adoptExistingHealthyGatewayIfAvailable` 的只读状态更新
- App 连接 gateway

### 8.4 配置写入备份

`normalizeConfig(for:)` 写外部配置前：

- 判断 `sourceKind == .externalReuse`。
- 生成备份：

```text
openclaw.json.ezrworker-backup-YYYYMMDD-HHMMSS
```

- 写后重新解析 JSON。
- 失败时恢复备份。

MVP 可以先只在 supervised externalReuse 写入时备份；managed profile 不需要备份。

### 8.5 Runtime snapshot

`SupervisorProfileRuntime` 建议增加：

```swift
var sourceKind: GatewayProfileSourceKind
var managementMode: GatewayProfileManagementMode
```

这样设置页可以直接展示真实运行态，不用只靠本地 profile 推导。

### 8.6 验收

- externalReuse observeOnly 不能被 start/stop/restart。
- externalReuse 运行中且端口 pid 匹配 config/state 时可显示 adopted。
- 端口上是别的进程时不会被 kill。
- supervised externalReuse 写配置前生成备份。

## 九、Step 6：测试与验收

### 9.1 单元测试

建议新增：

```text
tests/ExternalOpenClawProfileImportTests.swift
tests/OpenClawInstanceDiscoveryTests.swift
tests/GatewayProfileCodableCompatibilityTests.swift
```

覆盖：

- 旧 profiles JSON 缺 `managementMode` 能解码。
- externalReuse 创建必须有绝对 config path。
- observeOnly 导入强制 autoStart false。
- 删除 externalReuse 不删除原始目录。
- 候选项去重。
- `openclaw.json` 端口读取。
- workspace 推导。

### 9.2 手动验收场景

准备 3 个临时实例目录：

```text
/tmp/ezrworker-adopt/a/openclaw.json
/tmp/ezrworker-adopt/b/openclaw.json
~/.openclaw/openclaw.json
```

场景：

1. 无 `profiles.json`、无 OpenClaw：首启创建 default。
2. 只有 `~/.openclaw`：仍出现复用老的/创建新的。
3. 有多个外部配置：首启展示导入页。
4. 手动选择 `/tmp/.../openclaw.json`：可导入为 externalReuse。
5. observeOnly：点击启动/停止时提示不可操作。
6. supervised：可 prepare/start，并写入备份。
7. 删除 externalReuse：原目录仍存在。
8. 端口被 `python -m http.server` 占用：不 adopt、不 kill。

### 9.3 推荐验证命令

```bash
make build
xcodebuild -project EZRWorker.xcodeproj -scheme EZRWorker -configuration Debug build
```

如果新增 Swift 测试 target 可用，再跑对应测试；如果当前工程测试链路不稳定，至少保证 build 和手动验收通过。

## 十、发布策略

### 10.1 灰度开关

建议先加 UserDefaults 开关：

```text
ai.ezrworker.mac.existingOpenClawImport.enabled
```

默认开启首启轻量发现，但深度扫描默认关闭。

### 10.2 日志

关键日志：

- 扫描开始/结束/候选数量。
- 候选项被跳过的原因。
- 导入 externalReuse 的 config/state/port。
- observeOnly 阻止 start/stop/restart 的原因。
- supervised 写配置备份路径。
- adopt 失败原因。

不要记录 token、secret、完整 credentials 内容。

### 10.3 回滚

回滚方式：

- 删除 externalReuse profile 记录。
- 恢复 `openclaw.json.ezrworker-backup-*`。
- 重新启用用户原来的启动脚本或 launchd job。

MVP 不自动操作旧 launchd，所以回滚成本应保持很低。

## 十一、任务切分清单

### PR 1：模型与兼容

- [ ] 新增 `GatewayProfileSourceKind.externalReuse`
- [ ] 新增 `GatewayProfileManagementMode`
- [ ] `GatewayProfile` 自定义 Codable 默认值
- [ ] `GatewayProfileResolver` 支持 externalReuse
- [ ] `SupervisorProfileRuntime` 增加 source/mode
- [ ] 补兼容解码测试

### PR 2：Store 导入

- [ ] 新增 `OpenClawInstanceCandidate`
- [ ] 新增 `importExternalProfile`
- [ ] 增加 externalReuse 校验
- [ ] 删除逻辑只清理 managed
- [ ] 补 Store 测试

### PR 3：发现服务

- [ ] 新增 `OpenClawInstanceDiscoveryService`
- [ ] 实现运行中进程扫描
- [ ] 实现 `~/.openclaw` 检测
- [ ] 实现手动选择候选项
- [ ] 实现去重和风险评级
- [ ] 补 discovery 测试

### PR 4：导入 UI

- [ ] 新增 `ExistingOpenClawImportView`
- [ ] `AppRootGateView` 接入新 status
- [ ] 设置页新增扫描/导入按钮
- [ ] Profile 卡片展示 externalReuse 和 observeOnly
- [ ] 导入后 reload Supervisor

### PR 5：Supervisor 保护

- [ ] externalReuse strict adopt
- [ ] observeOnly 禁止 prepare/start/stop/restart 写操作
- [ ] supervised externalReuse 写配置备份
- [ ] stop 不误杀非匹配进程
- [ ] 更新 runtime 状态文案

### PR 6：验收与文档

- [ ] 完成手动验收清单
- [ ] 更新 `docs/project-structure-v2.zh.md`
- [ ] 更新设置页文案或 release notes
- [ ] 记录已知限制：MVP 不做深度扫描/launchd 自动交接

## 十二、最小上线判断

满足下面条件即可上线 MVP：

1. 旧用户 `~/.openclaw` 迁移不倒退。
2. 外部任意 `openclaw.json` 可手动导入。
3. 运行中 OpenClaw 可被发现并以 observeOnly 进入 App。
4. App 可以切换到导入 profile 并连接 gateway。
5. observeOnly 不会停止或重启用户原进程。
6. 删除导入 profile 不删除用户原目录。
7. 端口被非 OpenClaw 占用时不会误接管。

第一版做到这些，用户就可以在“之前安装过 OpenClaw 且目录不固定”的机器上，把 App 作为统一控制面先用起来；后续再逐步把深度扫描、launchd 交接和全自动托管补上。
