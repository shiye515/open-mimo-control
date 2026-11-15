# DUML 帧格式（duml-frame）

> WiFi / TCP / BLE 三通道共用的业务帧格式（官方称 DUML，SOF 0x55）。
> 本章含逐字段定义、CRC 参考实现与**已验证测试向量**——按本文实现即可通过
> 相机的 CRC 校验。

## 1. 帧布局

```
偏移  大小  字段        说明
0     1    SOF        固定 0x55
1     2    len (LE)   [9:0] = 整帧总长（含 SOF..crc16）
                      [15:10] = 版本，实测 0x01
3     1    crc8       头校验：覆盖 SOF..len 共 3 字节
4     1    src        发送方节点（0x02 = 手机）
5     1    dst        接收方节点（0x28 = 相机主控；BLE 侧按功能分派
                      0x01/0x07/0x08/0x0F/0x48/0x68/0x88/0xF0）
6     2    seq (LE)   帧序号；应答帧回显同值
8     1    cmdType    0x40 = 请求（需应答）
                      0xC0 = 应答帧
                      0x00 = 推送（不需应答）
9     1    cmdSet     命令集
10    1    cmdId      命令 ID
11    n    payload    命令载荷
末2   2    crc16 (LE) 覆盖 SOF..payload（不含自身）
```

整帧长 = 11 + payload_len + 2。`len [9:0]` 即该值；`[15:10]` 版本位实测恒 0x01。

节点角色速查：0x02 手机 · 0x28 相机主控 · 0x07 WiFi 模块 · 0x08 参数节点 ·
0x48 推送节点 · 0x01/0x05/0x68/0x88/0xF0 其他子系统（BLE 侧 dst 按表分派）。

## 2. CRC 参考实现（Python，可直接复制）

```python
def crc8_duml(data: bytes, poly: int = 0x8C, init: int = 0x77) -> int:
    """头校验：覆盖 SOF..len 共 3 字节"""
    crc = init
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ poly if crc & 1 else crc >> 1
    return crc & 0xFF

def crc16_duml(data: bytes, poly: int = 0x8408, init: int = 0x3692) -> int:
    """帧校验：覆盖 SOF..payload（不含 crc16 自身）"""
    crc = init
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ poly if crc & 1 else crc >> 1
    return crc & 0xFFFF

def build_frame(src: int, dst: int, seq: int, cmd_type: int,
                cmd_set: int, cmd_id: int, payload: bytes = b"") -> bytes:
    head = bytes([0x55]) + (11 + len(payload)).to_bytes(2, "little")
    head += bytes([crc8_duml(head), src, dst]) + seq.to_bytes(2, "little")
    body = bytes([cmd_type, cmd_set, cmd_id]) + payload
    crc = crc16_duml(head + body)
    return head + body + crc.to_bytes(2, "little")
```

跨平台注意：crc8/crc16 参数在 iOS 与 Android 官方 app 流量上**完全相同**
（Android 抓包 4131 帧以本实现 100% 校验通过）。

## 3. 已验证测试向量

以下 4 帧取自真实会话，可用 §2 实现逐字节复算：

### 向量 1 — 录像控制（iOS 官方 app，14B）

```
55 0e 04 66 | 02 01 | 98 a8 | 40 | 02 | 02 | 00 | 2f 83
```
- len 0x0E=14、crc8=0x66、src=02、dst=01、seq=0xA898、
  cmdType 0x40（请求）、cmdSet 0x02 / cmdId 0x02、payload `00`（= 停止）
- 02/02 payload：`01` = 开始、`00` = 停止（双平台实证，
  见 [commands.md](commands.md) §录像；本样例即一份"停止"帧）
- 对应文件 [samples/record_start_c2s.bin](samples/record_start_c2s.bin)（文件名为历史命名）

### 向量 2 — 快门写入 1/100s（Android 官方 app，20B）

```
55 14 04 6d | 02 01 | 68 e6 | 40 | 02 | 28 | 01 64 80 00 00 00 40 | 51 1d
```
- cmdSet 0x02 / cmdId 0x28，payload `01 [64 80] [00] 00 00 00 40`
- 快门值 = 0x8064：`0x8000 | 分母 100` → 1/100s（小数字节 00 = 整数档）
- 另测 1/120（`78 80`）、1/320（`40 81`）同构

### 向量 3 — EV 补偿 +0.3（Android 官方 app，14B）

```
55 0e 04 66 | 02 01 | 69 f5 | 40 | 02 | 2e | 11 | 2a c5
```
- cmdSet 0x02 / cmdId 0x2E，payload 单字节 `11`（= 17）
- EV 码 16 = 0EV、1/3 档步进 → 码 17 = +0.3EV

### 向量 4 — ISO 写入 12800（Android 官方 app，14B）

```
55 0e 04 66 | 02 01 | e2 f9 | 40 | 02 | 2a | 09 | 34 61
```
- cmdSet 0x02 / cmdId 0x2A，payload 单字节 `09`
- ISO 枚举 = log2(ISO/50) + 1 → 9 = 12800（8 = 6400 亦实测）

> 校验方式：`python3 -c` 载入 §2 函数后对上述 hex 逐帧复算；
> 批量验证见 [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md)
> （4131 帧 100% 通过）。

## 4. cmdType 语义

| cmdType | 方向 | 含义 | 应答 |
|---|---|---|---|
| 0x40 | C2S | 请求（需应答） | 同 cmdSet/cmdId 的 0xC0 帧，单字节 `00`=成功 |
| 0xC0 | S2C | 应答帧 | — |
| 0x00 | S2C | 推送（不需应答） | — |
| 0x80 | C2S | 通知类（观测于预览开启序列） | — |

## 5. 常见陷阱

1. **len/版本位**：len 的低 10 位才是整帧长，高 6 位是版本（恒 0x01）——
   按整 u16 解读会得到 24≠20 一类假象；
2. **CRC16 init 是 0x3692 非 0**：标准 MCRF4XX 库默认 init=0xFFFF/0，
   需显式传参；
3. **dst 按功能分派**（BLE 侧尤其）：错 dst 会被 0xE0 拒绝且后续帧被无视；
4. 大包在外层封装层处理（len u16 + 0x8000 标志），DUML 层不变，
   见 [transport.md](transport.md) §1.3。

## 证据

- [protocol-raw/control-channel.md](../protocol-raw/control-channel.md) §1（帧格式与 CRC 的
  双重验证记录）与 samples/ 样例帧
- [protocol-raw/cmd-map-android-csdk.md](../protocol-raw/cmd-map-android-csdk.md)
  （Android 帧 + 4131 帧批量校验）
- [tools/parse_mimo_capture.py](tools/parse_mimo_capture.py) `--crc-test`（可复算）
