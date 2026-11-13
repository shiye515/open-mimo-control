import XCTest
@testable import OpenMimoProtocol

/// OSMO 状态解析偏移锁定测试——字节布局来自 osmocam PROTOCOL.md §7/§8，
/// 偏移写错会导致整块状态显示错值，用合成帧锁死。
final class OSMOStatusParsingTests: XCTestCase {

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }
    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    // MARK: 02/80 相机状态（§8.1）

    func testCameraStatusPush() {
        var p = [UInt8](repeating: 0, count: 58)
        p[0] = 0x80                       // bits6-7 = 10 = 2 录制中
        p[2] = 0x08                       // 写文件
        p[3] = 0x40                       // 媒体库模式
        p[4] = 1                          // 工作态 = 视频
        p.replaceSubrange(5...8, with: le32(61_440))           // 总 60GB
        p.replaceSubrange(9...12, with: le32(24_576))          // 余 24GB
        p.replaceSubrange(13...16, with: le32(0))              // 视频模式无剩余张数
        p.replaceSubrange(17...20, with: le32(1_890))          // 剩余 1890s
        p.replaceSubrange(29...32, with: le32(75))             // 已录 75s
        p[57] = 0x01                      // 拍摄模式 = 视频

        let t = OSMOStatusTracker()
        var modes: [UInt8] = []
        t.onCaptureModeChanged = { modes.append($0) }
        t.handle(cmdSet: 0x02, cmdId: 0x80, sender: 0x01, payload: Data(p))

        XCTAssertEqual(t.snapshot.recordState, 2)
        XCTAssertTrue(t.snapshot.isWritingFile)
        XCTAssertTrue(t.snapshot.mediaMode)
        XCTAssertEqual(t.snapshot.workMode, 1)
        XCTAssertEqual(t.snapshot.totalStorageMB, 61_440)
        XCTAssertEqual(t.snapshot.freeStorageMB, 24_576)
        XCTAssertEqual(t.snapshot.photosLeft, nil)     // 0 → 保留 nil
        XCTAssertEqual(t.snapshot.videoSecondsLeft, 1_890)
        XCTAssertEqual(t.snapshot.clipSeconds, 75)
        XCTAssertEqual(t.snapshot.captureMode, 0x01)
        XCTAssertEqual(t.snapshot.captureModeName, "视频")
        XCTAssertEqual(modes, [0x01])                  // 模式变化触发重查
    }

    // MARK: 0D/02 电池（§8.2）

    func testBatteryPush() {
        var p = [UInt8](repeating: 0, count: 21)
        p.replaceSubrange(1...4, with: le32(3_850))            // 3850mV
        p.replaceSubrange(5...8, with: le32(UInt32(bitPattern: Int32(-412))))  // 放电 412mA
        p.replaceSubrange(17...18, with: le16(286))            // 28.6°C
        p[20] = 78                        // 78%

        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x0D, cmdId: 0x02, sender: 0x05, payload: Data(p))

        XCTAssertEqual(t.snapshot.batteryVoltageMV, 3_850)
        XCTAssertEqual(t.snapshot.batteryCurrentMA, -412)
        XCTAssertEqual(t.snapshot.batteryTempDeciC, 286)
        XCTAssertEqual(t.snapshot.batteryPercent, 78)
    }

    // MARK: 02/DC 存储明细（§8.5）

    func testStoragePush() {
        var p = [UInt8](repeating: 0, count: 32)
        p.replaceSubrange(6...9, with: le32(61_440))           // microSD 60GB
        p.replaceSubrange(10...13, with: le32(24_576))         // 余 24GB
        p.replaceSubrange(24...27, with: le32(32_768))         // 内置 32GB
        p.replaceSubrange(28...31, with: le32(10_240))         // 余 10GB

        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x02, cmdId: 0xDC, sender: 0x01, payload: Data(p))

        XCTAssertEqual(t.snapshot.sdTotalMB, 61_440)
        XCTAssertEqual(t.snapshot.sdFreeMB, 24_576)
        XCTAssertEqual(t.snapshot.internalTotalMB, 32_768)
        XCTAssertEqual(t.snapshot.internalFreeMB, 10_240)
    }

    // MARK: 00/99 主题推送（§8.3）

    private func topicFrame(name: String, data: [UInt8]) -> Data {
        var f: [UInt8] = [0x02, 0x06, 0x00, 0x00, 0x34, 0x12, 0, 0, 0, 0, 0]
        f += le16(UInt16(name.utf8.count + 6 + 2 + data.count))
        f += le16(UInt16(name.utf8.count))
        f += Array(name.utf8)
        f += [0, 0, 0, 0, 0, 0]           // 00×6
        f += le16(UInt16(data.count))
        f += data
        return Data(f)
    }

    func testExpoParamTopic() {
        var d = [UInt8](repeating: 0, count: 41)
        d[6] = 0x13                       // EV 码 0x13（视频模式直读）
        d[7] = 0x01                       // 曝光模式 = 自动
        d[11] = 0x07                      // ISO 档码 = 0x07（1600 档，自动曝光）
        d[15] = 0x07                      // 测光 = -1 EV（07=-3EV…16=0…19=+3EV）
        d.replaceSubrange(16...17, with: le16(3200))           // 生效 ISO 3200（u16 模拟增益分量）
        d.replaceSubrange(20...21, with: le16(0x8019))         // 生效快门 1/25s
        d.replaceSubrange(33...34, with: le16(354))            // 数字增益 354
        d[35] = 9                         // 数字增益十分位 → 354.9

        let t = OSMOStatusTracker()

        // 连接即同步——无需 App 先写一次、无需模式前置（2026-11-14 固定布局实锤后直读 @6）
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d))
        XCTAssertEqual(t.snapshot.expoCompValue, 0x13)
        XCTAssertEqual(t.snapshot.expoCompName, "+1.0")      // 0x13：码 16=0EV → +1.0（一位小数）
        XCTAssertEqual(t.snapshot.exposureMode, 0x01)        // @7 推送驱动 曝光模式
        XCTAssertEqual(t.snapshot.lightMeterName, "-3.0 EV")
        XCTAssertEqual(t.snapshot.effectiveISO, 3_200)
        XCTAssertEqual(t.snapshot.isoStepCode, 0x07)
        XCTAssertEqual(t.snapshot.effectiveShutter, 0x8019)    // @22=0 无小数
        XCTAssertEqual(t.snapshot.effectiveShutterName, "1/25 s")
        XCTAssertEqual(t.snapshot.digitalGain, 354)
        XCTAssertEqual(t.snapshot.digitalGainFine, 9)

        // 相机端改动同步：@6 变化 → EV 直接跟随（全模式）
        var d2 = d
        d2[6] = 0x0A                       // 相机端把 EV 从 +1.0 改到 -2.0
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d2))
        XCTAssertEqual(t.snapshot.expoCompValue, 0x0A)
        XCTAssertEqual(t.snapshot.expoCompName, "-2.0")

        // 码域出格兜底：@6 不在 0x07-0x19 → 不更新
        var d3 = d
        d3[6] = 0x20
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d3))
        XCTAssertEqual(t.snapshot.expoCompValue, 0x0A)

        // 各模式独立 EV 记忆：切模式时 @6 跳到该模式记忆值 → 显示跟随（正确行为）
        var d4 = d
        d4[6] = 0x10                       // 切到照片模式，该模式 EV 记忆为 0.0（码 16）
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d4))
        XCTAssertEqual(t.snapshot.expoCompValue, 0x10)
        XCTAssertEqual(t.snapshot.expoCompName, "+0.0")

        // 切回视频：@6 恢复视频 EV → 立即跟随
        var d5 = d
        d5[6] = 0x19
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d5))
        XCTAssertEqual(t.snapshot.expoCompValue, 0x19)
        XCTAssertEqual(t.snapshot.expoCompName, "+3.0")
    }

    /// @22 = 快门小数字节（双粒度 ≤9 十分位/≥10 百分位，与 02/29、shutterRaw 同构）
    func testExpoParamShutterDecimal() {
        var d = [UInt8](repeating: 0, count: 41)
        d[6] = 0x13
        d[7] = 0x04                      // 手动曝光
        d.replaceSubrange(20...21, with: le16(0x0001))         // u16 = 1s
        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d))
        XCTAssertEqual(t.snapshot.effectiveShutter, 0x0001)    // 无小数 → 1s
        XCTAssertEqual(t.snapshot.effectiveShutterName, "1 s")

        d[22] = 0x03                                           // 十分位 0.3 → 1.3s
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d))
        XCTAssertEqual(t.snapshot.effectiveShutter, 0x3_0001)
        XCTAssertEqual(t.snapshot.effectiveShutterName, "1.3 s")

        d[22] = 0x43                                           // 百分位 0.67（分母形 0x8001）→ 1/1.67s
        d[20] = 0x01
        d[21] = 0x80
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d))
        XCTAssertEqual(t.snapshot.effectiveShutter, 0x43_8001)
        XCTAssertEqual(t.snapshot.effectiveShutterName, "1/1.67 s")
    }

    /// 真实抓包帧锁定（2026-11-14 App 会话首帧）：41B 固定布局逐域对账——
    /// 恒定域（@0-5/@7-10/@12-14/@18-19/@22-27/@29-31/@37-39）偏移写错会静默错位
    func testExpoParamRealFrameLayout() {
        let hex = "0000328000001901010000070318010f40060000198000000000000064000000016201096400000001"
        let d = hexToBytes(hex)
        XCTAssertEqual(d.count, 41)
        XCTAssertEqual(Int(d[2]) | Int(d[3]) << 8, 0x8032)                 // 拍照快门 1/50（拍照子系统 AE，随场景变化）
        XCTAssertEqual(d[6], 0x19)                                         // EV +3.0
        XCTAssertEqual(d[7], 0x01)                                         // 曝光模式：自动
        XCTAssertEqual(d[8], 0x01)
        XCTAssertEqual(Array(d[9...10]), [0, 0])
        XCTAssertEqual(d[11], 0x07)                                        // ISO 档码 1600 档（该帧 ISO=1600）
        XCTAssertEqual(d[12], 0x03)
        XCTAssertEqual(d[13], 0x18)
        XCTAssertEqual(d[14], 0x01)
        XCTAssertEqual(d[15], 0x0f)                                        // 测光 +1.0
        XCTAssertEqual(Int(d[16]) | Int(d[17]) << 8, 1600)                           // ISO（ISO MAX 钳制值）
        XCTAssertEqual(Array(d[18...19]), [0, 0])
        XCTAssertEqual(Int(d[20]) | Int(d[21]) << 8, 0x8019)                         // 快门 1/25
        XCTAssertEqual(Array(d[22...27]), [UInt8](repeating: 0, count: 6))
        XCTAssertEqual(d[28], 100)                                         // 恒 100（候选电池%）
        XCTAssertEqual(Array(d[29...31]), [0, 0, 0])
        XCTAssertEqual(d[32], 0x01)
        XCTAssertEqual(Int(d[33]) | Int(d[34]) << 8, 354)                  // 数字增益
        XCTAssertEqual(d[35], 9)                                           // 十分位 → 354.9
        XCTAssertEqual(d[36], 100)                                         // 恒 100
        XCTAssertEqual(Array(d[37...39]), [0, 0, 0])
        XCTAssertEqual(d[40], 0x01)

        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_expo_param", data: d))
        XCTAssertEqual(t.snapshot.expoCompValue, 0x19)
        XCTAssertEqual(t.snapshot.effectiveISO, 1600)
        XCTAssertEqual(t.snapshot.exposureMode, 0x01)      // @7 = 01 自动
        XCTAssertEqual(t.snapshot.isoStepCode, 0x07)
        XCTAssertEqual(t.snapshot.effectiveShutterName, "1/25 s")
        XCTAssertEqual(t.snapshot.photoShutterName, "1/50 s")
        XCTAssertEqual(t.snapshot.digitalGain, 354)
    }

    private func hexToBytes(_ s: String) -> [UInt8] {
        Array(stride(from: 0, to: s.count, by: 2).map {
            UInt8(s[s.index(s.startIndex, offsetBy: $0)..<s.index(s.startIndex, offsetBy: $0 + 2)], radix: 16)!
        })
    }

    func testVideoParamV2Topic() {
        let t = OSMOStatusTracker()
        // OA4 实测布局（2026-11-11 抓包）：@0 分辨率码、@1 帧率码 u8；
        // 6 次分辨率变化 + 2 次帧率变化（60↔24）与用户操作逐一对应
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_video_param_v2", data: [0x10, 0x06]))

        XCTAssertEqual(t.snapshot.videoResolutionCode, 0x10)
        XCTAssertEqual(t.snapshot.videoResolutionName, "4K 16:9")
        XCTAssertEqual(t.snapshot.videoFpsCode, 0x06)
        XCTAssertEqual(t.snapshot.videoFpsName, "60")
    }

    func testImageEffectAndLapseTopics() {
        var d = [UInt8](repeating: 0, count: 16)
        d[2] = 0x34                       // D-Log M（OA4 实测码 0x34；Nano 的 0x3D 不适用）
        d[14] = 0xFF                      // 降噪 -1（s8 位型）
        d[15] = 2                         // 锐度 +2
        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_image_effect", data: d))
        XCTAssertEqual(t.snapshot.colorProfileName, "D-Log M")
        XCTAssertEqual(t.snapshot.denoise, Int8(-1))
        XCTAssertEqual(t.snapshot.sharpness, 2)

        var l = [UInt8](repeating: 0, count: 12)
        l[0] = 0x02                       // 保存 JPEG
        l.replaceSubrange(1...2, with: le16(20))               // 间隔 2.0s
        l.replaceSubrange(5...8, with: le32(600))              // 时长 600s
        l.replaceSubrange(9...10, with: le16(15))              // 速度 15×
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: topicFrame(name: "cam_lapse_param", data: l))
        XCTAssertEqual(t.snapshot.lapseKeepName, "JPEG")
        XCTAssertEqual(t.snapshot.lapseIntervalDeciS, 20)
        XCTAssertEqual(t.snapshot.lapseDurationS, 600)
        XCTAssertEqual(t.snapshot.lapseSpeed, 15)
    }

    // MARK: 查询应答

    func testQueryReplies() {
        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x02, cmdId: 0x19, sender: 0x01,
                 payload: Data([0x00, 0x10, 0x03, 0x00, 0x00, 0x00]))   // 4K 30fps
        XCTAssertEqual(t.snapshot.videoResolutionName, "4K 16:9")
        XCTAssertEqual(t.snapshot.videoFpsName, "30")

        t.handle(cmdSet: 0x02, cmdId: 0x1F, sender: 0x01, payload: Data([0x00, 0x04, 0x00]))
        XCTAssertEqual(t.snapshot.exposureModeName, "手动")

        t.handle(cmdSet: 0x02, cmdId: 0x2B, sender: 0x01, payload: Data([0x00, 0x08]))
        XCTAssertEqual(t.snapshot.isoName, "3200")

        // 快门 0x800C + 5 → 1/12.5s（§7.1 样例）
        t.handle(cmdSet: 0x02, cmdId: 0x29, sender: 0x01,
                 payload: Data([0x00, 0x01, 0x0C, 0x80, 0x05]))
        XCTAssertEqual(t.snapshot.shutterName, "1/12.5 s")

        t.handle(cmdSet: 0x02, cmdId: 0x2D, sender: 0x01,
                 payload: Data([0x00, 0x06, 0x1E, 0x28]))               // 5500K? 0x281E=10270?
        XCTAssertEqual(t.snapshot.wbMode, 0x06)

        // 错误码记录：E0 不支持（02/13 照片格式已被跟踪；非照片模式下应答 DF/E3）
        t.handle(cmdSet: 0x02, cmdId: 0x13, sender: 0x01, payload: Data([0xE0]))
        XCTAssertEqual(t.snapshot.queryErrors["photo_format"], 0xE0)
    }

    func testQueryErrorRecording() {
        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x02, cmdId: 0x29, sender: 0x01, payload: Data([0xDF]))  // 自动曝光下快门 DF
        XCTAssertEqual(t.snapshot.queryErrors["shutter"], 0xDF)
        XCTAssertEqual(t.snapshot.shutterName, nil)
    }

    // MARK: 00/99 主题推送扩容（unknown-signals-report 实测布局）

    /// 构造 00/99 命名主题推送帧载荷（布局同 osmocam §8.3 / parseTopicPush）
    private func topicPush(name: String, data: [UInt8]) -> [UInt8] {
        var p: [UInt8] = [0x02, 0x06, 0x00, 0x00, 0xd5, 0xf0, 0, 0, 0, 0, 0]
        let nameBytes = Array(name.utf8)
        let rest = nameBytes.count + 6
        p += le16(UInt16(rest))
        p += le16(UInt16(nameBytes.count))
        p += nameBytes
        p += [UInt8](repeating: 0, count: 6)
        p += le16(UInt16(data.count))
        p += data
        return p
    }

    func testRecordTimePush() {
        let t = OSMOStatusTracker()
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: Data(topicPush(name: "cam_record_time", data: [1, 0, 0, 0, 0, 0])))
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: Data(topicPush(name: "cam_record_time", data: [37, 0, 0, 0, 0, 0])))
        XCTAssertEqual(t.snapshot.recordSeconds, 37)
    }

    func testRawTopicSampleRecordedOnChangeOnly() {
        let t = OSMOStatusTracker()
        let fovData: [UInt8] = [0x6d, 0x09, 0x00, 0x00, 0x11, 0x07, 0x00, 0x00,
                                0x01, 0x00, 0x00, 0x00, 0x38, 0x31, 0x00, 0x00]
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: Data(topicPush(name: "cam_fov", data: fovData)))
        XCTAssertEqual(t.snapshot.rawTopicSamples["cam_fov"], fovData.map { String(format: "%02x", $0) }.joined())
        // 相同数据重复推送不产生变化（快照引用相同 hex）
        t.handle(cmdSet: 0x00, cmdId: 0x99, sender: 0x28,
                 payload: Data(topicPush(name: "cam_fov", data: fovData)))
        XCTAssertEqual(t.snapshot.rawTopicSamples["cam_fov"], fovData.map { String(format: "%02x", $0) }.joined())
    }

    func testUnknownParamRawReadsAnd0AFlipLog() {
        let t = OSMOStatusTracker()
        var logs: [String] = []
        t.onLog = { logs.append($0) }
        // 成功应答内嵌 pid：00 00 01 0A 00 01 01
        t.handle(cmdSet: 0x02, cmdId: 0x8E, sender: 0x01,
                 payload: Data([0x00, 0x00, 0x01, 0x0A, 0x00, 0x01, 0x01]))
        XCTAssertEqual(t.snapshot.rawParams[0x000A], "01")
        XCTAssertEqual(t.snapshot.rawParam0A, 0x01)
        // 翻转 01 → 00：负响应之外的合法应答
        t.handle(cmdSet: 0x02, cmdId: 0x8E, sender: 0x01,
                 payload: Data([0x00, 0x00, 0x01, 0x0A, 0x00, 0x01, 0x00]))
        XCTAssertEqual(t.snapshot.rawParam0A, 0x00)
        XCTAssertTrue(logs.contains { $0.contains("pid 000A") })
    }

    func testNegativeParamAttributedToLastRequestedPid() {
        let t = OSMOStatusTracker()
        t.noteParameterRequest(0x0015)
        t.handle(cmdSet: 0x02, cmdId: 0x8E, sender: 0x01, payload: Data([0xE3]))
        XCTAssertEqual(t.snapshot.queryErrors["param-0015"], 0xE3)
    }

    // MARK: 00/4A 相机 RTC 对时载荷（2026-10-19 抓包实锤帧）

    func testCameraClockPayloadMatchesCapture() {
        var comps = DateComponents()
        comps.year = 2026; comps.month = 10; comps.day = 19
        comps.hour = 19; comps.minute = 52; comps.second = 36
        comps.nanosecond = 480_000_000
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        let d = OSMOA4.cameraClockPayload(date: date,
                                          calendar: Calendar(identifier: .gregorian))
        XCTAssertEqual(Array(d), [0xEA, 0x07, 0x0A, 0x13, 0x13, 0x34, 0x24, 0xE0, 0x01])
    }

    // MARK: 00/76 固件动作事件（JSON event_id 提取）

    func testActionEventExtracted() {
        let t = OSMOStatusTracker()
        var events: [String] = []
        t.onEvent = { id, _ in events.append(id) }
        let json = #"{"event_id":"fw_0100_action_result","action":"record","is_success":true}"#
        let payload: [UInt8] = [0x00, 0x30, 0x00] + Array(json.utf8)
        t.handle(cmdSet: 0x00, cmdId: 0x76, sender: 0x28, payload: Data(payload))
        XCTAssertEqual(events, ["fw_0100_action_result"])
    }

    func testActionEventFailureFieldExtractable() {
        // 失败判定在 OSMOCameraLink 接线层（is_success=false → onEventFailure → toast）；
        // 这里锁定 JSON 字段可从真实载荷形态（长度头 + JSON 文本）提取
        let json = #"{"event_id":"fw_0100_action_result","action":"capture","is_success":false}"#
        let payload: [UInt8] = [0x00, 0x30, 0x00] + Array(json.utf8)
        let obj = try? JSONSerialization.jsonObject(with: Data(payload[3...]))
        XCTAssertEqual((obj as? [String: Any])?["is_success"] as? Bool, false)
        XCTAssertEqual((obj as? [String: Any])?["event_id"] as? String, "fw_0100_action_result")
    }

    // MARK: 订阅帧构造（osmocam protocol.py topic_subscription）

    func testTopicSubscriptionLayout() {
        let d = Array(OSMOCameraLink.topicSubscription(name: "cam_expo_param", id: 0x6A00))
        XCTAssertEqual(Array(d[0...3]), [0x02, 0x02, 0x00, 0x00])
        XCTAssertEqual(Array(d[4...7]), le32(0x6A00))
        XCTAssertEqual(Array(d[8...10]), [0, 0, 0])
        let nameLen = Int(d[13]) | Int(d[14]) << 8
        XCTAssertEqual(nameLen, "cam_expo_param".utf8.count)
        let totalLen = Int(d[11]) | Int(d[12]) << 8
        XCTAssertEqual(totalLen, nameLen + 6)
        XCTAssertEqual(String(bytes: d[15..<15+nameLen], encoding: .utf8), "cam_expo_param")
        XCTAssertEqual(d.count, 15 + nameLen + 4)
        XCTAssertEqual(Array(d.suffix(4)), [0, 0, 0, 0])
    }
}
