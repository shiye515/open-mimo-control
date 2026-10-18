#!/usr/bin/env python3
"""parse_mimo_capture.py —— 按 docs/protocol/ 文档（DUML 布局）解析官方 App 抓包，验证文档自洽。

用法：
  python3 parse_mimo_capture.py <capture.pcapng|pcap> [--crc-test]

依赖：scapy（pip install scapy；仅用于读 pcapng）。
验证内容（对应文档章节）：
  - DUML 帧解析 + CRC8/CRC16 全帧校验（control-channel.md §1）
  - 连接期订阅主题清单（telemetry.md §3）
  - 模式切换命令 (0x40, 0x02, 0xE1, [mode])（control-channel.md §4.1）
  - 录制开始命令 (0x40, 0x02, 0x02, [00]) 及 ACK 回显（control-channel.md §4.2）
  - cam_status 值结构（telemetry.md §4）
  - --crc-test：对 samples/ 样例帧复算 CRC8/CRC16 并校验（文档 §6：已解决）
"""
import re
import sys
import time
from collections import Counter

PHONE, CAM = "192.168.2.140", "192.168.2.1"


def crc8_duml(data):
    crc = 0x77
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8C if crc & 1 else crc >> 1
    return crc


def crc16_mcrf4xx(data):
    crc = 0x3692
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    return crc


def crc_test():
    """samples/README.md 中样例帧的 CRC8/CRC16 全部应校验通过（文档 §6：已解决）。"""
    import pathlib
    samples = pathlib.Path(__file__).resolve().parent.parent / "samples"
    ok = True
    for f in sorted(samples.glob("*.bin")):
        frame = bytes.fromhex(f.read_text().strip()) if f.suffix == ".bin" and f.stat().st_size > 2 else f.read_bytes()
        if len(frame) < 11 or frame[0] != 0x55:
            continue
        length = frame[1] | (frame[2] & 0x03) << 8
        crc8_ok = crc8_duml(frame[:3]) == frame[3]
        crc16_ok = crc16_mcrf4xx(frame[:-2]).to_bytes(2, "little") == frame[-2:]
        status = "OK" if (crc8_ok and crc16_ok and length == len(frame)) else "FAIL"
        ok &= status == "OK"
        print(f"{f.name:34} len={length:3} crc8={'✓' if crc8_ok else '✗'} crc16={'✓' if crc16_ok else '✗'} → {status}")
    print("样例帧 CRC 校验：", "全部通过 ✓" if ok else "存在失败 ✗")


def parse_frame(payload):
    """DUML 单帧解析（control-channel.md §1）：长度/版本/CRC8/CRC16 全校验，帧恰收尾。"""
    b = payload
    if len(b) < 13 or b[0] != 0x55:
        return None
    length = b[1] | (b[2] & 0x03) << 8
    if length != len(b) or b[2] >> 2 != 0x01:
        return None
    if crc8_duml(b[:3]) != b[3]:
        return None
    if crc16_mcrf4xx(b[:-2]).to_bytes(2, "little") != b[-2:]:
        return None
    return {"sender": b[4], "receiver": b[5], "seq": int.from_bytes(b[6:8], "little"),
            "cmdType": b[8], "cmdSet": b[9], "cmdId": b[10], "payload": b[11:-2]}


def find_frames(p):
    i = 0
    while i < len(p) - 3:
        if p[i] == 0x55:
            ln = p[i + 1] | (p[i + 2] & 0x03) << 8
            if 13 <= ln and i + ln == len(p):
                fr = parse_frame(p[i:i + ln])
                if fr:
                    return [fr]
        i += 1
    return []


def topic_of(payload):
    m = re.search(rb"[a-z][a-z0-9_]{4,40}", payload)
    return m.group(0).decode() if m else None


def main(path):
    from scapy.all import PcapNgReader, PcapReader, IP, UDP, TCP
    R = PcapNgReader if open(path, "rb").read(4) == b"\n\r\r\n" else PcapReader
    stats = Counter()
    topics, modes, records, cam_status = set(), set(), [], set()
    with R(path) as rd:
        for pkt in rd:
            if IP not in pkt:
                continue
            ip = pkt[IP]
            if {ip.src, ip.dst} != {PHONE, CAM}:
                continue
            if UDP in pkt and 9004 in (pkt[UDP].sport, pkt[UDP].dport):
                payloads = [bytes(pkt[UDP].payload)]
            elif TCP in pkt and 7001 in (pkt[TCP].sport, pkt[TCP].dport):
                payloads = [bytes(pkt[TCP].payload)] if bytes(pkt[TCP].payload) else []
            else:
                continue
            ts = time.strftime("%H:%M:%S", time.localtime(float(pkt.time)))
            for p in payloads:
                for fr in find_frames(p):
                    key = f"({fr['cmdType']:02x},{fr['cmdSet']:02x},{fr['cmdId']:02x})"
                    stats[key] += 1
                    t = topic_of(fr["payload"])
                    if t and bytes([len(t) >> 8, len(t) & 0xFF, 0x00]) + t.encode() in fr["payload"]:
                        topics.add(t)
                    if (fr["cmdType"], fr["cmdSet"], fr["cmdId"]) == (0x40, 0x02, 0xE1) and fr["payload"]:
                        modes.add(fr["payload"][0])
                    if (fr["cmdType"], fr["cmdSet"], fr["cmdId"]) == (0x40, 0x02, 0x02):
                        records.append((ts, "start"))
                    if (fr["cmdType"], fr["cmdSet"], fr["cmdId"]) == (0xC0, 0x02, 0x02):
                        records.append((ts, "ack"))
                    if fr["cmdId"] == 0x99 and b"cam_status" in fr["payload"]:
                        v = fr["payload"].split(b"cam_status", 1)[1]
                        cam_status.add(v[-7:].hex())
    print(f"DUML 帧总数（全帧 CRC 校验通过）: {sum(stats.values())}")
    print(f"高频命令（前 12）: {stats.most_common(12)}")
    print(f"订阅主题数: {len(topics)} → {sorted(topics)[:8]} …")
    print(f"模式切换值域: {sorted(hex(m) for m in modes)} （文档 §4.1: 00/01/02/05/0a）")
    print(f"录制开始/ACK 事件: {records[:4]} …")
    print(f"cam_status 值样例: {sorted(cam_status)[:4]}")
    ok = bool(topics) and modes <= {0x00, 0x01, 0x02, 0x05, 0x0A} and any(r[1] == "start" for r in records)
    print("文档自洽验证:", "通过 ✓" if ok else "存在偏差 ✗")


if __name__ == "__main__":
    if "--crc-test" in sys.argv:
        crc_test()
    else:
        main(sys.argv[1])
