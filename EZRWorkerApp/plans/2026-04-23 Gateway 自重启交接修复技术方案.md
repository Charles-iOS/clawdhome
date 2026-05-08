---
name: Gateway Self Restart Handoff Repair
overview: 修复 OpenClaw gateway 在 EZRWorkerSupervisor 子进程模式下误判 launchd 托管，导致飞书绑定等配置变更触发 full process restart 后 gateway 退出但无人重新拉起的问题。
todos:
  - id: phase1-env-sanitize
    content: "Phase 1: 清理 gateway 子进程继承的 launchd/systemd/schtasks supervisor 标记，避免 OpenClaw 误判托管环境"
    status: pending
  - id: phase2-supervisor-handoff
    content: "Phase 2: EZRWorkerSupervisor 识别 gateway 正常自重启交接并主动重新 startProfile"
    status: pending
  - id: phase3-diagnostics
    content: "Phase 3: 改善运行态错误展示、日志与回归验证"
    status: pending
isProject: false
---

# Gateway 自重启交接修复技术方案

## 一、背景

飞书扫码绑定后，当前 profile 从“正常运行”变为：

- UI 显示 `异常`
- `PID` 变为 `—`
- `运行权属` 变为 `无`
- `lastError` 显示：`[gateway] restart mode: full process restart (supervisor restart)`
- `18809` 端口无监听，Supervisor 探测得到 `Connection refused`

现场链路可以归纳为：

1. 用户启动飞书绑定工具：`npx -y @larksuite/openclaw-lark-tools install`
2. 工具写入当前 profile 的 `channels.feishu`、`plugins.openclaw-lark`、`secrets.providers.lark-secrets`
3. OpenClaw gateway 发现配置/插件变更，需要重启
4. OpenClaw 选择 `full process restart (supervisor restart)`
5. gateway 进程退出
6. 外部没有重新拉起 gateway，profile 停在无 PID 状态

关键矛盾是：OpenClaw 以为“外部 supervisor 会重启我”，但当前架构里直接托管 gateway 的不是 launchd，而是 `EZRWorkerSupervisor` 这个父进程。

## 二、根因

当前 gateway 启动链路是：

```text
launchd
  -> EZRWorkerSupervisor
       -> OpenClaw gateway
```

`OpenClawRuntime.buildEnvironment(profile:)` 当前基于 `ProcessInfo.processInfo.environment` 构造子进程环境。`EZRWorkerSupervisor` 本身由 launchd 启动，因此它的环境里可能带有：

- `XPC_SERVICE_NAME`
- `LAUNCH_JOB_LABEL`
- `LAUNCH_JOB_NAME`
- `OPENCLAW_LAUNCHD_LABEL`

OpenClaw 的 supervisor 检测逻辑会把这些变量视为“当前 gateway 由 launchd 直接托管”的信号。于是配置变更需要重启时，OpenClaw 不会在当前进程内重启，也不会自己 spawn detached child，而是选择：

```text
退出当前 gateway 进程 -> 等 launchd / supervisor 拉起新进程
```

但 launchd 实际只知道 `EZRWorkerSupervisor`，不知道这个 profile 的 gateway 子进程。当前 `EZRWorkerSupervisor` 在 `handleProcessTermination` 里也没有把 exit 0 + `supervisor restart` 识别为“正常重启交接请求”，所以最终 gateway 退出后无人接手。

## 三、设计目标

本次修复目标：

- 飞书绑定、插件安装、渠道配置变更后，gateway 能自动恢复运行
- 避免 OpenClaw 子进程误判自己被 launchd 直接托管
- 保留 full process restart 的“新 PID / 干净重载”优势
- Supervisor 能区分“正常请求重启”和“异常崩溃”
- UI 不再把正常重启交接日志当作最终错误展示

非目标：

- 不改 OpenClaw 上游的 supervisor 检测实现
- 不把每个 profile 改成独立 LaunchAgent
- 不默认降级为进程内重启，除非后续验证证明完整进程重启成本过高

## 四、方案对比

### 4.1 方案 A：只清理环境变量

做法：

- `OpenClawRuntime.buildEnvironment(profile:)` 构造 gateway/CLI 环境时移除 launchd/systemd/schtasks supervisor 标记
- OpenClaw 不再误判 launchd 托管
- 配置变更时会走 OpenClaw 自身的非托管重启策略，例如 detached spawn 或进程内 fallback

优点：

- 根因修复，避免错误识别
- 改动集中，风险较低
- 不依赖日志字符串识别

缺点：

- 如果 OpenClaw 选择 detached spawn，新 gateway 不再由 EZRWorkerSupervisor 的 `Process` 对象直接持有，Supervisor 需要通过端口 adoption 才能识别
- 如果 OpenClaw fallback 到进程内重启，插件安装类场景不如新进程彻底
- 对已经发生的 `supervisor restart` 退出没有兜底

### 4.2 方案 B：只让 Supervisor 识别重启交接

做法：

- `EZRWorkerSupervisor.handleProcessTermination` 检测：
  - `exitCode == 0`
  - captured output 包含 `restart mode: full process restart (supervisor restart)`
- 识别为正常重启交接后，主动调用 `startProfile(profileID:)`

优点：

- 保留 full process restart，新 PID，插件/模块重新加载最干净
- 与 OpenClaw 的 “supervised restart” 语义一致
- 对当前现场问题恢复最直接

缺点：

- 依赖 OpenClaw 日志文案，未来上游改文案可能失效
- 需要避免无限重启循环
- 仍允许 gateway 继续误判 launchd，根因未消除

### 4.3 推荐方案：A + B 双保险

采用组合修复：

1. **环境变量清理是根因修复**
2. **Supervisor 识别交接是运行时兜底**

这样既能避免后续误判，又能覆盖以下边界：

- 老版本 OpenClaw 仍输出 `supervisor restart`
- 其他 inherited supervisor marker 触发同类误判
- gateway 在配置变更中已进入 full process restart 分支

## 五、详细设计

### 5.1 Phase 1：子进程环境变量清理

修改位置：

- `Shared/OpenClawRuntime.swift`

新增环境清理逻辑：

```swift
private static let inheritedSupervisorMarkerKeys = [
    "LAUNCH_JOB_LABEL",
    "LAUNCH_JOB_NAME",
    "XPC_SERVICE_NAME",
    "OPENCLAW_LAUNCHD_LABEL",
    "OPENCLAW_SYSTEMD_UNIT",
    "INVOCATION_ID",
    "SYSTEMD_EXEC_PID",
    "JOURNAL_STREAM",
    "OPENCLAW_WINDOWS_TASK_NAME",
    "OPENCLAW_SERVICE_MARKER",
    "OPENCLAW_SERVICE_KIND",
]
```

在 `buildEnvironment(profile:)` 中：

```swift
for key in inheritedSupervisorMarkerKeys {
    environment.removeValue(forKey: key)
}
environment["EZRWORKER_SUPERVISOR_CHILD"] = "1"
```

注意点：

- `OPENCLAW_CONFIG_PATH`、`OPENCLAW_STATE_DIR` 必须保留
- `PATH`、`HOME`、`NODE_ENV` 保持现有行为
- 清理应作用于 gateway 子进程和本地 OpenClaw CLI，避免 pairing CLI 也继承错误 supervisor 语义
- 不设置 `OPENCLAW_NO_RESPAWN=1` 作为默认方案，避免强制进程内重启

### 5.2 Phase 2：Supervisor 识别正常重启交接

修改位置：

- `EZRWorkerSupervisor/SupervisorController.swift`

新增判断：

```swift
private func isSupervisorRestartHandoff(exitCode: Int32, output: String) -> Bool {
    guard exitCode == 0 else { return false }
    return output.localizedCaseInsensitiveContains(
        "restart mode: full process restart (supervisor restart)"
    )
}
```

在 `handleProcessTermination(profileID:pid:exitCode:capturedOutput:)` 中：

1. 如果 terminated PID 是当前 profile 的 gateway
2. 如果 probe 当前端口未 ready
3. 如果命中 `isSupervisorRestartHandoff`
4. 则不要进入 `.failed`
5. 设置：
   - `record.readyState = .starting`
   - `record.isRunning = false`
   - `record.pid = nil`
   - `record.ownership = .none`
   - `record.lastError = nil`
6. 异步调用 `startProfile(profileID:)`

伪代码：

```swift
if isSupervisorRestartHandoff(exitCode: exitCode, output: capturedOutput) {
    record.pid = nil
    record.isRunning = false
    record.ownership = .none
    record.readyState = .starting
    record.lastError = nil

    Task {
        let result = await startProfile(profileID: profileID)
        if !result.0 {
            // startProfile 内部会记录 lastError
        }
    }
    return
}
```

需要增加防抖/防循环：

- 每个 profile 的 handoff restart 增加短窗口计数
- 建议策略：60 秒内最多 3 次
- 超过后停止自动拉起，设置 `failed`：

```text
Gateway 连续请求 supervisor restart，已停止自动重启以避免循环
```

### 5.3 Phase 3：诊断与 UI 展示

当前 UI 会把 gateway 最后一行普通日志显示为红色错误。修复后应满足：

- 正常重启交接期间显示 `启动中`
- 不展示 `restart mode: full process restart (supervisor restart)` 作为异常
- 真正失败时展示启动失败原因，例如配置错误、端口占用、启动超时

可选增强：

- `SupervisorProfileRuntime` 增加 `lastLifecycleMessage`
- `lastError` 只承载真正失败
- profile 卡片展示最近生命周期事件，例如：

```text
14:06:06 gateway requested full process restart
14:06:09 restart handoff accepted by EZRWorkerSupervisor
14:06:11 gateway ready pid=12345
```

## 六、为什么不优先选进程内重启

进程内重启的优点是简单、快、PID 不变、无需外部 supervisor 介入。

但飞书绑定场景涉及：

- 安装 `openclaw-lark` 插件
- 新增插件 manifest
- 新增 channel runtime
- 写入 secrets provider
- 更新 `channels.feishu`

这些更适合 full process restart，因为新进程可以干净地重新加载插件文件、模块缓存、全局单例和 channel runtime。进程内重启如果有模块缓存或插件副作用残留，后续排障会更难。

因此推荐：

- 默认保留 full process restart
- 让 EZRWorkerSupervisor 正确接手
- 只有在确认 OpenClaw detached spawn/adoption 行为不可控时，才考虑对 gateway 设置 `OPENCLAW_NO_RESPAWN=1`

## 七、验收标准

### 7.1 手工验收

1. 启动 App，选择 `Default` profile
2. 启动 gateway，确认：
   - `readyState = ready`
   - `ownership = supervised`
   - `PID` 存在
   - `18809` 端口有监听
3. 执行飞书扫码绑定
4. 绑定工具写入配置后，gateway 允许短暂断连
5. 30 秒内 profile 自动恢复：
   - `readyState = ready`
   - `PID` 变为新 PID 或成功 adoption
   - `ownership = supervised` 或 `adopted`
   - UI 不停留在 `异常`
6. 飞书渠道状态显示已配置
7. 给飞书机器人发消息，确认 gateway 已加载 `openclaw-lark`

### 7.2 回归验收

- 点击 profile 卡片 `重启`，仍能正常 stop/start
- 点击 `停止`，不会被 handoff 识别误拉起
- gateway 配置错误时，不会无限重启
- 端口被占用时，仍显示明确错误
- profile 切换时，不会拉错 profile
- App 退出时，Supervisor 不误判 termination 为 restart handoff

### 7.3 自动化建议

可补充单元测试或轻量脚本测试：

- `OpenClawRuntime.buildEnvironment(profile:)` 不包含 `XPC_SERVICE_NAME`
- `isSupervisorRestartHandoff(exitCode:output:)` 只匹配 exit 0 + 指定 restart 文案
- 60 秒内超过 handoff 限制后进入 failed
- 非 0 exit 即使包含 restart 文案也不自动拉起

## 八、风险与缓解

| 风险 | 影响 | 缓解 |
| --- | --- | --- |
| 日志文案变更导致 handoff 识别失效 | 兜底失效 | Phase 1 环境清理作为根因修复；同时匹配更结构化的多关键词 |
| 自动重启循环 | CPU/日志/端口反复波动 | 加 profile 级 restart handoff rate limit |
| 清理 `XPC_SERVICE_NAME` 影响其他库 | 低概率影响子进程对 macOS 服务上下文判断 | 仅清理 OpenClaw 子进程环境，不影响 App/Supervisor 自身 |
| detached spawn 后 Supervisor 失去 `Process` 持有 | UI ownership 可能显示 adopted | 保留现有端口 probe/adoption 逻辑，必要时优先让 Supervisor 接手 full restart |
| 配置错误被误当正常重启 | 用户看不到真实错误 | 只有 exit 0 + restart handoff 文案才自动拉起；新启动失败仍写 lastError |

## 九、推荐落地顺序

1. 先做 `OpenClawRuntime` 环境清理
2. 再做 `SupervisorController` handoff 识别和 rate limit
3. 本地复现飞书绑定流程
4. 补 UI/日志小幅优化
5. 最后跑 Xcode build 验证

建议不要先引入 `OPENCLAW_NO_RESPAWN=1`，除非 A+B 修复后仍出现无法稳定 adoption 的情况。
