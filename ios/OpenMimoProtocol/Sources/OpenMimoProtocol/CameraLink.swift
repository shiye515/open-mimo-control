import Foundation
import Network

/// 与相机的一条连接（UDP 9004 + TCP 7001）。实现方负责收发与关闭；
/// `open()` 返回的入站流在链路关闭时自然结束。
public protocol CameraLink: Sendable {
    func open() async throws -> AsyncStream<Data>
    func sendUDP(_ data: Data) async throws
    func sendTCP(_ data: Data) async throws
    func close() async
}

/// NWConnection 实现（UDP 命令/遥测 + TCP 心跳）。
///
/// 并发约定：连接常驻（open 时建立），state 回调只负责就绪标记与入站收包；
/// continuation 一律经 `OnceResult` 保证单次 resume（真机曾因 double-resume 闪退，勿回退）。
/// 就绪判定：**UDP 就绪即 open 成功**（命令通道）；TCP 7001 尽力而为（相机可能限单客户端，
/// 且部分状态帧对控制非必需），其状态经 `onEvent` 上报。
///
/// 必须是 class：open() 建立的连接对象挂在实例 state 上，sendUDP/close 经同一实例访问。
/// （曾为 struct 且 open() 内局部 State 遮蔽实例属性 → sendUDP 永远读到空 State，
/// 全部 UDP 发送静默失败、相机 0 入站——2026-10-28 真机日志实锤后修复。）
public final class NWCameraLink: CameraLink, @unchecked Sendable {
    let host: NWEndpoint.Host
    let udpPort: NWEndpoint.Port
    let tcpPort: NWEndpoint.Port
    let onEvent: (@Sendable (String) -> Void)?
    /// TCP 7001 收到的数据（RTP 信令：SRTP 密钥经此下发，live-view.md §5）
    let onTCPData: (@Sendable (Data) -> Void)?

    public init(host: String, udpPort: Int = 9004, tcpPort: Int = 7001,
                onEvent: (@Sendable (String) -> Void)? = nil,
                onTCPData: (@Sendable (Data) -> Void)? = nil) {
        self.host = NWEndpoint.Host(host)
        self.udpPort = NWEndpoint.Port(rawValue: UInt16(udpPort))!
        self.tcpPort = NWEndpoint.Port(rawValue: UInt16(tcpPort))!
        self.onEvent = onEvent
        self.onTCPData = onTCPData
    }

    /// 线程安全的连接状态与单次放行的 open continuation。
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var udp: NWConnection?
        var tcp: NWConnection?
        var udpReady = false
        var tcpReady = false
        var shuttingDown = false
        var openResult: OnceResult?
        var inboundContinuation: AsyncStream<Data>.Continuation?

        var isShuttingDown: Bool {
            lock.lock(); defer { lock.unlock() }
            return shuttingDown
        }

        func setUDPReady() {
            lock.lock()
            udpReady = true
            let result = openResult
            openResult = nil
            lock.unlock()
            result?.succeed()
        }

        func setTCPReady() {
            lock.lock()
            tcpReady = true
            lock.unlock()
        }

        /// TCP 重建：替换连接对象并清除就绪标志。
        func replaceTCP(_ connection: NWConnection) {
            lock.lock()
            tcpReady = false
            let old = tcp
            tcp = connection
            lock.unlock()
            old?.cancel()
        }

        func invalidateTCP() {
            lock.lock()
            tcpReady = false
            tcp = nil
            lock.unlock()
        }

        func failOpen(_ error: Error) {
            lock.lock()
            let result = openResult
            openResult = nil
            lock.unlock()
            result?.fail(error)
        }

        func udpConnection() -> NWConnection? {
            lock.lock(); defer { lock.unlock() }
            return udpReady ? udp : nil
        }

        func tcpConnection() -> NWConnection? {
            lock.lock(); defer { lock.unlock() }
            return tcpReady ? tcp : nil
        }

        func setInbound(_ c: AsyncStream<Data>.Continuation) {
            lock.lock()
            inboundContinuation = c
            lock.unlock()
        }

        func cancelAll() {
            lock.lock()
            shuttingDown = true
            udpReady = false
            tcpReady = false
            let connections = [udp, tcp].compactMap { $0 }
            udp = nil
            tcp = nil
            let inbound = inboundContinuation
            inboundContinuation = nil
            lock.unlock()
            connections.forEach { $0.cancel() }
            // 显式结束入站流：保证 pump/runLoop 必定解除阻塞并走重连
            inbound?.finish()
        }
    }

    /// 单次放行的 continuation 包装（重复调用安全忽略）。
    private final class OnceResult: @unchecked Sendable {
        private let lock = NSLock()
        private var consumed = false
        private let continuation: CheckedContinuation<Void, Error>

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        func succeed() {
            lock.lock()
            guard !consumed else { lock.unlock(); return }
            consumed = true
            let c = continuation
            lock.unlock()
            c.resume()
        }

        func fail(_ error: Error) {
            lock.lock()
            guard !consumed else { lock.unlock(); return }
            consumed = true
            let c = continuation
            lock.unlock()
            c.resume(throwing: error)
        }
    }

    public func open() async throws -> AsyncStream<Data> {
        let st = State()
        state = st // 暴露给 sendUDP/sendTCP/close（重连路径复用同一实例）
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        st.setInbound(continuation)
        // 捕获本次连接的 state 实例：旧流终止只影响旧连接，不波及重连后的新 state
        continuation.onTermination = { _ in st.cancelAll() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            st.lock.lock()
            st.openResult = OnceResult(cont)
            st.lock.unlock()

            let udp = NWConnection(host: host, port: udpPort, using: .udp)
            st.lock.lock()
            st.udp = udp
            st.lock.unlock()

            udp.stateUpdateHandler = { [onEvent] newState in
                switch newState {
                case .ready:
                    onEvent?("UDP 通道就绪")
                    st.setUDPReady()
                    Self.receiveLoop(udp, continuation) { error in
                        onEvent?("UDP 接收错误: \(error)")
                    }
                case .failed(let error):
                    onEvent?("UDP 失败: \(error)")
                    st.failOpen(error)
                case .cancelled:
                    onEvent?("UDP 连接被取消（cancel 调用方排查点）")
                default:
                    break
                }
            }
            // TCP 心跳通道：失败/等待后自动重建（相机依赖 TCP 1s 心跳判活，必须保住）
            // 2026-10-29：TCP 7001 同时是 **RTP 信令通道**（SRTP 密钥经此下发，见 live-view.md §5），
            // 就绪后启动接收循环，收到数据经 onTCPData 交出。
            func startTCP() {
                guard !st.isShuttingDown else { return }
                let tcp = NWConnection(host: host, port: tcpPort, using: .tcp)
                st.replaceTCP(tcp)
                tcp.stateUpdateHandler = { [onEvent, onTCPData] newState in
                    switch newState {
                    case .ready:
                        onEvent?("TCP 通道就绪（心跳通道可用）")
                        st.setTCPReady()
                        Self.tcpReceiveLoop(tcp, onData: { data in
                            onTCPData?(data)
                        }, onError: { error in
                            onEvent?("TCP 接收错误: \(error)")
                        })
                    case .failed(let error):
                        onEvent?("TCP 失败: \(error)，1s 后重建…")
                        st.invalidateTCP()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { startTCP() }
                    case .waiting(let error):
                        onEvent?("TCP 等待中: \(error)（不强拆，继续等）")
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
                tcp.start(queue: .global())
            }
            startTCP()

            udp.start(queue: .global())
        }
        return stream
    }

    /// TCP 接收循环（RTP 信令；TCP 的 isComplete 才是真断链）。
    private static func tcpReceiveLoop(_ connection: NWConnection,
                                       onData: @escaping (Data) -> Void,
                                       onError: @escaping (Error) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error { onError(error); return }
            if let data, !data.isEmpty { onData(data) }
            if isComplete {
                onError(NSError(domain: "NWCameraLink", code: 4,
                                userInfo: [NSLocalizedDescriptionKey: "TCP 对端关闭"]))
                return
            }
            tcpReceiveLoop(connection, onData: onData, onError: onError)
        }
    }

    /// UDP 收包循环（入站流唯一来源）。static：闭包内调用无需捕获 self。
    ///
    /// 真机实测（2026-10-28，iOS 18/XS）：UDP receive 会在**首包就返回 isComplete=true 且无错误**——
    /// UDP 并无"流结束"语义，不能据此断链（此前每轮只收到 1 个包就自毁重连，即此因）。
    /// 策略：无错误的 isComplete 继续收包；连续 10 次无数据的 isComplete 才判定失效；
    /// 真正的错误立即断流。
    private static func receiveLoop(_ connection: NWConnection, _ continuation: AsyncStream<Data>.Continuation,
                                    onError: ((Error) -> Void)? = nil,
                                    idleSpins: Int = 0) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            if let error {
                onError?(error)
                continuation.finish()
                return
            }
            if let data {
                continuation.yield(data)
                receiveLoop(connection, continuation, onError: onError, idleSpins: 0)
                return
            }
            if isComplete {
                let spins = idleSpins + 1
                if spins >= 10 {
                    onError?(NSError(domain: "NWCameraLink", code: 3,
                                     userInfo: [NSLocalizedDescriptionKey: "连续 isComplete 无数据（连接疑似失效）"]))
                    continuation.finish()
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                    receiveLoop(connection, continuation, onError: onError, idleSpins: spins)
                }
                return
            }
            receiveLoop(connection, continuation, onError: onError, idleSpins: idleSpins)
        }
    }

    public func sendUDP(_ data: Data) async throws {
        // 未就绪时短暂等待（吸收 ready 事件与首次发送之间的竞态）
        var connection: NWConnection?
        for _ in 0..<20 {
            if let c = state.udpConnection() { connection = c; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let connection else {
            throw NSError(domain: "NWCameraLink", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "UDP 通道未就绪（等待 2s 超时）"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            // 唯一 resume 点：completion 回调
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func sendTCP(_ data: Data) async throws {
        guard let connection = state.tcpConnection() else {
            throw NSError(domain: "NWCameraLink", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "TCP 通道未就绪"])
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    public func close() async {
        state.cancelAll()
    }

    /// 当前连接的收发状态（open() 时整体替换；class 语义下所有副本共享同一实例）。
    private var state = State()
}
