# 工具链清单（全部在本机验证过）

> 验证日期：2026-10-25/26。工具缺失时的安装方式一并标注。

## 1. devicectl（Xcode 自带，USB 真机控制）

```bash
# 设备列表（关注 State：available / unavailable=锁屏或未信任 / unpaired）
xcrun devicectl list devices

# 安装 App（app 路径在 DerivedData；先 build）
xcrun devicectl device install app --device <UDID> \
  ~/Library/Developer/Xcode/DerivedData/OpenMimoControl-*/Build/Products/Debug-iphoneos/OpenMimoControl.app

# 启动 / 杀进程
xcrun devicectl device process launch --device <UDID> win.service-ai.OpenMimoControl
xcrun devicectl device process kill --device <UDID> --pid <PID>
xcrun devicectl device info processes --device <UDID> | grep -i mimo   # 查 PID

# 截图（--destination 必须显式给）
xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/shot.png

# 崩溃日志拉取（闪退排查第一步）
xcrun devicectl device copy from --device <UDID> --source . \
  --domain-type systemCrashLogs --destination /tmp/crashes

# 设备信息（iOS 版本、配对状态）
xcrun devicectl device info details --device <UDID>
```

注意：`sysdiagnose` 在本机/该 iOS 组合上稳定报 `DiagnoseError 0`（3 次复现）——放弃此通道，
蓝牙 HCI 抓包改用手机端硬件手势（音量上+音量下+侧键 1s）生成 sysdiagnose。

## 2. 构建（Xcode 27，签名自动化）

```bash
cd ios
# 真机构建（-allowProvisioningUpdates 自动注册 capability/重签）
# 工程内不内置签名 Team（开源隐私要求）：命令行构建需显式传 DEVELOPMENT_TEAM，
# 或在 Xcode → Signing & Capabilities 里选择自己的 Team 后再构建
xcodebuild -project OpenMimoControl.xcodeproj -scheme OpenMimoControl \
  -destination 'id=<UDID>' DEVELOPMENT_TEAM=<你的TeamID> \
  -allowProvisioningUpdates build

# 只看结果
... 2>&1 | grep -E "error:|BUILD" | head -6
```

签名事实：Team `<你的TeamID>`，Bundle `win.service-ai.OpenMimoControl`，
entitlements：`wifi-info` + `HotspotConfiguration`（后者是 apply 报 code=8 的修复，见 pitfalls）。
部署目标已降为 **iOS 18.0**（兼容 iPhone XS）。

构建产物目录（hash 因机器而异）：
`~/Library/Developer/Xcode/DerivedData/OpenMimoControl-<hash>/Build/Products/Debug-iphoneos/OpenMimoControl.app`

## 3. WDA 真机 UI 自动化（点击弹窗/读日志的通道）

一次性安装（已完成，产物在 /tmp/mimo-re/WebDriverAgent——**/tmp 会被清，重建见 pitfalls**）：

```bash
git clone --depth 1 https://github.com/appium/WebDriverAgent.git /tmp/mimo-re/WebDriverAgent
cd /tmp/mimo-re/WebDriverAgent
xcodebuild build-for-testing -project WebDriverAgent.xcodeproj -scheme WebDriverAgentRunner \
  -destination 'id=<UDID>' DEVELOPMENT_TEAM=<你的TeamID> CODE_SIGN_STYLE=Automatic \
  PRODUCT_BUNDLE_IDENTIFIER=win.service-ai.WebDriverAgentRunner -allowProvisioningUpdates
```

启动服务（每台设备一个进程，**可多台并行**）：

```bash
nohup xcodebuild test-without-building -project WebDriverAgent.xcodeproj \
  -scheme WebDriverAgentRunner -destination 'id=<UDID>' -allowProvisioningUpdates \
  > /tmp/mimo-re/wda_<别名>.log 2>&1 &
# 日志出现 "ServerURLHere->http://127.0.0.1:8100" 即就绪（约 40s）
```

USB 端口转发（**多设备必须 --udid**）：

```bash
iproxy 8100 8100 --udid <设备A的UDID>   # 设备 A → localhost:8100
iproxy 8101 8100 --udid <设备B的UDID>   # 设备 B → localhost:8101
```

健康检查：`curl -s -m 5 http://localhost:8100/status`

### WDA HTTP API（验证过的用法）

```bash
# 会话：默认挂 springboard（系统弹窗在这个上下文里）
SID=$(curl -s -X POST http://localhost:8100/session -H 'Content-Type: application/json' \
  -d '{"capabilities":{}}' | python3 -c "import json,sys; print(json.load(sys.stdin)['value']['sessionId'])")

# 挂到指定 App（读 App 内 UI 文本；注意可能较慢甚至挂起，见 pitfalls）
curl -s -X POST http://localhost:8100/session -H 'Content-Type: application/json' \
  -d '{"capabilities":{"alwaysMatch":{"appium:bundleId":"win.service-ai.OpenMimoControl"}}}'

# 截图（JSON 包 base64）
curl -s http://localhost:8100/screenshot | python3 -c "
import base64,json,sys
d=json.load(sys.stdin); open('shot.png','wb').write(base64.b64decode(d['value']))"

# 无障碍树（XML，含全部元素的 name/label/坐标）
curl -s "http://localhost:8100/session/$SID/source" -o src.json
# 注意：返回是 {"value":"<xml…>"}（XML 转义在 JSON 字符串里），先 json 再正则

# 按名字找元素（系统弹窗按钮如"加入"/"好"）
EID=$(curl -s -X POST "http://localhost:8100/session/$SID/element" \
  -H 'Content-Type: application/json' -d '{"using":"accessibility id","value":"加入"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin)['value']; print(d.get('ELEMENT-') or d.get('element-6066-11e4-a52e-4f735466cecf',''))")

# 点击元素（唯一验证成功的点击方式）
curl -s -X POST "http://localhost:8100/session/$SID/element/$EID/click" -d '{}'
```

### WDA 坑（详见 pitfalls.md）

- `POST /wda/tap/0` → `unknown command`（本 build 未实现）；`/actions` 需要 `id` 字段且依赖元素——
  **点击一律走 element/click**
- `/source` 直接给的是 JSON 包 XML；二次解析
- 服务会卡死（响应空/连接 cancelled）→ 重启：pkill xcodebuild+Runner → 重新 test-without-building → iproxy 重启
- 会话默认挂 **springboard**；App 内 UI 需 bundleId 会话（创建可能挂 30s+，失败就重启 WDA）

## 4. 截图与视觉判断

```bash
# 手机截图（devicectl）
xcrun devicectl device capture screenshot --device <UDID> --destination /tmp/shot.png
# WDA 截图（与 devicectl 等效，走 USB 转发；两者选顺手的）
# 缩放后交给视觉模型 Read()
sips -Z 700 /tmp/shot.png --out /tmp/shot_s.png
```

判断模式：`Read()` 截图 → 视觉模型输出界面状态（弹窗/页面/日志行）。
WGA 截图分辨率=逻辑像素×3（16PM 1320×2868，XS 1125×2436）。

## 5. Python 分析环境（协议分析用，/tmp 会被清）

```bash
python3 -m venv /tmp/mimo-re/venv2
/tmp/mimo-re/venv2/bin/pip install scapy dpkt capstone pyelftools
```

用途：pcap 分析（scapy/dpkt）、ELF 逆向（capstone+pyelftools，绕加固段表的手写解析器
曾在 /tmp/mimo-re/parse_symbols.py、disasm_wifi.py——被清理需重建，模板见 docs/protocol/ble-provisioning.md §8）。

## 6. iOS App 日志的机器读取（两条通道）

| 通道 | 做法 | 状态 |
| --- | --- | --- |
| WDA 无障碍树 | bundleId 会话 + /source + 正则提取 `[wifi]/[ble]/[session]` 行 | 可用但 app-attach 偶发挂起 |
| App 沙盒日志文件 | App 端把 AppDiagnostics 追加写 Application Support；`devicectl device copy from --source <path> --domain-type appDataContainer --domain-identifier win.service-ai.OpenMimoControl` | **推荐 TODO**（实现后最稳） |
