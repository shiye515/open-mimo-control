#!/bin/bash
# 变焦/命令抓包（用法与排错见同目录 README.md）
set -e
UDID="${1:?用法: bash start-zoom-capture.sh <iPhone的UDID>}"   # iPhone UDID（必填参数）
IFACE=rvi0

# 前置：手机重新插拔/解锁后远程网卡会失效，不存在时自动重新挂载
if ! ifconfig "$IFACE" >/dev/null 2>&1; then
  echo "rvi0 不存在，挂载远程抓包网卡（UDID=$UDID）…"
  rvictl -s "$UDID"
  sleep 1
fi

OUT="$(dirname "$0")/zoom-capture-$(date +%Y%m%d-%H%M%S).pcap"
echo "抓包输出: $OUT（Ctrl+C 停止）"
sudo tcpdump -i "$IFACE" -s 256 -w "$OUT" 'net 192.168.2.0/24'
