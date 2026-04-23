---
name: EZRWorker App 内嵌 OpenClaw 终端优先技术方案
overview: 本轮优先规划并实施 App 内嵌 OpenClaw 终端，让用户在 App 内直接执行当前 profile 命令；外部 Terminal wrapper 仅保留接口和设计预留，后续再实施。
isProject: false
---

# EZRWorker App 内嵌 OpenClaw 终端优先技术方案

## 一、背景

EZRWorker 当前已经有两类“终端/命令执行”能力：

- **App 内嵌终端**：例如飞书/企微接入、旧虾维护终端。用户在 App 窗口里看到终端 UI，实际由 App 或 Helper 启动子进程，并直接注入正确的用户身份、PATH、runtime 和 profile 环境。
- **外部系统终端**：用户打开 macOS Terminal/iTerm，在自己的 shell 中手动输入命令。这个 shell 不知道 EZRWorker 当前选中的 profile，也不知道 App bundle 内打包的 `node` 和 `openclaw.mjs` 路径。

最终可以形成“双入口”，但本轮先做 App 内嵌终端：

- **本轮实施：App 内嵌 OpenClaw 终端**。用户在 EZRWorker 内点击入口，直接打开当前 profile 的终端窗口。
- **后续实施：外部 Terminal wrapper**。用户离开 App，在 macOS Terminal/iTerm 里通过 `ezr-openclaw` 访问同一套 profile。

两者底层应复用 App 管理的 profile resolution 和打包 runtime。本轮实现 App 内入口时，需要把共享能力设计干净，给后续外部 wrapper 预留复用点。

## 二、现状确认

### 2.1 App 主线 Gateway 启动方式

App 主线通过 Supervisor 启动 Gateway：

- 可执行文件：`OpenClawRuntime.bundledNodeURL`
- 入口文件：`OpenClawRuntime.bundledOpenClawEntry`
- 参数：`gateway`
- 环境：`OpenClawRuntime.buildEnvironment(profile:)`

也就是说，Gateway 并不是依赖当前用户 shell 中的全局 `openclaw`，而是使用 App bundle 或 dev-runtime 内置的 Node/OpenClaw runtime。

### 2.2 Profile 隔离方式

主线多 profile 的隔离依赖显式路径：

- `OPENCLAW_CONFIG_PATH`
- `OPENCLAW_STATE_DIR`
- `resolvedWorkspaceRoot`
- `resolvedPort`

这些值由 `GatewayProfileResolver.resolve(_:)` 从 `profiles.json` 和 profile overrides 中解析得到。

### 2.3 当前 App 内嵌终端原理

App 内嵌终端不是“让用户系统 Terminal 自己找命令”，而是 App 自己构造命令：

- 飞书/企微接入：使用打包 `npx`，并通过 `GatewayProcessManager.buildEnvironment(profile:)` 注入当前 profile 环境。
- 旧虾维护终端：通过 Helper XPC 创建 PTY 会话，以指定虾用户身份运行 `openclaw`/`npx` 等维护命令。

因此 App 内嵌终端不需要安装命令到系统 PATH；外部 Terminal 若要获得同等体验，则需要一个可被 shell 找到的入口。

## 三、目标

- 允许用户在 EZRWorker 内点击入口，打开一个可交互的当前 profile OpenClaw 终端。
- 终端命令必须复用 App 管理的 runtime、config path、state dir、workspace root 和端口。
- 避免用户误执行 `openclaw gateway` 启动第二个 Gateway。
- 默认绑定当前 selected profile；后续可支持从终端窗口内切换 profile。
- 默认不暴露 Gateway token 等敏感信息。
- 与现有飞书/企微 onboarding 终端并存，但新增一个主线 profile 终端，不再依赖旧虾 Helper 维护终端链路。
- 为后续外部 `ezr-openclaw` wrapper 预留共享 service，但不在本轮实现外部安装入口。

## 四、非目标

- 不把 OpenClaw 安装为全局 npm 包。
- 不要求用户修改 `~/.zshrc` 或手动维护复杂 PATH。
- 不通过旧 Helper 的 Shrimp 用户链路执行当前 App 主线 profile 命令。
- 不默认开放无限制系统 shell 权限；App 内嵌终端应默认限定在当前用户和当前 profile 上下文。
- 本轮不安装 `ezr-openclaw` 到 `~/.local/bin` 或 `/usr/local/bin`。
- 本轮不实现外部 Terminal/iTerm 里的 wrapper 命令。
- 不把 App 内嵌终端变成完整的 Gateway 管理控制台；生命周期管理可以后续扩展。

## 五、推荐方案

本轮只实施 App 内嵌 OpenClaw 终端。

在 App 设置页或侧边栏增加“终端”入口，点击后打开一个新窗口：

```text
当前 Profile：Default
工作目录：<profile.resolvedWorkspaceRoot>
命令环境：EZRWorker runtime + OPENCLAW_CONFIG_PATH + OPENCLAW_STATE_DIR
```

用户可以直接执行：

```bash
openclaw agents list
openclaw pairing approve feishu <code>
openclaw configure --section model
```

App 内嵌终端由 App 自己启动进程，因此不需要安装 `ezr-openclaw`，也不依赖用户 shell 中的全局 `openclaw`。

### 5.1 后续预留：外部 Terminal wrapper

外部 Terminal wrapper 不进入本轮实施，但设计上保留复用点。后续可新增轻量命令入口：`ezr-openclaw`。

示例：

```bash
ezr-openclaw profiles
ezr-openclaw status --profile default
ezr-openclaw --profile default agents list
ezr-openclaw --profile default pairing approve feishu <code>
ezr-openclaw --profile default configure --section model
```

该入口本质是 wrapper：

1. 读取 EZRWorker 的 profile 配置。
2. 解析目标 profile。
3. 找到 App 打包的 Node/OpenClaw runtime。
4. 构造与 App Gateway 一致的环境变量。
5. 调用 `node openclaw.mjs <用户参数>`。

## 六、方案关系与分期

### 6.1 为什么先做 App 内嵌终端

App 内嵌终端和外部 wrapper 解决的是不同使用场景：

- App 内嵌终端适合普通用户：不需要安装、不需要 PATH、不需要理解 profile 路径，点击即可进入当前 profile。
- 外部 wrapper 适合高级用户：可以在 Terminal/iTerm、脚本、自动化流程中调用同一套 OpenClaw profile。

当前优先级选择 App 内嵌终端，原因是：

- 用户体验闭环更短：入口、profile、runtime、权限都由 App 管理。
- 风险更小：不需要写用户 PATH，也不需要安装命令到系统目录。
- 与已有飞书/企微 onboarding 终端经验一致，技术路径更可控。
- 可以先沉淀共享的 profile/runtime/env 能力，再给外部 wrapper 复用。

本轮应抽象出以下共享链路：

```text
GatewayProfileResolver.resolve(profile)
        ↓
OpenClawRuntime.buildEnvironment(profile)
        ↓
bundled node + bundled openclaw.mjs
        ↓
openclaw CLI 子命令
```

### 6.2 后续外部方案：只展示完整命令

形式：

```bash
OPENCLAW_CONFIG_PATH=... \
OPENCLAW_STATE_DIR=... \
/Applications/EZRWorker.app/Contents/Resources/node/bin/node \
/Applications/EZRWorker.app/Contents/Resources/openclaw/lib/node_modules/openclaw/openclaw.mjs \
agents list
```

优点：

- 无需安装任何命令。
- 实现成本最低。

缺点：

- 命令很长，不适合日常使用。
- profile 切换后命令容易过期。
- 用户容易遗漏环境变量，导致读写错误目录。

结论：仅作为调试兜底，不作为主入口。

### 6.3 后续外部方案：提供 `ezr-openclaw` wrapper

优点：

- 用户体验稳定，命令短。
- 可以统一处理 profile 解析、runtime 定位、环境注入、错误提示。
- 可以拦截危险命令，例如误启动第二个 Gateway。

缺点：

- 需要提供安装/卸载入口。
- 需要处理 wrapper 放置路径和 PATH 提示。

结论：后续再实施。本轮只要求 App 内嵌终端的共享能力不要封死，确保未来 wrapper 可以复用 profile 解析、runtime 定位、环境注入和 gateway 子命令保护。

## 七、详细设计

### 7.0 当前实施状态

已完成：

- [x] 新增 `ProfileCLIService`：`EZRWorkerApp/EZRWorker/Services/ProfileCLIService.swift`。
- [x] 新增 App 内嵌终端窗口：`EZRWorkerApp/EZRWorker/Views/ProfileTerminalView.swift`。
- [x] 设置页新增 `OpenClaw 终端` 入口。
- [x] 注册 `WindowGroup(id: "profile-terminal")`。
- [x] 为当前 profile 生成临时 `openclaw` shim。
- [x] 向终端会话注入当前 profile 的 `OPENCLAW_CONFIG_PATH`、`OPENCLAW_STATE_DIR`、工作目录和 runtime PATH。
- [x] 终端子进程启动前清掉 `OPENCLAW_PROFILE`。
- [x] 拦截 `openclaw gateway`，避免用户从内嵌终端重复启动 Gateway。
- [x] Debug 构建已通过。

部分完成：

- [~] 顶部状态已展示并支持手动刷新；命令执行后的业务页面自动刷新尚未实现。
- [~] 关闭窗口时会终止终端子进程；尚未增加二次确认弹窗。
- [~] 已有欢迎信息、当前 profile 信息和常用命令提示；文案仍可继续打磨。
- [~] 内嵌终端环境与 shim 已实现；具体业务命令仍需要人工端到端确认。

未开始 / 后续：

- [ ] 命令执行后自动触发业务页面刷新。
- [ ] 高风险 config 修改类命令改走 Gateway RPC `config.patch`。
- [ ] 外部 `ezr-openclaw` wrapper 与安装入口。
- [ ] Gateway RPC 命令组。

### 7.1 本轮共享核心能力

新增或收口一个主线 CLI 执行抽象，推荐命名：

```text
ProfileCLIService
```

职责：

- 持有 `GatewayProfileResolution`。
- 统一构造 `OpenClawRuntime.buildEnvironment(profile:)`。
- 提供 `runOpenClaw(args:currentDirectoryURL:)`。
- 对危险子命令做统一拦截。
- 对错误输出做统一格式化。

已有 `GatewayProcessManager.runOpenclawLocally(args:profile:)` 可以先作为底层实现，后续再迁移到独立 service，避免让 UI 直接关心 runtime 细节。

本轮 `ProfileCLIService` 优先服务 App 内嵌终端；外部 wrapper 只作为未来消费者预留。

### 7.2 App 内嵌终端设计

#### 7.2.1 入口位置

推荐提供两个入口：

- 设置页：`OpenClaw 终端`
- 当前 profile 状态卡片：`打开终端`

如果侧边栏空间允许，也可以增加一个一级入口 `终端`。

#### 7.2.2 窗口形态

新增窗口：

```text
WindowGroup(id: "profile-terminal")
```

窗口标题：

```text
OpenClaw 终端 · <profile.displayName>
```

窗口顶部展示：

- 当前 profile 名称和 slug
- Gateway 端口
- 当前工作目录
- Gateway 运行状态

#### 7.2.3 终端执行方式

推荐做主线专用终端组件，而不是复用旧虾 Helper 维护终端：

```text
ProfileTerminalPanel
ProfileTerminalSession
ProfileTerminalNSView
```

实现策略：

- 使用现有终端 UI 能力（`LocalProcessTerminalView` / `TerminalView`）。
- 启动当前 macOS 用户下的子进程，不切换到 Shrimp 用户。
- 注入 `GatewayProcessManager.buildEnvironment(profile: selectedResolution)`。
- 工作目录默认使用 `profile.resolvedWorkspaceRoot`。
- 提供 `openclaw` shim，让用户可直接输入 `openclaw ...`。

#### 7.2.4 `openclaw` shim

因为 App 内嵌终端如果直接启动 `/bin/zsh`，用户输入 `openclaw` 时 shell 仍然需要在 PATH 中找到命令。

推荐在临时目录生成 shim：

```text
/tmp/ezrworker-profile-terminal-shims/<profile-id>/openclaw
```

shim 内容：

```sh
#!/bin/sh
exec "<bundled-node>" "<bundled-openclaw-entry>" "$@"
```

然后把 shim 目录放在 PATH 最前面：

```text
PATH=<shim-dir>:<bundled node bin>:<bundled openclaw bin>:<原 PATH>
```

这样用户在内嵌终端里可以自然输入：

```bash
openclaw agents list
```

#### 7.2.5 启动 shell

终端启动命令建议：

```bash
/bin/zsh -f
```

原因：

- `-f` 避免加载用户复杂 shell 配置，减少 PATH、alias、`OPENCLAW_PROFILE` 干扰。
- App 已经注入完整 PATH 和 OpenClaw 环境。

可选增强：进入终端后打印一段欢迎信息：

```text
EZRWorker OpenClaw Terminal
Profile: Default (default)
Config: ~/Library/Application Support/EZRWorker/profiles/default/state/openclaw.json
State:  ~/Library/Application Support/EZRWorker/profiles/default/state

Try: openclaw agents list
```

#### 7.2.6 Gateway 子命令保护

App 内嵌终端也需要保护 `openclaw gateway`。

推荐做法：shim 内拦截第一个参数：

```sh
if [ "$1" = "gateway" ]; then
  echo "Gateway 由 EZRWorker 管理，请在 App 中启动/停止，或使用状态页查看。"
  exit 2
fi
```

如果后续需要支持 `gateway status/start/stop/restart`，应该通过 App/Supervisor 能力实现，不直接执行 `openclaw gateway`。

### 7.3 后续预留：外部命令入口形态

以下内容不进入本轮实施，仅作为后续 `ezr-openclaw` wrapper 的设计预留。

推荐优先安装到用户目录：

```text
~/.local/bin/ezr-openclaw
```

原因：

- 不需要 sudo。
- 不写 `/usr/local/bin`，降低权限风险。
- 便于卸载。

如果用户选择全局安装，可安装到：

```text
/usr/local/bin/ezr-openclaw
```

此路径需要权限确认。

### 7.4 后续预留：外部 CLI 参数设计

```text
ezr-openclaw [--profile <slug|uuid>] <openclaw args...>
ezr-openclaw profiles
ezr-openclaw status [--profile <slug|uuid>]
ezr-openclaw env [--profile <slug|uuid>]
ezr-openclaw doctor
```

说明：

- `profiles`：列出可用 profile、slug、displayName、port、configPath。
- `status`：展示目标 profile 的 Gateway 端口、运行状态、pid（可通过 Supervisor XPC 或本地 probe 获取）。
- `env`：输出当前 profile 将使用的关键环境变量，默认隐藏 token。
- 其他参数透传给 OpenClaw CLI。

### 7.5 Profile 解析

本轮 App 内嵌终端默认使用 `GatewayProfileStore.selectedResolution`。

后续外部 wrapper 的 profile 来源：

```text
~/Library/Application Support/EZRWorker/profiles.json
```

后续外部 wrapper 解析规则：

1. 如果传入 `--profile`，优先按 UUID 匹配，再按 slug 匹配。
2. 如果未传入 `--profile`，尝试读取 App 最后选择的 profile id。
3. 如果最后选择的 profile 不存在，回退到 profiles 文档中的第一个 profile。
4. 如果没有 profile，提示用户先打开 EZRWorker 完成初始化。

### 7.6 Runtime 定位

优先级：

1. `EZRWORKER_DEV_RUNTIME_DIR`
2. `CLAWDHOME_DEV_RUNTIME_DIR`
3. 当前 CLI 所在 App bundle 的 `Contents/Resources`
4. 常见安装路径 `/Applications/EZRWorker.app/Contents/Resources`
5. 调试构建路径 `build/dev-runtime`

需要注意：如果 `ezr-openclaw` 是 symlink，runtime resolver 应该解析 symlink 的真实路径，否则可能无法从 `/usr/local/bin` 或 `~/.local/bin` 反推出 App bundle。

### 7.7 环境变量构造

必须与 App 主线保持一致：

```text
HOME=<当前 macOS 用户 home>
PATH=<bundled node bin>:<bundled openclaw bin>:<~/.npm-global/bin>:<原 PATH>
NODE_ENV=production
OPENCLAW_CONFIG_PATH=<profile.resolvedConfigPath>
OPENCLAW_STATE_DIR=<profile.resolvedStateDir>
```

必须从子进程环境中移除：

```text
OPENCLAW_PROFILE
```

原因：主线 profile 隔离依赖显式 config/state 路径；如果继承 shell 中残留的 `OPENCLAW_PROFILE`，OpenClaw 可能按 legacy profile 规则推导路径，导致终端命令和 App Gateway 操作不同目录。

### 7.8 Gateway 子命令保护

本轮 App 内嵌终端默认拦截：

```bash
openclaw gateway
```

后续外部 wrapper 也应默认拦截：

```bash
ezr-openclaw gateway
```

提示：

```text
当前 Gateway 由 EZRWorker/Supervisor 管理。请使用 ezr-openclaw status 查看状态，或在 App 中启动/停止 Gateway。
```

后续可扩展：

```bash
ezr-openclaw gateway status --profile default
ezr-openclaw gateway start --profile default
ezr-openclaw gateway restart --profile default
ezr-openclaw gateway stop --profile default
```

这些命令应走 Supervisor XPC，不直接启动 `openclaw gateway`。

### 7.9 Gateway RPC 能力

OpenClaw CLI 子命令优先走本地 CLI 执行。

本轮不实现 Gateway RPC 命令组。如果后续需要从外部 Terminal 调用 Gateway RPC，可增加独立命令组：

```bash
ezr-openclaw rpc config.get --profile default
ezr-openclaw rpc models.list --profile default
```

RPC 连接需要：

- `resolvedPort`
- `gateway.auth.token`
- Device identity/握手逻辑

默认不在 `env` 或 `status` 输出中展示 token，除非显式传入类似 `--show-token` 的调试参数。

## 八、App 设置页交互

在设置页增加“OpenClaw 终端”区域：

- 按钮：打开 App 内嵌终端
- 展示当前 profile 名称、端口、运行状态
- 如果 Gateway 未运行，提示先启动 Gateway；仍允许执行纯本地 CLI 命令，但明确标识 Gateway RPC 类命令可能不可用

外部 Terminal 命令区域本轮不做。后续可增加：

- 显示当前安装状态：未安装 / 已安装到 `~/.local/bin` / 已安装到 `/usr/local/bin`
- 按钮：安装到 `~/.local/bin`
- 按钮：复制完整命令
- 按钮：卸载终端命令
- 如果 `~/.local/bin` 不在 PATH 中，展示 shell 配置提示，但不自动修改用户 shell 配置。

推荐提示文案：

```text
打开内嵌终端后，可直接执行当前 profile 的 openclaw 命令。
```

后续外部 wrapper 文案：

```text
安装后可在 Terminal 中使用 ezr-openclaw 命令访问当前 EZRWorker profile。
该命令不会安装全局 openclaw，只是复用 EZRWorker.app 内置 runtime。
```

## 九、安全与权限

- App 内嵌终端 shim 文件权限使用 `0755`，只写入 `/tmp/ezrworker-profile-terminal-shims/`。
- 不自动写入 `~/.zshrc`、`~/.bashrc`。
- 不默认打印 token、API key、secrets 路径内容。
- App 内嵌终端要对 `gateway` 子命令做保护，避免重复启动 Gateway。
- 对 profile config/state 路径做存在性和可写性检查。
- 对 openclaw 执行输出做原样透传，但 App 日志中避免记录敏感环境变量完整值。
- 后续外部 wrapper 实施时，默认安装到 `~/.local/bin`，wrapper 文件权限使用 `0755`，并复用同一套安全策略。

## 十、验收标准

- [x] 在 App 设置页点击“打开内嵌终端”后，会打开当前 profile 的终端窗口。
- [~] App 内嵌终端中执行 `openclaw agents list` 能读取当前 profile 数据；环境和 shim 已实现，仍需人工端到端确认。
- [~] App 内嵌终端中执行 `openclaw pairing approve ...` 写入当前 profile 的 config/state 目录；环境和目录隔离已实现，仍需人工端到端确认。
- [x] App 内嵌终端中执行 `openclaw gateway` 不会启动第二个 Gateway，而是给出明确提示。
- [x] App 内嵌终端中即使用户 shell 配置里存在 `OPENCLAW_PROFILE`，子进程也不会受影响。
- [x] App 内嵌终端默认工作目录是当前 profile 的 workspace root。
- [x] 关闭终端窗口后，子进程会被终止。
- [~] 未安装 runtime、profile 缺失、App 未初始化等错误已有中文错误路径；具体文案可继续打磨。
- [x] 本轮不要求 `ezr-openclaw profiles/env/status` 可用。

## 十一、风险与处理

### 11.1 UI 状态刷新延迟

App 内嵌终端修改配置后，App UI 可能不会立即刷新。

处理方式：

- MVP 阶段接受手动刷新或切页触发刷新。
- 后续可增加文件监听或 CLI 执行后通过 XPC 通知 App 刷新。

### 11.2 配置并发写入

App 内嵌终端与 App UI 同时修改 config 可能产生竞态。

处理方式：

- 优先使用 OpenClaw 原生命令处理其负责的数据结构。
- 对高风险 config 写入，后续考虑走 Gateway RPC 的 `config.patch`。

### 11.3 后续外部 wrapper runtime 定位失败

外部 wrapper symlink 安装后无法反推 App bundle。

处理方式：

- wrapper 内记录安装时的 App bundle path。
- 同时支持环境变量 override。
- 启动时检查 node/openclaw.mjs 是否存在。
- 本风险不阻塞本轮 App 内嵌终端。

### 11.4 内嵌 shell 继承用户配置导致漂移

如果内嵌终端加载用户 `~/.zshrc`，可能引入旧 PATH、alias 或 `OPENCLAW_PROFILE`。

处理方式：

- 默认使用 `/bin/zsh -f`。
- 显式注入完整环境。
- 显式移除 `OPENCLAW_PROFILE`。
- 如需“加载用户 shell 配置”，作为高级开关，默认关闭。

### 11.5 legacy Shrimp 链路混淆

旧 Helper/Shrimp 用户使用 `~/.npm-global/bin/openclaw`，主线 App profile 使用 App bundle runtime。

处理方式：

- `ezr-openclaw` 仅服务主线 App profile。
- App 内嵌 profile 终端仅服务主线 App profile。
- 文档明确不走旧 Helper `runOpenclawCommand(username:)`。

## 十二、实施拆分

### Phase 1：共享 Profile CLI 能力（已完成）

- [x] 新增或收口 `ProfileCLIService`。
- [x] 统一封装 profile resolution、runtime、environment、cwd。
- [x] 统一移除 `OPENCLAW_PROFILE`。
- [x] 统一拦截 `gateway` 子命令。

### Phase 2：App 内嵌终端 MVP（已完成）

- [x] 新增 `ProfileTerminalPanel` / 终端会话视图。
- [x] 新增 shim 生成逻辑，让内嵌终端可直接输入 `openclaw ...`。
- [x] 在设置页增加“打开内嵌终端”按钮。
- [x] 默认工作目录使用 `profile.resolvedWorkspaceRoot`。
- [~] 验证 `openclaw agents list`、`pairing approve/reject`；实现路径已完成，仍需人工端到端确认。

### Phase 3：状态与刷新集成（部分完成）

- [x] App 内嵌终端顶部状态接入本地 Gateway 状态读取，并支持手动刷新。
- [ ] App 内嵌终端命令执行后触发当前 profile UI 刷新。
- [ ] 可选增加 `gateway start/stop/restart`，但必须走 Supervisor。

### Phase 4：体验与安全打磨（部分完成）

- [x] 增加欢迎信息、当前 profile 信息、常用命令提示。
- [~] 关闭终端窗口时会终止子进程；二次确认尚未实现。
- [~] 增加错误提示和基础保护；日志脱敏仍需结合后续日志路径复查。
- [ ] 针对 config 修改类命令提供更强一致性路径。

### 后续 Backlog：外部 wrapper（未开始）

- [ ] 新增 `ezr-openclaw` CLI/wrapper 能力。
- [ ] 支持 `--profile`、`profiles`、`env`、`status`。
- [ ] 增加设置页安装/卸载入口。
- [ ] 支持安装到 `~/.local/bin`。
- [ ] 外部 CLI 修改后通知 App 刷新。
- [ ] 增加 Gateway RPC 命令组。

## 十三、推荐结论

本轮先做 App 内嵌 OpenClaw 终端：

- **App 内嵌 OpenClaw 终端**作为默认用户入口，优先落地。它不需要安装、不依赖系统 PATH，最符合 App 管理 profile 的产品体验。
- **外部 `ezr-openclaw` wrapper**保留为后续 Backlog，不进入当前实施范围。

本轮实现时仍要把 profile/runtime/env 能力抽象清楚，为后续 wrapper 复用；同时必须保护 `openclaw gateway`，避免绕过 EZRWorker/Supervisor 重复启动 Gateway。
