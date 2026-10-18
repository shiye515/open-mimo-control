import Foundation

/// 实时预览流解封装（docs/protocol/live-view.md §2/§5，2026-10-28 pcap 破译）。
///
/// UDP 9004 S2C 大包（会话变体 85c615）：
/// `[len][session:3][seq8:2][seqB:2][ack:2][seq8回显:2][0000][帧号:1][片号|0x80:1][00][末片01:1][载荷…]`
/// - 首片载荷前 15B 为子头：`000001ff [ts:2] [0000 0c11] [seq:1] [00000000] [01 02 01 d0]`；
/// - 续片载荷为纯密文；
/// - 内嵌 `0x55` 控制帧（遥测推送等）与大包多路复用——由 `MimoFrame.scanPayload` 剥离；
/// - 载荷高熵（加密），解密经 `VideoDecrypting` 可插拔——native 证据指向 SRTP
///   （libDJIVideoJNI: ff_srtp_decrypt / SRTP_AES128_CM_HMAC_SHA1_80），密钥协商通道未定。
public struct LiveViewDepacketizer {

    private let decryptor: VideoDecrypting
    private var frames: [UInt8: (frags: [Data], lastSeen: Bool)] = [:]
    private var lastFrameNo: UInt8?

    /// 重组出的一帧（密文或明文，取决于 decryptor）。
    public struct Frame {
        public let frameNumber: UInt8
        public let payload: Data
        public let isDecrypted: Bool
    }

    /// 解密接口：实现方提供会话密钥（SRTP/AES-CTR 等）。
    public protocol VideoDecrypting {
        func decrypt(_ ciphertext: Data, frameNumber: UInt8) throws -> Data
    }

    /// 直通解密器（未拿到密钥前的占位：输出原密文）。
    public struct PassthroughDecryptor: VideoDecrypting {
        public init() {}
        public func decrypt(_ ciphertext: Data, frameNumber: UInt8) throws -> Data { ciphertext }
    }

    public init(decryptor: VideoDecrypting = PassthroughDecryptor()) {
        self.decryptor = decryptor
    }

    /// 喂入一个 S2C 大包（已剥 UDP/IP 头）。返回重组完成的帧（可能 0/1 个）。
    ///
    /// 帧结束判定（pcap 实证两种）：
    /// 1. `b[19] == 0x01` 显式末片标志（多片帧的最后一片）；
    /// 2. 帧号推进（下一包帧号 != 当前）——单片帧无末片标志，靠这个冲刷。
    public mutating func ingest(_ packet: Data, onControl: ((MimoFrame) -> Void)? = nil) throws -> Frame? {
        guard packet.count > 20 else { return nil }
        let b = [UInt8](packet)

        // 内嵌控制帧剥离：相机在视频流中复用 0x55 帧（遥测推送等）
        for frame in MimoPacket.frames(in: packet) {
            onControl?(frame)
        }

        let frameNo = b[16]
        let fragIdx = b[17] & 0x7F
        let isContinuation = b[17] & 0x80 != 0
        let isLast = b[19] == 0x01

        // 帧号推进 → 冲刷未完的上一帧（单片帧无显式末片标志）
        var flushed: Frame?
        if let prev = lastFrameNo, prev != frameNo, entryExists(prev) {
            flushed = complete(prev)
        }
        lastFrameNo = frameNo

        // 载荷起点：首片剥 15B 子头（000001ff 开头），续片从 20 起
        var payloadStart = 20
        if !isContinuation, b[20] == 0x00, b[21] == 0x00, b[22] == 0x01, b[23] == 0xFF {
            payloadStart = 40 // 20 业务头 + 20 子头（000001ff + ts2 + 0000 + 0c11 + seq1 + 00000000 + 010201d0）
        }

        guard packet.count > payloadStart else { return flushed }
        let chunk = packet[payloadStart...]

        var entry = frames[frameNo] ?? ([], false)
        entry.frags.append(Data(chunk))
        entry.lastSeen = isLast
        frames[frameNo] = entry

        if isLast, let done = complete(frameNo) {
            return done
        }
        return flushed
    }

    private func entryExists(_ no: UInt8) -> Bool {
        frames[no]?.frags.isEmpty == false
    }

    /// 完成帧号 no 的重组并解密。
    private mutating func complete(_ no: UInt8) -> Frame? {
        guard let entry = frames.removeValue(forKey: no), !entry.frags.isEmpty else { return nil }
        let assembled = entry.frags.reduce(Data(), +)
        if frames.count > 32 { frames.removeAll() } // 防泄漏窗口
        do {
            let plain = try decryptor.decrypt(assembled, frameNumber: no)
            return Frame(frameNumber: no, payload: plain, isDecrypted: true)
        } catch {
            return Frame(frameNumber: no, payload: assembled, isDecrypted: false)
        }
    }

    /// 从解密后载荷探测 H.264/H.265 NALU（AnnexB 起始码）。密钥未解前返回空。
    public static func nalus(in data: Data) -> [Range<Data.Index>] {
        let b = [UInt8](data)
        var ranges: [Range<Data.Index>] = []
        var i = 0
        while i + 4 <= b.count {
            if b[i] == 0, b[i + 1] == 0, b[i + 2] == 0, b[i + 3] == 1 {
                let start = i + 4
                var end = b.count
                var j = start
                while j + 4 <= b.count {
                    if b[j] == 0, b[j + 1] == 0, b[j + 2] == 0, b[j + 3] == 1 { end = j; break }
                    j += 1
                }
                ranges.append(start..<end)
                i = end
            } else {
                i += 1
            }
        }
        return ranges
    }
}
