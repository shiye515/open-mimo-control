# Tasks

## 1. 订阅扩容与推送解析

- [x] 1.1 `OSMOCameraLink`：订阅数组扩为 20 主题（cam_status、cam_record_time、cam_storage、cam_fov、cam_photo_param、cam_lapse_param、cam_video_param_v2、cam_expo_param、cam_lens_state、cam_image_effect、shutter_param、camcap_common、cam_custom_mode_params、cam_magnifier_status、v_quality_enhance_status、cam_audio_status_v2、audio_timecode_status、timecode_info、temp_curve、cam_imu_calib_info），验证：单测断言订阅帧序列含全部主题名
- [x] 1.2 快照新增 `recordSeconds: UInt32?` 与 `rawTopicSamples: [String: String]`；`parseTopicPush` 新增 `cam_record_time` 解析（u32 秒 @0）与未确认主题原始 hex 记录（值变化才更新），验证：单测用 mimo-ios 实测推送帧构造 golden 样例（cam_record_time 递增序列 3 帧）
- [x] 1.3 界面消费：REC 计时与状态详情取 `recordSeconds ?? clipSeconds`；诊断面板新增「未知信号」区（未解析主题最新值 + pid 0x000A/06/15/18/20/28/29 回读值），验证：构建通过 + 诊断面板可见

## 2. 00/76 事件反馈

- [x] 2.1 `OSMOStatus.handle` 新增 `case (0x00, 0x76)`：跳过长度头后提取 JSON `event_id`（fw_0100_action_result / record_info / lapse_info / capture_info），事件映射入 StepLogger（信息级），验证：单测用抓包事件 JSON 构造 4 种样例
- [x] 2.2 失败事件轻提示：action_result 含失败标志时经既有 toast 通道反馈，验证：单测 + 真机拍照失败场景（可选）

## 3. 00/4A 相机对时

- [x] 3.1 `OSMOControl` 新增 `setCameraClock(date: Date)`（载荷 `[年 u16 LE, 月, 日, 时, 分, 秒, 毫秒 u16 LE]`）并接入连接完成钩子（对时一次），验证：单测断言载荷字节（用固定 Date 构造 2026-10-19 19:52:36+480ms 对齐抓包帧 `ea070a13133424e001`）+ 真机日志可见 ACK

## 4. pid 0x000A 诊断定位

- [x] 4.1 快照新增 `rawParam0A: UInt8?`（parseParameterReply 新 case）；值翻转时经 onLog 打 `[diag] pid 000A → <val>` 诊断日志，验证：单测（01→00 翻转产生日志）
- [ ] 4.2（待真机配合：诊断日志已就位，按上述流程执行 tcpdump 对照）真机定位实验：按脚本执行「进出素材页 / 录制启停 / 切模式」并 tcpdump 同步抓包，对照翻转日志确定 0x000A 语义，结论回写 control-channel.md 与本 change（定位成功则补 spec；不可定位则保持诊断观测并记录证据）

## 5. 验证与收尾

- [x] 5.1 全量 `swift test`（新增单测全绿，既有 60+ 不回归）+ `openspec validate --strict`
- [ ] 5.2（待真机配合：App 已装机，逐项核验需相机在场）真机端到端：订阅应答日志 20 条全可见 → 录制 5 秒验证 cam_record_time 推送驱动 REC 计时 → 拍照验证 00/76 事件日志 → 连接日志可见对时 ACK → 诊断面板未知信号区展示
- [x] 5.3 文档回写：control-channel.md「命名主题」节补 20 主题清单与 cam_record_time 布局；unknown-signals-report.md 标注已接入项
