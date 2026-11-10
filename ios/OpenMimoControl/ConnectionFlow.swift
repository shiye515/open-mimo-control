import Foundation
import NetworkExtension
import CoreBluetooth
import UIKit
import OpenMimoProtocol
import Combine

/// 连接流程单步定义
enum ConnectionStep: String, CaseIterable {
    case waking      = "唤醒广播"   // WKP+MAC反序 反向广播，触发相机热点开启
    case joining     = "热点入网"   // NEHotspotConfiguration apply
    case querying    = "WMS 查询"   // 握手/扫频/TOKEN/ssid/password
    case connecting  = "建立会话"   // UDP/TCP 控制会话
}

/// 连接流程状态
enum FlowState: Equatable {
    case idle
    case running(ConnectionStep)
    case success
    case failed(step: ConnectionStep, reason: String)
}

/// 线性连接流程（tasks 4.3a，design D-update）：
/// waking → joining → querying → connecting，任一步失败即停，由用户点重试重新执行。
/// 无自动循环重试。全程步骤经 StepLogger 记录。
@MainActor
final class ConnectionFlow: ObservableObject {

    @Published private(set) var state: FlowState = .idle
    @Published private(set) var currentStep: ConnectionStep?
    @Published private(set) var hotspotSSID: String = CameraWifiJoiner.DefaultCameraNetwork.ssid
    @Published private(set) var rememberedPassword: String

    /// 入网成功且密码查询完成后回调（UI 切控制页）
    var onFlowCompleted: (() -> Void)?
    /// 会话建立委托（ConnectionFlow 生成 CameraSession 后交 UI）
    var onSessionCreated: ((CameraSession) -> Void)?

    private let joiner = CameraWifiJoiner()
    private var flowTask: Task<Void, Never>?
    /// 相机 MAC（从 BLE 广播 manufacturer data 尾 6 字节解析），用于唤醒广播
    private var cameraMAC: [UInt8]?
    /// 本轮 BLE 取得的凭据（非空时入网密码用它，且跳过 UDP WMS 查询步骤）
    private var bleCredential: CameraBleWaker.CredentialResult?
    /// BLE 唤醒器引用（保持 central 活着）
    private let waker = CameraBleWaker.shared
    /// OSMO 实时画面 datalink（osmocam 协议，H.265 未加密）
    private var osmoLink: OSMOCameraLink?
    /// 后台期间曾处于已连接态（回前台时探测链路并按需重连）
    private var needsForegroundReconnect = false

    /// 素材页复用同一 datalink（相机单客户端）；未连接时为 nil
    public var activeOSMOLink: OSMOCameraLink? { osmoLink }

    /// 媒体模式退出后恢复实时预览
    public func resumeOSMOLiveView() {
        osmoLink?.startLiveView()
    }

    /// 连接成功后相机 RTC 对时（00/4A 一次；相机 RTC 断电保持，无需周期同步）
    private func syncCameraClock() {
        Task { _ = await osmoCommand("相机对时") { link in
            try await link.setCameraClock(date: Date())
        } }
    }

    /// 固件动作事件失败提示（00/76 is_success=false → 既有 osmoError toast 通道）
    private func handleEventFailure(_ message: String) {
        Task { @MainActor in
            osmoError = message
        }
    }

    /// --auto-switch 自动化钩子：切到视频模式后把分辨率在 16:9(1080p) ↔ 4:3(2.7K) 间切换
    /// （改变取景流尺寸，重启编码器），验证预览在切换后恢复
    public func autoSwitchAspect() async {
        if osmoStatus.captureMode != OSMOA4.modeVideo {
            await switchMode(OSMOA4.modeVideo)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        let res = osmoStatus.videoResolutionCode ?? 0x0A
        let target: UInt8 = res == 0x5F ? 0x0A : 0x5F   // 1080p 16:9 ↔ 2.7K 4:3
        _ = await osmoFormatCommand("自动格式切换") { link in
            try await link.setVideoFormat(res: target, fps: 3)
        }
    }
    @Published private(set) var osmoFrameCount = 0
    /// OSMO 相机状态快照（datalink 推送+查询，~0.5s 更新）
    @Published private(set) var osmoStatus = OSMOStatusSnapshot()
    private var firstFrameLogged = false
    /// H.265 解码渲染器（AVSampleBufferDisplayLayer，UI attach 后自动出画面）
    public let osmoRenderer = OSMOH265Renderer()
    /// 渲染层挂载后请求新 IDR（挂载前的关键帧已丢弃，P 帧无参考无法解码）
    public func requestOSMOKeyframe() {
        osmoLink?.requestKeyframe()
    }

    // MARK: 数码变焦（02/B8 方向+时间：捏合按住发方向命令，松手停止）

    /// 方向增量变焦（捏合按住期间 ~10Hz 调用）
    public func zoomMove(zoomIn: Bool) {
        osmoLink?.zoomMove(zoomIn: zoomIn)
    }

    /// 停止变焦（松手必发）
    public func zoomStop() {
        osmoLink?.zoomStop()
    }

    /// 绝对变焦位置（档位键）
    public func setZoomPosition(_ factor: Double) async {
        _ = await osmoCommand("变焦") { link in try await link.setZoomPosition(factor) }
    }

    /// 格式类命令（02/18 视频 / 02/12 照片 / 02/6C 延时）成功后编码器重启，
    /// 相机不再向已注册会话推流——延迟等编码器起稳后重发 live view 请求恢复预览，
    /// 并刷新回读。分辨率/帧率/比例/慢动作格式切换必须走此通道。
    public func osmoFormatCommand<T>(_ name: String,
                                     _ op: @escaping (OSMOCameraLink) async throws -> T) async -> T? {
        let ok = await osmoCommand(name, op)
        if ok != nil {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                self.resumeOSMOLiveView()
                self.refreshOSMOQueries()
            }
        }
        return ok
    }

    /// 控制命令结果反馈（specs「命令失败反馈」）；nil=无错误
    @Published private(set) var osmoError: String?
    /// 控制命令在途（specs「单发等应答」：同一时刻至多一条）
    @Published private(set) var osmoBusy = false

    /// 控制命令统一入口：单飞（在途时拒绝新命令）+ 结果码/超时错误捕获 + StepLogger
    public func osmoCommand<T>(_ name: String, _ op: @escaping (OSMOCameraLink) async throws -> T) async -> T? {
        guard let link = osmoLink else {
            osmoError = OSMOCommandError.linkDown.localizedDescription
            return nil
        }
        guard !osmoBusy else {
            osmoError = "上一条命令执行中，请稍候"
            return nil
        }
        osmoBusy = true
        defer { osmoBusy = false }
        do {
            let r = try await op(link)
            osmoError = nil
            log(.connecting, "✓ \(name)", content: "")
            return r
        } catch {
            osmoError = error.localizedDescription
            log(.connecting, "✗ \(name)失败", content: error.localizedDescription)
            return nil
        }
    }

    /// 快门/录制按钮：按模式与录制状态分派（specs「录制控制」）
    /// 照片=拍照 02/01；延时=启停 02/01；其余视频类=02/02。
    public func toggleRecord() async {
        let mode = osmoStatus.captureMode ?? OSMOA4.modeVideo
        if mode == OSMOA4.modePhoto {
            _ = await osmoCommand("拍照") { try await $0.takePhoto() }
            return
        }
        let recording = osmoStatus.recordState == 2
        let name: String
        if mode == OSMOA4.modeTimelapse {
            name = recording ? "停止延时" : "开始延时"
        } else {
            name = recording ? "停止录制" : "开始录制"
        }
        _ = await osmoCommand(name) { try await $0.setRecord(start: !recording, mode: mode) }
    }

    /// 模式切换（specs「模式切换」）：录制中先停止再切换；成功后 02/80 推送字节 57
    /// 变化触发链接层自动重查（onCaptureModeChanged）
    public func switchMode(_ mode: UInt8) async {
        guard mode != osmoStatus.captureMode else { return }
        if osmoStatus.recordState == 2 {
            let current = osmoStatus.captureMode ?? OSMOA4.modeVideo
            _ = await osmoCommand("录制中先停止") { try await $0.setRecord(start: false, mode: current) }
        }
        let ok = await osmoCommand("切换模式") { try await $0.setCaptureMode(mode) }
        if ok != nil {
            osmoLink?.refreshStatusQueries()   // 双保险：推送未到时也刷新
        }
    }

    /// 设置命令成功后的回读校准（specs「设置 → 应答 → 回读」）
    public func refreshOSMOQueries() {
        osmoLink?.refreshStatusQueries()
    }

    init() {
        rememberedPassword = KeychainStore.read(ssid: CameraWifiJoiner.DefaultCameraNetwork.ssid)
            ?? CameraWifiJoiner.DefaultCameraNetwork.password
        hotspotSSID = UserDefaults.standard.string(forKey: "camera.ssid")
            ?? CameraWifiJoiner.DefaultCameraNetwork.ssid
        CameraBleWaker.logSink = { [weak self] line in
            Task { @MainActor in
                self?.log(.waking, line, content: "")
            }
        }
        observeAppLifecycle()
    }

    // MARK: - 前后台生命周期（App 挂起后链路必然断、相机单客户端会释放会话）

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleEnteredBackground() }
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleWillEnterForeground() }
        }
    }

    private func handleEnteredBackground() {
        guard case .success = state else { return }
        needsForegroundReconnect = true
    }

    /// 回前台：探测链路——存活仅恢复推流（短后台无损）；已死整链重建（已入网走直连快路径）
    private func handleWillEnterForeground() {
        guard needsForegroundReconnect else { return }
        needsForegroundReconnect = false
        guard case .success = state, let link = osmoLink else { return }
        log(.connecting, "回前台探测链路", content: "")
        Task { [weak self] in
            let alive = (try? await link.request(cmdSet: 0x02, cmdId: 0x19, timeout: 2.0)) != nil
            guard let self else { return }
            if alive {
                log(.connecting, "链路存活", content: "恢复实时预览")
                resumeOSMOLiveView()
            } else {
                log(.connecting, "链路已断，自动重连", content: "")
                start()
            }
        }
    }

    // MARK: - 日志

    private func log(_ step: ConnectionStep, _ purpose: String, content: String = "", direction: String = "·") {
        StepLogger.shared.log(step: step.rawValue, purpose: purpose, direction: direction, content: content)
    }

    private func logFrame(_ step: ConnectionStep, direction: String, _ frame: Data, purpose: String) {
        StepLogger.shared.logFrame(step: step.rawValue, direction: direction, frame: frame, purpose: purpose)
    }

    // MARK: - 公开控制

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// 启动完整连接流程（重试=再次调用）
    func start() {
        guard !isRunning else { return }
        StepLogger.shared.clear()
        flowTask?.cancel()
        log(.waking, "流程开始", content: "用户触发连接")
        flowTask = Task { await run() }
    }

    /// 中止当前流程
    func cancel() {
        flowTask?.cancel()
        flowTask = nil
        state = .idle
        currentStep = nil
        log(.waking, "用户中止流程")
    }

    // MARK: - 线性流程

    private func run() async {
        // 0. 已在相机网络（断线重连/应用重启/相机仍广播）：跳过唤醒+BLE，直连会话。
        //    实证：相机对已建立关系的客户端会停 BLE 广播——此时 BLE 扫描必然超时，属正常状态非故障。
        currentStep = .waking
        state = .running(.waking)
        if await stepReuseJoinedNetwork() {
            // 直连：跳过 joining/querying
            currentStep = .connecting
            state = .running(.connecting)
            await stepConnect()
            state = .success
            log(.connecting, "流程完成", content: "复用相机网络直连")
            syncCameraClock()
            onFlowCompleted?()
            return
        }

        // waking：蓝牙唤醒广播（触发相机热点开启）
        guard await stepWake() else { return }

        // querying：BLE 连接 + DUML 帧序（TOKEN→get_ssid→get_password）
        currentStep = .querying
        state = .running(.querying)
        guard await stepBLEDUML() else { return }

        // joining：热点入网（用拿到的密码）
        currentStep = .joining
        state = .running(.joining)
        guard await stepJoin() else { return }

        // querying：WMS 查询（含 get_password 明文）
        currentStep = .querying
        state = .running(.querying)
        guard await stepQuery() else { return }

        // connecting：建立控制会话
        currentStep = .connecting
        state = .running(.connecting)
        await stepConnect()

        state = .success
        log(.connecting, "流程完成", content: "已连接相机")
        syncCameraClock()
        onFlowCompleted?()
    }

    // MARK: - 步骤实现

    /// 步骤 0：复用检测——当前 WiFi 已是相机热点即直连（断线重连全自动，不依赖 BLE）。
    /// 实证：相机对已建立关系的客户端会停 BLE 广播，此时 BLE 扫描必然超时（非故障）。
    /// 识别用相机前缀（兼容 SSID 变化），密码优先 Keychain（跨 App 重装持久）。
    /// 直连场景电量无 BLE 推送源——后台短暂扫 BLE（3 轮×4s）刷新电量缓存，不阻塞流程。
    private func stepReuseJoinedNetwork() async -> Bool {
        await joiner.requestLocationIfNeeded()
        let current = await joiner.currentSSID()
        log(.waking, "复用检测: fetchCurrent", content: current ?? "nil（不在相机网络）")
        guard let current, joiner.isCameraSSID(current) else { return false }
        if current != hotspotSSID {
            hotspotSSID = current
            rememberedPassword = KeychainStore.read(ssid: current) ?? rememberedPassword
        }
        guard !rememberedPassword.isEmpty else {
            log(.waking, "在相机网络但无记忆密码", content: "走完整流程（BLE 取凭据）")
            return false
        }
        log(.waking, "已在相机网络", content: "跳过唤醒/BLE，直接建立会话")
        // 缓存 MAC 供后台 BLE 任务的唤醒广播使用（相机 datalink 时常停 BLE 广播，
        // 扫描失败后需 WKP 广播触发其恢复）
        if cameraMAC == nil, let hex = UserDefaults.standard.string(forKey: "camera.mac") {
            cameraMAC = hexToBytes(hex)
        }
        // 电量：直连路径无 BLE 推送源（相机已停 BLE 广播）——会话从 BLE 缓存播种，UI 显示缓存值
        if let cached = CameraBleWaker.cachedBatteryPercent() {
            log(.waking, "电量缓存", content: "\(cached)%（BLE 场景更新）")
        }
        // 直连时后台补 BLE 会话（不阻塞主流程），两个目的：
        // ① datalink 开放条件 = 配对被相机屏幕批准（复用路径原本不发配对帧）
        // ② **BLE keepalive（00/2b 0101 每秒）是相机持续推流的条件**——无 BLE 会话时
        //    相机 1-2 帧后停止推流（真机实证：复用直连帧率 3 帧/min vs 完整流程 12fps+）。
        // 相机 datalink 运行时常停 BLE 广播 → 扫描失败后发唤醒广播（WKP）强制其恢复，再试。
        Task { [weak self] in
            guard let self else { return }
            CameraBleWaker.shared.keepBLEAlive(true)
            for round in 1...3 {
                log(.waking, "后台 BLE 会话 第\(round)/3 轮", content: "若相机屏幕弹 OSMO 提示，请按确认！")
                if await CameraBleWaker.shared.connectAndGetCredentials(timeout: 45) != nil {
                    log(.waking, "后台 BLE 会话建立", content: "keepalive 保活中 → 视频推流恢复")
                    return
                }
                guard round < 3, let mac = cameraMAC else { break }
                log(.waking, "BLE 扫描失败，发唤醒广播触发相机恢复广播", content: "")
                HotspotWaker.shared.wakeCamera(macReversed: mac.reversed()) { [weak self] line in
                    Task { @MainActor in self?.log(.waking, "唤醒广播", content: line) }
                }
                try? await Task.sleep(nanoseconds: 6_000_000_000)
            }
            log(.waking, "后台 BLE 会话未建立（3 轮）", content: "相机推流可能停止，可点连接相机重试")
        }
        // 已知局限：直连时电量显示缓存值/—，需 BLE 场景（完整连接）更新。见 telemetry.md §7。
        return true
    }

    /// 步骤 1：BLE 唤醒广播。相机休眠时热点关闭，需反向广播 WKP+MAC 反序触发热点开启。
    private func stepWake() async -> Bool {
        // MAC 来源：历史记录（UserDefaults）或 BLE 扫描现场解析
        // 优先缓存 MAC（历史成功值），无缓存才现场扫描；扫描 3 轮，全败回退缓存
        var mac: [UInt8]? = nil
        if let hex = UserDefaults.standard.string(forKey: "camera.mac") {
            mac = hexToBytes(hex)
            log(.waking, "使用缓存 MAC", content: hex)
        }
        if mac == nil {
            log(.waking, "无缓存 MAC，启动 BLE 扫描解析相机广播", content: "")
            for round in 1...3 {
                log(.waking, "MAC 扫描第\(round)/3 轮", content: "")
                mac = await scanForCameraMAC(timeout: 8)
                if mac != nil { break }
                log(.waking, "扫描未命中", content: "轮次 \(round)")
            }
        }
        guard let mac else {
            fail(.waking, "未能在广播中解析相机 MAC（相机是否开机且在附近？）")
            return false
        }
        // MAC 解析成功后写入缓存，下次跳过扫描
        UserDefaults.standard.set(mac.map { String(format: "%02x", $0) }.joined(), forKey: "camera.mac")
        let reversed = [UInt8](mac.reversed())
        log(.waking, "唤醒广播参数", content: "MAC=\(mac.map { String(format: "%02x", $0) }.joined()) 反序=\(reversed.map { String(format: "%02x", $0) }.joined())")

        // 广播 2 轮×2.5s（HotspotWaker 为 CBPeripheralManager）
        let waker = HotspotWaker.shared
        waker.wakeCamera(macReversed: reversed) { [weak self] line in
            Task { @MainActor in self?.log(.waking, "广播状态", content: line) }
        }
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        log(.waking, "唤醒广播完成", content: "等待相机热点开启")
        return true
    }

    /// 步骤 1.5：BLE 连接相机 → 发 DUML 明文帧序（TOKEN→get_ssid→get_password）
    /// pklg 实证：Mimo 不走 R 认证，连 FFF5 后直接发 DUML 帧
    private func stepBLEDUML() async -> Bool {
        log(.querying, "BLE 连接相机并发 DUML 帧序", content: "")
        // osmocam §3.3：WiFi datalink 期间 BLE 必须保持连接（1s keepalive）
        CameraBleWaker.shared.keepBLEAlive(true)
        let cred = await CameraBleWaker.shared.connectAndGetCredentials(timeout: 120)
        if let cred {
            log(.querying, "BLE 凭据获取成功", content: "ssid=\(cred.ssid) password=\(cred.password)")
            bleCredential = cred
            // 将 BLE 拿到的凭据用于入网
            hotspotSSID = cred.ssid
            rememberedPassword = cred.password
            joiner.remember(ssid: cred.ssid, passphrase: cred.password)
            return true
        }
        // 降级：本地已有记忆凭据（历史成功/手动输入）时继续入网——BLE 仅首次配对必需
        if !rememberedPassword.isEmpty {
            log(.querying, "BLE 未取得凭据，使用本地记忆凭据降级继续", content: "ssid=\(hotspotSSID)（\(CameraBleWaker.shared.status)）")
            return true
        }
        fail(.querying, "BLE 凭据获取失败：\(CameraBleWaker.shared.status)")
        return false
    }

    /// 步骤 2：热点入网（NEHotspotConfiguration apply + 系统接入等待）
    private func stepJoin() async -> Bool {
        await joiner.requestLocationIfNeeded()
        log(.joining, "apply 热点配置", content: "ssid=\(hotspotSSID) 密码=\(rememberedPassword)（明文/长度\(rememberedPassword.count)）")
        let hit = CameraWifiJoiner.ScanHit(ssid: hotspotSSID, source: .configured, hasStoredPassword: true)
        let joined = await joiner.autoConnect(hit: hit)
        if joined {
            log(.joining, "入网成功", content: "fetchCurrent=\(hotspotSSID)")
            return true
        }
        fail(.joining, "12s 内未接入热点（热点未广播或密码错误）")
        return false
    }

    /// 步骤 3：WMS 查询（握手→扫频→TOKEN→get_ssid→get_password），密码应答为明文。
    /// BLE 阶段已取得凭据时跳过——正式会话（connecting 步）内仍会执行同一 WMS 探测。
    private func stepQuery() async -> Bool {
        if bleCredential != nil {
            log(.querying, "BLE 阶段已取得凭据，跳过独立 WMS 查询会话", content: "密码以 BLE 明文应答为准")
            return true
        }
        let session = makeSessionForQuery()
        onSessionCreated?(session)
        await session.start()
        defer { Task { await session.stop() } }
        // startWMSProbe 在会话 UDP 就绪后自动发 5 连发；此处等待查询完成（含密码应答）
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if UserDefaults.standard.string(forKey: "camera.wifi_password") != nil {
                log(.querying, "密码查询完成", content: "明文密码已记忆，断线后可全自动重连")
                AppSessionHolder.shared.session = nil
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        AppSessionHolder.shared.session = nil
        fail(.querying, "WMS 查询无应答或未返回密码")
        return false
    }

    /// 步骤 4：建立 OSMO datalink。
    /// 老 CameraSession（Mimo 20B 协议）已弃用：其 runLoop 重连循环 + WMS/保活风暴会与
    /// OSMO 同时打 UDP 9004，真机实测导致帧率暴跌（3min 仅 14 帧）。OSMOCameraLink 的
    /// handshake OK 本身就是比老 session "connected" 更强的可达性确认。
    private func stepConnect() async {
        AppSessionHolder.shared.session = nil   // 切断老会话的持有与自动重建
        stopOSMOLink()   // 每次连接会话都重建链路：复用旧链路会把后台/重试前的死连接带回来
        startOSMOLiveView()
    }

    /// 关闭并丢弃当前 OSMO datalink（重连/重试前必须调用，否则死连接被复用）
    private func stopOSMOLink() {
        guard let link = osmoLink else { return }
        link.stop()
        osmoLink = nil
        osmoFrameCount = 0
        log(.connecting, "OSMOCameraLink stopped", content: "")
    }

    /// OSMO 实时画面（osmocam 协议，未加密 H.265）
    private func startOSMOLiveView() {
        guard osmoLink == nil else { return }
        osmoRenderer.onDiag = { [weak self] line in
            Task { @MainActor in
                self?.log(.connecting, line, content: "")
            }
        }
        // 编码器重启导致 format 重建后，向相机请求新关键帧兜底（重建 AU 内的 IDR
        // 万一缺失/失败，靠关键帧请求恢复——进出素材页恢复预览正是同一机制）
        osmoRenderer.onFormatRebuilt = { [weak self] in
            Task { @MainActor in self?.requestOSMOKeyframe() }
        }
        let link = OSMOCameraLink(
            onVideo: { [weak self] data in
                guard let self else { return }
                self.osmoRenderer.feed(annexb: data)
                Task { @MainActor in
                    let isFirst = self.osmoFrameCount == 0
                    self.osmoFrameCount += 1
                    if isFirst {
                        self.log(.connecting, "OSMO 首帧视频", content: "\(data.count)B → 解码渲染")
                    }
                }
            },
            onMessage: { cmdSet, cmdId, sender, payload in
                // 相机请求和推送走这里（状态解析在 link 内部 statusTracker）
            },
            onLog: { [weak self] line in
                Task { @MainActor in
                    self?.log(.connecting, line, content: "")
                }
            },
            onStatus: { [weak self] snap in
                Task { @MainActor in
                    self?.osmoStatus = snap
                }
            }
        )
        osmoLink = link
        link.onEventFailure = { [weak self] message in
            self?.handleEventFailure(message)
        }
        link.start()
        log(.connecting, "OSMOCameraLink started", content: "osmocam protocol, H.265")
    }

    // MARK: - 辅助

    private func makeSessionForQuery() -> CameraSession {
        CameraSession(link: AppSessionHolder.makeLink())
    }

    private func scanForCameraMAC(timeout: TimeInterval) async -> [UInt8]? {
        await withCheckedContinuation { cont in
            CameraBleWaker.shared.scanOnceForMAC(timeout: timeout) { mac in
                Task { @MainActor in cont.resume(returning: mac) }
            }
        }
    }

    private func hexToBytes(_ hex: String) -> [UInt8]? {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return bytes.isEmpty ? nil : bytes
    }

    private func fail(_ step: ConnectionStep, _ reason: String) {
        state = .failed(step: step, reason: reason)
        log(step, "流程失败", content: reason)
    }

    /// 供 UI 保存用户输入的凭据
    func rememberCredentials(ssid: String, password: String) {
        hotspotSSID = ssid
        rememberedPassword = password
        joiner.remember(ssid: ssid, passphrase: password)
        log(.joining, "用户更新凭据", content: "ssid=\(ssid)")
    }
}
