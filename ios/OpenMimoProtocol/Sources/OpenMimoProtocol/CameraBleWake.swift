import Foundation
import CoreBluetooth

/// BLE 唤醒 + 凭据获取一体机——复刻 Mimo 的完整连接流程：
/// 1. 扫描 "Osmo/OA4" 前缀外设
/// 2. BLE 连接 → FFF0 服务 → 认证握手（连接请求→ACK）
/// 3. 发送唤醒命令 (0x00,0x1A,[0x00]) → 相机热点开始广播
/// 4. 发送 wifi_get_ssid (0x02,0x07) + wifi_get_password (0x02,0x0E) 获取加密凭据
/// 5. 解密 → 输出真实 SSID + password
public final class CameraBleWaker: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    public static let shared = CameraBleWaker()

    public static let serviceUUID = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    public static let writeCharUUID = CBUUID(string: "0000FFF5-0000-1000-8000-00805F9B34FB")
    public static let notifyCharUUID = CBUUID(string: "0000FFF4-0000-1000-8000-00805F9B34FB")
    public static let namePrefixes = ["Osmo", "OA4", "OA5"]

    public struct CredentialResult {
        public let ssid: String
        public let password: String
    }

    /// 日志钩子：宿主 App 注入后，所有 BLE 日志（含收发帧原始 hex）同步流入统一诊断面板。
    public static var logSink: ((String) -> Void)?

    @Published public private(set) var status: String = "空闲"
    @Published public private(set) var log: [String] = []

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?
    private var fff3Char: CBCharacteristic?
    private var frameBuffer: [UInt8] = []
    private var frameSeq: UInt16 = 0x100
    private var cameraDeviceId: UInt32 = 0
    private var authComplete = false
    private var wakeComplete = false
    private var ssidResult: String?
    private var passwordResult: String?
    // ECDH 加密会话状态（docs/protocol/ble-provisioning.md）
    private var ecdhPrivateKey: Data?
    private var randApp: Data?
    private var sessionAESKey: Data?
    private var sessionIV: Data?
    private var completion: ((CredentialResult?) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?
    private var inFlight = false
    /// osmocam §3.3：BLE 全程保持连接（1s keepalive 00/2b `01 01`）。
    /// 置位后 finish() 不再断开连接，WiFi datalink 期间相机依赖此 BLE 会话。
    public func keepBLEAlive(_ on: Bool) {
        keepAliveOn = on
        if on {
            startKeepaliveLoop()
        } else {
            keepaliveWorkItem?.cancel()
            keepaliveWorkItem = nil
        }
    }

    /// BLE 会话是否已建立（peripheral + 写特征就绪）——
    /// 复用直连路径里据此跳过冗余的扫描/唤醒循环（keepalive 已在保活）
    public var bleSessionReady: Bool {
        keepAliveOn && peripheral != nil && writeChar != nil
    }

    private var keepAliveOn = false
    private var keepaliveWorkItem: DispatchWorkItem?

    /// BLE 保活间隔（秒）。写死 60s：2026-11-11 真机 A/B 实验实测 60s 仍流畅预览
    /// （5s/30s/60s 均无中断；三方 osmocam §3.3 的 1s 节奏为 Nano 机型参考）
    private var keepaliveInterval: Double { 60.0 }

    private func startKeepaliveLoop() {
        keepaliveWorkItem?.cancel()
        let first = nextKeepaliveItem()
        keepaliveWorkItem = first
        DispatchQueue.main.asyncAfter(deadline: .now() + keepaliveInterval, execute: first)
    }

    private func nextKeepaliveItem() -> DispatchWorkItem {
        let interval = keepaliveInterval
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.keepAliveOn else { return }
            self.sendKeepaliveTick()
            self.keepaliveWorkItem = self.nextKeepaliveItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: self.keepaliveWorkItem!)
        }
        return w
    }

    private func sendKeepaliveTick() {
        guard keepAliveOn, peripheral != nil, writeChar != nil else { return }
        let frame = buildDUML(src: 0x02, dst: 0xF0, seq: 0x802B, ct: 0x40, set: 0x00, id: 0x2B, pl: [0x01, 0x01])
        sendVia(frame, char: writeChar, label: "BLE-keepalive(00,2b)")
    }
    private var macScanCompletion: (([UInt8]?) -> Void)?
    private var macScanDeadline: Date?

    private func log(_ line: String) {
        DispatchQueue.main.async {
            self.status = line
            self.log.append("[ble] \(line)")
            if self.log.count > 20 { self.log.removeFirst(self.log.count - 20) }
            Self.logSink?(line)
        }
    }

    /// 帧收发原始 hex 记录（真机协议校准的关键观察点）。
    private func logFrame(_ direction: String, _ data: Data) {
        let hex = [UInt8](data).map { String(format: "%02x", $0) }.joined()
        log("\(direction)帧 hex[\(data.count)B]: \(hex)")
    }

    private func nextSeq() -> UInt16 {
        frameSeq &+= 1
        return frameSeq
    }

    // MARK: - 公开接口

    /// 扫描→连接→认证→唤醒→获取凭据。返回 nil = 失败。
    @discardableResult
    public func connectAndGetCredentials(timeout: TimeInterval = 60) async -> CredentialResult? {
        guard !inFlight else { return nil }
        inFlight = true
        authComplete = false
        wakeComplete = false
        ssidResult = nil
        passwordResult = nil
        frameBuffer = []
        writeChar = nil
        notifyChar = nil
        peripheral = nil

        return await withCheckedContinuation { (cont: CheckedContinuation<CredentialResult?, Never>) in
            DispatchQueue.main.async {
                self.completion = { result in cont.resume(returning: result) }
                self.log("启动 BLE 流程：扫描→连接→认证→唤醒→获取凭据")
                if let c = self.central, c.state == .poweredOn {
                    self.startScan()
                } else if self.central == nil {
                    // delegate（centralManagerDidUpdateState）会在状态变化时驱动扫描
                    self.log("初始化蓝牙管理器，等待蓝牙就绪…")
                    self.central = CBCentralManager(delegate: self, queue: .main)
                } else if let c = self.central {
                    self.log("蓝牙当前状态：\(self.stateName(c.state))，继续等待…")
                }
                let work = DispatchWorkItem { [weak self] in
                    guard let self, self.inFlight else { return }
                    self.log("⏱ 超时（60s）。阶段: \(self.status)；已认证=\(self.authComplete) 已唤醒=\(self.wakeComplete) ssid=\(self.ssidResult ?? "nil")")
                    self.log("提示：若停在'发现相机'→检查相机蓝牙；若已认证但无凭据应答→命令编址需校准")
                    self.finish(nil)
                }
                self.timeoutWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: work)
            }
        }
    }

    private func finish(_ result: CredentialResult?) {
        DispatchQueue.main.async {
            guard self.inFlight else { return }
            self.inFlight = false
            self.timeoutWorkItem?.cancel()
            let completion = self.completion
            self.completion = nil
            if let r = result {
                self.log("成功：SSID=\(r.ssid) ✓")
            } else {
                self.log("BLE 流程未完成：\(self.status)")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                // keepalive 开启时不断开：WiFi datalink 依赖此 BLE 会话（osmocam §3.3）
                if let self, !self.keepAliveOn, let p = self.peripheral { self.central?.cancelPeripheralConnection(p) }
                completion?(result)
            }
        }
    }

    private func startScan() {
        log("蓝牙就绪，扫描相机…")
        central?.scanForPeripherals(withServices: nil,
                                    options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func send(_ frame: [UInt8], label: String) {
        sendVia(frame, char: writeChar, label: label)
    }

    /// 指定特征发送（FFF3/FFF5 双通道探测用）。
    private func sendVia(_ frame: [UInt8], char: CBCharacteristic?, label: String) {
        guard let char else {
            log("✗ 发送失败（写特征未就绪）：\(label)")
            return
        }
        log("→ 发送\(label) [\(frame.count)B] via \(char.uuid)")
        logFrame("TX-\(label)", Data(frame))
        peripheral?.writeValue(Data(frame), for: char, type: .withResponse)
    }


    // MARK: - DUML 明文帧序（pklg 实证 Mimo BLE 阶段全流程）

    /// DUML 帧编码（BLE 版：无外层封装，55|len|crc8|src|dst|seq|ct|set|id|pl|crc16）
    private func buildDUML(src: UInt8, dst: UInt8, seq: UInt16,
                           ct: UInt8, set: UInt8, id: UInt8, pl: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x55, 0, 0, 0, src, dst,
                              UInt8(seq & 0xFF), UInt8(seq >> 8),
                              ct, set, id]
        bytes.append(contentsOf: pl)
        let total = bytes.count + 2
        bytes[1] = UInt8(total & 0xFF)
        bytes[2] = UInt8((total >> 8) & 0x03) | (1 << 2) // 版本 1
        bytes[3] = crc8DUML(Array(bytes[0..<3]))
        let c = crc16DUML(Array(bytes))
        bytes.append(UInt8(c & 0xFF))
        bytes.append(UInt8(c >> 8))
        return bytes
    }

    private func crc8DUML(_ b: [UInt8]) -> UInt8 {
        var crc: UInt8 = 0x77
        for x in b {
            crc ^= x
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1 }
        }
        return crc
    }

    private func crc16DUML(_ b: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0x3692
        for x in b {
            crc ^= UInt16(x)
            for _ in 0..<8 { crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8408 : crc >> 1 }
        }
        return crc
    }

    /// BLE 连接后直接发 Mimo 实测 DUML 帧序（无 R 认证无 ECDH）：
    /// 握手→TOKEN→(00,32)×2→(02,8e)→(08,79)→get_ssid→get_password
    /// TOKEN 缓存于 UserDefaults("camera.wms_token")，来自上一次成功连接。
    private func startDUMLSequence() {
        let token = UserDefaults.standard.data(forKey: "camera.wms_token")
            ?? Data([0x20, 0x63, 0x33, 0x38, 0x32, 0x66, 0x65, 0x34, 0x34, 0x36, 0x30, 0x35,
                     0x36, 0x61, 0x32, 0x37, 0x66, 0x36, 0x30, 0x66, 0x62, 0x31, 0x30, 0x38,
                     0x39, 0x63, 0x30, 0x38, 0x63, 0x61, 0x64, 0x35, 0x33, 0x04, 0x37, 0x33,
                     0x34, 0x30, 0x01, 0x01])
        // 落盘：WiFi datalink 的 poke（OSMOCameraLink）用同一 token 作已配对身份
        UserDefaults.standard.set(token, forKey: "camera.wms_token")
        // dst 按 pklg 实证逐条不同：握手→F0(网关) TOKEN/凭据→07(WiFi模块)
        // 配置→88(WiFi配置) 订阅/查询→08。dst 错配会被 e0 拒绝且后续凭据查询被无视。
        // osmocam/osmo-client 配对状态机（参考实现逐行比对）：
        // 阶段A = 握手 → 配对(osmo 身份) 后【停】——收到 0002 后相机屏幕弹提示，
        // 此期间发任何其他 07/45 都会顶掉待批准的提示（我们此前 TOKEN 紧跟其后的自伤）。
        // 阶段B（批准/已配对后）= 唤醒 → TOKEN → 配置 → 订阅/查询 → 凭据。
        let identity = Array("284ae5b8d76b3375a04a6417ad71bea3".utf8)
        var pairPl: [UInt8] = [UInt8(identity.count)]
        pairPl.append(contentsOf: identity)
        pairPl.append(4)
        pairPl.append(contentsOf: Array("osmo".utf8))
        pairPayload = Data(pairPl)
        self.token = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            var seq: UInt16 = 0x31D3
            // 阶段A：仅两帧
            for (dst, set, id, pl, name) in [
                (UInt8(0xF0), UInt8(0x00), UInt8(0x2b), [0x04, 0x00], "握手"),
                (UInt8(0x07), UInt8(0x07), UInt8(0x45), pairPl, "配对(osmo)"),
            ] {
                let frame = self.buildDUML(src: 0x02, dst: dst, seq: seq,
                                           ct: 0x40, set: set, id: id, pl: pl)
                self.send(frame, label: "DUML-\(name)(40,\(String(set, radix: 16)),\(String(id, radix: 16))) [\(frame.count)B] via FFF5")
                seq &+= 1
            }
            // 参考实现 _wait_for_pairing：完全无应答才在 2.5s/5s 重发；有状态(0002)则静默等批准
            self.pairingResendWork?.cancel()
            for delay in [2.5, 5.0] {
                let w = DispatchWorkItem { [weak self] in
                    guard let self, !self.pairingDone, !self.pairStatusReceived else { return }
                    let f = self.buildDUML(src: 0x02, dst: 0x07, seq: 0x8092,
                                           ct: 0x40, set: 0x07, id: 0x45, pl: pairPl)
                    self.send(f, label: "DUML-配对重发(40,7,45)")
                }
                self.pairingResendWork = w
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            }
            // 配对门总闸：90s（参考实现 approve_timeout 默认值）
            let gate = DispatchWorkItem { [weak self] in
                guard let self, !self.pairingDone else { return }
                self.log("✗ 配对未在 90s 内完成（相机屏幕提示 20s/次，确认后自动继续）")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 90, execute: gate)
            self.log("配对门：等待相机应答（0001=已配对 / 0002=请在相机屏幕按确认，20s 内）")
        }
    }

    /// 阶段B：配对完成后才允许发（osmo-client：批准 → wake → keepalive → 凭据查询）
    private var pairingDone = false
    private var pairStatusReceived = false
    private var pairingResendWork: DispatchWorkItem?
    private var postPairingSent = false
    private var pairPayload: Data?
    private var token: Data = Data()

    private func runPostPairingSequence() {
        guard !postPairingSent else { return }
        postPairingSent = true
        pairingResendWork?.cancel()
        log("▶ 配对完成，继续 BLE 流程（唤醒→凭据）")
        let queries: [(UInt8, UInt8, UInt8, [UInt8], String)] = [
            (0x1C, 0x53, 0x10, [0x00, 0x00, 0x00, 0x00], "唤醒(53,10)"),
            (0x07, 0x07, 0x45, [UInt8](token), "TOKEN"),
            (0x88, 0x00, 0x32, [0x31, 0x31, 0x00, 0x00, 0x00], "配置(00,32)"),
            (0x88, 0x00, 0x32, [0x31, 0x31, 0x00, 0x00, 0x00], "配置(00,32)#2"),
            (0x08, 0x02, 0x8e, [0x00, 0x01, 0x1c, 0x00], "订阅(02,8e)"),
            (0x08, 0x08, 0x79, [0x00], "查询(08,79)"),
            (0x07, 0x07, 0x07, [0x00], "get_ssid"),
            (0x07, 0x07, 0x0E, [0x00], "get_password"),
        ]
        var seq: UInt16 = 0x31E0
        for (dst, set, id, pl, name) in queries {
            let frame = buildDUML(src: 0x02, dst: dst, seq: seq,
                                  ct: 0x40, set: set, id: id, pl: pl)
            send(frame, label: "DUML-\(name)(40,\(String(set, radix: 16)),\(String(id, radix: 16))) [\(frame.count)B] via FFF5")
            seq &+= 1
        }
        log("DUML 帧序发送完成（\(queries.count) 条），等待 FFF4 应答…")
    }

    /// BLE 电量缓存读取：完整连接（BLE 场景）时 (0d,02) 推送会落 UserDefaults，
    /// 直连场景无 BLE 源，此值可能滞后。返回 nil=从未获取过。
    public static func cachedBatteryPercent() -> Int? {
        UserDefaults.standard.object(forKey: "camera.battery_percent") as? Int
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard inFlight else { return }
        switch central.state {
        case .poweredOn:
            startScan()
        case .poweredOff:
            // 不失败：用户打开蓝牙后本回调会再次触发，流程自动继续
            log("⚠ 手机蓝牙已关闭——请到 控制中心 打开蓝牙，打开后自动继续")
        case .unauthorized:
            log("✗ 蓝牙权限被拒：到 设置-隐私与安全性-蓝牙 允许本 App")
            finish(nil)
        case .unsupported:
            log("✗ 设备不支持 BLE")
            finish(nil)
        default:
            log("蓝牙状态：\(stateName(central.state))，等待…")
        }
    }

    private func stateName(_ state: CBManagerState) -> String {
        switch state {
        case .unknown: return "unknown(0)"
        case .resetting: return "resetting(1)"
        case .unsupported: return "unsupported(2)"
        case .unauthorized: return "unauthorized(3)"
        case .poweredOff: return "poweredOff(4) 关闭"
        case .poweredOn: return "poweredOn(5) 就绪"
        @unknown default: return "raw(\(state.rawValue))"
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // 纯 MAC 扫描路径（ConnectionFlow waking 步骤）：命中即回调，不建链
        if macScanCompletion != nil {
            if let mf = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, mf.count >= 6 {
                central.stopScan()
                let mac = [UInt8](mf.suffix(6))
                // 命中即持久化 MAC（ConnectionFlow 后续可直接用缓存）
                UserDefaults.standard.set(mac.map { String(format: "%02x", $0) }.joined(), forKey: "camera.mac")
                let cb = macScanCompletion
                macScanCompletion = nil
                cb?(mac)
            }
            return
        }
        guard inFlight, self.peripheral == nil else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
        guard Self.namePrefixes.contains(where: { name.hasPrefix($0) }) else { return }
        log("发现相机 \(name)（RSSI \(RSSI)）")
        // 广播 manufacturer data 尾 6 字节 = 相机 MAC（e4:7a:2c:19:76:e7，与 wifi_get_mac 一致）
        for (k, v) in advertisementData {
            if let d = v as? Data {
                let hx = [UInt8](d).map { String(format: "%02x", $0) }.joined()
                log("广播 \(k): \(hx)")
                if k == CBAdvertisementDataManufacturerDataKey, d.count >= 6 {
                    cameraMAC = [UInt8](d.suffix(6))
                    log("相机 MAC=\(cameraMAC!.map { String(format: "%02x", $0) }.joined())")
                }
            } else if k != CBAdvertisementDataOverflowServiceUUIDsKey {
                log("广播 \(k): \(v)")
            }
        }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard inFlight else { return }
        log("BLE 已连接，发现服务…")
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        log("BLE 连接失败：\(error?.localizedDescription ?? "?")")
        finish(nil)
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard inFlight else { return }
        log("BLE 断开")
        if let s = ssidResult {
            finish(CredentialResult(ssid: s, password: passwordResult ?? ""))
        } else {
            finish(nil)
        }
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard inFlight else { return }
        // 全量服务清单：加密通道可能不在 FFF0（native datalink_id/send_id 暗示多链路）
        for s in peripheral.services ?? [] {
            log("服务 \(s.uuid)")
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID })
        else { log("未找到 FFF0 服务"); finish(nil); return }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard inFlight else { return }
        // 全量特征清单（含属性位），校准加密通道用的特征
        for char in service.characteristics ?? [] {
            var names: [String] = []
            if char.properties.contains(.write) { names.append("write") }
            if char.properties.contains(.writeWithoutResponse) { names.append("writeNoRsp") }
            if char.properties.contains(.notify) { names.append("notify") }
            if char.properties.contains(.read) { names.append("read") }
            if char.properties.contains(.indicate) { names.append("indicate") }
            log("特征 \(char.uuid)（\(names.joined(separator: "|"))）")
        }
        for char in service.characteristics ?? [] {
            if char.uuid == Self.notifyCharUUID {
                notifyChar = char
                peripheral.setNotifyValue(true, for: char)
            } else if char.uuid == Self.writeCharUUID {
                writeChar = char
            } else if char.uuid == CBUUID(string: "0000FFF3-0000-1000-8000-00805F9B34FB") {
                // FFF3 也订阅 notify：多链路探测——相机的 0x1292 应答可能走 FFF3
                fff3Char = char
                peripheral.setNotifyValue(true, for: char)
            }
        }
        if notifyChar != nil, writeChar != nil {
            log("特征就绪，发送 DUML 帧序（Mimo 实测流程）…")
            startDUMLSequence()
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard inFlight, let data = characteristic.value else { return }
        // FFF4 与 FFF3 的通知都进同一帧管线（来源标注进日志，区分应答走哪条链路）
        logFrame("RX-通知原始@\(characteristic.uuid)", data)
        frameBuffer.append(contentsOf: [UInt8](data))
        processBuffer()
    }

    // MARK: - DUML 0x55 帧处理

    private func processBuffer() {
        while frameBuffer.count >= 3 {
            let sof = frameBuffer[0]
            guard sof == DjiRProtocol.sof || sof == 0x55 else {
                // 未知帧头：记录前 16 字节便于观察协议形态
                let head = frameBuffer.prefix(16).map { String(format: "%02x", $0) }.joined()
                log("⚠ 未识别帧头 0x\(String(format: "%02x", sof))，数据头: \(head)")
                frameBuffer.removeFirst(); continue
            }
            let frameLen = Int(frameBuffer[1]) | (Int(frameBuffer[2]) & 0x03) << 8
            guard frameBuffer.count >= frameLen else { break }

        if sof == DjiRProtocol.sof,
           let (frame, remaining) = DjiRProtocol.scanFrame(from: frameBuffer) {
            frameBuffer = remaining
            handleRFrame(frame)
        } else if sof == 0x55,
                  let duml = MimoFrame.parse(Data(frameBuffer.prefix(frameLen))) {
            // DUML 帧：WMS 加密通道的可能载体（"APP->WMS"），与 R 帧同通道复用
            frameBuffer.removeFirst(frameLen)
            log("◇ RX DUML 帧: src=0x\(String(duml.sender, radix: 16)) dst=0x\(String(duml.receiver, radix: 16)) cmdType=0x\(String(duml.cmdType, radix: 16)) cmdSet=0x\(String(duml.cmdSet, radix: 16)) cmdId=0x\(String(duml.cmdId, radix: 16)) payload[\(duml.payload.count)B]=\([UInt8](duml.payload).map { String(format: "%02x", $0) }.joined())")
            handleDumlFrame(duml)
        } else {
            // 未知帧：完整记录供协议校准
            let duml = frameBuffer.prefix(frameLen).map { String(format: "%02x", $0) }.joined()
            log("◇ RX 未识别帧 [\(frameLen)B]: \(duml)")
            frameBuffer.removeFirst(max(frameLen, 1))
        }
        }
    }

    /// DUML 帧路由：0x12/0x92 = ECDH 应答；0x07/0x07、0x07/0x0E = 凭据应答；
    /// BLE 裸推送：电量动态 (0d,02)、相机变体/存储 (02,dc)（dji-reversing lib-osmo-ble 遥测表）
    private func handleDumlFrame(_ f: MimoFrame) {
        let p = [UInt8](f.payload)
        if f.cmdSet == 0x12, f.cmdId == 0x92 {
            handleECDHResponse(p)
            return
        }
        // 配对状态机（参考实现 ble.py _pairing_status/_approval）：
        // 07/45 应答 payload[1]: 01=已配对 02=待批准；07/46 payload[0]: 01=已批准（否则拒绝/超时）。
        if f.cmdSet == 0x07, f.cmdId == 0x45, p.count >= 2 {
            pairStatusReceived = true
            switch p[1] {
            case 0x01:
                log("✅ 配对状态: 该身份已配对")
                pairingDone = true
                runPostPairingSequence()
            case 0x02:
                log("⚠️ 配对门：请在相机屏幕上按确认（OSMO 提示，20s 内；错过会再弹）")
                // 静默等待 07/46——此期间不发任何帧（会顶掉提示）
            default:
                log("配对状态: 0x\(String(p[1], radix: 16))")
            }
            if f.cmdType & 0x40 != 0 && f.cmdType & 0x80 == 0 {
                let echo = buildDUML(src: 0x02, dst: f.sender, seq: nextSeq(),
                                     ct: 0xC0, set: 0x07, id: 0x45, pl: p)
                send(echo, label: "配对状态回显(0xC0)")
            }
            return
        }
        if f.cmdSet == 0x07, f.cmdId == 0x46 {
            if p.first == 0x01 {
                log("✅ 相机屏幕已批准配对！→ 继续流程")
                UserDefaults.standard.set(true, forKey: "camera.osmo_paired")
                pairingDone = true
                runPostPairingSequence()
            } else {
                log("❌ 配对未批准（拒绝或 20s 超时）——下一轮配对帧会重新弹提示，请及时按")
                postPairingSent = false
            }
            return
        }
        if f.cmdSet == 0x07, f.cmdId == 0x07 || f.cmdId == 0x0E {
            handleCredentialResponse(cmdId: f.cmdId, p: p)
            return
        }
        // BLE 电量推送 (0x0d,0x02)：~1Hz。布局实测校准（2026-10-28 充电中样本）：
        // 34B 中 @20 u16 LE = 0x0064 = 100（电量百分比，充电满）；@17=0x2c=44 疑为温度℃
        if f.cmdSet == 0x0D, f.cmdId == 0x02 {
            if p.count >= 22 {
                let pct = Int(p[20]) | Int(p[21]) << 8
                if (0...100).contains(pct) {
                    UserDefaults.standard.set(pct, forKey: "camera.battery_percent")
                    log("✓ BLE 电量(0d,02)=\(pct)%（@20 u16 LE）")
                } else {
                    log("◇ BLE 电量推送(0d,02) @20=\(pct) 超域，原始=\(p.map { String(format: "%02x", $0) }.joined())")
                }
            } else {
                log("◇ BLE 电量推送(0d,02) 仅\(p.count)B，原始=\(p.map { String(format: "%02x", $0) }.joined())")
            }
            return
        }
        // (0x02,0xdc) 相机变体推送 ~2Hz 22B：XS 实测 payload 前缀 0012 0100 0001 与 cam_storage 值同构
        if f.cmdSet == 0x02, f.cmdId == 0xDC {
            let hex = p.map { String(format: "%02x", $0) }.joined()
            log("◇ BLE 相机推送(02,dc) [\(p.count)B]=\(hex)")
            return
        }
    }

    private func handleRFrame(_ frame: DjiRProtocol.Frame) {        log("◇ RX 0xAA 帧: cmdSet=0x\(String(frame.cmdSet, radix: 16)) cmdId=0x\(String(frame.cmdId, radix: 16)) isAck=\(frame.isAck) seq=\(frame.sequence) payload[\(frame.payload.count)B]=\([UInt8](frame.payload).map { String(format: "%02x", $0) }.joined())")
        // ECDH 交换应答（0x12,0x92）
        if frame.cmdSet == 0x12, frame.cmdId == 0x92 {
            handleECDHResponse([UInt8](frame.payload))
            return
        }
        // 凭据应答（0x07,0x07 / 0x07,0x0E）
        if frame.cmdSet == 0x07, frame.cmdId == 0x07 || frame.cmdId == 0x0E {
            handleCredentialResponse(cmdId: frame.cmdId, p: [UInt8](frame.payload))
            return
        }
        // 版本号查询应答（0x00,0x00）——连接健康度探针：ret=0+产品信息=连接已闭环
        if frame.cmdSet == 0x00, frame.cmdId == 0x00, frame.isAck {
            let p = [UInt8](frame.payload)
            let ret = p.count >= 2 ? UInt16(p[0]) | UInt16(p[1]) << 8 : 0xFFFF
            let info = p.count > 2 ? String(bytes: p[2...], encoding: .utf8) ?? p[2...].map { String(format: "%02x", $0) }.joined() : "空"
            log("◇ 版本查询应答: ret=\(ret) 信息=\(info) → \(ret == 0 ? "✓ 连接闭环正常" : "✗ 连接未闭环（后续命令都会失败）")")
            return
        }
        // 认证帧（0x00,0x19）——相机存在两种布局（真机实测）：
        // 全量 33B：device_id(4)@0 mac_len(1)@4 mac(16)@5 fw(4)@21 conidx(1)@25 verify_mode(1)@26 verify_data(2)@27
        // 紧凑 13B：device_id(4)@0 … verify_mode(1)@10 verify_data(2)@11
        // XS 实测：相机以 33B 全量帧持续广播（verify_mode=2 在 @26），只认 p[10] 会互等卡死
        if frame.cmdSet == 0x00, frame.cmdId == 0x19, !frame.isAck {
            guard !authComplete else { return } // 相机会重复广播，只应答一次
            let p = [UInt8](frame.payload)
            var verifyMode: UInt8 = 0
            var verifyData: UInt16 = 0
            if p.count >= 33 {
                verifyMode = p[26]
                verifyData = UInt16(p[27]) | UInt16(p[28]) << 8
            } else if p.count >= 13 {
                verifyMode = p[10]
                verifyData = UInt16(p[11]) | UInt16(p[12]) << 8
            } else {
                log("⚠ 认证帧 payload 过短（\(p.count)B），布局未知")
                return
            }
            log("认证应答字段: device_id=0x\(String(UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24, radix: 16)) verifyMode=\(verifyMode) verifyData=\(verifyData) (布局\(p.count)B)")
            guard verifyMode == 2 else {
                log("⚠ verifyMode=\(verifyMode)（预期 2），继续等待")
                return
            }
            cameraDeviceId = UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16 | UInt32(p[3]) << 24
            authComplete = true
            if verifyData == 0 {
                log("✓ 认证通过，回显 seq=\(frame.sequence) 发 ACK；500ms 后发探测+唤醒+ECDH")
                // ACK 必须回显相机请求帧的 seq（官方 connect_logic：received_seq）
                send(DjiRProtocol.buildConnectionAck(requestSequence: frame.sequence,
                                                     cameraDeviceId: cameraDeviceId),
                     label: "认证ACK(0x00,0x19,seq=\(frame.sequence))")
                // 广播唤醒流程（官方文档）：相机休眠时热点关闭，手机反向广播 WKP+MAC反序 2s 唤醒
                if let mac = cameraMAC {
                    let rev = [UInt8](mac.reversed())
                    HotspotWaker.setLogSink { line in
                        DispatchQueue.main.async { self.log(line) }
                    }
                    HotspotWaker.shared.wakeCamera(macReversed: rev) { line in
                        DispatchQueue.main.async { self.log(line) }
                    }
                }
                // 广播 2×2.5s 需 ~6s；连发命令撞状态机（实测 ret=0x01），官方流程天然有间隔
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) { [weak self] in
                    guard let self, self.inFlight else { return }
                    // 连接健康度探针：版本号查询（0x00,0x00），官方定义应答=ret(2B)+产品ID+SDK版本
                    self.send(DjiRProtocol.buildFrame(cmdType: 0x01, cmdSet: 0x00, cmdId: 0x00,
                                                      payload: [], sequence: self.nextSeq()),
                              label: "版本查询(0x00,0x00)")
                    self.send(DjiRProtocol.buildPowerModeCommand(0x00, sequence: self.nextSeq()),
                              label: "唤醒命令(0x00,0x1A)")
                    self.wakeComplete = true
                    self.beginECDHExchange()
                }
            } else {
                log("✗ 相机拒绝连接（verifyData=\(verifyData)）")
                finish(nil)
            }
        }
    }

    /// 阶段 1：发起 ECDH 交换（P-256 公钥 + rand_app）。
    /// payload 布局为推断值，真机校准点：看相机是否回 (0x12,0x92) 应答。
    /// 每轮 BLE 循环换一种变体（连接层已确认健康，盲区只在 payload 字节布局）。
    private var ecdhVariant = 0
    private var cameraMAC: [UInt8]?
    private func beginECDHExchange() {
        guard let (pub, priv) = WiFiCredentialCrypto.generateECDHKeyPair() else {
            log("✗ ECDH 密钥生成失败")
            finish(nil)
            return
        }
        ecdhPrivateKey = priv
        let rand = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        randApp = rand
        // 变体轮换（真机已证伪 0-8：R 帧×payload×通道、DUML dst=01/28 全灭）。
        // pcap 实锤：WiFi 通道上 WiFi 模块节点=0x07，(ct=40,set=07,id=07)=get_ssid 明文应答，
        // set=0x12 即 native 模块 18（加密模块，id=0x0c=get_mac 同命令空间）。
        // 9=DUML 02->07 get_ssid  10=DUML 02->07 get_password  11=DUML 02->07 ECDH
        let variant = abs(ecdhVariant) % 12
        ecdhVariant += 1
        if variant >= 9 {
            let frame: MimoFrame
            switch variant {
            case 9:
                frame = MimoFrame(sender: 0x02, receiver: 0x07, sequence: nextSeq(),
                                  cmdType: 0x40, cmdSet: 0x07, cmdId: 0x07, payload: Data())
            case 10:
                frame = MimoFrame(sender: 0x02, receiver: 0x07, sequence: nextSeq(),
                                  cmdType: 0x40, cmdSet: 0x07, cmdId: 0x0E, payload: Data())
            default:
                frame = MimoFrame(sender: 0x02, receiver: 0x07, sequence: nextSeq(),
                                  cmdType: 0x40, cmdSet: 0x12, cmdId: 0x92,
                                  payload: Data([0x00] + Array(pub) + Array(rand)))
            }
            sendVia([UInt8](frame.encodedData()), char: writeChar,
                    label: "WMS查询v\(variant)(DUML,set=0x\(String(frame.cmdSet, radix: 16)),id=0x\(String(frame.cmdId, radix: 16)))")
            return
        }
        let useFFF3 = variant >= 3
        let payload: [UInt8]
        switch variant % 3 {
        case 0: payload = [0x00] + Array(pub) + Array(rand)
        case 1: payload = Array(pub) + Array(rand)
        default: payload = [0x00] + Array(pub)
        }
        let label = "ECDH交换v\(variant)(0x12,0x92,\(useFFF3 ? "FFF3" : "FFF5"))"
        if useFFF3 {
            sendVia(DjiRProtocol.buildFrame(cmdType: 0x01, cmdSet: 0x12, cmdId: 0x92,
                                            payload: payload, sequence: nextSeq()),
                    char: fff3Char, label: label)
        } else {
            send(BLECredentialExchange.buildECDHExchangeRaw(payload: payload, sequence: nextSeq()),
                 label: label)
        }
    }

    /// 阶段 2：解析 ECDH 应答 → 派生会话密钥 → 发凭据查询。
    private func handleECDHResponse(_ p: [UInt8]) {
        log("◇ ECDH 应答 [\(p.count)B]")
        // 推断布局：[camera_pubkey 65B][rand_dev 16B]（真机校准点）
        guard p.count >= 81 else {
            log("⚠ ECDH 应答长度 \(p.count)B < 81，布局待校准；原始 payload 见上方 hex")
            return
        }
        let camPub = Data(p[0..<65])
        let randDev = Data(p[65..<81])
        guard let priv = ecdhPrivateKey,
              let secret = WiFiCredentialCrypto.computeSharedSecret(peerPublicKey: camPub, privateKey: priv),
              let (key, iv) = BLECredentialExchange.deriveSessionKey(sharedSecret: secret,
                                                                     randDev: randDev, randApp: randApp ?? Data())
        else {
            log("✗ 会话密钥派生失败")
            finish(nil)
            return
        }
        sessionAESKey = key
        sessionIV = iv
        log("✓ 会话密钥就绪，发送凭据查询…")
        send(BLECredentialExchange.buildGetSSID(sequence: nextSeq()), label: "get_ssid(0x02,0x07)")
        send(BLECredentialExchange.buildGetPassword(sequence: nextSeq()), label: "get_password(0x02,0x0E)")
    }

    /// 阶段 3：解密凭据应答。
    /// WiFi 模块应答（BLE 通知，pklg 实证明文）：payload = [ret:1][len:1][明文数据]。
    /// 实测 SSID 应答 pl=00 10 "OsmoAction4-xxxx"(16B)、密码应答 pl=00 0c 12B 明文。无 ECDH、无加密。
    private func handleCredentialResponse(cmdId: UInt8, p: [UInt8]) {
        guard p.count >= 2 else {
            log("⚠ 凭据应答过短（\(p.count)B）")
            return
        }
        let ret = p[0]
        let dataLen = Int(p[1])
        guard ret == 0, 2 + dataLen <= p.count else {
            log("⚠ 凭据应答异常 ret=\(String(ret, radix: 16)) len=\(dataLen) 实际\(p.count)B")
            return
        }
        let text = String(bytes: p[2..<(2 + dataLen)], encoding: .utf8) ?? ""
        if cmdId == 0x07 {
            ssidResult = text.isEmpty ? nil : text
            log("✓ SSID: \(ssidResult ?? "?")")
            // 写 UserDefaults 供流程使用
            UserDefaults.standard.set(ssidResult, forKey: "camera.ssid")
        } else {
            passwordResult = text.isEmpty ? nil : text
            log("✓ PASSWORD: \(passwordResult ?? "?")（\(dataLen)B 明文）")
            if let pwd = passwordResult {
                UserDefaults.standard.set(pwd, forKey: "camera.wifi_password")
            }
        }
        if let s = ssidResult, let pw = passwordResult {
            finish(CredentialResult(ssid: s, password: pw))
        }
    }
}

// MARK: - 轻量 MAC 扫描（ConnectionFlow waking 步骤用）
extension CameraBleWaker {
    /// 扫描相机广播并解析 manufacturer data 尾 6 字节 MAC，超时返回 nil。
    /// 与 connectAndGetCredentials 互斥（共用 central）；连接流程只取 MAC 不建链。
    public func scanOnceForMAC(timeout: TimeInterval, completion: @escaping ([UInt8]?) -> Void) {
        macScanCompletion = completion
        macScanDeadline = Date().addingTimeInterval(timeout)
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        }
        if central?.state == .poweredOn {
            central?.scanForPeripherals(withServices: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.macScanCompletion != nil else { return }
            self.central?.stopScan()
            let cb = self.macScanCompletion
            self.macScanCompletion = nil
            cb?(nil)
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               willRestoreState dict: [String: Any]) {}
}

