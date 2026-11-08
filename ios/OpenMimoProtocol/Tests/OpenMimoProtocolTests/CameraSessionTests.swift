import XCTest
@testable import OpenMimoProtocol

/// 可控链路：脚本化注入入站数据、记录发送、模拟断链。
final class MockCameraLink: CameraLink, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Data>.Continuation?
    private(set) var sentUDP: [Data] = []
    private(set) var sentTCP: [Data] = []
    private(set) var openCount = 0
    private var shouldFailOpen = false
    private var sendFailureMode = false

    func failNextOpen() { lock.withLock { shouldFailOpen = true } }

    /// 使所有 UDP 发送持续失败（测试轮询自愈）。
    func failAllSends() { lock.withLock { sendFailureMode = true } }

    func open() async throws -> AsyncStream<Data> {
        lock.lock()
        if shouldFailOpen {
            lock.unlock()
            throw NSError(domain: "mock", code: 1)
        }
        openCount += 1
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        self.continuation = continuation
        lock.unlock()
        return stream
    }

    func sendUDP(_ data: Data) async throws {
        lock.lock()
        if sendFailureMode { lock.unlock(); throw NSError(domain: "mock", code: 2) }
        sentUDP.append(data)
        lock.unlock()
    }

    func sendTCP(_ data: Data) async throws {
        lock.lock()
        if sendFailureMode { lock.unlock(); throw NSError(domain: "mock", code: 2) }
        sentTCP.append(data)
        lock.unlock()
    }

    func close() async {
        lock.lock(); let c = continuation; continuation = nil; lock.unlock()
        c?.finish()
    }

    /// 注入一个含 `frame` 的 S2C 包（加 8 字节模拟外层头）。
    func inject(_ frame: MimoFrame) {
        lock.lock(); let c = continuation; lock.unlock()
        var payload = Data([0x19, 0x85, 0xC6, 0x15, 0x00, 0x00, 0x01, 0x4E])
        payload += frame.encodedData()
        c?.yield(payload)
    }
}

final class CameraSessionTests: XCTestCase {
    func testConnectSendsHandshakeAndSubscriptions() async throws {
        let link = MockCameraLink()
        let session = CameraSession(link: link, watchdogTimeout: 5, reconnectBackoff: 0.1)
        await session.start()

        // 等待连接完成 + 握手帧发出
        try await waitFor("connected") { await session.state == .connected }
        try await waitFor("订阅帧已发出") {
            let sent = await link.sentUDP
            return sent.count >= 1 + CameraSession.coreTopics.count
        }

        // 握手首帧 + 4 个核心主题订阅
        let sent = await link.sentUDP
        let frames = sent.flatMap { MimoPacket.frames(in: $0) }
        XCTAssertEqual(frames.first?.cmdId, 0x2B, "连接后首帧为握手帧（CmdId 0x2B）")
        let topics = frames.dropFirst().compactMap { MimoTelemetry.parsePush($0)?.topic }
        XCTAssertEqual(topics, CameraSession.coreTopics, "订阅按 coreTopics 顺序发出")

        await session.stop()
    }

    func testSilenceIsReportedButLinkStaysUp() async throws {
        // 相机不推数据 ≠ 链路死：静默只报告，不断链（真机"连上即断"的修复）
        var lines: [String] = []
        CameraSession.logSink = { lines.append($0) }
        defer { CameraSession.logSink = nil }

        let link = MockCameraLink()
        let session = CameraSession(link: link, watchdogTimeout: 0.3, reconnectBackoff: 0.05)
        await session.start()
        try await waitFor("connected") { await session.state == .connected }

        // 静默 1.5s：应出现静默报告，且连接保持
        try await waitFor("静默报告") { lines.contains { $0.contains("无入站数据") } }
        try await Task.sleep(nanoseconds: 600_000_000)
        let state = await session.state
        XCTAssertEqual(state, .connected, "静默不得触发断链")
        let opens = await link.openCount
        XCTAssertEqual(opens, 1, "链路不被重建")

        await session.stop()
    }

    func testPollFailureSelfHealTriggersReconnect() async throws {
        var lines: [String] = []
        CameraSession.logSink = { lines.append($0) }
        defer { CameraSession.logSink = nil }

        let link = MockCameraLink()
        await link.failAllSends()
        let session = CameraSession(link: link, watchdogTimeout: 30, reconnectBackoff: 0.05)
        await session.start()
        try await waitFor("connected") { await session.state == .connected }

        // 连续发送失败 ≥10 → 主动重建链路
        try await waitFor("自愈重建", timeout: 15) { lines.contains { $0.contains("主动重建链路") } }
        try await waitFor("再次 connected", timeout: 5) { await session.state == .connected }
        await session.stop()
    }

    func testTelemetryPushUpdatesSnapshot() async throws {
        let link = MockCameraLink()
        let session = CameraSession(link: link, watchdogTimeout: 5, reconnectBackoff: 0.1)
        await session.start()
        try await waitFor("connected") { await session.state == .connected }

        // cam_status 推送（抓包 19:53:13.101 原值：视频模式、变焦 1 档、切换中）
        let statusFrame = MimoFrame.parse(Data(hex: "553704f92802120800009902060000ba0700000000001d000a0063616d5f73746174757300000000000009001000550101000102003eee"))!
        await link.inject(statusFrame)

        try await waitFor("快照更新") {
            let t = await session.telemetry
            return t.mode == .video && t.isRecording == false
        }
        let snapshot = await session.telemetry
        XCTAssertEqual(snapshot.status?.zoomIndex, 0x01)
        await session.stop()
    }

    func testSetModeSendsDocumentedFrame() async throws {
        let link = MockCameraLink()
        let session = CameraSession(link: link, watchdogTimeout: 5, reconnectBackoff: 0.1)
        await session.start()
        try await waitFor("connected") { await session.state == .connected }

        try await session.setMode(.slowMotion)
        try await waitFor("模式帧已发送") {
            let sent = await link.sentUDP
            return sent.contains { $0.range(of: Data(hex: "4002e100")) != nil }
        }
        await session.stop()
    }

    // MARK: helpers

    /// 轮询等待条件成立（actor 状态无法直接 select，短轮询最简可靠）。
    private func waitFor(_ label: String, timeout: TimeInterval = 3,
                         _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("等待超时：\(label)")
    }
}

private extension Data {
    init(hex: String) {
        self.init()
        var it = hex.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            append(UInt8(String([hi, lo]), radix: 16)!)
        }
    }
}
