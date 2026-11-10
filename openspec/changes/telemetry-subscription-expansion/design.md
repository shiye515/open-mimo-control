# Design

## Context

数据来源：unknown-signals-report.md（7 抓包 31,118 帧全量审计，2026-11-11）。
现状：`OSMOCameraLink.sendStatusQueries` 订阅 6 主题（cam_expo_param / cam_storage /
cam_video_param_v2 / cam_image_effect / cam_lapse_param / cam_portrait_mode），
`OSMOStatus.parseTopicPush` 解析其中 4 个（expo/image_effect/lapse/lens_state/portrait）；
官方 Mimo 订阅 20 主题，推送 ~8663 帧/30min。

## 主题数据段实测（mimo-ios.pcap diff）

推送帧布局（已实现）：`02 06 00 00 <seq u16> 00×5 <rest u16> <nameLen u16> <name> 00×6 <dataLen u16> <data>`。

| 主题 | dataLen | 数据段观测 | 结论 |
|---|---|---|---|
| cam_record_time | 6 | `N 00 00 00 00 00`（N=录制秒，39 次变化与录制启停对齐） | **布局实锤**：u32 秒 @0，u16 保留 @4 |
| cam_fov | 16 | u32×4 `[A, B, 0/1, 12600]`；A/B 比值 ≈ 流宽高比（2413/1809≈4:3、4794/2704≈16:9），尾值 12600=126×100（变焦单位） | 布局未定（疑似传感器有效区/校准），**先原始记录** |
| shutter_param | 16 | 全零（该会话未动快门） | 布局未定，先原始记录 |
| cam_photo_param | 13 | offset 11 变化（01/05/04/03） | 疑似倒计时相关，先原始记录 |
| temp_curve | 3 | 恒 `010202`（该会话温度平稳） | 布局未定，先原始记录 |
| camcap_common | 10 | `01 07 00 03 0b 00 10 01 11 03` | 疑似 [能力 id, 值] 对，先原始记录 |
| cam_audio_status_v2 | 114 | 多组 u8 电平（0x64=100 满值） | 音频电平表，低优先 |

cam_status（命名主题形式，×450）：内容与 02/80 推送同源，解析复用 `parseCameraStatus`。

## 设计决策

### D1 订阅清单常量化（20 主题）
`OSMOCameraLink` 的订阅数组从 6 项扩为 20 项（与 Mimo 全集一致）。理由：主题推送
仅在变化时推送（camcap_* 例外一次性），带宽数据实测 ~290 帧/min（短帧），开销可忽略。
订阅应答（00=已订阅/01=无此主题）已有按序匹配机制（`expectSubscriptionAcks`），直接扩容。

### D2 解析策略：已确认布局接入，未确认布局原始记录
- `parseTopicPush` 新增 `case "cam_record_time"`：dataLen≥4 时
  `snapshot.recordSeconds = u32(0)`（新快照字段；诊断面板与 REC 计时消费）。
- 其余新主题（cam_fov / shutter_param / cam_photo_param / temp_curve / camcap_common /
  cam_audio_status_v2 / cam_imu_calib_info / cam_status / cam_storage / v_quality_enhance_status /
  audio_timecode_status / timecode_info / cam_custom_mode_params / cam_magnifier_status）：
  `rawTopicSamples[theme] = data.hex()`（值变化才更新），诊断面板「未知信号」区展示。
  不做语义猜测解析——布局未实锤前猜测解析有脏状态风险。
- `parseCameraStatus`（02/80）不变；快照字段 `recordSeconds` 与既有 `clipSeconds` 并存，
  界面取 `recordSeconds ?? clipSeconds`（推送优先、轮询兜底，满足 control-screen delta）。

### D3 00/76 事件反馈
`OSMOStatus.handle` 新增 `case (0x00, 0x76)`：正则提取 `event_id`，映射到
StepLogger 记录（信息级）；`fw_0100_action_result` 的 JSON 内含失败标志时（实测样本含
`is_success` 类字段，实现时以真实 JSON diff 校准）以 toast 反馈。JSON 解析用
`JSONSerialization`（payload 为 UTF-8 JSON 文本，前缀 2 字节长度头需跳过——实测
`003000`/`006000` 头 + JSON）。

### D4 00/4A 对时
连接成功钩子（`ConnectionFlow` state → .success 后，或 onFlowCompleted 内）发送一次：
`00/4A → 0x28`，载荷 `[年 u16 LE, 月, 日, 时, 分, 秒, 毫秒 u16 LE]`（Calendar.current 本地时间）。
发送一次即止，不做周期同步（相机 RTC 断电保持）。结果（ACK 00）入 StepLogger。

### D5 pid 0x000A 诊断
- 快照新增 `rawParam0A: UInt8?`（parseParameterReply 新 case，单字节值 p[6]）。
- 诊断面板「未知信号」区显示 0x000A 当前值；`didSet` 式翻转检测在 statusTracker 内：
  值变化时通过 `onLog` 打一条 `[diag] pid 000A → <val>`（带时间戳）。
- 定位路径（实现后人工执行）：进出素材页 / 录制启停 / 切模式，对照翻转日志与 tcpdump。

### D6 轮询兜底保留
3s 参数轮询（GET 0x0009/0008/000F/0000/0030 + 02/19/1F/2B/29/2D）与 1s 旋转轮询全部保留。
推送到达即更新快照，轮询作为「推送丢失/订阅失败」的兜底，两类来源写同一快照字段（无回跳：
推送频率高于轮询，冲突时以时间靠后者为准，快照本身单调覆盖）。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 订阅扩容后推送洪泛刷爆诊断日志 | 原始记录仅值变化时写入；UI 侧按主题折叠展示最新值 |
| 未解析主题误解析出脏状态 | 未确认布局一律不写快照语义字段，只记原始 hex |
| 00/76 JSON 头格式误判（长度头实测 `003000`/`006000`） | 实现时先在真实推送上正则提取 event_id（已验证 4 种事件均可提取），失败静默忽略 |
| 订阅 01（无此主题）响应 | 按序匹配机制已处理（机型差异容忍），日志可见 |

## 实测数据附录（mimo-ios.pcap，2026-10-19 会话）

- cam_record_time：`000000000000 → 010000000000 → 020000000000…`（录制秒递增，39 变化）
- cam_fov：`6d090000 11070000 01000000 38310000` / `da120000 9a0a0000 01000000 38310000`（A/B 随分辨率变化）
- cam_photo_param：`00010201000001000000000001` / `…00000501`（offset 11 变化）
- camcap_common：`010700030b0010011103`
- 00/4A：`ea070a13133424e001` → 2026-10-19 19:52:36 +480ms
