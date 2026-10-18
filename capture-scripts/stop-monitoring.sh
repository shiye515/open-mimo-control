#!/bin/bash
# stop-monitoring.sh — 停止 logcat 监控
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/../captures/logcat.pid"

if [ -f "$PID_FILE" ]; then
  PID=$(cat "$PID_FILE")
  kill "$PID" 2>/dev/null && echo "[+] 已停止 logcat (pid=$PID)" || echo "[!] 进程 $PID 不存在（可能已退出）"
  rm -f "$PID_FILE"
else
  echo "[!] 未找到 logcat.pid，尝试按命令名匹配："
  pkill -f "adb logcat -b main,system,events,crash" && echo "[+] 已停止" || echo "[!] 无运行中的 logcat"
fi
ls -la "$SCRIPT_DIR/../captures/" | grep logcat || true
