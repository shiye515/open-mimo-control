# 蓝牙 & WiFi 抓包环境准备总结

> 准备日期：2026-11-13　设备：三星 SM-F731U1（Z Flip 5），Android 17，arm64-v8a，**无 root**
> 目标：抓取 `mimo.sz`（Mimo app）与 DJI OsmoAction4 相机之间的蓝牙与 WiFi 通信

## 设备与连接信息

| 项目 | 值 |
|---|---|
| Mimo 应用包名 | `mimo.sz` |
| 相机 SSID | `OsmoAction4-76E6`（SoftAP 模式，WPA2） |
| 相机 WiFi BSSID | `e4:7a:2c:19:76:e6` |
| 手机侧 IP | 192.168.2.165 |
| 相机蓝牙地址 | `…:76:e7`（与 WiFi BSSID 相邻，分析时可用作过滤） |
| 手机网络接口 | `wlan0`（连接相机热点）、`p2p0`（存在） |

## 已完成的准备

### 蓝牙抓包
- `adb shell settings put secure bluetooth_hci_log 1` 已开启，蓝牙已重启生效
- 所有 HCI 流量（BLE GATT、ACL）自动记录到设备
- **收尾脚本 `pull-btsnoop.sh`**：通过 bugreport（无 root 唯一途径）提取 `btsnoop_hci.log`

### WiFi 抓包
- 已安装 **PCAPdroid v2.0.2**（无 root，VpnService 抓 IP 层）
- 手机连着相机热点，流量走 `wlan0`，为可抓路径
- **收尾脚本 `pull-pcapdroid.sh`**：从手机 `/sdcard/Download` 拉取 pcap
- 已验证 adb 可访问手机 Download 目录 ✓

### 脚本用法
```bash
./capture-scripts/pull-btsnoop.sh     # 蓝牙操作结束后运行，提取 btsnoop_hci.log 到 captures/
./capture-scripts/pull-pcapdroid.sh   # WiFi 抓包结束后运行，拉取 pcap 到 captures/
```
输出统一保存在 `captures/` 目录（可用第一个参数覆盖）。

## 手机端一次性配置（WiFi 抓包前）

1. 打开 **PCAPdroid** → 点底部 **▶ 开始** → 弹窗中**允许 VPN 权限**
2. 设置里把**目标应用（Target apps）**设为 `mimo.sz`（过滤无关流量）
3. 主界面菜单选 **PCAP 文件（PCAP dump）** → 保存位置选 **Download** → 再点开始
4. 操作完成后：点**停止** → 电脑运行 `./capture-scripts/pull-pcapdroid.sh`

蓝牙抓包无需额外配置：直接操作 app 与相机蓝牙连接/通信，结束后运行 `pull-btsnoop.sh`。

## 待验证点（首次实际抓包时确认）

1. **btsnoop 是否出现在 bugreport 中**
   - 首次验证时蓝牙刚被重启、无 HCI 流量导致文件未生成，尚未确认
   - 连接一次相机蓝牙后运行 `pull-btsnoop.sh` 验证
   - 兜底方案：`adb shell dumpsys bluetooth_manager` 的 GATT 操作日志，或给 `mimo.sz` 加应用层日志
2. **PCAPdroid 能否抓到相机流量**
   - 若 app 用 ConnectivityManager 绑定特定 network，可能绕过 VPN 接口
   - 首次抓包检查 pcap 中有无 `192.168.2.x` 流量即可判断
   - 兜底方案：在 `mimo.sz` 内加 socket 层 dump（自研 app 可行）

## Mac 端分析工具

- 尚未安装 Wireshark/tshark（自带 `tcpdump -r` 可读 pcap，但解析能力有限）
- 建议：`brew install --cask wireshark`（GUI + CLI），方便人工分析协议流
