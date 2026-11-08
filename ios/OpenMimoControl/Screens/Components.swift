import SwiftUI
import Combine
import CoreBluetooth
import CoreLocation
import Network

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

// MARK: - 变焦轮盘（0.1x 刻度带随值滑动、整数焦段磁吸 + 触觉反馈）

struct ZoomWheelView: View {
    let range: ClosedRange<Double>          // 拍照 1.0...4.0 / 视频 1.0...2.0
    let snapPoints: [Double]                // 整数焦段（磁吸 + 高亮）
    @Binding var value: Double
    /// 每跨过一个 0.1x 刻度回调（外部节流发送绝对位置命令）
    var onTickChange: (Double) -> Void = { _ in }
    /// 松手磁吸完成后回调（发送最终位置）
    var onCommit: (Double) -> Void = { _ in }

    @State private var lastZoomFactor: Double = 1.0
    private let lightImpact = UIImpactFeedbackGenerator(style: .light)
    private let rigidImpact = UIImpactFeedbackGenerator(style: .rigid)

    private var tickCount: Int {
        Int((range.upperBound - range.lowerBound) / 0.1)
    }

    var body: some View {
        VStack(spacing: 16) {
            Text(String(format: "%.1fx", value))
                .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(OC.accent)
            GeometryReader { geometry in
                let center = geometry.size.width / 2
                ZStack(alignment: .top) {
                    // 生效对齐点（轮盘外部的固定指示，刻度滑到正下方即生效）
                    VStack(spacing: 2) {
                        Rectangle()
                            .fill(OC.accent)
                            .frame(width: 2, height: 8)
                        Circle()
                            .fill(OC.accent)
                            .frame(width: 5, height: 5)
                    }
                    .position(x: center, y: 12)
                    // 0.1x 细刻度；0.5x 主刻度标数字；整数焦段加粗高亮（无背景、无边缘衰减）
                    ForEach(0...tickCount, id: \.self) { index in
                        let tickValue = range.lowerBound + Double(index) * 0.1
                        let isSnapPoint = snapPoints.contains(tickValue)
                        let isMajor = Int(tickValue * 10) % 5 == 0
                        let xOffset = (tickValue - value) * 150 + center
                        VStack(spacing: 4) {
                            Rectangle()
                                .fill(isSnapPoint ? OC.accent : (isMajor ? OC.textSecondary : Color.gray))
                                .frame(width: isSnapPoint ? 3 : 1.5,
                                       height: isSnapPoint ? 26 : (isMajor ? 16 : 9))
                            if isMajor {
                                Text(String(format: "%g", tickValue))
                                    .font(.system(size: 9, weight: isSnapPoint ? .semibold : .regular).monospacedDigit())
                                    .foregroundStyle(isSnapPoint ? OC.accent : OC.textSecondary)
                                    .fixedSize()
                            } else {
                                Color.clear.frame(height: 12)
                            }
                        }
                        .position(x: xOffset, y: 48)
                    }
                }
                .clipped()
            }
            .frame(height: 90)
            .background(RoundedRectangle(cornerRadius: 12).fill(OC.pill.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(OC.stroke, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
            .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let delta = -value.translation.width * 0.005
                            let newFactor = min(max(lastZoomFactor + delta, range.lowerBound), range.upperBound)
                            let oldTick = Int(self.value * 10)
                            let newTick = Int(newFactor * 10)
                            if oldTick != newTick {
                                let rounded = Double(newTick) / 10.0
                                if snapPoints.contains(rounded) {
                                    rigidImpact.impactOccurred(intensity: 0.9)
                                } else {
                                    lightImpact.impactOccurred(intensity: 0.3)
                                }
                            }
                            self.value = newFactor
                            if oldTick != newTick { onTickChange(newFactor) }
                        }
                        .onEnded { _ in
                            let closest = snapPoints.min {
                                abs($0 - self.value) < abs($1 - self.value)
                            } ?? self.value
                            if abs(closest - self.value) < 0.25 {
                                withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                    self.value = closest
                                }
                                rigidImpact.impactOccurred(intensity: 1.0)
                            }
                            lastZoomFactor = self.value
                            onCommit(self.value)
                        }
                )
        }
        .onAppear { lastZoomFactor = value }   // 首拖以弹出时的实际倍率为基准（不强制回 1.0）
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
