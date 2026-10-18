#!/bin/bash
# pull-pcapdroid.sh — WiFi 抓包收尾：从手机拉取 PCAPdroid 导出的 pcap
#
# 前提：PCAPdroid 已在手机上开始抓包（建议 Target apps 过滤为 mimo.sz），
#   且「PCAP dump」已保存到 Download 目录。操作完成后运行本脚本。
#
# 用法：./pull-pcapdroid.sh [输出目录]   （默认 ../captures）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/../captures}"
mkdir -p "$OUT_DIR"

PCAP_DIR_ON_DEVICE="/sdcard/Download"

echo "[*] 查找手机 $PCAP_DIR_ON_DEVICE 中的 pcap 文件..."
FILES=$(adb shell ls "$PCAP_DIR_ON_DEVICE" 2>/dev/null | grep -i '\.pcap' || true)

if [ -z "$FILES" ]; then
  echo "[!] 未找到 pcap 文件。手机 Download 目录当前内容："
  adb shell ls -la "$PCAP_DIR_ON_DEVICE" 2>/dev/null | head -20 || true
  echo "    提示：确认 PCAPdroid 抓包界面已点「结束」且选择保存到 Download。"
  exit 1
fi

echo "$FILES" | while read -r f; do
  [ -z "$f" ] && continue
  echo "[*] 拉取: $f"
  adb pull "$PCAP_DIR_ON_DEVICE/$f" "$OUT_DIR/"
done

echo "[+] 完成，输出目录: $OUT_DIR"
ls -la "$OUT_DIR" | grep -i pcap || true
