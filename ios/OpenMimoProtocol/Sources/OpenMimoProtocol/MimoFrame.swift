import Foundation

/// DUML 帧（docs/protocol/control-channel.md §1；与 DJI Osmo GPS Controller Demo 参考文档互证）：
/// `55 | len(2B：[9:0]帧长 LSB first + [15:10]版本) | crc8(1, 覆盖前3字节) | src | dst |
///  seq(2, LE) | cmdType | cmdSet | cmdId | payload | crc16(2, LE, MCRF4XX 覆盖 SOF..payload)`
public struct MimoFrame: Equatable, Sendable {
    public static let sof: UInt8 = 0x55
    public static let version: UInt8 = 0x01
    /// 头部长度：SOF + len(2) + crc8 + src + dst + seq(2) + cmdType + cmdSet + cmdId
    public static let headerLength = 11
    public static let minimumLength = headerLength + 2

    /// 节点标识：0x02=手机；观测到的相机侧模块 0x28/0x48/0x01/0x05/0xF0 等
    public let sender: UInt8
    public let receiver: UInt8
    public let sequence: UInt16
    /// 0x40=请求（需应答）、0xC0=应答帧、0x00=推送（不需应答）
    public let cmdType: UInt8
    public let cmdSet: UInt8
    public let cmdId: UInt8
    public let payload: Data

    public init(sender: UInt8, receiver: UInt8, sequence: UInt16,
                cmdType: UInt8, cmdSet: UInt8, cmdId: UInt8, payload: Data) {
        self.sender = sender
        self.receiver = receiver
        self.sequence = sequence
        self.cmdType = cmdType
        self.cmdSet = cmdSet
        self.cmdId = cmdId
        self.payload = payload
    }

    /// 按文档规则解析单帧：长度自洽、版本匹配、CRC8/CRC16 全部校验。
    public static func parse(_ data: Data) -> MimoFrame? {
        let b = [UInt8](data)
        guard b.count >= minimumLength, b[0] == sof else { return nil }
        let length = Int(b[1]) | (Int(b[2]) & 0x03) << 8
        let version = b[2] >> 2
        guard length == b.count, version == Self.version else { return nil }
        guard CRC8.duml(Data(b[0..<3])) == b[3] else { return nil }
        let expectedCRC16 = UInt16(b[b.count - 1]) << 8 | UInt16(b[b.count - 2])
        guard CRC16.mcrf4xx(Data(b[0..<(b.count - 2)])) == expectedCRC16 else { return nil }
        return MimoFrame(
            sender: b[4],
            receiver: b[5],
            sequence: UInt16(b[6]) | UInt16(b[7]) << 8,
            cmdType: b[8],
            cmdSet: b[9],
            cmdId: b[10],
            payload: Data(b[headerLength..<(b.count - 2)])
        )
    }

    /// 在任意载荷中按文档规则扫描帧链（帧必须恰好收尾于载荷末尾，可多帧连排）。
    /// CRC 校验使加密视频载荷的误配几乎不可能通过。
    public static func scanPayload(_ data: Data) -> [MimoFrame] {
        let bytes = [UInt8](data)
        var frames: [MimoFrame] = []
        var i = 0
        while i < bytes.count - 3 {
            if bytes[i] == sof {
                let len = Int(bytes[i + 1]) | (Int(bytes[i + 2]) & 0x03) << 8
                if len >= minimumLength, i + len == bytes.count,
                   let frame = MimoFrame.parse(Data(bytes[i...])) {
                    frames.append(frame)
                    return frames
                }
            }
            i += 1
        }
        return frames
    }

    /// 编码（CRC8/CRC16 自动计算，结果与抓包帧逐字节一致）。
    public func encodedData() -> Data {
        var bytes: [UInt8] = [
            Self.sof, 0, 0, 0, sender, receiver,
            UInt8(sequence & 0xFF), UInt8(sequence >> 8),
            cmdType, cmdSet, cmdId,
        ]
        bytes.append(contentsOf: payload)
        let totalLength = bytes.count + 2 // 含 CRC16 两字节
        bytes[1] = UInt8(totalLength & 0xFF)
        bytes[2] = UInt8((totalLength >> 8) & 0x03) | (Self.version << 2)
        bytes[3] = CRC8.duml(Data(bytes[0..<3]))
        let crc = CRC16.mcrf4xx(Data(bytes))
        bytes.append(UInt8(crc & 0xFF))
        bytes.append(UInt8(crc >> 8))
        return Data(bytes)
    }
}

/// DUML 头校验：反射 poly 0x8C、init 0x77、无终态异或（样例帧验证，等价于查表实现）。
public enum CRC8 {
    public static func duml(_ data: Data) -> UInt8 {
        var crc: UInt8 = 0x77
        for b in [UInt8](data) {
            crc ^= b
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0x8C : crc >> 1
            }
        }
        return crc
    }
}

/// DUML 帧尾校验：CRC-16/MCRF4XX（反射 poly 0x8408、init 0x3692、无终态异或），线上小端存储。
public enum CRC16 {
    public static func mcrf4xx(_ data: Data) -> UInt16 {
        var crc: UInt16 = 0x3692
        for b in [UInt8](data) {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0x8408 : crc >> 1
            }
        }
        return crc
    }
}
