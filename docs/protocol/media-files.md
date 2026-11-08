# 素材文件协议（media-files）

> 状态：**已实现，OA4 真机验证中**（2026-11-07）。
> 协议依据：[osmosis MEDIA_PROTOCOL.md](https://github.com/KonradIT/osmosis/blob/main/MEDIA_PROTOCOL.md)
> 与 [osmocam PROTOCOL.md §9](https://github.com/luisreysan/osmocam/blob/main/docs/PROTOCOL.md)（二者在
> Osmo Nano / Pocket 3 / OA4 上互证；本项目在 OA4 上复现清单解析，golden 样本
> `OpenMimoProtocol/Tests/…/oa4_6.bin` 与 osmosis `Oa4ManifestTest` 逐字节一致）。
> 实现见 `OpenMimoProtocol/Sources/OpenMimoProtocol/OSMOMedia.swift` / `OSMOMediaSession.swift`。

## 0. 总览

| 能力 | 通道 | 命令/URL |
| --- | --- | --- |
| 进入媒体（回放）模式 | datalink | `02/0C [01 01 00 01]`（OA4 以 E0 拒绝）→ `01/01` 双脉冲（OA4 实测路线） |
| 维持媒体模式 | datalink | ~1Hz `00/88` 子命令 0x17（14B，"APP"@5-7） |
| 文件列表 | datalink | `00/26` 查询 → `00/27` 分块应答 |
| 删除 | datalink | `00/28`（应答 `0000`=成功） |
| 收藏 | datalink | `02/BF`（本期未实现） |
| 下载 / 缩略图 | HTTP 80 | `GET /v2?storage=<0|1>&path=<path>.<EXT>`（Range 续传） |

## 1. 媒体模式

- 尝试 `02/0C [01 01 00 01]`；OA4 / Pocket 系**一律以 `E0` 拒绝**（osmosis §13b 实测）。
- OA4 路线（`01/01`，cmd_type 0x00，无应答，receiver 0x01）：
  1. `03 00000000 04000000 07 01` ×~6 帧（~20Hz）
  2. `00 00000000 04000000 04 01` @~20Hz 直至 `02/80` byte3 bit6（mediaMode）置位——
     **唯一完成信号**，OA4 约 350ms 内置位。
- 维持：~1Hz `00/88` 载荷 `17 00 46 23 7C 41 50 50 00×5 02`（14B）。**停止心跳 ~1s 后相机自行脱离媒体模式**（即退出方式，无退出命令）。
- 进入后等 **≥1.7s** 再发首个列表查询（过早查询得到"仅 start"空流，存储未挂载）。
- 媒体模式下实时预览停流；退出媒体模式后需重新请求预览（`startLiveView` 重发注册/订阅）。

## 2. 文件列表（00/26 → 00/27）

### 查询载荷（38→42B，与 osmosis 参考逐字节一致）

```
4a002a10 <counter u32> 0000 <cursor u32> <pagesize u16=2d> 0d 01 00
ffffffffffffffff 0001000000000000 00000000 000000
```

- `@4` counter（应答子头 +4 处 u16 回显）· `@10` 游标 u32-LE · `@14` 页大小（≤45=0x2D）
- 游标：`0x00000001` = SD 卡最新一页；`0x40000001` = 内置存储最新一页；传文件句柄 = 该文件之前的一页

### 应答

- `00/26` 先回状态帧（00=受理），随后 `00/27` 分块（子头 10B）：
  `4A <type> <len u16> <counter u16> <seq u16> 00 00`，type `04` start / `01` data / `03` end。
- `len` 含子头，低 12 位为长度，**bit12 置位 = 最后一个数据块**。
- 完整判定：最后数据块与其前全部序号到齐（end 可能先到、会重复发）。
- **必须按 DUML 命令（00/27）+ counter 过滤**：`4A 01` 前缀同时匹配参数推送，仅按前缀过滤会污染清单。
- 分页三帧：`query(cursor=1)` → `trigger(4a040e10 01000000 0000 01000000)` → `query(cursor=页游标)`，
  两查询 counter 不同；页游标 = 上一页最旧**视频**句柄；相邻页重叠一条记录，按媒体路径去重。
- 清单内出现 `0c 01` TLV = 已到库末尾。

### 清单布局（CompositePack TLV）

`[u32 记录数][记录…]`，记录以 `19 06` 标记锚定（`T` = 其偏移）：

| 字段 | 位置 |
| --- | --- |
| 文件名（含扩展名，唯一来源） | TLV `0d <len> <ascii>` |
| 媒体路径（无扩展名，DCIM/…） | TLV `1a <total> 00 00 00 01 <ascii>` |
| 缩略图路径（MISC/THM/…） | TLV `1a <total> 00 00 00 02 <ascii>` |
| 类型 | `u8 @ T-2`（03=MP4，00=JPG，04=全景） |
| 帧率码 / 分辨率码 | `u8 @ T-4` / `u8 @ T-3` |
| 时长秒（视频） | `u16-LE @ T-6` |
| **句柄**（删除/翻页） | `u32-LE @ T-10` |
| 字节大小 | `u32-LE @ T-14` |
| FAT 打包时间 | `u32-LE @ T-18`（date<<16 \| time，可偏差 1 小时） |

记录边界由相邻媒体路径 TLV 划定（两种字段顺序布局均成立，不要按固定宽度读）。
OA4 句柄几何：`0x00040000 + seq × 0x10`，全部文件（含 JPG）独占句柄，仅 SD 存储（`/v2?storage=0`）。

## 3. 下载与缩略图（HTTP 80）

```
GET http://192.168.2.1/v2?storage=0&path=DCIM/100MEDIA/DJI_….MP4      # 原文件
GET http://192.168.2.1/v2?storage=0&path=MISC/THM/100MEDIA/DJI_….THM  # 缩略图 JPEG（256px）
```

- 支持 Range（206），可断点续传；媒体模式下无预览争用，吞吐 ~6×（osmocam §9.1）。
- 视频低清代理 `.LRF`（把媒体路径扩展名换掉）本期未实现。

## 4. 删除（00/28）

```
payload = [count u8][handle u32-LE × count][counter u32-LE] 00 [count u32-LE] 01 01 00 00
应答 00 00 = 成功；00 d6 = 句柄不存在。同一句柄禁止重复发送。
```

## 5. 已知限制 / 警告

- 相机单客户端：素材会话必须复用控制页的 datalink（`ConnectionFlow.activeOSMOLink`）。
- 写命令（删除）依赖会话 ACK 序列；本项目实测模式切换/录制可靠，沿用同一 `sendRequest`。
- 禁止扫未知命令/值（osmosis §11：扫拍摄模式值曾致相机死机、需拔电池）。
- iOS 需 ATS 放行（Info.plist `NSAllowsArbitraryLoads`，仅相机生态使用 HTTP）。
