# Agent 渠道绑定功能完善方案

## Context

项目有两个涉及渠道绑定的入口，目前都未完成功能闭环：

| 入口 | 视角 | 当前状态 |
|------|------|----------|
| 侧边栏「消息渠道」(`ChannelView`) | 渠道 → 选智能体 | 卡片中「请配置智能体」区域是**纯占位**，无功能 |
| Agent Workspace → 渠道绑定 Tab (`AgentBindingsView`) | 智能体 → 选渠道 | AddBindingSheet 用了 7 个硬编码渠道，未集成凭据配置 |

**渠道配置的两种模式**（参照向导实现）：
- **QR 交互式**（飞书、微信）：必须在 Helper PTY 终端里运行官方 CLI 工具，以 Shrimp 用户身份执行
- **凭据表单式**（钉钉、Telegram、Discord）：填写凭据字段，`configPatch` 写入 gateway

两个入口最终操作同一份 `bindings[]` 数据，互相联动。

## 可复用的现有基础设施

| 组件 | 路径 | 用途 |
|------|------|------|
| `ChannelType` | [ChannelType.swift](ClawdHome/Models/ChannelType.swift) | 5 渠道元数据 |
| `ChannelBotConfigSheet` | [ChannelBotConfigSheet.swift](ClawdHome/Views/Capabilities/ChannelBotConfigSheet.swift) | 凭据表单（钉钉/飞书/Telegram/Discord） |
| `FeishuChannelOnboardingSheet` | [FeishuChannelOnboardingSheet.swift](ClawdHome/Views/ChannelOnboarding/FeishuChannelOnboardingSheet.swift) | QR 扫码 PTY 终端（飞书/微信） |
| `ChannelOnboardingFlow` | 同上 | 飞书/微信 CLI 命令参数 |
| `AgentStore` | [AgentStore.swift](ClawdHome/Services/Stores/AgentStore.swift) | `addBinding`/`removeBinding` CRUD |

---

## 改动一：消息渠道入口（渠道 → 选智能体）

**文件**: [ChannelView.swift](ClawdHome/Views/Capabilities/ChannelView.swift)

### 1.1 激活卡片中的智能体区域

将 `ChannelCardView` 的 `agentPlaceholder` 从静态占位改为可交互：

**未绑定状态**（当前占位样式）：
- 点击 → 弹出 `ChannelAgentPickerSheet`（新组件）
- Sheet 内容：从 `AgentStore.agents` 列表中选择一个智能体
- 可选填 peer 匹配条件（accountId、peerId、peerKind、guildId）
- 确认 → `store.addBinding(AgentBinding(agentId: selected, channel: channelType.rawValue, ...))`

**已绑定状态**（替换占位区域）：
- 展示已绑定的智能体列表（emoji + name），每项带删除按钮
- 底部「+ 添加更多智能体」入口
- 数据来源：`store.bindings.filter { $0.channel == channel.rawValue }`

### 1.2 ChannelCardView 需要的新依赖

- 传入 `bindings: [AgentBinding]`（该渠道的绑定列表）和 `agents: [Agent]`（全部智能体，用于显示名称）
- 传入 `onBindAgent` / `onUnbindAgent` 回调（由父视图 `ChannelView` 处理 store 操作）

### 1.3 ChannelView 需要注入 AgentStore

当前 `ChannelView` 只有 `@Environment(GatewayService.self)`，需要新增：
- `@Environment(AgentStore.self)` — 读取 agents 列表和 bindings，执行 addBinding/removeBinding

### 1.4 新组件：ChannelAgentPickerSheet

从渠道侧选择智能体并创建绑定的 Sheet：
- 智能体列表（emoji + name + description），支持��索
- 可选的 peer 匹配条件表单
- 确认后创建 binding

---

## 改动二：Agent 渠道绑定 Tab 入口（智能体 → 选渠道）

**文件**: [AgentBindingsView.swift](ClawdHome/Views/Agent/AgentBindingsView.swift)

### 2.1 重写 AddBindingSheet 为三步流程

**Step 1 — 选择渠道**
- 使用 `ChannelType.allCases` 卡片（iconName + iconColor + displayName + subtitle）
- 每张卡片显示配置状态徽章（已配置/未配置）
- 从 gateway `configGetFull` 加载 `channels.*` 判断状态

**Step 2 — 配置渠道凭据（按类型分流，渠道未配置时显示）**

| 渠道 | 方式 | 组件 |
|------|------|------|
| 钉钉 | 凭据表单（appKey + appSecret） | 弹 `ChannelBotConfigSheet` |
| 飞书 | 双路径：凭据表单 或 QR 扫码 | `ChannelBotConfigSheet` 或 `FeishuChannelOnboardingSheet` |
| Telegram | 凭据表单（botToken） | 弹 `ChannelBotConfigSheet` |
| Discord | 凭据表单（botToken + applicationId） | 弹 `ChannelBotConfigSheet` |
| 微信 | QR 扫码 | 弹 `FeishuChannelOnboardingSheet(flow: .weixin)` |

- 渠道已配置 → 跳过此步，直接进入 Step 3
- 提供"重新配置"入口以修改已有凭据

**Step 3 — 绑定匹配条件**
- Account ID（可选）
- Peer ID + Peer Kind（可选）
- Discord 额外 Guild ID
- 确认 → `store.addBinding(...)`

### 2.2 更新绑定列表行

`bindingRow()` 改用 `ChannelType(rawValue: binding.channel)` 获取正确图标和颜色。

---

## 改动三：小幅增强

### 3.1 AgentBinding 添加 ChannelType 桥接

**文件**: [AgentBinding.swift](ClawdHome/Models/AgentBinding.swift)

```swift
var channelType: ChannelType? { ChannelType(rawValue: channel) }
```
更新 `channelIcon` 优先使用 `channelType?.iconName`。

### 3.2 暴露 AgentStore.username

**文件**: [AgentStore.swift](ClawdHome/Services/Stores/AgentStore.swift)

`private var username` → `private(set) var username`（供 QR onboarding 获取 Shrimp 用户名）。

### 3.3 ChannelType 添加 SwiftUI Color

**文件**: [ChannelType.swift](ClawdHome/Models/ChannelType.swift)

添加 `var swiftUIColor: Color` 计算属性，统一 string→Color 转换逻辑，消除 `ChannelCardView` 中的重复 switch。

---

## 数据流总览

```
┌─────────────────────────────────────┐
│  侧边栏「消息渠道」                    │
│  ChannelView                        │
│                                     │
│  ┌──────────┐  ┌──────────┐         │
│  │ 钉钉卡片  │  │ 微信卡片  │  ...    │
│  │          │  │          │         │
│  │ [智能体A] │  │ [+选智能体]│         │
│  │ [+添加]  │  │          │         │
│  └──────────┘  └──────────┘         │
│       │              │              │
│       ▼              ▼              │
│  ChannelAgentPickerSheet            │
│  选择智能体 + peer 条件              │
└──────────┬──────────────────────────┘
           │
           ▼
    store.addBinding()  ◄──── bindings[] ────►  store.addBinding()
                                                       ▲
┌──────────────────────────────────────────────────────┐│
│  Agent Workspace → 渠道绑定 Tab                       ││
│  AgentBindingsView                                   ││
│                                                      ││
│  已绑定列表：[钉钉/peer:xxx] [Telegram/*] ...         ││
│                                                      ││
│  [+ 添加绑定] → AddBindingSheet                       ││
│    Step 1: 选渠道（5 个 ChannelType 卡片）             ││
│    Step 2: 配凭据（表单/QR PTY，未配置时）             ││
│    Step 3: peer 匹配条件 → addBinding ────────────────┘│
└──────────────────────────────────────────────────────┘
```

---

## 实施顺序

1. **基础改动**：`AgentBinding.channelType`、`AgentStore.username` 暴露、`ChannelType.swiftUIColor`
2. **Agent 入口**：重写 `AddBindingSheet`（三步流程）+ 更新 `bindingRow` 显示
3. **渠道入口**：新增 `ChannelAgentPickerSheet` + 改造 `ChannelCardView` 智能体区域
4. **联动验证**：确认两端操作同一份 bindings 数据，刷新互相可见

## 验证方式

1. `make build` 构建通过
2. **渠道入口测试**：
   - 侧边栏「消息渠道」→ 钉钉卡片 → 点击智能体区域 → 选择智能体 → 绑定成功 → 卡片显示已绑定的智能体
   - 微信卡片 → 凭据未配置时底部按钮先走 QR → 再绑定智能体
3. **Agent 入口测试**：
   - Agent Workspace → 渠道绑定 Tab → 添加绑定 → 选钉钉 → 填凭据（或已配置则跳过）→ 填 peer 条件 → 绑定成功
   - 选微信 → 弹 PTY 终端 QR 窗口
4. **双向联动**：从渠道入口创建的绑定在 Agent 渠道绑定 Tab 可见，反之亦然
5. **删除**：两边都能删除绑定，互相同步
