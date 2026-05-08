---
name: OpenClaw LaunchAgent Handoff To EZRWorker Supervisor
overview: 为已存在的 OpenClaw LaunchAgent 增加显式交接流程，在用户选择由 EZRWorker 托管旧实例时，安全停用旧 launchd job，避免双 supervisor、重复拉起、端口冲突和 runtime 版本不一致。
todos:
  - id: phase1-launch-agent-model
    content: "Phase 1: 扩展 LaunchAgent 发现模型，记录 plist 路径、label、domain、KeepAlive、RunAtLoad、匹配依据和权限状态"
    status: pending
  - id: phase2-import-handoff-ui
    content: "Phase 2: 在导入页增加交接确认；有旧 LaunchAgent 的候选默认仅观察，切换托管时要求处理旧自启项"
    status: pending
  - id: phase3-handoff-service
    content: "Phase 3: 实现 LaunchAgentHandoffService，支持 bootout、disable、plist 备份改名、恢复和权限分支"
    status: pending
  - id: phase4-supervisor-guard
    content: "Phase 4: Supervisor 启动托管外部实例前检查旧 LaunchAgent 交接状态，阻止双重托管"
    status: pending
  - id: phase5-verification
    content: "Phase 5: 增加状态展示、日志、手动修复指引和回归验收"
    status: pending
isProject: false
---

# 旧 OpenClaw LaunchAgent 交接到 EZRWorker 托管技术方案

## 一、结论：打算怎么做

做成一个明确的“交接旧自启项”流程。

核心原则：

1. **仅观察模式不动旧 LaunchAgent**。
2. **托管模式必须处理旧 LaunchAgent**，否则不允许 EZRWorker 启动该 profile。
3. App 不偷偷停服务，必须让用户看到将要禁用的 plist、label、路径和影响。
4. 对用户 Home 下的 plist，App 直接 `bootout + disable + 改名 .disabled`。
5. 对 `/Library/LaunchAgents` 下 root-owned plist，走管理员授权或给出手动命令。
6. 每次操作前都重新校验 plist 是否仍然匹配当前 OpenClaw config/state，避免误停别的服务。

这次改动属于中等规模。重点不是启动 gateway，而是把“旧启动链路”安全退出，避免出现两个 supervisor 抢同一个 gateway。

## 二、背景

当前已经支持导入外部 OpenClaw 实例：

- 扫描运行中 gateway
- 扫描 `~/.openclaw`
- 扫描常见 `.openclaw*` 目录
- 扫描 `~/Library/LaunchAgents` 和 `/Library/LaunchAgents` 中的 OpenClaw plist
- 导入后可选择 `仅观察` 或 `托管`

但现在还有一个缺口：

如果外部实例原来由旧 LaunchAgent 启动，例如：

```text
~/Library/LaunchAgents/com.openclaw.gateway3.plist
/Library/LaunchAgents/com.openclaw.gateway4.plist
```

并且该 plist 有：

```text
RunAtLoad = true
KeepAlive = true
```

那么用户把它导入 EZRWorker 并选择“托管”后，会出现两个生命周期管理者：

```text
旧 LaunchAgent          -> openclaw-gateway
EZRWorkerSupervisor    -> openclaw gateway
```

这会造成停止失效、重启抢跑、端口冲突、版本不一致、机器重启后又回到旧 runtime 等问题。

因此需要显式交接。

## 三、目标

1. 扫描阶段识别某个候选实例是否由旧 LaunchAgent 管理。
2. 导入页明确展示：
   - plist label
   - plist 路径
   - 是否 `KeepAlive`
   - 是否 `RunAtLoad`
   - 是否需要管理员权限
   - 与当前 config/state 的匹配依据
3. 对带旧 LaunchAgent 的候选：
   - 默认选择 `仅观察`
   - 如果用户选择 `托管`，必须先完成交接或选择手动处理
   - 用户点击交接后，用户态 plist 交接成功时自动由 EZRWorker 启动或重启该 profile，不再要求用户额外点击“启动/重启”
4. 交接动作要可回滚：
   - 停止已加载的 launchd job
   - 禁用 job
   - 把 plist 改名为 `.disabled-<timestamp>`
   - 记录备份路径
5. EZRWorkerSupervisor 在启动托管外部 profile 前做二次保护：
   - 如果发现匹配的旧 LaunchAgent 仍然启用，拒绝启动并提示先交接
6. 不影响仅观察模式。

## 四、非目标

- 不自动删除旧 plist。
- 不默认处理其他 macOS 用户的 LaunchAgent。
- 不强行接管 root daemon 或 `/Library/LaunchDaemons`。
- 不修改 OpenClaw 自身的 launchd 检测逻辑。
- 不把“仅观察”变成托管；仅观察仍由旧 LaunchAgent 或用户原启动方式负责。

## 五、用户流程

### 5.1 扫描到旧 LaunchAgent

用户点击：

```text
设置 -> Profiles -> 扫描已有 OpenClaw
```

候选项显示：

```text
来源：LaunchAgent
Label：com.openclaw.gateway3
Plist：~/Library/LaunchAgents/com.openclaw.gateway3.plist
KeepAlive：是
RunAtLoad：是
匹配：OPENCLAW_STATE_DIR=/Users/macmini/.openclaw3/.openclaw
风险：需确认
```

默认模式：

```text
仅观察
```

### 5.2 用户选择仅观察

行为：

- 写入 EZRWorker profile 记录
- 不停旧 LaunchAgent
- 不启动、不停止、不重启 gateway
- App 只连接已有 gateway，展示状态

这是最安全路径。

### 5.3 用户选择托管

UI 展示交接确认：

```text
此实例当前由旧 LaunchAgent 自动启动。
如果由 EZRWorker 托管，需要先禁用旧自启项，避免两个 supervisor 同时拉起 Gateway。

将执行：
1. launchctl bootout gui/<uid> <plist>
2. launchctl disable gui/<uid>/<label>
3. 将 plist 改名为 <plist>.disabled-YYYYMMDD-HHMMSS
```

用户确认后：

1. App 再次读取 plist，确认它仍然匹配当前候选。
2. App 停用旧 job。
3. App 改名 plist。
4. App 导入 profile 为 `externalReuse + managedByEZRWorker`。
5. App 调用 supervisor reload。
6. 用户点击启动或 App 按 autoStart 启动。

启动后预期：

```text
ownership = supervised
runtime = App 内置 Node/OpenClaw
config/state = 外部旧实例目录
```

## 六、数据模型设计

### 6.1 LaunchAgent 信息模型

新增：

```swift
struct OpenClawLaunchAgentInfo: Codable, Hashable {
    var label: String
    var plistPath: String
    var domain: LaunchAgentDomain
    var programArguments: [String]
    var environment: [String: String]
    var workingDirectory: String?
    var keepAlive: Bool
    var runAtLoad: Bool
    var isLoaded: Bool?
    var isWritableByCurrentUser: Bool
    var requiresAdminForDisable: Bool
    var matchedConfigPath: String?
    var matchedStateDir: String?
    var matchReason: String
}

enum LaunchAgentDomain: String, Codable {
    case user
    case systemLaunchAgent
}
```

扩展候选：

```swift
struct OpenClawInstanceCandidate {
    ...
    var launchAgent: OpenClawLaunchAgentInfo?
}
```

当前已有 `launchdLabel`，后续可以保留兼容，但新逻辑应使用完整 `launchAgent`。

### 6.2 Profile 记录交接来源

托管外部 profile 建议记录一次交接结果：

```swift
struct GatewayProfileLaunchAgentHandoff: Codable, Hashable {
    var originalLabel: String
    var originalPlistPath: String
    var disabledPlistPath: String?
    var disabledAt: Date?
    var status: LaunchAgentHandoffStatus
}

enum LaunchAgentHandoffStatus: String, Codable {
    case notRequired
    case pending
    case disabled
    case manualRequired
    case failed
}
```

扩展：

```swift
struct GatewayProfile {
    ...
    var launchAgentHandoff: GatewayProfileLaunchAgentHandoff?
}
```

这样设置页能显示“这个 profile 曾从哪个旧 LaunchAgent 交接而来”，也方便恢复。

## 七、LaunchAgent 匹配规则

导入候选和 plist 的关联必须保守。

### 7.1 高置信匹配

满足任一条件：

1. plist `EnvironmentVariables.OPENCLAW_CONFIG_PATH` 等于候选 `configPath`
2. plist `EnvironmentVariables.OPENCLAW_STATE_DIR` 等于候选 `stateDir`
3. `ProgramArguments` 中包含候选 `configPath`
4. `WorkingDirectory` 指向候选 `stateDir`
5. plist 推导出的 `openclaw.json` 等于候选 `configPath`

### 7.2 中置信匹配

满足任一条件：

1. plist label 包含 `openclaw` 和 `gateway`
2. plist Program/Arguments 包含 `openclaw-gateway`
3. plist WorkingDirectory 位于 `.openclaw*` 路径

中置信匹配只允许展示和“仅观察”，切到“托管”前必须让用户手动确认路径。

### 7.3 禁止匹配

以下情况不允许自动交接：

- label 是 `ai.ezrworker.mac.supervisor`
- plist Program 指向 `EZRWorkerSupervisor`
- plist 不包含任何 OpenClaw/gateway 特征
- config/state 无法确定
- plist 路径不在：

```text
~/Library/LaunchAgents
/Library/LaunchAgents
```

## 八、交接服务设计

新增：

```text
EZRWorkerApp/EZRWorker/Services/LaunchAgentHandoffService.swift
```

核心 API：

```swift
enum LaunchAgentHandoffService {
    static func inspect(_ info: OpenClawLaunchAgentInfo) async -> LaunchAgentInspection

    static func disable(
        _ info: OpenClawLaunchAgentInfo,
        expectedConfigPath: String,
        expectedStateDir: String
    ) async throws -> LaunchAgentHandoffResult

    static func restore(_ result: LaunchAgentHandoffResult) async throws
}
```

### 8.1 inspect

检查：

- plist 是否还存在
- plist 是否仍匹配 config/state
- job 是否已 loaded
- 当前用户是否能写 plist
- 是否需要管理员权限

读取：

```text
launchctl print gui/<uid>/<label>
```

如果 print 失败，不代表不能禁用，只说明当前没加载或 label 不在该 domain。

### 8.2 disable

对 `~/Library/LaunchAgents`：

```text
launchctl bootout gui/<uid> <plist-path>
launchctl disable gui/<uid>/<label>
mv <plist-path> <plist-path>.disabled-YYYYMMDD-HHMMSS
```

对 `/Library/LaunchAgents`：

优先：

```text
launchctl bootout gui/<uid> <plist-path>
```

如果改名需要 root，则走管理员授权：

```text
osascript -e 'do shell script "mv ... ..." with administrator privileges'
```

如果用户取消授权：

```text
handoff.status = manualRequired
```

并展示手动命令。

### 8.3 restore

恢复流程：

```text
mv <disabled-plist> <original-plist>
launchctl bootstrap gui/<uid> <original-plist>
launchctl enable gui/<uid>/<label>
launchctl kickstart -k gui/<uid>/<label>
```

恢复入口可以先放在设置页“高级操作”里，不一定第一版就做主流程 UI。

## 九、Supervisor 保护

仅靠导入 UI 不够，因为用户可能导入后又手动恢复旧 plist。

在 `EZRWorkerSupervisor` 启动托管外部 profile 前增加检查：

```text
if profile.sourceKind == .externalReuse
   && profile.managementMode == .managedByEZRWorker
   && matching old OpenClaw LaunchAgent still loaded/enabled {
       refuse start
       lastError = "检测到旧 LaunchAgent 仍在管理该 OpenClaw，请先交接或禁用旧自启项"
   }
```

检查位置：

- `performStartProfile` 中，真正启动前
- `existingGatewayDisposition` 中，遇到端口已占用且进程来自旧 LaunchAgent 时，给出明确错误

注意：Supervisor 运行在用户态，读取 `/Library/LaunchAgents` 可以，改写可能不行。因此 Supervisor 只做阻止和提示，不做管理员授权。

## 十、UI 设计

### 10.1 导入页候选卡

增加信息：

```text
旧自启项：com.openclaw.gateway3
路径：~/Library/LaunchAgents/com.openclaw.gateway3.plist
KeepAlive：开启
RunAtLoad：开启
建议：仅观察，或先交接后托管
```

模式选择：

```text
[仅观察] [托管]
```

如果候选有旧 LaunchAgent，选择“托管”后展开交接区：

```text
由 EZRWorker 托管前，需要禁用旧 LaunchAgent。
[交接并启动]
[我已手动禁用，重新检查]
```

### 10.2 设置页 Profile 卡

对外部托管 profile 显示：

```text
托管状态：EZRWorker
旧自启项：已禁用 com.openclaw.gateway3
```

如果检测到旧 LaunchAgent 仍在：

```text
风险：旧 LaunchAgent 仍启用，可能导致双重拉起
[交接并启动] 或 [交接并重启]
```

### 10.3 错误提示

典型错误：

```text
旧 LaunchAgent 仍启用，EZRWorker 暂不启动该 Profile。请先交接旧自启项，或改为仅观察模式。
```

权限错误：

```text
该 plist 位于 /Library/LaunchAgents，需要管理员权限才能改名禁用。
```

## 十一、手动命令兜底

用户态 plist：

```bash
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.gateway3.plist
launchctl disable gui/$(id -u)/com.openclaw.gateway3
mv ~/Library/LaunchAgents/com.openclaw.gateway3.plist ~/Library/LaunchAgents/com.openclaw.gateway3.plist.disabled
```

系统 LaunchAgents：

```bash
sudo launchctl bootout gui/$(id -u) /Library/LaunchAgents/com.openclaw.gateway3.plist
sudo mv /Library/LaunchAgents/com.openclaw.gateway3.plist /Library/LaunchAgents/com.openclaw.gateway3.plist.disabled
```

恢复：

```bash
mv ~/Library/LaunchAgents/com.openclaw.gateway3.plist.disabled ~/Library/LaunchAgents/com.openclaw.gateway3.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.openclaw.gateway3.plist
launchctl enable gui/$(id -u)/com.openclaw.gateway3
launchctl kickstart -k gui/$(id -u)/com.openclaw.gateway3
```

## 十二、实施步骤

### Phase 1：扩展发现模型

改动：

- `Shared/GatewayProfiles.swift`
- `OpenClawInstanceDiscoveryService.swift`

内容：

- 新增 `OpenClawLaunchAgentInfo`
- 候选项记录 plist 路径、label、domain、KeepAlive、RunAtLoad
- 解析 `Program`、`ProgramArguments`、`EnvironmentVariables`、`WorkingDirectory`
- 标记 `requiresAdminForDisable`

验收：

- `com.openclaw.gateway2.plist`
- `com.openclaw.gateway3.plist`
- `com.openclaw.gateway4.plist`

能在扫描列表中显示，并带完整 plist 信息。

### Phase 2：导入页交接 UX

改动：

- `ExistingOpenClawImportView.swift`
- `GatewayProfileStore.swift`

内容：

- 有旧 LaunchAgent 的候选默认 `observeOnly`
- 切 `managedByEZRWorker` 时显示交接确认
- 未完成交接时不允许直接导入为托管
- 导入结果记录 `launchAgentHandoff`

验收：

- 仅观察导入不动旧 plist
- 托管导入必须完成交接或显示手动处理状态

### Phase 3：LaunchAgentHandoffService

新增：

- `EZRWorkerApp/EZRWorker/Services/LaunchAgentHandoffService.swift`

内容：

- inspect
- disable
- restore
- path 安全校验
- launchctl 执行封装
- 管理员授权分支

验收：

- 用户态 plist 能被 bootout 并改名
- `/Library/LaunchAgents` 权限不足时给出管理员授权或手动命令
- 操作失败不会创建半交接 profile

### Phase 4：Supervisor 二次保护

改动：

- `SupervisorController+Lifecycle.swift`
- `SupervisorController+GatewayProcess.swift`
- 可选新增共享 LaunchAgent 解析工具

内容：

- 托管外部 profile 启动前检查旧 LaunchAgent 是否仍在
- 如果仍在，拒绝启动并提示
- 仅观察模式不阻止

验收：

- 用户手动恢复旧 plist 后，EZRWorker 不会再启动第二个 gateway
- 错误消息能说明具体旧 label 和 plist

### Phase 5：回归和日志

内容：

- `os_log` 记录交接动作
- 设置页显示交接结果
- 增加手动恢复说明
- 跑 Debug/Release 构建

## 十三、验收场景

### 场景 A：仅观察旧 LaunchAgent

前置：

```text
com.openclaw.gateway3.plist loaded + KeepAlive
```

操作：

```text
扫描 -> 导入 -> 仅观察
```

期望：

- plist 不变
- gateway 继续由旧 LaunchAgent 运行
- EZRWorker 显示 adopted/仅观察
- 停止/重启按钮不可用

### 场景 B：托管并交接用户态 plist

操作：

```text
扫描 -> 选择托管 -> 交接旧 LaunchAgent -> EZRWorker 自动启动/重启
```

期望：

- `launchctl print gui/<uid>/<label>` 不再显示 loaded job
- plist 改名 `.disabled-<timestamp>`
- EZRWorker 自动启动 gateway；如果该 profile 已经运行，则自动重启 gateway
- ownership 为 `supervised`

### 场景 C：旧 plist 被手动恢复

操作：

```text
恢复旧 plist -> launchctl bootstrap -> 在 EZRWorker 点启动
```

期望：

- EZRWorker 拒绝启动
- 显示“旧 LaunchAgent 仍启用”
- 不产生第二个 gateway

### 场景 D：系统路径需要权限

前置：

```text
/Library/LaunchAgents/com.openclaw.gateway4.plist
```

期望：

- UI 提示需要管理员权限
- 用户取消时进入 `manualRequired`
- 不误导为已交接

## 十四、风险与对策

### 14.1 误停非目标 LaunchAgent

对策：

- 只处理 OpenClaw/gateway 特征明确的 plist
- 操作前重新匹配 config/state
- 禁止处理 EZRWorker 自己的 supervisor label

### 14.2 权限不足导致半交接

对策：

- 先 bootout，再改名
- 每一步记录结果
- 改名失败时提示用户旧 plist 仍可能重启
- 不把 profile 标记为已交接

### 14.3 交接后用户想回滚

对策：

- 不删除 plist，只改名
- 记录 disabled 路径
- 提供恢复命令和后续 UI

### 14.4 LaunchAgent 已经停止但 plist 仍在

对策：

- 只要 plist 仍在且 `RunAtLoad/KeepAlive` 开启，托管前仍建议改名禁用
- 避免下次登录或重启后旧 job 回来

## 十五、最终标准

当一台机器有：

```text
com.openclaw.gateway.plist
com.openclaw.gateway2.plist
com.openclaw.gateway3.plist
com.openclaw.gateway4.plist
```

EZRWorker 应做到：

1. 扫描列表能展示 4 个候选。
2. 每个候选能显示对应 LaunchAgent label 和 plist 路径。
3. 默认仅观察，不改旧启动链路。
4. 用户选择托管时，必须完成交接。
5. 交接后旧 plist 不会再自动拉起 gateway。
6. 用户点击“交接并启动/交接并重启”后，不需要再手动点启动或重启。
7. EZRWorker 托管启动后 ownership 为 `supervised`。
8. 机器重启后不回到旧 LaunchAgent 启动链路。
