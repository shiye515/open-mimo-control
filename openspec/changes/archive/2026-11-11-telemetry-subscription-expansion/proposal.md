# Proposal

## Why

深度审计（unknown-signals-report.md）发现：官方 Mimo 订阅 20 个命名主题（推送 ~8663 帧/30min），本仓库仅订阅并解析 6 个；14 个未解析主题中含高价值信号——cam_fov（FOV 推送，可替代 0x0009 轮询）、cam_record_time（录制秒数推送，可替代 02/80 内轮询位）、shutter_param（快门推送）、temp_curve（温度曲线）、camcap_common（能力表，含倒计时档位）。同时抓包显示 00/76 JSON 事件（拍照/录制动作结果）与 00/4A 相机 RTC 对时命令三方均未利用。实时性差距：FOV/快门当前依赖 3s 轮询，推送驱动可将同步延迟降到亚秒级。

## What Changes

- 00/99 订阅扩容：6 → 20 主题（补 cam_fov、cam_record_time、shutter_param、cam_photo_param、temp_curve、camcap_common、cam_status、cam_storage、cam_video_param_v2、v_quality_enhance_status、audio_timecode_status、timecode_info、cam_custom_mode_params、cam_magnifier_status、cam_audio_status_v2、cam_imu_calib_info）
- 解析新增主题推送：cam_fov（视角回读推送）、cam_record_time（录制秒数）、shutter_param（快门回读推送）、cam_photo_param（照片参数含倒计时）、temp_curve（温度曲线）、camcap_common（能力表，含倒计时档位）；布局以 mimo-ios.pcap 推送数据 diff 实测为准（design 附录记录）
- 00/76 JSON 事件接入：解析 `event_id`（fw_0100_action_result / record_info / lapse_info / capture_info）作为拍照/录制/延时动作结果反馈源（StepLogger 记录 + 失败 toast）
- 00/4A 相机 RTC 对时：连接成功后下发手机时间（载荷 `[年 u16 LE, 月, 日, 时, 分, 秒, 毫秒 u16 LE]`，2026-10-19 19:52:36+480ms 抓包实锤）
- pid 0x000A 定位：诊断面板新增该 pid 值实时显示，配合操作时序（进出素材页/录制启停）记录翻转日志，抓包对照
- 相应减少轮询依赖：cam_fov/shutter_param 推送到达后不再依赖 3s 轮询 GET 0x0009 / 02/29 的回读时机（轮询保留作兜底）

## Capabilities

### New Capabilities

<!-- 无新增能力边界：全部落入既有 capability -->

### Modified Capabilities

- `camera-connection`——订阅清单扩容（00/99）、00/4A 对时、00/76 事件反馈、pid 0x0A 诊断
- `control-screen`——推送驱动回读（cam_fov/cam_record_time/shutter_param 替代轮询时机）、温度曲线展示（诊断面板）
