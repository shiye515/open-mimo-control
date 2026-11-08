# 协议样例帧（fixtures）

来源：docs/protocol/mimo-ios.pcap（19:52:35–19:55:20 会话）。仅帧级 hex，供实现单测与 CRC 破解复算。
每行：文件名 | 抓包时刻 | 说明。所有帧为 `55` 帧原始字节（TCP 心跳除外）。

| 样例 | 时刻 | 说明 |
| --- | --- | --- |
| `tcp_heartbeat_c2s.bin` | 19:52:38+ 每秒 | TCP 7001 心跳，单字节 0x00 |
| `tcp_status_s2c.bin` | 19:52:35.490 | TCP 7001 相机状态帧（cmd 0xa2） |
| `udp_ack_c2s.bin` | 19:52:35.451 | UDP 9004 手机→相机纯 ACK 包（含外层头） |
| `record_start_c2s.bin` | 19:53:13.143 | 录制开始命令（0x66, 40 02 02 00） |
| `record_ack_s2c.bin` | 19:53:13.158 | 录制开始 ACK（0x66, c0 02 02 00，seq 回显） |
| `mode_slowmotion_c2s.bin` | 19:53:01.053 | 模式切换→慢动作（0x66, 40 02 e1 02） |
| `subscribe_camstatus_c2s.bin` | 19:52:35.552 | 订阅 cam_status（cmd 0x9c，含明文主题名） |
| `push_camstatus_s2c.bin` | 19:53:13.101 | cam_status 推送（cmd 0xf9，值 `55 01 01 00 01 0200`） |
| `video_s2c_1.hex` | 19:52:35.569 | 1305B 视频包：外层头 + 内嵌明文 cam_storage 推送 |
| `video_s2c_2.hex` | 19:52:35.629 | 1324B 视频包：外层头 + 高熵（加密）载荷 |

## CRC 算法（已解决，2026-10-19 经 DJI Osmo GPS Controller Demo 参考文档 + 样例帧闭环）

- **头 CRC8**：反射 poly `0x8C`、init `0x77`、无终态异或，覆盖 SOF..len 共 3 字节（帧偏移 3）。
- **帧尾 CRC16**：CRC-16/MCRF4XX（反射 poly `0x8408`、init `0x3692`、无终态异或），覆盖 SOF..payload，小端存储。
- 复算：`tools/parse_mimo_capture.py --crc-test`（全部样例 ✓）。
- 历史注记：早期曾排除 ARC/MODBUS/X-25/XMODEM/CCITT-FALSE/KERMIT 六种常见算法——当时帧布局尚未修正为 DUML。
