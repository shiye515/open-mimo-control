#!/bin/bash
# pull-btsnoop.sh — 蓝牙抓包收尾：从 Android bugreport 中提取 btsnoop_hci.log
#
# 前提：设备已开启「蓝牙 HCI 信息收集日志」（本脚本环境已通过
#   adb shell settings put secure bluetooth_hci_log 1 开启并重启蓝牙生效）。
# 蓝牙操作完成后（连接/断开相机、蓝牙配对、app 蓝牙通信等）运行本脚本。
#
# 用法：./pull-btsnoop.sh [输出目录]   （默认 ../captures）
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="${1:-$SCRIPT_DIR/../captures}"
mkdir -p "$OUT_DIR"

TS=$(date +%Y%m%d-%H%M%S)
WORK="$(mktemp -d /tmp/btsnoop-work.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

echo "[*] 正在收集 bugreport（可能需要 1-3 分钟，请保持设备连接）..."
adb bugreport "$WORK/bugreport-$TS.zip"

echo "[*] 在 bugreport 中查找 btsnoop 日志..."
# btsnoop 在 bugreport zip 的 FS/data/misc/bluetooth/logs/ 下（各版本路径略有差异，通配匹配）
MAPFILE=$(unzip -l "$WORK/bugreport-$TS.zip" 2>/dev/null | awk '{print $4}' | grep -i 'btsnoop_hci\.log' || true)

if [ -z "$MAPFILE" ]; then
  echo "[!] bugreport 中未找到 btsnoop_hci.log。zip 内相关蓝牙文件如下："
  unzip -l "$WORK/bugreport-$TS.zip" | grep -i -E 'bluetooth|btsnoop' | head -20 || true
  exit 1
fi

echo "$MAPFILE" | while read -r entry; do
  echo "[*] 提取: $entry"
  unzip -o -j "$WORK/bugreport-$TS.zip" "$entry" -d "$OUT_DIR"
done
mv "$OUT_DIR/btsnoop_hci.log" "$OUT_DIR/btsnoop_hci-$TS.log" 2>/dev/null || true

echo "[+] 完成，输出目录: $OUT_DIR"
ls -la "$OUT_DIR" | grep btsnoop
