---
name: App Login And Activation Gateway Non-invasive Recovery
overview: 调整 App 登录、激活、唤醒后的 Gateway bootstrap/recovery 链路，让 App 默认只连接和观测后台 Gateway，避免单次探活失败或状态短暂未 ready 时主动重启 Gateway，导致 Web UI 和 WebSocket 会话中断。
todos:
  - id: phase1-state-model
    content: "Phase 1: 梳理登录/激活 bootstrap 状态模型，区分 connect/check/recover/restart"
    status: pending
  - id: phase2-non-invasive-bootstrap
    content: "Phase 2: 将 App 启动后的默认行为改为非侵入式连接，只有确认未运行时才 start"
    status: pending
  - id: phase3-conservative-recovery
    content: "Phase 3: 收紧 appActivated/reconnectLoop/systemWake 的恢复策略，避免单次探活失败触发 restart"
    status: pending
  - id: phase4-diagnostics-and-ui
    content: "Phase 4: 增加诊断日志、状态文案与旧 launch agent 冲突提示"
    status: pending
  - id: phase5-regression
    content: "Phase 5: 增加回归验证场景，覆盖登录、激活、切 profile、真实崩溃恢复"
    status: pending
isProject: false
---

# App 登录与激活 Gateway 非侵入式恢复技术方案

## 一、背景

当前产品期望的运行模型是：

```text
launchd
  -> EZRWorkerSupervisor
       -> OpenClaw gateway

EZRWorker App
  -> XPC 连接 EZRWorkerSupervisor
  -> HTTP/WebSocket 连接当前 profile 的 gateway
  -> 管理配置、agent、模型、渠道、技能等
```

也就是说，Gateway 应该是后台常驻服务，App 是控制面。用户打开 App、登录 App、从后台切回 App 时，默认不应打断 gateway，也不应让已打开的 Web UI / WebSocket 会话退出。

现场现象是：

- App 登录完成后经常看到“Gateway 启动中”
- App 打开或激活时，Web 页面会短暂断开
- `gateway-current.log` / `gateway-previous.log` 显示短时间内出现连续 gateway 启动
- 当前选中 profile 的 gateway 由 `EZRWorkerSupervisor` 托管，但打开 App 仍可能触发恢复链路
- 本机同时存在旧 `ai.openclaw.gateway` launch agent 和 EZRWorker supervisor，容易造成旧 18789 gateway 与新 profile gateway 并存

## 二、当前链路

### 2.1 登录后 bootstrap

入口：

- `EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`

`AuthenticatedAppShell.task` 会在登录后执行：

```swift
await profileStore.loadIfNeeded()
if profileStore.canBootstrap {
    await bootstrapCoordinator.startIfNeeded()
}
```

`AppBootstrapCoordinator.performBootstrap()` 内部会：

1. 读取 profile
2. 检查运行环境
3. 连接 supervisor
4. `reloadProfiles()`
5. `listProfilesRuntime()`
6. 如果当前 runtime 不是 `.ready`，调用 `startProfileWithProgressTracking()`
7. 读取 gateway token
8. 连接 `GatewayService`
9. 加载 agent / workspace / model

关键问题：

```swift
if runtime?.readyState != .ready {
    try await startProfileWithProgressTracking(profileID: selectedProfile.id)
}
```

只要 runtime 不是 `.ready`，App 就进入“启动 Gateway”的生命周期操作。这里把“App 控制面初始化”和“后台服务生命周期修复”耦合得太紧。

### 2.2 App 激活/唤醒 recovery

入口：

- `NSApplication.didBecomeActiveNotification`
- `NSWorkspace.didWakeNotification`
- `com.apple.screenIsUnlocked`
- reconnect loop

这些触发都会进入：

```swift
await bootstrapCoordinator.recoverGatewayAfterInterruption(trigger:)
```

当前 recovery 中，如果 `GatewayClient.httpProbe(port:)` 单次返回 `alive == false`，会：

```swift
if runtime?.isRunning == true || runtime?.readyState == .ready {
    try await supervisorClient.restartProfile(profileID:)
} else {
    try await supervisorClient.startProfile(profileID:)
}
```

关键问题：

- 单次探活失败就可能 restart
- App 激活这种低风险事件也会触发生命周期操作
- `restartProfile` 会先 `stopProfile`，最终 `terminate/kill` gateway 进程
- Web UI 和 WebSocket 客户端都会被动断开

### 2.3 UI 文案误导

bootstrap progress 中固定存在：

```swift
ProgressStep(id: .gateway, title: "启动 Gateway", status: .pending)
```

即使只是连接已有 gateway，用户也会看到“启动 Gateway”，这会强化“每次登录都在启动”的感知。

## 三、根因分析

本问题不是单一 bug，而是三个因素叠加。

### 3.1 控制面初始化和生命周期恢复耦合

App 登录后需要的是：

- 连接 supervisor
- 获取当前 runtime
- 读取 token
- 连接 gateway WebSocket
- 加载工作区数据

只有在确认 gateway 未运行，且 profile 由 EZRWorker 管理时，才应该启动 gateway。

当前代码将“runtime 不是 ready”直接等价为“需要 startProfile”。但非 ready 可能只是：

- supervisor 刚 reload profiles，快照还没刷新
- gateway 正在启动或健康检查尚未 ready
- HTTP probe 短暂超时
- gateway 主线程短暂繁忙
- App 侧 socket 已断但 gateway 本身仍在

### 3.2 Recovery 策略过于激进

`appActivated`、`systemWake`、`screenUnlocked` 都属于“可能需要重连”的场景，不应默认承担“重启后台服务”的职责。

更合理的顺序应该是：

1. 刷新 supervisor runtime
2. 如果 gateway 正在启动，等待，不 restart
3. 如果 runtime 显示 running/ready，但 App socket 断了，先重连 socket
4. 如果 HTTP probe 短暂失败，多次确认
5. 只有持续确认端口无监听 / 进程已退出，才进入 start
6. 只有明确 stale pid / owned process 异常，才考虑 restart

### 3.3 旧 launch agent 与新 supervisor 并存造成认知混乱

当前机器存在：

- `ai.openclaw.gateway`：旧 OpenClaw gateway launch agent，监听 18789
- `ai.ezrworker.mac.supervisor`：EZRWorker supervisor
- 当前 selected profile `Default`：监听 18809

这不一定是本轮中断的直接原因，但会带来两个问题：

- 用户以为“gateway 一直在后台跑”，但 App 当前管理的可能不是旧 18789，而是 selected profile 的 18809
- 旧 gateway 仍 KeepAlive，可能占用资源、暴露旧 Web UI、干扰导入/迁移判断

## 四、设计目标

本轮目标：

1. App 登录/激活/唤醒默认不重启 Gateway
2. Gateway 已运行时，App 只重新连接 HTTP/WebSocket 和加载数据
3. 单次 HTTP probe 失败不触发 restart
4. `appActivated` 只做非侵入式 recovery
5. 真正崩溃或端口消失时，仍能由 supervisor 自动恢复
6. UI 文案区分“连接 Gateway”和“启动 Gateway”
7. 设置/诊断页提示旧 launch agent 与当前 selected profile 的关系

非目标：

- 不移除 `restartProfile` 手动能力
- 不改变 OpenClaw gateway 的自身重启机制
- 不把每个 profile 改为独立 LaunchAgent
- 不删除 legacy profile 能力

## 五、核心原则

### 5.1 默认非侵入

App 侧所有自动触发的行为，默认只允许：

- `listProfilesRuntime`
- `refreshRuntimeState`
- `httpProbe`
- `gatewayService.reconfigure`
- `gatewayService.connect`
- `agentStore.load`

默认不允许：

- `restartProfile`
- `stopProfile`
- `kill`

### 5.2 start 和 restart 分级

自动恢复只允许在明确条件下 `startProfile`：

- profile 是 `managedByEZRWorker`
- supervisor runtime 显示 stopped/unknown
- 端口连续多次无监听
- 没有正在进行的 start/restart 任务

自动恢复原则上不调用 `restartProfile`，除非后续有明确 stale runtime 判定：

- supervisor 记录 running/ready
- 端口持续无监听
- 记录中的 PID 已不存在
- 该 PID 原本属于当前 profile

### 5.3 先重连 socket，再处理生命周期

App 看到 `gatewayService.isConnected == false` 时，不代表 gateway down。应先：

1. 用当前 runtime port/token reconfigure
2. 重新 connect GatewayService
3. 如果 connect 成功，只刷新业务数据
4. 如果 connect 失败，再进入保守 probe

## 六、详细方案

### 6.1 Phase 1：调整状态语义

修改位置：

- `AppBootstrapCoordinator.ProgressStepID`
- `ProgressSnapshot.initial()`
- `runtimeProgressDetail(_:)`

将 UI step 从：

```swift
case gateway
ProgressStep(id: .gateway, title: "启动 Gateway", status: .pending)
```

调整为更准确的命名：

```swift
case gatewayStatus
ProgressStep(id: .gatewayStatus, title: "检查 Gateway", status: .pending)
```

或保留 enum id，改文案为：

```swift
ProgressStep(id: .gateway, title: "检查 Gateway", status: .pending)
```

文案规则：

- 已 ready：`Gateway 已在后台运行，准备连接本地服务。`
- starting：`Gateway 正在启动，等待本地服务就绪。`
- stopped 且将 start：`Gateway 未运行，正在由 Supervisor 拉起。`
- socket disconnected：`Gateway 已运行，正在重新连接控制接口。`

### 6.2 Phase 2：bootstrap 改为先观测再连接

当前：

```swift
if runtime?.readyState != .ready {
    try await startProfileWithProgressTracking(profileID: selectedProfile.id)
}
```

建议改为：

```swift
switch runtime?.readyState {
case .ready:
    // 直接连接
case .preparing, .starting:
    // 等待 ready，不重复 start
case .stopped, .unknown, nil:
    // 连续确认未运行后 start
case .failed:
    // 展示错误，不自动 restart
}
```

新增 helper：

```swift
private func waitForExistingGatewayOrStartIfNeeded(
    profileID: UUID,
    selectedResolution: GatewayProfileResolution,
    initialRuntime: SupervisorProfileRuntime?
) async throws -> SupervisorProfileRuntime
```

行为：

1. 如果 ready，立即返回
2. 如果 starting/preparing，最多等待一段短窗口，例如 30s
3. 等待期间只刷新 runtime，不调用 start
4. 如果 stopped/unknown，连续 probe 2-3 次端口无监听后 start
5. 如果 failed，除非错误明确是“未运行/端口未监听”，否则不自动 restart

### 6.3 Phase 3：Recovery 分层

新增 recovery policy：

```swift
private enum GatewayRecoveryMode {
    case reconnectOnly
    case conservativeStart
    case explicitRestart
}
```

映射：

- `appActivated` -> `reconnectOnly`
- `screenUnlocked` -> `reconnectOnly`
- `systemWake` -> `conservativeStart`
- `reconnectLoop` -> `conservativeStart`
- 用户点击“重启” -> `explicitRestart`

`performGatewayRecovery(trigger:)` 拆分为：

1. `recoverGatewayConnectionOnly(...)`
2. `conservativelyStartGatewayIfDown(...)`
3. 手动按钮继续走 `processManager.restart()`

`reconnectOnly` 只做：

- ensure supervisor connected
- reload/list runtime
- read token
- reconfigure GatewayService
- connect GatewayService
- refresh agent/workspace data

不做：

- start
- stop
- restart

`conservativeStart` 可以做 start，但需要满足连续确认条件。

### 6.4 Phase 4：多次探活确认

新增 helper：

```swift
private static func confirmGatewayUnavailable(
    port: Int,
    attempts: Int = 3,
    intervalNanoseconds: UInt64 = 1_000_000_000
) async -> Bool
```

判定规则：

- 只要任意一次 `alive == true`，认为 gateway 存在，不 start/restart
- 三次均 `alive == false`，再结合 supervisor runtime 判断
- 如果 runtime 是 `.starting` / `.preparing`，继续等待，不 start/restart

### 6.5 Phase 5：避免自动 restart

将 recovery 中这一段：

```swift
if runtime?.isRunning == true || runtime?.readyState == .ready {
    try await supervisorClient.restartProfile(profileID: selectedProfile.id)
} else {
    try await supervisorClient.startProfile(profileID: selectedProfile.id)
}
```

改为：

```swift
guard await Self.confirmGatewayUnavailable(port: resolvedPort) else {
    await reconnectGatewayService(...)
    return
}

let refreshedRuntime = await selectedRuntime(profileID: selectedProfile.id)
switch refreshedRuntime?.readyState {
case .preparing, .starting:
    await processManager.refreshRuntimeState()
    return
case .stopped, .unknown, nil:
    try await supervisorClient.startProfile(profileID: selectedProfile.id)
case .ready:
    await reconnectGatewayService(...)
case .failed:
    appLog("bootstrap: recovery skipped automatic restart for failed runtime: ...", level: .warn)
}
```

自动路径不再对 `.ready` 调用 `restartProfile`。

### 6.6 Phase 6：旧 launch agent 诊断提示

在设置页或诊断页加入检测：

- 当前 selected profile port
- `~/Library/LaunchAgents/ai.openclaw.gateway.plist` 是否存在
- 旧 launch agent 是否 loaded/running
- 旧 launch agent 监听端口是否等于当前 selected profile port

展示规则：

- 如果旧 agent 存在但端口不同：提示“检测到旧 OpenClaw Gateway 正在后台运行，它不属于当前 selected profile。”
- 如果旧 agent 端口和当前 selected profile 冲突：提示“端口冲突，建议停止旧 launch agent 或导入为 observeOnly。”
- 如果 selected profile 是 `legacyReuse`：提示“当前正在接管旧 OpenClaw profile。”

本轮先做诊断提示，不自动 bootout 旧 agent。

## 七、关键文件

预计修改：

- `EZRWorkerApp/EZRWorker/Services/AppBootstrapCoordinator.swift`
  - 拆分 bootstrap / recovery
  - 增加保守探活确认
  - 移除自动 restart

- `EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`
  - 调整 appActivated/screenUnlocked/systemWake 的 recovery mode

- `EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift`
  - 保持手动 start/stop/restart 能力
  - 可增加运行态刷新节流或暴露更准确的 lastRuntime

- `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`
  - 增加旧 launch agent / 端口冲突诊断

- `Shared/GatewayHealthProbe.swift`
  - 如现有 probe 过短，可新增更适合 App recovery 的 probe wrapper

## 八、验收标准

### 8.1 登录不重启

前置：

- 当前 selected profile gateway 已 ready
- 浏览器打开 `http://127.0.0.1:<port>/`
- WebSocket 已连接

操作：

1. 退出 App，不停止 gateway
2. 重新打开 App 并登录

期望：

- gateway PID 不变
- `gateway-current.log` 不被轮转为 `gateway-previous.log`
- Web UI 不刷新退出
- App UI 显示“连接/检查 Gateway”，不显示误导性“启动 Gateway”

### 8.2 App 激活不重启

操作：

1. App 退到后台
2. 浏览器保持 Web UI 会话
3. 点击 App 回到前台

期望：

- 不调用 `restartProfile`
- gateway PID 不变
- WebSocket 不断开

### 8.3 唤醒后保守恢复

操作：

1. Gateway 运行
2. 系统睡眠后唤醒

期望：

- 如果 gateway 仍 alive，只重连 App socket
- 如果 gateway 真的退出，连续确认后调用 `startProfile`
- 不对 ready/running runtime 调用 `restartProfile`

### 8.4 真实崩溃仍能恢复

操作：

1. 手动 kill 当前 selected profile gateway 进程
2. 等待 reconnect loop

期望：

- App/supervisor 识别端口持续不可用
- 自动 `startProfile`
- gateway 恢复 ready

### 8.5 手动重启仍可用

操作：

1. 点击仪表盘或设置页的“重启 Gateway”

期望：

- 显式调用 `restartProfile`
- PID 变化
- UI 显示重启过程
- Web UI 断开属于预期行为

## 九、风险与缓解

### 9.1 Gateway 真挂时恢复变慢

保守探活会让自动恢复多等待数秒。

缓解：

- reconnect loop 可使用 3 次 1s 探活
- systemWake 可使用 5 次 1s 探活
- UI 显示“正在确认 Gateway 状态”，避免无反馈

### 9.2 Runtime 快照 stale

如果 supervisor runtime 没及时刷新，App 可能误判。

缓解：

- 生命周期操作前后统一 `reloadProfiles` + `listProfilesRuntime`
- start 前再做一次 runtime/probe 双确认

### 9.3 旧 launch agent 干扰判断

旧 `ai.openclaw.gateway` 可能继续运行。

缓解：

- 诊断页明确显示当前 selected profile port
- 不把 18789 的旧 gateway 当成当前 profile 的 ready 状态
- 后续可提供“停止旧 OpenClaw launch agent”的显式按钮

## 十、实施顺序

1. 先改 UI 文案和 progress step，降低误导
2. 改 bootstrap：ready 直接连接，starting/preparing 等待，stopped 才 start
3. 改 recovery：appActivated/screenUnlocked 只重连，不 start/restart
4. 增加 `confirmGatewayUnavailable`
5. 移除自动 recovery 中对 `.ready` / `isRunning` 的 `restartProfile`
6. 增加日志：
   - recovery trigger
   - runtime before/after
   - probe attempts
   - decision: reconnect/start/skip
7. 增加设置页旧 launch agent 诊断
8. 手动验证五个验收场景

## 十一、决策摘要

本方案的核心决策是：

- App 是控制面，登录和激活只应连接后台服务
- 自动恢复可以 start，但必须保守确认 gateway 确实不在
- 自动恢复不应 restart 一个看起来 running/ready 的 gateway
- restart 保留给用户显式操作和 supervisor 内部明确的自重启交接

落地后，用户打开 App 时应看到的是“正在连接 Gateway”，而不是每次都经历一次真正的 gateway 进程重启。
