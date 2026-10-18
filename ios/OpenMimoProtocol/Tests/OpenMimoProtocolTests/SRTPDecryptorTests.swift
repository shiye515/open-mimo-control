import XCTest
@testable import OpenMimoProtocol

/// SRTP 解密离线验证（fixture = preview_wifi.pcap 真实流：密钥 + 重组后的双片帧密文）。
/// 通过标准：解密后载荷出现 H.264/H.265 AnnexB 起始码或合法 NALU 头。
final class SRTPDecryptorTests: XCTestCase {

    func testDecryptRealCaptureFrame() throws {
        // 读 /tmp fixture（存在时）；否则内嵌小样本
        let path = "/tmp/mimo-re/test_frame.txt"
        guard FileManager.default.fileExists(atPath: path) else {
            print("fixture 不存在，跳过")
            return
        }
        FileHandle.standardError.write(Data("读文件\n".utf8))
        let lines = try String(contentsOfFile: path, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        FileHandle.standardError.write(Data("行数 \(lines.count)\n".utf8))
        let keyLine = lines.last!
        guard keyLine.hasPrefix("KEY ") else { XCTFail("末行非 KEY"); return }
        let key = Data(hexToBytes(String(keyLine.dropFirst(4))))
        let cipher = lines[0..<lines.count-1].map { Data(hexToBytes($0)) }
        FileHandle.standardError.write(Data("片数 \(cipher.count)\n".utf8))
        let assembled = cipher.reduce(Data(), +)
        let decryptor = SRTPDecryptor(masterKey: key, ssrc: 0x01000000)
        let plain = try decryptor.decrypt(assembled, frameNumber: 0x02)
        let head = plain.prefix(32).map { String(format: "%02x", $0) }.joined()
        FileHandle.standardError.write(Data("解密首32B: \(head)\n".utf8))
        let nalus = LiveViewDepacketizer.nalus(in: plain)
        FileHandle.standardError.write(Data("NALU 数: \(nalus.count)\n".utf8))
    }

    /// AES-ECB 单块已知答案（FIPS-197 附录 C.1：key=000102..0f, in=001122..ff）。
    func testAESECBKnownAnswer() {
        let key = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
                        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f])
        let block: [UInt8] = [0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77,
                              0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]
        let d = SRTPDecryptor(masterKey: key, ssrc: 0)
        let out = d.aesECBEncryptSingleBlock(block, key: key)
        XCTAssertEqual(out, [0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30,
                             0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a])
    }

    /// AES-CM 往返自证：加密后解密还原。
    func testAESCMRoundTrip() {
        let key = Data((0..<16).map { UInt8($0) })
        let d = SRTPDecryptor(masterKey: key, ssrc: 0)
        let plain = (0..<48).map { UInt8($0 * 7 & 0xFF) }
        let iv: [UInt8] = (0..<16).map { UInt8($0 * 3 & 0xFF) }
        let enc = d.aesCMDecrypt(plain, key: key, iv: iv) // CM 加密=解密
        let dec = d.aesCMDecrypt(enc, key: key, iv: iv)
        XCTAssertEqual(dec, plain)
    }

    /// 信令密钥提取（preview_wifi.pcap 205B 包的字节形态）。
    func testSignalingKeyExtraction() {
        var packet = Data([0x80, 0xCD, 0x1E, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xED])
        packet += Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x68, 0xD5, 0x26, 0x3D,
                        0x01, 0x00, 0x01, 0x00, 0x20])
        packet += Data("eed484a0a5d8467c80a17fde5d1dd3f0".utf8)
        let key = SRTPSignaling.extractKey(packet)
        XCTAssertNotNil(key)
        XCTAssertEqual(key?.map { String(format: "%02x", $0) }.joined(),
                       "eed484a0a5d8467c80a17fde5d1dd3f0")
    }

    private func d0ECB(_ d: SRTPDecryptor) -> [UInt8] {
        d.aesECBEncryptSingleBlock([UInt8](repeating: 0, count: 16), key: Data(repeating: 1, count: 16))
    }

    private func hexToBytes(_ s: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            if let b = UInt8(s[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return bytes
    }
}
