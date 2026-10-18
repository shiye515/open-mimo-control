#!/usr/bin/env python3
"""pcap UDP 9004 会话解析器 — DJI OSMO 协议分析
用法:
  python3 pcap_9004.py <pcap> session              # 会话统计: 方向x头模式x长度
  python3 pcap_9004.py <pcap> timeline             # 每秒非心跳计数
  python3 pcap_9004.py <pcap> burst <HH:MM:SS>     # 某秒的非心跳指令包
  python3 pcap_9004.py <pcap> ascii <HH:MM:SS>     # 某秒含可读字符串的包
"""
import struct, sys, re, datetime
from collections import Counter, defaultdict

def read_pcap(path):
    with open(path, "rb") as f:
        gh = f.read(24)
        endian = "<" if gh[:4] in (b"\xd4\xc3\xb2\xa1", b"\x4d\x3c\xb2\xa1") else ">"
        linktype = struct.unpack(endian + "I", gh[20:24])[0]
        while True:
            rh = f.read(16)
            if len(rh) < 16:
                break
            ts_sec, ts_usec, incl_len, _ = struct.unpack(endian + "IIII", rh)
            data = f.read(incl_len)
            yield ts_sec + ts_usec / 1e6, linktype, data

def parse_sll_udp(data):
    """LINUX_SLL(113): 16B 头; 返回 (src, dst, sport, dport, payload) 或 None"""
    if len(data) < 16 + 20:
        return None
    ethertype = struct.unpack(">H", data[14:16])[0]
    if ethertype != 0x0800:
        return None
    ip = data[16:]
    ihl = (ip[0] & 0x0F) * 4
    if ip[9] != 17:  # UDP
        return None
    src = ".".join(map(str, ip[12:16]))
    dst = ".".join(map(str, ip[16:20]))
    udp = ip[ihl:]
    sport, dport = struct.unpack(">HH", udp[:4])
    return src, dst, sport, dport, udp[8:]

def hexdump_head(p, n=20):
    return " ".join(f"{b:02x}" for b in p[:n])

def ascii_strings(p, min_len=4):
    return re.findall(rb"[a-z][a-z_0-9]{%d,}" % (min_len - 1), p)

def fmt_ts(ts):
    return datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]

def load_packets(path):
    out = []
    for ts, lt, data in read_pcap(path):
        if lt != 113:
            continue
        r = parse_sll_udp(data)
        if not r:
            continue
        src, dst, sport, dport, payload = r
        if dport == 9004 or sport == 9004:
            out.append((ts, src, dst, sport, dport, payload))
    return out

def main():
    PCAP_PATH = sys.argv[1]
    MODE = sys.argv[2] if len(sys.argv) > 2 else "session"
    ARG = sys.argv[3] if len(sys.argv) > 3 else ""
    packets = load_packets(PCAP_PATH)

    if MODE == "session":
        groups = Counter()
        for ts, src, dst, sp, dp, p in packets:
            direction = "C->cam" if dp == 9004 else "cam->C"
            groups[(direction, hexdump_head(p, 4), len(p))] += 1
        print(f"{'方向':8} {'头4B':12} {'长度':>6} {'计数':>7}")
        for (d, h, l), c in sorted(groups.items(), key=lambda x: -x[1])[:40]:
            print(f"{d:8} {h:12} {l:>6} {c:>7}")

    elif MODE == "timeline":
        per_sec = defaultdict(int)
        for ts, src, dst, sp, dp, p in packets:
            if dp == 9004 and len(p) != 34:
                per_sec[fmt_ts(ts)[:8]] += 1
        for t in sorted(per_sec):
            print(f"{t} non_hb={per_sec[t]}")

    elif MODE == "burst":
        for ts, src, dst, sp, dp, p in packets:
            if dp == 9004 and fmt_ts(ts).startswith(ARG) and len(p) != 34:
                s = ascii_strings(p, 4)
                extra = f"  STR:{[x.decode() for x in s]}" if s else ""
                print(f"{fmt_ts(ts)} len={len(p):4} {hexdump_head(p, 24)}{extra}")

    elif MODE == "ascii":
        for ts, src, dst, sp, dp, p in packets:
            if fmt_ts(ts).startswith(ARG):
                s = ascii_strings(p, 4)
                if s:
                    print(f"{fmt_ts(ts)} {'C->cam' if dp==9004 else 'cam->C'} len={len(p):4} {[x.decode() for x in s]}")

if __name__ == "__main__":
    main()
