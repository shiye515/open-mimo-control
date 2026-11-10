# Spec Delta

## Purpose

推送驱动的参数回读：视角（cam_fov 主题）与快门（shutter_param 主题）推送到达时更新快照，降低对 3s 轮询 GET 的时机依赖（轮询保留为兜底）；录制时长改由 cam_record_time 推送驱动。推送数据布局以抓包 diff 实测为准——已确认布局的主题立即接入解析，未确认布局的主题先原始记录（见 camera-connection delta）。

## ADDED Requirements

### Requirement: 推送驱动参数回读
当订阅主题推送携带某参数的有效数据（已确认布局且非全零占位）时，应用必须（SHALL）以推送值更新对应快照字段并刷新界面；推送缺失或布局未确认时，必须（SHALL）维持既有轮询回读路径作为兜底。两类来源更新同一快照字段时必须（SHALL）以最新到达者为准，不得互相回跳。

#### Scenario: 推送与轮询双源一致
- **WHEN** cam_fov / shutter_param 推送与 3s 轮询 GET 先后到达
- **THEN** 界面值随最新数据更新，无回跳闪烁；数据冲突时以时间靠后者为准

#### Scenario: 录制时长推送驱动
- **WHEN** cam_record_time 推送（u32 秒）到达
- **THEN** 预览角标 REC 计时与状态详情中的录制时长以推送值更新，停止录制后保留最终值
