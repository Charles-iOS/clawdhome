# 模型设置页面与多 Provider 配置设计方案

## 一、背景与现状

当前新主线 app 没有一个面向用户的完整“模型设置”入口。仓库中已有一些可复用能力，但链路还没有收拢：

- `SidebarDestination` 目前只有数字员工、定时任务、技能、消息渠道、设置，没有模型页入口。
- `ModelConfigView` 能展示 Gateway 返回的模型列表和动态 Provider Key 行，但更偏只读诊断页，缺少添加 Provider、选择模型、设置默认模型的完整流程。
- `LLMManagerTab` / `AddProviderModelSheet` 具备“全局模型池 + 添加账户”的旧能力，但当前不在新主线侧边栏中暴露，且内置模型清单目前主要是 MiniMax。
- `ProviderKeyConfig` 已覆盖 OpenAI、MiniMax、MiniMax 国内、OpenRouter、Ollama、Moonshot、Kimi Coding、Z.AI 等 Provider 配置路径，可作为 Provider catalog 的基础。
- `AgentStore.setAgentModel()` 和智能体编辑页已经支持 `agents.list[].model.primary`，但依赖一个稳定的模型池供用户选择。

本方案目标是把模型配置做成新主线的一等功能页，让用户可以在 app 内配置 MiniMax、OpenAI/GPT、OpenAI-compatible、OpenRouter、本地 Ollama 等模型，并把模型选择写入当前 Gateway profile。

## 二、设计目标

1. 新增独立“模型”页面，用户不需要打开终端或旧窗口即可完成模型配置。
2. 支持 MiniMax、OpenAI/GPT、OpenAI-compatible、自定义 Base URL、OpenRouter、Ollama 等 Provider。
3. 支持 Provider 账户管理：添加、编辑、删除、启停、验证连接、刷新模型列表。
4. 支持模型选择与路由：全局主模型、备用模型、视觉模型、智能体单独覆盖。
5. 配置严格作用于当前 selected profile，不能静默写入 legacy `~/.openclaw`。
6. API Key 只进 Keychain；写入 OpenClaw 配置时通过现有 `GatewayService.configPatch()` / `OpenClawProviderKeySync` 做受控同步。
7. 模型列表不依赖硬编码 GPT 型号；优先从 Provider `/models` 或 Gateway `models.list` 动态拉取，内置清单只作为首次引导和离线 fallback。

非目标：

- 不重做 OpenClaw 的模型运行时协议。
- 不把所有 Provider 的完整商业模型目录固化进 app。
- 不在本轮实现团队云端同步；本方案只覆盖本机 app + 当前 profile。

## 三、信息架构

### 3.1 侧边栏入口

在 `SidebarDestination` 增加：

```swift
case models
```

推荐位置：

- Section：`能力`
- 排序：`消息渠道` 前或后均可，建议为 `技能`、`模型`、`消息渠道`、`定时任务`
- 图标：`cpu.fill` 或 `sparkles.rectangle.stack.fill`
- 文案：`模型`

`MainView.detailView` 增加：

```swift
case .models:
    ModelSettingsView()
```

### 3.2 页面结构

新页面命名建议：`ModelSettingsView`。

页面整体分为四块：

1. 顶部 Hero 区
2. Provider 账户区
3. 默认模型与路由区
4. 诊断与同步区

推荐布局：

```text
模型
管理当前 Profile 可用的模型 Provider、API Key、默认模型和智能体覆盖。

[当前 Profile] [全局默认模型] [已启用 Provider] [模型连通性]

┌ Provider 账户 ─────────────────────────────┐
│ + 添加 Provider                             │
│ MiniMax 国内        已配置 Key   7 models   │
│ OpenAI / GPT        待验证       12 models  │
│ OpenAI Compatible   自定义网关   4 models   │
└────────────────────────────────────────────┘
z
┌ 默认模型与路由 ────────────────────────────┐
│ 主模型        [openai/...]                 │
│ 备用模型      [minimax/...] [openrouter/...]│
│ 视觉模型      [minimax/MiniMax-VL-01]       │
│ 智能体覆盖    Alice -> MiniMax              │
└────────────────────────────────────────────┘

┌ 诊断 ──────────────────────────────────────┐
│ 刷新模型列表 | 测试选中模型 | 同步到 Gateway │
│ 最近错误 / 最近同步时间                    │
└────────────────────────────────────────────┘
```

## 四、页面功能设计

### 4.1 空状态

当当前 profile 没有任何 Provider 时，展示强引导卡片：

- 标题：`还没有配置模型`
- 描述：`添加 MiniMax、OpenAI/GPT 或 OpenAI-compatible Provider 后，数字员工即可选择模型运行。`
- 主按钮：`添加 Provider`
- 次按钮：`打开 OpenClaw 终端`，作为高级回退
- 快捷卡片：`MiniMax`、`OpenAI / GPT`、`OpenAI-compatible`、`Ollama`

### 4.2 Provider 账户列表

每个 Provider 账户卡片展示：

- Provider 名称：如 `MiniMax 国内`、`OpenAI / GPT`
- 账户名：如 `主账号`、`备用账号`
- 状态：`未配置 Key`、`已保存`、`已同步`、`验证失败`
- 模型数量：已选择 / 已发现的模型数
- 默认标识：如果该账户包含当前全局主模型，显示 `默认`
- 操作：`编辑`、`验证`、`刷新模型`、`删除`

列表顶部操作：

- `添加 Provider`
- `刷新全部模型列表`
- `只看异常`

### 4.3 添加 Provider 向导

使用 sheet 或 modal，分 4 步。

#### Step 1：选择 Provider

Provider 卡片分组：

- 推荐：`MiniMax`、`OpenAI / GPT`
- 聚合：`OpenRouter`
- 兼容接口：`OpenAI-compatible`
- 本地：`Ollama`
- 更多：`Anthropic`、`Google Gemini`、`Moonshot`、`Kimi Coding`、`Z.AI`

每张卡片显示：

- 名称
- 简短说明
- 鉴权方式：API Key / Base URL / OAuth
- 是否支持自动拉取模型

#### Step 2：填写连接信息

不同 Provider 显示不同字段：

- OpenAI / GPT：`API Key`，可选 `Organization` / `Project`，高级项可配置 `Base URL`
- MiniMax：`API Key`，地区选择 `国际` / `国内`，自动带出 `api`、`baseUrl`、`authHeader`
- OpenAI-compatible：`Provider ID`、`显示名称`、`Base URL`、`API Key`、`模型 ID 前缀`
- OpenRouter：`API Key`
- Ollama：`服务地址`

交互要求：

- API Key 使用 `SecureField`
- 保存前不明文回显
- 编辑已有账户时，默认展示 `已配置，留空保持不变`
- 高级字段默认折叠，避免普通用户被细节打断

#### Step 3：发现与选择模型

模型来源优先级：

1. 当前 Gateway 的 `models.list`
2. Provider 的 `/models` 接口，OpenAI-compatible 可复用 `CustomModelConfigUtils.fetchModelIDs`
3. app 内置精选清单，如 MiniMax 引导清单
4. 手动输入模型 ID

模型列表能力：

- 搜索
- 多选
- 全选 / 清空
- 标记能力：文本、视觉、推理、本地
- 显示完整写入 ID：例如 `provider/model-id`

OpenAI/GPT 不建议硬编码固定型号。默认体验应是用户填 Key 后点击 `拉取模型列表`，app 根据返回结果生成 `openai/<model-id>` 候选项。

MiniMax 可以保留内置精选清单作为 fallback，但保存时仍允许用户手动新增服务端已支持的新模型。

#### Step 4：设置默认路由

向导最后一步提供快捷选择：

- `设为全局主模型`
- `加入备用模型`
- `设为视觉模型`
- `只添加到模型池，稍后再设置`

如果是第一次添加 Provider，默认勾选 `设为全局主模型`，减少配置成本。

### 4.4 默认模型与备用模型

页面提供一个“模型路由”卡片：

- 主模型：写入 `agents.defaults.model.primary`
- 备用模型：写入 `agents.defaults.model.fallbacks`
- 视觉模型：如 OpenClaw 支持独立 image model，则写入对应字段；若当前 schema 不支持，先作为 app 层 pending 设计，不落盘

交互：

- 使用 picker 选择已启用模型
- 备用模型可拖拽排序
- 删除主模型时必须先选择新的主模型，或明确切回未设置
- 如果模型来自已禁用 Provider，显示黄色风险提示

### 4.5 智能体单独选模型

模型页显示“智能体覆盖”摘要：

- 默认展示有覆盖的智能体列表
- 每行：智能体名称、当前覆盖模型、继承全局默认按钮
- 点击可跳转到 `AgentEditorView` 或直接内联修改

写入规则沿用现有能力：

- 设置覆盖：`agents.list[].model.primary = modelId`
- 清除覆盖：移除该智能体的 `model`
- UI 文案：`使用全局默认`

### 4.6 诊断与测试

提供三类诊断：

- Provider 验证：检查 API Key / Base URL 是否可用，能否拉取模型列表。
- Gateway 同步：检查 app 本地模型池、Keychain、当前 profile `openclaw.json` 是否一致。
- 模型试跑：对选中模型发送轻量 ping，返回可用 / 超时 / 鉴权失败 / 模型不存在。

错误文案要给出可行动建议：

- `401 / 403`：提示检查 API Key 或账户权限。
- `404 model_not_found`：提示刷新模型列表或手动确认模型 ID。
- `network timeout`：提示检查代理、Base URL 或本地服务是否启动。
- `Gateway 未连接`：允许保存本地草稿，但写入 OpenClaw 的操作禁用。

## 五、数据与配置设计

### 5.1 Provider 定义

现有 `ProviderKeyConfig` 可扩展为更完整的 Provider catalog。

建议新增：

```swift
struct ModelProviderDefinition: Identifiable, Codable {
    let id: String
    let displayName: String
    let category: ProviderCategory
    let authFields: [ProviderAuthField]
    let defaultBaseURL: String?
    let openClawAPIType: String?
    let configPath: String
    let sideConfigs: [ProviderSideConfig]
    let supportsModelDiscovery: Bool
    let supportsOAuth: Bool
}
```

`ProviderKeyConfig` 可以继续保留，短期作为写入 OpenClaw 的适配层；长期迁移为 `ModelProviderDefinition`。

### 5.2 Provider 账户

现有 `ProviderTemplate` 建议升级为：

```swift
struct ModelProviderAccount: Codable, Identifiable {
    var id: UUID
    var providerId: String
    var accountName: String
    var displayName: String
    var baseURL: String?
    var authMode: AuthMode
    var selectedModelIds: [String]
    var discoveredModelIds: [String]
    var isEnabled: Bool
    var lastValidatedAt: Date?
    var lastValidationError: String?
}
```

兼容策略：

- 继续读取旧 `global-models.json` 的 `ProviderTemplate`
- 首次启动迁移为 `ModelProviderAccount`
- `ProviderTemplate.modelIds` 映射到 `selectedModelIds`
- 凭据仍通过 `providerId:accountName` 从 `GlobalSecretsStore` / Keychain 查找

### 5.3 模型条目

扩展 `ModelEntry`：

```swift
struct ModelCatalogEntry: Codable, Identifiable, Hashable {
    let id: String
    let providerId: String
    let rawModelId: String
    var label: String
    var capabilities: Set<ModelCapability>
    var contextWindow: Int?
    var maxTokens: Int?
    var source: ModelSource
}
```

`id` 统一为写入 OpenClaw 的完整 ID，例如：

- `minimax/MiniMax-M2.7`
- `openai/<provider-returned-model-id>`
- `openrouter/<provider-returned-model-id>`
- `ollama/<local-model-name>`

### 5.4 OpenClaw 写入路径

Provider 凭据与 side config：

```text
models.providers.<providerId>.apiKey
models.providers.<providerId>.api
models.providers.<providerId>.baseUrl
models.providers.<providerId>.authHeader
models.providers.<providerId>.models
```

默认模型：

```text
agents.defaults.model.primary
agents.defaults.model.fallbacks
```

智能体覆盖：

```text
agents.list[].model.primary
```

写入方式：

- 在线：统一通过 `GatewayService.configGetFull()` + `configPatch()`，避免覆盖并发修改。
- 多字段 Provider：用 `GatewayService.applyConfigLeafPatches()` 或单次 patch 合并写入，避免 schema 校验中间态失败。
- 离线：默认只允许保存 app 本地草稿；如要直接写当前 profile `openclaw.json`，必须基于 `GatewayProfileStore.selectedResolution`，并明确标注“离线写入”。

### 5.5 凭据存储

凭据分两层：

- 本机安全存储：Keychain，供 app 后续编辑、验证、同步使用。
- OpenClaw runtime 配置：按用户点击保存 / 同步写入当前 profile。

规则：

- UI 不展示完整 API Key。
- 导出诊断信息时必须脱敏。
- 删除 Provider 账户时，同时提示是否清理 Keychain 凭据。
- 修改账户名时要迁移旧 secret key，避免凭据丢失。

## 六、MiniMax 与 OpenAI/GPT 配置细节

### 6.1 MiniMax

Provider ID：

- `minimax`
- `minimax-cn`

推荐默认：

- 国际 / 通用：`minimax`
- 国内接入：`minimax-cn`

写入示例：

```json
{
  "models": {
    "providers": {
      "minimax-cn": {
        "api": "anthropic-messages",
        "baseUrl": "https://api.minimaxi.com/anthropic",
        "authHeader": true,
        "apiKey": "<from-keychain-or-user-input>",
        "models": []
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "minimax/MiniMax-M2.7",
        "fallbacks": []
      }
    }
  }
}
```

`models` 数组可使用现有 `minimaxOpenClawModelCatalog` 作为初始 catalog，但 UI 必须允许手动新增模型 ID，以适配 MiniMax 后续发布的新模型。

### 6.2 OpenAI / GPT

Provider ID：

- `openai`

写入示例：

```json
{
  "models": {
    "providers": {
      "openai": {
        "apiKey": "<from-keychain-or-user-input>"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "openai/<model-id-from-provider>",
        "fallbacks": []
      }
    }
  }
}
```

设计原则：

- GPT 模型 ID 不在 app 内长期硬编码。
- 用户保存 API Key 后，优先从 Provider 或 Gateway 获取可用模型列表。
- 如拉取失败，允许手动输入 `openai/<model-id>`。
- 如果未来 OpenAI OAuth 能在当前环境中稳定使用，可把 `supportsOAuth` 接到“使用 ChatGPT 登录授权”按钮；短期先保留 API Key 方式。

### 6.3 OpenAI-compatible

适用于自建网关、第三方代理、企业内网模型服务。

必填：

- Provider ID：如 `my-gateway`
- 显示名称：如 `公司模型网关`
- Base URL：如 `https://llm.example.com/v1`
- API Key：可选
- API 类型：默认 `openai-completions`

模型发现：

- 通过 `GET <baseURL>/models`
- 支持 OpenAI 风格 `{ "data": [{ "id": "..." }] }`
- 支持简化 `{ "models": [{ "id": "..." }] }`
- 失败时允许手动输入

写入示例：

```json
{
  "models": {
    "providers": {
      "my-gateway": {
        "api": "openai-completions",
        "baseUrl": "https://llm.example.com/v1",
        "apiKey": "<optional>",
        "models": [
          { "id": "gpt-compatible-large", "name": "GPT Compatible Large" }
        ]
      }
    }
  }
}
```

## 七、关键用户流程

### 7.1 首次配置 MiniMax

1. 用户进入侧边栏 `模型`。
2. 点击 `添加 Provider`，选择 `MiniMax 国内`。
3. 输入 API Key。
4. 页面展示内置 MiniMax 候选模型，也允许刷新远程模型。
5. 用户选择一个主模型，可选备用模型。
6. 点击保存。
7. app 将 Key 保存到 Keychain，并通过 Gateway patch 当前 profile。
8. 页面显示 `已同步`，全局默认模型更新。

### 7.2 配置 OpenAI/GPT

1. 用户选择 `OpenAI / GPT`。
2. 输入 API Key。
3. 点击 `拉取模型列表`。
4. app 展示 Provider 返回的模型 ID，并自动补齐写入前缀 `openai/`。
5. 用户选择主模型与备用模型。
6. 保存后写入 `models.providers.openai.apiKey` 与 `agents.defaults.model`。

### 7.3 添加自定义兼容网关

1. 用户选择 `OpenAI-compatible`。
2. 填写 Provider ID、显示名称、Base URL、API Key。
3. 点击 `测试连接`。
4. 成功后从 `/models` 拉取模型。
5. 用户选择模型并保存。
6. 如果 Gateway 未连接，则保存为本地草稿，提示稍后同步。

### 7.4 给单个智能体换模型

1. 用户在模型页的“智能体覆盖”区域找到目标智能体。
2. 选择模型，或选择 `使用全局默认`。
3. 在线时即时写入 `agents.list[].model.primary`。
4. 失败时保留原模型并显示错误。

## 八、技术实现方案

### Phase 1：暴露模型入口与页面骨架

改动：

- `SidebarView.swift`：新增 `models` destination。
- `MainView.swift`：路由到 `ModelSettingsView`。
- 新建 `EZRWorkerApp/EZRWorker/Views/Models/ModelSettingsView.swift`。

复用：

- `PageHeroHeader`
- `GatewayProfileStore`
- `GatewayService`
- `GlobalModelStore`
- `ProviderKeychainStore`

验收：

- 侧边栏出现 `模型`。
- Gateway 未连接时页面可读，写入按钮禁用。
- 无 Provider 时显示首次引导。

### Phase 2：Provider 账户 CRUD

改动：

- 将 `AddProviderModelSheet` 的能力迁移或重构为 `AddModelProviderSheet`。
- 扩展 `builtInModelGroups` 为更通用的 provider catalog。
- 兼容读取旧 `ProviderTemplate`。

验收：

- 能添加 MiniMax / OpenAI / OpenAI-compatible。
- 能编辑账户名称、模型选择和凭据。
- 删除账户时可清理对应 secret。

### Phase 3：模型发现与验证

改动：

- 新增 `ModelCatalogService`，负责 Provider `/models`、Gateway `models.list`、手动模型合并去重。
- 复用 `CustomModelConfigUtils.fetchModelIDs`。
- 增加 `ModelPingService` 的 UI 调用入口。

验收：

- OpenAI-compatible 能通过 `/models` 拉取模型。
- 拉取失败时可以手动输入模型 ID。
- 验证失败有明确错误文案。

### Phase 4：写入当前 profile 的 OpenClaw 配置

改动：

- 新增 `ModelRoutingStore` 或在 `GlobalModelStore` 中补充 routing 状态。
- 通过 `GatewayService.configGetFull()` + `configPatch()` 更新：
  - `models.providers.*`
  - `agents.defaults.model`
  - `agents.list[].model.primary`
- 对 MiniMax 等多字段 Provider 使用单次 patch。

验收：

- 设置主模型后，`openclaw.json` 中 `agents.defaults.model.primary` 正确变化。
- 设置备用模型后，`fallbacks` 顺序正确。
- 修改 Provider 不会覆盖其他配置块。

### Phase 5：多 profile 与迁移

改动：

- 所有离线读写都必须使用 `GatewayProfileStore.selectedResolution`。
- 增加旧 `global-models.json` 到新 schema 的迁移。
- 保留“打开 OpenClaw 终端”作为高级 fallback。

验收：

- 切换 profile 后，页面展示对应 profile 的模型配置。
- 不会在 selected profile 缺失时写入 `~/.openclaw`。
- legacy profile 被显式选中时仍能正常读写 legacy 路径。

## 九、涉及文件清单

建议新增：


| 文件                                                                | 用途                  |
| ----------------------------------------------------------------- | ------------------- |
| `EZRWorkerApp/EZRWorker/Views/Models/ModelSettingsView.swift`     | 新模型设置页              |
| `EZRWorkerApp/EZRWorker/Views/Models/AddModelProviderSheet.swift` | 添加 / 编辑 Provider 向导 |
| `EZRWorkerApp/EZRWorker/Views/Models/ModelRoutingSection.swift`   | 主模型、备用模型、视觉模型 UI    |
| `EZRWorkerApp/EZRWorker/Views/Models/ProviderAccountCard.swift`   | Provider 账户卡片       |
| `EZRWorkerApp/EZRWorker/Services/ModelCatalogService.swift`       | 模型发现、合并、刷新          |
| `EZRWorkerApp/EZRWorker/Services/ModelRoutingStore.swift`         | 当前 profile 模型路由读写   |
| `EZRWorkerApp/EZRWorker/Models/ModelProviderDefinition.swift`     | Provider catalog 定义 |
| `EZRWorkerApp/EZRWorker/Models/ModelProviderAccount.swift`        | Provider 账户持久化模型    |


建议修改：


| 文件                                                              | 改动                                    |
| --------------------------------------------------------------- | ------------------------------------- |
| `EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift`          | 增加模型入口                                |
| `EZRWorkerApp/EZRWorker/App/MainView.swift`                     | 增加模型页面路由                              |
| `EZRWorkerApp/EZRWorker/Models/ModelsStatus.swift`              | 扩展 `ModelEntry` 或新增 catalog entry     |
| `EZRWorkerApp/EZRWorker/Models/GlobalModelStore.swift`          | 迁移旧全局模型池，或拆分为新 store                  |
| `EZRWorkerApp/EZRWorker/Models/ProviderKeyConfig.swift`         | 补充 Provider 元数据和 OpenAI-compatible 定义 |
| `EZRWorkerApp/EZRWorker/Services/OpenClawProviderKeySync.swift` | 支持 account/baseURL/custom provider    |
| `EZRWorkerApp/EZRWorker/Views/Agent/AgentEditorView.swift`      | 与模型页共用模型选择数据源                         |
| `EZRWorkerApp/EZRWorker/Views/Agent/AgentWorkspaceView.swift`   | 与模型页共用模型选择数据源                         |


## 十、验收标准

基础验收：

- 侧边栏有 `模型` 页面。
- 用户可添加 MiniMax Provider，并设置为全局默认模型。
- 用户可添加 OpenAI/GPT Provider，通过远程或手动方式选择模型。
- API Key 不明文展示，重启 app 后仍能识别“已配置”。
- Gateway 在线时，保存会写入当前 profile 的 OpenClaw 配置。
- Gateway 离线时，页面能解释哪些操作不可用。

配置验收：

- `agents.defaults.model.primary` 能正确写入和读取。
- `agents.defaults.model.fallbacks` 能正确写入、排序和删除。
- `agents.list[].model.primary` 的智能体覆盖能正确写入和清除。
- MiniMax 的 `api`、`baseUrl`、`authHeader`、`models` 能以单次 patch 写入，避免 schema 中间态失败。
- OpenAI-compatible 的 `baseUrl` 和 `models` 能正确保存。

安全验收：

- API Key 不进入日志。
- 删除 Provider 账户有二次确认。
- 导出错误信息时 key 必须脱敏。
- 不在 selected profile 缺失时写 legacy `~/.openclaw`。

体验验收：

- 首次配置路径不超过 4 步。
- 模型列表支持搜索和手动输入。
- 所有失败态都有可执行建议。
- 智能体页面和模型页面看到的模型列表一致。

## 十一、推荐优先级

优先做最小闭环：

1. 新增侧边栏 `模型` 页面。
2. 支持 MiniMax、OpenAI/GPT、OpenAI-compatible 三类 Provider。
3. 支持 API Key / Base URL 保存、模型选择、主模型写入。
4. 接入智能体覆盖选择。

第二阶段再补：

- 备用模型拖拽排序。
- 视觉模型独立配置。
- 模型 ping 试跑。
- Provider 账户启停。
- OAuth 授权。

这样可以先解决“app 里不能设置模型”的核心问题，同时为后续更多 Provider 和模型能力留出扩展口。