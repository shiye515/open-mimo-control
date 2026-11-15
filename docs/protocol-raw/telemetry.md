# 状态遥测（telemetry）

> 证据：docs/protocol/mimo-ios.pcap。所有主题名均为线上明文 ASCII。

## 1. 订阅机制（已证实）

连接握手后，手机对每个主题发一条订阅帧（`0x55` 帧，cmd 随主题而异——推定为主题名的 8-bit 哈希，见 control-channel.md §4.5），body 形如：

```
[seq:2] [40 00 99 02 02 00 00] [req_id:2] [00 00 00 00] [total_len:2] [name_len:2] 00 [name] [pad] [crc]
```

样例（订阅 cam_status）：`552a 049c 0228 e6a4 4000 99020200 00efd5 00000000 0010 000a 00 "cam_status" 00000000 [crc]`

相机逐条返回 `cmd=0x38` ACK（回显 req_id），并立即以推送帧下发首个值。

## 2. 推送帧

推送承载于 `0x55` 帧（cmd 观测到 0x25/0xde/0xf9/0x70/0x21/0x67/0x1a/0x1e/0x93…，与主题相关），body 内嵌主题名与值：

```
[seq:4] [99 02] [action] [handle:4] [00 00] [total_len:2] 00 [name_len:2] 00 [name] [pad] [value…]
```

样例（cam_status 推送）：`…001d 000a 00 "cam_status" 00000000 0009 000000 55 01 01 00 01 0000`

## 3. 本次连接订阅的全部主题（19:52:35.55，已证实）

`cam_status`、`cam_record_time`、`cam_storage`、`cam_fov`、`cam_photo_param`、`cam_lapser_param`、`cam_video_param_v2`、`cam_expo_param`、`cam_lens_state`、`cam_image_effect`、`shutter_param`、`camcap_common`、`camcap_custom_mode_params`、`cam_fov`、`cam_audio_status_v2`、`audio_timecode_status`、`timecode_info`、`temp_curve`、`cam_imu_calib_info`、`cam_magnifier_status`、`cam_fov`、`v_quality_enhance_status`、`cam_custom_mode_params`

## 4. 关键主题值结构（已证实，经状态变化时间轴对齐）

### cam_status（9B：`55 [mode] [target] 00 [zoom_idx] [state] 00`）

| 字节 | 含义 | 观测值 |
| --- | --- | --- |
| +1 | 当前模式 | 00=照片, 01=视频, 02=慢动作, 05=延时(推定), 0a=直播(推定) |
| +2 | 目标模式（切换过渡期） | 同上值域 |
| +4 | 变焦档位 | 00/01/02/03（与 cam_fov 焦距联动：24.1→48.3→36.2mm） |
| +5 | 子状态 | 00=待机, 01=预览, 02=切换中, 03=录制中, 05=连拍/延时执行 |

样例：`55 01 01 00 01 0200`（视频模式、变焦 2 档、切换中）。

### cam_record_time

推送周期 1s（仅录制中）；值区 `[0006] [seconds…]`，观测 1→12 递增、停止归 0。

### cam_fov（等效焦距，×100 mm，u32 LE）

| 值 | 含义 |
| --- | --- |
| `6d09 0000` | 24.13mm（1.0x） |
| `da12 0000` | 48.26mm（2.0x） |
| `230e0000` | 36.19mm（1.5x） |

后随 `1107 0000 / 9a0a 0000` 等字段（第二焦距/光圈相关，未定）。变焦 UI 可直接由该值换算倍率（焦距 ÷ 24.13）。

### cam_storage

值区含容量字段（录制期间持续下降），样例：
`1600 0012 0100 0001 f3cf0100 b0c20100 00000000 5f220000` —— 布局未逐字段定案；录制 12s 期间尾部可用量字段 `5f22→5422` 变化对应写盘量。

### cam_photo_param / cam_lapser_param

延时摄影执行期观测到 **5→1 秒倒计时**（值尾 `05 01→04 01→…→00 01`，每秒一推）。

## 5. 遥测周期小结

| 主题 | 周期 |
| --- | --- |
| cam_status | 状态变化即推 + ~1.2s 心跳式重推 |
| cam_record_time | 录制中 1s |
| cam_storage | ~1.1s（录制中更密） |
| cam_fov | 变焦变化即推 |
| 其余 | 变化即推 |

## 6. iOS 实现现状（2026-10-28 三轮更新，遥测已上线）

订阅/推送机制是**明文**且自描述（带主题名）。**真机已验证的遥测链路**：

- **WiFi 侧 (0x02,0x80) 设备状态推送**（无需订阅，UDP 会话建立后相机每 ~1s 主动推，BLE/UDP 同构）：
  payload 布局 `[01][02][80][00 00][xx][total_mb:4 LE][free_mb:4 LE][photo:4 LE]…`。
  实时验证：total=118,771MB、free=118,858MB、photo=1,499 每秒刷新，UI 状态条显示 SD 110.9GB ✓。
  注意 free 可 > total（相机两字段语义不完全对齐，疑 total=用户可用、free=含保留区）。
- **会话层四连修复（遥测上线的完整根因链，2026-10-28）**：
  ① NWCameraLink struct State 遮蔽 → 全部 UDP 发送静默失败（改 class）；
  ② 外层包头布局错误 → 最终破译为 20B 业务头 `[len][session:3][seq8:2 步进+8][token 0501][ackBase][seq8回显][0000][外层序号:4 起始0x0101]`；
  ③ **NWConnection.receive 对 UDP 首包即返回 isComplete=true（iOS 真机实测）——不能当流结束**，需无错误时继续收包（此前每轮只收 1 包即自毁重连）；
  ④ ConnectView 的 `onSessionCreated` 在 SwiftUI init 里挂接会丢到临时 @StateObject 实例上，需移至 onAppear。
- 电量：直连路径无 BLE 推送源（相机已停 BLE 广播），UI 显示缓存值/—；BLE 场景（完整连接）
  (0x0d,0x02) 推送 @20 u16 LE = 电量百分比（充电中样本 0x0064=100 实测），经 UserDefaults 桥接入遥测。
- 1D05/1D02 订阅探测已实装待验证（WiFi 会话内无 ACK——对 OA4 的兼容性未确认）。

## 7. 电量主题调查结论（2026-10-28 专项）

**WiFi 主题空间不存在电量主题**（三重证据）：
1. pcap 全程 ASCII 检索：23 个主题无一含 battery/power；
2. libdjisdk_jni.so 主题名清单（48 个 cam_*/相关主题）：无电量主题；
3. 官方 App 电量 UI 显示期间，WiFi 抓包无任何电量数据到达。

电量的真实来源（两条候选路径，均已有协议定义）：

| 路径 | 命令 | 结构 | 来源 |
| --- | --- | --- | --- |
| 官方遥控器状态推送 | (0x40,0x1D,0x05) 订阅 → (0x1D,0x02) 推送 | 38B，**电量 uint8 @37**，另有 SD 剩余@15、录制秒@5、分辨率@2、帧率@3 | osmo-gps-controller/protocol_data_segment_CN.md（官方文档级） |
| BLE 裸推送 | (0x0D,0x02) ~1Hz | varies（布局未定案） | dji-reversing/lib-osmo-ble/PROTOCOL.md 遥测表 |

注：BLE (0x02,0xDC) 相机变体推送（~2Hz 22B）已在 XS 实测出现，payload 与 cam_storage 值同构——
两代设备的裸命令空间共通。iOS 已实现：1D05 订阅探测（startWMSProbe 附加）+ 1D02 解析（CameraStatusV2）
+ BLE (0d,02)/(02,dc) 推送日志；全部待真机验证。
