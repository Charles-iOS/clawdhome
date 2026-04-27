#!/usr/bin/env bash
# release.sh — EZRWorker 一键发布脚本
#
# 用法：
#   bash scripts/release.sh              # 完整发布流程
#   bash scripts/release.sh --dry-run    # 仅预览，不执行任何写操作
#   bash scripts/release.sh --skip-push  # 跳过 git push 和 GitHub Release
#
# 流程：
#   1. semver.sh 计算下一版本号
#   2. 读取 release-notes/vX.Y.Z.{zh,en}.md
#   3. 更新 CHANGELOG.zh.md / CHANGELOG.en.md
#   4. git commit + tag
#   5. build-pkg.sh 构建打包
#   6. 同步 version.json release_notes / release_notes_en
#   7. git push + gh release create
#
# 兼容 macOS bash 3.2，需要 gh CLI。

set -euo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

# ── 配置 ──────────────────────────────────────────────────────────────────────

UPDATE_BASE_URL="${UPDATE_BASE_URL:-https://assets.ezrpro.com/ezrworker/}"
UPDATE_SITE_DIR="${UPDATE_SITE_DIR:-${WEBSITE_DIR:-}}"
UPDATE_MANIFEST_PATH="${UPDATE_MANIFEST_PATH:-/updates/latest.json}"
UPDATE_COMPAT_MANIFEST_PATH="${UPDATE_COMPAT_MANIFEST_PATH:-/api/version.json}"
UPDATE_DOWNLOAD_PATH="${UPDATE_DOWNLOAD_PATH:-/download}"
MIN_APP_VERSION="${MIN_APP_VERSION:-}"
MANIFEST_JSON=""
COMPAT_MANIFEST_JSON=""
if [ -n "$UPDATE_SITE_DIR" ]; then
  MANIFEST_JSON="$UPDATE_SITE_DIR$UPDATE_MANIFEST_PATH"
  COMPAT_MANIFEST_JSON="$UPDATE_SITE_DIR$UPDATE_COMPAT_MANIFEST_PATH"
fi
NOTES_DIR="${NOTES_DIR:-$REPO_ROOT/release-notes}"
INFO_PLIST="$REPO_ROOT/EZRWorkerApp/Info.plist"
PLIST_BUDDY="/usr/libexec/PlistBuddy"

DRY_RUN=false
SKIP_PUSH=false
for arg in "$@"; do
  case "$arg" in
    --dry-run)    DRY_RUN=true ;;
    --skip-push)  SKIP_PUSH=true ;;
  esac
done

# ── 工具函数 ──────────────────────────────────────────────────────────────────

log()  { echo "▶ $*"; }
ok()   { echo "✅ $*"; }
warn() { echo "⚠️  $*"; }
fail() { echo "❌ $*" >&2; exit 1; }

fail_missing_notes() {
  local lang_label="$1"
  local notes_file="$2"
  cat >&2 <<EOF
❌ 缺少${lang_label} release notes：$notes_file

请先按下面步骤处理：
  1. 运行：make release-notes-draft
  2. 编辑并确认：$notes_file
  3. 预检查：make release-dry-run
  4. 正式发布：make release
EOF
  exit 1
}

set_plist_value() {
  local key="$1"
  local value="$2"
  "$PLIST_BUDDY" -c "Set :$key $value" "$INFO_PLIST" >/dev/null 2>&1 || \
    "$PLIST_BUDDY" -c "Add :$key string $value" "$INFO_PLIST" >/dev/null 2>&1
}

render_changelog_preview() {
  local lang="$1"
  local notes_file="$2"
  if [ -f "$notes_file" ]; then
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang "$lang" --version "$NEXT_VERSION" --notes-file "$notes_file"
  else
    bash "$SCRIPT_DIR/changelog.sh" --stdout --lang "$lang" --version "$NEXT_VERSION"
  fi
}

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

read_existing_min_version() {
  local manifest="$1"
  [ -f "$manifest" ] || return 0
  /usr/bin/python3 - "$manifest" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        value = json.load(fh).get("min_version", "")
except Exception:
    value = ""
print(value or "")
PY
}

# ── 前置检查 ──────────────────────────────────────────────────────────────────

if [ "$DRY_RUN" = false ]; then
  # 检查工作区是否干净（允许文档草稿目录未跟踪）
  DIRTY=$(git status --porcelain 2>/dev/null | grep -v "^?? scripts/" | grep -v "^?? release-notes/" || true)
  if [ -n "$DIRTY" ]; then
    echo "$DIRTY"
    fail "工作区有未提交的更改，请先 commit 或 stash"
  fi
fi

# 检查 gh CLI
if [ "$DRY_RUN" = false ] && [ "$SKIP_PUSH" = false ] && ! command -v gh &>/dev/null; then
  fail "需要 GitHub CLI（gh）。安装：brew install gh && gh auth login"
fi

# 检查 gh 登录状态
if [ "$DRY_RUN" = false ] && [ "$SKIP_PUSH" = false ] && ! gh auth status &>/dev/null 2>&1; then
  fail "gh 未登录。请运行：gh auth login"
fi

if [ "$DRY_RUN" = false ]; then
  validate_update_base_url "$UPDATE_BASE_URL"
  if [ -z "$UPDATE_SITE_DIR" ]; then
    warn "未设置 UPDATE_SITE_DIR，将不会写入静态更新清单"
  fi
fi

# ── Step 1：计算版本号 ────────────────────────────────────────────────────────

CURRENT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" --current 2>/dev/null || echo "")
NEXT_VERSION=$(bash "$SCRIPT_DIR/semver.sh" 2>/dev/null || echo "")
BUMP_TYPE=$(bash "$SCRIPT_DIR/semver.sh" --bump-type 2>/dev/null || echo "none")

[ -n "$NEXT_VERSION" ] || fail "无法计算下一版本号"

BUMP_LABEL="$BUMP_TYPE bump"
if [ "$BUMP_TYPE" = "initial" ]; then
  BUMP_LABEL="初始发布"
fi

log "当前版本：${CURRENT_VERSION:-无 tag}"
log "下一版本：v${NEXT_VERSION}（${BUMP_LABEL}）"

ZH_NOTES_FILE="$NOTES_DIR/v${NEXT_VERSION}.zh.md"
EN_NOTES_FILE="$NOTES_DIR/v${NEXT_VERSION}.en.md"

if [ "$BUMP_TYPE" = "none" ]; then
  warn "自上次 tag 以来没有 feat/fix commit，将执行 patch bump"
fi

if [ "$DRY_RUN" = true ]; then
  if [ ! -f "$ZH_NOTES_FILE" ] || [ ! -f "$EN_NOTES_FILE" ]; then
    warn "未找到正式 release notes，以下预览使用 git log 自动生成的草稿"
    [ -f "$ZH_NOTES_FILE" ] || warn "待补中文文件：$ZH_NOTES_FILE"
    [ -f "$EN_NOTES_FILE" ] || warn "待补英文文件：$EN_NOTES_FILE"
    warn "可先运行：make release-notes-draft"
  fi
  echo ""
  log "=== DRY RUN 模式 — 以下为预览 ==="
  echo ""
  log "将写入的中文 CHANGELOG："
  render_changelog_preview zh "$ZH_NOTES_FILE"
  echo ""
  log "将写入的英文 CHANGELOG："
  render_changelog_preview en "$EN_NOTES_FILE"
  echo ""
  PREVIEW_UPDATE_BASE_URL="$UPDATE_BASE_URL"
  if [ -z "$PREVIEW_UPDATE_BASE_URL" ]; then
    PREVIEW_UPDATE_BASE_URL="https://updates.example.invalid"
    warn "未设置 UPDATE_BASE_URL，以下更新清单 URL 使用占位域名；正式发布必须设置 HTTPS 更新源"
  elif [[ "$PREVIEW_UPDATE_BASE_URL" != https://* ]]; then
    warn "UPDATE_BASE_URL 不是 HTTPS，正式发布会失败：$PREVIEW_UPDATE_BASE_URL"
  elif [[ "$PREVIEW_UPDATE_BASE_URL" == *"clawdhome.app"* ]]; then
    warn "UPDATE_BASE_URL 使用旧域名，正式发布会失败：$PREVIEW_UPDATE_BASE_URL"
  fi

  PREVIEW_DOWNLOAD_URL_ARM64="$(join_url_path "$PREVIEW_UPDATE_BASE_URL" "$UPDATE_DOWNLOAD_PATH/EZRWorker-${NEXT_VERSION}-arm64.pkg")"
  PREVIEW_DOWNLOAD_URL_X64="$(join_url_path "$PREVIEW_UPDATE_BASE_URL" "$UPDATE_DOWNLOAD_PATH/EZRWorker-${NEXT_VERSION}-x64.pkg")"
  PREVIEW_MANIFEST_URL="$(join_url_path "$PREVIEW_UPDATE_BASE_URL" "$UPDATE_MANIFEST_PATH")"
  PREVIEW_MIN_VERSION="$MIN_APP_VERSION"
  if [ -z "$PREVIEW_MIN_VERSION" ] && [ -n "$MANIFEST_JSON" ]; then
    PREVIEW_MIN_VERSION="$(read_existing_min_version "$MANIFEST_JSON")"
  fi
  echo ""
  log "将生成的静态更新清单预览："
  echo "  Manifest URL：$PREVIEW_MANIFEST_URL"
  echo "  输出文件：${MANIFEST_JSON:-未设置 UPDATE_SITE_DIR，正式发布时不写本地清单}"
  echo "  兼容文件：${COMPAT_MANIFEST_JSON:-未设置 UPDATE_SITE_DIR，正式发布时不写兼容清单}"
  cat <<EOF
{
  "version": "${NEXT_VERSION}",
  "build": "<build number>",
  "min_version": "${PREVIEW_MIN_VERSION}",
  "channel": "stable",
  "release_date": "<UTC ISO8601>",
  "download_url": "${PREVIEW_DOWNLOAD_URL_ARM64}",
  "download_url_x64": "${PREVIEW_DOWNLOAD_URL_X64}",
  "packages": {
    "arm64": {
      "url": "${PREVIEW_DOWNLOAD_URL_ARM64}",
      "sha256": "<arm64 sha256>"
    },
    "x86_64": {
      "url": "${PREVIEW_DOWNLOAD_URL_X64}",
      "sha256": "<x64 sha256>"
    }
  }
}
EOF
  echo ""
  log "将执行的操作："
  echo "  1. 更新 EZRWorkerApp/Info.plist -> ${NEXT_VERSION}"
  echo "  2. 更新 CHANGELOG.zh.md / CHANGELOG.en.md"
  echo "  3. git commit -m \"chore(release): v${NEXT_VERSION}\""
  echo "  4. git tag -a v${NEXT_VERSION}"
  if [ "${NOTARIZE:-false}" = "true" ]; then
    echo "  5. xcodebuild + pkgbuild/productsign + notarize →"
    echo "     dist/EZRWorker-${NEXT_VERSION}-arm64.pkg"
    echo "     dist/EZRWorker-${NEXT_VERSION}-x64.pkg"
  else
    echo "  5. xcodebuild + pkgbuild/productsign →"
    echo "     dist/EZRWorker-${NEXT_VERSION}-arm64.pkg"
    echo "     dist/EZRWorker-${NEXT_VERSION}-x64.pkg"
  fi
  echo "  6. 生成 updates/latest.json（可选同步 api/version.json 兼容路径）"
  echo "  7. git push && git push --tags"
  echo "  8. gh release create v${NEXT_VERSION}"
  exit 0
fi

[ -f "$ZH_NOTES_FILE" ] || fail_missing_notes "中文" "$ZH_NOTES_FILE"
[ -f "$EN_NOTES_FILE" ] || fail_missing_notes "英文" "$EN_NOTES_FILE"

# ── Step 2：生成 CHANGELOG ────────────────────────────────────────────────────

log "更新中英文 CHANGELOG..."
bash "$SCRIPT_DIR/changelog.sh" --write --lang zh --version "$NEXT_VERSION" --notes-file "$ZH_NOTES_FILE"
bash "$SCRIPT_DIR/changelog.sh" --write --lang en --version "$NEXT_VERSION" --notes-file "$EN_NOTES_FILE"

# GitHub Release 和应用内更新使用同一份 release-notes 源
GITHUB_RELEASE_NOTES=$(bash "$SCRIPT_DIR/release_notes.sh" --github --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
API_RELEASE_NOTES_ZH=$(bash "$SCRIPT_DIR/release_notes.sh" --api zh --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
API_RELEASE_NOTES_EN=$(bash "$SCRIPT_DIR/release_notes.sh" --api en --version "$NEXT_VERSION" --notes-dir "$NOTES_DIR")
MANIFEST_MIN_VERSION="$MIN_APP_VERSION"
if [ -z "$MANIFEST_MIN_VERSION" ] && [ -n "$MANIFEST_JSON" ]; then
  MANIFEST_MIN_VERSION="$(read_existing_min_version "$MANIFEST_JSON")"
fi
APP_UPDATE_MANIFEST_URL="$(join_url_path "$UPDATE_BASE_URL" "$UPDATE_MANIFEST_PATH")"

# 统一 release 版本：正式发布时将 Info.plist 对齐到即将发布的 semver
log "更新 Info.plist 版本：${NEXT_VERSION}"
set_plist_value "CFBundleShortVersionString" "$NEXT_VERSION"

# ── Step 3：commit + tag ──────────────────────────────────────────────────────

log "提交 release commit..."
git add "$INFO_PLIST" CHANGELOG.zh.md CHANGELOG.en.md "$ZH_NOTES_FILE" "$EN_NOTES_FILE"
git commit -m "chore(release): v${NEXT_VERSION}"

log "打 tag v${NEXT_VERSION}..."
git tag -a "v${NEXT_VERSION}" -m "Release v${NEXT_VERSION}"

# 设置回滚点
RELEASE_COMMIT=$(git rev-parse HEAD)
NEED_ROLLBACK=true

# ── 回滚函数 ──────────────────────────────────────────────────────────────────

rollback() {
  if [ "$NEED_ROLLBACK" = true ]; then
    warn "发布失败，正在回滚..."
    git tag -d "v${NEXT_VERSION}" 2>/dev/null || true
    git reset --hard HEAD~1 2>/dev/null || true
    warn "已回滚：删除 tag v${NEXT_VERSION}，撤销 release commit"
  fi
}
trap rollback EXIT

# ── Step 4：构建打包 ──────────────────────────────────────────────────────────

build_release_pkg() {
  local archs="$1"
  log "构建打包（${archs}）..."
  APP_UPDATE_MANIFEST_URL="$APP_UPDATE_MANIFEST_URL" RELEASE_VERSION="$NEXT_VERSION" PKG_ARCHS="$archs" bash "$SCRIPT_DIR/build-pkg.sh" --no-sync-api-version
}

build_release_pkg "arm64"
build_release_pkg "x86_64"

PKG_ARM64="$REPO_ROOT/dist/EZRWorker-${NEXT_VERSION}-arm64.pkg"
PKG_X64="$REPO_ROOT/dist/EZRWorker-${NEXT_VERSION}-x64.pkg"
[ -f "$PKG_ARM64" ] || fail "未找到 $PKG_ARM64"
[ -f "$PKG_X64" ] || fail "未找到 $PKG_X64"

ok "打包完成：$PKG_ARM64"
ok "打包完成：$PKG_X64"

# ── Step 5：生成静态更新清单 ────────────────────────────────────────────────

PKG_ARM64_SHA256_FILE="$PKG_ARM64.sha256"
PKG_X64_SHA256_FILE="$PKG_X64.sha256"
[ -f "$PKG_ARM64_SHA256_FILE" ] || fail "未找到 $PKG_ARM64_SHA256_FILE"
[ -f "$PKG_X64_SHA256_FILE" ] || fail "未找到 $PKG_X64_SHA256_FILE"
PKG_ARM64_SHA256=$(awk '{print $1}' "$PKG_ARM64_SHA256_FILE")
PKG_X64_SHA256=$(awk '{print $1}' "$PKG_X64_SHA256_FILE")
APP_BUILD_NUMBER=$("$PLIST_BUDDY" -c "Print :CFBundleVersion" "$REPO_ROOT/build/export/EZRWorker.app/Contents/Info.plist" 2>/dev/null || echo "")
[ -n "$APP_BUILD_NUMBER" ] || fail "无法从构建产物读取 CFBundleVersion"
RELEASE_DATE_UTC=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

DOWNLOAD_URL_ARM64="$(join_url_path "$UPDATE_BASE_URL" "$UPDATE_DOWNLOAD_PATH/EZRWorker-${NEXT_VERSION}-arm64.pkg")"
DOWNLOAD_URL_X64="$(join_url_path "$UPDATE_BASE_URL" "$UPDATE_DOWNLOAD_PATH/EZRWorker-${NEXT_VERSION}-x64.pkg")"

if [ -n "$UPDATE_SITE_DIR" ] && [ -d "$UPDATE_SITE_DIR" ]; then
  log "生成静态更新清单..."
  mkdir -p "$(dirname "$MANIFEST_JSON")" "$(dirname "$COMPAT_MANIFEST_JSON")"

  TMP_JSON=$(mktemp)
  /usr/bin/python3 - "$TMP_JSON" "$NEXT_VERSION" "$APP_BUILD_NUMBER" "$MANIFEST_MIN_VERSION" "$RELEASE_DATE_UTC" "$DOWNLOAD_URL_ARM64" "$DOWNLOAD_URL_X64" "$PKG_ARM64_SHA256" "$PKG_X64_SHA256" "$API_RELEASE_NOTES_ZH" "$API_RELEASE_NOTES_EN" <<'PY'
import json
import sys

(
    dst,
    version,
    build,
    min_version,
    release_date,
    download_url_arm64,
    download_url_x64,
    sha256_arm64,
    sha256_x64,
    notes_zh,
    notes_en,
) = sys.argv[1:]

data = {
    "version": version,
    "build": build,
    "min_version": min_version,
    "channel": "stable",
    "release_date": release_date,
    "release_notes": notes_zh,
    "release_notes_en": notes_en,
    "download_url": download_url_arm64,
    "download_url_x64": download_url_x64,
    "packages": {
        "arm64": {
            "url": download_url_arm64,
            "sha256": sha256_arm64,
        },
        "x86_64": {
            "url": download_url_x64,
            "sha256": sha256_x64,
        },
    },
}

with open(dst, "w", encoding="utf-8") as fh:
    json.dump(data, fh, ensure_ascii=False, indent=2)
    fh.write("\n")
PY
  mv "$TMP_JSON" "$MANIFEST_JSON"
  cp "$MANIFEST_JSON" "$COMPAT_MANIFEST_JSON"
  chmod 644 "$MANIFEST_JSON" "$COMPAT_MANIFEST_JSON"

  UPDATE_DOWNLOAD_DIR="$UPDATE_SITE_DIR${UPDATE_DOWNLOAD_PATH%/}"
  mkdir -p "$UPDATE_DOWNLOAD_DIR"
  cp -f "$PKG_ARM64" "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-arm64.pkg"
  cp -f "$PKG_X64" "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-x64.pkg"
  cp -f "$PKG_ARM64_SHA256_FILE" "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-arm64.pkg.sha256"
  cp -f "$PKG_X64_SHA256_FILE" "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-x64.pkg.sha256"
  chmod 644 "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-arm64.pkg" \
    "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-x64.pkg" \
    "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-arm64.pkg.sha256" \
    "$UPDATE_DOWNLOAD_DIR/EZRWorker-${NEXT_VERSION}-x64.pkg.sha256"

  ok "静态更新清单已生成：$MANIFEST_JSON"
  ok "兼容更新清单已同步：$COMPAT_MANIFEST_JSON"
  ok "pkg 已复制到：$UPDATE_DOWNLOAD_DIR"
else
  warn "UPDATE_SITE_DIR 未设置或目录不存在，跳过静态更新清单写入"
fi

# ── Step 6：push + GitHub Release ────────────────────────────────────────────

if [ "$SKIP_PUSH" = false ]; then
  log "推送到远程仓库..."
  git push
  git push --tags

  log "创建 GitHub Release..."
  RELEASE_NOTES_FILE=$(mktemp)
  echo "$GITHUB_RELEASE_NOTES" > "$RELEASE_NOTES_FILE"

  gh release create "v${NEXT_VERSION}" "$PKG_ARM64" "$PKG_X64" "$PKG_ARM64_SHA256_FILE" "$PKG_X64_SHA256_FILE" \
    --title "EZRWorker ${NEXT_VERSION}" \
    --notes-file "$RELEASE_NOTES_FILE"

  rm -f "$RELEASE_NOTES_FILE"
  ok "GitHub Release v${NEXT_VERSION} 已创建"
else
  warn "跳过 push 和 GitHub Release（--skip-push）"
fi

# 发布成功，取消回滚
NEED_ROLLBACK=false
trap - EXIT

# ── 完成摘要 ──────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Release v${NEXT_VERSION} 完成"
echo ""
echo "  版本：${CURRENT_VERSION:-无} → ${NEXT_VERSION}"
echo "  Bump：${BUMP_TYPE}"
echo "  PKG (arm64)：$PKG_ARM64"
echo "  PKG (x64)：$PKG_X64"
echo "  Manifest URL：$(join_url_path "$UPDATE_BASE_URL" "$UPDATE_MANIFEST_PATH")"
echo "  Tag：v${NEXT_VERSION}"
if [ "$SKIP_PUSH" = false ]; then
  echo "  GitHub Release：已创建"
fi
if [ -f "$MANIFEST_JSON" ]; then
  echo "  latest.json：$MANIFEST_JSON"
fi
if [ -f "$COMPAT_MANIFEST_JSON" ]; then
  echo "  兼容 version.json：$COMPAT_MANIFEST_JSON"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
if [ -d "$UPDATE_SITE_DIR" ]; then
  echo "下一步（更新线上网站）："
  echo "  cd $UPDATE_SITE_DIR && make deploy"
fi
echo ""
