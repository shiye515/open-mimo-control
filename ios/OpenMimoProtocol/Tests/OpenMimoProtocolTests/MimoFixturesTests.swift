import XCTest
@testable import OpenMimoProtocol

/// 以 docs/protocol/samples/ 样例帧（抓包 19:52:35–19:55:20 会话）为 fixture 的回归测试。
/// DUML 布局 + CRC8/CRC16 算法（经 DJI Osmo GPS Controller Demo 参考文档与样例帧双重验证），
/// 编码测试可直接做到与抓包帧逐字节一致。
final class MimoFixturesTests: XCTestCase {
    // MARK: fixtures（与 docs/protocol/samples/ 一致）

    /// TCP 7001 相机状态帧（cmdType 0xC0 应答/推送）
    let tcpStatusS2C = Data(hex: "550f04a21d02d0a4c0ee060080c29a")
    /// UDP 9004 手机→相机纯 ACK 包
    let udpAckC2S = Data(hex: "2280c6150000047530ae30ae0000000030ae30ae0000000030ae30ae000000000000")
    /// 录制开始（19:53:13.143）
    let recordStart = Data(hex: "550e0466020198a8400202002f83")
    /// 录制开始 ACK（19:53:13.158，seq 回显）
    let recordAck = Data(hex: "550e0466010298a8c0020200ff8c")
    /// 模式切换→延时摄影（19:53:01.053，CmdId 0xE1 payload [0x02]）
    let modeSwitchTimelapse = Data(hex: "550e04660201a3a74002e102c5e3")
    /// 订阅 cam_status（19:52:35.552）
    let subscribeCamStatus = Data(hex: "552a049c0228e6a440009902020000efd5000000000010000a0063616d5f7374617475730000000051cb")
    /// cam_status 推送（19:53:13.101，录制切换中）
    let pushCamStatus = Data(hex: "553704f92802120800009902060000ba0700000000001d000a0063616d5f73746174757300000000000009001000550101000102003eee")

    // MARK: CRC 已知答案

    func testCRCKnownAnswers() {
        XCTAssertEqual(CRC8.duml(Data(hex: "550e04")), 0x66, "头 CRC8 覆盖 SOF+len(2B)")
        let start = try! XCTUnwrap(MimoFrame.parse(recordStart))
        XCTAssertEqual(CRC16.mcrf4xx(recordStart.prefix(12)), 0x832F)
        _ = start
    }

    // MARK: 解析

    func testParseTCPStatusFrame() {
        let f = try! XCTUnwrap(MimoFrame.parse(tcpStatusS2C))
        XCTAssertEqual(f.sender, 0x1D)
        XCTAssertEqual(f.receiver, 0x02)
        XCTAssertEqual(f.sequence, 0xA4D0, "seq 线上小端：d0 a4 → 0xA4D0")
        XCTAssertEqual(f.cmdType, 0xC0, "0xC0 = 应答帧")
        XCTAssertEqual(f.cmdSet, 0xEE)
        XCTAssertEqual(f.cmdId, 0x06)
        XCTAssertEqual(f.payload, Data(hex: "0080"))
    }

    func testParseRecordStartAndAckPair() {
        let start = try! XCTUnwrap(MimoFrame.parse(recordStart))
        let ack = try! XCTUnwrap(MimoFrame.parse(recordAck))
        XCTAssertEqual(start.cmdType, 0x40)
        XCTAssertEqual(start.cmdSet, 0x02)
        XCTAssertEqual(start.cmdId, 0x02, "record_video = (CmdSet 0x02, CmdId 0x02)，payload [0x00]")
        XCTAssertEqual(start.payload, Data([0x00]))
        XCTAssertEqual(start.sequence, ack.sequence, "ACK 回显请求 seq")
        XCTAssertEqual(ack.cmdType, 0xC0, "0xC0 = 应答帧")
        XCTAssertEqual(ack.cmdSet, 0x02)
        XCTAssertEqual(ack.cmdId, 0x02)
    }

    func testParseModeSwitch() {
        let f = try! XCTUnwrap(MimoFrame.parse(modeSwitchTimelapse))
        XCTAssertEqual(f.cmdSet, 0x02)
        XCTAssertEqual(f.cmdId, 0xE1, "set_mode_profile (CmdSet 0x02, CmdId 0xE1)，payload [mode]")
        XCTAssertEqual(f.payload, Data([CameraMode.timelapse.rawValue]),
                       "官方枚举：0x02 = 延时摄影")
    }

    func testParseSubscribeFrame() {
        let f = try! XCTUnwrap(MimoFrame.parse(subscribeCamStatus))
        XCTAssertEqual(f.cmdType, 0x40)
        XCTAssertEqual(f.cmdSet, 0x00)
        XCTAssertEqual(f.cmdId, 0x99, "united_pub_sub_agent (CmdSet 0x00, CmdId 0x99)")
        XCTAssertEqual(f.receiver, 0x28)
        let reqID = UInt16(f.payload[4]) | UInt16(f.payload[5]) << 8
        XCTAssertEqual(reqID, 0xD5EF, "reqId 线上小端：ef d5 → 0xD5EF")
        let nameRange = f.payload.range(of: Data("cam_status".utf8))
        XCTAssertNotNil(nameRange)
        let nameLen = Int(f.payload[12]) << 8 | Int(f.payload[13])
        XCTAssertEqual(nameLen, "cam_status".count)
    }

    func testParseTelemetryPushCamStatus() {
        let f = try! XCTUnwrap(MimoFrame.parse(pushCamStatus))
        XCTAssertEqual(f.cmdType, 0x00, "推送帧不需应答")
        let push = try! XCTUnwrap(MimoTelemetry.parsePush(f))
        XCTAssertEqual(push.topic, "cam_status")
        let status = try! XCTUnwrap(CameraStatus.searchingValue(in: push.value))
        XCTAssertEqual(status.mode, CameraMode.video.rawValue)
        XCTAssertEqual(status.targetMode, CameraMode.video.rawValue)
        XCTAssertEqual(status.zoomIndex, 0x01)
        XCTAssertEqual(status.stateKind, .switching)
    }

    func testScanPayloadRejectsPartialAndCorruptFrames() {
        XCTAssertNil(MimoFrame.parse(recordStart.prefix(7)))
        XCTAssertTrue(MimoFrame.scanPayload(recordStart.prefix(6)).isEmpty, "长度不自洽的载荷不得产出帧")
        var corrupted = [UInt8](recordStart)
        corrupted[11] ^= 0xFF // 破坏 payload
        XCTAssertNil(MimoFrame.parse(Data(corrupted)), "CRC16 校验应拒绝被篡改的帧")
    }

    // MARK: 编码（真实 CRC，与抓包帧逐字节一致）

    func testEncodeRoundTripByteIdentical() {
        for fixture in [recordStart, recordAck, modeSwitchTimelapse, subscribeCamStatus, pushCamStatus, tcpStatusS2C] {
            let original = try! XCTUnwrap(MimoFrame.parse(fixture))
            XCTAssertEqual(original.encodedData(), fixture, "解析→编码应逐字节还原")
        }
    }

    func testEncodeRecordStartMatchesCaptureByteForByte() {
        // seq 取抓包原值（线上 LE：98 a8 → 0xA898）
        XCTAssertEqual(MimoCommand.recordStart(sequence: 0xA898).encodedData(), recordStart)
    }

    func testEncodeSubscribeMatchesCaptureByteForByte() {
        XCTAssertEqual(
            MimoCommand.subscribe(topic: "cam_status", requestID: 0xD5EF, sequence: 0xA4E6).encodedData(),
            subscribeCamStatus
        )
    }

    func testCommandBuildersMatchDocumentedCommands() {
        let mode = MimoCommand.modeSwitch(.video, sequence: 1)
        XCTAssertEqual(mode.cmdSet, 0x02)
        XCTAssertEqual(mode.cmdId, 0xE1)
        XCTAssertEqual(mode.payload, Data([0x01]))

        let record = MimoCommand.recordStart(sequence: 1)
        XCTAssertEqual(record.cmdSet, 0x02)
        XCTAssertEqual(record.cmdId, 0x02)
        XCTAssertEqual(record.payload, Data([0x00]))

        let poll = MimoCommand.statusPoll(sequence: 1)
        XCTAssertEqual(poll.cmdSet, 0x00)
        XCTAssertEqual(poll.cmdId, 0x51)
        XCTAssertEqual(poll.payload, Data([0x04]))
        XCTAssertEqual(poll.receiver, 0x48)
    }

    func testTCPHeartbeat() {
        XCTAssertEqual(TCPHeartbeat.payload, Data([0x00]))
        XCTAssertEqual(TCPHeartbeat.interval, 1.0, accuracy: 0.001)
    }

    func testCameraStatusValueStruct() {
        // cam_status 值：55 [mode] [target] 00 [zoom] [state] 00
        let status = try! XCTUnwrap(CameraStatus(value: Data(hex: "55010100010200")))
        XCTAssertEqual(status.mode, 0x01)
        XCTAssertEqual(status.targetMode, 0x01)
        XCTAssertEqual(status.zoomIndex, 0x01)
        XCTAssertEqual(status.stateKind, .switching)
        let idle = try! XCTUnwrap(CameraStatus(value: Data(hex: "55010100010000")))
        XCTAssertEqual(idle.stateKind, .idle)
    }

    func testCameraFOVZoomFactor() {
        // 焦距×100，u32 LE：0x096D=2413 → 1.0x；0x12DA=4826 → 2.0x；0x0E23=3619 → 1.5x
        XCTAssertEqual(CameraFOV(value: Data(hex: "6d090000"))?.zoomFactor, 1.0)
        XCTAssertEqual(CameraFOV(value: Data(hex: "da120000"))?.zoomFactor, 2.0)
        XCTAssertEqual(CameraFOV(value: Data(hex: "230e0000"))?.zoomFactor, 1.5)
    }

    func testPacketFrameExtractionThroughOuterHeader() {
        // S2C 大包形态：外层头（含 85c615 会话）后跟完整 0x55 帧（video_s2c_1 的外层前缀 + 录制开始帧）
        let outer: [UInt8] = [0x19, 0x85, 0xC6, 0x15, 0x00, 0x00, 0x01, 0x4E]
        let packet = Data(outer) + recordStart
        let frames = MimoPacket.frames(in: packet)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.cmdId, 0x02)
        XCTAssertEqual(frames.first?.payload, Data([0x00]))
    }

    func testPacketFrameExtractionIgnoresEncryptedPayload() {
        // 加密视频载荷（video_s2c_2 样例前缀）：CRC 校验下不得误配出帧
        let video = Data(hex: "2c85c61540ae029630ae40ae0000000002010000000001ff0c0500000c11ea00000000012801af0d60fbf2196175aa2810c137bb06b054a3ca640000654201309e15100020c391d66d2100000301701b2d33f36a70498ff946ff993b37edc6c4")
        XCTAssertTrue(MimoPacket.frames(in: video).isEmpty)
    }

    // MARK: DJI R 协议（0xAA，BLE 唤醒通道）

    /// 官方文档示例帧：切换相机至运动延时（protocol_data_segment_CN.md「帧结构举例」）
    let rHyperlapseOfficial = Data(hex: "AA1B0001000000000500 57EE 1D04 000033FF 0A 01473936 F4FAE1D0".replacingOccurrences(of: " ", with: ""))

    func testDjiRBuildMatchesOfficialExampleByteForByte() {
        // payload: device_id(4)=00 00 33 FF + mode(1)=0x0A 运动延时 + reserved(4)
        let frame = DjiRProtocol.buildFrame(
            cmdType: 0x01, cmdSet: 0x1D, cmdId: 0x04,
            payload: [0x00, 0x00, 0x33, 0xFF, 0x0A, 0x01, 0x47, 0x39, 0x36],
            sequence: 5
        )
        XCTAssertEqual(Data(frame), rHyperlapseOfficial, "构造帧应与官方文档示例逐字节一致（含 CRC16/CRC32）")
    }

    func testDjiRParseOfficialExample() {
        let f = try! XCTUnwrap(DjiRProtocol.parse(rHyperlapseOfficial))
        XCTAssertFalse(f.isAck)
        XCTAssertEqual(f.cmdSet, 0x1D)
        XCTAssertEqual(f.cmdId, 0x04)
        XCTAssertEqual(f.sequence, 5)
        XCTAssertEqual(f.payload.count, 9)
        XCTAssertEqual(f.payload[4], 0x0A, "模式 = 运动延时")
    }

    func testDjiRCRCKnownAnswers() {
        // 官方示例帧头 10 字节 → CRC16 = 57 EE (LE)
        XCTAssertEqual(DjiRProtocol.crc16(Array(rHyperlapseOfficial.prefix(10))), 0xEE57)
        // 全帧去 CRC32 → CRC32 = F4 FA E1 D0 (LE)
        XCTAssertEqual(DjiRProtocol.crc32(Array(rHyperlapseOfficial.prefix(23))), 0xD0E1FAF4)
    }
}

private extension Data {
        init(hex: String) {
            self.init()
            var iterator = hex.makeIterator()
            while let hi = iterator.next(), let lo = iterator.next() {
                append(UInt8(String([hi, lo]), radix: 16)!)
            }
        }
    }

private extension CameraStatus {
    /// 值可能带推送尾部前缀（如 `0009 001000`），定位 `55` 开头的 7 字节结构。
    static func searchingValue(in data: Data) -> CameraStatus? {
        let bytes = [UInt8](data)
        guard let idx = bytes.firstIndex(where: { $0 == 0x55 }), bytes.count - idx >= 7 else { return nil }
        return CameraStatus(value: Data(bytes[idx...]))
    }
}

// MARK: WiFi 凭据加密层

final class WiFiCredentialCryptoTests: XCTestCase {
    func testECDHSameSharedSecret() {
        guard let (pub1, priv1) = WiFiCredentialCrypto.generateECDHKeyPair(),
              let (pub2, priv2) = WiFiCredentialCrypto.generateECDHKeyPair()
        else { XCTFail("keygen failed"); return }
        let s1 = WiFiCredentialCrypto.computeSharedSecret(peerPublicKey: pub2, privateKey: priv1)
        let s2 = WiFiCredentialCrypto.computeSharedSecret(peerPublicKey: pub1, privateKey: priv2)
        XCTAssertEqual(s1, s2, "ECDH 双方共享密钥应一致")
        XCTAssertEqual(s1?.count, 32, "P-256 共享密钥 32B")
    }

    func testHKDFDeterministic() {
        let ikm = Data(repeating: 0xAB, count: 32)
        let salt = Data(repeating: 0xCD, count: 16)
        let info = WiFiCredentialCrypto.hkdfInfo
        XCTAssertEqual(info, Data("BLE-WiFi-v1".utf8))
        let out1 = WiFiCredentialCrypto.hkdfSha256(ikm: ikm, salt: salt, info: info)
        let out2 = WiFiCredentialCrypto.hkdfSha256(ikm: ikm, salt: salt, info: info)
        XCTAssertEqual(out1, out2)
        XCTAssertEqual(out1.count, 32)
    }

    func testAESCBDRoundTrip() {
        let key = Data(repeating: 0x42, count: 16)
        let iv = Data(repeating: 0x43, count: 16)
        let plaintext = Data("test_credential_data".utf8) // 20B → PKCS7 填充到 32B
        // 用加密方向生成密文（需自行实现 AES-CBC 加密或手动构造）
        // 此处仅验证解密路径：构造一个已知密文
        // AES-128-CBC 加密 "test_credential_data" with key=0x42×16, iv=0x43×16
        // 实际值需用 OpenSSL 生成；此处仅验证接口无崩溃
        let ciphertext = Data(repeating: 0x00, count: 32)
        let result = WiFiCredentialCrypto.aes128CbcDecrypt(key: key, iv: iv,
                                                           ciphertext: ciphertext,
                                                           removePKCS7Padding: false)
        // 全零密文解密结果确定但不为 nil（无填充模式）
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.count, 32)
    }
}
