#!/usr/bin/env bash
# build-pkg.sh
# 构建 Release 并打包为可分发的 .pkg 安装包
#
# 用法：
#   bash scripts/build-pkg.sh              # 构建 + 打包
#   bash scripts/build-pkg.sh --skip-build # 跳过 xcodebuild，直接打包（用于重复打包）
#   PKG_ARCHS=x86_64 bash scripts/build-pkg.sh # 构建 Intel 包
#   PKG_ARCHS="arm64 x86_64" bash scripts/build-pkg.sh # 构建 Universal 包
#   bash scripts/build-pkg.sh --sync-api-version    # 同步 UPDATE_SITE_DIR 中的兼容更新清单（默认不同步）
#   SIGN_APP=true SIGN_PKG=true bash scripts/build-pkg.sh # 生成 Developer ID 签名 pkg
#   SIGN_APP=true SIGN_PKG=true NOTARIZE=true NOTARY_PROFILE=ezrworker-release bash scripts/build-pkg.sh
#
# 输出：dist/EZRWorker-<VERSION>-<ARCH>.pkg（如 -arm64 / -x64 / -universal）
#
# 依赖：xcodebuild / codesign / productsign / notarytool（按需）

set -euo pipefail
export LC_ALL=C  # 修复 Bash 3.2 UTF-8 编码问题

# ── 配置 ──────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

PROJECT_NAME="EZRWorker"
APP_NAME="EZRWorker"
BUNDLE_ID="ai.ezrworker.mac"
HELPER_LABEL="ai.ezrworker.mac.helper"
SUPERVISOR_LABEL="ai.ezrworker.mac.supervisor"
SCHEME="EZRWorker"
CONFIGURATION="Release"

BUILD_WORK_DIR="${BUILD_WORK_DIR:-$REPO_ROOT/build}"
ARCHIVE_PATH="${ARCHIVE_PATH:-$BUILD_WORK_DIR/${APP_NAME}.xcarchive}"
EXPORT_DIR="${EXPORT_DIR:-$BUILD_WORK_DIR/export}"
DIST_DIR="$REPO_ROOT/dist"
UPDATE_SITE_DIR="${UPDATE_SITE_DIR:-${WEBSITE_DIR:-}}"
UPDATE_BASE_URL="${UPDATE_BASE_URL:-https://assets.ezrpro.com/ezrworker/}"
UPDATE_MANIFEST_PATH="${UPDATE_MANIFEST_PATH:-/updates/latest.json}"
UPDATE_COMPAT_MANIFEST_PATH="${UPDATE_COMPAT_MANIFEST_PATH:-/api/version.json}"
UPDATE_DOWNLOAD_PATH="${UPDATE_DOWNLOAD_PATH:-/download}"
API_VERSION_JSON=""
if [ -n "$UPDATE_SITE_DIR" ]; then
  API_VERSION_JSON="$UPDATE_SITE_DIR$UPDATE_COMPAT_MANIFEST_PATH"
fi
SOURCE_INFO_PLIST="$REPO_ROOT/EZRWorkerApp/Info.plist"
BUILD_COUNTER_FILE="$REPO_ROOT/.build-version"
INITIAL_BUILD_NUMBER=500
BUILD_COUNTER_SCRIPT="$SCRIPT_DIR/build_counter.sh"

SKIP_BUILD=false
SYNC_API_VERSION=false
SIGN_APP="${SIGN_APP:-false}"
SIGN_PKG="${SIGN_PKG:-false}"
NOTARIZE="${NOTARIZE:-false}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:-9P6LY282WU}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-Developer ID Application: Shanghai Yike Information Technology Co.,Ltd. (9P6LY282WU)}"
PKG_SIGN_IDENTITY="${PKG_SIGN_IDENTITY:-Developer ID Installer: Shanghai Yike Information Technology Co.,Ltd. (9P6LY282WU)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-1h}"
NOTARY_S3_ACCELERATION="${NOTARY_S3_ACCELERATION:-false}"
NOTARY_LOCALE="${NOTARY_LOCALE:-en_US.UTF-8}"
RELEASE_VERSION="${RELEASE_VERSION:-}"
QUIET_XCODE="${QUIET_XCODE:-true}"
PKG_ARCHS_RAW="${PKG_ARCHS:-arm64}"
for arg in "$@"; do
  [[ "$arg" == "--skip-build" ]] && SKIP_BUILD=true
  [[ "$arg" == "--no-sync-api-version" ]] && SYNC_API_VERSION=false
  [[ "$arg" == "--sync-api-version" ]] && SYNC_API_VERSION=true
done

normalize_pkg_archs() {
  local raw="$1"
  local normalized
  normalized=$(echo "$raw" | tr ',' ' ' | xargs)
  case "$normalized" in
    arm64) echo "arm64" ;;
    x86_64|x64|intel) echo "x86_64" ;;
    "arm64 x86_64"|"x86_64 arm64"|universal|universal2) echo "arm64 x86_64" ;;
    *) fail "不支持的 PKG_ARCHS：$raw（支持：arm64 / x86_64 / arm64 x86_64）" ;;
  esac
}

PKG_ARCHS="$(normalize_pkg_archs "$PKG_ARCHS_RAW")"
case "$PKG_ARCHS" in
  arm64) PKG_ARCH_SUFFIX="-arm64" ;;
  x86_64) PKG_ARCH_SUFFIX="-x64" ;;
  "arm64 x86_64") PKG_ARCH_SUFFIX="-universal" ;;
  *) fail "内部错误：未知架构组合 $PKG_ARCHS" ;;
esac

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "缺少命令：$1"
}

assert_bool() {
  case "$2" in
    true|false) ;;
    *) fail "$1 必须是 true 或 false（当前：$2）" ;;
  esac
}

assert_bool "SIGN_APP" "$SIGN_APP"
assert_bool "SIGN_PKG" "$SIGN_PKG"
assert_bool "NOTARIZE" "$NOTARIZE"
assert_bool "NOTARY_S3_ACCELERATION" "$NOTARY_S3_ACCELERATION"
assert_bool "QUIET_XCODE" "$QUIET_XCODE"

validate_update_base_url() {
  local url="$1"
  [ -n "$url" ] || fail "UPDATE_BASE_URL 必填（例如：https://updates.example.com）"
  [[ "$url" == https://* ]] || fail "UPDATE_BASE_URL 必须使用 HTTPS：$url"
  [[ "$url" != *"clawdhome.app"* ]] || fail "UPDATE_BASE_URL 不能使用旧域名：$url"
}

join_url_path() {
  local base="${1%/}"
  local path="/${2#/}"
  echo "${base}${path}"
}

EFFECTIVE_APP_UPDATE_MANIFEST_URL="${APP_UPDATE_MANIFEST_URL:-$(join_url_path "$UPDATE_BASE_URL" "$UPDATE_MANIFEST_PATH")}"

if [ "$NOTARIZE" = true ] && [ "$SIGN_PKG" != true ]; then
  fail "NOTARIZE=true 时必须同时设置 SIGN_PKG=true"
fi

if [ "$NOTARIZE" = true ] && [ -z "$NOTARY_PROFILE" ]; then
  fail "NOTARIZE=true 时必须提供 NOTARY_PROFILE（xcrun notarytool store-credentials 的 profile 名）"
fi

print_notary_log_summary() {
  local log_file="$1"
  /usr/bin/python3 - "$log_file" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        data = json.load(fh)
except Exception:
    sys.exit(0)

issues = data.get("issues") or []
if not issues:
    sys.exit(0)

print("Apple 公证失败摘要：")
for issue in issues[:20]:
    message = issue.get("message", "Unknown issue")
    path = issue.get("path", "")
    arch = issue.get("architecture", "")
    suffix = f" ({arch})" if arch else ""
    print(f"- {message}{suffix}")
    if path:
        print(f"  {path}")
if len(issues) > 20:
    print(f"- 还有 {len(issues) - 20} 条，详见完整日志。")
PY
}

json_get() {
  local json_file="$1"
  local key="$2"
  /usr/bin/python3 - "$json_file" "$key" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        print(json.load(fh).get(sys.argv[2], ""))
except Exception:
    print("")
PY
}

run_notarytool_json() {
  local output_file="$1"
  local err_file="$2"
  shift 2

  rm -f "$output_file" "$err_file"
  set +e
  env LC_ALL="$NOTARY_LOCALE" LANG="$NOTARY_LOCALE" \
    xcrun notarytool "$@" --output-format json --no-progress > "$output_file" 2> "$err_file"
  local exit_code=$?
  set -e

  if [ "$exit_code" -ne 0 ]; then
    [ -s "$err_file" ] && cat "$err_file" >&2
    [ -s "$output_file" ] && cat "$output_file" >&2
    if [ "$exit_code" -eq 138 ]; then
      fail "notarytool 崩溃（Bus error 10）。输出：$output_file，错误：$err_file"
    fi
    fail "notarytool 执行失败（exit $exit_code）。输出：$output_file，错误：$err_file"
  fi
}

clean_filesystem_metadata() {
  local root="$1"
  [ -e "$root" ] || return 0
  find "$root" \( -name ".DS_Store" -o -name "._*" \) -print0 | xargs -0 rm -f
  xattr -cr "$root" 2>/dev/null || true
}

is_macho_file() {
  local path="$1"
  /usr/bin/file -b "$path" 2>/dev/null | grep -q "Mach-O"
}

sign_app_bundle_for_distribution() {
  [ "$SIGN_APP" = true ] || return 0
  require_cmd codesign

  local entitlements="$REPO_ROOT/EZRWorkerApp/EZRWorker.entitlements"
  local signed_count_file="$REPO_ROOT/build/logs/codesign-native-count.txt"
  mkdir -p "$(dirname "$signed_count_file")"
  echo "0" > "$signed_count_file"

  log "签名嵌入的原生运行时文件..."
  while IFS= read -r -d '' path; do
    if is_macho_file "$path"; then
      if ! codesign --force \
          --sign "$APP_SIGN_IDENTITY" \
          --timestamp \
          --options runtime \
          "$path"; then
        fail "原生文件签名失败：$path"
      fi
      echo $(( $(cat "$signed_count_file") + 1 )) > "$signed_count_file"
    fi
  done < <(find "$APP_BUNDLE" -type f -print0)
  ok "原生运行时文件签名完成（$(cat "$signed_count_file") 个 Mach-O 文件）"

  log "重签 app bundle..."
  if ! codesign --force \
      --sign "$APP_SIGN_IDENTITY" \
      --timestamp \
      --options runtime \
      --entitlements "$entitlements" \
      "$APP_BUNDLE"; then
    fail "app bundle 重签失败：$APP_BUNDLE"
  fi

  log "校验 app 签名..."
  codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  ok "app 签名校验通过"
}

read_source_plist() {
  local key="$1"
  /usr/libexec/PlistBuddy -c "Print :$key" "$SOURCE_INFO_PLIST" 2>/dev/null || true
}

compute_marketing_version() {
  if [ -n "$RELEASE_VERSION" ]; then
    echo "$RELEASE_VERSION"
    return
  fi

  local current_version next_version describe fallback_version
  current_version=$(bash "$SCRIPT_DIR/semver.sh" --current 2>/dev/null || true)
  next_version=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || true)
  describe=$(git describe --tags --match "v*" --long --dirty --always 2>/dev/null || true)
  fallback_version=$(read_source_plist "CFBundleShortVersionString")

  if [[ "$describe" =~ ^v([0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)-g([0-9a-f]+)(-dirty)?$ ]]; then
    if [ "${BASH_REMATCH[2]}" = "0" ] && [ -z "${BASH_REMATCH[4]:-}" ]; then
      echo "${BASH_REMATCH[1]}"
      return
    fi
    [ -n "$next_version" ] && echo "$next_version" && return
  fi

  [ -n "$current_version" ] && echo "$current_version" && return
  [ -n "$fallback_version" ] && echo "$fallback_version" && return
  echo "0.0.0"
}

compute_build_number() {
  if [ "$SKIP_BUILD" = false ]; then
    BUILD_COUNTER_FILE="$BUILD_COUNTER_FILE" \
      INITIAL_BUILD_NUMBER="$INITIAL_BUILD_NUMBER" \
      bash "$BUILD_COUNTER_SCRIPT" reserve
    return
  fi

  local reserved_build fallback_build
  reserved_build=$(BUILD_COUNTER_FILE="$BUILD_COUNTER_FILE" \
    INITIAL_BUILD_NUMBER="$INITIAL_BUILD_NUMBER" \
    bash "$BUILD_COUNTER_SCRIPT" current)
  fallback_build=$(read_source_plist "CFBundleVersion")
  [ "$reserved_build" -ge "$INITIAL_BUILD_NUMBER" ] && echo "$reserved_build" && return
  [ -n "$fallback_build" ] && echo "$fallback_build" && return
  echo "$INITIAL_BUILD_NUMBER"
}

BUILD_MARKETING_VERSION=$(compute_marketing_version)
BUILD_NUMBER=$(compute_build_number)

run_xcodebuild() {
  local log_file="$1"
  shift

  if [ "$QUIET_XCODE" = true ]; then
    mkdir -p "$(dirname "$log_file")"
    if ! xcodebuild "$@" >"$log_file" 2>&1; then
      echo "❌ xcodebuild 失败，日志：$log_file" >&2
      tail -n 120 "$log_file" >&2 || true
      exit 1
    fi
    ok "xcodebuild 完成（日志：$log_file）"
  else
    xcodebuild "$@"
  fi
}

# ── Step 1：构建 ──────────────────────────────────────────────────────────────

if [ "$SKIP_BUILD" = false ]; then
  log "构建 $APP_NAME..."
  mkdir -p "$BUILD_WORK_DIR"
  # 优先使用当前用户权限清理，避免 make pkg 触发 sudo 密码输入。
  # 若历史残留 root:wheel 文件导致删除失败，则提示一次性修复命令。
  if ! rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR" 2>/dev/null; then
    fail "无法清理构建目录（可能存在 root 权限残留）：$BUILD_WORK_DIR。请先执行：sudo chown -R \"$(id -un)\":staff \"$REPO_ROOT/build\""
  fi

  # 清除 DerivedData 增量缓存，确保 Release 从干净状态编译
  # （避免 Debug 残留中间产物影响 Release archive）
  XCODE_ARGS=(
    -project "$REPO_ROOT/${PROJECT_NAME}.xcodeproj"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
  )

  run_xcodebuild "$REPO_ROOT/build/logs/xcodebuild-clean.log" clean "${XCODE_ARGS[@]}" -destination "generic/platform=macOS" -quiet

  ARCHIVE_ARGS=(
    archive
    "${XCODE_ARGS[@]}"
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE_PATH"
    ARCHS="$PKG_ARCHS"
    ONLY_ACTIVE_ARCH=NO
  )

  if [ "$SIGN_APP" = true ]; then
    log "使用 Developer ID 签名 archive..."
    ARCHIVE_ARGS+=(
      DEVELOPMENT_TEAM="$APPLE_TEAM_ID"
      CODE_SIGN_STYLE=Manual
      CODE_SIGN_IDENTITY="$APP_SIGN_IDENTITY"
      EZRWORKER_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
      EZRWORKER_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
      CLAWDHOME_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
      CLAWDHOME_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
      MARKETING_VERSION="$BUILD_MARKETING_VERSION"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
      APP_UPDATE_MANIFEST_URL="$EFFECTIVE_APP_UPDATE_MANIFEST_URL"
      INFOPLIST_KEY_CFBundleShortVersionString="$BUILD_MARKETING_VERSION"
      INFOPLIST_KEY_CFBundleVersion="$BUILD_NUMBER"
      OTHER_CODE_SIGN_FLAGS="--timestamp"
    )
  else
    ARCHIVE_ARGS+=(
      CODE_SIGN_IDENTITY=-
      CODE_SIGNING_REQUIRED=NO
      CODE_SIGNING_ALLOWED=NO
      EZRWORKER_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
      EZRWORKER_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
      CLAWDHOME_MARKETING_VERSION_OVERRIDE="$BUILD_MARKETING_VERSION"
      CLAWDHOME_BUILD_NUMBER_OVERRIDE="$BUILD_NUMBER"
      MARKETING_VERSION="$BUILD_MARKETING_VERSION"
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
      APP_UPDATE_MANIFEST_URL="$EFFECTIVE_APP_UPDATE_MANIFEST_URL"
      INFOPLIST_KEY_CFBundleShortVersionString="$BUILD_MARKETING_VERSION"
      INFOPLIST_KEY_CFBundleVersion="$BUILD_NUMBER"
    )
  fi

  run_xcodebuild "$REPO_ROOT/build/logs/xcodebuild-archive.log" "${ARCHIVE_ARGS[@]}"

  # 从 archive 中取出 app（使用 ditto 保留符号链接，避免 Node/npm 运行时损坏）
  mkdir -p "$EXPORT_DIR"
  ditto --noextattr --noqtn "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$EXPORT_DIR/${APP_NAME}.app"
  ok "构建完成：$EXPORT_DIR/${APP_NAME}.app"
else
  log "跳过构建，使用已有：$EXPORT_DIR/${APP_NAME}.app"
  [ -d "$EXPORT_DIR/${APP_NAME}.app" ] || fail "未找到 $EXPORT_DIR/${APP_NAME}.app，请先构建"
fi

APP_BUNDLE="$EXPORT_DIR/${APP_NAME}.app"
APP_INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
[ -f "$APP_INFO_PLIST" ] || fail "未找到 $APP_INFO_PLIST"

# 统一版本来源：始终以“构建产物 app 的 Info.plist”为准
FULL_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_INFO_PLIST" 2>/dev/null || true)
[ -n "$FULL_VERSION" ] || fail "无法从构建产物读取 CFBundleShortVersionString"
APP_BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP_INFO_PLIST" 2>/dev/null || true)
[ -n "$APP_BUILD_NUMBER" ] || fail "无法从构建产物读取 CFBundleVersion"

if [ -n "$RELEASE_VERSION" ]; then
  PKG_VERSION_LABEL="${FULL_VERSION}${PKG_ARCH_SUFFIX}"
else
  PKG_VERSION_LABEL="${FULL_VERSION}-b${APP_BUILD_NUMBER}${PKG_ARCH_SUFFIX}"
fi

PKG_NAME="${APP_NAME}-${PKG_VERSION_LABEL}.pkg"
PKG_OUTPUT="$DIST_DIR/$PKG_NAME"

# ── Step 1.5：将 Node.js + OpenClaw 嵌入 app bundle ──────────────────────────

BUNDLE_RESOURCES="$APP_BUNDLE/Contents/Resources"
SKIP_BUNDLE_RUNTIME="${SKIP_BUNDLE_RUNTIME:-false}"

if [ "$SKIP_BUNDLE_RUNTIME" = false ]; then
  # 取 PKG_ARCHS 的第一个架构用于 Node.js 下载（universal 包用 arm64）
  BUNDLE_ARCH=$(echo "$PKG_ARCHS" | awk '{print $1}')
  log "嵌入 Node.js + OpenClaw 运行时 (${BUNDLE_ARCH})..."
  bash "$SCRIPT_DIR/bundle-runtime.sh" "$BUNDLE_RESOURCES" "$BUNDLE_ARCH"
else
  log "跳过运行时嵌入 (SKIP_BUNDLE_RUNTIME=true)"
  if [ ! -f "$BUNDLE_RESOURCES/node/bin/node" ]; then
    fail "SKIP_BUNDLE_RUNTIME=true 但 app bundle 中未找到 node"
  fi
fi

clean_filesystem_metadata "$APP_BUNDLE"
sign_app_bundle_for_distribution

# ── Step 2：准备 pkg 目录结构 ─────────────────────────────────────────────────

log "准备安装包目录结构..."

PKG_ROOT="$BUILD_WORK_DIR/pkg-root"
PKG_SCRIPTS="$BUILD_WORK_DIR/pkg-scripts"
rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

mkdir -p "$PKG_ROOT/Applications"
mkdir -p "$PKG_SCRIPTS"

# 拷贝 app（含嵌入的 Node.js + OpenClaw，保留符号链接）
ditto --noextattr --noqtn "$APP_BUNDLE" "$PKG_ROOT/Applications/${APP_NAME}.app"

SUPERVISOR_PLIST_IN_BUNDLE="$PKG_ROOT/Applications/${APP_NAME}.app/Contents/Library/LaunchAgents/${SUPERVISOR_LABEL}.plist"
SUPERVISOR_BINARY_IN_BUNDLE="$PKG_ROOT/Applications/${APP_NAME}.app/Contents/MacOS/EZRWorkerSupervisor"
if [ -f "$SUPERVISOR_PLIST_IN_BUNDLE" ] && [ -f "$SUPERVISOR_BINARY_IN_BUNDLE" ]; then
  mkdir -p "$PKG_ROOT/Library/LaunchAgents"
  cat > "$PKG_ROOT/Library/LaunchAgents/${SUPERVISOR_LABEL}.plist" << SUPERVISOR_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${SUPERVISOR_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/${APP_NAME}.app/Contents/MacOS/EZRWorkerSupervisor</string>
    </array>
    <key>MachServices</key>
    <dict>
        <key>${SUPERVISOR_LABEL}</key>
        <true/>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
</dict>
</plist>
SUPERVISOR_PLIST
  chmod 644 "$PKG_ROOT/Library/LaunchAgents/${SUPERVISOR_LABEL}.plist"
  log "Supervisor LaunchAgent 已生成"
else
  log "未找到 Supervisor LaunchAgent，跳过 LaunchAgent 部署"
fi

ok "目录结构准备完成"

# ── Step 3：preinstall 脚本（停止旧版本）─────────────────────────────────────

cat > "$PKG_SCRIPTS/preinstall" << PREINSTALL
#!/usr/bin/env bash
# 关闭 app
osascript -e 'tell application "${APP_NAME}" to quit' 2>/dev/null || true
# 停止并移除旧 Helper daemon（新主线不再安装）
if launchctl print "system/${HELPER_LABEL}" &>/dev/null 2>&1; then
  launchctl bootout "system/${HELPER_LABEL}" 2>/dev/null || true
fi
rm -f "/Library/LaunchDaemons/${HELPER_LABEL}.plist"
rm -f "/Library/PrivilegedHelperTools/${HELPER_LABEL}"
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
if [ -n "\$CONSOLE_USER" ] && [ "\$CONSOLE_USER" != "root" ]; then
  CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")
  if [ -n "\$CONSOLE_UID" ]; then
    launchctl bootout "gui/\${CONSOLE_UID}" "/Library/LaunchAgents/${SUPERVISOR_LABEL}.plist" 2>/dev/null || true
  fi
fi
sleep 1
exit 0
PREINSTALL

# ── Step 4：postinstall 脚本 ──────────────────────────────────────────────────

cat > "$PKG_SCRIPTS/postinstall" << POSTINSTALL
#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/Applications/${APP_NAME}.app"
SUPERVISOR_PLIST="/Library/LaunchAgents/${SUPERVISOR_LABEL}.plist"

# 解除 app 隔离（允许未签名 app 运行，无弹框）
xattr -cr "\$APP_DIR" 2>/dev/null || true

# ── 为当前登录用户安装并拉起 supervisor LaunchAgent ──
CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null || echo "")
if [ -n "\$CONSOLE_USER" ] && [ "\$CONSOLE_USER" != "root" ]; then
  CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null || echo "")
  if [ -n "\$CONSOLE_UID" ] && [ -f "\$SUPERVISOR_PLIST" ]; then
    chown root:wheel "\$SUPERVISOR_PLIST"
    chmod 644 "\$SUPERVISOR_PLIST"
    launchctl bootstrap "gui/\$CONSOLE_UID" "\$SUPERVISOR_PLIST" 2>/dev/null || true
    launchctl enable "gui/\$CONSOLE_UID/${SUPERVISOR_LABEL}" 2>/dev/null || true
    launchctl kickstart -k "gui/\$CONSOLE_UID/${SUPERVISOR_LABEL}" 2>/dev/null || true
    echo "✅ EZRWorkerSupervisor LaunchAgent 已为当前用户安装"
  fi
fi

echo "${APP_NAME} 安装完成"
exit 0
POSTINSTALL

chmod +x "$PKG_SCRIPTS/preinstall" "$PKG_SCRIPTS/postinstall"
ok "安装脚本生成完成"

clean_filesystem_metadata "$PKG_ROOT"
if [ "$SIGN_APP" = true ]; then
  log "校验打包目录中的 app 签名..."
  codesign --verify --deep --strict --verbose=2 "$PKG_ROOT/Applications/${APP_NAME}.app"
  ok "打包目录 app 签名校验通过"
fi

# ── Step 5：打包 pkg ──────────────────────────────────────────────────────────

log "生成 $PKG_NAME..."
mkdir -p "$DIST_DIR"

UNSIGNED_PKG_OUTPUT="$PKG_OUTPUT"
if [ "$SIGN_PKG" = true ]; then
  UNSIGNED_PKG_OUTPUT="$DIST_DIR/${APP_NAME}-${FULL_VERSION}${PKG_ARCH_SUFFIX}.unsigned.pkg"
  rm -f "$UNSIGNED_PKG_OUTPUT" "$PKG_OUTPUT"
fi

COPYFILE_DISABLE=1 pkgbuild \
  --root "$PKG_ROOT" \
  --scripts "$PKG_SCRIPTS" \
  --identifier "$BUNDLE_ID" \
  --version "$FULL_VERSION" \
  --install-location "/" \
  "$UNSIGNED_PKG_OUTPUT"

if [ "$SIGN_PKG" = true ]; then
  require_cmd productsign
  require_cmd pkgutil
  log "使用 Developer ID Installer 签名 pkg..."
  productsign \
    --sign "$PKG_SIGN_IDENTITY" \
    --timestamp \
    "$UNSIGNED_PKG_OUTPUT" \
    "$PKG_OUTPUT"
  pkgutil --check-signature "$PKG_OUTPUT"
  rm -f "$UNSIGNED_PKG_OUTPUT"
  ok "pkg 签名校验通过"
fi

if [ "$NOTARIZE" = true ]; then
  require_cmd xcrun
  require_cmd stapler
  require_cmd spctl
  log "提交 pkg 公证..."
  NOTARY_SUBMIT_JSON="$REPO_ROOT/build/logs/notary-submit-${PKG_VERSION_LABEL}.json"
  NOTARY_SUBMIT_ERR="$REPO_ROOT/build/logs/notary-submit-${PKG_VERSION_LABEL}.err"
  NOTARY_WAIT_JSON="$REPO_ROOT/build/logs/notary-wait-${PKG_VERSION_LABEL}.json"
  NOTARY_WAIT_ERR="$REPO_ROOT/build/logs/notary-wait-${PKG_VERSION_LABEL}.err"
  NOTARY_LOG_JSON="$REPO_ROOT/build/logs/notary-log-${PKG_VERSION_LABEL}.json"
  mkdir -p "$REPO_ROOT/build/logs"

  NOTARY_S3_ARGS=(--no-s3-acceleration)
  if [ "$NOTARY_S3_ACCELERATION" = true ]; then
    NOTARY_S3_ARGS=(--s3-acceleration)
  fi

  run_notarytool_json "$NOTARY_SUBMIT_JSON" "$NOTARY_SUBMIT_ERR" \
    submit "$PKG_OUTPUT" \
    --keychain-profile "$NOTARY_PROFILE" \
    "${NOTARY_S3_ARGS[@]}"

  NOTARY_ID=$(json_get "$NOTARY_SUBMIT_JSON" "id")
  [ -n "$NOTARY_ID" ] || fail "pkg 公证提交后未返回 submission id：$NOTARY_SUBMIT_JSON"

  log "等待公证结果：$NOTARY_ID"
  run_notarytool_json "$NOTARY_WAIT_JSON" "$NOTARY_WAIT_ERR" \
    wait "$NOTARY_ID" \
    --keychain-profile "$NOTARY_PROFILE" \
    --timeout "$NOTARY_TIMEOUT"

  NOTARY_STATUS=$(json_get "$NOTARY_WAIT_JSON" "status")
  if [ "$NOTARY_STATUS" != "Accepted" ]; then
    warn "pkg 公证未通过（${NOTARY_STATUS:-未知状态}）"
    if [ -n "$NOTARY_ID" ]; then
      env LC_ALL="$NOTARY_LOCALE" LANG="$NOTARY_LOCALE" \
        xcrun notarytool log "$NOTARY_ID" \
        --keychain-profile "$NOTARY_PROFILE" > "$NOTARY_LOG_JSON" 2>/dev/null || true
      print_notary_log_summary "$NOTARY_LOG_JSON"
      fail "pkg 公证失败，完整日志：$NOTARY_LOG_JSON"
    fi
    fail "pkg 公证失败，提交结果：$NOTARY_SUBMIT_JSON"
  fi
  log "写入 notarization ticket..."
  xcrun stapler staple "$PKG_OUTPUT"
  xcrun stapler validate "$PKG_OUTPUT"
  log "校验 Gatekeeper 对已公证 pkg 的放行状态..."
  spctl --assess --type install --verbose=2 "$PKG_OUTPUT"
  ok "pkg 公证完成"
fi

PKG_SHA256=$(shasum -a 256 "$PKG_OUTPUT" | awk '{print $1}')
printf "%s  %s\n" "$PKG_SHA256" "$(basename "$PKG_OUTPUT")" > "$PKG_OUTPUT.sha256"
chmod 644 "$PKG_OUTPUT.sha256"
ok "安装包已生成：$PKG_OUTPUT"
ok "SHA256：$PKG_OUTPUT.sha256"

if [ "$SYNC_API_VERSION" = true ]; then
  validate_update_base_url "$UPDATE_BASE_URL"
  if [ -z "$UPDATE_SITE_DIR" ]; then
    fail "使用 --sync-api-version 时必须设置 UPDATE_SITE_DIR"
  fi

  DOWNLOAD_URL="$(join_url_path "$UPDATE_BASE_URL" "$UPDATE_DOWNLOAD_PATH/${PKG_NAME}")"
  MANIFEST_ARCH_KEY="$PKG_ARCHS"
  if [ "$MANIFEST_ARCH_KEY" = "arm64 x86_64" ]; then
    MANIFEST_ARCH_KEY="universal"
  fi
  log "同步 $API_VERSION_JSON 版本号 -> $FULL_VERSION"
  mkdir -p "$(dirname "$API_VERSION_JSON")"
  TMP_API_JSON="$(mktemp)"
  /usr/bin/python3 - "$API_VERSION_JSON" "$TMP_API_JSON" "$FULL_VERSION" "$APP_BUILD_NUMBER" "$MANIFEST_ARCH_KEY" "$DOWNLOAD_URL" "$PKG_SHA256" <<'PY'
import json
import os
import sys

src, dst, version, build, arch, download_url, sha256 = sys.argv[1:]
if os.path.exists(src):
    with open(src, "r", encoding="utf-8") as fh:
        data = json.load(fh)
else:
    data = {}

data["version"] = version
data["build"] = build
if arch == "x86_64":
    data["download_url_x64"] = download_url
else:
    data["download_url"] = download_url

packages = data.setdefault("packages", {})
packages[arch] = {
    "url": download_url,
    "sha256": sha256,
}

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
  mv "$TMP_API_JSON" "$API_VERSION_JSON"
  chmod 644 "$API_VERSION_JSON"
  ok "已同步：$API_VERSION_JSON"
fi

# ── Step 6：清理临时目录 ──────────────────────────────────────────────────────

rm -rf "$PKG_ROOT" "$PKG_SCRIPTS"

# ── 完成摘要 ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  📦 ${PKG_NAME}"
echo "  App 版本：${FULL_VERSION}"
echo "  Build：${APP_BUILD_NUMBER}"
echo "  架构：${PKG_ARCHS}"
echo "  包版本：${PKG_VERSION_LABEL}"
echo "  大小：$(du -sh "$PKG_OUTPUT" | cut -f1)"
echo "  SHA256：$PKG_SHA256"
echo "  路径：$PKG_OUTPUT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "安装测试："
echo "  sudo installer -pkg \"$PKG_OUTPUT\" -target /"
echo ""
echo "发布到 GitHub："
echo "  gh release create v${FULL_VERSION} \"$PKG_OUTPUT\" --title \"EZRWorker ${FULL_VERSION}\""
echo ""
