# 实时预览流（live-view）

> **⚠️ 2026-11-06 重大修正（真机渲染成功后定案）**：本文件早版本的"SRTP/加密"判定系
> **分片帧格式误读**。正确格式为 [osmocam](https://github.com/luisreysan/osmocam)（MIT）路线：
> UDP 9004 视频包 = 8B link 头（u16 0x8000|len + session + seq + type=2 + xor）+ 20B 视频子头
> （AU 首包 `00 00 01 FF` + u32 LE AU 长度 + 头长 0x0C 低 6bit，OA4），载荷为
> **未加密 H.265 Annex-B**（ffprobe/ffmpeg 解码 1235 AU 实证；真机 AVSampleBufferDisplayLayer
> 渲染成功，OA4 = 1280x720/25fps）。手机→相机需 25ms type-4 ack（三组游标回显）。
> 本文件以下"加密/sec_comm/SRTP"章节**全部作废**，正确实现见
> `OpenMimoProtocol/Sources/OpenMimoProtocol/OSMOCameraLink.swift`（datalink）与
> `OSMOVideoRenderer.swift`（解码渲染），协议要点见本文件与 `docs/protocol/connection-implementation.md`。
> 原文保留作历史记录。

> 证据：docs/protocol/mimo-ios.pcap 19:52:35:35–19:55:20，UDP 9004 相机→手机 98,325 包 / 118.9MB / 165s ≈ **5.8 Mbps**（对应相机 2.7K/60 档位，与截图角标一致）。

## 1. 传输形态（已证实）

- 承载于 **UDP 9004**（与控制命令同端口，见 control-channel.md §3）；
- 相机→手机 ~600 包/s，单包典型 1281–1324B（分片重组后为连续流）；
- 手机→相机每秒 ~60 个 ACK 包（34B）对收包进行确认。

## 2. S2C 包头与分片（2026-10-28 完全破译）

视频大包（>1300B，主体 76,001 个）= 20B 业务头（session 变体 `85c615`，与控制 `80c615` 同构）+ 分片载荷：

```
[0]      1   len 低字节（c0/43/af…，随包长变化）
[1..3]   3   session id 变体（85 c6 15）
[4..7]   4   seq8/seqB/ack 区（与 C2S 业务头同构）
[8..15]  8   ackBase/seq8 回显/0000
[16..19] 4   分片控制：[16]=帧号(递增) [17]=片号|0x80(续片) [18]=00 [19]=01(末片标志)
[20..]   ..  载荷
```

- **首片**载荷前 20B 为子头：`000001ff [ts:2] 0000 0c11 [seq:1] 00000000 010201d0`（[24:26] 随时间波动，
  疑为时间戳/加密 nonce 组件；`010201d0` 全程恒定，语义未定）；
- **续片**载荷为纯密文；单片帧无末片标志（帧号推进隐式结束）；
- 实测帧 0x0d：三片 1432+1452+1452=4336B（自洽）；
- 大包内同时复用明文 `0x55` 控制帧（cam_storage/cam_status 推送等），由解封装器剥离。

## 3. C2S 确认（已证实形态，字段编码未定）

34B 纯 ACK 样例：
`22 80c615 00000475 30ae30ae00000000 30ae30ae00000000 30ae30ae00000000 0000`

- 3 组 `[hi:2][lo:2]` 序号区间 + 尾部 `0000`；
- 另有 48B 状态包（`30` 开头，含 `c0 05 14 00 00 64` 重复模式，~76s 一次，疑为 RTT/统计上报）。

## 4. 视频载荷：**SRTP 加密**（2026-10-28 证据升级）

- 1324B 样例的载荷区熵值极高，**无 H.264/H.265 起始码（00 00 00 01）**、无可辨识 NALU 头；
- **native 证据（决定性）**：libDJIVideoJNI.so 内置 ffmpeg SRTP 协议栈——
  `ff_srtp_decrypt` / `ff_srtp_encrypt` / `SRTP_AES128_CM_HMAC_SHA1_80` / `SRTP_AES128_CM_HMAC_SHA1_32` /
  `srtp_in_params` / `srtp_in_suite`——视频流为**标准 SRTP**（AES-128-CM 计数器模式 + HMAC-SHA1 认证）；
- 同库含完整 H.264/HEVC demuxer/parser（`h264_mp4toannexb`、`NAL %d/%d at %d/%d`）——
  解密后即标准 AnnexB 流，VideoToolbox 可直接消费；
- 控制帧（0x55）为明文，仅媒体载荷加密；
- **剩余缺口 = srtp_in_params 的密钥来源**：无明文 RTSP 信令（TCP 7000/7001 亦加密），
  sec_comm (1,0,54) 未在抓包出现——密钥疑经 BLE TOKEN 流程或控制通道加密下发。
  攻坚路径：① Android Frida hook `ff_srtp_decrypt` 直接取 key/参数（最快）；
  ② BLE HCI 抓包比对 TOKEN 应答后的密钥下发帧。

**iOS 实现现状（2026-10-28）**：传输/解封装/解码管线已全部就绪（LiveViewDepacketizer +
LiveViewPipeline），`VideoDecrypting` 协议留密钥实现位；密钥到手即通。

## 5. 预览开启序列（2026-10-28 逐帧定案，pcap 54.69–54.81s）

```
+54.690s  C2S (0x40,0xEE,0x2F) dst=0x1C  pl=0000794c 95ac   ← liveview_transmit_ctrl（前4B恒定，后2B参数）
+54.691s  C2S (0x80,0x00,0x81) dst=0x48  pl=00 "APP" + 零填充（70B，cmdType=0x80 通知类）
+54.778s  C2S (0x40,0x00,0x88) dst=0x28  pl=17 0000 23 00 "AP" 50 00…（27B）
+54.786s  C2S (0x40,0x00,0x74) dst=0x28  200B 预览参数（含 "wtm" 元数据条目）
+54.786s  C2S (0x40,0xB9,0x20) 233B 大帧
+54.688s→  C2S (0x40,0x00,0x4F) dst=0x48 高频（01 00 [idx] 0000 ffff，视频期 idx 快速递增）
+54.81s   S2C 视频大包开始
```

注意：`(ee,2f)` 的参数两次为 `95ac`/`1f00`（语义未定，疑分辨率/码率档位）。
**iOS 已按此序列完整实装（startLiveView 四帧含 (00,74) 逐字节重放），真机发送成功但相机未开始推流**——
(00,74) 内含疑会话绑定字段（b8fab920/4034814c/9cc74e9f，静态重放被识别为过期），
纯 pcap 静态重放已到边界。剩余路径：Android Frida hook（(00,74) 构造 + ff_srtp_decrypt）
或受控双抓包（HCI+WiFi）字段差分。

## 6. iOS 实现要点（设计层，非协议）

- `NWConnection` UDP 收包 → 按包头分片重组 → （待解密）→ 剥离内嵌控制帧 → 送 VideoToolbox；
- C2S ACK 必须实现（相机依赖确认驱动发送速率），字段编码需一次受控抓包定案（改变收包节奏对比 ACK 内容）。

## 5.5 SRTP 密钥下发通道（2026-10-29 受控双抓包定案）

**TCP 7001 同时是 RTP-over-TCP 信令通道**（此前误判为纯心跳）：

- S2C 包形态：标准 RTP 头（`80 cd [seq:2] [ssrc:4]`，V=2、PT=77）+ 信令体；
- **+33.6s（连接建立后）205B 关键包**：
  `RTP头12B | 00000000 00000014 68d5263d | 010001 00 | 20 | [32 字符 hex ASCII] | 加密块 128B`
  — `20`=hex 串长度，hex 串解出即 **16B SRTP master key**（本次实测 `eed484a0a5d8467c80a17fde5d1dd3f0`）；
- 时序：密钥下发 +33.6s → 预览命令 (ee,2f) +47.4s（参数 `00003a51` 随会话变）→ 视频流 +47.6s；
- (ee,2f) 参数前 4B 为会话派生标识（上次 `0000794c`），与密钥/会话关联。

**iOS 实现**：`SRTPSignaling.extractKey`（信令解析）+ `SRTPDecryptor`（AES-128-CM）已实装，
FIPS-197 KAT 与真实密钥提取测试通过；离线解密真实视频帧已执行但输出未出 NALU——
IV/KDF 构造参数待校准（已排除标准 RFC3711 KDF；master key 或为中间值，205B 包的加密块
或 BLE TOKEN 参与 KDF）。下一步：Android Frida hook `ff_srtp_decrypt` 拿三要素。