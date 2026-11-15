# 平台差异与复现建议（platform-notes）

> iOS 与 Android 两代官方 Mimo app 对同一相机的协议行为对照。核心协议
> （DUML 帧、命令空间、payload 编码）**完全一致**；差异集中在**外层封装与
> 保活策略**——属实现差异而非协议冲突。

## 1. 一致性验证方法

Android 官方 app 抓包 4131 帧，以 iOS 侧已验证的 CRC 参数
（crc8 poly 0x8C/init 0x77、CRC16-MCRF4XX 0x8408/init 0x3692）全量复算，
**100% 通过**；命令空间（cmdSet/cmdId）、payload 编码（快门 0x8000|分母+小数、
EV 码 16 基准 1/3 档、录像 01/00、按主题名订阅）逐项一致。
详见 [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md) 交叉验证节。

## 2. 实测差异表

| 维度 | iOS 官方 app | Android 官方 app | 复现建议 |
|---|---|---|---|
| **UDP 9004 外层头** | 34B：`[len u8][session 3B][seq 4B][ACK 24B][tail 2B]` | 20B：`[len u8][session 3B][seq 4B][ACK 8B]`（4131 帧验证 DUML@20） | 头为可变结构（心跳 9B 无 ACK 块）；ACK 块编码未定，单向命令不受影响 |
| **大包 len** | 未记录（pcap 无 >255B 控制包佐证） | u16 LE + 0x8000 标志（1418B 遥测/视频包实证） | 按 Android 形态实现 |
| **02/8E 轮询频率** | 1s 朝向 + 3s 参数一轮 | ~9.3/s 轮转 11 pid | 按 iOS 节奏即可（相机无硬约束） |
| **0.2s 心跳三连** (0,0x4F/0x51/0x82) | 每 0.2s 一组 | 未观测（0x4F 1/s、0x2B 2.5s 替代） | 按 iOS 节奏实现（statusPoll 缺失会掉帧） |
| **TCP 7001** | 建立，1s `0x00` 心跳 + 相机 1.5s 状态 + RTP 信令 | 未建立（仅 SYN 探测） | 按 iOS 实现（存活性通道） |
| **预览 ACK** | ~60/s（34B） | 相机侧等价确认 | 预览流必须实现 C2S ACK（速率驱动） |
| **能力表 camcap_*** | 订阅 20 主题 | 订阅 21 key（含同集） | OA4 仅 camcap_common 活跃推送 |

## 3. 预览流要点（两平台一致）

- 视频承载 UDP 9004：20B 业务头（session 变体 `85xxxx`）+ 分片控制 4B
  （帧号/片号|0x80 续片/末片标志）+ **未加密 H.265 Annex-B**
  （真机 AVSampleBufferDisplayLayer 渲染成功，1280x720/25fps 起步；
  早期"SRTP 加密"判定系分片误读，已证伪——详见 protocol-raw/live-view.md 头部修正）
- 大包内同时复用明文 0x55 控制帧（遥测推送内嵌），解封装时剥离
- 手机→相机 ACK（25ms 粒度）驱动相机发送速率，必须实现
- 预览开启命令序列（(0x40,0xEE,0x2F) 等）中 **(0x00,0x74) 含会话绑定字段**，
  静态重放会被识别为过期——需按会话动态构造（参考实现
  `OSMOCameraLink.swift` datalink）

## 4. 复现建议（从零实现者的优先级）

1. **先跑通 BLE 配对 + 入网**（discovery-pairing.md）——凭据明文可取，
   这是唯一依赖系统 BLE API 的环节
2. **UDP 会话 + 单命令回环**：外层 20B 头（Android 形态简单）+ DUML 录像命令
   （02/02 + 01/00，CRC 测试向量在 duml-frame.md）——最小验证闭环
3. **订阅 20 主题**（telemetry.md）——状态显示全靠推送，无轮询依赖
4. **保活按 iOS 节奏**（keepalive-timing.md §1）——statusPoll 是预览稳定的关键
5. **预览流最后做**：分片重组（transport.md §1.2）→ H.265 直解；
   (0x00,0x74) 开启帧的会话绑定字段参考 iOS 实现

## 5. 已证伪项（防回退清单）

| 曾经的误读 | 实际 |
|---|---|
| 02/02 payload `00`=开始 | `01`=开始 / `00`=停止（双平台真机验证） |
| crc8 字段是"命令字/主题哈希" | 是帧长 CRC8（同长度帧天然相同） |
| 视频流 SRTP 加密 | 未加密 H.265 Annex-B（分片帧格式误读） |
| BLE 阶段需要 ECDH+加密 | 明文 DUML（9 种 ECDH 变体帧无应答） |
| 0x2802 = EV 写 | 02/28 = 快门（EV 是 02/2E；0x8000 基准+分母） |
| cam_expo_param 滑动窗口漂移 | 41B 固定布局（手工切片误判） |

完整更正记录见 protocol-raw 各文档内嵌"更正记录/已证伪"节。

## 证据

- [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md)
- [protocol-raw/connection-implementation.md](../protocol-raw/connection-implementation.md)
- [protocol-raw/live-view.md](../protocol-raw/live-view.md)
- [protocol-raw/telemetry.md](../protocol-raw/telemetry.md) §6
