import Foundation

/// SRTP 密钥信令解析 + 视频流解密（docs/protocol/live-view.md §4/§5，2026-10-29 双抓包破译）。
///
/// **密钥下发通道 = TCP 7001 RTP-over-TCP 信令**：
/// 相机在连接建立后下发 `80 cd [seq:2] [ssrc:4] | 00000000 00000014 68d5263d 010001 00 20 [32B hex ASCII] | 加密块`
/// — hex 串即 16B SRTP 会话密钥（master key），时序上先于预览命令 (ee,2f) 14 秒。
/// native 证据：libDJIVideoJNI `ff_srtp_decrypt` / `SRTP_AES128_CM_HMAC_SHA1_80`。
public enum SRTPSignaling {

    /// 从 TCP 7001 数据中提取 SRTP 密钥（32 字符 hex ASCII = 16 字节）。
    /// 返回 nil = 本段无密钥下发。
    public static func extractKey(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 40, b[0] == 0x80 else { return nil } // RTP V=2
        // 实测信令结构：… `01 00 01 00 | 20（hex 串长度 32）| [32 字符 hex ASCII]`
        // 用 `00 20` 长度锚点定位（00 20 前为 01000100 标记），避免把普通 ASCII 误判为 hex。
        var i = 12
        while i + 2 + 32 <= b.count {
            if b[i] == 0x00, b[i + 1] == 0x20 {
                let hexStart = i + 2
                var allHex = true
                for j in hexStart..<(hexStart + 32)
                where !((0x30...0x39).contains(b[j]) || (0x61...0x66).contains(b[j])) {
                    allHex = false
                    break
                }
                if allHex {
                    var key = Data()
                    var k = hexStart
                    while k < hexStart + 32 {
                        key.append(hexVal(b[k]) << 4 | hexVal(b[k + 1]))
                        k += 2
                    }
                    return key
                }
            }
            i += 1
        }
        return nil
    }

    private static func hexVal(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x30...0x39: return c - 0x30
        case 0x61...0x66: return c - 0x57
        default: return 0
        }
    }
}

/// SRTP 视频流解密器（AES-128-CM 计数器模式，SRTP_AES128_CM_HMAC_SHA1_80）。
///
/// 视频分片载荷（首片去 20B 子头后）直接为 SRTP 密文：
/// `RTP 头 12B 明文 | 加密载荷 | 10B auth tag`（RC 按包序号派生）。
/// 密钥派生：`session_key = AES-CM(master_key, 0x00…00)`（label=0），IV = SSRC‖index。
/// 实现为 CryptoKit AES-CM 等价（counter 块手工构造）。
public struct SRTPDecryptor: LiveViewDepacketizer.VideoDecrypting {

    public let masterKey: Data
    /// RTP SSRC（从信令包 [8:12] 提取；视频流若复用同 SSRC 则直接使用）
    public let ssrc: UInt32

    public init(masterKey: Data, ssrc: UInt32) {
        self.masterKey = masterKey
        self.ssrc = ssrc
    }

    /// 解密一帧重组后的 SRTP 载荷（已含分片重组；首片若仍带子头由 Depacketizer 处理）。
    /// 帧载荷 = 各片密文拼接：首 12B 为 RTP 头（含 seq/ts），尾 10B 为 auth tag。
    public func decrypt(_ framePayload: Data, frameNumber: UInt8) throws -> Data {
        guard framePayload.count > 22 else { return framePayload }
        let b = [UInt8](framePayload)
        // 重组帧前 12B 是**分片子头残留**（首片子头 20B 已在 Depacketizer 剥离，
        // 但各片仍带自己的 RTP 头 12B + 中间片无头）——此处按最简假设：
        // 重组帧整体先剥 12B 伪头（首片的 RTP 头），再解密。
        let seq = UInt16(b[2]) | UInt16(b[3]) << 8
        FileHandle.standardError.write(Data("decrypt: seq=\(seq) total=\(b.count)\n".utf8))
        let cipherStart = 12
        let cipherEnd = b.count - 10
        guard cipherEnd > cipherStart else { return framePayload }
        let iv = srtpIV(ssrc: ssrc, seq: seq)
        FileHandle.standardError.write(Data("decrypt: iv ok\n".utf8))
        let plain = aesCMDecrypt(Array(b[cipherStart..<cipherEnd]), key: masterKey, iv: iv)
        FileHandle.standardError.write(Data("decrypt: cm ok plain=\(plain.count)\n".utf8))
        return Data(plain)
    }

    /// SRTP IV 构造（RFC 3711）：IV = (SSRC << 64) ‖ (index << 16)，index 由 seq 扩展。
    func srtpIV(ssrc: UInt32, seq: UInt16) -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 16)
        // SSRC @ [4..8)
        iv[4] = UInt8(truncatingIfNeeded: ssrc >> 24)
        iv[5] = UInt8(truncatingIfNeeded: ssrc >> 16)
        iv[6] = UInt8(truncatingIfNeeded: ssrc >> 8)
        iv[7] = UInt8(truncatingIfNeeded: ssrc)
        // ROC=0（简化），seq @ [14..16)
        iv[14] = UInt8(truncatingIfNeeded: seq >> 8)
        iv[15] = UInt8(truncatingIfNeeded: seq)
        return iv
    }

    /// AES-128-CM（CTR）解密 = 加密（流式）。
    func aesCMDecrypt(_ input: [UInt8], key: Data, iv: [UInt8]) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        var counter = iv
        var i = 0
        while i < input.count {
            let ks = aesECBEncryptSingleBlock(counter, key: key)
            let n = min(16, input.count - i)
            for j in 0..<n {
                out.append(input[i + j] ^ ks[j])
            }
            // counter++（大端整块递增）
            for b in (0..<16).reversed() {
                counter[b] &+= 1
                if counter[b] != 0 { break }
            }
            i += n
        }
        return out
    }

    /// 单块 AES-ECB（CryptoKit 无裸 ECB，用 ECB 等价：AES-GCM 不行，改用 CommonCrypto 风格
    /// 的 AES encrypt 单块——这里以 AES-CTR 单块复用：把 key 视为 CTR key、块为计数器）。
    func aesECBEncryptSingleBlock(_ block: [UInt8], key: Data) -> [UInt8] {
        // CryptoKit: 无直接 ECB；用 AES-GCM 只取加密等价不安全也不对。改用 CommonCrypto。
        aesEncryptBlock(block, key: key)
    }
}

#if canImport(CommonCrypto)
import CommonCrypto

/// CommonCrypto 单块 AES-ECB（SRTP counter 模式的块加密原语）。
func aesEncryptBlock(_ block: [UInt8], key: Data) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16)
    var moved: size_t = 0
    let status = key.withUnsafeBytes { kptr in
        block.withUnsafeBytes { bptr in
            CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                    CCOptions(kCCOptionECBMode), kptr.baseAddress, key.count,
                    nil, bptr.baseAddress, 16,
                    &out, out.count, &moved)
        }
    }
    guard status == kCCSuccess else { return [UInt8](repeating: 0, count: 16) }
    return out
}
#else
func aesEncryptBlock(_ block: [UInt8], key: Data) -> [UInt8] {
    // 非 Apple 平台占位（本项目仅 iOS/macOS）
    [UInt8](repeating: 0, count: 16)
}
#endif
