# 传输层（transport）

> 实现目标：把 DUML 帧装进 UDP 9004 / TCP 7001 的外层封装，并让相机接受。
> DUML 帧本身见 [duml-frame.md](duml-frame.md)。

## 1. UDP 9004：主通道

控制命令、遥测推送、实时预览流全部复用 UDP 9004。外层封装**双向同构**，
但 **iOS 与 Android 官方 app 的头长不同**（ACK 块大小差异，见 §1.3）。

### 1.1 Android 官方 app 外层头（20B，实测 4131 帧验证）

```
偏移  大小  字段                        示例（44B 控制包）
0     1    len（u8，整包长）           0x2C = 44
1     3    session id（App 声明，       80 04 51
           相机回显；iOS 侧观测同为
           0x80 开头 3B，如 80 c6 15）
4     4    seq（u32 LE，步进 +8）       30 89 05 45
8     8    ACK 块（8B 形态）            20 89 30 89 00 00 00 00
16    ..   DUML 帧一或多个              55 18 04 20 02 01 47 da …
```

### 1.2 iOS 官方 app 外层头（34B，mimo-ios.pcap 观测）

```
偏移  大小  字段
0     1    len（u8，≤255B 时成立）
1     3    session id（3B）
4     4    seq（u32 LE）
8     24   ACK 块（3 组 [hi:2][lo:2] 区间 + 组间 0000）
32    2    尾字节（观测 0000 / 4d00）
34    ..   DUML 帧
```

视频大包（S2C）为 **20B 变体**：`[len:1][session:3（0x85 开头）][seq:4]
[ackBase:4][seq8 回显:4][0000:4]`，[16..19] 为分片控制
（[16]=帧号、[17]=片号|0x80 续片、[19]=末片标志），详见
[protocol-raw/live-view.md](../protocol-raw/live-view.md) §2。

### 1.3 len 字段编码（大包扩展）

- ≤255B：`len` 为 1 字节 u8 = 整包长
- \>255B（视频/遥测聚合包）：**u16 LE + 0x8000 标志**，即
  `len_le16 = 0x8000 | 整包长`（实测 1418B 遥测包首两字节 `8a 85` = 0x858A =
  0x8000|0x058A；视频包 `c0 85` 亦同）

### 1.4 ACK 块（形态已证，编码未定）

- Android：8B（`[ack seq 相关 4B][0000 0000]`）
- iOS：24B（3 组 `30ae 30ae 0000 0000` 恒定形态）+ 尾 2B
- **字段编码未定**——不影响单向命令；实现预览流时手机→相机的 34B/25ms ACK
  是速率驱动条件（见 §2），建议按官方形态回放起点再受控差分

## 2. TCP 7001：辅助通道

| 阶段 | 流量 | 说明 |
|---|---|---|
| 连接期 | 握手帧数条 | 与 UDP 同命令空间 |
| 稳态 | 手机每 ~1s 单字节 `0x00` 心跳 | 存活性 |
| 稳态 | 相机每 ~1.5s 状态推送（DUML，src=0x1D，(0xC0, 0xEE, 0x06)，payload `0080`） | 基础状态 |
| 预览前 | RTP-over-TCP 信令（头 `80 cd`，PT=77） | 含 205B 关键包（内嵌 32 字符 hex = 16B 会话密钥材料），详见 protocol-raw/live-view.md §5.5 |

角色定位：低带宽"存活性 + 基础状态"通道，**全部业务命令走 UDP 9004**。
Android 官方 app 实测未建立 7001 连接（仅 SYN 探测），控制不受影响。

## 3. 保活与探测帧（外层形态）

| 帧 | 形态 | 节奏 | 说明 |
|---|---|---|---|
| 9B 心跳 | `[09][session:3][seq:4]` | — | 头部最短形态（无 ACK 块） |
| 48B 保活 | `[30][session:3][seq:4][30ae][统计 40B]` | ~0.5s 向各网关地址广播 | 入网前即发（会话探测/保活），相机回 9B |
| 34B 视频确认 | `[22][session][seq][ACK 块]` | 预览期 ~60/s | 相机依赖确认驱动发送速率 |

## 4. 会话建立要点

1. session id 由 **App 侧声明**、相机回显（iOS 实测 S2C 回显同 3B session；
   视频流 session 首字节变体 0x85/0x80 与控制 0x80 同构）
2. 入网后即可发业务命令（无需等待"连接完成"信令）；订阅后 0.4s 内收到首值推送
3. 断线重连：凭据已持久化时**全程无 BLE**，直接入网 + 重建 UDP 会话

## 证据

- [protocol-raw/control-channel.md](../protocol-raw/control-channel.md) §2/§3（TCP 7001、UDP 外层逐字节修正）
- [protocol-raw/live-view.md](../protocol-raw/live-view.md) §2/§3（视频大包 20B 头与分片）
- [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md)（Android 20B 头，4131 帧 CRC 校验）
