---
name: Existing OpenClaw Multi Gateway Import Flowchart
overview: 说明一台已安装并运行多个 OpenClaw Gateway 的机器，在安装 EZRWorker App 后，扫描、导入、仅观察、托管、交接旧自启和启动/重启的完整流程。
---

# 既有 OpenClaw 多 Gateway 导入、观察、托管流程图

## 一、适用场景

一台机器上已经安装过 OpenClaw，并且可能已经运行多个 gateway，例如：

```text
~/.openclaw                         port 18789
~/.openclaw3/.openclaw              port 19112
~/.openclaw4/.openclaw              port 19212
其他 openclaw.json/stateDir           port N
```

用户安装 EZRWorker App 后，希望 App 能扫描这些实例，并按需选择：

- 仅观察：App 只看运行态，不接管生命周期。
- 托管：App/EZRWorkerSupervisor 接管启动、停止、重启和登录后恢复。
- 交接旧自启：停用旧 OpenClaw LaunchAgent，避免旧链路和 EZRWorker 双拉起。

## 二、总流程

```mermaid
flowchart TD
    A[用户在已安装 OpenClaw 的机器上安装 EZRWorker App] --> B[首次打开 App]
    B --> C{安装版是否已有 profiles.json?}

    C -->|有| C1[直接加载已有 EZRWorker Profiles]
    C -->|没有| D[扫描已有 OpenClaw]

    D --> E[扫描运行中 gateway 进程]
    D --> F[扫描 ~/Library/LaunchAgents]
    D --> G[扫描 /Library/LaunchAgents]
    D --> H[扫描常见 .openclaw 目录]

    E --> I[生成候选实例]
    F --> I
    G --> I
    H --> I

    I --> J[按 configPath/stateDir 合并候选]
    J --> K{是否发现多个 OpenClaw 实例?}

    K -->|没有| L[进入默认迁移或创建流程]
    K -->|有| M[展示导入已有 OpenClaw 页面]

    M --> N[用户逐个选择候选]
    N --> O{每个候选选择模式}

    O -->|仅观察| P[导入为 observeOnly]
    O -->|托管| Q[导入为 managedByEZRWorker]

    P --> R[不动旧进程和旧 LaunchAgent]
    Q --> S{是否检测到旧 LaunchAgent?}

    S -->|没有| T[写入 Profile 交给 EZRWorker 管]
    S -->|有| U[先交接旧自启]
    U --> V[bootout / disable / 改名 plist]
    V --> W[写入交接状态]

    R --> X[设置页显示仅观察]
    T --> Y[设置页显示托管]
    W --> Y
```

## 三、扫描逻辑

```mermaid
flowchart TD
    A[开始扫描] --> B[ps 查运行中 openclaw gateway]
    A --> C[读用户 LaunchAgents]
    A --> D[读系统 LaunchAgents]
    A --> E[查常见目录]

    B --> B1{进程命令/打开文件能推断 configPath?}
    B1 -->|能| B2[候选 source=runningProcess，带 pid]
    B1 -->|不能| B3[忽略该进程]

    C --> C1{plist 像 OpenClaw Gateway?}
    D --> C1
    C1 -->|是| C2[解析 label、plistPath、KeepAlive、RunAtLoad]
    C2 --> C3{能推断 configPath/stateDir?}
    C3 -->|能| C4[候选 source=launchAgent，带 launchAgent 信息]
    C3 -->|不能| C5[忽略或降级]

    E --> E1[查 ~/.openclaw、~/.openclaw3/.openclaw 等]
    E1 --> E2{存在 openclaw.json?}
    E2 -->|是| E3[候选 source=knownDirectory]
    E2 -->|否| E4[跳过]

    B2 --> F[候选合并]
    C4 --> F
    E3 --> F

    F --> G[按 configPath 优先合并]
    G --> H[同一个 openclaw.json 只显示一个候选]
    H --> I[生成导入列表]
```

### 扫描出的候选字段

```text
configPath      该实例使用的 openclaw.json
stateDir        该实例的数据目录
workspaceRoot   工作区目录
port            gateway 端口
pid             当前是否有运行中进程
launchAgent     是否存在旧自启 plist
risk            safe / needsReview / blocked
```

如果机器上“开了 4 个 gateway”，但它们实际共用同一个 `openclaw.json`，导入页会合并成少于 4 个候选。导入粒度以 `configPath/stateDir` 为主，不是以 Chrome renderer 或 gateway 子进程数量为主。

## 四、仅观察模式

```mermaid
flowchart TD
    A[用户选择仅观察] --> B[写入 Profile]
    B --> C[managementMode = observeOnly]
    C --> D[autoStart = false]

    D --> E[不停止旧 gateway]
    D --> F[不禁用旧 LaunchAgent]
    D --> G[不由 EZRWorker 启动 gateway]

    E --> H[旧 OpenClaw 继续按原方式运行]
    F --> H
    G --> I[App 只读取/展示运行态]

    I --> J{旧 gateway 是否还在跑?}
    J -->|是| K[设置页显示运行中/仅观察]
    J -->|否| L[设置页显示未运行，App 不自动拉起]
```

仅观察的语义：

```text
App 看，不管。
不改变旧启动链路。
不保证机器重启后由 EZRWorker 恢复。
停止/重启按钮不可用或不会由 EZRWorker 执行。
```

适合先导入、先确认，不想破坏旧机器现状的阶段。

## 五、托管模式

```mermaid
flowchart TD
    A[用户选择托管] --> B[写入 Profile]
    B --> C[managementMode = managedByEZRWorker]
    C --> D[允许启动/停止/重启]
    D --> E[可开启登录后自动恢复]

    E --> F{候选是否有旧 LaunchAgent?}

    F -->|没有| G[EZRWorker Supervisor 可直接启动]
    F -->|有| H[必须交接旧自启]

    H --> I{plist 当前用户是否可写?}
    I -->|是| J[自动 bootout + disable + plist 改名]
    I -->|否| K[提示管理员手动处理]

    J --> L[记录 launchAgentHandoff.status = disabled]
    L --> M[Supervisor reloadProfiles]
    M --> N[由 EZRWorker 启动/重启 gateway]

    K --> O[记录 status = manualRequired]
    O --> P[不自动启动，避免双拉起]
```

托管的语义：

```text
App 管生命周期。
运行时使用 App 内置 Node/OpenClaw。
配置和状态目录仍指向原实例路径。
模型、渠道、技能等配置继续来自该实例的 openclaw.json/stateDir。
```

## 六、交接旧自启

旧 OpenClaw 可能有 LaunchAgent：

```text
~/Library/LaunchAgents/ai.openclaw.gateway.plist
~/Library/LaunchAgents/com.openclaw.gateway3.plist
/Library/LaunchAgents/com.openclaw.gateway4.plist
```

如果托管时不处理旧 LaunchAgent，会出现：

```text
旧 LaunchAgent       -> 拉起旧 gateway
EZRWorkerSupervisor -> 拉起新 gateway
```

后果：

- 停止后又被旧 KeepAlive 拉起。
- 端口冲突。
- App 运行态判断混乱。
- 机器重启后回到旧 runtime。
- Debug 版和安装版可能同时管理同一个实例。

### 用户态 plist 自动交接

```mermaid
flowchart TD
    A[点击交接并启动/交接并重启] --> B[重新读取 plist]
    B --> C{plist 是否仍匹配当前 Profile?}
    C -->|否| D[取消交接，提示匹配失败]
    C -->|是| E{是否需要管理员权限?}

    E -->|是| F[记录 manualRequired 并显示手动命令]
    E -->|否| G[launchctl bootout]

    G --> H[launchctl disable]
    H --> I[plist 改名为 .disabled-时间戳]
    I --> J[记录 handoff=disabled]
    J --> K[Supervisor reloadProfiles]
    K --> L{点击前 Profile 是否运行中?}
    L -->|是| M[restartProfile]
    L -->|否| N[startProfile]
```

### 系统 plist 或不可写 plist

```mermaid
flowchart TD
    A[检测到 /Library/LaunchAgents 或不可写 plist] --> B[不自动 sudo]
    B --> C[记录 status = manualRequired]
    C --> D[显示手动命令]
    D --> E[不启动/不重启]
    E --> F[等待用户手动处理后重新检查]
```

## 七、设置页按钮逻辑

```mermaid
flowchart TD
    A[设置页 Profile 卡片] --> B{Profile 是否旧实例复用?}
    B -->|否| C[不显示交接按钮]
    B -->|是| D{是否 managedByEZRWorker?}

    D -->|否，仅观察| E[不显示交接按钮]
    D -->|是| F{旧自启状态}

    F -->|disabled| G[显示旧自启已交接]
    F -->|notRequired 且已确认| H[显示无旧自启]
    F -->|pending/manualRequired/failed/未知| I[显示交接按钮]

    I --> J{当前 Profile 是否运行中?}
    J -->|是| K[按钮文案：交接并重启]
    J -->|否| L[按钮文案：交接并启动]

    K --> M[点击按钮]
    L --> M

    M --> N[匹配旧 LaunchAgent]
    N --> O{找到匹配 plist?}

    O -->|没有| P[标记无旧自启]
    P --> Q[reloadProfiles]
    Q --> R[startProfile]

    O -->|找到| S{是否需要管理员权限?}
    S -->|是| T[提示手动命令，不启动]
    S -->|否| U[bootout + disable + 改名 plist]

    U --> V[写入 handoff=disabled]
    V --> W[reloadProfiles]
    W --> X{点击前是否运行中?}
    X -->|是| Y[restartProfile]
    X -->|否| Z[startProfile]
```

## 八、4 个 Gateway 的推荐操作路径

```mermaid
flowchart TD
    A[机器上已有 4 个 OpenClaw gateway] --> B[App 扫描]
    B --> C{是否识别出 4 个不同 configPath/stateDir?}

    C -->|是| D[导入页显示 4 个候选]
    C -->|否| E[按相同 configPath 合并，显示少于 4 个]

    D --> F[建议先全部仅观察导入]
    F --> G[设置页确认每个候选的端口、配置路径、运行状态]

    G --> H[选择第 1 个要交给 App 管的实例]
    H --> I[点交接并启动/重启]
    I --> J[确认端口监听正常]

    J --> K{是否继续托管下一个?}
    K -->|是| H
    K -->|否| L[剩余实例保持仅观察]

    E --> M[检查为什么被合并]
    M --> N[确认多个 gateway 是否共用同一个 openclaw.json]
```

推荐顺序：

```text
1. 先全部仅观察导入。
2. 确认每个候选的 port/config/state 都对。
3. 一次只托管一个。
4. 对目标 Profile 点“交接并启动”或“交接并重启”。
5. 确认端口监听、App 运行态、LaunchAgent 状态。
6. 再处理下一个。
```

## 九、关键状态表

| 状态 | 谁启动 Gateway | App 能否停止/重启 | 旧 LaunchAgent 是否保留 | 登录后恢复 |
|---|---|---:|---:|---:|
| 仅观察 | 旧 LaunchAgent 或用户原方式 | 否 | 是 | 由旧链路决定 |
| 托管，未交接 | 不应启动 | 会被保护逻辑阻止 | 是 | 不应恢复 |
| 托管，交接成功 | EZRWorkerSupervisor | 是 | 改名禁用 | 由 EZRWorker 决定 |
| 托管，需要手动 | 暂不自动启动 | 否 | 是，需要手动处理 | 不应恢复 |
| 托管，无旧自启 | EZRWorkerSupervisor | 是 | 无 | 由 EZRWorker 决定 |

## 十、排查命令

查看当前哪些端口在监听：

```bash
lsof -nP -iTCP -sTCP:LISTEN | grep -E '18789|18809|19112|19212|19789'
```

查看 OpenClaw 相关进程：

```bash
ps -axo pid,ppid,user,command | grep -i openclaw
```

查看旧 OpenClaw LaunchAgent：

```bash
ls ~/Library/LaunchAgents | grep -i openclaw
launchctl print gui/$(id -u)/ai.openclaw.gateway
```

查看安装版 EZRWorker Supervisor：

```bash
launchctl print gui/$(id -u)/ai.ezrworker.mac.supervisor
```

查看 Debug 版 EZRWorker Supervisor：

```bash
launchctl print gui/$(id -u)/ai.ezrworker.mac.dev.supervisor
```

查看安装版 profiles：

```bash
cat "$HOME/Library/Application Support/EZRWorker/profiles.json"
```

查看 Debug 版 profiles：

```bash
cat "$HOME/Library/Application Support/EZRWorker-Dev/profiles.json"
```

## 十一、一句话总结

```text
仅观察 = App 看，不管。
托管 = App 管生命周期。
交接旧自启 = 拿掉旧 LaunchAgent 的拉起权。
交接并启动/重启 = 拿掉旧自启后，立刻让 EZRWorkerSupervisor 接手运行。
```
