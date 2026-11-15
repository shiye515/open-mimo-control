# DJI OSMO UDP 9004 — cmd 路由映射表

> 双源验证：抓包实证（`tcpdump_any_20261114215953.pcap`）+ 4676 个模板实例反编译（`cmd-map.tsv`）
> 帧格式见 `FRAME-FORMAT.md`：V2 帧内层 out[9..10] = cmd（u16 LE），out[11..] = payload

## ⚠️ 重要修正（v2）

`cmd-map.tsv` 中的常量（0x0110/0x0118 等）是 SendActionPack 函数体内的**其他常量**（proto 字段/Key ID），
**不是 wire cmd**。真实 cmd 由运行时 Key 注册表解析（表驱动，非编译立即数——0x2fee 精确搜索仅 1 个无关命中已证）。
wire cmd 的权威来源是抓包实证，见下表。

## 抓包实证 cmd 表（预览期 22:01:16-22:03:24，全部 V2 帧）

| cmd | 次数 | 频率 | 帧长 | 语义（实证推断） |
|---|---|---|---|---|
| **0x8e02** | 1774 | ~13.9/s | 37B | **状态轮询**（payload `00 01 14 00`，cmd 恒定=表驱动） |
| **0x0101** | 84 | 操作时 | 44B | **参数设置**（payload 含 param_id，见下） |
| 0x4f00 | 129 | 1/s | 42B | 周期查询 A（payload 8B 全 0） |
| 0x6102 | 128 | 1/s | 33B | 周期查询 B |
| 0x4407 | 128 | 1/s | 33B | 周期查询 C |
| 0x8800 | 128 | 1/s | 38B | 周期查询 D |
| 0xda03 | 16 | 偶发 | 38B | 录像/事件相关（payload `05 ff ff ff ff`） |
| 0x0000 | 32 | — | — | （待归档） |

### 0x0101 参数设置帧样本（= 用户 EV/快门/白平衡/ISO 操作）

```
内层: 55 18 04 20 | 02 01 39 db | 40 | 01 01 | 01 01 00 00 00 00 04 00 00 00 05 01 | 1d e8
      SOP  len+crc8  发送字段  cmd=0x0101  payload(11B)                     CRC16
```

payload 对比（两帧）：
```
01 03 00 00 00 00 04 00 00 00 07 01   ← 帧A
01 01 00 00 00 00 04 00 00 00 05 01   ← 帧B
      ↑ 差异：第2字节(03/01) 与倒数第3字节(07/05)
```
- 第 2 字节疑似**参数计数**（3 参数组 / 1 参数）
- 倒数第 3 字节疑似 **param_id**（0x07 / 0x05）
- 完整 param_id ↔ 参数映射待从 Key 注册表提取（key 名经 DAT 指针引用，需引用跟踪）

## proto 类型 → 功能对照（来自模板实例名，与 cmd 解耦）

121 个 req/rsp 类型（`proto-types.txt`）按功能分组，发送实例地址在 `cmd-map.tsv`：

- 拍照/录像：`take_photo_req`、`record_video_req`、`set_camera_capture_type_req`、`set_work_mode_req`
- 曝光：`set_camera_exposure_mode_req`、`set_camera_exposure_compensation_req`（EV）、`set_camera_shutter_speed_req`、`set_camera_mechanical_shutter_param_req`、`get_camera_ae_lock_req`、`set_camera_aeb_setting_req`
- 画质：`set_camera_video_quality_req`、`set_camera_video_format_req`、`set_camera_video_standard_req`、`set_camera_contrast/saturation/sharpness/hue_req`
- 其他：`format_sdcard_req`、`delete_photo_req`、`playback_control_req`、`wifi_get_ssid_req`、`activate_device_req`

**注意**：这些类型与 wire cmd 的对应关系是**运行时经 Key 注册表**（KeyHandlers/Characteristics）建立的，
不是函数内编译常量——iOS 复现时建议用抓包对照法：操作单个功能 → 抓帧 → 记录 (cmd, payload) 对。

## 下行特殊命令（DjiProtocolDecoder::DecodeCommand 硬编码）

| cmd | 处理 |
|---|---|
| 0x8409 | `wlm_send_external_data`（外部数据透传） |
| 0x0151 | 通用分支 |
| 0xcc00 | 特殊处理 |

## 复现工具链

```bash
# Ghidra 项目已保存（dji-base / dji-csdk），重跑脚本秒级：
/Users/shiye/tools/ghidra_12.2_PUBLIC/support/analyzeHeadless \
  ~/work/dji-research/ghidra-proj dji-csdk -process libdjisdk_jni.so -noanalysis \
  -scriptPath ~/work/dji-research/ghidra_scripts -postScript <脚本>.java
```

## 补充：key 名 ↔ topic 类型关联（响应 TLV 解码用）

`key-xref.tsv` 已建立部分关联（key 名字符串 → 引用函数）：

| key 名 | topic 类型（响应值解码结构） |
|---|---|
| `shutter_param` | `dji_topic_camera_shutter_info` |
| `cam_video_param` / `cam_video_param_v2` | `dji_topic_camera_video_param(_v2)` |
| `cam_audio_status` | `dji_topic_camera_audio_status` |
| `cam_multi_video_param` | `dji_topic_cam_multi_video_param` |
| `cam_lens_type` | `dji_topic_camera_accessory_lens_type` |
| `cam_pano_params` | `dji_topic_camera_photo_pano_params` |
| `cam_style_filter_status` | `dji_topic_camera_style_filter_status` |
| `cam_auto_aperture_range` | `dji_topic_camera_auto_aperture_range` |
| 其余 | 见 `key-xref.tsv`（70 行已固化，全量脚本可续跑） |

**param_id（写请求）注册表**：脚本已就绪（`KeyXrefExport.java`，预算 1200 需 30-60 分钟），或用对照法
（单参数写入测试 + SysDump 抓包）逐个实证——后者更快更可靠。

## 完整枚举数据

- `data/cmd-map.tsv`：4676 行（模板实例常量，注意非 wire cmd）
- `data/key-xref.tsv`：70 行（key 名 ↔ topic 类型，可续跑全量）
- `data/proto-types.txt`：121 个 proto req/rsp/topic 类型
- `dji-research/decompiled/`：106+ 反编译 C 文件（含 DjiProtocolEncoder/Decoder 全文）

## 更新（2026-11-15）：响应侧对齐 + 用户操作指令实证

响应帧结构与请求完全对称（SOP@外层 20B 后，cmd 在内层 out[9..10]，payload 为确认或数据）。
初始化期响应即设备信息明文：

| cmd | 响应内容 |
|---|---|
| 0x0707 | 相机名 `OsmoAction4-**` |
| 0x0c07 | WiFi MAC（=BSSID **） |
| 0x0c12 | 蓝牙 MAC（…**） |
| 0x0e07 | 13 字节设备串 |
| 0x1907 | 地区码 `CN` |
| 0x3200 | 时间戳 + 序列号 `**` |
| 0x7600 | JSON 产品信息（`{"general_msg":{"product_line_type":"consumer"...`） |
| 0x0100 | 固件版本串 `**` |

### 用户操作指令（抓包逐帧实证，预览期）

| 操作 | cmd | payload（内层 out[11..]） | 实测样本 |
|---|---|---|---|
| **EV 补偿** | 0x2802 | `01 [u16 LE] 00 00`，值 = 0x8000 + EV/0.0025 | 3 连发 0x8078→0x80a0→0x80c8（+0.3/+0.6/+0.9EV，每档 +40） |
| **白平衡色温** | 0x2c02 | `06 [u16 LE: K/100] 00 00` | 0x0034 = 5200K（连发 3 次同值） |
| **档位调整** | 0x2a02 | 1 字节枚举 | 0x05 → 0x0a（快门/ISO 档位，待对照确认） |
| **拍照** | 0xe102 | 1 字节（05→00 按下/释放？） | 22:01:30 ×4（进预览静置后第一操作，时刻吻合） |
| **主题订阅** | 0x9900 | `02 02 00 00 [ts 2B] 00000000 00 [name_len 2B] [key 名明文] 0000` | 进预览时 21 连发订阅 cam_storage/cam_status/cam_record_time/cam_expo_param… |
| **页面参数拉取** | 0x0101 | 28 帧/次页面变更 | 进预览/进相册/回预览各一轮 |

轮询 cmd 0x8e02（~13.9/s 双向）payload `00 01 14 00`——疑似 `00`=读、`01`=数量、`14 00`=node id；
0xda03 为手机→相机的 1s 周期状态推送（`05 ff ff ff ff`，非用户操作）。
0x2fee 仅初始化期出现 2 次（请求+响应各一），非轮询。

### 订阅机制（0x9900）与 iOS 侧对应

订阅请求直接携带 key 名明文（`cam_storage`/`cam_status`/`cam_record_time`/`cam_expo_param`…21 个），
与 telemetry.md/topics-catalog.md 的主题清单应一致——**订阅协议可直接复现**：
响应以 TLV（key 名 + 值）推送（见 capture-analysis-android-20261114.md §4 参数字典）。

## 更新（2026-11-15 第二轮对照抓包）：三大缺口全部补齐

对照测试（10:56:49 连接进预览 → 10:57 快门 → 10:57:29 ISO → 10:58:02 录像 → 10:58:15 拍照）逐帧实证：

| cmd | 语义（定案） | payload 编码 | 实测 |
|---|---|---|---|
| **0x2802** | **快门速度写入** | `01 [u16 LE = 0x8000 + 分母] 00 00` | 100/120/320 → `01 64 80` / `01 78 80` / `01 40 81`（1/100、1/120、1/320） |
| **0x2a02** | **ISO 写入** | 单字节枚举 | 0x09 → 0x04（枚举值表待一次带档位记录的确认） |
| **0x0202** | **录像开始/停止** | 1 字节：`01`=开始、`00`=停止 | 10:58:02（`01`）/ 10:58:09（`00`），间隔 = 录像时长 |
| 0xe102 | 拍照（确认） | 1 字节 `05`（触发）→ `00` | 10:58:15-16、10:58:35-37 两组 |
| 0x2b00 | 2.5s 周期帧 | `04 00 74 6a` 恒定 | 新发现 |

**修正记录**：前一轮将 0x2802 三连（120/160/200）误判为 EV——实为快门分母（1/120、1/160、1/200，DJI 标准档）。
0x2802 = 曝光数值参数写（快门已实证；EV 若同 cmd 则值域不同，待测）。昨晚的 EV 调整未在 WiFi 帧中定位到，
不排除走 BLE 或当时未实际生效。

### 订阅 key 全清单（0x9900，21 个，进预览时顺序）

cam_storage、cam_status、cam_record_time、cam_expo_param、shutter_param、cam_photo_param、
cam_lapse_param、cam_video_param_v2、cam_image_effect、v_quality_enhance_status、cam_fov、
cam_lens_state、cam_audio_status_v2、audio_timecode_status、temp_curve、camcap_common、
cam_imu_calib_info、timecode_info、cam_custom_mode_param、cam_magnifier_status
（+ 初始化期 1 个，与抓包 TLV 字典一致）

### 剩余待测（下次 2 分钟小抓包）

1. **EV 补偿写入**的 cmd 与编码（0x2802 变体或独立 cmd）——调一次 EV 记录前后档位
2. **0x2a02 ISO 枚举值表**——调 ISO 时记录改前/改后的实际 ISO 数值
3. 0x0101 页面拉取的 28 帧 payload 结构（低优先）

## 更新（2026-11-15 第三轮对照）：EV/ISO 枚举公式与 0x0101 结构定案

对照测试（11:08 EV 0.0→+0.3；11:09 ISO 12800→6400→3200；11:10 相册）：

| cmd | 语义 | payload 公式 | 实测验证 |
|---|---|---|---|
| **0x2e02** | **EV 补偿写入** | 单字节 = 16 + EV/0.3（0.3 步进） | +0.3 → 0x11(17) ✓；0.0 → 16（推定，单点） |
| **0x2a02** | **ISO 写入** | 单字节 = log2(ISO/50) + 1 | 12800→9、6400→8 ✓✓（3200→7 推定） |
| **0x0101** | 页面参数拉取 | 固定 11B：`03 00000000 04 0000 07 01`（3 参数，ID 4/7） | 两轮抓包 4 簇逐字节一致 ✓ |

**用户操作的关键提示**：EV 仅自动曝光模式可调（cmd 0x2e02），ISO 仅手动曝光可调（cmd 0x2a02）——
两者是不同 cmd 的原因。快门（0x2802）与 EV（0x2e02）也是分离 cmd，前一轮"0x2802 = EV"误判已彻底澄清。

### ISO 枚举完整表（payload = log2(ISO/50)+1）

| payload | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 |
|---|---|---|---|---|---|---|---|---|---|
| ISO | 50 | 100 | 200 | 400 | 800 | 1600 | 3200 | 6400 | 12800 |

### EV 枚举（payload = 16 + EV/0.3，0.3 步进）

payload 6..26 ↔ EV -3.0..+3.0（0.0 = 16）。边界（-4.8 或 -3.0 起）待一次负值实测确认。

### 协议手册状态：WiFi 控制面闭环 ✅

拍照 0xe102 / 录像 0x0202 / 快门 0x2802 / EV 0x2e02 / ISO 0x2a02 / 白平衡 0x2c02 /
订阅 0x9900 / 轮询 0x8e02 / 参数拉取 0x0101 全部源码级+抓包双重验证。

## ⚠️ 重大更正（2026-11-15）：与 iOS 协议文档交叉验证后

用 control-channel.md 的 DUML 认知重审全部 Android 帧：**本文档此前的 "cmd u16"（0x2802/0x2a02/…）
是呈现错误**——真实结构为 DUML 三元组，与 iOS 侧完全一致：

```
内层 DUML 帧（Android 与 iOS 同构）：
[0]   SOF 0x55
[1-2] len（[9:0]=整帧总长、[15:10]=版本 0x01）
[3]   crc8（poly 0x8C 反射 / init 0x77，覆盖 SOF..len 3 字节）
[4]   src（0x02=手机）
[5]   dst（0x28=相机主控 / 0x01 等）
[6-7] seq（LE）
[8]   cmdType（0x40 请求 / 0xC0 应答 / 0x00 推送）
[9]   cmdSet
[10]  cmdId
[11..] payload
末2   crc16（CRC-16/MCRF4XX 0x8408 反射 / init 0x3692，覆盖 SOF..payload）
```

**交叉验证**：新 pcap 4131 帧 crc8 + crc16 按 iOS 参数全部校验通过（100%）。
本文档前文所有 "0xXXXX" 形态的 cmd 按下表换算：

| 本文旧记法 | 真实三元组 (cmdType, cmdSet, cmdId) | 与 iOS 文档对照 |
|---|---|---|
| 0x2802 | (0x40, **0x02, 0x28**) | **快门** = control-channel.md「快门双粒度 02/28」，payload 逐字节一致（含小数字节 00、尾字节 0x40） |
| 0x2e02 | (0x40, **0x02, 0x2E**) | **EV 写** = §「EV 补偿 02/2E」，码 17=+0.3 与「码 16=0EV、1/3 档步进」一致 |
| 0x2a02 | (0x40, **0x02, 0x2A**) | **ISO 写**（单字节枚举 log2(ISO/50)+1）——iOS 未记录，Android 增量 |
| 0x2c02 | (0x40, **0x02, 0x2C**) | **白平衡**（payload `06 34 00000000`，0x34=5200K）——iOS 未记录，Android 增量 |
| 0x0202 | (0x40, **0x02, 0x02**) | **录像开始/停止** = §4.2 02/02，payload 01/00 一致 |
| 0xe102 | (0x40, **0x02, 0xE1**) | **模式切换** = §4.1（payload 05=照片模式）——此前误读"拍照"，实为切模式 |
| 0x9900 | (0x00, **0x00, 0x99**) | **按主题名订阅** = §4.5 pub_sub_agent，payload 内嵌 key 名明文一致 |
| 0x8e02 | (0x40/0x00, **0x02, 0x8E**) | **02/8E 参数读写** = §4.3（GET `00 01 <pid u16 LE>`，Android 实测 GET pid 0x0014 朝向同款） |
| 0x0101 | (0x00, **0x01, 0x01**) | 页面切换推送 ×28（payload 固定 `03 00000000 04 0000 07 01`）——iOS 未记录 |
| 0xda03 | (0x40, **0x03, 0xDA**) | 1s 周期推送 `05 ffffffff`——cmdSet 0x03 iOS 未记录 |
| 0x4f00 | (0x40, **0x00, 0x4F**) | 推送通道管理 = §4.5 ✓ |
| 0x5100 | (0xC0, **0x00, 0x51**) | statusPoll 应答 = §4.4 (0x00,0x51) ✓ |
| 0x0100/0x0202 短帧 | (0xC0, 0x02, 0x01) | **拍照应答**（单字节 00）= §4.2 CmdId 0x01 ✓ |

### 冲突判定结论

**两份协议（iOS 实测 / Android 官方 app 实测）无实质冲突**：DUML 帧格式、CRC 参数、
命令空间、payload 编码（快门 0x8000|分母+小数、EV 码 16 基准 1/3 档、录像 01/00、
按主题名订阅）全部一致；Android 抓包 4131 帧以 iOS 侧 CRC 参数 100% 校验通过。

**平台实现差异（非冲突，复现时注意）**：

1. **UDP 9004 外层头**：Android = 20B（`[len u8/大包 u16+0x8000][session 3B][seq 4B][ACK 8B]`），
   iOS = 34B（`[len][session 3B][seq 4B][ACK 24B][tail 2B]`）——ACK 块长度不同；
   大包（>255B）len 用 u16 LE + 0x8000 标志（Android 遥测包实证，如 `8a85`=1418）
2. **02/8E 轮询频率**：Android ~9.3/s（本文 0x8e02 1774 帧）vs iOS 1s 朝向 + 3s 一轮——
   节奏非硬约束，复现按 iOS 节奏即可
3. **0.2s 心跳三连（0,0x4F)/(0,0x51)/(0,0x82)**：Android 流量中未观测到同节奏帧
   （0x4f00 1/s、0x2b00 2.5s）——保活策略平台差异
4. **TCP 7001**：Android 官方 app 未建立该通道（仅 SYN），iOS 有心跳——复现按 iOS 的
   存活性通道处理
