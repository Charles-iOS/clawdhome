---
name: Gateway Health State Machine Consolidation
overview: 收敛 EZRWorker App、Supervisor、Gateway 三层运行状态，修复登录后 supervisor 未就绪、19789 端口假活、左下角与设置页状态不一致等问题，同时延续 App 登录/激活默认非侵入式恢复的原则。
todos:
  - id: phase1-state-contract
    content: "Phase 1: 明确 SupervisorProfileRuntime 健康状态契约，拆分进程状态、端口状态、健康状态、连接状态"
    status: pending
  - id: phase2-supervisor-health-window
    content: "Phase 2: 在 SupervisorRecord 中记录 lastReadyAt/unhealthySince，并由 supervisor 判定持续不响应"
    status: pending
  - id: phase3-app-recovery-policy
    content: "Phase 3: 收紧 App recovery 策略，移除基于 readyState 的直接 restart 分支"
    status: pending
  - id: phase4-ui-state-unification
    content: "Phase 4: 统一左下角、设置页、bootstrap progress 的状态文案与颜色"
    status: pending
  - id: phase5-regression-matrix
    content: "Phase 5: 按 Debug Run、登录、激活、唤醒、端口假活、supervisor XPC 不可用等场景回归验证"
    status: pending
isProject: false
---

# Gateway 健康状态机收敛与非侵入式恢复技术方案

## 一、背景

最近几轮修复集中在同一条链路：

```text
EZRWorker App
  -> XPC 连接 EZRWorkerSupervisor
  -> HTTP/WebSocket 连接当前 profile 的 OpenClaw Gateway

EZRWorkerSupervisor
  -> 负责 prepare/start/stop/restart managed profile
  -> 负责观测 legacy/external/adopted Gateway

OpenClaw Gateway
  -> 监听 profile 端口，例如 Debug 默认 19789
  -> 提供 /health、/readyz、WebSocket、业务 RPC
```

现场出现过几个容易混在一起的现象：

- 登录完成后提示 `EZRWorkerSupervisor 未就绪`
- 重新 Run 后 App 一直连接 `19789`
- `19789` 有 Node 进程监听，但 HTTP 请求超时，WebSocket 握手超时
- 左下角显示未连接，设置页显示运行中
- Debug Run 替换 helper 后，launchd 中 supervisor 可能短时间处于未 ready、重启中或签名退出状态

这些不是一个单点 bug，而是 App、Supervisor、Gateway 三层状态没有清楚分工导致的：

- App 把“控制面 supervisor 不可用”和“业务面 gateway 不可用”混成了一类
- Supervisor 用 `readyState` 同时表达启动中、健康检查中、端口假活、失败等状态
- UI 用不同来源的数据渲染，导致状态看起来互相矛盾
- 自动恢复逻辑在少数路径里仍可能根据 `.ready`/`.starting` 这种粗状态决定 start/restart

本方案是对既有《App 登录与激活 Gateway 非侵入式恢复技术方案》的补充和收敛，不推翻前一份方案。

## 二、核心结论

### 2.1 大方向不变

App 登录、激活、解锁时默认只做非侵入式恢复：

- 连接 supervisor
- 刷新 runtime
- 读取 token
- 重连 HTTP/WebSocket
- 加载 agent/workspace/model 数据

默认不做：

- `restartProfile`
- `stopProfile`
- kill 进程
- 自动接管 external/observe-only profile

### 2.2 需要修正的边界

当前 App recovery 中存在一个临时止血逻辑：

```swift
case .ready:
    try await supervisorClient.restartProfile(profileID: selectedProfile.id)
```

它只会在 conservative recovery 路径里触发，并且会先经过多次端口不可用确认。它的目的是处理 stale ready：

```text
Supervisor 仍认为 Gateway ready
App 连接失败
端口探测连续失败
=> 重启 managed Gateway
```

但从状态机设计看，App 不应该直接根据 `readyState == .ready` 决定 restart。正确位置应该在 supervisor：

- supervisor 记录健康检查连续失败的起点
- supervisor 判断进程是否由自己管理
- supervisor 判断监听 PID 是否匹配当前 profile
- supervisor 暴露明确的“不响应/失败/停止”状态
- App 只根据恢复场景和 supervisor 的明确状态决定是否允许生命周期操作

因此本方案要求移除 App 侧基于 `.ready` 的直接 restart 分支，改为 supervisor 驱动的持续不健康判定。

## 三、术语与状态分层

### 3.1 Supervisor 可用

“supervisor 不可用”仅表示：

```text
App 通过 XPC 无法正常 ping/listProfilesRuntime/reloadProfiles
```

它不等价于：

- Gateway 进程已退出
- 端口没有监听
- WebSocket 不可连接
- 用户业务不可用

Debug Run 下 supervisor 不可用的常见原因：

- Xcode build 替换了 embedded helper，launchd 仍持有旧实例
- launchd 正在 bootstrap/kickstart，App 先启动并超时
- helper 签名、路径或 service name 切换导致旧实例退出
- XPC 连接断开，但 Gateway 子进程仍在

### 3.2 Gateway 进程状态

由 supervisor 负责判断：

- 是否有 `Process`
- `Process.isRunning`
- 当前端口监听 PID
- 监听 PID 是否匹配当前 profile 的 config/state/env
- ownership 是 `supervised`、`adopted` 还是 `none`

### 3.3 Gateway 健康状态

由 supervisor 负责判断：

- HTTP probe 是否能连通
- `/health` 或 `/readyz` 是否返回 ready
- 健康检查失败持续了多久
- 最近一次 ready 是什么时候
- 是否已经超过不健康阈值

### 3.4 App 连接状态

由 App 负责判断：

- HTTP token 是否可读
- `GatewayService` 当前配置端口是否正确
- WebSocket 是否已连接
- pending RPC 是否超时
- socket 断开后是否已清理旧 session

App 连接状态不能反推 Gateway 生命周期状态。  
例如：WebSocket 未连接，可能只是 App socket 断了；Gateway 本身可能健康。

## 四、目标

1. 登录后 supervisor 慢启动时，App 不误判 Gateway 已失败
2. supervisor XPC 暂时不可用时，App 可以尝试直接连接健康 Gateway
3. `19789` 端口有监听但不响应时，不显示为 ready
4. Gateway 端口假活不能永久卡在 starting
5. App 不再基于 `.ready`/`.starting` 这种粗状态直接 restart
6. 用户手动停止的 profile 不被自动拉起
7. external / observe-only profile 不被自动 restart
8. 左下角、设置页、bootstrap progress 使用同一套状态含义
9. Debug Run、正式安装版、managed、legacy、external profile 都有明确边界

## 五、非目标

- 不取消用户手动 start/stop/restart 能力
- 不移除 supervisor 的 `restartProfile` API
- 不改变 OpenClaw Gateway 内部实现
- 不把每个 profile 改成独立 LaunchAgent
- 不在 App 侧用 kill/lsof 等方式直接管理 Gateway
- 不在登录/激活路径里恢复 aggressive restart 行为

## 六、现状问题

### 6.1 `readyState` 承载过多含义

当前共享模型：

```swift
enum SupervisorReadyState: String, Codable {
    case unknown
    case stopped
    case preparing
    case starting
    case ready
    case failed
}
```

问题是：

- `starting` 可能表示刚启动
- `starting` 也可能表示端口已监听但健康检查不响应
- `ready` 可能是历史快照
- `failed` 可能是启动失败，也可能是端口被其他进程占用
- `isRunning == true` + `readyState == starting` 不能区分“正常启动中”和“长时间假活”

### 6.2 SupervisorRecord 缺少时间窗口

当前 `SupervisorRecord` 有：

```swift
var lastProbeAt: Date?
var lastError: String?
var lastLifecycleMessage: String?
```

但没有：

- `lastReadyAt`
- `unhealthySince`
- `lastHealthyProbeAt`
- `lastUnhealthyReason`
- `userStoppedAt` 或等价的 manual stop 标记

导致 supervisor 只能看到“这次 probe 失败”，无法判断“已经连续失败多久”。

### 6.3 App Recovery 仍有状态泄漏

App recovery 已经区分：

```swift
appActivated / screenUnlocked => reconnectOnly
systemWake / reconnectLoop    => conservativeStart
```

这是对的。

但 conservativeStart 后半段仍有：

```text
runtime.readyState == ready
端口多次探测失败
=> restartProfile
```

这个判断应该改成：

```text
runtime.health == unresponsive
runtime.unhealthyDuration >= threshold
profile managed
trigger allows lifecycle operation
=> restartProfile
```

### 6.4 UI 同时展示了不同层的状态

左下角更接近 App WebSocket 状态。  
设置页更接近 supervisor runtime 状态。

因此会出现：

```text
左下角：未连接
设置页：运行中
```

这两个状态都可能是真的，但缺少分层说明。用户看到的是矛盾。

## 七、目标状态模型

### 7.1 保持兼容的共享模型扩展

为降低改动风险，短期不直接删除 `SupervisorReadyState`，而是在 `SupervisorProfileRuntime` 增加辅助字段：

```swift
enum SupervisorHealthState: String, Codable {
    case unknown
    case noProcess
    case launching
    case portListening
    case healthy
    case unresponsive
    case failed
}
```

建议新增字段：

```swift
var healthState: SupervisorHealthState
var lastReadyAt: Date?
var unhealthySince: Date?
var lastHealthyProbeAt: Date?
var lastUnhealthyReason: String?
var userStoppedAt: Date?
```

短期兼容策略：

- 老 UI 继续使用 `readyState`
- 新 recovery 逻辑优先使用 `healthState`
- `readyState` 由 `healthState` 映射生成
- XPC JSON 编解码保持向后兼容，新增字段给默认值

### 7.2 状态含义

```text
noProcess
  没有子进程，也没有匹配当前 profile 的监听 PID

launching
  supervisor 刚启动进程，仍在等待端口或健康检查

portListening
  端口有匹配当前 profile 的 Gateway PID，但 /readyz 尚未 ready
  这是短期可接受状态

healthy
  HTTP probe ready，Gateway 可服务

unresponsive
  端口有监听或进程仍在，但健康检查连续失败超过阈值
  这是端口假活/进程卡死的明确状态

failed
  启动失败、端口被其他进程占用、配置缺失、进程异常退出等终态错误
```

### 7.3 `readyState` 映射

```text
healthState.noProcess      -> stopped
healthState.launching      -> starting
healthState.portListening  -> starting
healthState.healthy        -> ready
healthState.unresponsive   -> failed 或 starting
healthState.failed         -> failed
```

推荐短期将 `unresponsive` 映射为 `.failed`，并用 `lastLifecycleMessage` 表达：

```text
Gateway 进程运行中，但健康检查已连续 90 秒无响应
```

这样 App 可以在 conservativeStart 中按 `.failed` 或 `healthState.unresponsive` 统一处理，不会永远卡在 `.starting`。

如果担心 `.failed` 太强，可以先保持 `.starting`，但必须新增 `healthState == .unresponsive` 供 App 判断。

## 八、Supervisor 侧设计

### 8.1 新增记录字段

在 `SupervisorRecord` 中增加：

```swift
var healthState: SupervisorHealthState = .unknown
var lastReadyAt: Date?
var unhealthySince: Date?
var lastHealthyProbeAt: Date?
var lastUnhealthyReason: String?
var userStoppedAt: Date?
```

辅助方法：

```swift
func markHealthy(now: Date)
func markUnhealthy(now: Date, reason: String)
func clearManualStopMarker()
func markManuallyStopped(now: Date)
```

### 8.2 健康时间阈值

建议阈值：

```swift
static let gatewayUnresponsiveThreshold: TimeInterval = 90
static let gatewayFreshLaunchGracePeriod: TimeInterval = 180
```

含义：

- 新启动后的 180 秒内，端口未 ready 仍可显示 `launching` 或 `portListening`
- 曾经 ready 过的进程，如果健康检查连续失败 90 秒，则标记 `unresponsive`
- 未曾 ready 过但已经超过启动等待上限，则标记 `failed`

Debug 首次启动插件依赖较慢，因此 fresh launch grace 不应短于现有等待上限。

### 8.3 Managed profile 刷新逻辑

`refreshManagedRuntimeSnapshot` 的目标逻辑：

```text
probe ready
  -> healthState = healthy
  -> readyState = ready
  -> clear unhealthySince

probe alive but not ready
  -> pid 匹配
  -> within grace/threshold: portListening 或 launching
  -> over threshold: unresponsive

probe not alive, supervised process still running
  -> 如果进程刚启动: launching
  -> 如果已超过阈值: unresponsive

probe not alive, matching listening PID exists
  -> portListening 或 unresponsive

no process, no matching pid
  -> stopped
```

关键点：

- 即使 HTTP probe 失败，也要查端口监听 PID
- 端口监听 PID 必须匹配当前 profile
- 不匹配则是端口占用，不是 adopted healthy gateway
- `unhealthySince` 第一次失败时设置，恢复 healthy 时清空

### 8.4 Legacy / External profile 边界

legacy / external 可以观测健康状态，但不能自动 restart：

```text
sourceKind == legacyReuse
  可以 adopted，可以显示 unresponsive
  自动恢复最多 start managed 迁移后的 profile，不直接 kill legacy

sourceKind == externalReuse
  managementMode == observeOnly 时只观测
  端口不响应也只显示异常，不 restart
```

### 8.5 用户手动停止边界

`stopProfile` 成功后：

```swift
record.userStoppedAt = Date()
record.healthState = .noProcess
record.readyState = .stopped
```

自动 recovery 遇到 `userStoppedAt != nil` 时：

- 不 start
- 不 restart
- UI 显示 `已停止`

用户手动点击 start/restart 或切换 profile 后清除该标记。

## 九、App Recovery 策略

### 9.1 Recovery mode 保持现状

```text
appActivated     -> reconnectOnly
screenUnlocked   -> reconnectOnly
systemWake       -> conservativeStart
reconnectLoop    -> conservativeStart
```

### 9.2 supervisor 不可用时

App 行为：

```text
ensureSupervisorConnected failed
  -> 使用当前 selected profile resolution/token
  -> 尝试直接 HTTP/WebSocket 连接 Gateway
  -> 成功：进入 started，加载数据，UI 标注 supervisor 未就绪
  -> 失败：保持 disconnected，不 start/restart
```

理由：

- supervisor 是控制面
- Gateway 是业务面
- 控制面短暂不可用不应打断健康 Gateway

### 9.3 reconnectOnly 路径

适用于：

- App 激活
- 屏幕解锁

允许：

- refresh runtime
- http probe
- WebSocket reconnect
- stale socket cleanup
- refresh UI state

禁止：

- startProfile
- restartProfile
- stopProfile

### 9.4 conservativeStart 路径

适用于：

- system wake
- reconnect loop

允许 start 的条件：

```text
profile.managementMode == managedByEZRWorker
runtime.healthState == noProcess
runtime.userStoppedAt == nil
confirmGatewayUnavailable == true
```

允许 restart 的条件：

```text
profile.managementMode == managedByEZRWorker
runtime.ownership == supervised
runtime.healthState == unresponsive
runtime.unhealthySince 已超过阈值
runtime.userStoppedAt == nil
confirmGatewayUnavailable == true
```

禁止 restart 的条件：

```text
trigger == appActivated
trigger == screenUnlocked
profile observe-only
runtime ownership == adopted 且无法确认由当前 profile 管理
runtime healthState == launching
runtime healthState == portListening 且未超过阈值
runtime userStoppedAt != nil
supervisor XPC 不可用
```

### 9.5 移除 App 侧 `.ready` restart

将当前逻辑：

```swift
case .ready:
    try await supervisorClient.restartProfile(profileID: selectedProfile.id)
```

替换为：

```text
case healthState == .unresponsive && recovery mode allows restart:
    supervisorClient.restartProfile(...)

case readyState == .ready:
    skip lifecycle operation; log stale runtime mismatch
```

日志建议：

```text
bootstrap: recovery skipped restart for ready runtime without supervisor unresponsive state
bootstrap: recovery restarting supervised unresponsive gateway on port 19789 after 94s unhealthy
```

## 十、UI 状态统一

### 10.1 状态来源

UI 需要同时展示两层状态：

```text
进程/健康状态：来自 SupervisorProfileRuntime
App 连接状态：来自 GatewayService.isConnected
```

不能只用其中一个覆盖另一个。

### 10.2 展示矩阵

| Supervisor health | App WebSocket | 左下角 | 设置页 |
| --- | --- | --- | --- |
| healthy | connected | 已连接 | 运行中 |
| healthy | disconnected | WebSocket 未连接 | Gateway 健康，App 未连接 |
| launching | disconnected | 启动中 | Gateway 启动中 |
| portListening | disconnected | 健康检查中 | 进程运行中，等待健康检查 |
| unresponsive | disconnected | Gateway 无响应 | 进程运行中，健康检查未响应 |
| noProcess | disconnected | 未运行 | 已停止 |
| failed | disconnected | 运行失败 | 显示 lastError |
| supervisor unavailable | connected | 已连接 | Supervisor 未就绪，Gateway 已连接 |
| supervisor unavailable | disconnected | 未连接 | Supervisor 未就绪 |

### 10.3 文案原则

避免单独显示“运行中”而隐藏连接断开。  
避免单独显示“未连接”而隐藏进程仍在。

推荐文案：

- `运行中`
- `启动中`
- `进程运行中，等待健康检查`
- `进程运行中，健康检查未响应`
- `Gateway 健康，WebSocket 未连接`
- `Supervisor 未就绪，Gateway 已连接`
- `Supervisor 未就绪，Gateway 未连接`
- `已停止`
- `运行失败`

## 十一、Bootstrap 策略

登录后首次 bootstrap 的原则：

```text
1. load profile
2. check environment
3. connect supervisor
4. reload/list runtime
5. 如果 supervisor 不可用，尝试 direct gateway reconnect
6. 如果 runtime healthy，连接 Gateway
7. 如果 runtime launching/portListening，等待 ready，不 restart
8. 如果 runtime noProcess 且 managed 且非 user stopped，才 start
9. 如果 runtime unresponsive，不在登录路径自动 restart，显示可解释状态
```

登录路径不应该做 restart。  
即使 Gateway unresponsive，也应优先展示明确状态，让 conservative recovery 或用户手动操作处理。

## 十二、日志与诊断

### 12.1 App 日志

关键日志必须包含：

- trigger
- recovery mode
- profile id/slug
- port
- supervisor connected
- runtime healthState
- readyState
- ownership
- unhealthy duration
- lifecycle decision

示例：

```text
bootstrap: recovery trigger=reconnect-loop mode=conservativeStart profile=default port=19789
bootstrap: supervisor unavailable; trying direct gateway reconnect on port 19789
bootstrap: gateway reconnect failed; runtime health=unresponsive ownership=supervised unhealthy=94s
bootstrap: recovery restarting supervised unresponsive gateway on port 19789
```

### 12.2 Supervisor 日志

关键日志必须包含：

- probe result
- listening PID
- recorded process PID
- ownership
- health transition
- unhealthySince
- final readyState

示例：

```text
supervisor: profile=default port=19789 pid=93544 health healthy -> unresponsive after 92s
supervisor: profile=default port=19789 probe failed but process still running; waiting within grace period
```

## 十三、迁移与兼容

### 13.1 XPC JSON 兼容

`SupervisorProfileRuntime` 通过 JSON 传输。新增字段应保持 Codable 兼容：

- App 新版读取老 supervisor 返回：字段给默认值
- 老 App 读取新 supervisor 返回：忽略新增字段

如果当前自动合成 `Decodable` 无法给新增字段默认值，需要手写 `init(from:)`。

### 13.2 Debug/Release 隔离

继续保持：

- Debug 使用 dev supervisor service name
- Debug 使用独立默认端口，例如 `19789`
- Release 使用正式 service name 和正式 profile

本方案不改变隔离策略，只要求 Debug Run 下 supervisor XPC 短暂不可用时，App 能保持业务连接和清晰状态。

### 13.3 已有 dirty worktree

当前工作区存在多处未提交改动。实施时应分两步：

1. 先落状态模型和恢复策略，避免混入 UI 大改
2. 再统一 UI 文案

不要回滚无关文件，不要把 LaunchAgent handoff 相关改动混在本方案里。

## 十四、实施步骤

### Phase 1: 状态契约

修改：

- `Shared/GatewayProfiles.swift`
- `EZRWorkerSupervisor/SupervisorRecord.swift`

内容：

- 新增 `SupervisorHealthState`
- 扩展 `SupervisorProfileRuntime`
- 为新增字段提供 Codable 默认值
- 在 `snapshot()` 中输出健康字段

验收：

- 新旧字段并存
- build 通过
- App 能正常解析 runtime

### Phase 2: Supervisor 健康窗口

修改：

- `EZRWorkerSupervisor/SupervisorController+Readiness.swift`
- `EZRWorkerSupervisor/SupervisorController+Lifecycle.swift`

内容：

- 统一 `markHealthy` / `markUnhealthy`
- `refreshManagedRuntimeSnapshot` 中记录 `unhealthySince`
- 超过阈值后标记 `unresponsive`
- `startProfile` 成功后清除不健康窗口
- `stopProfile` 成功后记录 manual stop

验收：

- 健康 Gateway 显示 healthy/ready
- 端口假活超过阈值显示 unresponsive
- 刚启动慢的 Gateway 不被误判 failed

### Phase 3: App Recovery 策略

修改：

- `EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`

内容：

- 保留 supervisor 不可用时 direct reconnect
- 保留 reconnectOnly/conservativeStart 区分
- 移除 `.ready` 直接 restart
- 只在 `healthState == .unresponsive` 且满足 managed/supervised/threshold 时 restart
- 登录 bootstrap 不自动 restart unresponsive gateway

验收：

- appActivated/screenUnlocked 不触发生命周期操作
- reconnectLoop/systemWake 只在持续不健康后 restart
- supervisor XPC 不可用时不会 start/restart

### Phase 4: UI 状态统一

修改：

- `EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift`
- `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`
- `EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift`

内容：

- `GatewayProcessManager.State` 增加或映射健康检查未响应状态
- 左下角展示 App WebSocket + runtime health 的组合状态
- 设置页展示 supervisor/runtime 细节
- bootstrap progress 中保持“检查 Gateway”，不再显示“启动 Gateway”作为默认步骤

验收：

- 不再出现左下角“未连接”但设置页简单“运行中”的矛盾
- 用户能看懂是 supervisor 未就绪、Gateway 无响应，还是仅 WebSocket 未连接

### Phase 5: 回归验证

验证场景：

1. Debug Run 首次登录，supervisor 启动慢
2. Debug Run 重新 Run，旧 `19789` 进程仍在
3. `19789` 有监听但 `/readyz` 超时
4. supervisor XPC 不可用但 Gateway `/readyz` 正常
5. App 激活
6. 屏幕解锁
7. 系统唤醒
8. reconnect loop
9. 用户手动 stop 后等待 reconnect loop
10. managed profile 与 observe-only external profile
11. adopted PID 与 recorded process PID 不一致
12. 端口被非 Gateway 进程占用

## 十五、风险与防护

### 15.1 风险：新增状态字段导致 JSON 解析失败

防护：

- 新字段必须有默认值
- 必要时手写 `Decodable`
- 先单独 build 验证 App 与 supervisor 都能编译

### 15.2 风险：unresponsive 阈值过短误杀慢启动

防护：

- fresh launch grace period 不短于现有启动等待
- 只有曾经 ready 后失联，才使用较短 unresponsive threshold
- 首次启动依赖安装仍按 startup timeout 处理

### 15.3 风险：用户手动停止后被自动拉起

防护：

- stopProfile 设置 `userStoppedAt`
- automatic recovery 检查该字段
- 用户手动 start/restart 才清除该字段

### 15.4 风险：external Gateway 被误重启

防护：

- restart 必须满足 `managementMode == .managedByEZRWorker`
- restart 必须满足 `ownership == .supervised`
- adopted/external/observe-only 只显示状态，不自动 restart

### 15.5 风险：supervisor 不可用时状态停滞

防护：

- App direct reconnect 成功后显示 Gateway 已连接
- 设置页单独显示 supervisor 未就绪
- 不用空 runtime 覆盖已有 running 状态

## 十六、最终判定规则

可以自动 start：

```text
trigger in [systemWake, reconnectLoop]
AND mode == conservativeStart
AND profile.managementMode == managedByEZRWorker
AND runtime.healthState == noProcess
AND runtime.userStoppedAt == nil
AND supervisor connected
AND confirmGatewayUnavailable == true
```

可以自动 restart：

```text
trigger in [systemWake, reconnectLoop]
AND mode == conservativeStart
AND profile.managementMode == managedByEZRWorker
AND runtime.ownership == supervised
AND runtime.healthState == unresponsive
AND runtime.unhealthySince older than threshold
AND runtime.userStoppedAt == nil
AND supervisor connected
AND confirmGatewayUnavailable == true
```

绝不自动 restart：

```text
trigger in [appActivated, screenUnlocked]
OR login bootstrap
OR supervisor unavailable
OR profile observe-only
OR ownership adopted/external
OR user stopped
OR healthState launching/portListening within grace period
```

## 十七、预期结果

完成后，几个原始问题的表现应变为：

```text
登录后 supervisor 未就绪
  -> App 尝试直连 Gateway
  -> Gateway 健康则继续使用
  -> UI 显示 supervisor 未就绪但 Gateway 已连接

重新 Run 后一直连接 19789
  -> 如果 19789 健康，直接连接成功
  -> 如果 19789 假活，supervisor 标记 unresponsive
  -> conservative recovery 达到阈值后才 restart managed Gateway

左下角未连接，设置里运行中
  -> 左下角显示 WebSocket 未连接
  -> 设置页显示 Gateway 健康/不健康与 supervisor 状态
  -> 两处文案不再互相否定
```

核心原则：

```text
App 负责连接和展示。
Supervisor 负责进程归属和健康判定。
Gateway restart 只能发生在明确、受限、可解释的恢复路径里。
```
