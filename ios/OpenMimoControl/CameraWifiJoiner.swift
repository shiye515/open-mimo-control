import Foundation
import Combine
import CoreLocation
import NetworkExtension
import os

/// 相机 Wi-Fi 自动发现与入网（tasks 4.3，自动扫描式流程）。
///
/// iOS 不向第三方 App 开放周边热点枚举，自动化的等效路径为（docs/protocol/discovery.md）：
/// 1. 当前网络已是相机热点（wifi-info entitlement 读取 SSID）→ 直接可用；
/// 2. 本 App 曾配置过的相机热点（NEHotspotConfigurationManager.getConfiguredSSIDs）→ 自动重连；
/// 3. 以上皆无 → 轮询等待系统自动加入（相机开机后 iOS 会自动回连已知网络），同时保留一次性手动兜底。
///
/// 运行时诊断：所有关键步骤的结果都记录到 `diagnosticLog`（界面可见 + os_log），便于真机排查。
@MainActor
final class CameraWifiJoiner: ObservableObject {
    enum AutoResult: Equatable {
        case joined(String)
        case waitingSystemJoin
    }

    enum JoinOutcome: Equatable {
        case joined(String)
        case manualFallback(String)
    }

    /// 相机热点 SSID 前缀（Osmo 系列出厂命名；真机实测后在此补全，记忆过的 SSID 恒定命中）
    static let cameraSSIDPrefixes = ["OSMO", "Osmo", "osmo", "DJ"]

    /// 默认相机热点（开源仓库不预置真实凭据。需要「免输入直连」时，在下方填入
    /// 自己的热点 SSID/密码，或首次运行后在手动连接页输入并记忆，存 UserDefaults/Keychain）
    enum DefaultCameraNetwork {
        static let ssid = ""
        static let password = ""
    }

    /// 首次运行时把默认相机热点写入记忆（此后 scanLoop 的记忆重连即全自动）。
    /// 默认 SSID 为空时跳过（开源默认），凭据由用户在手动连接页输入并记忆。
    func seedDefaultIfNeeded() {
        guard !DefaultCameraNetwork.ssid.isEmpty,
              UserDefaults.standard.string(forKey: "camera.ssid") == nil else { return }
        remember(ssid: DefaultCameraNetwork.ssid, passphrase: DefaultCameraNetwork.password)
        log("已写入默认相机热点配置：\(DefaultCameraNetwork.ssid)")
    }

    @Published var lastOutcome: JoinOutcome?
    @Published var discoveredSSID: String?

    private let logger = Logger(subsystem: "win.service-ai.OpenMimoControl", category: "wifi")
    private let locationGate = LocationGate()

    /// 当前定位授权描述（诊断面板显示用；scanOnce/request 时刷新）
    @Published var locationStatus: String = "未检测"

    /// 静态摘要（无状态 UI 用）
    static var locationSummary: String {
        "见步骤日志与系统定位授权"
    }

    func refreshLocationStatus() {
        locationStatus = locationGate.authorizationSummary()
    }

    /// 扫描前调用：未决定时请求 WhenInUse 定位授权；返回 false = 已拒绝（不阻塞流程，仅提示）。
    func requestLocationIfNeeded() async -> Bool {
        let granted = await locationGate.ensure()
        locationStatus = locationGate.authorizationSummary()
        return granted
    }

    /// 一次性自检（每次启动至多一次）：apply 一个不存在的开放网络。
    /// code=8 根因隔离——假 SSID 也 code=8 → 系统性（entitlement/iOS 版本）；
    /// 假 SSID OK、相机 SSID code=8 → 该 SSID 特有（历史配置/系统已知网络冲突）。
    private var selfTestDone = false
    func applySelfTestIfNeeded() async {
        guard !selfTestDone else { return }
        selfTestDone = true
        let probe = "OpenMimo-SelfTest-9F3A"
        let config = NEHotspotConfiguration(ssid: probe)
        config.joinOnce = true
        do {
            try await NEHotspotConfigurationManager.shared.apply(config)
            log("自检: 假SSID apply=OK → apply 通道本身健康，相机SSID的 code=8 是该SSID特有")
            NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: probe)
        } catch {
            log("自检: 假SSID apply=ERR code=\((error as NSError).code) → 任意 apply 都失败（系统性问题）")
        }
    }

    /// 诊断统一写入 AppDiagnostics（连接页/控制页显示同一份，复制即所见）
    private func log(_ line: String) {
        logger.notice("\(line, privacy: .public)")
        AppDiagnostics.shared.add("[wifi] \(line)")
    }

    // MARK: - 扫描（对应 Flutter 项目 device_scan_view 的"扫描→记忆命中→自动连一次"模式）

    struct ScanHit: Equatable {
        enum Source: Equatable { case current, configured }
        let ssid: String
        let source: Source
        let hasStoredPassword: Bool
    }

    /// 单轮扫描：检测当前网络 + 本 App 历史配置的相机热点。
    func scanOnce() async -> [ScanHit] {
        let current = await currentSSID()
        let auth = locationGate.authorizationSummary()
        if auth != lastLoggedAuth {
            lastLoggedAuth = auth
            locationStatus = auth
            log("定位: \(auth)")
        }
        log("scan: fetchCurrent = \(current ?? "nil（定位权限/entitlement 受限？）")")
        var hits: [ScanHit] = []
        if let current {
            hits.append(ScanHit(ssid: current, source: .current,
                                hasStoredPassword: KeychainStore.read(ssid: current) != nil))
        }
        let configured = await configuredSSIDs()
        log("scan: configuredSSIDs = [\(configured.joined(separator: ", "))]")
        for ssid in configured where ssid != (hits.first?.ssid) {
            hits.append(ScanHit(ssid: ssid, source: .configured,
                                hasStoredPassword: KeychainStore.read(ssid: ssid) != nil))
        }
        return hits
    }

    func isCameraSSID(_ ssid: String) -> Bool {
        Self.cameraSSIDPrefixes.contains { ssid.hasPrefix($0) }
    }

    // MARK: - 自动连接

    /// 同一 SSID 的重连尝试限频（相机未开机时避免每轮弹配置）。
    private var lastAttempt: (ssid: String, at: Date)?
    private var lastLoggedAuth: String?

    func autoConnect(hit: ScanHit) async -> Bool {
        if let last = lastAttempt, last.ssid == hit.ssid,
           Date().timeIntervalSince(last.at) < 15 { return false }
        lastAttempt = (hit.ssid, Date())

        if hit.source == .current { discoveredSSID = hit.ssid; return true }
        log("autoConnect: apply \(hit.ssid)（\(hit.hasStoredPassword ? "有存密" : "开放网")）")
        await apply(hit.ssid, passphrase: KeychainStore.read(ssid: hit.ssid))

        // 快速轮询 12s：接入可能出现又很快被系统切回可上网网络，需及时捕获并建会话
        var lastSeenNetwork: String?
        for _ in 0..<24 {
            if let current = await currentSSID() {
                if current == hit.ssid {
                    discoveredSSID = hit.ssid
                    log("autoConnect: 已接入 \(hit.ssid) ✓")
                    return true
                }
                lastSeenNetwork = current
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        log("autoConnect: 12s 内未接入 \(hit.ssid)（手机始终在 \(lastSeenNetwork ?? "nil")；热点未广播或密码错误）")
        return false
    }

    private var lastOtherNetwork: String?

    // MARK: - 手动兜底（一次性；之后进入自动重连集合）

    func join(ssid: String, passphrase: String?) async -> JoinOutcome {
        await locationGate.ensure()
        if let current = await currentSSID(), current == ssid {
            let outcome = JoinOutcome.joined(ssid)
            lastOutcome = outcome
            return outcome
        }
        let applyError = await apply(ssid, passphrase: passphrase)
        if let current = await currentSSID(), current == ssid {
            let outcome = JoinOutcome.joined(ssid)
            lastOutcome = outcome
            return outcome
        }
        let msg = "已登记「\(ssid)」但尚未接入\(applyError.map { "（\( $0)）" } ?? "")。确认相机已开机；若系统弹窗未出现，请到 设置-WLAN 手动选择。"
        log("join 失败: \(msg)")
        lastOutcome = .manualFallback(msg)
        return lastOutcome!
    }

    // MARK: - 底层

    /// 应用热点配置；返回系统错误描述（无错为 nil）。
    /// 弹窗控制：remove+apply 组合会重复触发系统确认弹窗——仅在上次 code=8（配置冲突）时才 remove。
    @discardableResult
    private func apply(_ ssid: String, passphrase: String?) async -> String? {
        await locationGate.ensure()
        let needRemoveFirst = conflictRecovery[ssid] == true

        var attempt = 0
        while attempt < 2 {
            if needRemoveFirst || attempt == 1 {
                NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: ssid)
            }
            let config: NEHotspotConfiguration
            if let passphrase, !passphrase.isEmpty {
                config = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
            } else {
                config = NEHotspotConfiguration(ssid: ssid)
            }
            config.joinOnce = false // 持久登记，供 getConfiguredSSIDs 自动重连
            do {
                try await NEHotspotConfigurationManager.shared.apply(config)
                conflictRecovery[ssid] = false
                log("apply ssid=\(ssid) result=OK（等待系统接入）")
                return nil
            } catch {
                let code = (error as NSError).code
                log("apply ssid=\(ssid) result=ERR code=\(code) desc=\(error.localizedDescription) attempt=\(attempt + 1)")
                if code == 8 {
                    conflictRecovery[ssid] = true // 下次 apply 前 remove（冲突恢复）
                }
                if attempt == 0 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    attempt += 1
                    continue
                }
                return error.localizedDescription
            }
        }
        return "apply 重试后仍失败"
    }

    /// 各 SSID 的冲突恢复标记（上次 apply 是否 code=8）
    private var conflictRecovery: [String: Bool] = [:]

    /// 读取当前 SSID；wifi-info entitlement 受限时返回 nil（自动流程退化为等待系统加入）。
    func currentSSID() async -> String? {
        await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { network in
                cont.resume(returning: network?.ssid)
            }
        }
    }

    /// 本 App 历史配置过的 SSID。
    func configuredSSIDs() async -> [String] {
        await withCheckedContinuation { cont in
            NEHotspotConfigurationManager().getConfiguredSSIDs { ssids in
                cont.resume(returning: ssids)
            }
        }
    }

    func remember(ssid: String, passphrase: String?) {
        UserDefaults.standard.set(ssid, forKey: "camera.ssid")
        KeychainStore.set(passphrase, ssid: ssid)
    }
}

/// SSID 读取在部分 iOS 版本受定位权限门控；首次使用前请求 WhenInUse。
/// 注意：全局"定位服务"总开关关闭时，requestWhenInUseAuthorization 不弹窗直接拒绝——
/// 因此状态会显式打进诊断，UI 提供"去设置"快捷入口。
@MainActor
private final class LocationGate: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Bool, Never>?

    func ensure() async -> Bool {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { cont in
                continuation = cont
                manager.delegate = self
                manager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    /// 诊断用授权摘要（含定位服务总开关状态）。
    nonisolated func authorizationSummary() -> String {
        let status: String
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: status = "未决定"
        case .denied: status = "已拒绝"
        case .restricted: status = "受限制"
        case .authorizedWhenInUse: status = "使用期间允许"
        case .authorizedAlways: status = "始终允许"
        @unknown default: status = "未知"
        }
        let servicesOn = CLLocationManager.locationServicesEnabled()
        return "授权=\(status)，定位服务=\(servicesOn ? "开" : "关")"
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard let continuation else { return }
            self.continuation = nil
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: continuation.resume(returning: true)
            default: continuation.resume(returning: false)
            }
        }
    }
}

/// 密码存 Keychain（不入 UserDefaults）。
enum KeychainStore {
    private static let service = "win.service-ai.OpenMimoControl.wifi"

    static func set(_ value: String?, ssid: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
        ]
        SecItemDelete(query as CFDictionary)
        guard let value else { return }
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func read(ssid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: ssid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
