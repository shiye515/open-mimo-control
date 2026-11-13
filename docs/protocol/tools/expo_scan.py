#!/usr/bin/env python3
"""cam_expo_param 全字段破解工具：从 pcap 提取该主题全部推送并做字节变化矩阵。

用法：
  python3 expo_scan.py <pcap 路径>              # 列出每条推送（相对时间 + 41B hex）
  python3 expo_scan.py <pcap 路径> --matrix     # 逐字节 distinct 值 + 变化时刻矩阵
  python3 expo_scan.py <pcap 路径> --changes    # 仅列内容发生变化的推送

pcap 格式自动识别 pcap / pcapng；仅解析 UDP 9004。帧校验：crc8 + crc16 双闭环。
"""
import sys
from collections import OrderedDict


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


def parse_frame(b):
    if len(b) < 13 or b[0] != 0x55:
        return None
    length = b[1] | (b[2] & 0x03) << 8
    if length != len(b) or b[2] >> 2 != 0x01:
        return None
    if crc8_duml(b[:3]) != b[3]:
        return None
    if crc16_mcrf4xx(b[:-2]).to_bytes(2, "little") != b[-2:]:
        return None
    return {"sender": b[4], "receiver": b[5],
            "cmdSet": b[9], "cmdId": b[10], "payload": b[11:-2]}


def extract_duml(p):
    """UDP 载荷里全部完整 DUML 帧（多帧包拆出）。"""
    out, i, n = [], 0, len(p)
    while i < n - 3:
        if p[i] == 0x55:
            ln = p[i + 1] | (p[i + 2] & 0x03) << 8
            if 13 <= ln and i + ln <= n:
                fr = parse_frame(p[i:i + ln])
                if fr:
                    out.append(fr)
        i += 1
    return out


def all_topic_frames(path):
    """[(相对秒, 主题名, 数据段 bytes)]——全部 00/99 主题推送。"""
    import io
    from scapy.all import PcapNgReader, PcapReader, IP, UDP

    raw = open(path, "rb").read()
    rd = _reader_for(raw)
    hits, t0 = [], None
    for pkt in rd:
        if IP not in pkt or UDP not in pkt:
            continue
        if 9004 not in (pkt[UDP].sport, pkt[UDP].dport):
            continue
        if t0 is None:
            t0 = float(pkt.time)
        ts = float(pkt.time) - t0
        for fr in extract_duml(bytes(pkt[UDP].payload)):
            if (fr["cmdSet"], fr["cmdId"]) != (0x00, 0x99):
                continue
            name, data = _split_topic_push(fr["payload"])
            if name:
                hits.append((ts, name, data))
    return hits


def duml_frames(path, cmd_filter=None):
    """[(相对秒, 帧 dict)]——全部 DUML 帧，可选 (cmdSet,cmdId) 过滤。"""
    import io
    from scapy.all import PcapNgReader, PcapReader, IP, UDP

    raw = open(path, "rb").read()
    rd = _reader_for(raw)
    out, t0 = [], None
    for pkt in rd:
        if IP not in pkt or UDP not in pkt:
            continue
        if 9004 not in (pkt[UDP].sport, pkt[UDP].dport):
            continue
        if t0 is None:
            t0 = float(pkt.time)
        ts = float(pkt.time) - t0
        for fr in extract_duml(bytes(pkt[UDP].payload)):
            if cmd_filter and (fr["cmdSet"], fr["cmdId"]) != cmd_filter:
                continue
            out.append((ts, fr))
    return out


def _split_topic_push(p):
    """00/99 推送载荷 → (主题名, 数据段)；非推送返回 (None, b'')。"""
    if len(p) < 17:
        return None, b""
    name_len = p[13] | p[14] << 8
    if name_len <= 0 or 15 + name_len + 8 > len(p):
        return None, b""
    name = p[15:15 + name_len].decode("utf-8", "replace")
    data_start = 15 + name_len + 6
    data_len = p[data_start] | p[data_start + 1] << 8
    return name, p[data_start + 2:data_start + 2 + data_len]


def show_correlate(path):
    """expo 推送与相机真实状态对齐：状态变化去重 + 每次 expo 变化附当前状态。"""
    expo = topic_frames(path)
    truth = _truth_timeline(path) + _topic_truth(path)
    truth.sort(key=lambda x: x[0])

    print("== 相机状态变化（去重）==")
    shown = {}
    for ts, kind, v in truth:
        if shown.get(kind) != v:
            shown[kind] = v
            print(f"{ts:10.3f}  {kind:10s} {v}")

    print("\n== cam_expo_param 变化（附当时状态）==")
    prev = None
    state = {}
    ti = 0
    for ts, d in expo:
        while ti < len(truth) and truth[ti][0] <= ts:
            state[truth[ti][1]] = truth[ti][2]
            ti += 1
        if d == prev:
            continue
        diff = (" ".join(f"@{i}:{prev[i]:02x}→{v:02x}" for i, v in enumerate(d)
                         if i < len(prev) and prev[i] != v) if prev else "initial")
        st = (f"mode={state.get('mode', '?')} rec={state.get('rec', '?')} "
              f"v2={state.get('v2', '?')} lens={state.get('lens', '?')} "
              f"battT={state.get('battT', '?')}")
        print(f"{ts:10.3f}  {st}  {diff}")
        prev = d


def _topic_truth(path):
    """其他主题的关键字段 → 判别 ground truth。"""
    out = []
    for ts, name, d in all_topic_frames(path):
        if name == "cam_lens_state" and len(d) >= 16:
            out.append((ts, "lens", int.from_bytes(d[14:16], "little")))
        elif name == "cam_video_param_v2" and len(d) >= 2:
            out.append((ts, "v2", f"res={d[0]:02x} fps={d[1]:02x}"))
        elif name == "cam_image_effect" and len(d) >= 3:
            out.append((ts, "color", f"{d[2]:02x}"))
    for ts, fr in duml_frames(path, cmd_filter=(0x0D, 0x02)):
        p = fr["payload"]
        if len(p) >= 19:
            t = int.from_bytes(p[17:19], "little", signed=True)   # 电池温度 0.1°C
            out.append((ts, "battT", t))
    return out


def _truth_timeline(path):
    """[(时间, 类型, 值)]：02/80 模式/录制、02/1F/2B/29/2D 回读、02/2E EV 写、02/E1 模式切换。"""
    truth = []
    for ts, fr in duml_frames(path):
        cs, cid, p = fr["cmdSet"], fr["cmdId"], fr["payload"]
        if (cs, cid) == (0x02, 0x80) and len(p) >= 58:
            truth.append((ts, "mode", p[57]))
            truth.append((ts, "rec", p[0] >> 6))
        elif (cs, cid) == (0x02, 0x1F) and len(p) >= 2 and p[0] == 0:
            truth.append((ts, "expoMode", p[1]))
        elif (cs, cid) == (0x02, 0x2B) and len(p) >= 2 and p[0] == 0:
            truth.append((ts, "isoCode", p[1]))
        elif (cs, cid) == (0x02, 0x29) and len(p) >= 5 and p[0] == 0:
            truth.append((ts, "shutter", int.from_bytes(p[2:4], "little") | p[4] << 16))
        elif (cs, cid) == (0x02, 0x2D) and len(p) >= 4 and p[0] == 0:
            truth.append((ts, "wb", (p[1], int.from_bytes(p[2:4], "little") * 100)))
        elif (cs, cid) == (0x02, 0x2E):
            truth.append((ts, "EVset", p[1] if len(p) > 1 else None))
        elif (cs, cid) == (0x02, 0x8E) and len(p) >= 7 and p[0] == 0 and p[1] == 0 and p[2] == 1:
            truth.append((ts, f"pid{int.from_bytes(p[3:5], 'little'):04x}", p[6]))
        elif (cs, cid) == (0x02, 0xE1) and p:
            truth.append((ts, "modeSet", p[0]))
    truth.sort(key=lambda x: x[0])
    return truth


def topic_frames(path, topic="cam_expo_param"):
    """[(相对秒, 数据段 bytes)]——目标主题的全部推送。

    支持三种文件形态：
    - 纯 pcapng（magic 0a0d0d0a @0）
    - 经典 pcap（magic d4c3b2a1 @0）
    - tcp-capture.sh 产物：24B 陈旧经典 pcap 头 + pcapng 主体（rvi0 抓包工具拼接瑕疵）
    """
    import io
    from scapy.all import PcapNgReader, PcapReader, IP, UDP

    raw = open(path, "rb").read()
    rd = _reader_for(raw)
    hits, t0 = [], None
    for pkt in rd:
        if IP not in pkt or UDP not in pkt:
            continue
        if 9004 not in (pkt[UDP].sport, pkt[UDP].dport):
            continue
        if t0 is None:
            t0 = float(pkt.time)
        ts = float(pkt.time) - t0
        for fr in extract_duml(bytes(pkt[UDP].payload)):
            if (fr["cmdSet"], fr["cmdId"]) != (0x00, 0x99):
                continue
            p = fr["payload"]
            if len(p) < 17:
                continue
            name_len = p[13] | p[14] << 8
            if name_len <= 0 or 15 + name_len + 8 > len(p):
                continue
            name = p[15:15 + name_len].decode("utf-8", "replace")
            if name != topic:
                continue
            data_start = 15 + name_len + 6
            data_len = p[data_start] | p[data_start + 1] << 8
            data = p[data_start + 2:data_start + 2 + data_len]
            hits.append((ts, data))
    return hits


def hexs(b):
    return b.hex()


def _reader_for(raw):
    """按文件形态返回 scapy reader（pcapng / 经典 pcap / 24B 陈旧头 + pcapng 主体）。"""
    import io
    from scapy.all import PcapNgReader, PcapReader
    if raw[:4] == b"\n\r\r\n":
        return PcapNgReader(io.BytesIO(raw))
    if raw[:4] in (b"\xd4\xc3\xb2\xa1", b"\xa1\xb2\xc3\xd4"):
        if raw[24:28] == b"\n\r\r\n":
            return PcapNgReader(io.BytesIO(raw[24:]))   # 剥离陈旧 pcap 头，主体是 pcapng
        return PcapReader(io.BytesIO(raw))
    raise SystemExit("无法识别的抓包格式")


def show_all(hits):
    for ts, d in hits:
        print(f"{ts:10.3f}  {len(d):3d}B  {hexs(d)}")
    print(f"-- 共 {len(hits)} 条")


def show_changes(hits):
    prev = None
    n = 0
    for ts, d in hits:
        if d == prev:
            continue
        print(f"{ts:10.3f}  {len(d):3d}B  {hexs(d)}")
        prev = d
        n += 1
    print(f"-- 变化 {n} / 总 {len(hits)} 条")


def show_matrix(hits):
    """逐字节：distinct 值数 + 首末次时间 + 值序列（≤12 个采样）。"""
    if not hits:
        print("无推送")
        return
    width = max(len(d) for _, d in hits)
    print(f"推送 {len(hits)} 条，最大长度 {width}B\n")
    for off in range(width):
        vals = OrderedDict()   # value -> [first_ts, last_ts, count]
        for ts, d in hits:
            if off >= len(d):
                continue
            v = d[off]
            if v not in vals:
                vals[v] = [ts, ts, 1]
            else:
                vals[v][1] = ts
                vals[v][2] += 1
        samples = " ".join(f"{v:02x}(n{c},t{t0:.0f})" for v, (_, _, c) in
                           [(v, vals[v]) for v in list(vals)[:12]] for t0 in [vals[v][0]])
        # 变化时间点（值变化才列）
        change_ts = []
        prev = None
        for ts, d in hits:
            if off < len(d):
                v = d[off]
                if v != prev:
                    change_ts.append((ts, v))
                    prev = v
        marks = " ".join(f"{t:.1f}s={v:02x}" for t, v in change_ts[:14])
        extra = f" …共{len(change_ts)}变" if len(change_ts) > 14 else ""
        print(f"@{off:2d}  值域{len(vals):3d}  {marks}{extra}")


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    hits = topic_frames(sys.argv[1])
    if "--matrix" in sys.argv:
        show_matrix(hits)
    elif "--changes" in sys.argv:
        show_changes(hits)
    elif "--correlate" in sys.argv:
        show_correlate(sys.argv[1])
    else:
        show_all(hits)


if __name__ == "__main__":
    main()
