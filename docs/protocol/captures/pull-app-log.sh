#!/bin/bash
# 拉取 App 诊断日志（沙盒 Documents/diag.log）到 Mac 本地，便于离线分析。
# 用法：bash pull-app-log.sh [输出目录]（默认 docs/protocol/captures/app-logs）
set -e
UDID="${UDID:-00008020-001A59210104002E}"   # 可用环境变量 UDID 覆盖设备
BUNDLE="win.service-ai.OpenMimoControl"
DEST="${1:-$(dirname "$0")/app-logs}"

mkdir -p "$DEST"
TS=$(date +%Y%m%d-%H%M%S)
OUT="$DEST/diag-$TS.log"

xcrun devicectl device copy from --device "$UDID" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" \
  --source Documents/diag.log --destination "$OUT" 2>&1 | grep -v "^$" || true

if [ -f "$OUT" ]; then
  echo "==> 拉取成功: $OUT ($(wc -l < "$OUT") 行)"
  echo "==> 最新 20 行预览:"
  tail -20 "$OUT"
else
  echo "✗ 拉取失败：确认设备 USB 连接、App 已安装且启动过（diag.log 由首次诊断写入）" >&2
  exit 1
fi
