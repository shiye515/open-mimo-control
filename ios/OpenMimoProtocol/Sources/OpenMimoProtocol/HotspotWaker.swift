import Foundation
import CoreBluetooth

/// OA4 热点唤醒（官方 Osmo-GPS-Controller Demo 文档 §广播唤醒流程）：
/// 相机休眠时 BLE 仍在广播但热点关闭；手机需反向广播
/// `[len=10][0xFF]['W''K''P' + 相机MAC反序]` 持续 2 秒，相机收到后唤醒并开启热点。
/// iOS 经 CBPeripheralManager 广播 manufacturer data（自动带 2 字节 CID 前缀，
/// 相机侧按 "WKP" 模式扫描——两种偏移各试 2.5s）。
public final class HotspotWaker: NSObject, CBPeripheralManagerDelegate {

    public static let shared = HotspotWaker()

    private var manager: CBPeripheralManager?
    private var mac: [UInt8] = []
    private var round = 0
    private var stopAt: Date?
    public private(set) var status = "空闲"

    public func wakeCamera(macReversed: [UInt8], rounds: Int = 2, log: @escaping (String) -> Void) {
        self.mac = macReversed
        self.round = rounds
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        }
        status = "等待广播权限"
        log("[wake] 等待 CBPeripheralManager 就绪（MAC 反序=\(macReversed.map { String(format: "%02x", $0) }.joined())）")
    }

    /// CBPeripheralManager 对外广播最多 28 字节 manufacturer data——超出会静默失败，
    /// 必须 DidStartAdvertising 回调确认；失败记录 error 供诊断。
    public func peripheralManager(_ peripheral: CBPeripheralManager,
                                  didStartAdvertising error: Error?) {
        if let error {
            logSink?("[wake] ✗ 广播启动失败: \(error.localizedDescription)（payload 长度? 权限?）")
        } else {
            logSink?("[wake] ✓ 广播已启动（当前变体 payload=\(lastPayload.count)B）")
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            logSink?("[wake] ✗ 广播启动失败(新回调): \(error.localizedDescription)")
        } else {
            logSink?("[wake] ✓ 广播已启动(新回调)")
        }
    }

    private var lastPayload: Data = Data()
    private var logSink: ((String) -> Void)?

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn, !mac.isEmpty, round > 0 else {
            if peripheral.state != .poweredOn {
                logSink?("[wake] PeripheralManager state=\(peripheral.state.rawValue)（4=on）")
            }
            return
        }
        round -= 1
        let wkp: [UInt8] = [0x57, 0x4B, 0x50] // "WKP"
        // 变体 A：WKP+MAC反序（9B，相机裸扫模式）
        let payloadA = Data(wkp + mac)
        // 变体 B：2 字节占位 CID + WKP+MAC（iOS 自动加 CID 前缀的补偿实验）
        let payloadB = Data([0x00, 0x00]) + payloadA
        let data = round % 2 == 0 ? payloadA : payloadB
        lastPayload = data
        logSink?("[wake] 发起广播 round=\(round) payload=\([UInt8](data).map { String(format: "%02x", $0) }.joined())")
        manager?.startAdvertising([CBAdvertisementDataManufacturerDataKey: data])
        status = "广播唤醒中（第\(2 - round)轮）"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.manager?.stopAdvertising()
        }
    }

    /// 外部注入日志管道
    public static func setLogSink(_ sink: @escaping (String) -> Void) {
        shared.logSink = sink
    }
}
