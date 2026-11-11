# Spec Delta

## Purpose

遥测订阅扩容与推送驱动回读：00/99 订阅从 6 主题扩容到官方 Mimo 同款 20 主题，解析录制时长推送（cam_record_time），接入 00/76 固件动作事件作为拍摄反馈源，连接后下发 00/4A 相机 RTC 对时，并为未知参数 pid 0x000A 提供诊断观测。数据依据：unknown-signals-report.md（7 抓包 31,118 帧全量审计）。

## ADDED Requirements

### Requirement: 遥测主题订阅扩容
应用必须（SHALL）在会话建立后通过 `00/99` 订阅官方 Mimo 同款 20 个命名主题（cam_status、cam_record_time、cam_storage、cam_fov、cam_photo_param、cam_lapse_param、cam_video_param_v2、cam_expo_param、cam_lens_state、cam_image_effect、shutter_param、camcap_common、cam_custom_mode_params、cam_magnifier_status、v_quality_enhance_status、cam_audio_status_v2、audio_timecode_status、timecode_info、temp_curve、cam_imu_calib_info），订阅应答（00=已订阅 / 01=无此主题）按序记录到步骤日志。已确认布局的主题必须（SHALL）解析入快照；未确认布局的主题必须（SHALL）将原始数据段记录到诊断日志（值变化时节流），供后续抓包 diff 定位。

#### Scenario: 订阅应答全记录
- **WHEN** 会话建立后发出 20 个主题订阅
- **THEN** 每个主题的订阅应答（已订阅/无此主题）在步骤日志中按序可见

#### Scenario: 录制时长推送解析
- **WHEN** 收到 cam_record_time 主题推送（数据段 u32 秒 @0，2026-11-08 抓包实锤：录制中逐秒递增）
- **THEN** 快照的录制累计时长更新为推送值，与相机实际录制进度一致

#### Scenario: 未解析主题原始记录
- **WHEN** 收到尚未确认布局的主题推送（如 cam_fov 16B、shutter_param 16B、cam_photo_param 13B、camcap_common 10B）
- **THEN** 原始数据段在诊断面板可见（值变化时记录，不刷屏）

### Requirement: 相机 RTC 对时
应用必须（SHALL）在连接成功后通过 `00/4A`（02→28）下发一次手机当前时间，载荷为 `[年 u16 LE, 月, 日, 时, 分, 秒, 毫秒 u16 LE]`（2026-10-19 19:52:36 +480ms 抓包实锤：`ea07 0a 13 13 34 24 e001`）；发送结果记录到步骤日志。

#### Scenario: 连接后对时
- **WHEN** 连接流程完成（会话建立）
- **THEN** 应用发送 00/4A 对时命令，载荷编码手机当前本地时间，相机应答 ACK 记录到日志

### Requirement: 固件动作事件反馈
应用必须（SHALL）解析 `00/76` 推送中的 JSON `event_id`（fw_0100_action_result / fw_0100_record_info / fw_0100_lapse_info / fw_0100_capture_info），将事件记录到步骤日志；动作失败类事件必须（SHALL）以轻提示反馈用户。

#### Scenario: 拍照动作事件
- **WHEN** 相机推送 fw_0100_capture_info / fw_0100_action_result 事件
- **THEN** 事件类型记录到步骤日志；动作结果为失败时给出轻提示

### Requirement: 未知参数诊断观测
应用必须（SHALL）在诊断面板展示 02/8E 未解析参数 pid 的最新回读值（至少含 0x0006/0x000A/0x0015/0x0018/0x0020/0x0028/0x0029），并在 pid 0x000A 值发生 01↔00 翻转时记录一条带时间戳的诊断日志，供操作时序对照定位。

#### Scenario: pid 0x000A 翻转记录
- **WHEN** pid 0x000A 回读值发生 01↔00 翻转
- **THEN** 诊断日志新增一条翻转记录（时间戳 + 新值），与当时用户操作可对照
