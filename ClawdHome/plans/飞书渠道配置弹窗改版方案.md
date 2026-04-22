# 飞书渠道配置弹窗改版方案

## 摘要
- 这次只改飞书卡片的主入口逻辑。
- 飞书未配置时，底部 `设置机器人` 保持现状：先走原来的接入流，仍可选扫码绑定或手动凭据。
- 飞书已配置后，底部 `设置机器人` 改为打开统一的“渠道配置”弹窗；卡片里单独的 `配对管理` 入口对飞书移除，Telegram 等其它渠道维持现状。
- 新弹窗同时承载三类能力：渠道策略配置、重新绑定入口、旧配对逻辑。`groups` 走高级 JSON 编辑，不做普通表单版的逐群配置。

## 关键改动
### 入口与导航
- 在 `ChannelView` 的 sheet 路由里新增一个飞书专用配置目的地，例如 `.channelConfig(.feishu)`。
- `onSetup` 的决策改为：
  - 飞书未配置：沿用当前 `methodPicker -> interactive/credentials`。
  - 飞书已配置：直接打开新的 `FeishuChannelConfigSheet`。
- 飞书卡片不再展示独立的 `配对管理` 行；其它渠道继续保留现有配对入口。

### 新的飞书配置弹窗
- 新建一个飞书专用弹窗视图，保持 `ChannelBotConfigSheet` 继续作为“手动凭据编辑子流程”存在，不把它直接扩成大杂烩。
- 弹窗分 3 个区块：
  - 接入状态区：展示当前绑定模式
    - 扫码模式：显示“已通过扫码绑定”
    - 手动模式：显示“已通过手动凭据配置”
  - 渠道策略区：编辑这些顶层字段
    - `dmPolicy`
    - `groupPolicy`
    - `requireMention`
    - `groupAllowFrom`
    - `groups` 高级 JSON
  - 配对管理区：保留旧的审批/移除逻辑
- 策略区约束：
  - `dmPolicy` 只管私信入口策略。
  - `groupPolicy`、`requireMention`、`groupAllowFrom` 只管群组全局默认策略。
  - `groups` 只编辑 `channels.feishu.groups` 这一个对象，支持 `*` 和逐群 override，但入口是高级 JSON，不做单群表单。
  - `groupAllowFrom` 用普通表单编辑，建议一行一个 ID；文案明确提示这里只接受群内发送者 `open_id (ou_xxx)`，`oc_xxx` 这类群 ID 应该放进 `groups`。
- 接入状态区动作：
  - 始终提供 `重新扫码绑定`，直接复用现有 `FeishuChannelOnboardingSheet`。
  - 提供手动凭据入口，但不在统一弹窗里直接编辑 `appSecret`
    - 当前是扫码模式：按钮文案用“改用手动凭据”
    - 当前是手动模式：按钮文案用“编辑手动凭据”
  - 这个入口继续复用现有 `ChannelBotConfigSheet(channelType: .feishu)`。

### 数据读取与保存
- 新弹窗加载时先读 `gateway.configGetFull()`；若 gateway 不在线，则降级读本地 `~/.openclaw/openclaw.json` 做展示。
- gateway 不在线时：
  - 允许查看当前值
  - 禁用保存、重新扫码、手动凭据入口
  - 显示“当前为离线只读”提示
- 保存时对 `channels.feishu` 做一次统一 `configPatch`，不要分散写多个 patch。
- `groups` JSON 要求：
  - 只接受对象根节点
  - 语法错误时禁用保存
  - 加载时 pretty print
  - 保存时仅回写 `channels.feishu.groups`，不动同级其它字段
- 顶层普通字段与 `groups` JSON 同次提交，避免 hash 冲突和部分成功。

### 旧配对逻辑的保留方式
- 配对区始终显示，但 `dmPolicy != pairing` 时顶部加状态说明：
  - 当前不再自动产生新的待审批请求
  - 已有配对数据仍可查看和管理
- 保留这些能力：
  - 手动输入配对码审批
  - 待审批列表 approve/reject
  - 已配对用户移除
- 旧配对区的数据语义必须和群组策略彻底拆开：
  - 配对区只代表私信 pairing store / DM allow-from store
  - `groupAllowFrom` 和 `groups` 不得混入“已配对用户”
- 对飞书来说，配对区的数据源应回到 pairing store 语义：
  - 待审批：`feishu-pairing.json`，按默认 account 过滤
  - 已配对：`feishu-<account>-allowFrom.json` 及兼容 legacy allowFrom store
- 卡片上的 `已配对用户 / 待处理请求` 统计也应与这个 DM 配对语义保持一致，不再把群组策略条目算进去。

## 接口与类型
- 新增一个飞书配置弹窗视图，例如 `FeishuChannelConfigSheet`。
- 新增一个草稿/视图模型类型，例如 `FeishuChannelConfigDraft`，至少包含：
  - `dmPolicy`
  - `groupPolicy`
  - `requireMention`
  - `groupAllowFromText`
  - `groupsJSONText`
  - `credentialMode`
  - `isReadOnly`
  - `validationError`
- `ChannelSetupDestination` 增加一个“已配置后打开统一配置弹窗”的分支。
- 如需避免散落字符串，补两个枚举辅助类型：
  - `FeishuDmPolicy`
  - `FeishuGroupPolicy`

## 测试场景
- 飞书未配置时，点击 `设置机器人` 仍进入原来的接入方式选择与扫码/手动流程。
- 飞书已配置时，点击 `设置机器人` 打开统一配置弹窗，卡片里不再出现单独的飞书 `配对管理` 行。
- 修改 `dmPolicy/groupPolicy/requireMention/groupAllowFrom` 后保存成功，刷新后值一致。
- `groups` 填非法 JSON 时保存按钮禁用；填合法对象后可保存，并能保留 `"*"` 和逐群 override。
- `dmPolicy != pairing` 时，配对区仍展示，但带说明文案；待审批区不会误导成“当前仍自动配对”。
- `重新扫码绑定` 完成后，弹窗和卡片状态能自动刷新。
- `改用手动凭据/编辑手动凭据` 仍能进入原有凭据弹窗。
- 飞书卡片统计与弹窗配对区都只反映 DM pairing，不把 `groupAllowFrom/groups` 统计成“已配对用户”。

## 假设
- 本轮只做飞书，其他渠道不并入统一配置弹窗。
- 统一弹窗不直接编辑 `appSecret`，只负责策略配置和重新绑定入口。
- `allowFrom` 顶层私信白名单编辑先不做表单化，仍沿用旧配对/store 逻辑管理。
- `groups` 的复杂 per-group override 全部交给高级 JSON，不再额外设计可视化逐群编辑器。
