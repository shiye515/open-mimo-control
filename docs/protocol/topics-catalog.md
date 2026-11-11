# 00/99 命名主题总目录（含非 OA4 机型）

> 2026-11-11 整理。来源：OA4 抓包实测（7 个 pcap，31,118 帧）+ osmo-client PROTOCOL.md
> §8.3/§8.4 + osmocam PROTOCOL.md §8.3/§8.4 + 官方 Mimo 订阅清单（抓包观测）。
> 订阅机制：`00/99 → 0x28`，载荷 `02 02 00 00 <id u32 LE> 00 00 00 <rest u16> <nameLen u16>
> <主题名> 00×4`；应答 00=已订阅 / 01=无此主题；推送帧布局 `02 06 00 00 <seq u16> 00×5
> <rest u16> <nameLen u16> <主题名> 00×6 <dataLen u16> <data>`。
> OA4 特性：**周期性全量推送**（~2-4s/主题错峰），非"仅变化时推送"（Nano 文档描述不适用 OA4）。

## 1. 状态推送主题（20 个，OA4 观测全集 = 官方 Mimo 订阅全集）

| # | 主题 | OA4 推送 | 数据段布局 | 解析状态 |
|---|---|---|---|---|
| 1 | cam_status | ×450 | 同 02/80（60B），复用 parseCameraStatus | ✅ 已实现（复用） |
| 2 | cam_record_time | ×826 | u32 秒 @0 + u16 保留（录制中逐秒递增，39 变化） | ✅ 已解析（REC 计时推送驱动） |
| 3 | cam_storage | ×415 | 录制写入时容量更新；与 02/DC 命令同源 | ✅ 02/DC 命令覆盖 |
| 4 | cam_fov | ×415 | 16B：u32×4 `[A, B, 0/1, 12600]`，A/B 随分辨率变（疑似传感器有效区） | ⏳ 原始记录待 diff |
| 5 | cam_photo_param | ×426 | 13B，offset 11 变化（01/05/04/03，疑似倒计时相关） | ⏳ 原始记录待 diff |
| 6 | cam_lapse_param | ×415 | @0 保存 / @1-2 间隔 u16 (0.1s) / @5-8 时长 u32 / @9-10 速率 u16 | ✅ 已解析 |
| 7 | cam_video_param_v2 | ×414 | 布局未解码（三方也无） | ⏳ 原始记录待 diff |
| 8 | cam_expo_param | ×415 | @6 EV 补偿 / @15 测光 / @16 ISO u32 / @20 快门 u16 | ✅ 已解析 |
| 9 | cam_lens_state | ×415 | @14 lens u16，÷126 = 变焦倍率 | ✅ 已解析 |
| 10 | cam_image_effect | ×414 | @2 色彩 / @14 降噪 s8 / @15 锐度 s8 | ✅ 已解析 |
| 11 | shutter_param | ×414 | 16B 全零（会话未动快门） | ⏳ 原始记录 |
| 12 | camcap_common | ×2 | 10B `010700030b0010011103`（疑似 [能力id, 值] 对） | ⏳ 原始记录 |
| 13 | cam_custom_mode_params | ×414 | 未解析 | ⏳ 原始记录 |
| 14 | cam_magnifier_status | ×414 | 未解析 | ⏳ 原始记录 |
| 15 | v_quality_enhance_status | ×414 | 未解析 | ⏳ 原始记录 |
| 16 | cam_audio_status_v2 | ×825 | 114B；录制时多通道电平字节实时跳动（@3/@6/@8 等，0x64=满值） | ✅ 语义确认（电平表），字段细分布局待 diff |
| 17 | audio_timecode_status | ×414 | 未解析 | ⏳ 原始记录 |
| 18 | timecode_info | ×168 | @11-13 时/分/秒（录制中递增，真机观测） | ✅ 语义确认，解析待接入 |
| 19 | temp_curve | ×166 | 3B `010202`（会话温度平稳） | ⏳ 原始记录 |
| 20 | cam_imu_calib_info | ×414 | 未解析 | ⏳ 原始记录 |

其余未解析主题已移入诊断面板「未知信号」区展示（原始 hex，值变化才更新）。

## 2. 能力表主题 camcap_*（osmo-client/osmocam §8.4；OA4 实测仅 camcap_common 活跃）

订阅后一次性推送能力值（Nano 文档描述；OA4 对逐项订阅一律应答 01，
**唯一观测到推送的是 camcap_common**，数据疑似 [能力id, 值] 对序列）：

| 主题 | 记录的内容 |
|---|---|
| camcap_base | 基础能力 |
| camcap_video_format | 支持的视频格式 |
| camcap_iso | ISO 档位 |
| camcap_iso_auto_max | 自动 ISO 上限 |
| camcap_shutter | 快门档位 |
| camcap_photo_size | 照片尺寸 |
| camcap_capture_aspect_type | 画幅类型 |
| camcap_wb | 白平衡档位 |
| camcap_exposure_mode | 曝光模式 |
| camcap_color_mode | 色彩档位 |
| camcap_fov | 视角档位 |
| camcap_eis | 增稳档位 |
| camcap_sharpness / camcap_denoise | 锐度 / 降噪（Nano: −2…+2 / −2…+1） |
| camcap_photo_timer_interval | 拍照倒计时档位 |
| camcap_timelapse_duration | 延时时长档位 |
| camcap_hyperlapse_ratio | 运动延时速率比 |
| camcap_countdown | 倒计时档位（u32 ms，与 OA4 实测 7 档吻合） |
| camcap_loop_video_duration | 循环录像时长（u16 s） |
| camcap_slowmotion_ratio | 慢动作倍速 |

> 价值：能力表是"值域自描述"通道——若能解析 camcap_* 推送，参数值域表（如
> isoCodes/shutterSpeeds）可直接从相机获取，无需硬编码。OA4 是否支持逐项订阅
> 待实验（此前枚举测试应答 01，但 camcap_common 证明至少部分存在）。

## 3. 已知非 OA4 / 其他机型主题与命令（记录备查，勿在 OA4 使用）

| 项 | 机型/场景 | 说明 |
|---|---|---|
| `camcap_capture_aspect_type` | Nano | 画幅类型能力 |
| `camcap_iso_auto_max` | Nano | 自动 ISO 上限能力 |
| `camcap_countdown` (u32 ms) | Nano | 倒计时能力 |
| `camcap_loop_video_duration` (u16 s) | Nano | 循环录像时长能力 |
| `camcap_slowmotion_ratio` | Nano | 慢动作倍速能力 |
| 色彩码 3D D-Log M / 3F Normal 10-bit / 17 D-Log / 41 D-Log2 | Nano/Pocket | OA4 色彩仅 00 普通 / 34 D-Log M |
| FOV 码 00 超广 / 05 自然广 | Nano/Pocket | OA4 的 00=超广 / 05 未观测 |
| `02/68` `04/4C` `04/50` `04/01` `04/05` | Pocket 3/4/4P 云台 | 会话/云台控制，OA4 不适用 |
| `02/09 [00×10 03]` | 实时画面源（osmo-client §5.6） | OA4 用 09/A8 → 0x41 |
| `02/BF` 收藏 / `00/28` 删除 | 媒体库 | OA4 实测删除用 00/28 ✓、02/BF 未验证 |

## 4. 订阅/推送机制要点（OA4 实测）

- 订阅必须主动发起（会话建立后一次性 20 帧 `00/99 → 0x28`），相机重启前持续有效，
  重复订阅无副作用；应答 00=已订阅 / 01=无此主题（按序匹配）
- 推送为**周期性全量**（~2-4s/主题错峰），非仅变化时推送；值变化只发生在数据内容层面
- 无推送的主题（PRO/ISO MAX/弱光增稳/朝向/增稳等 02/8E 参数）只能轮询——两类机制互补
- 订阅应答与推送均明文携带主题名，抓包可直接聚合
