# 状态遥测（telemetry）

> 实现目标：订阅相机状态主题、解析周期推送。全部主题名以明文 ASCII 在线上传输，
> 自描述协议。cmd 记法见 [duml-frame.md](duml-frame.md)。

## 1. 订阅（00 / 99）

会话建立后，App 对每个主题发一条订阅帧：**(cmdType 0x00, cmdSet 0x00, cmdId 0x99)，
dst = 0x28（相机主控）**。

### 订阅帧 payload（31B 形态，订阅 cam_status 样例）

```
02 02 00 00 | id u32 LE | 00 00 00 | rest u16 | nameLen u16 | 00 | <主题名> | 00×4
```

完整样例（订阅 cam_status，Android 官方 app）：

```
55 2a 04 9c | 02 28 | e6 a4 40 00 99 | 02 02 00 00 ef d5 00 00 00 00
0010 000a 00 "cam_status" 00000000 | crc
```

（iOS 侧样例 body 同构：`[40 00 99 02 02 00 00] [req_id] [00000000] [0010] [000a] 00 "cam_status" …`）

- **req_id**：自增；相机 ACK 回显该值
- 应答单帧：`00` = 已订阅、`01` = 无此主题（按序匹配）
- 订阅必须主动发起（会话建立后一次 21 帧），**相机重启前持续有效，重复订阅无副作用**
- 完整订阅风暴在连接后 0.2s 内连发 21 帧

## 2. 推送帧

推送同样承载于 0x55 帧（cmdType 0x00，cmd 随主题相关的会话句柄），body 内嵌主题名：

```
02 06 00 00 | seq u16 | 00×5 | rest u16 | nameLen u16 | <主题名> | 00×6 | dataLen u16 | <data>
```

- **OA4 特性：周期性全量推送**（~2-4s/主题错峰），非"仅变化时推送"——
  值变化只体现在 data 内容层
- 明文自描述：解析器按主题名分发，无需硬编码 cmd 映射

## 3. 主题清单与推送频率（21 key 实测）

| 主题 | 推送频率（Android 实测包数/107,888 S2C 包） | 数据段布局状态 |
|---|---|---|
| cam_record_time | 1127（高频 4.4/s） | ✅ u32 秒 @0 |
| cam_audio_status_v2 | 1127 | ✅ 电平表 |
| cam_imu_calib_info | 1127 | 恒定 |
| cam_status | 566（2.2/s） | ✅ 9B 状态帧 |
| cam_storage | 564 | ✅ 22B |
| cam_expo_param | 564 | ✅ 41B 全字段 |
| shutter_param | 564 | 恒零（无动态信息） |
| cam_photo_param | 564 | ⏳ @11 倒计秒待复核 |
| cam_lapse_param | 564 | ✅ |
| cam_video_param_v2 | 564 | ✅ @0/@1（@4/@8 待定） |
| cam_image_effect | 564 | ✅ 色彩/降噪/锐度 |
| v_quality_enhance_status | 564 | 恒 00 |
| cam_fov | 564 | ◐ 读出区宽高（@12-13 待定） |
| cam_lens_state | 564 | ✅ lens ÷126 |
| audio_timecode_status | 564 | 恒 00 |
| cam_custom_mode_param | 564 | 结构已见语义待定 |
| cam_magnifier_status | 564 | 恒定 |
| timecode_info | 228 | ◐ @5 会话秒 |
| temp_curve | 227 | 恒定 |
| camcap_common | 2 | 一次性能力帧 |
| camcap_iso 等 camcap_* | 0 | ❌ 订阅应答 01（OA4 不支持逐项） |

## 4. 已实锤值结构（重点主题）

### cam_status（9B 紧凑状态帧）

`@0` 状态位图（08 写文件/10 录制/80 特殊模式）· `@3` 管线标志（0 视频/1 照片系/7 特殊）
· `@4` captureMode（与 02/E1 同码：00 照片/01 视频/02 慢动作/05 延时/0A 直播）
· `@7` 录制状态（0 待机/1/2/3 录制中）· `@6` 心跳翻转位。
旧版 9B 解读（+1 模式/+2 目标模式/+4 变焦档/+5 子状态）为 iOS 侧不同固件版本观测。

### cam_record_time（6B）

`u32 秒 @0 + u16 保留`——录制中逐秒递增、停止归 0。**REC 计时首选来源**。

### cam_expo_param（41B 固定布局，全字段实锤）

| 偏移 | 内容 |
|---|---|
| @2-3 | 拍照快门 u16（0x8000\|分母，拍照子系统） |
| @6 | **EV 补偿码**（码 16=0EV、1/3 档；各模式独立记忆，全模式直读） |
| @7 | 曝光模式标志（1=自动 / 4=手动） |
| @11 | 生效 ISO 标准档位码（手动恒 00） |
| @15 | 测光 EV 码（画面偏离 0EV 程度） |
| @16-17 | 生效 ISO u16（AE 实时增益；手动=设定值；受 ISO MAX 钳制） |
| @20-22 | 视频/预览快门三元组（0x8000\|分母 u16 + 小数字节，与 02/28 同构） |
| @33-35 | 数字增益 u16 + 十分位 |

曝光三参数联动（自动模式）：ISO 在 [100, ISO MAX] 细步进 → 触顶后快门接棒
（视频上限 1/25s）→ 双触顶后数字增益延伸。白平衡/色彩/Pro/弱光/变焦**不在此流中**
（各走独立命令/主题）。字段地图与实验证据链见
[protocol-raw/cam-expo-param.md](../protocol-raw/cam-expo-param.md)。

### cam_video_param_v2（10B）

`@0` 分辨率码、`@1` 帧率码（码表见 [commands.md](commands.md) §11）——
分辨率/帧率变化的读取通道（02/19 轮询已退役）。

### cam_storage（22B）

`@10-13` 剩余可录秒 u32（录制递减；慢动作 ~16× 消耗）· `@14-16` 剩余可拍张数 u24
（分模式重算）· `@18-19` 剩余可录量 u16（按当前模式码率折算）。

### cam_lens_state（47B）/ cam_fov（16B）/ cam_audio_status_v2（114B）

- cam_lens_state：`@14-15` lens u16（÷126）、`@12-13` 同源变焦位置副本
- cam_fov：`@0-3/@4-7` 读出区宽/高 u32（待机 4:3 形 2413×1809 / 录制 16:9 形
  4596×2585 / 夜景 2394×1350）；`@8` 管线标志；`@12-13` 变化域（待定）
- cam_audio_status_v2：`@3/@7/@9` 三通道实时电平（0x64=满）

## 5. 订阅与轮询的分工（重要）

- **有推送主题的状态一律用订阅**（本次 21 key 覆盖全部遥测需求）——
  02/8E GET 轮询仅用于**无推送主题**的参数（朝向 0x0014、EIS 0x0008、
  ISO MAX 0x000F、Pro 0x0000、弱光 0x0030 等）
- 两类机制互补：推送是周期性全量（OA4），轮询是按需点名
- camcap_* 能力表主题 OA4 实测仅 camcap_common 推送一次（能力值域不可
  从相机自描述，档位表需按机型硬编码——见 commands.md 各码表）

## 证据

- [protocol-raw/telemetry.md](../protocol-raw/telemetry.md)（订阅/推送帧格式、值结构、电量主题调查）
- [protocol-raw/topics-catalog.md](../protocol-raw/topics-catalog.md)（20 主题布局定稿，31,118 帧矩阵）
- [protocol-raw/cam-expo-param.md](../protocol-raw/cam-expo-param.md)（41B 字段地图与受控实验）
- [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md)（Android 订阅风暴与推送频率实证）
