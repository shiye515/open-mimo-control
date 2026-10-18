import Foundation

/// UDP 9004 外层封装（docs/protocol/control-channel.md §3）。
///
/// **C2S 业务包头（2026-10-28 pcap 逐包序列破译，20B）**：
/// `[len][session:3][seq8:2 LE 步进+8/包][token:2 =05xx][ackBase:2][seq8回显:2][0000][外层序号:4 LE 逐包+1 起始0x0101][帧…]`
/// - seq8：u16 LE（官方 0xae38→0xae40→…逐包 +8），ackBase 滞后约 4 包回显；
/// - 外层序号：u32 LE（官方 0x0101→0x0102→…逐包 +1）；
/// - 相机 S2C 的 ACK 窗回显 seq8（50ae50ae 实证），证明相机解析这些字段；
/// - token 字段官方恒 0x05 前缀（05e3/0599/0595…低字节变化，语义未定）。
///
/// **S2C 包头（相机→手机）**：`[len][session:3][seq:4 LE][30ae30ae 00000000 ×3][尾2B][帧…]`（111B/34B 实证）。
/// 9B 心跳（`09 80c615 0000005a 01`）为最短形态 `[len][session:3][seq:4]`；
/// 48B 保活/统计包（`30` 开头）为独立形态。
/// 历史：旧实现（seq@4-7 + 全 0 块）与官方业务包不符——相机静默无视全部业务帧，仅 48B 保活帧得到 9B 应答。
public struct MimoPacket: Equatable, Sendable {
    public static let port = 9004

    public let session: Data
    /// seq8 字段：u16 LE，调用方负责每包 +8（官方步进）
    public let seq8: UInt16
    /// 外层序号：u32 LE，调用方负责每包 +1（官方起始 0x0101）
    public let sequence: UInt32
    public let frames: [MimoFrame]

    public init(session: Data, seq8: UInt16, sequence: UInt32, frames: [MimoFrame]) {
        self.session = session
        self.seq8 = seq8
        self.sequence = sequence
        self.frames = frames
    }

    /// 编码 C2S 业务包（官方样例：35B 握手包 `2380c615 38ae05e3 30ae38ae 00000000 01010000 55…`）。
    public func encodedData() -> Data {
        var bytes: [UInt8] = [0]
        bytes.append(contentsOf: [UInt8](session))
        // [4..5] seq8 u16 LE；ackBase = seq8 - 8×4（官方滞后回显模式）
        let ackBase = seq8 &- 8 &* 4
        bytes.append(UInt8(truncatingIfNeeded: seq8))
        bytes.append(UInt8(truncatingIfNeeded: seq8 >> 8))
        // [6..7] token：官方观测为 [0x05, xx]（05 前缀在前，低字节变化，语义未定；固定 0x0501）
        bytes.append(contentsOf: [0x05, 0x01])
        // [8..9] ackBase / [10..11] seq8 回显
        bytes.append(UInt8(truncatingIfNeeded: ackBase))
        bytes.append(UInt8(truncatingIfNeeded: ackBase >> 8))
        bytes.append(UInt8(truncatingIfNeeded: seq8))
        bytes.append(UInt8(truncatingIfNeeded: seq8 >> 8))
        // [12..15] 0000
        bytes.append(contentsOf: [0, 0, 0, 0])
        // [16..19] 外层序号 u32 LE
        bytes.append(UInt8(truncatingIfNeeded: sequence))
        bytes.append(UInt8(truncatingIfNeeded: sequence >> 8))
        bytes.append(UInt8(truncatingIfNeeded: sequence >> 16))
        bytes.append(UInt8(truncatingIfNeeded: sequence >> 24))
        for frame in frames {
            bytes.append(contentsOf: [UInt8](frame.encodedData()))
        }
        bytes[0] = UInt8(bytes.count)
        return Data(bytes)
    }

    /// 从 S2C 包提取全部 `0x55` 帧（不依赖首字节长度规则）。
    public static func frames(in payload: Data) -> [MimoFrame] {
        MimoFrame.scanPayload(payload)
    }
}

/// TCP 7001 辅助通道的心跳（docs/protocol/control-channel.md §2）：
/// 手机每 1s 发送单字节 0x00。
public enum TCPHeartbeat {
    public static let port = 7001
    public static let interval: TimeInterval = 1.0
    public static let payload = Data([0x00])
}
