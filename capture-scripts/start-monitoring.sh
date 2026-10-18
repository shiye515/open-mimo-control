#!/bin/bash
# start-monitoring.sh — 启动后台 logcat 全量监控（抓包期间运行）
# 输出写入 captures/logcat-<时间戳>.log；结束后由 stop-monitoring.sh 停止
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$SCRIPT_DIR/../captures"
mkdir -p "$OUT_DIR"

LOGFILE="$OUT_DIR/logcat-$(date +%Y%m%d-%H%M%S).log"
nohup adb logcat -b main,system,events,crash -v threadtime > "$LOGFILE" 2>&1 &
PID=$!
echo "$PID" > "$OUT_DIR/logcat.pid"
echo "[+] logcat 已启动 (pid=$PID) → $LOGFILE"
