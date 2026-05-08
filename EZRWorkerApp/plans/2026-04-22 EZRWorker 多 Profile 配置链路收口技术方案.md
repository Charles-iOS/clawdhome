---
name: EZRWorker Multi Profile Config Isolation Closure
overview: 收口新主线下仍直接读写 ~/.openclaw 的 UI、本地配置、credentials 与 pairing CLI 链路，确保当前选中的 profile 在在线/离线场景都严格按 resolved profile 路径工作。
todos:
  - id: phase1-path-context
    content: "Phase 1: 抽象当前 profile 的本地 config / state / credentials 路径上下文"
    status: completed
  - id: phase2-local-fallback
    content: "Phase 2: 收口 Channel / Bindings / Onboarding 的本地 fallback，移除主线硬编码 ~/.openclaw"
    status: completed
  - id: phase3-feishu-pairing
    content: "Phase 3: 收口 FeishuChannelConfigSheet / ChannelPairingSheet / pairing CLI 的 profile 透传"
    status: completed
  - id: phase4-hardening
    content: "Phase 4: 增加 fail-fast、验收与遗留链路边界说明"
    status: completed
isProject: false
---

# EZRWorker 多 Profile 配置链路收口技术方案

## 一、背景

当前 `EZRWorker` 的多 profile 运行时核心已经具备：

- `GatewayProfileStore` 能选择当前 profile
- `SupervisorClient` / `EZRWorkerSupervisor` 能按 profile 管理 lifecycle
- `GatewayService`、`AgentStore`、`AgentWorkspaceManager` 已开始绑定当前 profile

但主线仍残留一批“直接读写 `~/.openclaw`”的 UI 和本地配置链路。这些链路会绕过当前选中的 profile，使多 profile 的隔离只在 runtime 核心成立，而在配置读取、离线 fallback、扫码状态、pairing store 和本地 JSON 写回场景中失效。

2026-04-22 落地结果：

- 主线 capability / pairing / onboarding 的当前 profile 本地路径已统一收口到 `selectedResolution`
- 当前 profile 的本地 pairing CLI 已显式透传 `profile`
- 主线不再把 `GatewayProcessManager.openClawConfigDir` 当作当前 profile 入口
- `AgentWorkspaceManager` 已移除内部 legacy silent fallback，并在 profile 切换 / 登出时清空旧 profile 绑定
- `AgentWorkspaceView` 默认 workspace 展示已改为当前 profile 的实际路径，不再写死 `~/.openclaw/workspace`

## 二、问题清单

### 2.1 主线仍暴露 legacy 默认目录

- `GatewayProcessManager.openClawConfigDir` 直接返回 `EZRWorkerPaths.legacyOpenClawDirectory`
- 主线多个页面将它当成“当前 profile 的本地配置目录”来用

结果：

- 任何未显式走 gateway config 的本地读取，都会默认回落到 `~/.openclaw`
- 即使用户当前选中的是 `managed profile`，UI 仍可能展示 legacy profile 的本地状态

### 2.2 Channel / Bindings 离线 fallback 仍读 legacy 路径

以下页面在 gateway 不在线时，仍会直接读取 legacy 本地文件：

- `ChannelView`
  - `lark.secrets.json`
  - `openclaw.json`
  - `credentials/*`
- `AgentBindingsView`
  - `lark.secrets.json`
  - `openclaw.json`

结果：

- 当前 profile 的渠道状态、已配置判断、配对统计可能展示错 profile 的数据
- 离线场景下尤其明显，因为代码会直接绕开 `configGetFull()`

### 2.3 Feishu 配置弹窗将 ~/.openclaw 写死

`FeishuChannelConfigSheet` 当前存在整块 legacy-only 逻辑：

- 顶部 `openClawConfigDirectoryURL = ~/.openclaw`
- 本地 `loadLocalConfigRoot()` 固定读 `~/.openclaw/openclaw.json`
- 本地 `removeAllowFromPeerFromLocalConfig()` 固定写 `~/.openclaw/openclaw.json`
- 配对数据读取固定走 `~/.openclaw/credentials`
- 若 gateway 不在线，整张弹窗的本地读写都落到 legacy 目录

结果：

- 当前选中 `managed profile` 时，飞书策略和 allow-from 的离线操作会污染错误 profile
- `legacyReuse profile` 与 `managed profile` 无法严格隔离

### 2.4 Pairing CLI 未透传 profile

`ChannelPairingSheet` 与 `FeishuChannelConfigSheet` 中多处调用：

```swift
GatewayProcessManager.runOpenclawLocally(args: ...)
```

但未传 `profile:` 参数，等价于在当前登录用户默认环境下运行 CLI。

受影响操作包括：

- `pairing approve`
- `pairing reject`
- `pairing remove`

结果：

- CLI 可能继续作用于 legacy 默认目录
- 即使 UI 展示的是某个 managed profile，实际 approve/reject/remove 的 pairing store 也可能落在其他 profile

### 2.5 扫码接入完成后的本地校验仍读 legacy 配置

`FeishuChannelOnboardingSheet` 在验证接入结果时，会读取本地 `openclaw.json` 快照；当前快照路径仍来自 `GatewayProcessManager.openClawConfigDir`。

结果：

- 扫码接入完成后的“本地已接入 / 已启用”判断可能与当前 profile 不一致

### 2.6 仍需保留的 legacy 边界与暂不改动项

以下内容不属于本轮“主线多 profile 收口”的直接改造对象：

- 旧 helper / shrimp / 多用户兼容窗口
- `ProfileMigrationChoiceView` 中与 `~/.openclaw` 相关的迁移文案与导入路径
- `GatewayProfileStore` 中 `legacyReuse` profile 对 `~/.openclaw` 的显式建模

说明：

- `legacyReuse` 本来就应该解析到 `~/.openclaw`
- 本轮要移除的是“主线默认回落到 legacy 路径”，不是移除 legacy profile 能力本身

## 三、目标

本轮目标：

1. 主线所有“当前 selected profile 的本地 config / credentials / pairing”读写，都必须基于 `selectedResolution`
2. gateway 在线时仍优先走 `configGetFull()` / `configPatch()`；仅在离线 fallback 时读当前 profile 的本地文件
3. 所有主线 `openclaw` CLI 操作，只要语义上属于“当前 profile”，都必须显式透传 `profile`
4. `legacyReuse` 被选中时，路径仍自然落到 `~/.openclaw`
5. 当当前 profile 上下文缺失时，主线应 fail-fast 或降级为只读，不再静默回退到 legacy 目录

非目标：

- 不重做 `GatewayProfileResolver`
- 不调整 supervisor runtime model
- 不改变 `legacyReuse` 的解析规则
- 不处理 helper 旧链路的全面 profile 化

## 四、核心设计

### 4.1 引入统一的当前 profile 本地路径上下文

不再让页面自行拼接 `~/.openclaw`，统一由当前 selected profile 派生本地路径上下文。

建议新增一个轻量 helper，例如：

```swift
struct GatewayProfileLocalPaths {
    let resolution: GatewayProfileResolution

    var configURL: URL
    var stateDirURL: URL
    var workspaceRootURL: URL
    var credentialsDirURL: URL
}
```

其中：

- `configURL = resolution.configURL`
- `stateDirURL = resolution.stateDirURL`
- `workspaceRootURL = resolution.workspaceRootURL`
- `credentialsDirURL = stateDirURL.appendingPathComponent("credentials", isDirectory: true)`

约束：

- 主线不再把“config 目录”当作“credentials 根目录”
- credentials 一律从当前 profile 的 `stateDir` 派生
- `legacyReuse` profile 下，这些路径自然会解析到 `~/.openclaw` 及其子目录

### 4.2 当前 profile 路径来源

主线视图层的当前 profile 本地路径来源统一为：

1. 首选 `GatewayProfileStore.selectedResolution`
2. 若视图当前已绑定运行时服务，也可与 `AgentWorkspaceManager.currentProfileResolution` 做一致性校验
3. 若两者都缺失：
   - 不再静默回退到 `~/.openclaw`
   - 页面进入只读 / 未就绪态，或直接返回空结果并打日志

这意味着：

- `GatewayProcessManager.openClawConfigDir` 不能再作为主线的“当前 profile 本地目录入口”
- 如保留该属性，也只能用于 legacy-only 场景，不能再被主线 capability views 使用

### 4.3 本地文件读写规则

统一规则如下：

#### 在线

- 读取：优先 `gateway.configGetFull()`
- 写入：优先 `gateway.configPatch()`

#### 离线 fallback

- 读取：当前 profile 的 `configURL` / `credentialsDirURL`
- 写入：当前 profile 的 `configURL`
- 只允许操作当前 profile 对应的本地文件

禁止：

- 主线 capability 页面直接写死 `FileManager.default.homeDirectoryForCurrentUser/.openclaw`
- 页面在 profile 缺失时自动回退到 legacy 目录

### 4.4 CLI 执行规则

所有属于“当前 profile”的本地 CLI 调用，都必须显式传入：

```swift
GatewayProcessManager.runOpenclawLocally(args: ..., profile: selectedResolution)
```

包括但不限于：

- `pairing approve`
- `pairing reject`
- `pairing remove`
- 后续其他本地 CLI 变更命令

约束：

- 主线代码禁止再使用 `profile: nil` 来执行当前 profile 相关 CLI
- 只有 legacy-only / helper-compatible 链路才能保留默认无 profile 上下文

### 4.5 页面收口策略

#### `ChannelView`

- 去掉对 `GatewayProcessManager.openClawConfigDir` 的依赖
- 本地 `lark.secrets.json`、`openclaw.json`、配对统计全部改为从当前 `selectedResolution` 派生

#### `AgentBindingsView`

- 与 `ChannelView` 保持一致
- 本地已配置判断、扫码凭据存在性判断全部切到当前 profile

#### `FeishuChannelConfigSheet`

- 删除顶层 `openClawConfigDirectoryURL = ~/.openclaw`
- 本地 `loadLocalConfigRoot`、`allowFrom` 写回、配对数据读取全部通过当前 profile 本地路径 helper 完成
- `ChannelPairingMutationSupport` 中涉及 CLI 的 remove 操作必须透传当前 profile

#### `ChannelPairingSheet`

- 待审批 / 已配对列表读取当前 profile 的 `credentialsDir`
- `approve/reject` 走 `runOpenclawLocally(..., profile: selectedResolution)`

#### `FeishuChannelOnboardingSheet`

- 扫码接入成功后的本地校验快照改读当前 profile 的 `configURL`
- 避免“扫码写到 A profile，验证却从 legacy profile 读取”

## 五、实施拆分

### Phase 1: 路径上下文抽象

- 在 profile 相关模型层新增 `credentialsDirURL` 等 helper
- 新增“从当前 selected profile 派生本地路径”的统一入口
- 标记 `GatewayProcessManager.openClawConfigDir` 为 legacy-only，逐步移除主线引用

### Phase 2: Channel / Bindings / Onboarding 收口

- 改 `ChannelView`
- 改 `AgentBindingsView`
- 改 `FeishuChannelOnboardingSheet`
- 确保离线 fallback 都读当前 profile

### Phase 3: Feishu / Pairing 收口

- 改 `FeishuChannelConfigSheet`
- 改 `ChannelPairingSheet`
- 改 `ChannelPairingMutationSupport`
- 所有 pairing CLI 调用显式透传 profile

### Phase 4: Hardening

- 主线缺少 profile 上下文时改为只读 / fail-fast
- 清理 legacy 默认路径注释和文案
- 将大方案里的 `phase3-profiles` 状态在完成验收前保持 `pending`

## 六、建议改动文件

核心文件：

- `Shared/GatewayProfiles.swift`
- `EZRWorkerApp/EZRWorker/Services/Gateway/GatewayProcessManager.swift`
- `EZRWorkerApp/EZRWorker/Views/Capabilities/ChannelView.swift`
- `EZRWorkerApp/EZRWorker/Views/Agent/AgentBindingsView.swift`
- `EZRWorkerApp/EZRWorker/Views/Capabilities/FeishuChannelConfigSheet.swift`
- `EZRWorkerApp/EZRWorker/Views/Capabilities/ChannelPairingSheet.swift`
- `EZRWorkerApp/EZRWorker/Views/ChannelOnboarding/FeishuChannelOnboardingSheet.swift`

可选 hardening：

- `EZRWorkerApp/EZRWorker/Services/AgentWorkspaceManager.swift`

说明：

- `AgentWorkspaceManager` 的底层路径解析已改为 profile-only
- profile 缺失时会返回 `notConfigured`，不再默默回落到 legacy 目录
- `AppBootstrapCoordinator` 在 profile 切换 / 登出时会主动清空旧绑定，避免主界面短暂沿用上一 profile 的 workspace 上下文

## 七、验收标准

### 7.1 Managed Profile

- 新建 `managed profile A`
- 在其 `channels` 配置里修改飞书 / telegram 等配置
- gateway 在线和离线两种情况下，页面读取与写入都只作用于 `profile A`

### 7.2 Multi-Profile Isolation

- 同时存在 `profile A`、`profile B`
- 二者 `openclaw.json` 与 `state/credentials` 数据不同
- 切换 selected profile 后：
  - `ChannelView` 展示跟随切换
  - `AgentBindingsView` 展示跟随切换
  - `FeishuChannelConfigSheet` 离线 fallback 跟随切换
  - `ChannelPairingSheet` 待审批 / 已配对列表跟随切换

### 7.3 Legacy Reuse

- 选中 `legacyReuse` profile 时
  - 本地 config 读取仍然落到 `~/.openclaw/openclaw.json`
  - credentials 读取仍然落到 `~/.openclaw/credentials`
  - pairing CLI 作用于 legacy profile

### 7.4 Pairing CLI

- 在 `profile A` 中 approve / reject / remove 一条 pairing 数据
- 验证：
  - 仅 `profile A` 的 pairing store 改变
  - `profile B` 与 `legacy` 不受影响

### 7.5 Onboarding 校验

- 扫码接入完成后
  - 本地快照验证读取当前 profile config
  - 不再出现“接入成功但 UI 仍显示未配置”的跨 profile 误判

## 八、风险与注意事项

1. `credentials` 的真实运行时目录必须先确认
当前方案默认主线 credentials 落在 `stateDir/credentials`。实施前需用现有 managed profile 实测一次，确认 pairing store、`lark.secrets.json`、allowFrom store 的实际生成位置。

2. 一些页面过去默认把“config 目录”与“state 根目录”视为同一层
多 profile 模式下这两个概念已经分离，必须明确：
- `openclaw.json` 走 `configURL`
- runtime 数据 / credentials / pairings 走 `stateDir`

3. 不能把“离线 fallback”继续当作 legacy 兼容捷径
离线 fallback 的目标应该是“当前 profile 的本地快照”，不是“用户 home 下唯一的 `.openclaw`”

## 九、结论

这轮收口完成前，`EZRWorker` 的多 profile 只能算“runtime 核心支持多 profile”，还不能算“应用层完全隔离”。

只有当：

- 主线页面不再默认读写 `~/.openclaw`
- pairing CLI 显式绑定当前 profile
- 本地 `openclaw.json / credentials / allowFrom / pairing` 全部按 `selectedResolution` 工作

`Phase 3: 引入 GatewayProfileStore、Profile UI、multi-gateway lifecycle` 才能视为真正完成。
