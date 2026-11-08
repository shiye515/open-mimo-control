# 稳定连接实现记录（connection-implementation）

> 状态：**已真机验证、端到端可复现**（2026-10-28）。连续两轮完整流程 17s / 18s 成功入网并建立会话。
> 本文档记录当前 iOS 代码（`ios/OpenMimoControl/` + `ios/OpenMimoProtocol/`）中已稳定工作的连接链路，
> 是 ble-provisioning.md / discovery.md 中"推定/未定"结论的实测修正版。改协议前先读本文。

## 0. 链路总览

```
唤醒广播(WKP+MAC反序) → BLE 连接 FFF5 → 明文 DUML 8 帧序
→ SSID/密码明文应答 → NEHotspot apply 入网 → WMS 查询密码持久化 → 建立控制会话
```

全程**无 R 协议认证（0xAA）、无 ECDH**——此前逆向假设 BLE 阶段需要认证+加密交换，
真机实测 Mimo 连上 FFF5 后直接发明文 DUML 帧序，凭据应答也是明文。

## 1. 代码结构

| 文件 | 职责 |
| --- | --- |
| `ios/OpenMimoControl/ConnectionFlow.swift` | 线性流程编排：waking → BLE 查询 → joining → WMS 查询 → connecting，任一步失败即停 |
| `ios/OpenMimoProtocol/Sources/OpenMimoProtocol/CameraBleWake.swift` | BLE 扫描/连接/DUML 帧收发与解析（`CameraBleWaker.shared` 单例） |
| `ios/OpenMimoProtocol/Sources/OpenMimoProtocol/HotspotWaker.swift` | CBPeripheralManager 反向广播唤醒（WKP+MAC 反序） |
| `ios/OpenMimoControl/CameraWifiJoiner.swift` | NEHotspotConfiguration apply 入网 + 12s 轮询 + KeychainStore 密码持久化 |
| `ios/OpenMimoProtocol/Sources/OpenMimoProtocol/CameraSession.swift` | UDP 9004 WMS 探测（`startWMSProbe`）+ 心跳保活 |
| `ios/OpenMimoControl/StepLogger.swift` | 步骤日志（`时间戳 | 步骤 | 方向 | 内容`，进 AppDiagnostics 面板） |

## 2. 步骤 1：唤醒广播（waking）

相机休眠时热点关闭，需先用反向广播唤醒热点。

1. **MAC 来源**（优先级）：UserDefaults `camera.mac` 缓存 → 无缓存时 `CameraBleWaker.scanOnceForMAC` 扫描 3 轮 × 8s。
   相机广播 manufacturer data **尾 6 字节 = 相机 MAC**（与 wifi_get_mac 应答一致，实测 e4:7a:2c:19:76:e7）。
   MAC 命中后立即持久化，下次跳过扫描。
2. **广播**（`HotspotWaker.wakeCamera(macReversed:)`）：CBPeripheralManager 广播
   `[len=10][0xFF]['W''K''P' + MAC反序]`，2 轮 × 2.5s（变体 A：9B 裸 WKP+MAC反序；变体 B：2B 占位 CID 前缀补偿），随后等待 6s 让相机开热点。
   注意 iOS 会自动在 manufacturer data 前加 2 字节 CID，超出 28B 会静默失败，必须用 DidStartAdvertising 回调确认。

## 3. 步骤 2：BLE 凭据获取（querying，`connectAndGetCredentials` 30s 超时）

1. 扫描名称前缀 `Osmo/OA4/OA5` → `CBCentralManager.connect` → 发现服务 **FFF0**。
2. 订阅 **FFF4**（notify，应答通道）与 **FFF3**（多链路探测用），写通道为 **FFF5**（withResponse）。
3. 特征就绪 0.5s 后**同 ATT 连发 8 帧明文 DUML**（帧格式 `55|len2|crc8|src|dst|seq|ct|set|id|payload|crc16`，
   src=0x02，ct=0x40，seq 从 0x31D3 递增；CRC8 init 0x77/poly 0x8C 作用于前 3 字节，
   CRC16 init 0x3692/poly 0x8408 作用于 header+payload）：

| # | dst | cmdSet | cmdId | payload | 用途 |
| --- | --- | --- | --- | --- | --- |
| 1 | **F0** | 00 | 2b | `04 00` | 握手 |
| 2 | **07** | 07 | 45 | TOKEN（40B） | TOKEN 验证 |
| 3 | **88** | 00 | 32 | `31 31 00 00 00` | 配置 |
| 4 | **88** | 00 | 32 | 同上 | 配置 #2 |
| 5 | **08** | 02 | 8e | `00 01 1c 00` | 订阅 |
| 6 | **08** | 08 | 79 | `00` | 查询 |
| 7 | **07** | 07 | 07 | `00` | get_ssid |
| 8 | **07** | 07 | 0e | `00` | get_password |

**dst 是关键校准点**（pklg 两次抓包一致）：握手→F0（网关）、TOKEN/凭据→07（WiFi 模块）、
配置→88、订阅/查询→08。dst 错配会被 0xE0 拒绝，且后续凭据查询被相机无视。

TOKEN 帧（40B）缓存于 UserDefaults `camera.wms_token`，来自 pklg 真实帧抓取
（`[0x20][16B密钥][0x04][4B数字][01 01]`，两次抓包前 17 字节稳定，仅尾部 4 位数字变化）；代码内置一份默认值兜底。

4. **应答解析**（FFF4 通知 → 帧缓冲 → DUML 解析）：`(07,07)` 与 `(07,0E)` 的 payload =
   `[ret:1][len:1][明文 UTF-8]`。实测 SSID 为 16B（`OsmoAction4-xxxx`，后缀因设备而异）、密码为 12B 明文（因设备与会话轮换，不在文档中留存）。
5. 凭据到手即持久化：`camera.ssid`、`camera.wifi_password`（UserDefaults），并写入 Keychain 供入网使用。

**修正记录**：ble-provisioning.md 的"ECDH 密钥交换 + 加密应答"假设对 **BLE 阶段不成立**
（9 种变体 0x92 帧无应答；明文应答已两次实测）。加密通道仅存在于 WiFi 侧 `(07,72)` 入口，与本链路无关。

## 4. 步骤 3：热点入网（joining）

1. `LocationGate.ensure()`：定位授权未决定时请求 WhenInUse（iOS 上 SSID 读取受定位门控）。
2. `NEHotspotConfiguration(ssid, passphrase, isWEP: false)`，`joinOnce = false`（持久登记，供 getConfiguredSSIDs 自动重连）。
3. apply 失败 code=8（配置冲突）→ 记录冲突标记，下次 apply 前 `removeConfiguration`，共重试 2 次。
4. apply 成功后轮询 `NEHotspotNetwork.fetchCurrent` 24 次 × 0.5s（12s 窗口）确认实际接入——
   接入可能出现后又被系统切回可上网网络，必须轮询捕获。
5. 历史坑实证：**之前 NEHotspot 失败的根因是密码错误，不是系统 bug**。凭据来自 BLE 明文应答后入网即稳定成功。

## 5. 步骤 4：WMS 查询（WiFi 侧 UDP 9004）

入网后 `CameraSession.start()`，UDP 就绪即自动发 `startWMSProbe` 5 连发：
握手(00,2b) → 扫频(00,4f) → TOKEN(40,07,45) → get_ssid(07,07) → get_password(07,0e)（与 BLE 帧序同一命令空间，WiFi 通道 DUML 0x55）。

ConnectionFlow 轮询 UserDefaults `camera.wifi_password`（15s 窗口），密码应答落地即视为查询完成。
此步的意义：**断线重连全程无 BLE**——密码已持久化，直接 apply 即可。

## 6. 步骤 5：建立会话（connecting）

新建 `CameraSession`（UDP 9004 主通道 + TCP 7001 辅助），周期轮询/ACK 心跳保活（见 CameraSession 与 control-channel.md）。
流程结束 `state = .success`，UI 切控制页。

## 7. 持久化键清单

| 键 | 位置 | 内容 |
| --- | --- | --- |
| `camera.mac` | UserDefaults | 相机 MAC hex（唤醒广播用，命中后缓存） |
| `camera.ssid` | UserDefaults | 相机热点 SSID |
| `camera.wifi_password` | UserDefaults | BLE/WMS 明文密码（断线自动重连用） |
| `camera.wms_token` | UserDefaults | TOKEN 帧 40B（BLE 与 UDP 帧序共用） |
| Keychain `win.service-ai.OpenMimoControl.wifi`，account=ssid | Keychain | 入网密码（不进 UserDefaults） |

## 8. 失败语义与重试

- 任一步失败 → `FlowState.failed(step:reason:)`，**无自动循环重试**，由用户点重试重新执行 `start()`（design D-update 决策）。
- 蓝牙关闭不判失败：`centralManagerDidUpdateState` 提示用户开蓝牙，打开后自动继续。
- `cancel()` 中止当前流程回 idle。

## 9. 已验证 / 未验证边界（2026-10-28）

- ✅ 两轮成功均发生在相机热点本就开启（BLE manufacturer data 可连）的场景；**冷态（热点关）下唤醒广播是否有效未验证**（02:05 轮实测冷态唤醒未生效）。
- ✅ BLE 凭据 → NEHotspot 入网 → WMS 密码持久化全链路。
- ✅ UDP 会话层：session id 由 App 声明、相机回显（`S2C 回显本地 session=80c615` 真机实证）；48B 保活帧触发相机 9B 应答（与 pcap 首包逐字节一致）。
- ⏳ 遥测推送上线：依赖外层包头 34B 布局修复（本轮已改，待相机可用时复测——见 iter_20261028_0153.md）。
- ⏭ 下一层：遥测订阅（控制页电量/SD/信号）、live-view 加密流解密。

## 10. 关键 bug 记录（2026-10-28 遥测轮，防回退）

1. **NWCameraLink 发送层失效**：struct 的 `open()` 内 `let state = State()` 遮蔽实例属性，
   `sendUDP/sendTCP/close` 永远读到空 State → 全部 UDP 发送静默失败（TX 日志在发送前打印 + try? 吞错，
   日志呈"假成功"）。修复：改 class，open() 将新 State 暴露给实例。
2. **MimoPacket 外层包头布局错误**：旧 20B 头（rxSeq4+ack8+seq4）vs pcap 实际 34B 头
   （`[len][session:3][seq:4][ACK块24B][尾2B]`）→ 相机无法解析任何业务帧，全部静默无视。
   仅 48B 保活帧（独立构建）碰巧格式正确，故相机只回 9B 会话包。
3. 经验：TX 日志必须在发送成功后打印；receive/send 的错误必须落日志（曾被吞导致不可诊断）。
