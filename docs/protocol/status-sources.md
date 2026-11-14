# App 状态位信息来源表（status-sources）

> 2026-11-14 整理。对应实现：`OSMOStatus.swift`（解析）、`OSMOCameraLink.swift`（通道）、
> `ControlScreenView.swift`（消费）。字段语义详见 `cam-expo-param.md` 与 `topics-catalog.md`。
> 三类来源：**订阅推送**（00/99 主题，~2.5s 周期全量）、**命令应答**（轮询/按需查询）、
> **BLE**（保活/电量缓存）。

## 1. 主表：App 状态位 → 来源通道 → 解析方法

### 1.1 录制与模式

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 录制状态（空闲/启动/录制/停止） | `recordState` | 02/80 推送 | b[0] >> 6（2 bit） | ~10/s |
| 正在写文件 | `isWritingFile` | 02/80 推送 | b[2] & 0x08 | 同上 |
| 拍摄模式（视频/照片/慢动作/延时/运动延时/夜景） | `captureMode` | 02/80 推送 | b[57]（02/E1 同码） | ~10/s（cam_status 9B 主题 @4 为冗余源，未接线） |
| REC 计时（已录秒） | `recordSeconds` | **cam_record_time 推送** | u32 LE @0 | 逐秒递增（02/80 u32@29 clipSeconds 为兜底） |
| 录音电平（未接线，诊断原始 hex） | — | cam_audio_status_v2 推送 | @3/@7/@9 三通道电平（0x64=满） | ~2.5s |

### 1.2 存储（02/80 + BLE 推送）

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 存储总量 / 剩余 | `totalStorageMB` / `freeStorageMB` | 02/80 推送 | u32 LE @5 / @9（回放时读 0 保留上次非零） | ~10/s |
| 剩余可拍张数 / 可录秒数 | `photosLeft` / `videoSecondsLeft` | 02/80 推送 | u32 LE @13 / @17 | 同上 |
| SD / 内置存储明细 | `sdTotalMB` 等 | 02/DC 帧（datalink；BLE 侧 ~2Hz 推送仅日志未解析，22B 与 cam_storage 主题同构） | @6/@10/@24/@28 u32 LE，回放时读 0 保留上次非零 | 触发时机未定（总量/剩余以 02/80 为准） |

### 1.3 电池

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 电量 % / 电压 mV / 电流 mA / 温度 0.1°C | `batteryPercent` 等 | 0D/02 推送 | @20 u8 / @1 s32 / @5 s32 / @17 u16 | ~1/s |
| 连接页电量缓存 | — | BLE 广播/查询 | 后台 3 轮×4s 扫描刷新（直连场景无 BLE 电量推送） | 连接时 |

### 1.4 曝光（cam_expo_param 41B 固定布局，见 cam-expo-param.md）

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| EV 补偿 | `expoCompValue` | cam_expo_param 推送 | u8 @6（各模式独立记忆；码 16=0EV） | ~2.5s |
| 曝光模式（自动/手动） | `exposureMode` | cam_expo_param 推送 | u8 @7（1 自动/4 手动，同 02/1F 编码）【替代 02/1F 轮询】 | ~2.5s |
| 生效 ISO | `effectiveISO` | cam_expo_param 推送 | u16 LE @16（模拟增益分量；自动受 ISO MAX 钳制/手动=设定值） | ~2.5s |
| ISO 档位码 | `isoStepCode` | cam_expo_param 推送 | u8 @11（自动；手动恒 0） | ~2.5s |
| 生效快门（含小数） | `effectiveShutter` | cam_expo_param 推送 | @20-21 u16 + @22 小数字节<<16（=shutterRaw 同构）【替代 02/29 轮询】 | ~2.5s |
| 拍照快门 | `photoShutter` | cam_expo_param 推送 | u16 LE @2（拍照子系统 AE） | ~2.5s |
| 测光 | `lightMeterValue` | cam_expo_param 推送 | u8 @15（EV 同编码） | ~2.5s |
| 数字增益 | `digitalGain/Fine` | cam_expo_param 推送 | @33-34 u16 + @35 十分位 | ~2.5s |
| 用户 ISO 档位码（手动滚轮定位） | `isoCode` | cam_expo_param 推送 | @7 门控 + @16-17 按档位表反查（手动=设定值精确映射、自动=00）【02/2B 轮询退役】 | ~2.5s |

### 1.5 图像 / 视频 / 变焦

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 视频分辨率 / 帧率 | `videoResolutionCode` / `videoFpsCode` | cam_video_param_v2 推送 | u8 @0 / @1【替代 02/19 轮询；02/19 仅存前台存活探测】 | ~2.5s |
| 色彩档位 | `colorProfile` | cam_image_effect 推送 | u8 @2 | ~2.5s |
| 锐度 / 降噪 | `sharpness` / `denoise` | cam_image_effect 推送 | s8 @15 / @14 | ~2.5s |
| 变焦倍率 | `zoomFactor` | cam_lens_state 推送 | u16 LE @14 ÷ 126 | ~2.5s |
| 竖拍模式 | `portraitMode` | cam_portrait_mode 推送 | u8 @0 != 0 | ~2.5s |

### 1.6 02/8E 参数 TLV（轮询家族，均不在任何订阅主题中）

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 视角 FOV | `fovValue` | 02/8E GET pid 0x0009 | 应答值 [6]（码表 fovModes） | 3s 轮询 |
| 电子增稳 EIS | `eisValue` | pid 0x0008 | 同上（eisModes） | 3s 轮询 |
| ISO 上限 | `isoMaxCode` | pid 0x000F | 同上（isoMaxSteps） | 3s 轮询 |
| Pro 模式 | `proOnCode` | pid 0x0000 | 同上（01/00） | 3s 轮询 |
| 弱光增稳 | `lowLightCode` | pid 0x0030 | 同上（01/00，仅视频模式） | 3s 轮询 |
| 相机朝向 | `orientationCode` | pid 0x0014 | 3B 值 [0, 朝向, 0]，象限@7（**1s 快轮询**，预览方向跟随） | 1s 轮询 |
| pid 000A 翻转（诊断） | `rawParam0A` | pid 0x000A | 值翻转日志（语义未知） | 3s 轮询 |
| 未知 pid 原始回读（诊断） | `rawParams` | pid 0018/0020/0029 | hex（归因：noteParameterRequest） | 3s 轮询 |

### 1.7 白平衡 / 照片格式（命令应答）

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 白平衡模式 / 色温 | `wbMode` / `wbKelvin` | 02/2D 查询 | `00 <mode> <kelvin/100 u16>` | 3s 轮询 |
| 照片格式（尺寸/比例） | `photoSizeCode` / `photoRatioCode` | 02/13 查询 | `00 <size> <ratio>`（**仅照片模式轮询**，其他模式 DF） | 3s 轮询（照片模式） |

### 1.8 延时 / 运动延时

| 状态位 | 快照字段 | 通道 | 解析方法 | 更新节奏 |
|---|---|---|---|---|
| 保存类型 / 间隔 / 时长 / 速率 | `lapseKeep` 等 | cam_lapse_param 推送 | keep u8 @0、间隔 u16 @1（0.1s）、时长 u32 @5、速度 u16 @9 | ~2.5s |

### 1.9 事件 / 系统

| 状态位 | 来源 | 解析方法 | 备注 |
|---|---|---|---|
| 固件动作事件（失败 toast） | 00/76 推送 | JSON `event_id` + `is_success` | 4 种 event_id |
| 相机 RTC | 00/4A 写 | 连接后下发一次手机时间 | 非状态读取 |
| 订阅生效确认 | 00/99 应答 | 00=已订阅 / 01=无此主题 | 逐条按序匹配 |
| 查询错误表 | 各应答首字节 | E0/E3/DF/D8 → `queryErrors` | 诊断面板展示 |
| 网格 / 画幅等本地项 | UserDefaults | App 本地叠加/记忆 | 非相机状态 |

## 2. 当前轮询清单（sendStatusQueries，3s 一轮 / 0.3s 间隔）

| 查询 | 模式条件 | 用途 |
|---|---|---|
| 02/2D 白平衡 | 全模式 | 滚轮定位（wbMode/kelvin） |
| 02/8E GET ×5 | 全模式 | FOV / EIS / ISO MAX / Pro / 弱光 |
| 02/8E GET ×4 | 全模式 | 诊断 pid 000A / 0018 / 0020 / 0029 |
| 02/13 照片格式 | 仅照片模式 | 滚轮定位 |


另有：02/8E pid 0x0014 朝向 1s 快轮询；02/19 仅前台返回存活探测。已退役数据轮询（全部由订阅推送接管）：02/19 视频格式 → cam_video_param_v2；02/1F 曝光模式 → @7；02/29 快门 → @20-22；02/2B ISO 档位码 → @16-17 反查。

## 3. 未接线的订阅主题（信息源已确认，见 topics-catalog.md）

cam_status 9B（冗余）、cam_fov（zoom 冗余/读出区无消费方）、timecode_info（REC 计时冗余）、
cam_storage（02/80 覆盖）、cam_audio_status_v2（电平表 UI 未做）、shutter_param（待实验）、
camcap_common（不可黑盒破译）、cam_custom_mode_params / cam_magnifier_status /
v_quality_enhance_status / temp_curve / cam_imu_calib_info / audio_timecode_status（恒定/待实验）。
