import Foundation
import Network

/// DJI Osmo 实时画面 datalink——基于 osmocam 项目 (MIT) 的协议逆向。
/// 视频流为未加密 H.265 Annex-B（Action 4: 1280x720），经 UDP 9004 传输。
public final class OSMOCameraLink {

    // MARK: - 常量（实例级，避免 static 访问问题）

    private let videoHeaderSize = 20
    private let seqStep: UInt16 = 8
    private let ackIntervalNs: UInt64 = 25_000_000
    private let heartbeatIntervalNs: UInt64 = 200_000_000
    private let cameraHost = "192.168.2.1"
    private let datalinkPort: UInt16 = 9004
    private let pokePort: UInt16 = 7001

    private let addrApp: UInt8 = 0x02
    private let addrCamera: UInt8 = 0x01
    private let addrWiFi: UInt8 = 0x07
    private let addrLiveView: UInt8 = 0x41
    private let addrEncoder1: UInt8 = 0x28
    private let addrEncoder2: UInt8 = 0x48
    private let addrTopics: UInt8 = 0x28

    private let appIdentity = "284ae5b8d76b3375a04a6417ad71bea3"
    private let pairToken = "osmo"

    // MARK: - 状态

    private var connection: NWConnection?
    private var ackTimer: DispatchSourceTimer?
    private var heartbeatTimer: DispatchSourceTimer?
    /// 设置轮询定时器（相机端改动同步：参数 GET 每 3s 一轮）
    private var settingsPollTimer: DispatchSourceTimer?
    /// 画面旋转象限专用快轮询（pid 0x0014，1s——旋转预览跟随需要比 3s 参数轮询更快）
    private var orientationPollTimer: DispatchSourceTimer?

    private var session: UInt16
    private var baseSeq: UInt16
    private var linkSeq: UInt16 = 0
    private var dataSeq: UInt16 = 0
    private var dataCount: UInt8 = 0
    private var messageSeq: UInt16 = 0xA000
    private var cursors: [UInt16] = [0, 0, 0]
    private var ackedCursor: Int = -1
    private var heartbeatTick = 0

    private var unacked: [(seq: UInt16, packet: Data, sent: DispatchTime)] = []
    private var acksSeen = false
    private var lastAckTime: DispatchTime = .now()

    private let queue = DispatchQueue(label: "osmo-datalink", qos: .userInteractive)
    private let lock = NSLock()
    private var stopped = false
    private(set) var isReady = false

    // MARK: - 回调

    public var onVideo: ((Data) -> Void)?
    public var onMessage: ((UInt8, UInt8, UInt8, Data) -> Void)?
    public var onLog: ((String) -> Void)?
    /// 相机状态快照变化（节流 ~0.5s 一次，datalink 线程）
    public var onStatus: ((OSMOStatusSnapshot) -> Void)?

    /// 状态跟踪：解析 02/80、0D/02、02/DC、00/99 推送、00/76 事件与
    /// 02/1F/2B/29/2D/13/8E 查询应答（02/19 已退役，仅存活探测兼容）
    let statusTracker = OSMOStatusTracker()
    /// 事件回调（00/76 固件动作事件 event_id；失败事件由上层 toast）
    public var onEventFailure: ((String) -> Void)?
    private var lastStatusEmit: DispatchTime?

    // MARK: - Frame Assembler

    private var frameAssembler: FrameAssembler!

    public struct FrameAssembler {
        var data = [UInt8]()
        var need = 0
        var synced = false
        var nextSeq: UInt16?
        var params: Data?
        var keyframes = 0
        var videoSince: DispatchTime?
        var truncated = 0
        weak var owner: OSMOCameraLink?

        mutating func add(seq: UInt16, data: Data, now: DispatchTime) {
            guard let owner else { return }
            let bytes = [UInt8](data)
            if videoSince == nil { videoSince = now }
            let lost = nextSeq != nil && seq != nextSeq!
            nextSeq = (seq &+ owner.seqStep) & 0xFFFF

            var d = bytes
            let magic: [UInt8] = [0x00, 0x00, 0x01, 0xFF]
            if d.count >= 12 && Array(d[0...3]) == magic {
                if !self.data.isEmpty { finish(short: true) }
                else if lost { truncated += 1 }
                need = Int(UInt32(d[4]) | UInt32(d[5]) << 8 | UInt32(d[6]) << 16 | UInt32(d[7]) << 24)
                // 长度域损坏防护：AU 上限 2MB（4K 码率下 IDR ~100KB），超限视为脏数据丢弃，
                // 否则 self.data/need 无界增长（长时间运行的内存崩溃源）
                if need < 1 || need > 2_000_000 {
                    need = 0
                    self.data = []
                    return
                }
                var hdrSize = Int(d[8] & 0x3F)
                if hdrSize < 12 || hdrSize > d.count { hdrSize = 16 }
                if d.count > hdrSize { d = Array(d[hdrSize...]) }
                self.data.append(contentsOf: d)
                need -= d.count
            } else if need > 0 {
                if lost { finish(short: true); return }
                let take = min(d.count, need)
                self.data.append(contentsOf: d[0..<take])
                need -= take
            } else {
                return
            }
            if need <= 0 && !self.data.isEmpty { finish() }
        }

        mutating func finish(short: Bool = false) {
            let d = Data(data)
            data = []
            need = 0
            if short { truncated += 1 }
            if d.isEmpty { return }
            let spsPattern = Data([0x00, 0x00, 0x00, 0x01, 0x42, 0x01])
            let vpsPattern = Data([0x00, 0x00, 0x00, 0x01, 0x40, 0x01])
            let isParams = d.range(of: spsPattern) != nil && d.range(of: vpsPattern) != nil && d.count < 200
            if isParams { params = d; return }
            if let p = params {
                var combined = p
                combined.append(d)
                owner?.onVideo?(combined)
                params = nil
            } else {
                owner?.onVideo?(d)
            }
            if d.range(of: spsPattern) != nil { synced = true }
        }
    }

    // MARK: - 初始化

    public init(onVideo: ((Data) -> Void)?, onMessage: ((UInt8, UInt8, UInt8, Data) -> Void)? = nil,
                onLog: ((String) -> Void)? = nil,
                onStatus: ((OSMOStatusSnapshot) -> Void)? = nil) {
        self.onVideo = onVideo
        self.onMessage = onMessage
        self.onLog = onLog
        self.onStatus = onStatus
        session = UInt16.random(in: 0x1000...0xFFFD)
        baseSeq = UInt16.random(in: 0x1000...0xEFFF) & 0xFFF8
        cursors = [0, baseSeq, baseSeq]
        frameAssembler = FrameAssembler(owner: self)
    }

    private func log(_ msg: String) { onLog?(msg) }

    // MARK: - 固定载荷（计算属性，实例级）

    private var registerPayload: Data {
        var d = Data([0x00]) + Data("APP".utf8)
        d.append(Data(count: 38))
        d.append(0x02)
        d.append(Data(count: 8))
        d.append(contentsOf: [0x02, 0x08])
        d.append(Data(count: 11))
        return d
    }

    private var appInfoReply: Data {
        var d = Data([0x00]) + Data("APP".utf8)
        d.append(Data(count: 37))
        d.append(0x02)
        d.append(Data(count: 8))
        d.append(contentsOf: [0x02, 0x08])
        d.append(Data(count: 10))
        return d
    }

    private var encoderRegister: Data {
        Data([0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02])
    }

    private let channelParams: [(UInt16, UInt16)] = [(100, 100), (256, 400), (20, 100)]
    private let handshakeTail: [UInt8] = [1, 1, 4, 1, 2]

    // MARK: - 公开接口

    /// 全局唯一活动实例：新实例 start 时停掉旧实例（双会话会互相竞争 UDP 9004 应答）
    private static var active: OSMOCameraLink?

    public func start() {
        if let old = OSMOCameraLink.active, old !== self {
            old.log("[osmo] 新 datalink 启动，停掉旧会话")
            old.stop()
        }
        OSMOCameraLink.active = self
        stopped = false
        // 状态跟踪回调（一次性挂接）：节流 0.5s 发 onStatus；模式变化 0.5s 后重查该模式参数
        statusTracker.onLog = { [weak self] line in
            guard let self else { return }
            self.log("[status] \(line)")
        }
        statusTracker.onChanged = { [weak self] snap in
            guard let self, !self.stopped else { return }
            let now = DispatchTime.now()
            if let last = self.lastStatusEmit,
               now.uptimeNanoseconds - last.uptimeNanoseconds < 500_000_000 { return }
            self.lastStatusEmit = now
            self.onStatus?(snap)
        }
        statusTracker.onCaptureModeChanged = { [weak self] _ in
            guard let self, !self.stopped else { return }
            self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !self.stopped else { return }
                self.sendStatusQueries()
            }
        }
        // 00/76 固件动作事件：全部事件入日志；失败事件经 onEventFailure 供上层 toast
        statusTracker.onEvent = { [weak self] eventID, dict in
            guard let self else { return }
            self.onLog?("[event] \(eventID)")
            let failed = (dict["is_success"] as? Bool == false) || (dict["success"] as? Int == 0)
            if failed {
                let name = (dict["action"] as? String) ?? eventID
                DispatchQueue.main.async { [weak self] in
                    self?.onEventFailure?("相机动作失败：\(name)")
                }
            }
        }
        queue.async { [weak self] in self?.pokeThenRun() }
    }

    public func stop() {
        stopped = true
        if OSMOCameraLink.active === self { OSMOCameraLink.active = nil }
        ackTimer?.cancel()
        heartbeatTimer?.cancel()
        settingsPollTimer?.cancel()
        orientationPollTimer?.cancel()
        connection?.cancel()
        pokeConnection?.cancel()
    }

    /// 单发命令帧。flags 恒为 0x40（请求位）——osmocam 参考实现对部分保活帧用
    /// 0x80/0xC0，OA4 真机全程以 0x40 验证通过，保持实测行为（历史调用点曾误传
    /// flags 参数但被本方法忽略，2026-11-13 审计移除该死参数）。
    public func send(cmdSet: UInt8, cmdId: UInt8, payload: Data = Data(), receiver: UInt8? = nil) {
        let recv = receiver ?? ((cmdSet == 0x09 && cmdId == 0xA8) ? addrLiveView : addrCamera)
        let seq = messageSeq
        messageSeq = (messageSeq &+ 1) & 0xFFFF
        let msg = encodeDUML(sender: addrApp, receiver: recv, seq: seq,
                             flags: 0x40, cmdSet: cmdSet, cmdId: cmdId, payload: payload)
        sendDataPacket(msg)
    }

    public func requestKeyframe() {
        send(cmdSet: 0x09, cmdId: 0xA8, payload: Data([0, 4, 2, 0, 0, 0, 0, 0, 0, 0]))
    }

    // MARK: - 请求-应答（控制命令层，design D-ctrl）

    /// 控制命令单发等应答：应答 DUML 帧携带请求的 message seq（osmocam §2），
    /// 按.seq 匹配派发；超时由 ack 循环清扫。结果码语义见 OSMOCommandError。
    struct PendingRequest {
        let seq: UInt16
        let sentAt: DispatchTime
        let timeoutNs: UInt64
        let completion: (Result<Data, OSMOCommandError>) -> Void
    }
    private var pendingRequests: [PendingRequest] = []

    /// 发送控制命令并等待应答（完成回调在 datalink queue）。UI 层经 OSMOControl
    /// actor 串行化——同一时刻至多一条在途（specs「控制命令应答与错误统一」）。
    public func sendRequest(cmdSet: UInt8, cmdId: UInt8, payload: Data = Data(),
                            receiver: UInt8? = nil, timeout: TimeInterval = 3.0,
                            completion: @escaping (Result<Data, OSMOCommandError>) -> Void) {
        guard isReady, !stopped else { completion(.failure(.linkDown)); return }
        let seq = messageSeq
        messageSeq = (messageSeq &+ 1) & 0xFFFF
        let recv = receiver ?? ((cmdSet == 0x09 && cmdId == 0xA8) ? addrLiveView : addrCamera)
        let msg = encodeDUML(sender: addrApp, receiver: recv, seq: seq,
                             flags: 0x40, cmdSet: cmdSet, cmdId: cmdId, payload: payload)
        lock.lock()
        pendingRequests.append(PendingRequest(seq: seq, sentAt: .now(),
                                              timeoutNs: UInt64(timeout * 1e9), completion: completion))
        if pendingRequests.count > 8 {   // 队列上限兜底：全超时处理，不让 UI 悬挂
            let stale = pendingRequests.removeFirst()
            stale.completion(.failure(.timeout))
        }
        lock.unlock()
        sendDataPacket(msg)
    }

    /// async 版本（ continuation 恰好恢复一次：派发与超时清扫都先从数组移除）
    public func request(cmdSet: UInt8, cmdId: UInt8, payload: Data = Data(),
                        receiver: UInt8? = nil, timeout: TimeInterval = 3.0) async throws -> Data {
        try await withCheckedThrowingContinuation { cont in
            sendRequest(cmdSet: cmdSet, cmdId: cmdId, payload: payload, receiver: receiver,
                        timeout: timeout) { result in
                cont.resume(with: result)
            }
        }
    }

    /// parseDUML 内调用：flags 0x80 的帧按 seq 派发给在途请求
    private func dispatchReply(seq: UInt16, cmdSet: UInt8, cmdId: UInt8, flags: UInt8, payload: Data) {
        guard flags & 0x80 != 0, !pendingRequests.isEmpty else { return }
        lock.lock()
        guard let idx = pendingRequests.firstIndex(where: { $0.seq == seq }) else {
            lock.unlock(); return
        }
        let req = pendingRequests.remove(at: idx)
        lock.unlock()
        let code = payload.first ?? 0xFF
        if code == 0x00 { req.completion(.success(payload)) }
        else { req.completion(.failure(.result(code))) }
    }

    /// ack 循环（25ms）内调用：清扫超时请求
    private func sweepRequestTimeouts() {
        guard !pendingRequests.isEmpty else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        var expired: [PendingRequest] = []
        pendingRequests.removeAll { req in
            if now - req.sentAt.uptimeNanoseconds > req.timeoutNs {
                expired.append(req); return true
            }
            return false
        }
        lock.unlock()
        for req in expired { req.completion(.failure(.timeout)) }
    }

    // MARK: - TCP Poke

    /// pcap 实证：相机 datalink 未就绪时 TCP 7001 不接听，Mimo 以 ~1s 周期持续 SYN 重试直至 t+40；
    /// UDP 握手同样要 hammer 到相机就绪（真机 pcap 536 次、应答 1 次）。因此：
    /// poke 失败不放弃、握手期间每 5s 重发 pairing、握手重试上限放大到 400 次（~140s）。
    private var pokeConnection: NWConnection?

    private func pokeThenRun() {
        // 参考实现 datalink.poke：TCP 单发配对帧 → 0.4s → 关闭。不保活、不重发——
        // 高频 07/45 会不断重置相机配对状态机，datalink 永远不 open（A/B 实证）。
        let conn = NWConnection(host: NWEndpoint.Host(cameraHost),
                                port: NWEndpoint.Port(rawValue: pokePort)!, using: .tcp)
        pokeConnection = conn
        conn.stateUpdateHandler = { [weak self] state in
            if case .ready = state {
                self?.log("[osmo] TCP poke connected")
                self?.sendPoke(on: conn)
            }
            if case .failed = state {
                self?.log("[osmo] poke failed, starting datalink anyway")
                self?.startDatalink()
            }
        }
        conn.start(queue: queue)
    }

    private func sendPoke(on conn: NWConnection) {
        let payload = pairingPayload()
        let msg = encodeDUML(sender: addrApp, receiver: addrWiFi,
                             seq: 0x8092, flags: 0x40, cmdSet: 0x07, cmdId: 0x45,
                             payload: payload)
        conn.send(content: msg, completion: .contentProcessed { [weak self] err in
            if let err {
                self?.log("[osmo] poke 发送失败: \(err)")
                self?.startDatalink()
                return
            }
            // 0.4s 后关闭 TCP（参考实现同款），随后启动 UDP datalink
            self?.queue.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.stopped else { return }
                conn.cancel()
                self.log("[osmo] poke sent, TCP closed, starting datalink")
                self.startDatalink()
            }
        })
    }


    // MARK: - TCP 配对通道（osmocam §3.3 状态机）
    // 07/45 应答 payload[1]: 01=已配对 02=待批准；07/46 payload[0]: 01=已批准（否则拒绝/超时）。
    // 首次配对相机屏幕弹 "OSMO" 批准提示（~20s 超时）——无人批准则 datalink 永不开放（真机实证）。

    private var tcpBuffer = Data()
    private var tcpReceiveStarted = false

    private func startTcpReceiveIfNeeded(_ conn: NWConnection) {
        guard !tcpReceiveStarted else { return }
        tcpReceiveStarted = true
        receiveTcp(conn)
    }

    private func receiveTcp(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, !self.stopped else { return }
            if let data, !data.isEmpty {
                self.tcpBuffer.append(data)
                self.scanTcpFrames()
            }
            if isComplete {
                self.log("[osmo] TCP 对端关闭 → 5s 后重建并重 poke")
                self.pokeConnection = nil
                self.queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    guard let self, !self.stopped, self.pokeConnection == nil else { return }
                    self.pokeThenRun()
                }
                return
            }
            if let error {
                self.log("[osmo] TCP 接收错误: \(error)")
            } else {
                self.receiveTcp(conn)
            }
        }
    }

    private func scanTcpFrames() {
        let bytes = [UInt8](tcpBuffer)
        var offset = 0
        var consumed = 0
        defer { if consumed > 0 { tcpBuffer.removeFirst(consumed) } }
        while offset < bytes.count {
            guard bytes[offset] == 0x55 else { offset += 1; consumed = offset; continue }
            guard offset + 4 <= bytes.count else { consumed = offset; return }
            let rawLen = UInt16(bytes[offset+1]) | (UInt16(bytes[offset+2]) << 8)
            let frameLen = Int(rawLen & 0x3FF)
            guard frameLen >= 13 else { offset += 1; consumed = offset; continue }
            guard offset + frameLen <= bytes.count else { consumed = offset; return }   // 等更多字节
            guard crc8(Array(bytes[offset..<offset+3])) == bytes[offset+3] else { offset += 1; consumed = offset; continue }
            let frame = Array(bytes[offset..<offset+frameLen])
            let crcData = Data(bytes[offset..<offset+frameLen-2])
            let expected = UInt16(bytes[offset+frameLen-2]) | (UInt16(bytes[offset+frameLen-1]) << 8)
            guard crc16(crcData) == expected else { offset += 1; consumed = offset; continue }

            handleTcpDUML(sender: frame[4], receiver: frame[5], flags: frame[8],
                          cmdSet: frame[9], cmdId: frame[10],
                          payload: Data(frame[11..<frameLen-2]))
            offset += frameLen
            consumed = offset
        }
    }

    private func handleTcpDUML(sender: UInt8, receiver: UInt8, flags: UInt8,
                               cmdSet: UInt8, cmdId: UInt8, payload: Data) {
        let p = payload.map { String(format: "%02x", $0) }.joined().prefix(32)
        log("[osmo] TCP DUML \(String(format: "%02x", cmdSet))/\(String(format: "%02x", cmdId)) flags=\(String(format: "%02x", flags)) from=\(String(format: "%02x", sender)) pl=\(p)")
        if cmdSet == 0x07 && cmdId == 0x45 && flags & 0x80 != 0 && payload.count >= 2 {
            switch payload[1] {
            case 0x01: log("[osmo] ✅ 相机：该身份已配对")
            case 0x02: log("[osmo] ⚠️ 相机：需要在相机屏幕上批准连接（OSMO 提示，20s 超时）！")
            default: log("[osmo] 配对状态 0x\(String(format: "%02x", payload[1]))")
            }
        }
        if cmdSet == 0x07 && cmdId == 0x46 {
            if payload.first == 0x01 {
                log("[osmo] ✅ 相机屏幕已批准配对 → datalink 应开放")
            } else {
                log("[osmo] ❌ 配对未批准（拒绝或提示超时）")
            }
        }
        // 相机请求必须应答（flags 0x40）：回显 payload（00/81 回 app record），flags 0xC0（osmocam §3.4）
        if flags == 0x40 {
            let replyPayload = (cmdSet == 0x00 && cmdId == 0x81) ? appInfoReply : payload
            let msg = encodeDUML(sender: addrApp, receiver: sender, seq: 0x8093,
                                 flags: 0xC0, cmdSet: cmdSet, cmdId: cmdId, payload: replyPayload)
            pokeConnection?.send(content: msg, completion: .contentProcessed { _ in })
        }
        onMessage?(cmdSet, cmdId, sender, payload)
    }

    private func pairingPayload() -> Data {
        let identity = Data(appIdentity.utf8)
        let token = Data(pairToken.utf8)
        var d = Data([UInt8(identity.count)])
        d.append(identity)
        d.append(UInt8(token.count))
        d.append(token)
        return d
    }

    // MARK: - UDP Datalink

    private func startDatalink() {
        log("[osmo] starting UDP datalink → \(cameraHost):\(datalinkPort)")
        connection = NWConnection(host: NWEndpoint.Host(cameraHost),
                                  port: NWEndpoint.Port(rawValue: datalinkPort)!,
                                  using: .udp)
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("[osmo] UDP connected")
                // 接收循环必须先于握手启动：握手应答由 processPacket 捕获，
                // 不先 receiveMessage 就永远读不到相机回应（真机实证的卡点）。
                self?.startReceiveLoop()
                self?.handshake()
            case .failed(let err):
                self?.log("[osmo] UDP failed: \(err)")
            case .waiting(let err):
                self?.log("[osmo] UDP waiting: \(err)")
            default:
                self?.log("[osmo] UDP state: \(state)")
            }
        }
        connection?.start(queue: queue)
    }

    private func handshake() {
        let body = handshakeBody()
        sendHandshakeAttempt(body: body, attempt: 1)
    }

    private var flowRound = 0

    private func sendHandshakeAttempt(body: Data, attempt: Int) {
        // 参考实现：30 次 × 0.35s；外层 while 循环失败后重新 poke+握手（osmo_client_main.py
        // 重试循环同款）——相机释放上一客户端会话需要时间。
        guard !stopped, !isReady, attempt <= 30 else {
            if !isReady { return }
            flowRound += 1
            log("[osmo] 第 \(flowRound) 轮握手无应答，2s 后重新 poke（参考实现外层重试循环）")
            connection?.cancel()
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !self.stopped, !self.isReady else { return }
                self.pokeThenRun()
            }
            return
        }
        let pkt = makeLinkPacket(type: 0, seq: linkSeq, body: body)
        if attempt == 1 && flowRound == 0 {
            log("[osmo] 握手首包 hex: \(pkt.map { String(format: "%02x", $0) }.joined())")
        }
        connection?.send(content: pkt, completion: .contentProcessed { _ in })
        linkSeq = (linkSeq &+ seqStep) & 0xFFFF
        queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.isReady, !self.stopped else { return }
            self.sendHandshakeAttempt(body: body, attempt: attempt + 1)
        }
    }

    private func handshakeComplete() {
        guard !isReady else { return }
        isReady = true
        linkSeq = (baseSeq &+ seqStep) & 0xFFFF
        dataSeq = linkSeq
        log("[osmo] handshake OK")
        startLiveView()
        startAckLoop()
        startHeartbeatLoop()
        // 接收循环已在 UDP ready 时启动（握手阶段就要读应答）
    }

    /// 公开给媒体模式退出后恢复实时预览（重发注册/订阅序列，相机容忍重复注册）
    public func startLiveView() {
        startLiveViewRegistration()
    }

    /// 素材浏览维持心跳：`00/88` APP_PRESENCE（14B，'APP'@5-7）→ 编码器地址 0x28
    /// （osmosis holdPlayback：receiverType 0x08 + id 1，~1Hz；停止后相机脱离媒体模式）
    public func sendAppPresenceBeat() {
        send(cmdSet: 0x00, cmdId: 0x88, payload: OSMOMedia.playbackBeatPayload, receiver: addrEncoder1)
    }

    private func startLiveViewRegistration() {
        send(cmdSet: 0x00, cmdId: 0x81, payload: registerPayload)
        sendStatusSubscriptions()
        send(cmdSet: 0x02, cmdId: 0x09, payload: Data(count: 10) + Data([0x03]))
        requestKeyframe()
        send(cmdSet: 0x00, cmdId: 0x81, payload: appInfoReply, receiver: addrEncoder2)
        send(cmdSet: 0x00, cmdId: 0x88, payload: encoderRegister, receiver: addrEncoder1)
        send(cmdSet: 0x00, cmdId: 0x81, payload: appInfoReply, receiver: addrEncoder2)
        send(cmdSet: 0x00, cmdId: 0x82, payload: Data([0x00]), receiver: addrEncoder2)
        log("[osmo] live view requested (Action)")
        // 注册/订阅落定后再查询当前参数（应答由 parseDUML → statusTracker 捕获）
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, !self.stopped else { return }
            self.sendStatusQueries()
        }
        // 相机端改动同步：参数 GET 每 3s 一轮（曝光/ISO/快门/白平衡/视角/防抖/格式）。
        // 相机机身改设置不产生任何已解析的推送，只能靠轮询回读（负载 ~2.7 cmd/s，
        // 远低于官方 App 的轮询强度）。
        startSettingsPolling()
    }

    private func startSettingsPolling() {
        settingsPollTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 3.0, repeating: 3.0)
        t.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.isReady else { return }
            self.sendStatusQueries()
        }
        t.resume()
        settingsPollTimer = t
        // 旋转象限 1s 快轮询（官方 Mimo 同节奏；预览方向跟随需要低延迟）
        orientationPollTimer?.cancel()
        let o = DispatchSource.makeTimerSource(queue: queue)
        o.schedule(deadline: .now() + 1.0, repeating: 1.0)
        o.setEventHandler { [weak self] in
            guard let self, !self.stopped, self.isReady else { return }
            self.statusTracker.noteParameterRequest(OSMOA4.paramOrientation)
            self.send(cmdSet: 0x02, cmdId: 0x8E,
                      payload: OSMOA4.parameterGetPayload(type: OSMOA4.paramOrientation))
        }
        o.resume()
        orientationPollTimer = o
    }

    // MARK: - 状态订阅与查询（osmocam §5.6 / §8）

    /// 订阅命名状态主题（发到 0x28；应答 00=已订阅 / 01=该型号无此主题）。
    /// 订阅在相机重启前持续有效；重复订阅不重复推送。
    /// 订阅主题全集（官方 Mimo 同款 20 主题，2026-11-10 抓包审计 unknown-signals-report；
    /// 推送仅在变化时发生，camcap_common 能力表为一次性推送）
    static let telemetryTopics = [
        "cam_status", "cam_record_time", "cam_storage", "cam_fov", "cam_photo_param",
        "cam_lapse_param", "cam_video_param_v2", "cam_expo_param", "cam_lens_state",
        "cam_image_effect", "shutter_param", "camcap_common", "cam_custom_mode_params",
        "cam_magnifier_status", "v_quality_enhance_status", "cam_audio_status_v2",
        "audio_timecode_status", "timecode_info", "temp_curve", "cam_imu_calib_info",
    ]

    /// 能力表探测组（三方 §8.4 记录的 camcap_* 全家族，OA4 支持性未验证）：
    /// 2026-11-11 用户要求全量订阅测试，应答逐一确认后裁剪不支持的
    static let capabilityProbeTopics = [
        "camcap_base", "camcap_video_format", "camcap_iso", "camcap_shutter",
        "camcap_photo_size", "camcap_wb", "camcap_exposure_mode", "camcap_color_mode",
        "camcap_fov", "camcap_eis", "camcap_sharpness", "camcap_denoise",
        "camcap_photo_timer_interval", "camcap_timelapse_duration", "camcap_hyperlapse_ratio",
        "camcap_capture_aspect_type", "camcap_iso_auto_max", "camcap_countdown",
        "camcap_loop_video_duration", "camcap_slowmotion_ratio",
    ]

    private func sendStatusSubscriptions() {
        // 应答按发送顺序逐条回来，登记合并清单一次（两次调用会互相覆盖）
        statusTracker.expectSubscriptionAcks(Self.telemetryTopics + Self.capabilityProbeTopics)
        for (i, name) in Self.telemetryTopics.enumerated() {
            send(cmdSet: 0x00, cmdId: 0x99,
                 payload: Self.topicSubscription(name: name, id: 0x6A00 + UInt32(i)),
                 receiver: addrTopics)
        }
        log("[osmo] 已订阅 \(Self.telemetryTopics.count) 个状态主题")
        // 能力表探测：第二批订阅（id 错开 0x100），应答确认 OA4 是否支持逐项能力订阅
        for (i, name) in Self.capabilityProbeTopics.enumerated() {
            send(cmdSet: 0x00, cmdId: 0x99,
                 payload: Self.topicSubscription(name: name, id: 0x6B00 + UInt32(i)),
                 receiver: addrTopics)
        }
        log("[osmo] 已订阅 \(Self.capabilityProbeTopics.count) 个能力主题（探测）")
    }

    /// osmocam protocol.py topic_subscription：
    /// `<4s><I><3x><HH>` = "02 02 00 00" + id u32 LE + 3×00 + (nameLen+6) u16 + nameLen u16，尾 4×00
    static func topicSubscription(name: String, id: UInt32) -> Data {
        let raw = Array(name.utf8)
        var d = Data([0x02, 0x02, 0x00, 0x00])
        func le32(_ v: UInt32) -> [UInt8] {
            [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
        }
        func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
        d.append(contentsOf: le32(id))
        d.append(contentsOf: [0, 0, 0])
        d.append(contentsOf: le16(UInt16(raw.count + 6)))
        d.append(contentsOf: le16(UInt16(raw.count)))
        d.append(contentsOf: raw)
        d.append(contentsOf: [0, 0, 0, 0])
        return d
    }

    /// 当前拍摄模式下的参数查询（一次一条，间隔 0.3s——osmocam §5.9：单发等应答）。
    /// 触发点：连接落定 / 拍摄模式切换 / 3s 参数轮询 / 设置成功后 0.5s 校准。
    /// 回读走 statusTracker（02/1F/2B/29/2D/13/8E 应答解析）；视频格式已由
    /// cam_video_param_v2 推送驱动，不再轮询。UI 以回读为准。
    private func sendStatusQueries() {
        // 按模式裁剪查询：无效查询（如照片模式读视频格式）会被相机 DF 拒绝，直接不发
        let mode = statusTracker.snapshot.captureMode
        let manual = statusTracker.snapshot.exposureMode == 0x04
        var queries: [(UInt8, UInt8, Data)] = [
            (0x02, 0x1F, Data()),   // 曝光模式
            (0x02, 0x2B, Data()),   // ISO
            (0x02, 0x2D, Data()),   // 白平衡
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: OSMOA4.paramFOV)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: OSMOA4.paramEIS)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: OSMOA4.paramISOMax)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: OSMOA4.paramPro)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: OSMOA4.paramLowLight)),
            // 未解析 pid 轮询（诊断观测；负响应按 noteParameterRequest 登记的 pid 归因）
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: 0x000A)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: 0x0018)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: 0x0020)),
            (0x02, 0x8E, OSMOA4.parameterGetPayload(type: 0x0029)),
        ]
        if mode == OSMOA4.modePhoto {
            queries.insert((0x02, 0x13, Data()), at: 0)   // 照片格式（仅照片模式；视频格式由 cam_video_param_v2 推送驱动）
        }
        if manual {
            queries.append((0x02, 0x29, Data()))          // 快门（仅手动曝光可读）
        }
        for (i, q) in queries.enumerated() {
            queue.asyncAfter(deadline: .now() + Double(i) * 0.3) { [weak self] in
                guard let self, !self.stopped else { return }
                if q.0 == 0x02, q.1 == 0x8E, q.2.count >= 4 {
                    // pid 在 GET 载荷的 [2],[3]（[0]=读操作 00，[1]=01 常量）
                    self.statusTracker.noteParameterRequest(UInt16(q.2[2]) | (UInt16(q.2[3]) << 8))
                }
                self.send(cmdSet: q.0, cmdId: q.1, payload: q.2)
            }
        }
    }

    /// 外部触发的回读（设置成功后 0.5s 校准；specs「设置 → 应答 → 回读校准」）
    public func refreshStatusQueries() {
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.stopped else { return }
            self.sendStatusQueries()
        }
    }

    private func startAckLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(ackIntervalNs)))
        timer.setEventHandler { [weak self] in
            self?.sendAck()
            self?.resendUnacked()
            self?.sweepRequestTimeouts()
        }
        timer.resume()
        ackTimer = timer
    }

    private func startHeartbeatLoop() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(heartbeatIntervalNs)))
        timer.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            self.heartbeatTick += 1
            // Swift UInt8(Int) 严格转换：>255 直接 trap（真机 SIGTRAP，启动 ~102s 必崩）。
            // 参考实现为 (tick // 2) & 0xFF。
            var p = Data([1, 0, UInt8((self.heartbeatTick / 2) & 0xFF), 0, 0])
            p.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
            self.send(cmdSet: 0x00, cmdId: 0x4F, payload: p, receiver: self.addrEncoder2)
            // 老协议 statusPoll 保活组合移植（真机实证：缺失时相机视频掉到 3 帧/min）：
            // (00,51)[04]@0x48 + (00,82)@0x48 随心跳基频 0.2s；节奏表见 control-channel §4.4
            self.send(cmdSet: 0x00, cmdId: 0x51, payload: Data([0x04]), receiver: 0x48)
            self.send(cmdSet: 0x00, cmdId: 0x82, payload: Data(), receiver: 0x48)
            if self.heartbeatTick % 5 == 0 {
                self.send(cmdSet: 0x00, cmdId: 0x88, payload: self.encoderRegister, receiver: self.addrEncoder1)
            }
            if self.heartbeatTick % 20 == 0 {
                self.send(cmdSet: 0x00, cmdId: 0x00, payload: Data(), receiver: 0x28)
            }
            if self.heartbeatTick % 10 == 0 {
                self.send(cmdSet: 0x00, cmdId: 0x81, payload: self.appInfoReply, receiver: self.addrEncoder2)
                self.send(cmdSet: 0x00, cmdId: 0x82, payload: Data([0x00]), receiver: self.addrEncoder2)
            }
        }
        timer.resume()
        heartbeatTimer = timer
    }

    private func sendAck() {
        let body = ackBody(video: cursors[0], data: cursors[1], extra: cursors[2])
        let pkt = makeLinkPacket(type: 4, seq: linkSeq, body: body)
        connection?.send(content: pkt, completion: .contentProcessed { _ in })
        linkSeq = (linkSeq &+ seqStep) & 0xFFFF
    }

    private func sendDataPacket(_ msg: Data) {
        lock.lock()
        defer { lock.unlock() }
        let seq = dataSeq
        var routing = Data()
        appendLE16(&routing, (seq &- seqStep))
        appendLE16(&routing, seq)
        routing.append(contentsOf: [0, 0, 0, 0])   // osmocam "<HH4xBB2x"：seq 后 4B 填充
        routing.append(dataCount)
        routing.append(1)
        routing.append(contentsOf: [0, 0])
        let pkt = makeLinkPacket(type: 5, seq: seq, body: routing + msg)
        connection?.send(content: pkt, completion: .contentProcessed { _ in })
        unacked.append((seq, pkt, DispatchTime.now()))
        if unacked.count > 256 { unacked.removeFirst(unacked.count - 256) }
        dataSeq = (seq &+ seqStep) & 0xFFFF
        dataCount = (dataCount &+ 1) & 0xFF
    }

    private func resendUnacked() {
        lock.lock()
        defer { lock.unlock() }
        guard !unacked.isEmpty, acksSeen else { return }
        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - unacked[0].sent.uptimeNanoseconds > 300_000_000 else { return }
        for i in unacked.indices {
            connection?.send(content: unacked[i].packet, completion: .contentProcessed { _ in })
            unacked[i].sent = now
        }
    }

    private var rxPackets = 0
    private var rxVideoPackets = 0
    private var rxBytes = 0
    private var lastStatsTime: DispatchTime?

    private func startReceiveLoop() {
        receiveNext()
    }

    private func receiveNext() {
        connection?.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped else { return }
            if error != nil { return }
            guard let data else { self.receiveNext(); return }
            self.rxPackets += 1
            self.rxBytes += data.count
            var kind: UInt8 = 0
            if data.count >= 8 {
                kind = data[data.startIndex + 6]
                if kind == 2 { self.rxVideoPackets += 1 }
            }
            // 每 30s 一条收包统计（过高频率会把 diag.log 的关键日志冲出 256KB 截断窗）
            let now = DispatchTime.now()
            if let last = self.lastStatsTime,
               now.uptimeNanoseconds - last.uptimeNanoseconds > 30_000_000_000 {
                self.lastStatsTime = now
                self.log("[osmo] 收包统计: 总 \(self.rxPackets) 包 / 视频 \(self.rxVideoPackets) 包 / \(self.rxBytes / 1024)KB")
            } else if self.lastStatsTime == nil {
                self.lastStatsTime = now
            }
            if data.count < 8 {
                if !self.isReady {
                    self.log("[osmo] 收到短包 \(data.count)B: \(data.map { String(format: "%02x", $0) }.joined().prefix(40))")
                }
                self.receiveNext(); return
            }
            if !self.isReady { self.log("[osmo] 收到包 type=\(data[6]) \(data.count)B") }
            self.processPacket(data)
            self.receiveNext()
        }
    }

    private func processPacket(_ data: Data) {
        guard data.count >= 8 else { return }
        let bytes = [UInt8](data)
        let kind = bytes[6]

        switch kind {
        case 0:
            handshakeComplete()
        case 2:
            guard data.count > videoHeaderSize else { return }
            let seq = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
            cursors[0] = seq
            let group = bytes[16]
            let videoData = data.subdata(in: videoHeaderSize..<data.count)
            frameAssembler.add(seq: seq, data: videoData, now: DispatchTime.now())
        case 1:
            guard data.count >= 34 else { break }
            cursors[0] = UInt16(bytes[10]) | (UInt16(bytes[11]) << 8)
            cursors[1] = UInt16(bytes[18]) | (UInt16(bytes[19]) << 8)
            cursors[2] = UInt16(bytes[26]) | (UInt16(bytes[27]) << 8)
            if Int(cursors[2]) != ackedCursor {
                ackedCursor = Int(cursors[2])
                lock.lock()
                if let idx = unacked.firstIndex(where: { $0.seq == cursors[2] }) {
                    unacked.removeFirst(idx + 1)
                    acksSeen = true
                }
                lock.unlock()
            }
            parseDUML(data)
        case 3:
            if data.count > 5 {
                let seq = UInt16(bytes[4]) | (UInt16(bytes[5]) << 8)
                cursors[1] = seq
            }
            parseDUML(data)
        default:
            parseDUML(data)
        }
    }

    private func parseDUML(_ data: Data) {
        guard data.count > 8 else { return }
        let bytes = Array(data.dropFirst(8))   // 单次转换（原 subdata + Array 双重复制）
        var offset = 0
        while offset + 13 <= bytes.count {
            guard bytes[offset] == 0x55 else { offset += 1; continue }
            let rawLen = UInt16(bytes[offset+1]) | (UInt16(bytes[offset+2]) << 8)
            let frameLen = Int(rawLen & 0x3FF)
            guard frameLen >= 13, offset + frameLen <= bytes.count else { offset += 1; continue }
            guard crc8(Array(bytes[offset..<offset+3])) == bytes[offset+3] else { offset += 1; continue }
            let crcData = Data(bytes[offset..<offset+frameLen-2])
            let expectedCRC = UInt16(bytes[offset+frameLen-2]) | (UInt16(bytes[offset+frameLen-1]) << 8)
            guard crc16(crcData) == expectedCRC else { offset += 1; continue }

            let sender = bytes[offset+4]
            let seq = UInt16(bytes[offset+6]) | (UInt16(bytes[offset+7]) << 8)
            let flags = bytes[offset+8]
            let cmdSet = bytes[offset+9]
            let cmdId = bytes[offset+10]
            let payload = Data(bytes[offset+11..<offset+frameLen-2])

            if flags == 0x40 {
                answerRequest(cmdSet: cmdSet, cmdId: cmdId, sender: sender)
            }
            dispatchReply(seq: seq, cmdSet: cmdSet, cmdId: cmdId, flags: flags, payload: payload)
            onMessage?(cmdSet, cmdId, sender, payload)
            feedStatus(cmdSet: cmdSet, cmdId: cmdId, sender: sender, payload: payload)
            offset += frameLen
        }
    }

    /// DUML 帧 → 状态跟踪器；快照变化节流 0.5s 发一次 onStatus。
    /// handle 在 datalink 队列执行：tracker 状态与 noteEVWrite / noteParameterRequest 等
    /// 登记路径天然串行（NW 接收回调线程、调用方线程都不再触碰 tracker）
    private func feedStatus(cmdSet: UInt8, cmdId: UInt8, sender: UInt8, payload: Data) {
        queue.async { [weak self] in
            self?.statusTracker.handle(cmdSet: cmdSet, cmdId: cmdId, sender: sender, payload: payload)
        }
    }

    /// 链路队列登记最近写入的 EV 码（setEV 从调用方线程调用，跳转后与解析串行；
    /// cam_expo_param 滑动窗口解析锚点）
    func noteEVWrite(_ code: UInt8) {
        queue.async { [weak self] in self?.statusTracker.lastSetEVCode = code }
    }

    private func answerRequest(cmdSet: UInt8, cmdId: UInt8, sender: UInt8) {
        var payload: Data
        if cmdSet == 0x00 && cmdId == 0x81 { payload = appInfoReply }
        else if cmdSet == 0x00 && cmdId == 0x88 { payload = Data([0x1A, 0x00, 0x00, 0x00, 0x00]) }
        else { payload = Data([0x00]) }
        let seq = messageSeq
        messageSeq = (messageSeq &+ 1) & 0xFFFF
        let msg = encodeDUML(sender: addrApp, receiver: sender, seq: seq,
                             flags: 0x80, cmdSet: cmdSet, cmdId: cmdId, payload: payload)
        sendDataPacket(msg)
    }

    // MARK: - 编码工具

    private func makeLinkPacket(type: UInt8, seq: UInt16, body: Data) -> Data {
        let totalLen = 8 + body.count
        var head = Data()
        let lenField = UInt16(0x8000) | UInt16(totalLen & 0x3FFF)
        appendLE16(&head, lenField)
        appendLE16(&head, session)
        appendLE16(&head, seq)
        head.append(type)
        var xor: UInt8 = 0
        for b in head { xor ^= b }
        head.append(xor)
        return head + body
    }

    private func handshakeBody() -> Data {
        // osmocam struct.pack("<HHHHBH", first, second, 1472, 20, 0, 100)：
        // 20 是 u16（H）！之前写成 1B append(20) → 每块少 1B、握手包 45B≠48B，
        // 相机解析长度不符直接丢弃（A/B 首包 hex diff 实证）。
        var body = Data()
        appendLE16(&body, baseSeq)
        for (first, second) in channelParams {
            appendLE16(&body, first)
            appendLE16(&body, second)
            appendLE16(&body, 1472)
            appendLE16(&body, 20)
            body.append(0)
            appendLE16(&body, 100)
        }
        body.append(contentsOf: handshakeTail)
        return body
    }

    private func ackBody(video: UInt16, data: UInt16, extra: UInt16) -> Data {
        var d = Data()
        for cursor in [video, data, extra] {
            appendLE16(&d, cursor)
            appendLE16(&d, cursor)
            d.append(contentsOf: [0, 0, 0, 0])
        }
        d.append(contentsOf: [0, 0])
        return d
    }

    // MARK: - CRC & DUML

    private static let crc8Table: [UInt8] = {
        (0...255).map { i -> UInt8 in
            var v = UInt8(i)
            for _ in 0..<8 { v = (v & 1) != 0 ? (v >> 1) ^ 0x8C : v >> 1 }
            return v
        }
    }()

    private static let crc16Table: [UInt16] = {
        (0...255).map { i -> UInt16 in
            var v = UInt16(i)
            for _ in 0..<8 { v = (v & 1) != 0 ? (v >> 1) ^ 0x8408 : v >> 1 }
            return v
        }
    }()

    private func crc8(_ data: [UInt8], init value: UInt8 = 0x77) -> UInt8 {
        var val = value
        for byte in data { val = Self.crc8Table[Int(val ^ byte)] }
        return val
    }

    private func crc16(_ data: Data, init value: UInt16 = 0x3692) -> UInt16 {
        var val = value
        for byte in data { val = (val >> 8) ^ Self.crc16Table[Int((val ^ UInt16(byte)) & 0xFF)] }
        return val
    }

    private func encodeDUML(sender: UInt8, receiver: UInt8, seq: UInt16,
                            flags: UInt8, cmdSet: UInt8, cmdId: UInt8, payload: Data) -> Data {
        let size = 13 + payload.count
        var head = Data([0x55])
        appendLE16(&head, UInt16((size & 0x3FF) | (1 << 10)))
        var frame = head
        frame.append(crc8([UInt8](head)))
        frame.append(sender)
        frame.append(receiver)
        appendLE16(&frame, seq)
        frame.append(flags)
        frame.append(cmdSet)
        frame.append(cmdId)
        frame.append(contentsOf: payload)
        let crc = crc16(frame)
        frame.append(contentsOf: withUnsafeBytes(of: crc.littleEndian) { Array($0) })
        return frame
    }

    // MARK: - 小工具

    private func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(contentsOf: withUnsafeBytes(of: value.littleEndian) { Array($0) })
    }
}
