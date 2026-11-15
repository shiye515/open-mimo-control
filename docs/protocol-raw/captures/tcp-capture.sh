#!/bin/bash
# 一键抓包：自动获取 UDID → 自动挂载 rvi 网卡 → 自动开始抓包
# （可选参数传 UDID 覆盖自动检测；用法与排错见同目录 README.md）
set -e
IFACE=rvi0
DIR="$(cd "$(dirname "$0")" && pwd)"

# ---- 1. 确定 UDID：参数 > 自动检测（USB 连接的 iPhone，多台时交互选择）----
UDID="${1:-}"
if [ -z "$UDID" ]; then
  echo "==> 自动检测 USB 连接的 iPhone…"
  if command -v idevice_id >/dev/null 2>&1; then
    DETECTED="$(idevice_id -l 2>/dev/null || true)"
  fi
  if [ -z "${DETECTED:-}" ]; then
    # 兜底：Xcode 设备列表里的物理设备（按 UDID 格式提取，避免设备名含空格干扰）
    DETECTED="$(xcrun devicectl list devices 2>/dev/null | grep physical | grep -Eo '[0-9A-F]{8}-[0-9A-F]{12,16}' || true)"
  fi
  if [ -z "${DETECTED:-}" ]; then
    echo "✗ 未检测到 USB 连接的 iPhone：插上数据线、解锁并信任本机后重试，" \
         "或显式传参：bash tcp-capture.sh <UDID>" >&2
    exit 1
  fi
  COUNT="$(printf '%s\n' "$DETECTED" | grep -c .)"
  if [ "$COUNT" -gt 1 ]; then
    echo "检测到 $COUNT 台设备："
    i=1
    for d in $DETECTED; do
      echo "  $i) $d"
      i=$((i+1))
    done
    printf '选择 [1-%s]: ' "$COUNT"
    read -r CHOICE
    UDID="$(printf '%s\n' "$DETECTED" | sed -n "${CHOICE}p")"
  else
    UDID="$(printf '%s\n' "$DETECTED" | head -1)"
  fi
fi
echo "==> UDID: $UDID"

# ---- 2. 挂载 rvi 远程抓包网卡（手机重新插拔/解锁后失效会自动重挂，最多试 3 次）----
if ! ifconfig "$IFACE" >/dev/null 2>&1; then
  echo "==> $IFACE 不存在，挂载远程抓包网卡…"
  for i in 1 2 3; do
    rvictl -s "$UDID" >/dev/null 2>&1 || true
    if ifconfig "$IFACE" >/dev/null 2>&1; then
      break
    fi
    echo "   第 $i 次未就绪，解锁手机稍候重试…"
    sleep 2
  done
  if ! ifconfig "$IFACE" >/dev/null 2>&1; then
    echo "✗ 挂载失败：确认 USB 已连接、手机已解锁信任；" \
         "或手动执行 rvictl -s $UDID 后重跑" >&2
    exit 1
  fi
fi
echo "==> $IFACE 就绪"

# ---- 3. 自动开始抓包（Ctrl+C 停止；仅抓相机热点网段，边抓边落盘）----
OUT="$DIR/tcp-capture-$(date +%Y%m%d-%H%M%S).pcap"
echo "==> 抓包输出: $OUT（Ctrl+C 停止）"
trap 'echo; echo "==> 抓包已停止。"' INT
# -s 0 全包捕获：曾用 -s 256 截断主题推送帧（00/99 名字+数据段超 256B 被切），
# 6 个历史抓包因此丢失全部 cam_expo_param 等主题数据（2026-11-13 教训）
sudo tcpdump -i "$IFACE" -s 0 -U -w "$OUT" 'net 192.168.2.0/24' || true
echo "==> 完成。产物: $OUT（大小: $(du -h "$OUT" | cut -f1)）"
