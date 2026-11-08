import SwiftUI
import OpenMimoProtocol

// MARK: - 连接页（设计稿 ①—③：应用标识 + 权限行 + 进度卡 + 底部主按钮，三态同布局；
// 步骤日志与手动加入凭据作为折叠兜底保留，满足 specs camera-connection 的日志与手动入网要求）

struct ConnectScreenView: View {
    let onConnected: () -> Void
    @ObservedObject var flow: ConnectionFlow

    @StateObject private var permissions = PermissionStatus()
    @ObservedObject private var stepLogger = StepLogger.shared
    @State private var showLogs = false
    @State private var showManual = false
    @State private var manualSSID = CameraWifiJoiner.DefaultCameraNetwork.ssid
    @State private var manualPassphrase = CameraWifiJoiner.DefaultCameraNetwork.password
    @State private var autoEntered = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    identityHeader
                    permissionCard
                    if showsProgress { progressCard }
                    logDisclosure
                    manualDisclosure
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
            }
            bottomArea
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 12)
        }
        .background(OC.bg.ignoresSafeArea())
        .onAppear {
            // 会话挂接（onAppear 时机：@StateObject 已定型——init 里挂接会丢到临时实例上）
            flow.onSessionCreated = { session in
                AppSessionHolder.shared.session = session
            }
            // 用户手动凭据透传给流程
            flow.rememberCredentials(ssid: manualSSID, password: manualPassphrase)
            permissions.startPolling()
            // 自动化测试钩子（devicectl launch 传参）：--auto-connect 启动 1 秒后自动发起
            // 完整连接流程（等价旧版自动连接能力，便于无人值守回归；正常启动不带该参数）
            if ProcessInfo.processInfo.arguments.contains("--auto-connect") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if !flow.isRunning { flow.start() }
                }
            }
        }
        .onDisappear { permissions.stopPolling() }
        .onChange(of: flow.state) { state in
            if case .success = state {
                permissions.markLocalNetworkGranted()
                // --auto-media 时由 ContentView 直接路由素材页，跳过本页的延迟跳转
                guard !ProcessInfo.processInfo.arguments.contains("--auto-media") else { return }
                // 已连接态短暂可见后自动进入控制页（设计稿③「无需点击」）
                guard !autoEntered else { return }
                autoEntered = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { onConnected() }
            }
        }
    }

    // MARK: 应用标识区

    private var identityHeader: some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 16)
                .fill(LinearGradient(colors: [OC.accent, Color(hex: 0x0040DD)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 56, height: 56)
                .overlay(Image(systemName: "camera.fill").font(.system(size: 24)).foregroundStyle(.white))
                .padding(.bottom, 8)
            Text("OpenMimoControl")
                .font(.headline)
                .foregroundStyle(OC.textPrimary)
            Text("Osmo Action 4 远程控制")
                .font(.footnote)
                .foregroundStyle(OC.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: 权限状态区（本地网络 / 蓝牙 / 定位）

    private var permissionCard: some View {
        VStack(spacing: 0) {
            permissionRow(.localNetwork, icon: "wifi",
                          purpose: "发现并连接相机热点")
            localNetworkHintRow
            Divider().overlay(OC.stroke.opacity(0.6))
            permissionRow(.bluetooth, icon: "antenna.radiowaves.left.and.right",
                          purpose: "配对 / 唤醒 / 获取凭据")
            Divider().overlay(OC.stroke.opacity(0.6))
            permissionRow(.location, icon: "location",
                          purpose: "读取当前 Wi-Fi 名称")
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(OC.card))
    }

    /// 本地网络权限弹窗未出现时的兜底引导（iOS 无查询 API，只能引导去设置）
    @ViewBuilder
    private var localNetworkHintRow: some View {
        if permissions.localNetworkHint && !permissions.granted(.localNetwork) {
            HStack(spacing: 6) {
                Text("未弹出授权框？接入相机热点后重试，或到设置手动开启")
                    .font(.caption2)
                    .foregroundStyle(OC.textTertiary)
                Button("打开设置") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(OC.accent)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
    }

    private func permissionRow(_ kind: PermissionStatus.Kind, icon: String, purpose: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(OC.accent)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.rawValue).font(.subheadline).foregroundStyle(OC.textPrimary)
                Text(purpose).font(.caption2).foregroundStyle(OC.textSecondary)
            }
            Spacer()
            if permissions.granted(kind) {
                Label("已授权", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(OC.okGreen)
            } else if kind == .localNetwork && permissions.localNetworkProbing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini).tint(OC.accent)
                    Text("探测中").font(.caption).foregroundStyle(OC.textSecondary)
                }
            } else {
                Button("申请") { permissions.request(kind) }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(OC.accent))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: 进度卡（连接中 / 成功 / 失败；待连接态不显示）

    private var showsProgress: Bool {
        switch flow.state {
        case .idle: return false
        default: return true
        }
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(progressTitle).font(.footnote.weight(.medium)).foregroundStyle(OC.textPrimary)
                Spacer()
                Text("\(progressPercent)%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(progressPercentColor)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(OC.pill)
                    Capsule().fill(progressBarColor).frame(width: geo.size.width * CGFloat(progressPercent) / 100)
                }
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                progressDetail
            }
            .font(.caption)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(OC.card))
    }

    private var progressTitle: String {
        switch flow.state {
        case .success: return "连接成功"
        case .failed: return "连接失败"
        default: return "正在连接相机"
        }
    }

    private var progressPercent: Int {
        func pct(_ step: ConnectionStep) -> Int {
            switch step {
            case .waking: return 25
            case .joining: return 50
            case .querying: return 75
            case .connecting: return 90
            }
        }
        switch flow.state {
        case .success: return 100
        case .running(let step): return pct(step)
        case .failed(let step, _): return pct(step)
        case .idle: return 0
        }
    }

    private var progressBarColor: Color {
        if case .success = flow.state { return OC.okGreen }
        return OC.accent
    }

    private var progressPercentColor: Color {
        if case .success = flow.state { return OC.okGreen }
        if case .failed = flow.state { return OC.recRed }
        return OC.textSecondary
    }

    @ViewBuilder
    private var progressDetail: some View {
        switch flow.state {
        case .running(let step):
            ProgressView().controlSize(.mini).tint(OC.accent)
            Text("\(step.rawValue)…").foregroundStyle(Color(hex: 0xC7C7CC))
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(OC.okGreen)
            Text("建立会话完成").foregroundStyle(OC.okGreen)
        case .failed(let step, let reason):
            Image(systemName: "xmark.octagon.fill").foregroundStyle(OC.recRed)
            VStack(alignment: .leading, spacing: 2) {
                Text("失败步骤：\(step.rawValue)").foregroundStyle(OC.recRed)
                Text(reason).foregroundStyle(OC.textSecondary)
            }
        case .idle:
            EmptyView()
        }
    }

    // MARK: 步骤日志（specs camera-connection：日志在界面可见且可复制）

    private var logDisclosure: some View {
        Group {
            if !stepLogger.entries.isEmpty {
                DisclosureGroup("步骤日志（\(stepLogger.entries.count)）", isExpanded: $showLogs) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(stepLogger.entries) { e in
                                Text("\(e.time) | \(e.step) | \(e.purpose) | \(e.content)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(OC.textSecondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .overlay(alignment: .topTrailing) {
                        CopyDiagnosticsButton(snapshotProvider: { stepLogger.export() })
                    }
                }
                .font(.footnote.weight(.medium))
                .foregroundStyle(OC.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 14).fill(OC.card))
            }
        }
    }

    // MARK: 手动加入兜底（specs「热点入网」：无 BLE 凭据时回退用户手动输入的凭据）

    private var manualDisclosure: some View {
        DisclosureGroup("手动加入（首次使用）", isExpanded: $showManual) {
            VStack(spacing: 10) {
                TextField("相机热点名（SSID）", text: $manualSSID)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                SecureField("密码（开放热点留空）", text: $manualPassphrase)
                    .textFieldStyle(.roundedBorder)
                Text("填入后点「连接相机」，流程会用此凭据入网并自动查询最新密码")
                    .font(.caption2)
                    .foregroundStyle(OC.textSecondary)
            }
            .padding(.vertical, 6)
            .onChange(of: manualSSID) { flow.rememberCredentials(ssid: $0, password: manualPassphrase) }
            .onChange(of: manualPassphrase) { flow.rememberCredentials(ssid: manualSSID, password: $0) }
        }
        .font(.footnote)
        .foregroundStyle(OC.textSecondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 14).fill(OC.card))
    }

    // MARK: 底部主按钮

    private var bottomArea: some View {
        VStack(spacing: 8) {
            Button {
                connectTapped()
            } label: {
                HStack(spacing: 8) {
                    if flow.isRunning {
                        ProgressView().controlSize(.regular).tint(.white)
                    } else {
                        Image(systemName: "bolt.fill")
                    }
                    Text(bottomTitle)
                }
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(flow.isRunning ? OC.textSecondary : .white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(flow.isRunning
                              ? AnyShapeStyle(OC.pill)
                              : AnyShapeStyle(LinearGradient(colors: [OC.accent, Color(hex: 0x0040DD)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing)))
                )
            }
            .disabled(flow.isRunning)
            .accessibilityLabel(bottomTitle)

            Text(bottomNote)
                .font(.caption2)
                .foregroundStyle(OC.textTertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private var bottomTitle: String {
        if flow.isRunning { return "连接中…" }
        if case .failed = flow.state { return "重试连接" }
        return "连接相机"
    }

    private var bottomNote: String {
        if flow.isRunning { return "进度走完自动进入控制页" }
        if case .failed = flow.state { return "点击重新执行完整连接流程（不自动循环）" }
        return "点击后申请缺失权限并开始连接"
    }

    /// 「连接相机」= 先补申请缺失权限（等待弹窗结果），再开始完整连接流程。
    private func connectTapped() {
        guard !flow.isRunning else { return }
        autoEntered = false
        permissions.requestMissingThen {
            flow.start()
        }
    }
}
