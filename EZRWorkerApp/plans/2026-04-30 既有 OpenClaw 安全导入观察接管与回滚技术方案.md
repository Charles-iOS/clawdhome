# 既有 OpenClaw 安全导入、观察、接管与回滚技术方案

## 1. 背景

当用户在已经安装并长期运行 OpenClaw 的机器上安装 EZRWorker App 时，机器上通常已经存在一套完整的旧运行环境：

- 旧 `openclaw.json`
- 旧 `~/.openclaw` state/workspace/logs/credentials
- 旧 LaunchAgent 或其他自启动链路
- 旧 Node/OpenClaw runtime
- 旧插件目录与插件依赖 `node_modules`
- 旧插件 runtime dependency cache
- 正在运行的 Gateway 进程、端口、WebSocket 会话、渠道连接

本轮问题暴露出一个关键风险：**复用旧配置不等于可以安全接管旧服务**。

当前 App 托管逻辑在接管后会使用 App 内置 runtime 启动旧配置。旧配置中的 Telegram、飞书、企微、自定义插件等会被新 runtime 重新加载。只要依赖缓存、插件目录、Node/OpenClaw 版本、临时安装目录、LaunchAgent 状态中任一项不一致，就可能出现启动失败、插件失败、端口占用、双进程竞争或无法自动回滚。

因此必须把“导入观察”和“迁移接管”拆成两个安全等级完全不同的流程。

## 2. 结论

默认策略必须是：

1. 已存在 OpenClaw 的机器，默认只导入为“仅观察”。
2. 仅观察不得停止、禁用、改名、重启旧 LaunchAgent。
3. 仅观察不得用 App runtime 启动旧配置。
4. 接管必须是显式高级操作，必须先通过完整 preflight。
5. 接管必须事务化，失败必须自动恢复旧 LaunchAgent、旧 runtime、旧端口占用状态。
6. 接管失败不能把用户留在“旧的被停、App 又起不来”的状态。

## 3. 目标

- 保护用户既有 OpenClaw 环境，不破坏旧 runtime、旧插件依赖、旧 LaunchAgent。
- 用户首次安装 App 时可以无风险接入既有 OpenClaw。
- App 能准确显示“当前谁在管理 Gateway”：旧 LaunchAgent、App Supervisor、外部进程、未知。
- App 能明确区分“观察”“接管”“迁移”“回滚”。
- 对接管前的风险给出确定性诊断，不用“可能、大概率”等模糊描述。
- 接管流程具备可回滚事务，不让用户手工救火。
- 保留未来能力：在安全条件满足后，支持 App 托管旧配置，或支持 App 通过旧 runtime 托管。

## 4. 非目标

- 不在第一阶段强行修复所有历史插件目录问题。
- 不默认清理用户 `~/.openclaw/extensions` 下的任何目录。
- 不默认升级用户旧 OpenClaw runtime。
- 不默认改写 `~/.openclaw/openclaw.json`。
- 不把 App 内置 runtime 的依赖缓存和旧 runtime 的依赖缓存混用。
- 不用一次“导入”同时完成发现、禁用旧服务、迁移依赖、启动新服务。

## 5. 当前实现风险点

### 5.1 legacyReuse 默认托管风险

`GatewayProfile.defaultManagementMode(for:)` 当前对 `.legacyReuse` 默认返回 `.managedByEZRWorker`。这意味着旧 `~/.openclaw` 被复用后，后续 start/restart 会进入 App 托管生命周期。

风险：

- 用户理解的“复用旧的”可能只是复用旧运行环境。
- 实际行为会在旧进程不存在或旧 LaunchAgent 被交接后，用 App 内置 runtime 启动旧配置。
- 旧 runtime 里的依赖不等于 App runtime 的依赖。

### 5.2 App 托管启动必然使用 App runtime

`SupervisorController+Lifecycle.startProfile` 启动进程时使用：

- `OpenClawRuntime.bundledNodeURL`
- `OpenClawRuntime.bundledOpenClawEntry`
- `OpenClawRuntime.buildEnvironment(profile:)`

`OpenClawRuntime.buildEnvironment` 会设置：

- `OPENCLAW_CONFIG_PATH`
- `OPENCLAW_STATE_DIR`
- `OPENCLAW_PLUGIN_STAGE_DIR`
- `OPENCLAW_NO_RESPAWN=1`
- `EZRWORKER_SUPERVISOR_CHILD=1`

风险：

- 用户旧配置被 App runtime 执行。
- 插件依赖 stage 目录变成 EZRWorker Application Support 下的新目录。
- 旧 runtime 缓存中的依赖不会自动复用。

### 5.3 LaunchAgent handoff 是破坏性动作

`LaunchAgentHandoffService.disable` 会：

- `launchctl bootout`
- `launchctl disable`
- 把 plist 改名为 `.disabled-时间戳`

风险：

- 旧服务一旦被停，用户原本可用的旧环境中断。
- 如果 App runtime 随后启动失败，需要可靠恢复 plist、launchctl enable、kickstart、端口监听。
- 当前交接和启动之间没有完整事务边界。

### 5.4 插件与依赖的真实风险

既有 OpenClaw 可能包含：

- bundled plugin
- external plugin
- 手动安装插件
- 残留安装临时目录，例如 `.openclaw-install-stage-*`
- duplicate plugin id
- 插件自己的 `node_modules`
- 插件依赖缺失
- native module 与 CPU 架构绑定
- 依赖通过旧 runtime 或旧 NODE_PATH 才能解析

App runtime 重新扫描这些目录时，可能出现：

- `Cannot find module`
- `npm install failed`
- plugin register 失败
- bundled runtime deps stage 失败
- duplicate plugin id 覆盖顺序变化
- 渠道插件部分加载，部分失败

### 5.5 双进程与端口竞争

如果旧 LaunchAgent 和 App Supervisor 同时尝试管理同一个 port：

- 端口会被其中一个进程占用。
- 另一个进程可能处于运行但未监听状态。
- App UI 可能显示运行态和实际监听 PID 不一致。
- 停错进程会造成旧环境或 App 环境异常。

## 6. 术语定义

### 6.1 仅观察

App 只记录既有 OpenClaw 的 config/state/workspace/port/LaunchAgent 信息，只读取运行态，不拥有生命周期。

约束：

- 不调用 start/restart/stop。
- 不禁用旧 LaunchAgent。
- 不改写旧 config。
- 不改写旧插件目录。
- 不改写旧 runtime deps cache。
- UI 中所有“启动/重启/停止/交接”动作默认隐藏或禁用。

### 6.2 App 托管

App Supervisor 拥有 Gateway 生命周期，使用 App 内置 runtime 启动 OpenClaw。

约束：

- 必须无旧 LaunchAgent 冲突。
- 必须拥有依赖 stage 目录。
- 必须能停止自身启动的进程。
- 必须能记录启动失败并触发回滚。

### 6.3 旧 runtime 托管

未来可选模式：App Supervisor 拥有生命周期，但启动命令使用旧 LaunchAgent 中记录的 Node/OpenClaw runtime，而不是 App 内置 runtime。

用途：

- 对已经稳定运行的 legacy 机器降低迁移风险。
- 保持插件依赖解析环境不变。
- 仍允许 App 统一控制 start/stop/restart。

该模式不是第一阶段必需，但数据模型应预留。

### 6.4 迁移接管

把 profile 从“仅观察”切换到“App 托管”或“旧 runtime 托管”的显式事务。

迁移接管不是导入；导入只创建观察记录。

## 7. 产品策略

### 7.1 首次安装时

如果扫描到既有 OpenClaw：

- 默认选项：保持旧 OpenClaw 运行，仅接入观察。
- 次选项：创建新的 EZRWorker Default Profile。
- 高级选项：迁移由 EZRWorker 托管。

不得把“复用旧配置”默认映射为“App 托管”。

### 7.2 设置页导入时

“扫描已有 OpenClaw”结果中：

- 每个候选默认 `observeOnly`。
- “托管”按钮默认折叠在高级区域。
- 托管按钮在 preflight 未执行前不可直接提交。
- preflight 有 blocker 时不可托管。

### 7.3 UI 文案要求

避免使用含混词：

- 不用“复用旧的”单独表达复杂行为。
- 使用“仅观察旧 OpenClaw”。
- 使用“迁移并由 App 托管”。
- 使用“继续使用旧 runtime 托管”。

关键提示必须明确：

- “仅观察不会停止旧 LaunchAgent。”
- “App 托管会停用旧 LaunchAgent，并使用 App 内置 runtime 重新加载旧配置。”
- “旧 runtime 中已有依赖不会自动等同于 App runtime 可用依赖。”
- “迁移失败将自动恢复旧 LaunchAgent。”

## 8. 目标数据模型

### 8.1 GatewayProfile 调整

保留：

- `sourceKind`
- `managementMode`
- `launchAgentHandoff`

建议新增：

```swift
enum GatewayProfileRuntimeMode: String, Codable {
    case appBundled
    case observedExternal
    case externalCommand
}
```

含义：

- `observedExternal`：只观察，不启动。
- `appBundled`：App Supervisor 使用 App 内置 runtime。
- `externalCommand`：App Supervisor 使用旧 runtime descriptor 启动。

### 8.2 LegacyRuntimeDescriptor

```swift
struct LegacyRuntimeDescriptor: Codable, Hashable {
    var nodePath: String
    var openClawEntryPath: String
    var arguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var openClawVersion: String?
    var nodeVersion: String?
    var source: Source

    enum Source: String, Codable {
        case launchAgent
        case runningProcess
        case manual
    }
}
```

用途：

- 精确表达旧 LaunchAgent 原来怎么启动。
- 支持“旧 runtime 托管”。
- 支持回滚时恢复原启动链路。

### 8.3 CompatibilityReport

```swift
struct CompatibilityReport: Codable, Hashable {
    var generatedAt: Date
    var candidateID: UUID
    var targetRuntimeMode: GatewayProfileRuntimeMode
    var summary: Summary
    var checks: [CompatibilityCheck]
    var proposedActions: [MigrationAction]
    var evidence: [Evidence]
}

struct CompatibilityCheck: Codable, Hashable {
    var id: String
    var title: String
    var severity: Severity
    var status: Status
    var message: String
    var remediation: String?
}

enum Severity: String, Codable {
    case info
    case warning
    case blocker
}
```

### 8.4 HandoffTransaction

```swift
struct HandoffTransaction: Codable, Hashable {
    var id: UUID
    var profileID: UUID
    var phase: Phase
    var startedAt: Date
    var updatedAt: Date
    var originalLaunchAgent: OpenClawLaunchAgentInfo?
    var originalPlistBackupPath: String?
    var originalListeningPID: Int32?
    var originalPort: Int
    var appStartedPID: Int32?
    var rollbackPlan: [RollbackAction]
    var failureMessage: String?
}
```

事务必须落盘，App 崩溃后下次启动能继续回滚或提示用户。

## 9. 状态机

### 9.1 Profile 管理状态

```text
Discovered
  -> ImportedObserveOnly
  -> PreflightRunning
  -> PreflightPassed
  -> PreflightFailed
  -> HandoffPreparing
  -> OldLaunchAgentDisabled
  -> AppRuntimeStarting
  -> AppRuntimeHealthy
  -> HandoffCommitted
  -> RollbackRunning
  -> RollbackSucceeded
  -> RollbackFailed
```

### 9.2 状态不变量

`ImportedObserveOnly`：

- 旧 LaunchAgent 不变。
- 不存在 App 托管 PID。
- profile `autoStart=false`。

`PreflightRunning`：

- 只读检查。
- 可写检查只写入临时目录。
- 不改旧 plist。
- 不停旧进程。

`OldLaunchAgentDisabled`：

- 必须已有 rollback 记录。
- 必须已有 plist backup 或 disabled path。
- 必须知道原 label、domain、plist path。

`AppRuntimeStarting`：

- App 启动的 PID 必须被记录。
- readiness timeout 必须有限。
- 失败进入 rollback。

`HandoffCommitted`：

- App PID 监听目标端口。
- 旧 LaunchAgent 处于 disabled 或 not required。
- profile runtime owner 是 App。

`RollbackSucceeded`：

- App PID 已停止。
- 旧 plist 已恢复。
- 旧 LaunchAgent 已 enable/bootstrap/kickstart。
- 目标端口由旧 runtime 或旧外部进程监听。
- profile 降级为 `observeOnly`。

## 10. Preflight 检查

接管前必须生成报告。报告分 blocker、warning、info。

### 10.1 配置与路径

- `openclaw.json` 存在且可解析。
- state dir 存在。
- workspace 存在或可创建。
- credentials 目录存在或明确缺失。
- config/state/workspace 不是 App managed profile 目录。
- 路径不跨用户 home。
- 符号链接解析后仍在允许范围。

### 10.2 当前运行态

- 目标端口是否有监听 PID。
- 监听 PID 是否匹配候选 instance。
- 监听 PID 的 executable 是否可识别。
- 监听 PID 的 parent 是否为旧 LaunchAgent、App Supervisor 或未知。
- 当前 Gateway health 是否响应。
- WebSocket 是否可连接。
- 是否有活跃渠道连接。

### 10.3 LaunchAgent

- 是否存在匹配 LaunchAgent。
- label 是否唯一。
- plist path 是否在允许范围。
- domain 是 user 还是 system。
- 当前用户是否有权限禁用和恢复。
- ProgramArguments 是否能解析出 Node/OpenClaw entry。
- EnvironmentVariables 中是否指定了 config/state/port。
- KeepAlive/RunAtLoad/ThrottleInterval 是否符合预期。
- 是否存在多个 LaunchAgent 指向同一个 config/state/port。

### 10.4 Runtime 版本

- 旧 OpenClaw 版本。
- App 内置 OpenClaw 版本。
- 旧 Node 版本。
- App Node 版本。
- 版本差距是否跨 breaking boundary。
- 旧 runtime 是否来自 dev checkout、npm global、standalone bundle、Homebrew 或其他。

### 10.5 插件清单

扫描：

- `plugins.allow`
- `plugins.entries`
- `~/.openclaw/extensions`
- bundled extensions
- external plugin manifests
- `.openclaw-install-stage-*`
- duplicate plugin ids
- plugin `package.json`
- plugin `openclaw.plugin.json`

检查：

- 启用插件是否存在。
- 插件 main/exports 是否存在。
- 插件依赖是否完整。
- 插件是否声明 channelConfigs。
- 插件是否使用 deprecated SDK。
- 是否有安装临时目录被当作正式插件加载。
- duplicate plugin id 的覆盖顺序是否确定。

### 10.6 依赖与 stage 目录

必须检查：

- App runtime stage root 是否可写。
- App runtime stage root 是否已有 retained manifest。
- 缺失哪些 specs。
- 安装是否需要网络。
- npm registry 是否可访问。
- 磁盘空间是否足够。
- native module 是否匹配 CPU 架构。
- 是否会 prune 已有无关依赖。

禁止：

- 在共享依赖目录直接执行裸 `npm install <少量 specs>`。
- 让 npm prune 掉 retained manifest 中的依赖。
- 在旧插件自己的 `node_modules` 中自动删除依赖。

### 10.7 渠道副作用

接管预检不能触发真实渠道副作用：

- 不注册 Telegram webhook。
- 不主动发消息。
- 不修改 Telegram command menu。
- 不重置企微/飞书连接状态。
- 不写入外部渠道凭证。

如果无法 dry-run，则该检查只能标记为 warning 或 blocker，不能偷偷真实启动。

### 10.8 安全与隐私

- 不在诊断报告中明文展示 token。
- 日志中对 bot token、secret、API key 做脱敏。
- 报告可复制时默认隐藏敏感值。
- App 不上传本地配置。

## 11. 依赖处理方案

### 11.1 App runtime deps

App 内置 runtime 的依赖必须由 App 管理，不能依赖旧 runtime cache。

策略：

1. 根据启用插件生成完整 install spec set。
2. 合并 retained manifest。
3. 在临时 install execution root 执行安装。
4. 安装成功后原子替换或合并到 stage root。
5. 写入 retained manifest。
6. 失败时删除临时目录，不影响现有 stage root。

### 11.2 External plugin deps

外部插件目录有两类：

- 插件自带 `node_modules`，按插件自身解析。
- 插件声明需要 bundled runtime deps，由 OpenClaw stage root 提供。

处理原则：

- 不自动修复用户插件目录，除非用户点“修复插件依赖”。
- 修复前备份或写入插件级 transaction。
- `.openclaw-install-stage-*` 默认判为残留安装目录，不应作为正式插件加载；清理必须用户确认。

### 11.3 Offline 策略

无网络时：

- 仅观察可用。
- App 托管 preflight 可运行，但依赖安装检查可能失败。
- 已有完整 App stage cache 时允许托管。
- 缺依赖且无法下载时禁止托管。

### 11.4 不同 runtime 的隔离

必须明确隔离：

- 旧 runtime cache：`~/.openclaw/plugin-runtime-deps/...`
- App runtime cache：`~/Library/Application Support/EZRWorker/openclaw/plugin-runtime-deps/...`
- 插件自身依赖：`~/.openclaw/extensions/<plugin>/node_modules`

UI 不应把“旧 runtime 已有依赖”显示成“App runtime 可用”。

## 12. 接管流程

### 12.1 仅观察导入

步骤：

1. 扫描候选。
2. 生成 profile：`managementMode=observeOnly`。
3. `autoStart=false`。
4. 记录 LaunchAgent 为 pending/notRequired 说明，但不禁用。
5. reload supervisor profiles。
6. refresh runtime。
7. 如果旧 Gateway 健康，显示“由旧 LaunchAgent 管理，App 仅观察”。

失败处理：

- 只影响 App profile 记录。
- 不影响旧 OpenClaw。

### 12.2 App runtime 接管

前置条件：

- 用户明确选择高级接管。
- preflight 没有 blocker。
- App runtime deps 已在临时目录准备完成。
- rollback transaction 已落盘。

步骤：

1. 记录旧 LaunchAgent、plist、端口、监听 PID、旧 runtime descriptor。
2. 保存 profiles.json 快照。
3. 准备 App runtime deps。
4. 禁用旧 LaunchAgent，但不要删除 plist，只改名或备份。
5. 停止旧 PID。
6. 启动 App runtime。
7. 等待目标端口监听。
8. 等待 health ready。
9. 验证监听 PID 是 App 启动的 PID。
10. 提交 transaction。
11. profile 切换为 App 托管。

失败处理：

1. 停止 App 启动的 PID。
2. 恢复旧 plist。
3. `launchctl enable/bootstrap/kickstart` 旧 LaunchAgent。
4. 等待旧端口监听。
5. profile 降级为 observeOnly。
6. UI 显示“接管失败，已恢复旧 OpenClaw”。

### 12.3 旧 runtime 托管

未来模式：

1. 从旧 LaunchAgent 提取启动命令。
2. App Supervisor 使用该命令启动。
3. App 可控制生命周期，但不切 App runtime。
4. 仍需要禁用旧 LaunchAgent，避免双管理。

优点：

- 对 legacy 环境最兼容。
- 不需要迁移插件依赖。

风险：

- 旧 runtime 可能来自 dev checkout，稳定性不可控。
- App 更新无法保证旧 runtime 兼容。
- 需要更强的命令白名单和路径校验。

## 13. 回滚设计

### 13.1 回滚触发条件

- App runtime 进程启动失败。
- readiness timeout。
- health check failed。
- 端口监听 PID 不匹配。
- plugin blocker 失败。
- 用户取消接管。
- App 崩溃后检测到未完成 transaction。

### 13.2 回滚动作

必须按顺序：

1. 停止 App-owned PID。
2. 确认目标端口释放。
3. 恢复旧 LaunchAgent plist。
4. `launchctl enable`。
5. `launchctl bootstrap`。
6. `launchctl kickstart -k`。
7. 等待旧 PID 监听端口。
8. 恢复 profile 为 observeOnly。
9. 标记 transaction rollback succeeded。

### 13.3 回滚失败

如果回滚失败：

- UI 必须给出完整手动命令。
- 不隐藏 transaction 状态。
- 保留原 plist backup path、disabled path、label、port。
- 不继续尝试 App runtime 自动重启。

## 14. UI 设计

### 14.1 导入页

候选卡片显示：

- 当前管理者：旧 LaunchAgent / App Supervisor / 外部进程 / 未知。
- 当前 runtime：旧 runtime / App runtime / 未知。
- 端口监听 PID。
- 旧 LaunchAgent label/path。
- 风险等级。
- 推荐动作。

默认按钮：

- “仅观察并继续使用旧 OpenClaw”

高级按钮：

- “运行接管检查”
- “迁移到 App 托管”
- “使用旧 runtime 托管”

### 14.2 设置页 Profile 卡片

必须显示：

- `管理模式：仅观察/托管`
- `生命周期所有者：旧 LaunchAgent/App Supervisor/外部`
- `Runtime：旧 runtime/App 内置 runtime`
- `监听 PID`
- `LaunchAgent 状态`
- `接管检查结果`

仅观察 profile：

- 隐藏启动、重启、停止。
- 显示“由外部管理，App 不控制生命周期”。
- 提供“运行接管检查”。

托管 profile：

- 启动/停止/重启可用。
- 若存在未解决 LaunchAgent handoff，启动按钮禁用。

### 14.3 错误弹窗

错误弹窗必须包含：

- 失败阶段。
- 精确错误。
- 已执行动作。
- 是否已回滚。
- 下一步建议。
- 诊断日志路径。

示例：

```text
接管失败，已恢复旧 OpenClaw

失败阶段：App runtime 插件预加载
原因：telegram 缺少 @grammyjs/runner
已恢复：旧 LaunchAgent ai.openclaw.gateway 已重新启动，18789 已监听
当前模式：仅观察
```

## 15. 代码改造建议

### 15.1 第一阶段：安全默认值

必须尽快改：

- `.legacyReuse` 默认 management mode 改为 `.observeOnly`，或 migration flow 显式传入 `.observeOnly`。
- `completeLegacyReuseMigration()` 不应创建 autoStart true 的托管 profile。
- `importLegacyProfile()` 应支持传入 `managementMode`，默认 observeOnly。
- 仅观察 profile 禁止 start/restart/stop/handoff。
- 设置页按钮文案从“复用旧...”改为“仅观察旧 OpenClaw”。

### 15.2 第二阶段：PreflightReport

新增：

- `OpenClawCompatibilityPreflightService`
- `CompatibilityReport`
- `PluginInventoryScanner`
- `RuntimeDependencyPreflightService`
- `LaunchAgentPreflightService`

产物：

- UI 可展示报告。
- 报告可写入 profile 或独立 json。

### 15.3 第三阶段：事务化 handoff

新增：

- `HandoffTransactionStore`
- `HandoffRollbackService`
- `LaunchAgentRestoreService`

修改：

- `LaunchAgentHandoffService.disable` 只做 transaction 的一个 step。
- 禁用旧 LaunchAgent 前必须写 transaction。
- App 启动失败必须自动 rollback。

### 15.4 第四阶段：RuntimeMode

新增：

- `GatewayProfileRuntimeMode`
- `LegacyRuntimeDescriptor`

修改：

- Supervisor start 根据 runtime mode 选择 App bundled 或 external command。
- UI 清晰展示 runtime mode。

## 16. 测试计划

### 16.1 单元测试

- legacy profile 默认 observeOnly。
- observeOnly 强制 autoStart false。
- observeOnly 禁止 start/restart/stop。
- LaunchAgent 匹配 config/state。
- LaunchAgent disabled path 唯一。
- CompatibilityReport blocker 判断。
- Runtime deps retained manifest 合并。
- duplicate plugin id 检测。
- `.openclaw-install-stage-*` 检测。

### 16.2 集成测试

使用 fake runtime 和 fake LaunchAgent：

- 已运行旧 Gateway，导入仅观察，不停止旧进程。
- 已运行旧 Gateway，App 接管 preflight 成功，接管成功。
- App runtime 启动失败，自动恢复旧 LaunchAgent。
- App runtime 插件失败，自动恢复旧 LaunchAgent。
- 旧 LaunchAgent 需要管理员权限，禁止自动接管。
- 端口被第三方占用，禁止接管。
- 旧 plist 缺失，按 notRequired 处理。
- App 崩溃后重启，继续 rollback。

### 16.3 手工 QA 矩阵

维度：

- 新机器，无 OpenClaw。
- 旧机器，有 `~/.openclaw/openclaw.json`，无 LaunchAgent。
- 旧机器，有 user LaunchAgent。
- 旧机器，有 system LaunchAgent。
- 旧机器，有 dev checkout runtime。
- 旧机器，有 npm global runtime。
- 旧机器，有 Telegram。
- 旧机器，有飞书。
- 旧机器，有企微。
- 旧机器，有自定义插件。
- 网络断开。
- npm registry 慢或失败。
- 端口冲突。
- Apple Silicon / Intel。

## 17. 边界条件

### 17.1 已有 OpenClaw 正在跑

默认仅观察。接管必须先确认旧 PID 与候选匹配，并准备 rollback。

### 17.2 已有 OpenClaw 没在跑，但有 LaunchAgent

仍默认仅观察。不能因为 PID nil 就默认托管。LaunchAgent 可能在下次登录启动。

### 17.3 有多个 OpenClaw

每个 candidate 独立 profile，独立端口，独立管理模式。禁止批量接管。

### 17.4 端口缺失

如果 config 读不到 port：

- 仅观察可导入，但显示“端口未知”。
- 托管前必须明确端口。

### 17.5 plist 不可写

托管 blocker。仅观察允许。

### 17.6 system LaunchAgent

托管 blocker，除非用户手动执行管理员命令并重新 preflight。

### 17.7 旧 runtime 是 dev checkout

仅观察推荐。App runtime 接管必须额外提示版本差异。旧 runtime 托管必须记录 checkout 路径风险。

### 17.8 插件残留临时目录

`.openclaw-install-stage-*` 默认 warning 或 blocker：

- 仅观察不处理。
- 托管前建议清理或忽略。
- 自动清理必须有备份和确认。

### 17.9 依赖安装需要网络

如果无网络且 App stage cache 不完整，App runtime 接管 blocker。

### 17.10 App 更新

App 更新后 App runtime 版本变化，已有 App 托管 legacy profile 需要重新 preflight。不能盲目继续 autoStart。

### 17.11 用户手动修改 profiles.json

启动时 validate profile document。发现不一致时：

- 不自动接管。
- 降级观察。
- 提示修复。

### 17.12 App 和旧 LaunchAgent 同时存在

如果 App-owned PID 和 LaunchAgent PID 同时存在：

- 标记 conflict。
- 禁止自动 stop 非 App-owned PID，除非用户明确恢复或接管。
- UI 提供“恢复旧 LaunchAgent”或“停止 App 托管进程”。

## 18. 恢复工具

建议新增“恢复旧 OpenClaw”按钮，仅对 legacy/external profile 展示。

功能：

1. 停止 App-owned PID。
2. 恢复 disabled plist。
3. enable/bootstrap/kickstart 旧 LaunchAgent。
4. profile 改为 observeOnly。
5. refresh runtime。

必须展示将执行的动作，并写恢复日志。

## 19. 观测与诊断

新增诊断面板：

- profile id
- config path
- state dir
- workspace
- port
- listener PID
- owner
- runtime mode
- node path
- openclaw entry
- launch agent path
- handoff transaction
- last preflight report
- last rollback result

日志要求：

- 每个 handoff transaction 有 id。
- 每个 step 有 started/succeeded/failed。
- 错误保留 stderr/stdout 摘要。
- 敏感值脱敏。

## 20. 分阶段落地

### Phase 0：止血

- legacy 默认 observeOnly。
- 禁止首次导入时自动托管。
- 禁止未 preflight 的 handoff。
- 增加“恢复旧 OpenClaw”手动动作。
- 改 UI 文案，消除“复用旧的”歧义。

### Phase 1：诊断

- 接入 CompatibilityReport。
- 接管按钮必须先跑 preflight。
- 报告支持复制。

### Phase 2：事务化接管

- HandoffTransaction 落盘。
- 自动 rollback。
- App 崩溃后继续 rollback。

### Phase 3：依赖 stage 加固

- 完整 retained manifest。
- 临时 root 安装。
- 原子 promote。
- 无网络 blocker。
- external plugin deps 检查。

### Phase 4：旧 runtime 托管

- LegacyRuntimeDescriptor。
- Supervisor 支持 externalCommand runtime。
- 安全白名单和路径校验。

## 21. 验收标准

### 21.1 首次安装旧机器

- App 发现旧 OpenClaw。
- 默认仅观察。
- 旧 LaunchAgent 不变。
- 旧 Gateway 不重启。
- App 能显示旧 Gateway 状态。

### 21.2 用户误点导入

- 不会停旧服务。
- 不会换 runtime。
- 不会改旧 config。

### 21.3 用户选择接管但 preflight 失败

- 旧服务不变。
- UI 显示 blocker。
- 无 plist 改名。

### 21.4 接管启动失败

- 自动恢复旧 LaunchAgent。
- 端口回到旧 runtime。
- profile 回到 observeOnly。
- UI 明确显示已回滚。

### 21.5 接管成功

- 旧 LaunchAgent disabled。
- App PID 监听目标端口。
- Gateway health ready。
- profile 显示 App runtime。
- transaction committed。

## 22. 立即建议

短期必须先做：

1. 把 legacy 初次导入默认改成 observeOnly。
2. 把“复用旧的”文案改成“仅观察旧 OpenClaw”。
3. App 托管接管入口前置 preflight。
4. 增加恢复旧 LaunchAgent 的自动化按钮。
5. 禁止接管失败后停留在半交接状态。

这五项完成前，不应把已有 OpenClaw 的机器默认导向 App 托管。
