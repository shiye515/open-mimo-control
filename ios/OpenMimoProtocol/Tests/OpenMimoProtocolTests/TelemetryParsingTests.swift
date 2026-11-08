import XCTest
@testable import OpenMimoProtocol

/// 遥测解析单元测试（fixtures 来自 docs/protocol/samples/ 与真机实测帧）。
final class TelemetryParsingTests: XCTestCase {

    /// pcap 样例 push_camstatus_s2c.bin：cam_status 推送，值区 `55 01 01 00 01 0200`。
    func testParsePushCamStatusFromPcapFixture() {
        // 帧 = 55 3704 f9 | 28 02 | 1208 | 00 | 99 | 02 | …name… | 值
        let hex = "553704f92802120800009902060000ba0700000000001d000a0063616d5f737461747573" +
                  "00000000000009001000550101000102003eee"
        let frame = hexToFrame(hex)
        let push = MimoTelemetry.parsePush(frame)
        XCTAssertNotNil(push)
        XCTAssertEqual(push?.topic, "cam_status")
        let status = locateCameraStatus(push!.value)
        XCTAssertEqual(status?.mode, 0x01)       // 视频
        XCTAssertEqual(status?.targetMode, 0x01)
        XCTAssertEqual(status?.zoomIndex, 0x01)  // 变焦 2 档
        XCTAssertEqual(status?.state, 0x02)      // 切换中
    }

    /// parsePush 应拒绝非主题名的伪匹配。
    func testParsePushRejectsNonTopic() {
        let frame = MimoFrame(sender: 0x01, receiver: 0x02, sequence: 1,
                              cmdType: 0x00, cmdSet: 0x99, cmdId: 0x02,
                              payload: Data([0x00, 0x05, 0x00, 0x41, 0x42, 0x43, 0x44, 0x45]))
        XCTAssertNil(MimoTelemetry.parsePush(frame)) // "ABCDE" 不满足小写/下划线/数字白名单? A-E 是大写 → 拒绝
    }

    /// 1D02 相机状态推送解析：38B，电量 @37（真机验证前的合成 fixture）。
    func testCameraStatusV2Parse() {
        var b = [UInt8](repeating: 0, count: 38)
        b[0] = 0x01                 // 视频
        b[1] = 0x03                 // 拍摄中
        b[2] = 45                   // 2.7K 16:9
        b[3] = 6                    // 60fps
        b[5] = 0x07; b[6] = 0x00    // 录制 7s
        let cap = 62_319            // SD 剩余 MB
        b[15] = UInt8(cap & 0xFF); b[16] = UInt8((cap >> 8) & 0xFF)
        b[17] = UInt8((cap >> 16) & 0xFF); b[18] = UInt8((cap >> 24) & 0xFF)
        b[37] = 86                  // 电量 86%
        let v2 = CameraStatusV2(value: Data(b))
        XCTAssertNotNil(v2)
        XCTAssertEqual(v2?.mode, 0x01)
        XCTAssertEqual(v2?.cameraState, 0x03)
        XCTAssertEqual(v2?.resolution, 45)
        XCTAssertEqual(v2?.fpsIndex, 6)
        XCTAssertEqual(v2?.recordTime, 7)
        XCTAssertEqual(v2?.remainCapacityMB, 62_319)
        XCTAssertEqual(v2?.batteryPercent, 86)
        // 过短拒绝
        XCTAssertNil(CameraStatusV2(value: Data(b.prefix(37))))
    }

    /// cam_record_time / cam_storage 值解析（含前缀容忍）。
    func testRecordTimeAndStorageValueParsing() {
        // cam_record_time：值区 [0006][2B][seconds:4 LE]，前缀 pad 容忍
        let rt = RecordTime(value: Data([0x00, 0x00, 0x00, 0x00, 0x06, 0x00, 0x0C, 0x00, 0x00, 0x00]))
        XCTAssertEqual(rt?.seconds, 12)
        // cam_storage：真实样例（video_s2c_1.hex + telemetry.md §4 拼合）：
        // pad(4) + len(1600) + 值 22B：0012 0100 0001 | total=f3cf0100 | free=b0c20100 | 00000000 | photo=5f220000
        let value = Data(hexToBytes("00000000" + "00001600001201000001f3cf0100b0c20100000000" + "5f220000"))
        let st = StorageInfo(value: value)
        XCTAssertEqual(st?.totalMB, 0x1cff3)  // 118,259 MB ≈ 128GB 卡
        XCTAssertEqual(st?.freeMB, 0x1c2b0)   // 115,408 MB
    }

    /// MockCameraLink 注入 1D02 推送 → 会话遥测更新电量（端到端解析路径）。
    func testSessionConsumes1D02Push() async throws {
        let link = MockCameraLink()
        let session = CameraSession(link: link)
        await session.start()
        // 等待 open 完成
        try await Task.sleep(nanoseconds: 200_000_000)

        var b = [UInt8](repeating: 0, count: 38)
        b[0] = 0x01; b[1] = 0x01; b[37] = 73
        let frame = MimoFrame(sender: 0x01, receiver: 0x02, sequence: 1,
                              cmdType: 0x00, cmdSet: 0x1D, cmdId: 0x02, payload: Data(b))
        link.inject(frame)

        var got: TelemetrySnapshot?
        let stream = await session.events()
        let deadline = Date().addingTimeInterval(3)
        for await event in stream {
            if case .telemetryChanged(let t) = event, t.batteryPercent != nil {
                got = t
                break
            }
            if Date() > deadline { break }
        }
        XCTAssertEqual(got?.batteryPercent, 73)
        await session.stop()
    }

    // MARK: - 辅助（不走 CameraSession 私有 locate 的独立验证）

    private func locateCameraStatus(_ value: Data) -> CameraStatus? {
        let bytes = [UInt8](value)
        guard let idx = bytes.firstIndex(of: 0x55), bytes.count - idx >= 7 else { return nil }
        return CameraStatus(value: Data(bytes[idx...]))
    }

    private func hexToBytes(_ hex: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return bytes
    }

    private func hexToFrame(_ hex: String) -> MimoFrame {
        let data = Data(hexToBytes(hex))
        return MimoFrame.parse(data)!
    }
}
