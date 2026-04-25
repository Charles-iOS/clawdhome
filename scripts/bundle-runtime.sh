#!/usr/bin/env bash
# bundle-runtime.sh
# 下载 Node.js 并安装 OpenClaw，打包到 app bundle 的 Resources 目录
#
# 用法：
#   bash scripts/bundle-runtime.sh <app-resources-dir> [arch]
#   bash scripts/bundle-runtime.sh build/export/EZRWorker.app/Contents/Resources arm64
#
# 输出结构：
#   <resources>/node/bin/node
#   <resources>/node/bin/npm
#   <resources>/node/lib/node_modules/npm/...
#   <resources>/openclaw/lib/node_modules/openclaw/bin/openclaw.js
#   <resources>/openclaw/bin/openclaw -> ../lib/node_modules/openclaw/bin/openclaw.js

set -euo pipefail

RESOURCES_DIR="${1:?用法: bundle-runtime.sh <app-resources-dir> [arch]}"
TARGET_ARCH="${2:-$(uname -m)}"
HOST_ARCH="$(uname -m)"

# Node.js 版本（LTS）
NODE_VERSION="${NODE_VERSION:-22.22.2}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${SCRIPT_DIR}/../build/runtime-cache"

log()  { echo "▶ [bundle-runtime] $*"; }
ok()   { echo "✅ [bundle-runtime] $*"; }
fail() { echo "❌ [bundle-runtime] $*" >&2; exit 1; }

arch_to_node_arch() {
  case "$1" in
    arm64)  echo "arm64" ;;
    x86_64) echo "x64" ;;
    *)      fail "不支持的架构: $1" ;;
  esac
}

download_node() {
  local arch="$1" dest="$2"
  local node_arch
  node_arch=$(arch_to_node_arch "$arch")
  local tarball="node-v${NODE_VERSION}-darwin-${node_arch}.tar.gz"
  local url="https://nodejs.org/dist/v${NODE_VERSION}/${tarball}"
  local local_path="$CACHE_DIR/$tarball"

  if [ -f "$local_path" ]; then
    log "使用缓存: $local_path"
  else
    log "下载 Node.js v${NODE_VERSION} (${node_arch})..."
    curl -fSL -o "$local_path" "$url"
    ok "Node.js 下载完成"
  fi

  rm -rf "$dest"
  mkdir -p "$dest"
  tar xzf "$local_path" -C "$dest" --strip-components=1
  rm -rf "$dest/include" "$dest/share" "$dest/CHANGELOG.md" "$dest/LICENSE" "$dest/README.md"
}

mkdir -p "$CACHE_DIR"

# ── 1. 准备 Node.js ─────────────────────────────────────────────────────────

NODE_DIR="$RESOURCES_DIR/node"

if [ "$TARGET_ARCH" = "$HOST_ARCH" ]; then
  log "同架构构建 ($TARGET_ARCH)"
  download_node "$TARGET_ARCH" "$NODE_DIR"
  BUILD_NODE="$NODE_DIR/bin/node"
  BUILD_NPM="$NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
else
  log "交叉构建: host=$HOST_ARCH target=$TARGET_ARCH"
  HOST_NODE_DIR="$CACHE_DIR/node-host-${HOST_ARCH}"
  download_node "$HOST_ARCH" "$HOST_NODE_DIR"
  download_node "$TARGET_ARCH" "$NODE_DIR"
  BUILD_NODE="$HOST_NODE_DIR/bin/node"
  BUILD_NPM="$HOST_NODE_DIR/lib/node_modules/npm/bin/npm-cli.js"
fi

ok "Node.js 已安装到 $NODE_DIR ($(du -sh "$NODE_DIR" | cut -f1))"

# ── 2. 用 host Node.js 安装 OpenClaw ────────────────────────────────────────

OPENCLAW_PREFIX="$RESOURCES_DIR/openclaw"
rm -rf "$OPENCLAW_PREFIX"
mkdir -p "$OPENCLAW_PREFIX"

[ -x "$BUILD_NODE" ] || fail "构建用 Node 不存在: $BUILD_NODE"
[ -f "$BUILD_NPM" ]  || fail "npm-cli.js 不存在: $BUILD_NPM"

BUILD_NODE_DIR="$(cd "$(dirname "$BUILD_NODE")" && pwd)"
export PATH="$BUILD_NODE_DIR:$PATH"

log "安装 OpenClaw (npm install -g openclaw --ignore-scripts)..."
"$BUILD_NODE" "$BUILD_NPM" install -g \
  --prefix "$OPENCLAW_PREFIX" \
  --loglevel warn \
  --ignore-scripts \
  openclaw@latest

BUILD_NODE_ABS="$BUILD_NODE_DIR/node"

log "执行 OpenClaw postinstall..."
OPENCLAW_PKG_DIR="$OPENCLAW_PREFIX/lib/node_modules/openclaw"
if [ -f "$OPENCLAW_PKG_DIR/scripts/postinstall-bundled-plugins.mjs" ]; then
  (cd "$OPENCLAW_PKG_DIR" && "$BUILD_NODE_ABS" scripts/postinstall-bundled-plugins.mjs) || {
    log "postinstall 脚本失败（非致命，继续）"
  }
fi

OPENCLAW_ENTRY="$OPENCLAW_PREFIX/lib/node_modules/openclaw/openclaw.mjs"
[ -f "$OPENCLAW_ENTRY" ] || fail "OpenClaw 入口不存在: $OPENCLAW_ENTRY"

ok "OpenClaw 已安装到 $OPENCLAW_PREFIX ($(du -sh "$OPENCLAW_PREFIX" | cut -f1))"

# ── 4. 验证 ──────────────────────────────────────────────────────────────────

log "验证安装..."
OPENCLAW_VERSION=$("$BUILD_NODE" "$OPENCLAW_ENTRY" --version 2>/dev/null || echo "未知")
NODE_ACTUAL_VERSION=$("$BUILD_NODE" --version 2>/dev/null || echo "未知")

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Node.js:  ${NODE_ACTUAL_VERSION}"
echo "  OpenClaw: ${OPENCLAW_VERSION}"
echo "  Node 路径: ${NODE_DIR}/bin/node"
echo "  OpenClaw 入口: ${OPENCLAW_ENTRY}"
echo "  总大小:   $(du -sh "$RESOURCES_DIR/node" "$RESOURCES_DIR/openclaw" | tail -1 | cut -f1 || du -sh "$RESOURCES_DIR" | cut -f1)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

ok "运行时 bundle 完成"
