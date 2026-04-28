# App 版本更新功能设计方案

## 核心结论

App 版本更新功能不再依赖 Helper。

- 主 App 直接读取静态更新清单 `version.json` / `latest.json`，不需要动态后端接口。
- 主 App 自己缓存更新状态。
- 主 App 自己下载 pkg、展示进度、校验 sha256。
- 安装仍交给系统 Installer；pkg 安装过程会覆盖 App、Helper 和 Supervisor 文件。
- Helper 里的更新心跳/XPC 缓存只作为历史链路处理，不进入新方案主路径。
- 更新域名不能硬编码。客户端、发布脚本和静态清单都必须从配置读取更新源。

## 一、背景与现状

当前仓库里已经有一套 App 更新能力的雏形，但还没有形成完整产品闭环。

已有能力：

- `EZRWorkerApp/EZRWorker/Services/UpdateChecker.swift`
  - 当前读取构建配置中的更新清单 URL，默认指向 `https://imp-assets.ezrpro.com/ezrworker/updates/latest.json`
  - 比较当前 App 版本和远端版本
  - 下载 `.pkg`
  - 打开安装器
  - 隐藏当前 App，并在检测到新版安装完成后自动拉起
- `EZRWorkerApp/Views/AppUpdateBanner.swift`
  - 展示“有新版本”侧边栏横幅
  - 展示更新说明、下载进度、取消下载和立即更新
- `Shared/AppUpdateState.swift`
  - 已定义更新状态模型，但它目前放在 Shared 层，容易暗示 App 更新需要跨进程协作
- `scripts/release.sh` / `scripts/build-pkg.sh`
  - 已能生成 arm64 / x64 pkg
  - 已能同步 `updates/latest.json` 和兼容路径 `api/version.json`
  - 已能写出 `version`、`build`、`download_url`、`download_url_x64`、`packages`、`sha256`、`release_notes`、`release_notes_en`
  - 当前默认更新源为 `https://imp-assets.ezrpro.com/ezrworker/`，静态站目录由 `UPDATE_SITE_DIR` 指定

主要缺口：

- 新主线 `MainView` / `SidebarView` 没有展示 `AppUpdateBanner`，更新横幅目前只接在 legacy `ContentView`。
- 新主线 `AppSettingsView` 的“关于”区域只展示当前版本/构建号，没有检查更新、更新详情和下载入口。
- 现有 Helper 里有 `AppUpdateHeartbeatService` / `getCachedAppUpdateState` 历史链路，但新主线 App 更新不应再依赖 Helper/XPC。
- 更新状态模型没有架构信息、文件大小、sha256、强制升级文案等字段。
- 需要确认线上 CDN 已同步 `updates/latest.json`、`api/version.json` 和 `download/` 下的双架构 pkg。
- `appMustUpdate` 已计算，但 UI 没有强制升级 gating。
- 版本比较逻辑只支持纯数字段，应该集中测试 `1.6.0`、`1.6`、`v1.6.0`、build metadata 等场景。
- 下载完整性只检查文件大小大于 100KB，缺少 sha256 校验。
- 发布侧没有把 checksum 写入 `version.json`，线上回滚/灰度/最低版本策略也没有明确约束。
- 更新源域名仍散落在 App、脚本和 README 中，必须收口到统一配置，避免误指向不再归属自己的域名。

## 二、设计目标

1. 用户启动 App 后能自动发现新版本，不依赖手动进入设置页。
2. 新主线侧边栏和设置页都能清晰展示更新状态。
3. 下载过程可见、可取消、错误可恢复。
4. 完成 pkg 安装后，App 能尽量自动拉起新版；失败时给出明确手动操作提示。
5. 支持强制升级：当当前版本低于 `min_version` 时，阻止进入主功能，只允许更新或退出。
6. 支持 arm64 / x64 分发，客户端按当前 CPU 架构选择正确下载地址。
7. 下载前后做基础安全校验：HTTPS、文件大小、sha256、pkg 签名/公证发布约束。
8. App 更新检查、缓存、下载、校验都在主 App 内完成，不依赖 Helper。
9. 发布流程自动生成足够完整的静态 `version.json` / `latest.json`，避免手工同步遗漏。

非目标：

- 第一阶段不引入 Sparkle。当前安装包需要同时部署 App、Helper LaunchDaemon、Supervisor LaunchAgent，继续使用现有 pkg 更新链路更贴合项目现状；但“检查更新/下载更新”本身不调用 Helper。
- 不做静默后台安装。pkg 安装仍由系统安装器接管，避免绕过管理员授权与系统安全提示。
- 不改 OpenClaw 自身版本更新逻辑。`UpdateChecker` 里 openclaw 检查可以保留，但 App 更新应逐步独立成更清晰的服务边界。
- 不继续扩展 `EZRWorkerHelper/Operations/AppUpdateHeartbeatService.swift`。它可作为后续清理项移除或保留为旧版本兼容代码，但不进入新方案主路径。

## 三、无后端的静态更新清单协议

不需要新增后端接口。更新检查设计成“静态文件读取”：

- 发布脚本生成一个 JSON 清单文件。
- 清单文件随官网静态资源、CDN、对象存储或 GitHub Pages 一起发布。
- App 只做普通 HTTPS GET，不依赖登录态、数据库、服务端计算或 Helper。

更新源配置：

- 客户端构建配置：`APP_UPDATE_MANIFEST_URL`
- 发布脚本配置：`UPDATE_BASE_URL`
- 静态站目录配置：`UPDATE_SITE_DIR`

推荐清单地址形态：

- `{UPDATE_BASE_URL}/updates/latest.json`

兼容旧客户端时可额外生成：

- `{UPDATE_BASE_URL}/api/version.json`

说明：即使路径叫 `/api/version.json`，它也只是静态 JSON 文件，不是动态后端 API。若当前静态站没有 `/api` 路由，可以只使用 `/updates/latest.json`。客户端首选 URL 从 `Info.plist` 或构建参数读取，不应写死任何具体域名。

清单结构如下，保持旧字段兼容：

```json
{
  "version": "1.7.0",
  "build": "620",
  "min_version": "1.5.0",
  "channel": "stable",
  "release_date": "2026-04-25T10:00:00Z",
  "release_notes": "中文更新说明",
  "release_notes_en": "English release notes",
  "download_url": "https://example.com/download/EZRWorker-1.7.0-arm64.pkg",
  "download_url_x64": "https://example.com/download/EZRWorker-1.7.0-x64.pkg",
  "packages": {
    "arm64": {
      "url": "https://example.com/download/EZRWorker-1.7.0-arm64.pkg",
      "sha256": "..."
    },
    "x86_64": {
      "url": "https://example.com/download/EZRWorker-1.7.0-x64.pkg",
      "sha256": "..."
    }
  }
}
```

兼容策略：

- 新客户端优先读取 `packages[arch].url`。
- 如果 `packages` 不存在：
  - arm64 使用 `download_url`
  - x86_64 优先使用 `download_url_x64`，缺失时回退 `download_url`
- `release_notes` 按 App 当前语言或系统语言选择，中文优先中文，其他语言优先英文。
- `min_version` 为空时不触发强制升级。
- `channel` 第一阶段固定 `stable`，预留以后 `beta` / `canary`。

清单源策略：

```swift
enum AppUpdateManifestSource {
    static let bundledManifestURLKey = "AppUpdateManifestURL"
}
```

请求策略：

- 自动检查读取 `Info.plist` 中的 `AppUpdateManifestURL`。
- 如果 `AppUpdateManifestURL` 为空，App 更新功能显示为未配置，不请求网络。
- 如需兼容多个清单地址，可在 `Info.plist` 中放数组或在本地代码里派生 `/api/version.json` 兼容路径。
- 手动检查可以给 URL 加短 query，例如 `?t=<unix>`，用于绕过 CDN 短缓存。
- 静态站建议给清单设置较短缓存，例如 `Cache-Control: max-age=300`。
- 如果官网暂时没有静态文件托管能力，临时 fallback 可以使用 GitHub Release 的 `latest` 资产或 Release API；但这只是兜底，不作为首选方案。

## 四、核心模型

新增 App 内部更新模型，建议放在 `EZRWorkerApp/EZRWorker/Models/AppUpdateModels.swift` 或 `EZRWorkerApp/EZRWorker/Services/AppUpdateService.swift` 附近。第一阶段可以暂时复用现有 `Shared/AppUpdateState.swift`，但不再因为更新功能需要跨进程共享而继续扩展 Shared 边界。

```swift
struct AppUpdateState: Codable, Equatable {
    var latestVersion: String?
    var latestBuild: String?
    var downloadURL: String?
    var downloadURLX64: String?
    var selectedPackageURL: String?
    var selectedPackageSHA256: String?
    var releaseNotes: String?
    var minimumVersion: String?
    var channel: String
    var releaseDate: String?
    var lastSuccessfulCheckAt: TimeInterval?
    var lastError: String?
    var source: String
}
```

新增本地下载状态只放在 App 进程内，不跨进程持久化：

```swift
enum AppUpdateDownloadPhase: Equatable {
    case idle
    case checking
    case available
    case upToDate
    case downloading(progress: Double)
    case openingInstaller
    case awaitingRelaunch
    case failed(String)
}
```

版本比较建议抽成纯函数：

```swift
enum AppVersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult
}
```

规则：

- 去掉前缀 `v`
- 只比较主要数字段：`major.minor.patch`
- 缺失段补 0：`1.6 == 1.6.0`
- 非数字后缀作为较低优先级处理：`1.6.0-beta < 1.6.0`
- build 号不参与强制升级判断，只用于展示和诊断

## 五、服务设计

### 5.1 AppUpdateService

建议从 `UpdateChecker` 中拆出 App 自更新部分，形成 `AppUpdateService`；`UpdateChecker` 可以暂时保留 openclaw 检查职责，或作为 facade 兼容旧调用。

职责：

- 从 UserDefaults 恢复上次 App 更新状态。
- 启动后先读 App 本地缓存，再按策略决定是否直接发起网络检查。
- 拉取静态更新清单并解析为 `AppUpdateState`。
- 选择当前架构的下载包。
- 计算 `needsUpdate` / `mustUpdate`。
- 管理下载、校验、打开安装器、等待新版安装完成、重启当前 App。

推荐接口：

```swift
@Observable
@MainActor
final class AppUpdateService {
    var state: AppUpdateState
    var phase: AppUpdateDownloadPhase
    var downloadedBytes: Int64
    var totalBytes: Int64
    var downloadSpeed: Double

    var currentVersion: String { get }
    var currentBuild: String { get }
    var needsUpdate: Bool { get }
    var mustUpdate: Bool { get }

    func bootstrap() async
    func checkNow(forceNetwork: Bool) async
    func downloadAndInstall() async
    func cancelDownload()
}
```

### 5.2 本地缓存与检查策略

启动流程：

1. App 初始化 `AppUpdateService`。
2. 进入主窗口后调用 `bootstrap()`。
3. `bootstrap` 先读取 App 本地缓存，UI 可立即展示上次检查结果。
4. 再调用 `UpdateCheckPolicy.shouldCheck` 判断是否需要网络刷新。
5. 需要刷新时，主 App 直接请求静态更新清单 URL。
6. 检查成功后写入 App 本地缓存；检查失败只记录错误，不阻塞主流程。

注意：

- 当 App 主动点击“检查更新”时，必须绕过本地缓存直接请求静态更新清单。
- 强制升级只在 App 本地缓存或本次网络检查拿到明确 `min_version` 后生效。
- 本地缓存建议使用 `Application Support/EZRWorker/app-update-state.json`；如果先沿用 `UserDefaults`，后续可平滑迁移。
- 不调用 `HelperClient.getCachedAppUpdateState()`，不读取 `/var/lib/ezrworker/app-update-state.json`。

### 5.3 下载与安装

下载流程沿用现有实现，但增加校验：

1. 根据架构选择 pkg URL。
2. 要求 URL scheme 为 `https`。
3. 使用 `URLSessionDownloadDelegate` 追踪进度、速度、总大小。
4. 下载完成后校验：
   - HTTP 2xx
   - 文件大小大于最小阈值
   - 如果 `sha256` 存在，计算本地 sha256 并比对
5. 移动到临时目录：`~/Library/Caches/EZRWorker/Updates/EZRWorker-<version>-<arch>.pkg`。
6. 调用 `NSWorkspace.shared.open(pkgURL)` 打开系统安装器。
7. 隐藏当前 App，进入 `awaitingRelaunch`。
8. 周期性读取 `/Applications/EZRWorker.app/Contents/Info.plist`，检测安装版本是否不低于目标版本。
9. 检测成功后用 `NSWorkspace.openApplication` 拉起新版，再终止旧进程。
10. 20 分钟未检测成功则恢复窗口，提示用户手动完成安装或重新打开 App。

取消下载：

- 调用 `URLSession.invalidateAndCancel()`。
- 清理临时文件。
- phase 回到 `available`。

## 六、UI 设计

### 6.1 新主线侧边栏入口

在 `EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift` 的 `safeAreaInset(edge: .bottom)` 中加入更新横幅，位置在 Gateway 状态上方。

展示规则：

- `needsUpdate == true`：显示小型横幅，文案 `EZRWorker vX.Y.Z 可用`，点击打开更新详情 sheet。
- `mustUpdate == true`：横幅使用更强提醒色，文案 `需要更新后继续使用`。
- `phase == awaitingRelaunch`：显示安装器已打开/等待重启状态。
- 没有更新时不展示横幅。

`EZRWorkerApp/Views/AppUpdateBanner.swift` 可以迁移到新主线目录，或改造成共享组件。

### 6.2 设置页关于区域

在 `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift` 的 `aboutSection` 中增加：

- 当前版本 + 构建号。
- 最新版本。
- 最近检查时间。
- 检查更新按钮。
- 有更新时展示 `立即更新` 按钮。
- 有错误时展示错误摘要。

按钮规则：

- 检查中：按钮禁用，显示 `检查中...`
- 下载中：显示 progress 和取消按钮。
- 有更新：主按钮为 `立即更新`
- 无更新：显示 `当前已是最新版本`

### 6.3 强制升级 Gate

在 `AppRootGateView` 或 `AuthenticatedAppShell` 外层增加强制升级覆盖层：

- 当 `mustUpdate == true` 时，覆盖主界面。
- 展示当前版本、最低要求版本、最新版本和 release notes。
- 主操作：`立即更新`
- 次操作：`退出 EZRWorker`
- 不提供“稍后再说”。

如果网络检查失败：

- 不因为检查失败而阻断启动。
- 只有拿到明确的 `min_version` 且当前版本低于它时才进入强制升级。

### 6.4 Sheet 统一

把现有 `AppUpdateSheet` 改造成新主线可复用 sheet：

- 头部：App 图标、当前版本 -> 最新版本。
- 正文：release notes，可选展示发布日期。
- 底部：下载进度、速度、取消/重试/立即更新。
- 错误：明确区分“检查失败”“下载失败”“校验失败”“安装器打开失败”。

## 七、发布流程

### 7.0 当前 release.sh 做了什么

当前 `scripts/release.sh` 是“一键发布”脚本，职责不只是生成安装包：

1. 调用 `scripts/semver.sh`，根据 git tag 和提交记录计算下一版本号。
2. 读取 `release-notes/vX.Y.Z.zh.md` 与 `release-notes/vX.Y.Z.en.md`。
3. 更新 `CHANGELOG.zh.md` / `CHANGELOG.en.md`。
4. 更新 `EZRWorkerApp/Info.plist` 的 `CFBundleShortVersionString`。
5. 创建 release commit 和 `vX.Y.Z` tag。
6. 分别调用 `scripts/build-pkg.sh` 构建、签名并公证 arm64 / x86_64 pkg。
7. 写入 `$UPDATE_SITE_DIR/updates/latest.json`，并同步兼容路径 `$UPDATE_SITE_DIR/api/version.json`。
8. 把 pkg 与 `.sha256` 复制到 `$UPDATE_SITE_DIR/download/`。
9. `make release` 会 `git push`、推送 tag，并用 `gh release create` 创建 GitHub Release。
10. `make release-local` 会 `git push`、推送 tag，但跳过 GitHub Release。
11. 最后提示把 `$UPDATE_SITE_DIR` 发布到 CDN 源站。

当前发布源配置：

- 默认 `UPDATE_BASE_URL=https://imp-assets.ezrpro.com/ezrworker/`。
- 客户端默认读取 `https://imp-assets.ezrpro.com/ezrworker/updates/latest.json`。
- 本地静态站目录由 `UPDATE_SITE_DIR` 指定；示例：`/Users/charles/Desktop/WORK/clawdhome/ezrworker-updates-site`。
- `release-local` 生成本地更新站内容后，还需要把该目录内容上传或部署到 CDN 源站。

实现状态：更新站点已配置化，不再内置旧域名或旧网站目录。

### 7.1 build-pkg.sh

保持当前 pkg 构建逻辑，新增 checksum 输出：

- 每个 pkg 生成后计算 `shasum -a 256`。
- 输出到 `dist/EZRWorker-<version>-<arch>.pkg.sha256`。
- `--sync-api-version` 若保留，也必须改用 `UPDATE_BASE_URL` / `UPDATE_SITE_DIR`，或者直接废弃，统一由 `release.sh` 生成清单。

### 7.2 release.sh

发布时生成静态更新清单，至少写入：

- `version`
- `build`
- `min_version`
- `download_url`
- `download_url_x64`
- `packages.arm64.url`
- `packages.arm64.sha256`
- `packages.x86_64.url`
- `packages.x86_64.sha256`
- `release_notes`
- `release_notes_en`
- `release_date`

输出建议：

- `$UPDATE_SITE_DIR/updates/latest.json`
- 兼容旧路径时同步一份到 `$UPDATE_SITE_DIR/api/version.json`

这两个文件都由 `release.sh` 直接写入，不需要后端接口。

必要环境变量：

```bash
UPDATE_BASE_URL="https://imp-assets.ezrpro.com/ezrworker/"
UPDATE_SITE_DIR="/Users/charles/Desktop/WORK/clawdhome/ezrworker-updates-site"
```

可选环境变量：

```bash
UPDATE_MANIFEST_PATH="/updates/latest.json"
UPDATE_COMPAT_MANIFEST_PATH="/api/version.json"
UPDATE_DOWNLOAD_PATH="/download"
MIN_APP_VERSION="1.6.0"
```

生成下载地址：

```text
${UPDATE_BASE_URL}${UPDATE_DOWNLOAD_PATH}/EZRWorker-${NEXT_VERSION}-arm64.pkg
${UPDATE_BASE_URL}${UPDATE_DOWNLOAD_PATH}/EZRWorker-${NEXT_VERSION}-x64.pkg
```

脚本约束：

- 正式发布时 `UPDATE_BASE_URL` 必填，默认使用 `https://imp-assets.ezrpro.com/ezrworker/`。
- `UPDATE_BASE_URL` 必须是 HTTPS。
- `UPDATE_BASE_URL` 不能是旧域名。
- `UPDATE_SITE_DIR` 不存在时不写清单，但仍可创建 GitHub Release。
- dry-run 必须打印最终 manifest URL、download URL、输出文件路径。
- 发布构建前会检查并清理 `build/release-arm64` / `build/release-x86_64`，避免第二个架构清理失败导致前一个架构白跑。

`min_version` 来源建议：

- 默认沿用现有线上 `min_version`，避免每次发布误触强制升级。
- 支持环境变量覆盖：`MIN_APP_VERSION=1.6.0 make release`。
- dry-run 输出即将写入的清单内容和 `min_version`，让发布人确认。

### 7.3 线上回滚

回滚方式：

- 只回滚静态更新清单指向的 `version` 和下载地址，不要求客户端特殊处理。
- 如果已经发布了较高 `min_version`，回滚时必须同步降低或清空 `min_version`，否则旧版本会被继续强制升级。

## 八、安全与可靠性

安全约束：

- 下载地址必须是 HTTPS。
- sha256 存在时必须校验通过。
- 正式发布的 pkg 必须 Developer ID Installer 签名并完成 notarization。
- 安装前不执行自定义提权命令，交给系统 Installer。

可靠性约束：

- `checkAppIfNeeded` 保持 24 小时缓存，手动检查绕过缓存。
- App 本地缓存只用于快速展示和离线降级，不作为唯一真相；手动检查始终请求静态清单。
- 下载失败保留更新详情 sheet，允许重试。
- 安装器打开后旧 App 不立即退出，而是隐藏并等待新版安装完成。
- 自动重启失败时恢复旧 App 并提示用户手动打开新版。

隐私约束：

- `User-Agent` 只发送版本、系统、架构、语言等诊断字段。
- 不发送手机号、profile 名称、agent 信息、模型 API key 或本地路径。

## 九、实施阶段

### Phase 1：补齐主线 UI 与 App 自更新服务

文件：

- `EZRWorkerApp/EZRWorker/Services/UpdateChecker.swift`
- `EZRWorkerApp/EZRWorker/App/EZRWorkerApp.swift`
- `EZRWorkerApp/EZRWorker/App/Sidebar/SidebarView.swift`
- `EZRWorkerApp/EZRWorker/Views/Settings/AppSettingsView.swift`
- `EZRWorkerApp/Views/AppUpdateBanner.swift`

工作：

- 新主线注入并启动 App 更新检查。
- App 启动时读取本地更新缓存，并按策略直接请求静态更新清单。
- 侧边栏加入更新横幅。
- 设置页“关于”加入检查更新和立即更新。
- 复用现有 `AppUpdateSheet`。
- 不接入 `HelperClient.getCachedAppUpdateState()`。

验收：

- 有更新时新主线侧边栏能看到横幅。
- 设置页可手动检查更新。
- App 本地缓存存在时，断网启动仍能展示最近一次更新状态。

### Phase 2：版本协议与架构选择

文件：

- `EZRWorkerApp/EZRWorker/Models/AppUpdateModels.swift` 或 `EZRWorkerApp/EZRWorker/Services/UpdateChecker.swift`
- `EZRWorkerApp/EZRWorker/Services/UpdateChecker.swift`
- `tests/AppUpdateModelTests.swift` 或现有 `tests/AppUpdateStateTests.swift`

工作：

- 扩展 App 内更新状态模型。
- 解析 `packages`、`download_url_x64`、`sha256`。
- 按当前 CPU 架构选择下载地址。
- 保持旧版 `version.json` 字段兼容。

验收：

- arm64 机器选择 arm64 pkg。
- x86_64 机器选择 x64 pkg。
- 旧版 `version.json` 仍可解析。

### Phase 3：下载校验与强制升级

文件：

- `EZRWorkerApp/EZRWorker/Services/UpdateChecker.swift`
- `EZRWorkerApp/EZRWorker/App/AppRootGateView.swift`
- `EZRWorkerApp/Views/AppUpdateBanner.swift`
- `tests/UpdateCheckPolicyTests.swift`

工作：

- 下载完成后校验 sha256。
- 引入强制升级覆盖层。
- 完善下载失败、校验失败、安装器打开失败错误状态。
- 抽出版本比较纯函数并加测试。

验收：

- sha256 不匹配时不会打开安装器。
- 当前版本低于 `min_version` 时无法进入主功能。
- `1.6` 与 `1.6.0` 被视为同版本。

### Phase 4：发布自动化

文件：

- `scripts/build-pkg.sh`
- `scripts/release.sh`
- `EZRWorkerApp/Info.plist`

工作：

- 生成 pkg sha256。
- `release.sh` 写入 `packages`、`sha256`、`build`、`release_date`。
- `release.sh` 改用 `UPDATE_BASE_URL` / `UPDATE_SITE_DIR`，移除旧域名硬编码。
- App 从 `Info.plist` 的 `AppUpdateManifestURL` 读取更新清单地址。
- 支持 `MIN_APP_VERSION` 覆盖。
- dry-run 展示静态更新清单预期变更。

验收：

- `make release-dry-run` 能看到完整静态更新清单预览。
- 正式 release 后 `updates/latest.json` 包含 arm64/x86_64 下载地址和 sha256；如保留兼容路径，`api/version.json` 内容一致。
- 仓库中 App 更新路径不再硬编码旧域名。
- 未配置 `AppUpdateManifestURL` 时，App 不请求旧域名，只展示更新源未配置。

## 十、测试计划

单元测试：

- `AppUpdateModelTests`
  - 旧 JSON 字段兼容
  - 新 `packages` 字段解析
  - 缺失可选字段不崩溃
- `AppVersionComparatorTests`
  - `1.6 == 1.6.0`
  - `v1.6.0 == 1.6.0`
  - `1.6.1 > 1.6.0`
  - `1.6.0-beta < 1.6.0`
- `UpdateCheckPolicyTests`
  - 手动检查绕过缓存
  - 缓存不存在立即检查
  - 缓存未过期时启动检查不重复请求静态清单

手动验证：

1. 本地 mock 静态更新清单指向一个高版本。
2. 启动 App，验证侧边栏横幅出现。
3. 在设置页点击检查更新，验证文案和最新版本。
4. 点击立即更新，验证下载进度、取消、重试。
5. 用错误 sha256 验证校验失败。
6. 用正确 pkg 验证安装器打开、App 隐藏、安装完成后自动拉起。
7. 设置 `min_version` 高于当前版本，验证强制升级覆盖层。
8. 断网启动，验证 App 本地缓存展示不阻塞主流程。

## 十一、风险与处理

- pkg 安装期间用户取消安装：旧 App 会在等待超时后恢复，并提示手动完成安装。
- 用户没有管理员权限：系统 Installer 会处理授权失败，App 侧展示“安装器已打开但未检测到新版”。
- 下载到错误 HTML 页面：文件大小和 sha256 校验会拦截。
- `version.json` 写错 x64 地址：x64 用户下载失败，设置页保留重试和错误提示；发布 dry-run 要显示两个 URL。
- 强制升级配置错误：只能通过线上修正 `min_version` 恢复，因此 release 脚本必须在 dry-run 中突出展示。

## 十二、待确认问题

1. 是否需要支持 beta 更新通道，还是第一阶段只做 stable？
2. `min_version` 的发布权限是否需要单独开关，例如只能由手动环境变量设置？
3. 是否需要在更新弹窗中显示“官网下载”备用链接？
4. 正式发布是否要求所有 pkg 均签名并 notarize 后才同步 `version.json`？
5. 新的更新静态站域名是什么？如果暂时没有域名，是否先用 GitHub Release 资产作为下载源、GitHub Pages 作为 manifest 源？
