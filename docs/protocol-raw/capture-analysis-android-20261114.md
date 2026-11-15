# DJI OsmoAction4 ↔ 官方 Mimo App (Android) 协议分析报告

> 抓包时间：2026-11-14 22:00:25 – 22:03:32　|　设备：** (Android 17)
> 数据源：`captures/tcpdump_any_20261114215953.pcap`（87MB, 86,644 包相关流量，Samsung SysDump `*#9900#` TCP DUMP）
> 辅助：`captures/logcat-20261114-220059.log`（46MB）　|　分析工具：`tools/pcap_9004.py`

---

## 1. 网络结构总览

| 通道 | 结果 |
|---|---|
| **UDP 9004** | **唯一有效通道**：控制 + 图传 + 遥测全部复用。会话 `192.168.2.165`(手机) ↔ `192.168.2.1`(相机) |
| TCP 6001 / 7001 | 全部为未完成连接（手机连接热点前盲发的探测 SYN，每秒重试，均失败） |
| 多网段探测 | app 同时向 `192.168.2.1 / 4.1 / 22.1` 三个预设网段发 UDP 9004 探测（各 329 包） |

**流量构成**（UDP 9004，方向）：
- 相机 → 手机：52,286 × 1472B（**图传视频**，预览期 4.5–6.5 Mbps）+ 13,181 × 34B（心跳）+ 遥测聚合包（1284B×162 等）
- 手机 → 相机：10,367 包，全部 33–76B 小包（心跳 + 轮询 + 指令）

## 2. 帧格式（已破译部分）

```
偏移   长度  内容
0      2    帧长，小端 = 0x8000 | payload_len   （22 80 = 34B；c0 85 = 1472B）
2      2    会话标记 0x5104（主控制会话，小端"04 51"；少数包 0x56A6/0xD7FC 为子会话）
4      2    seq（步进 8 递增，如 0x9110 → 0x9118）
6      2    对端 seq 确认（递减）
8      2    前一 seq
10     2    保留 0x0000
（注：遥测/心跳包的 4-17 偏移为 3 组通道状态数组 [2088 2088 0000 0000]×3）
18/20  2    包计数（步进 1）/ 命令参数
20     4    DJI 命令字：0x55 [cmd] [04] [crc8]    ← 0x55 为 SOP
末尾   2    CRC16（随内容变化）
```

## 3. 命令字字典（0x55xx，手机 → 相机）

| cmd | type | 长度 | 频率 | 推断用途 |
|---|---|---|---|---|
| `0x550e` | 0x22 | 34B | ~69/s 双向 | **心跳**（含 3 通道信号数组 2088/2888/3888） |
| `0x5511` | 0x25 | 37B | ~10/s | **高频参数轮询**（官方"轮询"实现，对应 iOS 侧主题轮询） |
| `0x5518` | 0x2c | 44B | 爆发期密集 | **参数组/模式查询**（进预览页后基线 5→18/s 的主力） |
| `0x5517` | 0x2b | 43B | 单发×3 | **模式/参数切换指令**（三次页面/模式变更时刻均出现） |
| `0x551b` | 0x2f | 47B | 会话初始×3 | **APP 注册/握手**（载荷含 "APP" 明文 0x415050） |
| `0x5537` | 0x4b | 75B | 全程仅 2 次 | **关键动作指令**（含操作序号 `10 05`/`10 06` 递增；与相册页进入时刻吻合） |
| `0x550d/0x550f/0x5512/0x5516` | | 33-42B | 周期 | 低频状态查询组 |

## 4. 相机遥测参数字典（cam → app，明文 TLV）

聚合包（1284B/1418B）内含 TLV：`[type 2B][name_len 2B]["param_name"][值区（嵌套 0x55 条目 + CRC）]`

| 高频 (~4.4/s) | 中频 (~2.3/s) | 低频 |
|---|---|---|
| `cam_record_time` | `cam_status`、`cam_photo_param` | `timecode_info` |
| `cam_imu_calib_info` | `shutter_param`、`cam_video_param_v2` | `temp_curve` |
| `cam_audio_status_v2` | `cam_storage`、`cam_lens_state`、`cam_fov` | `camcap_common` |
| | `cam_expo_param`、`cam_image_effect`、`cam_custom_mode_params`、`cam_magnifier_status`、`cam_lapse_param`、`v_quality_enhance_status`、`audio_timecode_status` | |

**与 iOS 侧 OpenMimoProtocol 对照**：`shutter_param`、`cam_expo_param`（EV/快门/ISO）、主题轮询机制均可直接映射到既有实现。

## 5. 操作时间线（pcap × logcat 交叉对齐）

| 时刻 | pcap 证据 | logcat 证据 | 事件 |
|---|---|---|---|
| 22:00:29 | BLE 连接 `…:**`（conn_interval=24） | btif_gattc_open | BLE 连接（GATT UUID 家族 594a****-31db-11ea-*，双特征 594a36e6/594a3010） |
| 22:00:38-40 | 订阅风暴 30/s；0x551b APP 注册；0x5537#1 (seq 05) | — | 会话建立 + 参数订阅 |
| 22:00:41-22:01:15 | 基线 5 非心跳/s，码率 0 | MainActivity | 主页面静置（无图传） |
| **22:01:15.9** | 码率跳 6.5Mbps；轮询 5→18/s | `wm_create_activity: DJIFpvActivity` | **进入实时预览页，图传启动** |
| 22:01:30-35 | 码率骤降 6.5→1.5→2.4→6.2 | — | 疑似**拍照瞬间**（图传冻结）待验证 |
| **22:02:55.8** | 图传暂停；0x5537#2 (seq 06) | `PlaybackContainerActivity` | **进入相册/回放页** |
| 22:03:09-10 | 图传恢复 6.4Mbps；0x5517 | — | 返回预览页 |
| 22:03:24 | 流量骤停 | WIFI disconnected | 断开 |

## 6. BLE 层（本轮发现，btsnoop 不可用下的替代证据）

- 手机同时为 **GATT Client + Server**（双向通道协议）
- 手机侧注册服务：`594a34fc-31db-11ea-978f-2e728ce88125`
  - 特征 `594a36e6-…`（Write+Indicate）
  - 特征 `594a3010-…`（Write No Response）
- WiFi 凭据经 BLE 下发（阶段 B 配网流程）

## 7. 待深入项

1. **拍照/录像指令精确定位**：淹没在预览期 18/s 基线中；0x5537 仅 2 次（seq 05/06）与页面切换吻合而非快门——快门指令候选为 0x26/0x5512 或 0x2a/0x5516 的单发变体
2. **TLV 值区完整解码**：值区含嵌套 0x55 条目 + CRC，需结合 APK 逆向的解析代码
3. **视频流封装**：1472B 包的分片/帧头结构未解析
4. **`0x5104` 会话字段与子会话（0x56A6/0xD7FC）语义**

## 8. 工具与数据清单

| 文件 | 说明 |
|---|---|
| `captures/tcpdump_any_20261114215953.pcap` | 本次 WiFi 抓包主数据 |
| `captures/logcat-20261114-220059.log` | 同期应用层日志 |
| `captures/logcat-20261114-211019.log` | 前次会话日志（含 VPN 失败轮 + GATT 注册日志） |
| `tools/pcap_9004.py` | pcap 解析器（session/timeline/burst/ascii 四模式） |
| `dji-research/mimo-apk/` | 官方 app 4 个 APK（base 141MB / arm64 168MB / **csdk 90MB** / assets 580MB） |
| `dji-research/csdk-extract/so/` | 19 个 CSDK 原生库（`libdjisdk_jni.so` 43MB = 控制协议核心） |
| `dji-research/sysdump-otp.py` | SysDump OTP 计算器 |
| `dji-research/csdk-latest.log` | CSDK 加密日志样本（DJI 私有格式，未解） |

**抓包方法论结论**（无 root Samsung）：
- WiFi：PCAPdroid/VPN 不可行（私有热点无互联网 → 转发黑洞）；**SysDump `*#9900#` TCP DUMP 是正解**（需 OTP，`sysdump-otp.py` 可算；导出需 `Copy to sdcard`）
- 蓝牙：btsnoop 被 One UI 从 bugreport 裁剪且无 root 不可达 → 蓝牙协议走 **APK Java 层静态逆向**（DJI BLE 栈为 Java 实现）
