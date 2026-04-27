# 打包、版本和发布流程

这份文档说明 EZRWorker 的 macOS `.pkg` 打包、版本更新和正式发布流程。当前项目支持 Apple Silicon（M 系列，`arm64`）和 Intel（`x86_64`）两类安装包。

## 快速命令

| 场景 | 命令 | 输出 |
| --- | --- | --- |
| 本机开发快速打包，默认 Apple Silicon | `make pkg` | `dist/EZRWorker-<version>-b<build>-arm64.pkg` |
| 单独打 Intel 包 | `make pkg-intel` | `dist/EZRWorker-<version>-b<build>-x64.pkg` |
| 连续打 Apple Silicon + Intel 两个包 | `make pkg-all` | `dist/*-arm64.pkg` 和 `dist/*-x64.pkg` |
| 打 Universal 包 | `make pkg-universal` | `dist/*-universal.pkg` |
| 本地验收用签名包 | `make pkg-signed` | 已签名、未公证 pkg |
| 签名并公证 | `make notarize-pkg` | 已签名、已公证 pkg |
| 正式发布 | `make release NOTARIZE=true` | `dist/EZRWorker-<version>-arm64.pkg` 和 `dist/EZRWorker-<version>-x64.pkg` |

正式对外发布推荐使用两个独立包：`arm64` 给 M 系列 Mac，`x64` 给 Intel Mac。`pkg-universal` 会构建 Universal App 二进制，但当前嵌入的 Node.js/OpenClaw 运行时只取 `PKG_ARCHS` 的第一个架构，外部分发时不要把它当作 Intel + Apple Silicon 的唯一包。

## 前置条件

- macOS 14+
- Xcode 15+，并已接受 license
- 可访问网络，因为打包会下载 Node.js，并通过 npm 安装 `openclaw@latest`
- 正式发布需要 Developer ID Application / Developer ID Installer 证书
- 正式发布需要 `gh` CLI 登录，用于创建 GitHub Release
- 如果要同步官网更新信息，默认相邻目录存在 `../clawdhome_website`

检查 Xcode：

```bash
xcode-select -p
sudo xcodebuild -license accept
```

配置公证 profile 示例：

```bash
xcrun notarytool store-credentials clawdhome-release \
  --apple-id "你的 Apple ID" \
  --team-id "9P6LY282WU" \
  --password "app-specific-password"
```

项目默认读取这些环境变量：

```bash
APPLE_TEAM_ID=9P6LY282WU
APP_SIGN_IDENTITY="Developer ID Application"
PKG_SIGN_IDENTITY="Developer ID Installer"
NOTARY_PROFILE=clawdhome-release
```

## 版本规则

项目版本分两层：

- `CFBundleShortVersionString`：面向用户的语义化版本，例如 `1.5.0`
- `CFBundleVersion`：构建号，由本地 `.build-version` 自动递增，默认从 `500` 开始

语义化版本由 `scripts/semver.sh` 根据最近的 `v*` tag 和之后的 commit 自动计算：

```bash
make version
make version-next
bash scripts/semver.sh --current
bash scripts/semver.sh --bump-type
```

没有任何 `v*` tag 时，首个发布版本默认为 `1.0.0`。如需临时调整首发版本，可设置 `INITIAL_VERSION=1.0.0` 这类 `MAJOR.MINOR.PATCH` 格式的值。

bump 规则：

| Commit 类型 | 版本变化 |
| --- | --- |
| `BREAKING CHANGE:`、`feat!:`、`fix!:` | major |
| `feat:` | minor |
| `fix:`、`perf:` | patch |
| 没有功能或修复提交 | 默认 patch |

正常不要手动改 `EZRWorkerApp/Info.plist` 的版本号。`make release` 会在发布提交里把 `CFBundleShortVersionString` 更新为下一版本，并创建 `vX.Y.Z` tag。

## 本地打包

生成 Apple Silicon 包：

```bash
make pkg
```

生成 Intel 包：

```bash
make pkg-intel
```

一次生成两个独立包：

```bash
make pkg-all
```

如果不想触发 Makefile 里的 Finder 打开动作，可以直接运行脚本：

```bash
PKG_ARCHS=arm64 bash scripts/build-pkg.sh --no-sync-api-version
PKG_ARCHS=x86_64 bash scripts/build-pkg.sh --no-sync-api-version
```

支持的 `PKG_ARCHS`：

| 值 | 说明 | 包名后缀 |
| --- | --- | --- |
| `arm64` | Apple Silicon / M 系列 | `-arm64` |
| `x86_64`、`x64`、`intel` | Intel Mac | `-x64` |
| `arm64 x86_64`、`universal`、`universal2` | Universal App 二进制 | `-universal` |

安装最新本地包：

```bash
make install-pkg
```

或安装指定包：

```bash
sudo installer -pkg "dist/EZRWorker-1.5.0-b501-arm64.pkg" -target /
```

## 签名和公证

生成已签名、未公证的本地验收包：

```bash
make pkg-signed
```

生成已签名、已公证的包：

```bash
make notarize-pkg NOTARY_PROFILE=clawdhome-release
```

如果证书名称不同，按需覆盖：

```bash
make notarize-pkg \
  APPLE_TEAM_ID=9P6LY282WU \
  APP_SIGN_IDENTITY="Developer ID Application" \
  PKG_SIGN_IDENTITY="Developer ID Installer" \
  NOTARY_PROFILE=clawdhome-release
```

## 发布说明

每个正式版本需要两份发布说明：

- `release-notes/vX.Y.Z.zh.md`
- `release-notes/vX.Y.Z.en.md`

推荐流程：

```bash
make version-next
make release-notes-draft
```

检查并编辑生成的中英文文件后，再做 dry run：

```bash
make release-dry-run NOTARIZE=true
```

## 正式发布

发布前确保工作区干净，release notes 已确认：

```bash
git status --short
make release-dry-run NOTARIZE=true
make release NOTARIZE=true
```

`make release` 会执行：

1. 计算下一版本号。
2. 读取中英文 release notes。
3. 更新 `CHANGELOG.zh.md` 和 `CHANGELOG.en.md`。
4. 更新 `EZRWorkerApp/Info.plist` 的 `CFBundleShortVersionString`。
5. 创建 release commit：`chore(release): vX.Y.Z`。
6. 创建 tag：`vX.Y.Z`。
7. 分别构建 `arm64` 和 `x86_64` pkg。
8. 同步 `../clawdhome_website/api/version.json`。
9. 复制安装包到 `../clawdhome_website/download/`。
10. `git push`、`git push --tags`，并创建 GitHub Release。

正式产物：

```text
dist/EZRWorker-<version>-arm64.pkg
dist/EZRWorker-<version>-x64.pkg
```

官网目录会得到：

```text
download/EZRWorker-<version>-arm64.pkg
download/EZRWorker-<version>-x64.pkg
download/EZRWorker-<version>.pkg
download/EZRWorker-latest.pkg
download/EZRWorker-latest-x64.pkg
```

其中无架构后缀的历史命名默认指向 `arm64` 包。

## Intel 与 M 芯片分发说明

| 用户机器 | 推荐安装包 |
| --- | --- |
| M1/M2/M3/M4 等 Apple Silicon | `EZRWorker-<version>-arm64.pkg` |
| Intel Mac | `EZRWorker-<version>-x64.pkg` |

确认当前机器架构：

```bash
uname -m
```

检查 App 主二进制架构：

```bash
lipo -info /Applications/EZRWorker.app/Contents/MacOS/EZRWorker
```

检查内置 Node.js 架构：

```bash
file /Applications/EZRWorker.app/Contents/Resources/node/bin/node
```

注意：`scripts/release.sh` 会把 `version.json` 的 `download_url` 写成 `arm64` 包，同时写入 `download_url_x64`。当前 App 侧更新逻辑读取的是 `download_url`；如果要让 Intel 用户在应用内自动拿到 x64 包，需要官网 API 根据请求架构返回不同的 `download_url`，或让 App 读取 `download_url_x64`。

## 常见问题

### `xcodebuild` 输出太少

默认会把详细日志写到 `build/logs/`。需要直接看完整输出时：

```bash
QUIET_XCODE=false make pkg
```

### 构建目录权限错误

如果之前用 sudo 生成过构建产物，可能需要修复 `build/` 归属：

```bash
sudo chown -R "$(id -un)":staff build
```

### Node.js 或 npm 下载失败

打包会访问 `nodejs.org` 和 npm registry。确认网络后重试：

```bash
make pkg
```

### 只想重新打包，不重新编译

已有 `build/export/EZRWorker.app` 时：

```bash
make pkg-skip-build
```

### 清理后重来

```bash
make clean
make pkg
```
