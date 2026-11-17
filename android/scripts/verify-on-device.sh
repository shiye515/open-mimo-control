#!/bin/bash
# =============================================================
# OpenMimoControl 设备端到端验证脚本
# 前置：adb 已连接手机；手机已解锁（输入 PIN/指纹）；相机开机在附近
# 用法：./verify-on-device.sh
# 产物：/tmp/oc-verify/ 下三页截图 + diag.log + logcat
# =============================================================
set -e
UDID_ARG=""
PACKAGE="com.openmimo.control"
OUT=/tmp/oc-verify
mkdir -p "$OUT"

echo "== 1. 唤醒屏幕并启动 App =="
adb shell input keyevent KEYCODE_WAKEUP; sleep 1
adb shell wm dismiss-keyguard 2>/dev/null || true; sleep 1
adb shell am start -W -n $PACKAGE/.MainActivity >/dev/null
sleep 3

shot() { adb exec-out screencap -p > "$OUT/$1" 2>/dev/null && echo "  截图: $OUT/$1"; }

echo "== 2. 连接页截图 =="
shot 01-connect.png

find_tap() {
  # 按文本定位 UI 节点并点击（uiautomator dump）
  adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1
  local bounds=$(adb shell cat /sdcard/ui.xml | python3 -c "
import sys, re
d = sys.stdin.read()
m = re.search(r'text=\"$1\"[^>]*bounds=\"(\[(\d+),(\d+)\]\[(\d+),(\d+)\])\"', d)
if m:
    x = (int(m.group(2)) + int(m.group(4))) // 2
    y = (int(m.group(3)) + int(m.group(5))) // 2
    print(f'{x} {y}')
")
  [ -n "$bounds" ] && adb shell input tap $bounds
}

echo "== 3. 点「连接相机」触发连接流程（BLE 配对时请在相机屏幕按确认！）=="
find_tap "连接相机"

# 等待流程结果：最长 135s（BLE 120s 超时 + 入网 12s 内任意时点可能成功）
SUCCESS=0
for i in $(seq 1 45); do
  sleep 3
  if adb shell uiautomator dump /sdcard/ui.xml >/dev/null 2>&1 \
     && adb shell cat /sdcard/ui.xml | grep -q "已连接相机"; then
    SUCCESS=1; break
  fi
  # 连接失败（超时/拒绝）也截图留证
  if adb shell cat /sdcard/ui.xml 2>/dev/null | grep -q "连接失败"; then
    echo "  连接页显示失败提示（留证）"
    break
  fi
done
echo "== 4. 流程结果: $([ $SUCCESS = 1 ] && echo 成功 || echo 未成功) =="
shot 02-after-flow.png

if [ $SUCCESS = 1 ]; then
  echo "== 5. 控制页截图 =="
  sleep 2
  shot 03-control.png

  echo "== 6. 素材页截图 =="
  find_tap "素材浏览" || adb shell input tap 80 2500
  sleep 3
  shot 04-media.png
fi

echo "== 7. 收集 diag.log + logcat =="
adb exec-out run-as $PACKAGE cat files/diag.log > "$OUT/diag.log" 2>/dev/null
adb logcat -d > "$OUT/logcat.txt" 2>/dev/null
echo "  diag.log 行数: $(wc -l < "$OUT/diag.log")"
echo "== 完成。产物在 $OUT/ =="
