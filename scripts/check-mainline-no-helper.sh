#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

MAINLINE_PATHS=(
  EZRWorkerApp/EZRWorker/App
  EZRWorkerApp/EZRWorker/Models
  EZRWorkerApp/EZRWorker/Services
  EZRWorkerApp/EZRWorker/Views
)

PATTERN='\bHelperClient\b|\bShrimpPool\b|\bManagedUser\b|\bDaemonInstaller\b|\bEZRWorkerHelperProtocol\b|\bkHelperMachServiceName\b|\bGatewayHub\b'

matches="$(rg -n --glob '*.swift' "$PATTERN" "${MAINLINE_PATHS[@]}" || true)"

if [ -n "$matches" ]; then
  echo ""
  echo "❌ 检测到 helper 相关类型重新进入主线路径："
  echo ""
  printf '%s\n' "$matches"
  echo ""
  echo "允许保留的位置："
  echo "  - EZRWorkerHelper/"
  echo "  - Shared/HelperProtocol.swift"
  echo ""
  exit 1
fi

echo "✅ mainline helper guard passed"
