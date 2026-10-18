import Foundation
import CoreVideo

/// 控制屏状态条所需的遥测快照（来源均为已证实主题：telemetry.md §4）。
/// 电量百分比来自 1D02 备选路径（主题空间无电量主题，见 CameraStatusV2 注释）。
public struct TelemetrySnapshot: Equatable, Sendable {
    public var status: CameraStatus?
    public var mode: CameraMode?
    public var zoomFactor: Double?
    public var recordSeconds: Int?
    public var storageBytes: Int?
    public var isRecording: Bool
    public var batteryPercent: Int?

    public init(status: CameraStatus? = nil, mode: CameraMode? = nil, zoomFactor: Double? = nil,
                recordSeconds: Int? = nil, storageBytes: Int? = nil, isRecording: Bool = false,
                batteryPercent: Int? = nil) {
        self.status = status
        self.mode = mode
        self.zoomFactor = zoomFactor
        self.recordSeconds = recordSeconds
        self.storageBytes = storageBytes
        self.isRecording = isRecording
        self.batteryPercent = batteryPercent
    }
}

/// 相机会话：连接生命周期（连接/保活/看门狗重连）、命令发送、遥测聚合。
/// 状态机：idle → connecting → connected ⇄ reconnecting → disconnected（docs/protocol 设计 §4.2）。
public actor CameraSession {
    public enum State: Equatable, Sendable {
        case idle, connecting, connected, reconnecting, disconnected
    }

    public enum Event: Sendable {
        case stateChanged(State)
        case telemetryChanged(TelemetrySnapshot)
    }

    /// 订阅主题：官方连接风暴的完整清单（pcap 54.786s 帧序 + telemetry.md §3，21 主题）。
    /// 预览开启 (ee,2f) 疑依赖完整订阅状态——只订 4 主题时命令无响应。
    static let coreTopics = [
        "cam_status", "cam_record_time", "cam_storage", "cam_fov",
        "cam_photo_param", "cam_lapser_param", "cam_video_param_v2", "cam_expo_param",
        "cam_lens_state", "cam_image_effect", "shutter_param", "camcap_common",
        "camcap_custom_mode_params", "cam_audio_status_v2", "audio_timecode_status",
        "timecode_info", "temp_curve", "cam_imu_calib_info", "cam_magnifier_status",
        "v_quality_enhance_status", "cam_custom_mode_params",
    ]

    /// 实时预览管线：S2C 大包分流进 LiveView（视频包 20B 头，区别于 9B 心跳/34B ACK）。
    public private(set) var liveView = LiveViewPipeline()
    /// SRTP 会话密钥（TCP 7001 信令下发后重建管线）
    private var srtpKey: Data? {
        didSet {
            guard let key = srtpKey, key != oldValue else { return }
            sessionLog("[srtp] ✓ 密钥到手（16B），管线切换 SRTP 解密")
            Task { await rebuildPipeline(key: key) }
        }
    }

    /// 密钥到手后用 SRTPDecryptor 重建管线。
    private func rebuildPipeline(key: Data) async {
        // SSRC 取自信令包 RTP 头 [8:12]；此处简化用固定占位（视频 RTP 头本身的 seq 用于 IV）。
        // SSRC 实际值在视频 RTP 头内逐帧可得，但 IV 构造按信令 SSRC。
        let newPipe = LiveViewPipeline(decryptor: SRTPDecryptor(masterKey: key, ssrc: signalingSSRC))
        await newPipe.setPixelBufferHandler { [weak self] pb in
            self?.forwardPixelBuffer(pb)
        }
        liveView = newPipe
    }

    /// UI 订阅解码帧（C 回调线程安全：经 box 转发）
    private let pixelBufferBox = PixelBufferBox()
    public func setPixelBufferHandler(_ handler: ((CVPixelBuffer) -> Void)?) {
        pixelBufferBox.set(handler)
    }
    nonisolated private func forwardPixelBuffer(_ pb: CVPixelBuffer) {
        pixelBufferBox.invoke(pb)
    }

    /// 线程安全的 handler 容器。
    final class PixelBufferBox: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((CVPixelBuffer) -> Void)?
        func set(_ h: ((CVPixelBuffer) -> Void)?) { lock.withLock { handler = h } }
        func invoke(_ pb: CVPixelBuffer) { lock.withLock { handler }?(pb) }
    }
    /// 信令包 RTP 头 SSRC（密钥关联）
    private var signalingSSRC: UInt32 = 0x01000000

    /// TCP 信令回调入口（App 层转发）：提取/设置 SRTP 密钥。
    public func deliverSRTPKey(_ key: Data) {
        srtpKey = key
    }

    /// 会话日志钩子：宿主 App 注入后，连接状态与保活异常直通统一诊断面板。
    public static var logSink: ((String) -> Void)?

    // 可注入配置（测试用短超时）
    private let link: any CameraLink
    private let watchdogTimeout: TimeInterval
    private let reconnectBackoff: TimeInterval

    public private(set) var state: State = .idle
    public private(set) var telemetry = TelemetrySnapshot()

    private var continuationStore: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var runTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var pollsTask: Task<Void, Never>?
    private var ackKeepaliveTask: Task<Void, Never>?
    private var frameSeq: UInt16 = 0x1000
    /// C2S 外层序号（包头 16-19，u32 LE 逐包 +1，官方起始 0x0101）
    private var packetSeq: UInt32 = 0x101
    /// C2S seq8 字段（包头 4-5，u16 LE 逐包 +8，官方起始 0xae38）
    private var seq8Counter: UInt16 = 0xae38
    private var requestID: UInt16 = 0xD500
    private var inboundLogCount = 0
    private var appReplySent = false
    private var sessionID = Data([0x80, 0xC6, 0x15]) // 观测会话值；每次全新配对可重随机化
    private var lastInbound = Date.distantPast
    private var inboundBytes = 0
    private var stopping = false

    private nonisolated func sessionLog(_ line: String) {
        Self.logSink?(line)
    }

    public init(link: any CameraLink,
                watchdogTimeout: TimeInterval = 3.0,
                reconnectBackoff: TimeInterval = 1.0) {
        self.link = link
        self.watchdogTimeout = watchdogTimeout
        self.reconnectBackoff = reconnectBackoff
    }

    // MARK: - 生命周期

    public func start() {
        guard runTask == nil else { return }
        stopping = false
        runTask = Task { await runLoop() }
    }

    public func stop() {
        stopping = true
        runTask?.cancel()
        heartbeatTask?.cancel()
        ackKeepaliveTask?.cancel()
        rawVideoDump?.closeFile()
        rawVideoDump = nil
        Task { await link.close() }
        setState(.disconnected)
        runTask = nil
    }

    public func events() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let token = UUID()
            continuationStore[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
            continuation.yield(.stateChanged(state))
            continuation.yield(.telemetryChanged(telemetry))
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuationStore[token] = nil
    }

    /// 供保活 Task 查询停止标志。
    fileprivate func checkStopping() -> Bool { stopping }

    private func yield(_ event: Event) {
        for c in continuationStore.values { c.yield(event) }
    }

    private func setState(_ new: State) {
        guard state != new else { return }
        state = new
        sessionLog("会话状态: \(new)")
        yield(.stateChanged(new))
    }

    // MARK: - 主循环

    private func runLoop() async {
        var first = true
        while !stopping {
            setState(first ? .connecting : .reconnecting)
            first = false
            do {
                let inbound = try await link.open()
                guard !stopping else { await link.close(); break }
                setState(.connected)
                inboundBytes = 0
                inboundLogCount = 0
                appReplySent = false
                await sendHandshakeAndSubscriptions()
                startHeartbeat()
                startACKKeepalive()
                startPeriodicPolls()
                startWMSProbe()
                lastInbound = Date()
                try await pump(inbound)
            } catch {
                sessionLog("链路打开失败: \(error.localizedDescription)（进入重连）")
            }
            heartbeatTask?.cancel()
            heartbeatTask = nil
            ackKeepaliveTask?.cancel()
            ackKeepaliveTask = nil
            pollsTask?.cancel()
            pollsTask = nil
            await link.close()
            guard !stopping else { break }
            try? await Task.sleep(nanoseconds: UInt64(reconnectBackoff * 1_000_000_000))
        }
        setState(.disconnected)
    }

    /// UDP 9004 周期轮询（官方保活组合，抓包 §4.4）：
    /// 每 1s 两条 (0x40,0x00,0x51)/[04] 与 (0x80,0x00,0x82)；每 4s 一条 (0xC0,0x00,0x00)。
    /// 相机以此判定客户端存活——缺失会导致连接被踢（真机已复现"连上即断"）。
    private func startPeriodicPolls() {
        pollsTask?.cancel()
        pollsTask = Task { [weak self] in
            var tick = 0
            var failures = 0
            while !Task.isCancelled {
                guard let self, !(await self.checkStopping()) else { return }
                do {
                    try await self.send(MimoCommand.statusPoll(sequence: await self.nextFrameSeq()))
                    try await self.send(MimoCommand.statusPoll2(sequence: await self.nextFrameSeq()))
                    if tick % 4 == 0 {
                        try await self.send(MimoCommand.statusPoll3(sequence: await self.nextFrameSeq()))
                    }
                    if failures > 0 {
                        self.sessionLog("轮询恢复 ✓")
                        failures = 0
                    }
                    // BLE 侧电量桥接：电量仅经 BLE (0d,02) 推送（telemetry.md §7），
                    // CameraBleWaker 持久化后在此并入遥测快照
                    await self.bridgeBLEBattery()
                } catch {
                    failures += 1
                    if failures == 1 || failures % 5 == 0 {
                        self.sessionLog("⚠ 保活轮询发送失败 ×\(failures)：\(error.localizedDescription)")
                    }
                    if failures >= 10 {
                        self.sessionLog("连续发送失败 → 主动重建链路（重连后自动恢复保活）")
                        await self.link.close()
                        return
                    }
                }
                tick += 1
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 单条控制帧处理（UDP 直收与 live-view 内嵌帧两条路径共用）。
    /// 返回 true = 需要 APP 应答（相机 (0x00,0x81) 模型广播）。
    @discardableResult
    private func handleInboundControlFrame(_ frame: MimoFrame) -> Bool {
        var appReplyNeeded = false
        // 相机 (0x00,0x81) 模型广播 → 手机须回 "APP" 应答（pcap 12.16–12.21s 实证）
        if frame.cmdSet == 0x00, frame.cmdId == 0x81 {
            appReplyNeeded = true
        }
        // WiFi 模块应答 (c0,07,xx)：get_ssid / get_password 明文
        if frame.cmdType == 0xC0, frame.cmdSet == 0x07 {
            let pl = [UInt8](frame.payload)
            if frame.cmdId == 0x07, pl.count > 2 {
                let ssid = String(bytes: pl[2...], encoding: .utf8) ?? ""
                sessionLog("[wms] ✓ SSID=\(ssid)")
                UserDefaults.standard.set(ssid, forKey: "camera.ssid")
            }
            if frame.cmdId == 0x0E, pl.count > 2 {
                let pwd = String(bytes: pl[2...], encoding: .utf8) ?? ""
                sessionLog("[wms] ✓ PASSWORD=\(pwd)（\(pl.count-2)B 明文）")
                if pwd.count >= 8 {
                    // TODO: 迁移到 Keychain（KeychainStore 在 App target）
                    UserDefaults.standard.set(pwd, forKey: "camera.wifi_password")
                    sessionLog("[wms] 密码已存 UserDefaults——断线后可全自动重连")
                }
            }
        }
        // (c0,00,51) 长载荷 = 视频加密密钥应答（Mimo pcap：[00 10][16B key]，预览开启前下发）。
        // 短载荷 (≤4B，如 e0504901) 为保活状态应答，忽略。
        if frame.cmdType == 0xC0, frame.cmdSet == 0x00, frame.cmdId == 0x51,
           frame.payload.count >= 16 {
            let pl = [UInt8](frame.payload)
            // 跳过 [00 10] 长度前缀取 16B（若前两字节恰为长度标记）
            let keyData: Data
            if pl.count >= 18, pl[0] == 0x00, Int(pl[1]) == pl.count - 2 {
                keyData = Data(pl[2...])
            } else {
                keyData = frame.payload
            }
            let hex = keyData.map { String(format: "%02x", $0) }.joined()
            let prev = UserDefaults.standard.string(forKey: "camera.video_key")
            if prev != hex {
                UserDefaults.standard.set(hex, forKey: "camera.video_key")
                sessionLog("[video] ✓ 收到视频密钥 \(keyData.count)B: \(hex)")
            }
        }
        // 1D02 相机状态推送（备选遥测路径：唯一含电量百分比的结构，见 CameraStatusV2）
        if frame.cmdSet == 0x1D, frame.cmdId == 0x02,
           let v2 = CameraStatusV2(value: frame.payload) {
            telemetry.batteryPercent = v2.batteryPercent
            if v2.recordTime > 0 { telemetry.recordSeconds = v2.recordTime }
            if v2.remainCapacityMB > 0 { telemetry.storageBytes = v2.remainCapacityMB * 1_000_000 }
            sessionLog("[telemetry] 1D02: mode=\(v2.mode) state=\(v2.cameraState) " +
                       "res=\(v2.resolution) fps=\(v2.fpsIndex) 电量=\(v2.batteryPercent)% " +
                       "SD=\(v2.remainCapacityMB)MB 录制=\(v2.recordTime)s")
            yield(.telemetryChanged(telemetry))
        }
        // (0x02,0x80) 设备状态推送（无需订阅，会话建立即推；BLE/UDP 双通道同构）。
        // 相机 ~10Hz 恒频重推；值不变时静默（防日志灌屏与无效 UI 刷新）。
        if frame.cmdSet == 0x02, frame.cmdId == 0x80,
           let dev = CameraDeviceState(value: frame.payload) {
            if dev.freeMB > 0, telemetry.storageBytes != dev.freeMB * 1_000_000 {
                telemetry.storageBytes = dev.freeMB * 1_000_000
                sessionLog("[telemetry] 0x80: SD total=\(dev.totalMB)MB free=\(dev.freeMB)MB photo=\(dev.remainPhotoCount)")
                yield(.telemetryChanged(telemetry))
            }
        }
        if let push = MimoTelemetry.parsePush(frame) {
            apply(push)
        }
        return appReplyNeeded
    }

    /// BLE 侧电量桥接：BLE (0d,02) 推送落 UserDefaults 后在此并入遥测（telemetry.md §7）。
    private func bridgeBLEBattery() {
        if let pct = UserDefaults.standard.object(forKey: "camera.battery_percent") as? Int,
           telemetry.batteryPercent != pct {
            telemetry.batteryPercent = pct
            sessionLog("[telemetry] 电量(桥接自 BLE)=\(pct)%")
            yield(.telemetryChanged(telemetry))
        }
    }

    /// 消费入站流；仅当流结束（真断链：WiFi 掉/连接被取消）时返回。
    /// 静默（相机不推数据）只报告不断链——WiFi 层连接与保活轮询继续保持。
    private func pump(_ inbound: AsyncStream<Data>) async throws {
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                if let self, await self.stale() {
                    await self.reportStall()
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        defer { watchdog.cancel() }
        for await data in inbound {
            lastInbound = Date()
            inboundBytes += data.count
            stallLogged = false
            // 视频大包分流（>128B 的 S2C 包 = live-view 分片帧；34B ACK/9B 心跳不进管线）
            if data.count > 128 {
                dumpRawVideoIfEnabled(data)
                let controls = await liveView.ingest(data)
                var appReplyNeeded = false
                for frame in controls where handleInboundControlFrame(frame) {
                    appReplyNeeded = true
                }
                if appReplyNeeded, !appReplySent {
                    appReplySent = true
                    await sendAppAnnouncement()
                }
            }
            handleInbound(data)
        }
        sessionLog("入站流结束（Task.isCancelled=\(Task.isCancelled)）→ 重建链路")
    }

    private func stale() -> Bool {
        !stopping && state == .connected && Date().timeIntervalSince(lastInbound) > watchdogTimeout
    }

    /// 原始视频包落盘（离线解密分析用）：UserDefaults "video.dumpRaw" = true 时启用。
    /// 写入 Documents/rawvideo.bin（追加 [len:4 LE][包字节]；沙盒文件经 devicectl 拉取）。
    private var rawVideoDump: FileHandle?
    private func dumpRawVideoIfEnabled(_ data: Data) {
        guard UserDefaults.standard.bool(forKey: "video.dumpRaw") else { return }
        if rawVideoDump == nil {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("rawvideo.bin")
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            rawVideoDump = try? FileHandle(forWritingTo: url)
            sessionLog("[dump] 原始视频包落盘开启 → Documents/rawvideo.bin")
        }
        guard let fh = rawVideoDump else { return }
        var len = UInt32(data.count).littleEndian
        fh.write(Data(bytes: &len, count: 4))
        fh.write(data)
    }

    private var stallLogged = false

    /// 静默报告（每段静默只报一次；入站到达时复位）。
    private func reportStall() {
        guard !stallLogged else { return }
        stallLogged = true
        let idle = Date().timeIntervalSince(lastInbound)
        sessionLog("⚠ \(String(format: "%.0f", idle))s 无入站数据（累计收 \(inboundBytes)B）——保持连接继续保活")
        if inboundBytes == 0 {
            sessionLog("诊断：入站为 0 → 相机未回应握手/订阅帧（命令细节需真机校准）；WiFi 层仍保持")
        }
    }

    // MARK: - 收包与遥测

    private func handleInbound(_ data: Data) {
        // 入站原始帧日志（前 20 个包全 hex——会话建立校准的关键观察点）
        inboundLogCount &+= 1
        if inboundLogCount <= 20 {
            let hex = [UInt8](data).map { String(format: "%02x", $0) }.joined()
            sessionLog("← RX[\(inboundLogCount)] [\(data.count)B]: \(String(hex.prefix(160)))")
        }
        // S2C 外层包头 = [len][session:3][seq:4]…（pcap 实证）：校验相机是否回显本端会话 id
        if inboundLogCount == 1, data.count >= 8 {
            let s2c = [UInt8](data.prefix(4))
            let local = [UInt8](sessionID)
            if Array(s2c[1...3]) != local {
                sessionLog("⚠ S2C session=\(s2c[1...3].map { String(format: "%02x", $0) }.joined()) " +
                           "≠ 本地 \(local.map { String(format: "%02x", $0) }.joined())——相机使用了不同会话 id")
            } else {
                sessionLog("✓ S2C 回显本地 session=\(local.map { String(format: "%02x", $0) }.joined())")
            }
        }
        var appReplyNeeded = false
        for frame in MimoPacket.frames(in: data) {
            if handleInboundControlFrame(frame) {
                appReplyNeeded = true
            }
        }
        if appReplyNeeded, !appReplySent {
            appReplySent = true
            Task { [weak self] in
                await self?.sendAppAnnouncement()
            }
        }
    }

    /// 官方预览开启序列（pcap 54.69–54.81s 逐帧定案）：
    /// `(ee,2f)` → 1ms → **(0x80,0x00,0x81) dst=0x48**（70B，payload=00 "APP"+零填充，cmdType=0x80 通知类）
    /// → 87ms → **(0x40,0x00,0x88) dst=0x28**（27B，payload=17 0000 23 00 "AP" 50…）
    /// → 120ms → 视频大包开始。
    public func sendLiveViewAnnouncements() async {
        // 1. (0x80,0x00,0x81) dst=48：payload 00 + "APP" + 零填充（70B）
        var p1: [UInt8] = [0x00, 0x41, 0x50, 0x50]
        p1.append(contentsOf: [UInt8](repeating: 0, count: 66))
        let f1 = MimoFrame(sender: 0x02, receiver: 0x48, sequence: nextFrameSeq(),
                           cmdType: 0x80, cmdSet: 0x00, cmdId: 0x81, payload: Data(p1))
        await trySend(f1, label: "APP 通告(80,00,81)@48")
        // 2. 87ms 后 (0x40,0x00,0x88) dst=28
        try? await Task.sleep(nanoseconds: 87_000_000)
        let p2 = Data([0x17, 0x00, 0x00, 0x23, 0x00, 0x41, 0x50, 0x50, 0x00,
                       0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        let f2 = MimoFrame(sender: 0x02, receiver: 0x28, sequence: nextFrameSeq(),
                           cmdType: 0x40, cmdSet: 0x00, cmdId: 0x88, payload: p2)
        await trySend(f2, label: "APP 信息帧(40,00,88)@28")
    }

    private func trySend(_ frame: MimoFrame, label: String) async {
        packetSeq &+= 1
        seq8Counter &+= 8
        let packet = MimoPacket(session: sessionID, seq8: seq8Counter, sequence: packetSeq, frames: [frame])
        let data = packet.encodedData()
        let hex = [UInt8](data).map { String(format: "%02x", $0) }.joined()
        sessionLog("→ TX \(label) [\(data.count)B]: \(String(hex.prefix(120)))")
        do {
            try await link.sendUDP(data)
        } catch {
            sessionLog("✗ TX 失败 \(label): \(error.localizedDescription)")
        }
    }

    private func apply(_ push: TelemetryPush) {
        switch push.topic {
        case "cam_status":
            if let status = locate(CameraStatus.self, in: push.value) {
                telemetry.status = status
                telemetry.mode = CameraMode(rawValue: status.mode)
                telemetry.isRecording = status.stateKind == .recording
            }
        case "cam_fov":
            if let fov = locate(CameraFOV.self, in: push.value) {
                telemetry.zoomFactor = fov.zoomFactor
            }
        case "cam_record_time":
            if let seconds = locate(RecordTime.self, in: push.value)?.seconds {
                telemetry.recordSeconds = seconds
            }
        case "cam_storage":
            if let storage = locate(StorageInfo.self, in: push.value) {
                telemetry.storageBytes = storage.freeMB * 1_000_000
            }
        default:
            break
        }
        yield(.telemetryChanged(telemetry))
    }

    /// 值区可能带推送前缀，定位内嵌结构（与测试 searchingValue 同策略）。
    private func locate<T>(_ type: T.Type, in value: Data) -> T? where T: Sendable {
        // CameraStatus / CameraFOV / RecordTime / StorageInfo 各自实现 init?(value:)，此处按类型分发
        switch type {
        case is CameraStatus.Type:
            let bytes = [UInt8](value)
            guard let idx = bytes.firstIndex(of: 0x55), bytes.count - idx >= 7 else { return nil }
            return CameraStatus(value: Data(bytes[idx...])) as? T
        case is CameraFOV.Type:
            let bytes = [UInt8](value)
            guard bytes.count >= 4, let idx = bytes.firstIndex(where: { $0 != 0 }) else { return nil }
            guard bytes.count - idx >= 4 else { return nil }
            return CameraFOV(value: Data(bytes[idx...])) as? T
        case is RecordTime.Type:
            // 值区尾 4B = 秒数（[0006][seconds:4]，前缀/pad 由 init 容忍）
            return RecordTime(value: value) as? T
        case is StorageInfo.Type:
            // 值区尾 4B = 可用量 u32 LE（观测位；init 容忍前缀）
            return StorageInfo(value: value) as? T
        default:
            return nil
        }
    }

    // MARK: - 命令

    /// 开启实时预览：发 (0x40,0xEE,0x2F) 传输控制（pcap 54.69s 实证：视频大包前 120ms 首发，
    /// 338ms 后二次发送；对应 native `core22liveview_transmit_ctrl`）。
    /// 相机开始经 UDP 9004 推视频分片（SRTP 加密），管线自动分流解封装。

    /// hex 字符串 → Data（离线 pcap 载荷回放用）
    private static func hx(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return Data(bytes)
    }

    public func startLiveView() async throws {
        sessionLog("[live] 预览序列：(ee,2f)→APP通告→APP信息帧")
        try await send(MimoCommand.liveViewTransmitCtrl(sequence: nextFrameSeq()))
        try? await Task.sleep(nanoseconds: 1_000_000)
        await sendLiveViewAnnouncements()
        // 87ms 后 (00,74) 预览参数帧（pcap 同期 54.786s）
        try? await Task.sleep(nanoseconds: 87_000_000)
        await trySend(MimoCommand.liveViewParams(sequence: nextFrameSeq()),
                      label: "预览参数(00,74)@28")
        try? await Task.sleep(nanoseconds: 250_000_000)
        try await send(MimoCommand.liveViewTransmitCtrl(sequence: nextFrameSeq(), param: 0x1f00))
        // (40,03,da) [05 ff ff ff ff]——Mimo 预览序列第 4 帧（pcap #458）
        try? await Task.sleep(nanoseconds: 120_000_000)
        await trySend(MimoFrame(sender: 0x02, receiver: 0x03, sequence: nextFrameSeq(),
                                cmdType: 0x40, cmdSet: 0x03, cmdId: 0xda,
                                payload: Self.hx("05ffffffff")),
                      label: "视频启动(03,da)")
        // (00,74) 后：Mimo 完整帧序（pcap #462-#526，视频在密钥应答后 4 包开始）
        try? await Task.sleep(nanoseconds: 80_000_000)
        await trySend(MimoFrame(sender: 0x02, receiver: 0x88, sequence: nextFrameSeq(),
                                cmdType: 0x40, cmdSet: 0x00, cmdId: 0x32,
                                payload: Self.hx("3131000000")),
                      label: "配置(00,32)")
        // 20 条 (40,00,99) 主题订阅（payload 已剥原 CRC，MimoFrame 重算）
        let topics: [String] = [
            "02020000a3a7000000000011000b0063616d5f73746f726167650000000000",
            "02020000a4a7000000000010000a0063616d5f737461747573000000000000",
            "02020000a5a7000000000015000f0063616d5f7265636f72645f74696d65000000000000",
            "02020000a6a7000000000014000e0063616d5f6578706f5f706172616d000000000000",
            "02020000a7a7000000000013000d00736875747465725f706172616d000000000000",
            "02020000a8a7000000000015000f0063616d5f70686f746f5f706172616d000000000000",
            "02020000a9a7000000000015000f0063616d5f6c617073655f706172616d000000000000",
            "02020000aaa700000000001800120063616d5f766964656f5f706172616d5f7632000000000000",
            "02020000aba700000000001600100063616d5f696d6167655f656666656374000000000000",
            "02020000aca700000000001e001800765f7175616c6974795f656e68616e63655f737461747573000000000000",
            "02020000ada700000000000d00070063616d5f666f76000000000000",
            "02020000aea7000000000014000e0063616d5f6c656e735f7374617465000000000000",
            "02020000afa700000000001900130063616d5f617564696f5f7374617475735f7632000000000000",
            "02020000b0a700000000001b001500617564696f5f74696d65636f64655f737461747573000000000000",
            "02020000b1a7000000000010000a0074656d705f6375727665000000000000",
            "02020000b2a7000000000013000d0063616d6361705f636f6d6d6f6e000000000000",
            "02020000b3a700000000001800120063616d5f696d755f63616c69625f696e666f000000000000",
            "02020000b4a7000000000013000d0074696d65636f64655f696e666f000000000000",
            "02020000b5a700000000001c00160063616d5f637573746f6d5f6d6f64655f706172616d73000000000000",
            "02020000b6a700000000001a00140063616d5f6d61676e69666965725f737461747573000000000000",
        ]
        for (k, hexPl) in topics.enumerated() {
            await trySend(MimoFrame(sender: 0x02, receiver: 0x28, sequence: nextFrameSeq(),
                                    cmdType: 0x40, cmdSet: 0x00, cmdId: 0x99,
                                    payload: Self.hx(hexPl)),
                          label: "主题订阅#\(k)")
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        // (40,02,8e) 推送开启（WiFi 版 payload [00 01 18 00]）
        await trySend(MimoFrame(sender: 0x02, receiver: 0x01, sequence: nextFrameSeq(),
                                cmdType: 0x40, cmdSet: 0x02, cmdId: 0x8e,
                                payload: Self.hx("00011800")),
                      label: "推送开启(02,8e)")
        // (40,00,26) 直播质量配置（pcap #525，紧邻密钥请求）
        try? await Task.sleep(nanoseconds: 150_000_000)
        await trySend(MimoFrame(sender: 0x02, receiver: 0x01, sequence: nextFrameSeq(),
                                cmdType: 0x40, cmdSet: 0x00, cmdId: 0x26,
                                payload: Self.hx("4a002a1001000000000001000000ffff0c0000000000000000000000010000000000000000000000")),
                      label: "直播配置(00,26)")
        // (40,00,51)@28 [05 ec 09] = 密钥请求（pcap #526，相机回 [00 10][16B key]，4 包后视频开始）
        for wait: UInt64 in [0, 2_000_000_000, 5_000_000_000] {
            if wait > 0 { try? await Task.sleep(nanoseconds: wait) }
            await trySend(MimoFrame(sender: 0x02, receiver: 0x28, sequence: nextFrameSeq(),
                                    cmdType: 0x40, cmdSet: 0x00, cmdId: 0x51,
                                    payload: Self.hx("05ec09")),
                          label: "视频密钥请求(预览后)")
        }
    }

    /// 模式切换（docs/protocol/control-channel.md §4.1）
    public func setMode(_ mode: CameraMode) async throws {
        try await send(MimoCommand.modeSwitch(mode, sequence: nextFrameSeq()))
    }

    /// 录制开始（§4.2；停止命令未定，见文档 §6 未定项）
    public func startRecording() async throws {
        try await send(MimoCommand.recordStart(sequence: nextFrameSeq()))
    }

    private func sendHandshakeAndSubscriptions() async {
        try? await send(MimoCommand.handshakeIntro(sequence: nextFrameSeq()))
        for topic in Self.coreTopics {
            requestID &+= 1
            try? await send(MimoCommand.subscribe(topic: topic, requestID: requestID,
                                                  sequence: nextFrameSeq()))
        }
    }

    /// WiFi 通道 WMS 查询（pklg 实证 2026-10-27，Mimo 真实帧序）：
    /// 握手(00,2b)→扫频(00,4f)→TOKEN(40,07,45)+BLE token→get_ssid(07,07)→get_password(07,0e)
    /// 应答 [c0,07,0e] pl=[07 0e][len:2][明文密码] → Keychain 记忆 → 断线后自动重连
    private func startWMSProbe() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // pklg 实测 TOKEN（官方 Mimo 真实帧抓取，作为兜底默认值）
            let token = UserDefaults.standard.data(forKey: "camera.wms_token")
                ?? Data([0x20, 0x63, 0x33, 0x38, 0x32, 0x66, 0x65, 0x34, 0x34, 0x36, 0x30, 0x35,
                         0x36, 0x61, 0x32, 0x37, 0x66, 0x36, 0x30, 0x66, 0x62, 0x31, 0x30, 0x38,
                         0x39, 0x63, 0x30, 0x38, 0x63, 0x61, 0x64, 0x35, 0x33, 0x04, 0x37, 0x33,
                         0x34, 0x30, 0x01, 0x01])
            let queries: [(UInt8, UInt8, UInt8, [UInt8], String)] = [
                // dst 按 pklg/pcap 官方逐帧实证：握手→F0（网关）、扫频→48、TOKEN/凭据→07、enc_probe→07
                (0xF0, 0x00, 0x2b, [0x04, 0x00], "握手"),
                (0x48, 0x00, 0x4f, [0x04, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff], "扫频配置"),
                (0x07, 0x07, 0x45, [UInt8](token), "TOKEN"),
                (0x07, 0x07, 0x07, [0x00], "get_ssid"),
                (0x07, 0x07, 0x0E, [0x00], "get_password"),
                // 视频加密密钥请求（Mimo pcap 实证：预览开启前 (40,00,51)@dst68 pl=[04 03 5a]，
                // 相机回 (c0,00,51) [00 10][16B]——2026-10-30 逆向：视频流 = AES-CTR/CBC，key 由此下发）
                (0x28, 0x00, 0x51, [0x05, 0xec, 0x09], "视频密钥请求"),
                // 加密模式入口（pklg 实证：token 验证后命令走 (07,72)）
                // payload 首帧=4B 头；测试用 Mimo 同款头 + 探测数据
                (0x07, 0x07, 0x72, [0x00, 0x6c, 0xd2, 0x4c, 0x00], "enc_probe"),
                // 1D05 相机状态订阅（官方遥控器协议备选路径，push_mode=3 周期+变化，freq=20=2Hz；
                // 1D02 推送含电量@37——主题空间无电量主题，此路径若通则遥测含电量）
                (0x01, 0x1D, 0x05, [0x03, 0x14, 0x00, 0x00, 0x00, 0x00], "状态订阅(1d,05)"),
            ]
            for (dst, set, id, pl, name) in queries {
                guard let self, !(await self.checkStopping()) else { return }
                let frame = MimoFrame(sender: 0x02, receiver: dst, sequence: await self.nextFrameSeq(),
                                      cmdType: 0x40, cmdSet: set, cmdId: id, payload: Data(pl))
                await self.trySend(frame, label: "WMS-\(name)(40,\(String(set, radix: 16)),\(String(id, radix: 16)))")
                try? await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    /// UDP 9004 的 48B ACK 心跳（pcap 19:52:35.425 实证，官方 App 的会话首包+保活帧）：
    /// 外层包头 `[len][session:3][seq:4]`，session 由 App 侧声明、相机回显（pcap 中手机
    /// 先发此包声明 80c615，相机 4ms 后 S2C 回显同值）。构建时嵌入当前 sessionID。
    private func startACKKeepalive() {
        ackKeepaliveTask?.cancel()
        let payload = Data([0x30] + [UInt8](sessionID) + [
            0x00, 0x00, 0x00, 0x63, 0x30, 0xae, 0x64, 0x00, 0x64, 0x00,
            0xc0, 0x05, 0x14, 0x00, 0x00, 0x64, 0x00, 0x00, 0x01, 0x90, 0x01, 0xc0, 0x05, 0x14,
            0x00, 0x00, 0x64, 0x00, 0x14, 0x00, 0x64, 0x00, 0xc0, 0x05, 0x14, 0x00, 0x00, 0x64,
            0x00, 0x01, 0x01, 0x04, 0x01, 0x02,
        ])
        ackKeepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, await !self.checkStopping() {
                    try? await self.link.sendUDP(payload)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func startHeartbeat() {        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(TCPHeartbeat.interval * 1_000_000_000))
                guard let self, await !self.stopping else { return }
                try? await self.link.sendTCP(TCPHeartbeat.payload)
            }
        }
    }

    private func send(_ frame: MimoFrame) async throws {
        packetSeq &+= 1
        seq8Counter &+= 8
        let packet = MimoPacket(session: sessionID, seq8: seq8Counter, sequence: packetSeq, frames: [frame])
        let data = packet.encodedData()
        if packetSeq <= 5 || packetSeq % 50 == 0 {
            let hex = [UInt8](data).map { String(format: "%02x", $0) }.joined()
            sessionLog("→ TX 包#\(packetSeq) [\(data.count)B]: \(hex)")
        }
        try await link.sendUDP(data)
    }

    private func nextFrameSeq() -> UInt16 {
        frameSeq &+= 1
        return frameSeq
    }
}

/// cam_record_time 值：`[0006] [seconds:4 LE]`（telemetry.md §4，观测 1→12 递增）
struct RecordTime: Sendable {
    let seconds: Int

    init?(value: Data) {
        let b = [UInt8](value)
        guard b.count >= 4 else { return nil }
        // 值区尾部取 4 字节小端秒数；抓包观测形如 …0600 01000000
        let tail = Array(b.suffix(4))
        seconds = Int(tail[0]) | Int(tail[1]) << 8 | Int(tail[2]) << 16 | Int(tail[3]) << 24
    }
}

/// cam_storage 值解析（2026-10-28 真实样例 video_s2c_1.hex 定案）：
/// 值区 22B = `[0012][0100][0001][total_mb:4 LE][free_mb:4 LE][00000000][remain_photo:4 LE]`
/// 前带 pad/长度前缀；以 `00 12 01 00 00 01` 签名定位后取偏移。
/// 实证：total=0x1cff3=118,259MB（跨会话恒定，128GB 卡），free=0x1c2b0=115,408MB（录制递减），
/// 末尾 0x225F=8,799（剩余照片数，非容量——旧 suffix(4) 实现语义错误）。
struct StorageInfo: Sendable {
    let totalMB: Int
    let freeMB: Int

    init?(value: Data) {
        let b = [UInt8](value)
        let signature: [UInt8] = [0x00, 0x12, 0x01, 0x00, 0x00, 0x01]
        guard let s = b.firstRange(of: signature), b.count - s.upperBound >= 8 else { return nil }
        let base = s.upperBound // 签名结束处 = total_mb 起点
        func u32(_ o: Int) -> Int {
            Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        totalMB = u32(base)
        freeMB = u32(base + 4)
    }
}

/// 旧 (0x00,0x81)@dst48 响应版保留（收到相机模型广播时的应答路径）。
extension CameraSession {
    fileprivate func sendAppAnnouncement() async {
        var payload: [UInt8] = [0x00, 0x41, 0x50, 0x50]
        payload.append(contentsOf: [UInt8](repeating: 0, count: 60))
        let frame = MimoFrame(sender: 0x02, receiver: 0x48, sequence: nextFrameSeq(),
                              cmdType: 0x00, cmdSet: 0x00, cmdId: 0x81, payload: Data(payload))
        await trySend(frame, label: "APP 应答(0x00,0x81)")
    }
}
