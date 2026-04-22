# 智能体 Workspace 重设计方案

## Context

**现状**：当前智能体系统是 prompt 模板管理器 — Agent 只有 systemPrompt/identity 文本字段，全局只能激活一个，激活时将 soul/identity patch 到 gateway 配置。无独立 workspace、不支持并发。

**OpenClaw 多智能体能力**：Gateway 原生支持多智能体并存。每个 agentId 是完全隔离的"大脑"：
- **Workspace**：`~/.openclaw/workspace-<agentId>/`（含 SOUL.md、IDENTITY.md、AGENTS.md、USER.md 等 persona 文件）
- **Agent 目录**：`~/.openclaw/agents/<agentId>/agent/`（认证配置、模型注册）
- **Sessions**：`~/.openclaw/agents/<agentId>/sessions/`（聊天历史 + 路由状态）
- **配置**：`openclaw.json` 中 `agents.list[]` 数组定义智能体，`bindings[]` 路由入站消息
- **Skills**：从智能体 workspace + 共享根加载，通过 `agents.defaults.skills` 和 `agents.list[].skills` 控制

**目标**：将 EZRWorker 的智能体管理从 prompt 模板升级为 OpenClaw 原生多智能体管理，支持：
1. 每个智能体拥有独立 workspace（persona 文件 + 工作文件 + 对话历史 + 工具配置）
2. 多智能体同时运行在同一 Gateway 上
3. Bindings 路由管理（渠道账号 → 智能体）
4. 通过 `openclaw.json` 配置驱动，与 OpenClaw CLI 保持一致

## 文件系统布局（OpenClaw 原生）

```
~<shrimp>/.openclaw/
  openclaw.json                          # 主配置（agents.list, bindings, channels）
  workspace/                             # 默认智能体(main)的 workspace
    SOUL.md / IDENTITY.md / AGENTS.md / TOOLS.md / MEMORY.md / USER.md
  workspace-<agentId>/                   # 非默认智能体的 workspace
    SOUL.md / IDENTITY.md / AGENTS.md / TOOLS.md / MEMORY.md / USER.md
    memory/                              # 记忆日志
  agents/
    <agentId>/
      agent/                             # 认证配置（auth-profiles.json 等）
        auth-profiles.json
      sessions/                          # 聊天历史 + 路由状态
  skills/                                # 共享 skills 目录
```

## 实现步骤

### Phase 1: 数据模型重设计

#### 1.1 重写 `Agent` 模型
**修改 `EZRWorkerApp/Models/Agent.swift`**

从 prompt 模板转为 OpenClaw 原生智能体定义：

```swift
struct Agent: Codable, Identifiable, Equatable {
    let id: String                    // agentId（如 "main", "work", "social"）
    var name: String                  // 显示名称
    var emoji: String                 // 图标
    var description: String           // 简短描述
    var category: AgentCategory       // 分类
    var preferredModel: String?       // 首选模型
    var skills: [String]              // 技能标签
    var isPreset: Bool                // 是否为预置模板

    // OpenClaw 原生字段
    var workspace: String?            // 自定义 workspace 路径（nil 时用默认路径）
    var agentDir: String?             // 自定义 agent 目录路径
    var isDefault: Bool               // 是否为默认智能体

    // 运行时状态（不持久化到 config）
    var status: AgentStatus = .idle
    var boundBindings: [AgentBinding] = []  // 关联的 bindings
    var sessionCount: Int = 0               // 活跃会话数
    var lastActiveAt: Date?                 // 最后活跃时间

    // 移除: systemPrompt, identity, userTemplate, isActive
    // 这些是 workspace 中的 .md 文件，不再作为 Agent 属性
}
```

#### 1.2 新增 `AgentStatus` 枚举
**新建 `EZRWorkerApp/Models/AgentStatus.swift`**

```swift
enum AgentStatus: Codable, Equatable {
    case idle              // workspace 存在，未收到过消息
    case active            // 有活跃 session
    case uninitialized     // 预置模板，workspace 未创建
}
```

#### 1.3 新增 `AgentBinding` 模型
**新建 `EZRWorkerApp/Models/AgentBinding.swift`**

对应 OpenClaw 的 `bindings[]` 配置：

```swift
struct AgentBinding: Codable, Identifiable, Equatable {
    var id: String { "\(agentId):\(channel):\(accountId ?? "*"):\(peerId ?? "*")" }
    var agentId: String
    var channel: String           // "whatsapp", "telegram", "discord", etc.
    var accountId: String?        // 渠道账号 ID
    var peerId: String?           // 精确 peer（私信/群组 ID）
    var peerKind: String?         // "direct", "group", etc.
    var guildId: String?          // Discord guild
    var teamId: String?           // Slack team
}
```

#### 1.4 保留 `AgentCategory`
**`EZRWorkerApp/Models/AgentCategory.swift`** 不变。

### Phase 2: 服务层重设计

#### 2.1 重写 `AgentStore`
**修改 `EZRWorkerApp/Services/Stores/AgentStore.swift`**

从本地 JSON 文件管理转为 **OpenClaw gateway 配置驱动**：

```swift
@MainActor @Observable
final class AgentStore {
    private(set) var agents: [Agent] = []
    private(set) var bindings: [AgentBinding] = []
    private(set) var presetTemplates: [Agent] = []   // bundled 预置模板

    // 依赖
    private var gateway: GatewayService?
    private var helperClient: HelperClient?
    private var username: String = ""                  // 当前 Shrimp 用户名
}
```

**核心方法**：

- `load(gateway:helperClient:username:)` — 初始化依赖
  1. 从 bundled `PresetAgents.json` 加载预置模板列表
  2. 通过 `gateway.configGetFull()` 获取 `openclaw.json` 的 `agents.list[]` 和 `bindings[]`
  3. 解析为 `[Agent]` 和 `[AgentBinding]`
  4. 通过 `helperClient.readFile()` 扫描各智能体 workspace 状态（是否存在 SOUL.md 等）

- `addAgent(id:name:fromPreset:)` — 添加智能体
  1. 若 fromPreset 非空，从预置模板获取初始 persona 内容
  2. 通过 `helperClient.createDirectory()` 创建 workspace 目录
  3. 通过 `helperClient.writeFile()` 写入初始 SOUL.md / IDENTITY.md / USER.md
  4. 通过 `gateway.configPatch()` 将新 agent 追加到 `agents.list[]`

- `removeAgent(id:)` — 删除智能体
  1. 通过 `gateway.configPatch()` 从 `agents.list[]` 移除
  2. 通过 `helperClient.deleteItem()` 清理 workspace 目录（需用户确认）
  3. 同时清理关联的 bindings

- `updateAgent(_:)` — 更新智能体元数据
  通过 `gateway.configPatch()` 更新 `agents.list[]` 中对应条目

- `addBinding(_:)` / `removeBinding(_:)` — 管理 bindings
  通过 `gateway.configPatch()` 更新 `bindings[]` 配置

- `refreshStatus()` — 刷新运行时状态
  扫描各智能体 sessions 目录获取会话数、最后活跃时间

**移除**：`activate()` / `deactivateAll()` / `saveCustomAgents()` / `loadCustomAgents()` — 不再需要本地 agents.json，不再有单一激活概念。

#### 2.2 新增 `AgentWorkspaceManager` 服务
**新建 `EZRWorkerApp/Services/AgentWorkspaceManager.swift`**

通过 HelperClient XPC 管理智能体 workspace 文件读写：

```swift
@MainActor @Observable
final class AgentWorkspaceManager {
    private var helperClient: HelperClient?
    private var username: String = ""

    // workspace 路径解析
    func workspacePath(for agentId: String) -> String {
        agentId == "main"
            ? ".openclaw/workspace"
            : ".openclaw/workspace-\(agentId)"
    }

    func personaFilePath(agentId: String, file: PersonaFile) -> String {
        "\(workspacePath(for: agentId))/\(file.rawValue)"
    }
}
```

**核心方法**（全部通过 HelperClient XPC）：
- `initializeWorkspace(agentId:seedContent:)` — 创建目录 + 写入初始 persona 文件
- `readPersonaFile(agentId:file:) -> String?` — 读取 persona 文件内容
- `writePersonaFile(agentId:file:content:)` — 写入 persona 文件
- `commitPersonaFile(agentId:file:message:)` — Git 提交 persona 文件变更
- `getPersonaFileHistory(agentId:file:) -> [CommitEntry]` — persona 文件变更历史
- `listWorkspaceFiles(agentId:) -> [FileEntry]` — 列出 workspace 内文件
- `listSessions(agentId:) -> [String]` — 列出 sessions 目录

**复用**：直接调用 HelperClient 现有的 `readFile(username:relativePath:)`、`writeFile(username:relativePath:data:)`、`createDirectory(username:relativePath:)`、`deleteItem(username:relativePath:)`、`commitPersonaFile(username:relativePath:message:)`、`getPersonaFileHistory(username:relativePath:)` 等方法。路径只需从固定的 `.openclaw/workspace/` 改为按 agentId 动态计算。

**不需要修改 HelperProtocol** — 现有 XPC 接口完全够用。

### Phase 3: 视图层重设计

#### 3.1 重写 `AgentGridView`
**修改 `EZRWorkerApp/Views/Agent/AgentGridView.swift`**

- 顶部工具栏：搜索框 + 分类筛选 + "新建智能体"按钮
- 网格显示所有已配置智能体（从 gateway `agents.list[]` 读取）
- 底部区域：预置模板库（可折叠），点击从模板创建新智能体
- 点击卡片 → 导航到 `AgentWorkspaceView`（不再用 sheet，用 NavigationStack push）
- 右键菜单：打开 Workspace、编辑信息、管理 Bindings、删除

#### 3.2 重写 `AgentCardView`
**修改 `EZRWorkerApp/Views/Agent/AgentCardView.swift`**

- 状态指示器替代绿色对勾：
  - 绿色脉冲点 = active（有活跃 session）
  - 灰色实心点 = idle
  - 虚线圆 = uninitialized
- 显示绑定的渠道图标（WhatsApp/Telegram/Discord 小图标）
- 显示 session 数量、最后活跃时间
- 移除 `isActive` 相关逻辑

#### 3.3 新增 `AgentWorkspaceView`（核心新视图）
**新建 `EZRWorkerApp/Views/Agent/AgentWorkspaceView.swift`**

复用 `PersonaDefView` (`CharacterDefTabView`) 的分栏编辑器架构：

```
AgentWorkspaceView(agentId: String)
├── 顶部: Agent 信息栏（emoji + name + status + 绑定渠道 tags）
├── TabView
│   ├── Tab "Persona"（复用 PersonaDefView 分栏编辑器）
│   │   ├── 左侧: PersonaFileSidebarView（SOUL.md, IDENTITY.md, ...）
│   │   └── 右侧: PersonaEditorAreaView（编辑器 + 历史 + 回滚）
│   ├── Tab "Bindings"（渠道绑定管理）
│   │   ├── 当前绑定列表
│   │   └── 添加/编辑/删除绑定
│   ├── Tab "Sessions"（对话历史浏览）
│   │   ├── Session 列表
│   │   └── Session 详情（经净化的回忆视图）
│   └── Tab "Settings"（智能体设置）
│       ├── 首选模型配置
│       ├── Skills 允许列表
│       └── Memory/QMD 配置
```

关键复用：
- `PersonaFile` 枚举直接复用，仅修改 `relPath` 计算逻辑使其接收 agentId 参数
- `PersonaEditorAreaView` 的编辑/保存/dirty检查/git历史/回滚逻辑直接复用
- `PersonaFileSidebarView` 的文件列表样式直接复用
- 传递 `username` 和修改后的 `relativePath`（`.openclaw/workspace-<agentId>/`）即可

#### 3.4 新增 `AgentBindingsView`
**新建 `EZRWorkerApp/Views/Agent/AgentBindingsView.swift`**

管理单个智能体的渠道绑定：
- 列表显示当前绑定（渠道 icon + 账号 + peer 信息）
- 添加绑定：选择渠道 → 选择账号 → 可选指定 peer
- 删除绑定
- 所有操作通过 `gateway.configPatch()` 更新 `bindings[]`

#### 3.5 新增 `AgentSessionsView`
**新建 `EZRWorkerApp/Views/Agent/AgentSessionsView.swift`**

浏览智能体的对话历史：
- 列出 `~/.openclaw/agents/<agentId>/sessions/` 下的会话文件
- 按时间排序，显示会话摘要
- 点击查看会话详情（经净化的内容）

#### 3.6 简化 `AgentEditorView`
**修改 `EZRWorkerApp/Views/Agent/AgentEditorView.swift`**

仅保留元数据编辑（name, emoji, category, description, preferredModel, skills）。
移除：systemPrompt/identity TextEditor、激活按钮。
作为 sheet 从 workspace view 调用。

#### 3.7 重写 `CreateAgentSheet`
**修改 `EZRWorkerApp/Views/Agent/CreateAgentSheet.swift`**

- 两种创建方式：
  - "从模板创建"：选择预置模板 → 填写 agentId + 名称 → 创建
  - "空白创建"：填写 agentId + 名称 + 基本信息 → 创建
- 创建流程：
  1. 验证 agentId 唯一性
  2. `AgentWorkspaceManager.initializeWorkspace()` 创建目录和 persona 文件
  3. `AgentStore.addAgent()` 更新 gateway 配置的 `agents.list[]`

#### 3.8 导航更新
**修改 `EZRWorkerApp/Views/MainView.swift`**

`case .agents` 的 detail view 从直接渲染 `AgentGridView()` 改为用 `NavigationStack` 包裹，支持 push 到 `AgentWorkspaceView`：

```swift
case .agents:
    NavigationStack {
        AgentGridView()
            .navigationDestination(for: String.self) { agentId in
                AgentWorkspaceView(agentId: agentId)
            }
    }
```

### Phase 4: PersonaFile 路径适配

**修改 `EZRWorkerApp/Views/PersonaDefView.swift` 中 `PersonaFile.relPath`**

当前 `relPath` 硬编码为 `.openclaw/workspace/<filename>`。需要改为支持 agentId：

```swift
enum PersonaFile {
    // ...existing cases...

    /// 默认路径（兼容旧 PersonaDefView）
    var relPath: String { relPath(agentId: nil) }

    /// 按智能体的路径
    func relPath(agentId: String?) -> String {
        let dir = agentId == nil || agentId == "main"
            ? ".openclaw/workspace"
            : ".openclaw/workspace-\(agentId!)"
        return "\(dir)/\(rawValue)"
    }
}
```

同步修改 `PersonaSelection.relPath` 的 `memoryLog` 路径。

### Phase 5: 数据迁移

在 `AgentStore.load()` 中执行一次性迁移：

1. **检测旧 `agents.json`**：如果 `~/.openclaw/agents.json` 存在（旧格式）
2. **迁移预置模板到 workspace**：对旧 JSON 中 `isActive == true` 的 agent：
   - 通过 `gateway.configPatch()` 在 `agents.list[]` 中注册
   - 创建 workspace 目录，写入 SOUL.md（从 systemPrompt）、IDENTITY.md（从 identity）、USER.md（从 userTemplate）
3. **备份**：重命名 `agents.json` → `agents.json.migrated`

对于从未激活过的旧 agent（纯模板），不迁移为 workspace — 它们仍作为预置模板在模板库中展示。

### Phase 6: 环境注入

**修改 `EZRWorkerApp/EZRWorkerApp.swift`**

```swift
@State private var agentStore = AgentStore()
@State private var workspaceManager = AgentWorkspaceManager()

// bootstrap 中:
workspaceManager.configure(helperClient: helperClient, username: currentUsername)
agentStore.load(gateway: gatewayService, helperClient: helperClient, username: currentUsername)

// environment:
.environment(agentStore)
.environment(workspaceManager)
```

## 关键文件清单

### 新建文件（5 个）
| 文件 | 用途 |
|------|------|
| `EZRWorkerApp/Models/AgentStatus.swift` | 智能体运行状态枚举 |
| `EZRWorkerApp/Models/AgentBinding.swift` | 渠道绑定模型（对应 OpenClaw bindings） |
| `EZRWorkerApp/Services/AgentWorkspaceManager.swift` | Workspace 文件操作服务（通过 HelperClient XPC） |
| `EZRWorkerApp/Views/Agent/AgentWorkspaceView.swift` | 分栏式 workspace 编辑器 + bindings + sessions + settings |
| `EZRWorkerApp/Views/Agent/AgentBindingsView.swift` | 渠道绑定管理子视图 |
| `EZRWorkerApp/Views/Agent/AgentSessionsView.swift` | 对话历史浏览子视图 |

### 修改文件（8 个）
| 文件 | 改动 |
|------|------|
| `EZRWorkerApp/Models/Agent.swift` | 移除 systemPrompt/identity/userTemplate/isActive，新增 workspace/agentDir/isDefault/status/boundBindings/sessionCount |
| `EZRWorkerApp/Services/Stores/AgentStore.swift` | 改为从 gateway config 驱动，CRUD 通过 configPatch，支持多智能体 + bindings 管理 |
| `EZRWorkerApp/Views/Agent/AgentGridView.swift` | NavigationLink 到 workspace、状态徽章、预置模板库区域、右键菜单 |
| `EZRWorkerApp/Views/Agent/AgentCardView.swift` | 状态指示器、渠道图标、session 统计 |
| `EZRWorkerApp/Views/Agent/AgentEditorView.swift` | 简化为元数据编辑（移除 prompt/identity/激活按钮） |
| `EZRWorkerApp/Views/Agent/CreateAgentSheet.swift` | 两种创建方式（从模板 / 空白），agentId 输入，workspace 初始化 |
| `EZRWorkerApp/Views/MainView.swift` | agents 区域用 NavigationStack 包裹，支持 push 到 workspace |
| `EZRWorkerApp/Views/PersonaDefView.swift` | PersonaFile.relPath 支持 agentId 参数 |
| `EZRWorkerApp/EZRWorkerApp.swift` | 注入 AgentWorkspaceManager，更新 bootstrap |

### 不修改
| 文件 | 原因 |
|------|------|
| `Shared/HelperProtocol.swift` | 现有 readFile/writeFile/createDirectory/commitPersonaFile 等 XPC 方法完全够用 |
| `EZRWorkerApp/Services/HelperClient.swift` | 复用 fileConnection XPC 通道 |
| `EZRWorkerApp/Services/Gateway/GatewayService.swift` | configGetFull/configPatch API 不变 |
| `EZRWorkerApp/Models/AgentCategory.swift` | 分类体系不变 |

## 验证计划

1. `make build` 编译通过
2. 通过 UI 新建智能体（指定 agentId）→ 验证 `openclaw.json` 的 `agents.list[]` 已追加
3. 验证 `~/.openclaw/workspace-<agentId>/` 目录和 SOUL.md 等文件已创建
4. 打开 workspace 编辑 SOUL.md → 保存 → 重新打开验证持久化
5. 添加 binding（渠道 + 账号 → 智能体）→ 验证 `openclaw.json` 的 `bindings[]` 已更新
6. 同时存在多个智能体 → 验证各自 workspace 独立、不互相干扰
7. 从预置模板创建 → 验证 workspace 初始内容从 bundled JSON 正确填充
8. 删除智能体 → 验证 gateway config 和 workspace 目录均清理
9. 旧版 agents.json 存在时启动 → 验证迁移逻辑正确
10. `make i18n-check` 通过
