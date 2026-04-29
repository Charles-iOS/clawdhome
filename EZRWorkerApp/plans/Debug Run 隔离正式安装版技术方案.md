---
name: Debug Run Isolation From Installed App
overview: 为 EZRWorker 增加 Debug/Dev 运行隔离能力，使 Xcode Debug Run 不复用或覆盖已安装正式版 App 的数据目录、LaunchAgent、Supervisor Mach service、Keychain 与 Gateway 端口。
todos:
  - id: phase1-flavor-branding
    content: "Phase 1: 增加 Debug flavor 运行时标识，隔离 bundle id、service label、Keychain service、UserDefaults key 与 App Support 目录"
    status: pending
  - id: phase2-port-runtime
    content: "Phase 2: 隔离 Debug Gateway 默认端口段与 Supervisor LaunchAgent 生成路径"
    status: pending
  - id: phase3-xcode-settings
    content: "Phase 3: 调整 Xcode Debug 构建设置与 entitlements，使 Xcode Run 使用 dev 身份"
    status: pending
  - id: phase4-dev-safety
    content: "Phase 4: 增加 Debug 运行安全提示、外部 OpenClaw 导入保护与清理手册"
    status: pending
  - id: phase5-verification
    content: "Phase 5: 验证 Debug 版与正式安装版可同时存在、互不覆盖、端口不冲突"
    status: pending
isProject: false
---

# Debug Run 隔离正式安装版技术方案

## 一、结论：改动大吗

改动不大，属于小到中等。

这不是业务逻辑重构，主要是把当前硬编码的生产运行身份拆成：

- `Release / Installed`：继续使用正式身份
- `Debug / Xcode Run`：使用 dev 身份

预计改动范围：

| 模块 | 改动量 | 说明 |
| --- | --- | --- |
| `Shared/EZRWorkerBranding.swift` | 中 | 新增 Debug/Release flavor 分支，统一管理标识 |
| `Shared/GatewayProfiles.swift` | 小 | Debug 默认端口段改为独立范围 |
| `EZRWorker.xcodeproj/project.pbxproj` | 小到中 | Debug bundle id / entitlement / app display name |
| `EZRWorkerApp/EZRWorker.entitlements` 或新增 Debug entitlements | 小 | 允许 Debug App 连接 dev supervisor Mach service |
| `SupervisorClient` | 小 | 现有动态 LaunchAgent 已走 branding，主要做确认和少量保护 |
| 设置页/启动页提示 | 可选小改 | Debug 版显示 Dev 标识，避免误操作 |

不需要改 OpenClaw runtime 打包逻辑，不需要改正式版安装器，不需要迁移正式数据。

## 二、背景

当前项目的 App、Supervisor、数据路径和 Keychain 服务都使用正式标识：

```text
App bundle id:        ai.ezrworker.mac
Supervisor service:   ai.ezrworker.mac.supervisor
Supervisor plist:     ~/Library/LaunchAgents/ai.ezrworker.mac.supervisor.plist
App Support:          ~/Library/Application Support/EZRWorker
Keychain service:     ai.ezrworker.mac*
Gateway port range:   18789...18999
```

如果直接从 Xcode Debug Run：

1. Debug App 会读取正式版 `~/Library/Application Support/EZRWorker/profiles.json`。
2. Debug App 会连接或重写正式版 `ai.ezrworker.mac.supervisor`。
3. `SupervisorClient` 可能把 `~/Library/LaunchAgents/ai.ezrworker.mac.supervisor.plist` 的 `ProgramArguments` 改成 DerivedData 中的 debug supervisor。
4. Debug Gateway 默认端口可能和正式版 gateway 冲突。
5. Debug App 会读写正式版 Keychain service 下的 provider/account/app-lock 信息。

因此，在实现隔离前，不建议直接对当前 scheme 执行 Xcode Run。

## 三、设计目标

1. Xcode Debug Run 不读写正式安装版 App Support 目录。
2. Debug Supervisor 使用独立 Mach service 和 LaunchAgent label。
3. Debug App 不会 bootout、kickstart 或覆盖正式版 supervisor。
4. Debug 创建的 managed profile 使用独立默认端口段。
5. Debug Keychain/UserDefaults 与正式版隔离。
6. 正式版 Release 构建行为不变。
7. 正式安装版和 Debug 版可以同时运行，互不抢数据、互不抢 supervisor。

## 四、非目标

- 不隔离用户手动选择的外部 OpenClaw 目录本身。
  - 如果用户在 Debug 版里主动导入某个生产 OpenClaw 配置，并选择“托管”，Debug 版仍可能写入该外部 `openclaw.json`。
  - Debug 方案只能保证 EZRWorker 自身数据、supervisor、端口隔离。
- 不新增完整多品牌构建系统。
- 不改 Release 安装器的正式路径、正式 label 和正式 bundle id。
- 不自动停止正式版 App 或正式版 gateway。

## 五、隔离矩阵

| 资源 | 正式版 | Debug 版 |
| --- | --- | --- |
| App bundle id | `ai.ezrworker.mac` | `ai.ezrworker.mac.dev` |
| App display name | `EZRWorker` | `EZRWorker Dev` |
| Supervisor Mach service | `ai.ezrworker.mac.supervisor` | `ai.ezrworker.mac.dev.supervisor` |
| Supervisor LaunchAgent label | `ai.ezrworker.mac.supervisor` | `ai.ezrworker.mac.dev.supervisor` |
| Supervisor plist | `~/Library/LaunchAgents/ai.ezrworker.mac.supervisor.plist` | `~/Library/LaunchAgents/ai.ezrworker.mac.dev.supervisor.plist` |
| App Support | `~/Library/Application Support/EZRWorker` | `~/Library/Application Support/EZRWorker-Dev` |
| profiles document | `~/Library/Application Support/EZRWorker/profiles.json` | `~/Library/Application Support/EZRWorker-Dev/profiles.json` |
| managed profile root | `~/Library/Application Support/EZRWorker/profiles/<slug>` | `~/Library/Application Support/EZRWorker-Dev/profiles/<slug>` |
| Keychain prefix | `ai.ezrworker.mac*` | `ai.ezrworker.mac.dev*` |
| UserDefaults key prefix | `ai.ezrworker.mac*` | `ai.ezrworker.mac.dev*` |
| Gateway port range | `18789...18999` | `19789...19999` |

## 六、核心设计

### 6.1 增加 Build Flavor

在 `Shared/EZRWorkerBranding.swift` 中集中管理 Debug/Release 差异。

建议采用编译期分支：

```swift
enum EZRWorkerBuildFlavor {
    #if DEBUG
    static let isDev = true
    #else
    static let isDev = false
    #endif
}
```

然后所有身份字段统一从 flavor 派生：

```swift
enum EZRWorkerBranding {
    #if DEBUG
    static let appName = "EZRWorker Dev"
    static let appBundleIdentifier = "ai.ezrworker.mac.dev"
    static let supervisorMachServiceName = "ai.ezrworker.mac.dev.supervisor"
    static let supervisorLaunchAgentLabel = "ai.ezrworker.mac.dev.supervisor"
    static let helperMachServiceName = "ai.ezrworker.mac.dev.helper"
    static let osLogSubsystem = "ai.ezrworker.mac.dev"
    static let providerKeychainService = "ai.ezrworker.mac.dev"
    static let accountKeychainService = "ai.ezrworker.mac.dev.accounts"
    static let userPasswordKeychainService = "ai.ezrworker.mac.dev.user-pw"
    static let appLockKeychainService = "ai.ezrworker.mac.dev.applock"
    static let appLockEnabledDefaultsKey = "ai.ezrworker.mac.dev.applock.enabled"
    static let lastSelectedProfileDefaultsKey = "ai.ezrworker.mac.dev.lastSelectedProfileID"
    static let applicationSupportDirectoryName = "EZRWorker-Dev"
    #else
    static let appName = "EZRWorker"
    static let appBundleIdentifier = "ai.ezrworker.mac"
    static let supervisorMachServiceName = "ai.ezrworker.mac.supervisor"
    static let supervisorLaunchAgentLabel = "ai.ezrworker.mac.supervisor"
    static let helperMachServiceName = "ai.ezrworker.mac.helper"
    static let osLogSubsystem = "ai.ezrworker.mac"
    static let providerKeychainService = "ai.ezrworker.mac"
    static let accountKeychainService = "ai.ezrworker.mac.accounts"
    static let userPasswordKeychainService = "ai.ezrworker.mac.user-pw"
    static let appLockKeychainService = "ai.ezrworker.mac.applock"
    static let appLockEnabledDefaultsKey = "ai.ezrworker.mac.applock.enabled"
    static let lastSelectedProfileDefaultsKey = "ai.ezrworker.mac.lastSelectedProfileID"
    static let applicationSupportDirectoryName = "EZRWorker"
    #endif
}
```

注意：`Shared/EZRWorkerBranding.swift` 同时被 App 和 Supervisor 使用，所以 Debug 编译时 App 和 Supervisor 会自然使用同一套 dev service name。

### 6.2 隔离 Gateway 默认端口段

在 `GatewayProfileResolver` 中按 flavor 分叉：

```swift
enum GatewayProfileResolver {
    #if DEBUG
    static let defaultGatewayPort = 19789
    static let managedPortRange = 19789...19999
    #else
    static let defaultGatewayPort = 18789
    static let managedPortRange = 18789...18999
    #endif

    static let managedPortSpacing = 20
}
```

这样 Debug 新建 profile 时不会与正式版默认 profile 抢 `18789` 端口。

### 6.3 隔离 Supervisor LaunchAgent

当前 `SupervisorClient.runtimeLaunchAgentContext()` 已经使用：

```swift
EZRWorkerBranding.supervisorLaunchAgentLabel
EZRWorkerBranding.supervisorMachServiceName
```

因此 branding 切到 Debug 后，它会自动生成：

```text
~/Library/LaunchAgents/ai.ezrworker.mac.dev.supervisor.plist
```

并执行：

```text
launchctl bootout gui/<uid>/ai.ezrworker.mac.dev.supervisor
launchctl bootstrap gui/<uid> ~/Library/LaunchAgents/ai.ezrworker.mac.dev.supervisor.plist
launchctl kickstart -k gui/<uid>/ai.ezrworker.mac.dev.supervisor
```

不会碰正式版：

```text
ai.ezrworker.mac.supervisor
```

需要重点检查 `SupervisorClient` 中是否仍有硬编码 `ai.ezrworker.mac.supervisor`。如果有，全部改为 branding 常量。

### 6.4 Xcode Debug Bundle ID

在 `EZRWorker.xcodeproj/project.pbxproj` 中把 App target 的 Debug 配置改为：

```text
PRODUCT_BUNDLE_IDENTIFIER = ai.ezrworker.mac.dev;
```

Release 保持：

```text
PRODUCT_BUNDLE_IDENTIFIER = ai.ezrworker.mac;
```

Supervisor target Debug 配置改为：

```text
PRODUCT_BUNDLE_IDENTIFIER = ai.ezrworker.mac.dev.supervisor;
```

Release 保持：

```text
PRODUCT_BUNDLE_IDENTIFIER = ai.ezrworker.mac.supervisor;
```

可选：Debug 的 `INFOPLIST_KEY_CFBundleDisplayName` 设置为：

```text
EZRWorker Dev
```

这样 Dock、Activity Monitor、崩溃日志里能一眼区分。

### 6.5 Entitlements

当前 App entitlement 允许连接：

```xml
<string>ai.ezrworker.mac.helper</string>
<string>ai.ezrworker.mac.supervisor</string>
```

推荐方案：新增 `EZRWorkerApp/EZRWorkerDebug.entitlements`，Debug 使用：

```xml
<array>
    <string>ai.ezrworker.mac.dev.helper</string>
    <string>ai.ezrworker.mac.dev.supervisor</string>
</array>
```

Release 继续使用 `EZRWorker.entitlements`。

如果想减少文件数量，也可以在同一个 entitlement 里同时加入正式和 dev service name。但 Release 包含 dev 临时例外不够干净，因此不作为首选。

### 6.6 静态资源 plist

`Resources/ai.ezrworker.mac.supervisor.plist` 是正式版 supervisor plist。

Debug Run 的关键路径是 `SupervisorClient.runtimeLaunchAgentContext()` 动态写入用户目录 plist，不强依赖 bundle 内静态 plist。

最低改动方案：

- 保持现有静态 plist 不动。
- Debug Run 只使用动态生成的 dev plist。

更完整方案：

- 增加 `Resources/ai.ezrworker.mac.dev.supervisor.plist`。
- Embed script 根据 `CONFIGURATION` 复制不同 plist。

本阶段建议采用最低改动方案，除非后续要做 Debug pkg。

### 6.7 Debug 外部导入保护

Debug flavor 隔离的是 EZRWorker 自己的数据，不自动隔离用户手动导入的外部 OpenClaw 目录。

因此建议增加两条保护：

1. Debug 版导入外部 OpenClaw 时，默认选择 `observeOnly`。
2. 用户切到 `managedByEZRWorker` 时显示明确提示：

```text
Debug 版托管外部 OpenClaw 会写入该实例的 openclaw.json。仅观察不会写入配置。
```

这不是阻塞项，但对调试“已有 OpenClaw 接管”很有价值。

## 七、实施步骤

### Phase 1：Branding 分叉

修改：

- `Shared/EZRWorkerBranding.swift`

内容：

- 加入 Debug/Release 分支。
- 所有 service/key/path 名称使用 Debug dev 后缀。
- 保持 Release 常量完全不变。

验收：

- Debug 下 `EZRWorkerPaths.applicationSupportDirectory.path` 为：

```text
~/Library/Application Support/EZRWorker-Dev
```

- Release 下仍为：

```text
~/Library/Application Support/EZRWorker
```

### Phase 2：端口分叉

修改：

- `Shared/GatewayProfiles.swift`

内容：

- Debug `defaultGatewayPort = 19789`
- Debug `managedPortRange = 19789...19999`
- Release 保持 `18789...18999`

验收：

- Debug 首次创建 default profile，resolved port 为 `19789`。
- 正式版 default profile 不变。

### Phase 3：Xcode 构建设置

修改：

- `EZRWorker.xcodeproj/project.pbxproj`
- 可选新增 `EZRWorkerApp/EZRWorkerDebug.entitlements`

内容：

- App Debug bundle id 改为 `ai.ezrworker.mac.dev`。
- Supervisor Debug bundle id 改为 `ai.ezrworker.mac.dev.supervisor`。
- Debug App 使用 Debug entitlement。
- Release 设置不变。

验收：

```text
Debug EZRWorker.app Info.plist:
CFBundleIdentifier = ai.ezrworker.mac.dev

Release EZRWorker.app Info.plist:
CFBundleIdentifier = ai.ezrworker.mac
```

### Phase 4：Supervisor 硬编码检查

扫描：

```text
ai.ezrworker.mac.supervisor
ai.ezrworker.mac.helper
~/Library/Application Support/EZRWorker
```

要求：

- App/Supervisor 运行时代码不能再硬编码正式 service/path。
- 文档、Release 脚本、正式安装器可以保留正式硬编码。

重点检查：

- `EZRWorkerApp/EZRWorker/Services/SupervisorClient.swift`
- `EZRWorkerSupervisor/main.swift`
- `Shared/EZRWorkerBranding.swift`
- `Shared/EZRWorkerPaths`

### Phase 5：Debug 安全 UI

可选修改：

- 设置页或 About 区域显示 `Dev` 标记。
- 外部 OpenClaw 导入页在 Debug 下默认 `observeOnly`。
- 托管外部实例时提示会写入外部配置。

这一步不是 Debug Run 隔离的硬要求，但能降低误操作风险。

## 八、验证方案

### 8.1 构建验证

```text
xcodebuild -project EZRWorker.xcodeproj -scheme EZRWorker -configuration Debug -destination 'platform=macOS,arch=x86_64' build
xcodebuild -project EZRWorker.xcodeproj -scheme EZRWorker -configuration Release -destination 'platform=macOS,arch=x86_64' build
```

### 8.2 身份验证

检查 Debug app：

```text
plutil -p <DerivedData>/Build/Products/Debug/EZRWorker.app/Contents/Info.plist | grep CFBundleIdentifier
```

期望：

```text
ai.ezrworker.mac.dev
```

检查正式安装版：

```text
plutil -p /Applications/EZRWorker.app/Contents/Info.plist | grep CFBundleIdentifier
```

期望：

```text
ai.ezrworker.mac
```

### 8.3 LaunchAgent 验证

运行 Debug App 后检查：

```text
launchctl print gui/$(id -u)/ai.ezrworker.mac.dev.supervisor
launchctl print gui/$(id -u)/ai.ezrworker.mac.supervisor
```

期望：

- dev supervisor 存在，ProgramArguments 指向 DerivedData 中的 Debug `EZRWorkerSupervisor`
- 正式 supervisor 如果存在，仍指向 `/Applications/EZRWorker.app/...` 或正式安装路径
- Debug Run 不会把正式 plist 改成 DerivedData 路径

### 8.4 文件路径验证

Debug App 运行后应出现：

```text
~/Library/Application Support/EZRWorker-Dev/profiles.json
~/Library/LaunchAgents/ai.ezrworker.mac.dev.supervisor.plist
```

正式目录不应因 Debug 首启被修改：

```text
~/Library/Application Support/EZRWorker/profiles.json
~/Library/LaunchAgents/ai.ezrworker.mac.supervisor.plist
```

### 8.5 端口验证

Debug default profile 应监听：

```text
19789
```

正式版 default profile 仍监听：

```text
18789
```

两者可以同时存在。

## 九、Debug 清理手册

如果需要清掉 Debug 环境：

```text
launchctl bootout gui/$(id -u)/ai.ezrworker.mac.dev.supervisor
rm -f ~/Library/LaunchAgents/ai.ezrworker.mac.dev.supervisor.plist
rm -rf ~/Library/Application\ Support/EZRWorker-Dev
```

Keychain 清理可按需要单独做，不建议默认自动删除，避免误删调试凭据。

## 十、风险与对策

### 10.1 Debug 误写正式 LaunchAgent

风险：某处仍硬编码 `ai.ezrworker.mac.supervisor`。

对策：

- 实施后用 `rg "ai\\.ezrworker\\.mac\\.supervisor"` 检查运行时代码。
- 允许 Release 脚本/文档保留正式标识。

### 10.2 Debug 误读正式 profiles

风险：路径仍写死 `EZRWorker`。

对策：

- 所有 App Support 路径必须走 `EZRWorkerPaths.applicationSupportDirectory`。
- Debug 首启验证只生成 `EZRWorker-Dev`。

### 10.3 Debug 与正式 gateway 端口冲突

风险：默认端口仍是 `18789`。

对策：

- Debug 端口段改为 `19789...19999`。
- `GatewayProfileResolver.nextAvailablePort` 继续使用现有可用性检测。

### 10.4 外部 OpenClaw 目录仍可能被写

风险：用户在 Debug 版导入生产 OpenClaw 并选择托管。

对策：

- Debug 默认导入模式为 `observeOnly`。
- 托管前明确提示会写入外部 `openclaw.json`。

## 十一、推荐落地顺序

1. 先做 `EZRWorkerBranding` 和端口分叉。
2. 再改 Xcode Debug bundle id。
3. 跑 Debug build，确认 LaunchAgent 生成 dev plist。
4. 跑 Release build，确认正式身份完全不变。
5. 最后补 Debug UI 标记和外部导入提示。

## 十二、最终验收标准

在已安装正式版 `/Applications/EZRWorker.app` 的机器上：

1. 从 Xcode Run Debug App。
2. 正式版 `~/Library/Application Support/EZRWorker` 不被修改。
3. 正式版 `~/Library/LaunchAgents/ai.ezrworker.mac.supervisor.plist` 不被改写。
4. Debug App 创建 `~/Library/Application Support/EZRWorker-Dev`。
5. Debug App 创建 `~/Library/LaunchAgents/ai.ezrworker.mac.dev.supervisor.plist`。
6. Debug Supervisor Mach service 为 `ai.ezrworker.mac.dev.supervisor`。
7. Debug Gateway 默认端口为 `19789`。
8. 正式版 Gateway 可以继续使用 `18789`。
9. 两个 App 可以同时启动，互不抢 supervisor、互不抢 profile 数据。
