# DJI OSMO UDP 9004 帧格式 — 源码级破译

> 来源：`DjiProtocolEncoder::Encode`（libdjisdk_jni.so @ 0x28e485c，Ghidra 反编译）
> 反编译文件：`dji-research/decompiled/CRCXREF_*_28e485c.c`
> 验证：与抓包 `captures/tcpdump_any_20261114215953.pcap` 逐字节吻合

## 总体分层

```
UDP 9004 载荷
└── 外层传输头（20B，link/bridge 层）
    [0-1]  len, u16 LE = 0x8000 | 总长
    [2-3]  0x5104（会话/链路标记，LE）
    [4-5]  seq（步进 8）
    [6-7]  对端 ack（递减）
    [8-9]  前一 seq
    [10-11] 0x0000
    [12-15] 通道状态数组①（2088 2088 0000 0000）
    [16-19] 通道状态数组②
    └── 内层协议帧（DjiProtocolEncoder 输出，V2 格式）
```

## 内层帧格式（V2，param_4&1==1 分支——本轮抓包全部命中）

```
偏移  大小  字段                          抓包验证（37B 轮询帧 / 44B 参数帧）
0x00  1    SOP = 0x55                    55 / 55
0x01  2    u16 LE = 0x400 | total_len    11 04 → 17 字节 / 18 04 → 24 字节 ✓
0x03  1    CRC8（覆盖偏移 0x00-0x02 共 3 字节）  92 / 20
0x04  5    发送/接收打包字段：
           [4-5] u16: sender_type/index/receiver 打包（cmd_req[5..7] 各取位段）
           [6-7] u16: 调用方 param_6（host/session）
           [8]   flags: (cmd_req[3]&3)<<5 | param_9<<7 | …
0x09  2    cmd（u16，cmd_req[1..2]）      ee 2f（轮询）/ 00 01 = 0x0100（参数读写！）
0x0b  N    payload（proto 编码，cmd_req+0x28 起）
末尾  2    CRC16（Kermit，poly 0x1021 反射；覆盖 0x00 至 total_len-2）  0d b5 / b9 28
```

**总长** = payload_len + 13。N=0 时 payload 仍占 4 字节（空 proto 消息）。

### 验证实例（44B 参数帧）

```
外层 20B:  2c 80 | 04 51 | 30 89 | 05 45 | 20 89 | 30 89 | 0000 0000 | 2201 | 2037
内层 24B:  55 | 18 04 | 20 | 02 01 47 da | 40 | 00 01 | 01 03 00000000 04 0000 07 | b9 28
                                   ↑cmd=0x0100    ↑proto payload
```
- `0x0418 & 0x3FF` = 24 = 内层总长 ✓
- cmd **0x0100** = 参数读写（对应 open-mimo-control 提交"param-0100 幽灵错误"）
- payload proto：`01 03 00000000 04 0000 07 01`……（参数 ID/值，待与 proto 定义对照）

## 内层帧格式（V1，param_4&1==0 分支，29B 头）

```
0x00  1    SOP = 0x55
0x01  2    初始 0x0818（保留/版本）
0x03  2    帧总长（LE）= payload_len + 29
0x05  2    flags: cmd_req[3]==1 → 0x21；==2 → 0x01；否则 0x41
0x07  4    调用方 param_6
0x0b  3    sender/receiver 位段（cmd_req[5]、[6]、[7]）
0x11  2    receiver_index << 8
0x15  2    seq（u16 LE）
0x17  1    CRC8（覆盖 0x00-0x16 共 23 字节）
0x18  1    0xff（若 cmd_req[0]==1）
0x19  2    cmd（cmd_req[1..2]）
0x1b  N    payload
末尾  2    CRC16（覆盖 0 至 total_len-2）
```
V1 用于设备注册/激活等大帧（`dji::sdk::DeviceRegisterLogic` 路径）。

## CRC 算法（libdjibase.so 导出，@0xafa84c/0xafa890）

- `calc_crc8(data, len)`：逐字节查表
- `calc_crc16(data, len)`：**CRC-16/KERMIT**（poly 0x1021 反射 = 0x8408，初始 0，查表 @libdjibase+0x80fbb0）
- 反射实现：`crc = (crc >> 8) ^ table[(byte ^ crc) & 0xFF]`

```python
def crc16_kermit(data, init=0):
    crc = init
    for b in data:
        crc = ((crc >> 8) ^ T[(b ^ crc) & 0xFF]) & 0xFFFF
    return crc
```

## 加密层（V2 特例）

当 `sender==3 且 total_len > 11` 时，payload 先经**流加密**再算 CRC：
- 密钥种子（21 字节，Encode 内嵌常量异或生成）：`f4 9b df f6 32 de 8e b8 4e cb ec 1b ae 34 2d 7e cb 5d 24 d8 e8`
- 加密：`out[i] = keystream[(i&0xF ^ pos+1) % keylen] ^ out[i] ^ (byte)(seq >> ((i&1)*8))`

## dji_cmd_req 结构（JNI_SendData 反编译，0x28 字节）

```
+0x00  u8   type（==1 时 V1 特殊处理）
+0x01  2    cmd（LE）
+0x03  2    cmd 高位/flags
+0x05  1    sender_type
+0x06  1    sender_index（GlobalPacketStatus）
+0x07  1    （SetSendPackParam 按命令范围 0x8d-0xcb/0x44c-0x455/0x4c2-0x4c4 设 receiver=8）
+0x0c  u32  固定 0x57490000（"IW" 标记?）
+0x24  u32  payload_len
+0x28  ptr  payload（proto 编码数据）
默认超时 500ms（+0x0c 处初始化为 500）
```

## 已知 cmd 值（待扩展）

| cmd | 含义 | 证据 |
|---|---|---|
| **0x0100** | 参数读写 | 44B 帧 + iOS 侧 param-0100 提交记录 |
| 0x2fee（`ee 2f`）| 高频轮询（37B 帧） | 抓包 ~10/s，待与 key 注册表对照 |
| 0x2fe? 系列 | 轮询/状态组 | 0x25/0x2a/0x2b type 变体 |

**下一步**：cmd ↔ 功能映射表——反编译 KeyHandlers 注册路径（`SendParamGet<T>`/`SendActionPack<T>` 的调用方）或 Dump proto 描述符。
