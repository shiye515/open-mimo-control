import SwiftUI
import Combine
import CoreBluetooth
import CoreLocation
import Network
import OpenMimoProtocol

/// 连接页权限行状态。蓝牙/定位读系统真实授权；本地网络 iOS 无公开查询 API，
/// 用派生信号：成功建立过会话即视为已授权（UserDefaults 持久），
/// 否则「申请」触发一次对相机网关的探测以促使系统弹出授权弹窗。
@MainActor
final class PermissionStatus: ObservableObject {
    enum Kind: String, CaseIterable {
        case localNetwork = "本地网络"
        case bluetooth = "蓝牙"
        case location = "定位"
    }

    static let grantedKey = "oc.localNetwork.granted"

    @Published private(set) var bluetoothGranted = false
    @Published private(set) var locationGranted = false
    @Published private(set) var localNetworkGranted: Bool
    @Published private(set) var localNetworkProbing = false
    /// 探测后仍未见授权 → 引导用户去系统设置手动开启
    @Published private(set) var localNetworkHint = false

    private let locationManager = CLLocationManager()
    private var central: CBCentralManager?
    private var probe: NWConnection?
    private var browser: NWBrowser?
    private var pollTimer: Timer?

    init() {
        localNetworkGranted = UserDefaults.standard.bool(forKey: Self.grantedKey)
        refresh()
    }

    func granted(_ kind: Kind) -> Bool {
        switch kind {
        case .localNetwork: return localNetworkGranted
        case .bluetooth: return bluetoothGranted
        case .location: return locationGranted
        }
    }

    func refresh() {
        bluetoothGranted = CBManager.authorization == .allowedAlways
        let s = locationManager.authorizationStatus
        locationGranted = s == .authorizedAlways || s == .authorizedWhenInUse
    }

    /// 界面可见期间轮询刷新（系统授权弹窗关闭后无需回调即可反映）。
    func startPolling() {
        stopPolling()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func request(_ kind: Kind) {
        switch kind {
        case .location:
            locationManager.requestWhenInUseAuthorization()
        case .bluetooth:
            // 首次创建 CBCentralManager 会在未决定状态触发系统蓝牙权限弹窗
            if central == nil { central = CBCentralManager(delegate: nil, queue: .main) }
        case .localNetwork:
            probeLocalNetwork()
        }
        refresh()
    }

    /// 「连接相机」语义：先补申请缺失权限（等待系统弹窗结果，超时放行），再开始连接。
    func requestMissingThen(timeout: TimeInterval = 6, _ body: @escaping () -> Void) {
        if !bluetoothGranted { request(.bluetooth) }
        if !locationGranted { request(.location) }
        if !localNetworkGranted { probeLocalNetwork() } // 非阻塞：无法查询结果
        waitGranted(.bluetooth, deadline: Date().addingTimeInterval(timeout)) { [weak self] in
            self?.waitGranted(.location, deadline: Date().addingTimeInterval(timeout)) {
                body()
            }
        }
    }

    /// 轮询等待某权限授权或超时（授权弹窗关闭后系统状态即更新，无需回调）。
    private func waitGranted(_ kind: Kind, deadline: Date, next: @escaping () -> Void) {
        refresh()
        if granted(kind) || Date() >= deadline {
            next()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.waitGranted(kind, deadline: deadline, next: next)
            }
        }
    }

    /// 触发本地网络权限：Bonjour 浏览（系统推荐的可靠触发方式）+ UDP 探测相机网关双管齐下。
    /// 注意：未接入任何本地 Wi-Fi 时系统可能不弹授权框——3s 后给出「打开设置」兜底引导。
    private func probeLocalNetwork() {
        guard !localNetworkProbing else { return }
        localNetworkProbing = true
        let browser = NWBrowser(for: .bonjour(type: "_ipp._tcp", domain: nil), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !results.isEmpty else { return }
            Task { @MainActor in
                self.markLocalNetworkGranted()
                self.stopProbe()
            }
        }
        browser.start(queue: .global(qos: .utility))
        self.browser = browser
        let conn = NWConnection(host: "192.168.2.1", port: 7001, using: .udp)
        probe = conn
        conn.start(queue: .global(qos: .utility))
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            self.stopProbe()
            if !self.localNetworkGranted { self.localNetworkHint = true }
        }
    }

    private func stopProbe() {
        localNetworkProbing = false
        browser?.cancel()
        browser = nil
        probe?.cancel()
        probe = nil
    }

    /// 连接成功后调用：本地网络实际可用。
    func markLocalNetworkGranted() {
        UserDefaults.standard.set(true, forKey: Self.grantedKey)
        localNetworkGranted = true
        localNetworkHint = false
    }
}

/// 诊断面板右上角的悬浮复制按钮：复制内容与面板所见完全一致。
struct CopyDiagnosticsButton: View {
    let snapshotProvider: () -> String
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = snapshotProvider()
            copied = true
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(OC.accent)
                .padding(6)
                .background(Circle().fill(OC.pill))
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("复制诊断信息")
    }
}

/// 预览左上角 REC 角标：红点闪烁 + 每秒递增的录制时长。
struct RecBadge: View {
    let seconds: Int64
    @State private var blinkOn = true

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(OC.recRed)
                .frame(width: 7, height: 7)
                .opacity(blinkOn ? 1 : 0.25)
            Text(String(format: "REC %02d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.65)))
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                blinkOn = false
            }
        }
    }
}

// MARK: - 取景网格叠加（官方 Mimo 同款：App 端预览显示，不向相机发送任何命令）

/// 三分网格 + 可选对角线；mode: 1=网格线 2=网格线和对角线
struct FramingGridOverlay: View {
    let mode: Int

    var body: some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height
            Path { p in
                for i in 1...2 {
                    p.move(to: CGPoint(x: w * CGFloat(i) / 3, y: 0))
                    p.addLine(to: CGPoint(x: w * CGFloat(i) / 3, y: h))
                    p.move(to: CGPoint(x: 0, y: h * CGFloat(i) / 3))
                    p.addLine(to: CGPoint(x: w, y: h * CGFloat(i) / 3))
                }
                if mode >= 2 {
                    p.move(to: CGPoint(x: 0, y: 0))
                    p.addLine(to: CGPoint(x: w, y: h))
                    p.move(to: CGPoint(x: w, y: 0))
                    p.addLine(to: CGPoint(x: 0, y: h))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 轻提示（顶部浮出、3s 自动消失，可点击立即关闭）

struct OCToastView: View {
    let text: String
    var isError: Bool = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "info.circle.fill")
            Text(text)
                .font(.footnote.weight(.medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(isError ? OC.recRed.opacity(0.92) : Color.black.opacity(0.82)))
        .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        .padding(.horizontal, 20)
    }
}

/// `.ocToast($message)`：message 非空时顶部浮出轻提示，3 秒自动消失，点击立即关闭
struct OCToastModifier: ViewModifier {
    @Binding var message: String?
    var isError: Bool = true
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    OCToastView(text: message, isError: isError)
                        .onTapGesture { dismiss() }
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 6)
                }
            }
            .animation(.easeOut(duration: 0.25), value: message)
            .onChange(of: message) { _ in schedule() }
            .onAppear { schedule() }
    }

    private func schedule() {
        dismissTask?.cancel()
        guard message != nil else { return }
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { message = nil }
        }
    }

    private func dismiss() {
        dismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { message = nil }
    }
}

extension View {
    func ocToast(_ message: Binding<String?>, isError: Bool = true) -> some View {
        modifier(OCToastModifier(message: message, isError: isError))
    }
}
