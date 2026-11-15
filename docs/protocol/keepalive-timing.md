# 保活与轮询节奏（keepalive-timing）

> 实现目标：维持会话长期稳定（不掉推送、不掉预览）。本文给出两代官方 app 的
> 实测节奏与最低保活集。

## 1. 节奏总表

### iOS 官方 app（mimo-ios.pcap 实测，0.2s 主节奏）

| 周期 | 命令 (cmdSet, cmdId) → dst | payload | 作用 |
|---|---|---|---|
| **0.2s** | (0x00, 0x4F) → 0x48 | `01 00 <tick/2> 00 00 FF×4` | 心跳主帧（tick/2 取 u8 防溢出） |
| **0.2s** | (0x00, 0x51) → 0x48 | `04` | statusPoll 保活组合——**缺失时视频掉到 3 帧/min** |
| **0.2s** | (0x00, 0x82) → 0x48 | 空 | 同上组合 |
| 1s | (0x00, 0x88) → 0x28 | 空 | encoderRegister 续期 |
| 2s | (0x00, 0x81 / 0x82) → 0x48 | appInfoReply / `00` | App 身份续期 |
| 4s | (0x00, 0x00) → 0x28 | 空 | 通道保活 |
| 1s | 02/8E GET pid 0x0014 → 0x28 | `00 01 1400` | 朝向快轮询（预览方向跟随） |
| 3s | 02/8E GET 一轮 ×10/11 条（0.3s 间隔） | — | 参数轮询（已大半退役转推送，见 §3） |
| 1s | TCP 7001 单字节 `0x00` | — | TCP 存活性 |
| 60s | BLE 保活帧 | — | **推流必要条件**（无 BLE 会话推流 1-2 帧即停） |

### Android 官方 app（三轮 pcap 实测对照）

| 周期 | 帧 | 说明 |
|---|---|---|
| ~0.11s | 02/8E GET 轮转 11 pid | 轮询比 iOS 激进（pid 集合与 iOS 基本重合） |
| 1s | (0x40, 0x03, 0xDA) `05 ffffffff` | 周期状态推送 |
| 1s | (0x40, 0x00, 0x4F) | 推送通道管理 |
| 2.5s | (0x40, 0x00, 0x2B) `04 00` | 周期帧 |
| 0.5s | 48B 保活帧（外层形态） | 会话探测/保活 |

**未观测到 iOS 的 0.2s 三连**（0x4F/0x51/0x82 组合在 Android 为 1s/低频形态）——
保活策略为平台实现差异，非协议硬约束。

## 2. 节奏时间轴（预览稳态，示意）

```
iOS（0.2s 主节奏）：
0.0s  4F心跳 ─ 51poll ─ 82 ─ 4F ─ 51 ─ 82 ─ 4F …   （每 0.2s 一组）
1.0s  02/8E GET pid 0014（朝向）     每 1s
1.0s  (0,0x88) encoderRegister       每 1s
3.0s  02/8E GET 参数一轮 ×10 条      每 3s（0.3s 间隔轮转）
4.0s  (0,0x00) 通道保活              每 4s
2.0s  (0,0x81/82) appInfo           每 2s

Android（1s 主节奏 + 高频参数轮询）：
~0.11s 02/8E GET 轮转（11 pid 循环）
1.0s   (0x40,0x03,0xDA) + (0x40,0x00,0x4F)
2.5s   (0x40,0x00,0x2B)
```

## 3. 最低保活集（实测边界）

| 项 | 结论 | 证据 |
|---|---|---|
| (0x00, 0x51) statusPoll | **必需**——缺失时视频掉到 3 帧/min | iOS 真机 A/B |
| BLE 保活 | **推流必要条件**——无 BLE 会话推流 1-2 帧即停；OA4 实测 **60s 档位仍流畅**（1s/5s/30s/60s 对照） | 2026-11-11 真机 A/B |
| (0x00, 0x88) encoderRegister | 1s 续期（编码器注册） | iOS 实测节奏 |
| 其余保活帧 | 未逐一做缺失实验；建议按 iOS 节奏实现 | — |

## 4. 轮询与推送的分工

- **有推送主题的状态一律订阅**（21 key 覆盖全部遥测需求，见 [telemetry.md](telemetry.md)）
- **02/8E GET 轮询仅保留无推送主题的参数**：朝向 0x0014（1s，预览方向跟随需低延迟）、
  EIS 0x0008、ISO MAX 0x000F、Pro 0x0000、弱光 0x0030
- 已退役转推送的轮询（2026-11-12/14）：视频格式→cam_video_param_v2、
  曝光模式→cam_expo_param @7、生效 ISO/快门→@16-17/@20-22、ISO 档位码→@11
- 未知 pid 0x000A/0x0018/0x0020/0x0029/0x0028/0x0015/0x001F：官方 app 仍在轮询，
  语义未定——**可轮询观测但勿盲发 SET**

## 5. 负响应与归因

02/8E 负响应为单字节结果码（DF 当前不可用 / E3 参数非法 / E0 不支持），**无 pid**——
归因依赖本地登记的最近 GET pid（实现时维护"最近请求"队列）。

## 证据

- [protocol-raw/control-channel.md](../protocol-raw/control-channel.md) §4.4（节奏表与实现函数映射）
- [protocol-raw/topics-catalog.md](../protocol-raw/topics-catalog.md) §4（订阅机制要点、BLE 保活 A/B 实验）
- [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md)（Android 轮转清单与频率实证）
- [protocol-raw/cam-expo-param.md](../protocol-raw/cam-expo-param.md)（轮询退役的推送映射）
