import SwiftUI
import OpenMimoProtocol
import AudioToolbox

// MARK: - 控制主界面（设计稿 ④—⑧：顶部两行状态 + 固定预览卡 + 参数平铺面板 + 底部三键操作栏；
// 相机状态详情/断开收进顶部状态区弹窗，模式选择为底部弹窗。命令层复用 ConnectionFlow/OSMOA4 不变）

struct ControlScreenView: View {
    let onDisconnect: () -> Void
    let onMedia: () -> Void
    @ObservedObject var flow: ConnectionFlow

    @ObservedObject private var diagnostics = AppDiagnostics.shared
    @ObservedObject private var stepLogger = StepLogger.shared
    @State private var showDetail = false
    @State private var showModeSheet = false
    /// 数码变焦（02/B8 方向+时间：捏合按住连续变焦，松手停止；轮盘/双击发绝对位置）
    @State private var zoomLevel: Double = 1.0
    @State private var zoomBase: Double = 1.0
    @State private var showZoomSlider = false
    @State private var lastMoveAt: Date = .distantPast
    @State private var lastZoomSentAt: Date = .distantPast
    @State private var toast: String?
    /// 取景网格模式（App 端叠加，本地记忆）：0 关闭 / 1 网格线 / 2 网格线和对角线
    @AppStorage("preview.grid") private var gridMode = 0
    /// Pro 模式本地即时覆盖（SET 成功后先行展开；回读 pid 0x0000 到达后以快照为准）
    @State private var proOverride: Bool?
    /// Pro 生效状态：优先本地覆盖，否则相机回读（pid 0x0000）
    private var proOn: Bool { proOverride ?? (st.proOnCode == 1) }
    /// 图像调节模式（本地记忆门控锐度/降噪）：0 默认 / 1 人像 / 2 自定义
    @AppStorage("image.tune") private var imageTune = 0
    static let imageTuneModes = ["默认", "人像", "自定义"]
    /// 拍照倒计时（本地记忆；0 关闭，1-6 对应 0.5/1/2/3/5/10s。02/4A 已实锤）
    @AppStorage("photo.countdown") private var photoCountdown = 0
    static let countdownModes = ["关闭", "0.5s", "1s", "2s", "3s", "5s", "10s"]
    static let countdownMillis: [UInt32] = [0, 500, 1000, 2000, 3000, 5000, 10000]
    /// 弱光增稳本地即时覆盖（SET 成功后先行显示；回读 pid 0x0030 到达后以快照为准）
    @State private var lowLightOverride: Bool?
    /// 系统滚轮逐档反馈：选择震动 + 系统 tick 音效
    private func selectionFeedback() {
        UISelectionFeedbackGenerator().selectionChanged()
        AudioServicesPlaySystemSound(1104)
    }

    /// EV 滚动中的本地草稿（显示优先于回读；关闭滚轮后交还回读）
    @State private var evDraft: UInt8?
    @State private var lastEVSentAt: Date = .distantPast
    /// EV 滚轮弹窗（长按 EV 控制项触发）
    @State private var showEVDial = false

    /// Picker 选中项绑定：滚动跨档即震动 + 音效 + 节流下发
    private var evPickerBinding: Binding<UInt8> {
        Binding(get: { evDraft ?? st.expoCompValue ?? 16 },
                set: { new in
                    guard new != evDraft else { return }
                    evDraft = new
                    selectionFeedback()
                    throttledEV(new)
                })
    }

    /// 变焦滚轮草稿（0.1x 步进码 ×10；显示优先于回读，关闭后交还回读）
    @State private var zoomDraft: UInt16?
    @State private var lastZoomDialSentAt: Date = .distantPast

    private var zoomPickerBinding: Binding<UInt16> {
        Binding(get: { zoomDraft ?? UInt16((displayZoom * 10).rounded()) },
                set: { new in
                    guard new != zoomDraft else { return }
                    zoomDraft = new
                    selectionFeedback()
                    throttledZoomDial(new)
                })
    }

    /// 当前量程下的滚轮档位（0.1x 步进码：拍照 10…40 / 视频 10…20）
    private var zoomDialCodes: [UInt16] {
        guard let range = zoomRange else { return [] }
        return Array(UInt16((range.lowerBound * 10).rounded())...UInt16((range.upperBound * 10).rounded()))
    }

    /// 通用滚轮弹窗上下文（选项 ≥5 的控制项点击弹出）
    @State private var wheelSheetCtx: WheelSheetContext?

    /// 长档位控制项：选项 ≥6 时点击弹出滚轮弹窗，其余保持 Menu 交互不变；
    /// live=false 的格式类滚轮仅在关闭时下发（命令会重启编码器）
    @ViewBuilder
    private func pillWheelRow(_ title: String, current: String?, options: [String],
                              initialIndex: Int? = nil,
                              disabled: Bool = false,
                              live: Bool = true, rowWidth: CGFloat = 60,
                              onPick: @escaping (Int) -> Void,
                              onClose: (() -> Void)? = nil) -> some View {
        if options.count < 6 {
            pillRow(title, current: current, options: options, disabled: disabled) { i in
                onPick(i)
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        } else {
            let idx = initialIndex ?? (options.firstIndex(of: current ?? "") ?? 0)
            HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13))
                .foregroundStyle(OC.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Text(current ?? "—")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(disabled ? OC.textTertiary : OC.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(OC.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .onTapGesture {
            guard !disabled else { return }   // 禁用态点击无反应（.disabled 不拦截后挂手势）
            wheelSheetCtx = WheelSheetContext(title: title, options: options,
                                              initialIndex: idx, live: live, rowWidth: rowWidth,
                                              onPick: onPick, onClose: onClose)
        }
        }
    }

    /// 滚轮跨档节流下发（150ms，与捏合变焦同节奏）
    private func throttledZoomDial(_ code: UInt16) {
        guard Date().timeIntervalSince(lastZoomDialSentAt) > 0.15 else { return }
        lastZoomDialSentAt = Date()
        Task { await flow.setZoomPosition(Double(code) / 10) }
    }

    /// 收起变焦滚轮：当前档直发 + 回读校准 + 清草稿
    private func zoomClose() {
        let final = zoomDraft ?? UInt16((displayZoom * 10).rounded())
        Task {
            await flow.setZoomPosition(Double(final) / 10)
            await MainActor.run {
                zoomDraft = nil
                flow.refreshOSMOQueries()
            }
        }
    }

    /// EV 拖动跨档节流下发（200ms）
    private func throttledEV(_ code: UInt8) {
        guard Date().timeIntervalSince(lastEVSentAt) > 0.2 else { return }
        lastEVSentAt = Date()
        Task { await flow.osmoCommand("EV") { try await $0.setEV(code) } }
    }

    /// 松手最终档直发（防节流窗口吞尾档）+ 清草稿交给回读校准
    private func evCommit(_ code: UInt8) {
        Task {
            let ok = await flow.osmoCommand("EV") { try await $0.setEV(code) }
            if ok != nil {
                await MainActor.run {
                    evDraft = nil
                    flow.refreshOSMOQueries()
                }
            }
        }
    }

    /// 收起 EV 滚轮：当前档直发 + 回读校准 + 清草稿
    private func evClose() {
        let final = evDraft ?? st.expoCompValue ?? 16
        Task {
            let ok = await flow.osmoCommand("EV") { try await $0.setEV(final) }
            if ok != nil {
                await MainActor.run {
                    evDraft = nil
                    flow.refreshOSMOQueries()
                }
            }
        }
    }

    /// EV 滚轮弹窗（底部弹出，系统 wheel 选择器 + 逐档震动/音效；下滑关闭）
    private var evDialSheet: some View {
        VStack(spacing: 8) {
            Text("EV")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(OC.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("EV", selection: evPickerBinding) {
                ForEach(OSMOA4.evSteps, id: \.self) { code in
                    Text(OSMOA4.evName(code))
                        .font(.system(size: 16, weight: .medium).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)   // 滚轮行宽统一 60
                        .tag(code)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 170)
            .padding(.horizontal, -8)   // wheel 自带左右内边距，向外借齐弹窗边
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
    }

    /// EV 控制项：点击弹出底部滚轮弹窗（19 档超出系统 Menu 可选范围）
    @ViewBuilder
    private var evPill: some View {
        HStack(spacing: 6) {
            Text("EV")
                .font(.system(size: 13))
                .foregroundStyle(OC.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            HStack(spacing: 3) {
                Text((evDraft ?? st.expoCompValue).map { OSMOA4.evName($0) } ?? "—")
                    .font(.system(size: 13, weight: .medium).monospacedDigit())
                    .foregroundStyle(OC.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
                    .foregroundStyle(OC.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { showEVDial = true }
    }
    @State private var liveNotice: String?
    @State private var recBlinkInited = false

    private var st: OSMOStatusSnapshot { flow.osmoStatus }

    /// 变焦量程：仅拍照（1.0x–4.0x）与视频（1.0x–2.0x）模式支持；其他模式不支持变焦（nil）
    private var zoomRange: ClosedRange<Double>? {
        switch st.captureMode {
        case OSMOA4.modeVideo: return 1.0...2.0
        case OSMOA4.modePhoto: return 1.0...4.0
        default: return nil
        }
    }

    /// 整数焦段档位（拍照 1/2/3/4；视频 1/2）
    private var zoomStops: [Double] {
        guard let range = zoomRange else { return [] }
        return stride(from: range.lowerBound, through: range.upperBound, by: 1.0).map { $0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            topStatus
            previewCard
            paramsPanel
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OC.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { bottomBar }
        .sheet(item: $wheelSheetCtx) { ctx in WheelSheetView(ctx: ctx) }
        .sheet(isPresented: $showEVDial, onDismiss: { evClose() }) { evDialSheet }
        .ocToast($toast)
        .sheet(isPresented: $showDetail) { detailSheet }
        .sheet(isPresented: $showModeSheet) { modeSheet }
        .sheet(isPresented: $showZoomSlider, onDismiss: { zoomClose() }) { zoomSliderSheet }
        .onChange(of: flow.osmoStatus.captureMode) { _ in
            // 模式切换后变焦量程变化（视频 1x–2x），钳制当前值
            if let range = zoomRange, zoomLevel > range.upperBound { zoomLevel = range.upperBound }
        }
        .onChange(of: flow.osmoError) { err in
            // 命令失败反馈改为轻提示：3s 自动消失（同一文本重复出错时先清再置，确保重触发）
            guard let err, !err.isEmpty else { return }
            toast = nil
            DispatchQueue.main.async { toast = err }
        }
    }

    // MARK: 顶部状态两行（第一行 电量·温度 / SD；第二行 分辨率帧率 / FOV / 曝光概要；
    // 不展示录制时长与录制模式 —— 录制时长在预览左上角 REC 角标）。点击展开相机状态详情。

    private var topStatus: some View {
        Button { showDetail = true } label: {
            VStack(spacing: 5) {
                HStack(spacing: 10) {
                    Spacer()
                    Text(batteryText)
                    Text(sdText)
                }
                HStack(spacing: 0) {
                    Text(resFpsText)
                    Spacer()
                    Text(fovText)
                    Spacer()
                    Text(exposureText)
                }
            }
            .font(.system(size: 10.5).monospacedDigit())
            .foregroundStyle(OC.textSecondary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("相机状态详情")
    }

    private var batteryText: String {
        var parts: [String] = []
        if let p = st.batteryPercent { parts.append("电量 \(p)%") }
        if let t = st.batteryTempDeciC { parts.append(String(format: "%.1f°C", Double(t) / 10)) }
        return parts.joined(separator: " · ")
    }

    private var sdText: String {
        if let free = st.freeStorageMB, let total = st.totalStorageMB {
            return String(format: "SD %.1f/%.0fGB", Double(free) / 1024, Double(total) / 1024)
        }
        return "SD —"
    }

    private var resFpsText: String {
        let res = st.videoResolutionName ?? "—"
        let fps = st.videoFpsName.map { "\($0)fps" } ?? "—"
        return "\(res)/\(fps)"
    }

    private var fovText: String {
        guard let fov = st.fovValue, let name = OSMOA4.fovName(fov) else { return "FOV —" }
        return "FOV \(name)"
    }

    private var exposureText: String {
        var parts = ["曝光 \(st.exposureModeName ?? "—")"]
        // EV 补偿仅自动曝光下生效（手动模式相机以 E3/DF 拒绝）
        if st.exposureMode != 0x04, let ev = st.expoCompName {
            parts.append("EV \(ev)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: 实时预览卡（固定高度圆角卡片；左上角 REC 角标；捏合仅提示不发光命令 —— 6.8）

    /// 预览卡宽度（屏宽 - 左右各 12 边距）
    private var previewWidth: CGFloat {
        UIScreen.main.bounds.width - 24
    }
    /// 16:9 预览窗（2026-11-11 由 4:3 调整）；码流同为 16:9，满窗显示无黑边
    private var previewHeight: CGFloat {
        previewWidth * 9 / 16
    }

    /// 相机朝向（pid 0x0014 回读，用户四向实测：0=上 / 1=左横置 / 2=下 / 3=右横置）。
    /// 预览补偿旋转（2026-11-10 旋转会话真机验证正确的公式）：(4-码) % 4 × 90°
    /// ——上 0°、左横置 270°、下 180°、右横置 90°（勿改直接映射，方向会反）
    private var previewCorrectionDegrees: Double {
        let code = Int(st.orientationCode ?? 0)
        return Double((4 - code) % 4) * 90
    }


    /// 码流宽高比（分辨率码 0x67/0x5F/0x0C 为 4:3，其余 16:9）
    private var streamAspect: CGFloat {
        switch st.videoResolutionCode {
        case 0x67, 0x5F, 0x0C: return 4 / 3
        default: return 16 / 9
        }
    }

    private var previewCard: some View {
        ZStack(alignment: .topLeading) {
            // 外层固定黑色背景（不旋转）：内层预览视图整体旋转后露出的角由它补齐。
            // 必须显式限定卡片尺寸——无 frame 的 Color 是 greedy 的，会把 ZStack 撑出 4:3
            Color.black
                .frame(height: previewHeight)
                .frame(maxWidth: .infinity)
            LivePreviewView(flow: flow)
                .frame(height: previewHeight)
                .frame(maxWidth: .infinity)
                // 朝向修正（pid 0x0014：0 上/1 左/2 下/3 右，真机实测）：内容转回正；
                // 左右横置（90°/270°）时缩放 1/码流宽高比，使画面高度顶满仅左右黑边
                .rotationEffect(.degrees(previewCorrectionDegrees))
                .scaleEffect((Int(st.orientationCode ?? 0)) % 2 == 1 ? 1 / streamAspect : 1)
            if gridMode >= 1 {
                FramingGridOverlay(mode: gridMode)
                    .frame(height: previewHeight)
                    .frame(maxWidth: .infinity)
            }
            if st.recordState == 2 {
                RecBadge(seconds: Int64(st.recordSeconds ?? UInt32(st.clipSeconds ?? 0)))
                    .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // 倍率角标用 overlay（不参与 ZStack sizing）——此前作为 maxHeight:.infinity 的
        // ZStack 子视图，变焦 >1x 时会把预览卡撑满剩余空间、面板整体下移
        .overlay(alignment: .topTrailing) {
            if displayZoom > 1.01 {
                Text(String(format: "%.1fx", displayZoom))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(8)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: st.orientationCode ?? 0)
        .simultaneousGesture(MagnifyGesture()
            .onChanged { v in
                // 方向+时间：捏合期间按 ~10Hz 发方向命令，相机持续变焦
                guard Date().timeIntervalSince(lastMoveAt) > 0.1 else { return }
                lastMoveAt = Date()
                flow.zoomMove(zoomIn: v.magnification >= zoomBase)
            }
            .onEnded { _ in
                flow.zoomStop()
                zoomBase = 1.0
            })
        .onTapGesture(count: 2) { setZoom(1.0) }
        .padding(.horizontal, 12)
    }

    /// 倍率显示：优先 cam_lens_state 回读（相机端真实值），无回读时用本地档位
    private var displayZoom: Double {
        st.zoomFactor ?? zoomLevel
    }

    /// 变焦入口行（仅拍照/视频模式；点击弹出轮盘）
    private func zoomEntryButton(_ range: ClosedRange<Double>) -> some View {
        Button {
            zoomLevel = displayZoom   // 弹出时以相机实际倍率为轮盘基准
            showZoomSlider = true
        } label: {
                HStack(spacing: 6) {
                    Text("变焦")
                        .font(.system(size: 13))
                        .foregroundStyle(OC.textSecondary)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Text(String(format: "%.1fx", displayZoom))
                            .font(.system(size: 13, weight: .medium).monospacedDigit())
                            .foregroundStyle(OC.textPrimary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 9))
                            .foregroundStyle(OC.textSecondary)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }

    /// 变焦轮盘弹窗（0.1x 刻度 + 整数焦段磁吸；拍照 1.0–4.0 / 视频 1.0–2.0）
    /// 变焦滚轮弹窗（底部弹出，系统 wheel + 逐档震动/音效；量程按模式：拍照 1.0–4.0 / 视频 1.0–2.0；下滑关闭）
    private var zoomSliderSheet: some View {
        VStack(spacing: 8) {
            Text("变焦")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(OC.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker("变焦", selection: zoomPickerBinding) {
                ForEach(zoomDialCodes, id: \.self) { code in
                    Text(String(format: "%.1fx", Double(code) / 10))
                        .font(.system(size: 16, weight: .medium).monospacedDigit())
                        .frame(width: 60, alignment: .trailing)   // 滚轮行宽统一 60
                        .tag(code)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 170)
            .padding(.horizontal, -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
    }

    private func setZoom(_ level: Double) {
        guard flow.state == .success, let range = zoomRange else { return }
        zoomLevel = min(range.upperBound, max(range.lowerBound, level))
        Task { await flow.setZoomPosition(zoomLevel) }
    }

    /// 滚轮拖动中节流发送绝对位置命令（150ms）
    private func throttledZoomPosition(_ level: Double) {
        guard Date().timeIntervalSince(lastZoomSentAt) > 0.15 else { return }
        lastZoomSentAt = Date()
        Task { await flow.setZoomPosition(level) }
    }

    // MARK: 拍摄参数面板（无折叠标题，直接平铺；占满预览与底栏之间，超出在面板内滚动）

    private var paramsPanel: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 4) {
                groupLabel("通用设置")
                pillGrid {
                    videoPills
                    photoRatioPill
                    lapsePills
                }
                groupLabel("图像")
                pillGrid {
                    proPill
                    exposurePills
                    imagePills
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(RoundedRectangle(cornerRadius: 14).fill(OC.card))
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .tracking(0.5)
            .foregroundStyle(OC.textTertiary)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func pillGrid<P: View>(@ViewBuilder _ pills: () -> P) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)],
                  alignment: .leading,
                  spacing: 10) { pills() }   // 行距与列距一致
    }

    /// 参数胶囊：Menu 选择器 + 回读值（specs「拍摄参数设置」：显示值来自回读，成功后 refresh 校准）。
    /// 整块胶囊都是 Menu label（触摸热区 = 整个 pill，≥44pt），点标题区与值区同样弹出选项
    private func pillRow(_ title: String, current: String?, options: [String],
                         disabled: Bool = false,
                         action: @escaping (Int) async -> Void) -> some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i]) { Task { await action(i) } }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(OC.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Text(current ?? "—")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(disabled ? OC.textTertiary : OC.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9))
                        .foregroundStyle(OC.textSecondary)
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .disabled(disabled || flow.osmoBusy)
    }

    /// 通用设置组（优先级：分辨率/帧率 → 视角 → 变焦 → 电子增稳 → 弱光增稳 → 网格。
    /// 慢动作模式以组合格式项替代分辨率/帧率；照片模式无分辨率/帧率。
    /// ⚠️ ViewBuilder 单帧过大曾致主线程栈溢出（素材页返回整面板重建时，崩溃日志
    /// OpenMimoControl-2026-11-10-014339：videoPills.getter ___chkstk）——大组必须拆
    /// 子 builder、闭包体抽方法，勿再往单一 getter 堆控制项）
    @ViewBuilder
    private var videoPills: some View {
        videoFormatPills
        fovZoomPills
        stabilizePills
        gridCountdownPills
    }

    /// 分辨率/帧率/慢动作（格式类：live=false 滚轮仅关闭时下发；<6 档回退 Menu）
    @ViewBuilder
    private var videoFormatPills: some View {
        let mode = st.captureMode
        if mode == OSMOA4.modeSlowmo {
            pillRow("慢动作", current: slowmoCurrent,
                    options: OSMOA4.slowmoFormats.map { Self.slowmoText($0) }) { i in
                let f = OSMOA4.slowmoFormats[i]
                // 格式切换重启编码器：走 osmoFormatCommand 自动恢复推流
                _ = await flow.osmoFormatCommand("慢动作格式") { link in
                    try await link.setVideoFormat(res: f.res, fps: f.fps, factor: f.factor)
                }
            }
        } else if mode != OSMOA4.modePhoto {
            pillWheelRow("分辨率", current: st.videoResolutionName,
                         options: activeResOptions,
                         initialIndex: st.videoResolutionCode.flatMap { activeResCodes.firstIndex(of: $0) },
                         live: false,
                         onPick: { pickResolution($0) },
                         onClose: { flow.refreshOSMOQueries() })
            pillWheelRow("帧率", current: st.videoFpsName.map { "\($0)fps" },
                         options: activeFpsOptionNames,
                         initialIndex: st.videoFpsCode.flatMap { activeFpsCodes.firstIndex(of: $0) },
                         live: false,
                         onPick: { pickFPS($0) },
                         onClose: { flow.refreshOSMOQueries() })
        }
    }

    private var activeResCodes: [UInt8] {
        OSMOA4.modeResolutions[st.captureMode ?? OSMOA4.modeVideo] ?? []
    }
    private var activeResOptions: [String] {
        activeResCodes.compactMap { OSMOA4.resolutionNames[$0] }
    }
    private var activeFpsCodes: [UInt8] {
        OSMOA4.fpsOptions(mode: st.captureMode ?? OSMOA4.modeVideo, res: st.videoResolutionCode ?? 0x0A)
    }
    private var activeFpsOptionNames: [String] {
        activeFpsCodes.compactMap { OSMOA4.fpsNames[$0].map { "\($0)fps" } }
    }
    private func pickResolution(_ i: Int) {
        let codes = activeResCodes
        guard i < codes.count else { return }
        let res = codes[i]
        let fps = st.videoFpsCode ?? 3
        Task { _ = await flow.osmoFormatCommand("分辨率") { link in
            try await link.setVideoFormat(res: res, fps: fps)
        } }
    }
    private func pickFPS(_ i: Int) {
        let codes = activeFpsCodes
        guard i < codes.count else { return }
        let res = st.videoResolutionCode ?? 0x0A
        Task { _ = await flow.osmoFormatCommand("帧率") { link in
            try await link.setVideoFormat(res: res, fps: codes[i])
        } }
    }

    /// 视角 + 变焦入口
    @ViewBuilder
    private var fovZoomPills: some View {
        pillRow("视角", current: st.fovValue.flatMap { OSMOA4.fovName($0) },
                options: fovOptions.map(\.name)) { i in
            pickFOV(i)
        }
        if let range = zoomRange {
            zoomEntryButton(range)
        }
    }
    private func pickFOV(_ i: Int) {
        let codes = fovOptions.map(\.code)
        guard i < codes.count else { return }
        Task {
            let ok = await flow.osmoCommand("视角") { link in try await link.setFOV(codes[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }

    /// 电子增稳/弱光增稳（仅视频模式）
    @ViewBuilder
    private var stabilizePills: some View {
        if st.captureMode == OSMOA4.modeVideo {
            pillWheelRow("电子增稳", current: st.eisValue.flatMap { OSMOA4.eisName($0) },
                         options: OSMOA4.eisModes.map(\.name),
                         initialIndex: st.eisValue.flatMap { v in OSMOA4.eisModes.firstIndex { $0.code == v } },
                         onPick: { pickEIS($0) },
                         onClose: { flow.refreshOSMOQueries() })
            // 弱光增稳（02/8E pid 0x0030，2026-11-10 Mimo 抓包实锤）
            pillRow("弱光增稳", current: lowLightOverride.map { $0 ? "开启" : "关闭" }
                        ?? (st.lowLightCode == 1 ? "开启" : st.lowLightCode == 0 ? "关闭" : nil),
                    options: ["关闭", "开启"]) { i in
                pickLowLight(i == 1)
            }
        }
    }
    private func pickEIS(_ i: Int) {
        guard i < OSMOA4.eisModes.count else { return }
        Task { _ = await flow.osmoCommand("电子增稳") { try await $0.setEIS(OSMOA4.eisModes[i].code) } }
    }
    private func pickLowLight(_ on: Bool) {
        Task {
            let ok = await flow.osmoCommand("弱光增稳") { link in try await link.setLowLight(on) }
            if ok != nil {
                await MainActor.run {
                    lowLightOverride = on            // 即时反馈；回读到达后对齐
                    flow.refreshOSMOQueries()
                }
            }
        }
    }

    /// 网格（App 端叠加）/ 拍照倒计时（仅照片模式）
    @ViewBuilder
    private var gridCountdownPills: some View {
        // 取景网格（官方 Mimo 即 App 端预览叠加，不向相机发送命令）
        pillRow("网格", current: Self.gridModes[gridMode],
                options: Self.gridModes) { i in
            gridMode = i
        }
        // 拍照倒计时（02/4A，2026-11-10 Mimo 抓包实锤；无 GET 回读形态，本地记忆当前值）
        if st.captureMode == OSMOA4.modePhoto {
            pillWheelRow("拍照倒计时", current: Self.countdownModes[photoCountdown],
                         options: Self.countdownModes,
                         initialIndex: photoCountdown, live: false,
                         onPick: { pickCountdown($0) })
        }
    }
    private func pickCountdown(_ i: Int) {
        guard i != photoCountdown else { return }
        photoCountdown = i
        let ms = Self.countdownMillis[i]
        Task { _ = await flow.osmoCommand("拍照倒计时") { link in
            try await link.setCountdown(seconds: UInt16(ms / 1000),
                                        millis: UInt16(ms % 1000))
        } }
    }

    static let gridModes = ["关闭", "网格线", "网格线和对角线"]

    /// PRO 开关（图像组首项；Pro 关闭时图像组仅此项）
    @ViewBuilder
    private var proPill: some View {
        pillRow("PRO", current: proOn ? "开" : "关",
                options: ["关", "开"]) { i in
            let on = i == 1
            let ok = await flow.osmoCommand("Pro 开关") { link in try await link.setPro(on) }
            if ok != nil {
                await MainActor.run {
                    proOverride = on            // 立即展开/收起专业参数
                    flow.refreshOSMOQueries()   // 回读 pid 0x0000 校准
                }
            }
        }
    }

    /// 曝光组（Pro 开启时显示：曝光 → EV → 快门 → ISO → ISO MAX。
    /// 自动曝光下快门/ISO 置灰并回显相机自计算值；02/1E 手动下才能设快门/ISO）
    @ViewBuilder
    private var exposurePills: some View {
        let manual = st.exposureMode == 0x04
        if proOn {
            pillRow("曝光", current: st.exposureModeName,
                    options: ["自动", "手动"]) { i in
                pickExposureMode(auto: i == 0)
            }
            evPill
            pillWheelRow("快门", current: st.effectiveShutterName ?? st.shutterName,
                         options: activeShutterRaws.map { OSMOA4.shutterText(raw: $0) },
                         initialIndex: st.effectiveShutter.flatMap { activeShutterRaws.firstIndex(of: $0) },
                         disabled: !manual,
                         onPick: { pickShutter($0) },
                         onClose: { flow.refreshOSMOQueries() })
            pillWheelRow("ISO", current: manual ? st.isoName : (st.effectiveISOName ?? st.isoName),
                         options: ["自动"] + OSMOA4.isoCodes.map { "\($0.value)" },
                         initialIndex: st.isoCode.flatMap { c in
                             c == 0 ? 0 : OSMOA4.isoCodes.firstIndex { $0.code == c }.map { $0 + 1 }
                         },
                         disabled: !manual,
                         onPick: { pickISO($0) },
                         onClose: { flow.refreshOSMOQueries() })
            // ISO 上限（02/8E pid 0x000F；手动曝光下同样可调）
            pillWheelRow("ISO MAX", current: st.isoMaxCode.flatMap { OSMOA4.isoMaxName($0) },
                         options: OSMOA4.isoMaxSteps.map(\.name),
                         initialIndex: st.isoMaxCode.flatMap { c in OSMOA4.isoMaxSteps.firstIndex { $0.code == c } },
                         onPick: { pickISOMax($0) },
                         onClose: { flow.refreshOSMOQueries() })
        }
    }

    /// 视频模式快门上限 1/25（真机实测；其他模式全表）
    private var activeShutterRaws: [UInt32] {
        st.captureMode == OSMOA4.modeVideo
            ? OSMOA4.shutterSpeeds.filter { (OSMOA4.shutterSeconds(raw: $0) ?? 0) <= 1.0 / 25.0 + 1e-9 }
            : OSMOA4.shutterSpeeds
    }
    private func pickExposureMode(auto: Bool) {
        Task {
            let ok = await flow.osmoCommand("曝光模式") { link in try await link.setExposureMode(auto: auto) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }
    private func pickShutter(_ i: Int) {
        let raws = activeShutterRaws
        guard i < raws.count else { return }
        Task { _ = await flow.osmoCommand("快门") { try await $0.setShutter(raw: raws[i]) } }
    }
    private func pickISO(_ i: Int) {
        let code = i == 0 ? UInt8(0) : OSMOA4.isoCodes[i - 1].code
        Task { _ = await flow.osmoCommand("ISO") { try await $0.setISO(code) } }
    }
    private func pickISOMax(_ i: Int) {
        guard i < OSMOA4.isoMaxSteps.count else { return }
        Task { _ = await flow.osmoCommand("ISO MAX") { try await $0.setISOMax(OSMOA4.isoMaxSteps[i].code) } }
    }

    /// 视角值域按模式约束（OA4）：视频模式 窄/标准/广角/超广（是否可选随分辨率与帧率变化，
    /// 精确矩阵待实测——不可选时相机回 E3 拒绝并由回读校准）；其他模式 标准/广角
    private var fovOptions: [(code: UInt8, name: String)] {
        st.captureMode == OSMOA4.modeVideo
            ? [(0x03, "窄"), (0x02, "标准（畸变校正）"), (0x01, "广角"), (0x00, "超广")]
            : [(0x02, "标准（畸变校正）"), (0x01, "广角")]
    }

    /// 图像组（02/2C/42/38/44；视角/增稳已移入通用设置组）
    @ViewBuilder
    private var imagePills: some View {
        pillWheelRow("白平衡", current: st.wbName,
                     options: ["自动"] + OSMOA4.wbKelvins.map { "\($0)K" },
                     initialIndex: st.wbMode == 0x00 ? 0
                         : st.wbKelvin.flatMap { k in OSMOA4.wbKelvins.firstIndex(of: k) }.map { $0 + 1 },
                     onPick: { pickWhiteBalance($0) },
                     onClose: { flow.refreshOSMOQueries() })
        pillRow("色彩", current: st.colorProfileName,
                options: OSMOA4.colorModes.map(\.name)) { i in
            pickColorProfile(i)
        }
        // 图像调节（App 侧预设，无独立相机字段——三方文档 02/8E pid 表均无此概念。
        // 实测映射：默认=锐度0/降噪0，人像=锐度0/降噪1，经 02/38+02/44 下发；自定义仅解锁手动调节）
        pillRow("图像调节", current: Self.imageTuneModes[imageTune],
                options: Self.imageTuneModes) { i in
            pickImageTune(i)
        }
        pillRow("锐度", current: st.sharpness.map(String.init),
                options: OSMOA4.sharpnessRange.map(String.init),
                disabled: imageTune != 2) { i in
            pickSharpness(i)
        }
        pillRow("降噪", current: st.denoise.map(String.init),
                options: OSMOA4.denoiseRange.map(String.init),
                disabled: imageTune != 2) { i in
            pickDenoise(i)
        }
    }

    private func pickWhiteBalance(_ i: Int) {
        let manual = i > 0
        let kelvin = i > 0 ? OSMOA4.wbKelvins[i - 1] : 5600
        Task { _ = await flow.osmoCommand("白平衡") { try await $0.setWhiteBalance(manual: manual, kelvin: kelvin) } }
    }
    private func pickColorProfile(_ i: Int) {
        Task {
            let ok = await flow.osmoCommand("色彩档位") { link in try await link.setColorProfile(OSMOA4.colorModes[i].code) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }
    private func pickImageTune(_ i: Int) {
        Task { @MainActor in imageTune = i }
        guard i < 2 else { return }   // 自定义不改动当前值
        let denoise: Int8 = i == 0 ? 0 : 1
        Task {
            let ok = await flow.osmoCommand("图像调节") { link in
                try await link.setSharpness(0)
                try await link.setDenoise(denoise)
            }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }
    private func pickSharpness(_ i: Int) {
        Task {
            let ok = await flow.osmoCommand("锐度") { link in try await link.setSharpness(OSMOA4.sharpnessRange[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }
    private func pickDenoise(_ i: Int) {
        Task {
            let ok = await flow.osmoCommand("降噪") { link in try await link.setDenoise(OSMOA4.denoiseRange[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }

    /// 画幅（仅照片模式；通用设置组）
    @ViewBuilder
    private var photoRatioPill: some View {
        if st.captureMode == OSMOA4.modePhoto {
            pillRow("画幅", current: st.photoRatioCode.map { $0 == 1 ? "16:9" : "4:3" },
                    options: ["4:3", "16:9"]) { i in
                _ = await flow.osmoFormatCommand("画幅") { link in try await link.setPhotoFormat(size: 0, ratio: UInt8(i)) }
            }
        }
    }

    /// 延时/运动延时（02/6C 双形态；平铺进通用设置组两列网格；当前值来自 cam_lapse_param 回读）
    @ViewBuilder
    private var lapsePills: some View {
        if st.captureMode == OSMOA4.modeTimelapse {
            pillWheelRow("延时间隔", current: st.lapseIntervalDeciS.map { Self.intervalText($0) },
                         options: OSMOA4.timelapseIntervalsTenths.map { Self.intervalText($0) },
                         initialIndex: st.lapseIntervalDeciS.flatMap { v in OSMOA4.timelapseIntervalsTenths.firstIndex(of: v) },
                         onPick: { pickLapseInterval($0) },
                         onClose: { flow.refreshOSMOQueries() })
            pillWheelRow("拍摄时长", current: st.lapseDurationS.map { $0 == 0 ? "不限" : "\(Int($0) / 60)分" },
                         options: OSMOA4.timelapseDurationsS.map { $0 == 0 ? "不限" : "\(Int($0) / 60)分" },
                         initialIndex: st.lapseDurationS.flatMap { v in OSMOA4.timelapseDurationsS.firstIndex(of: v) },
                         onPick: { pickLapseDuration($0) },
                         onClose: { flow.refreshOSMOQueries() })
            pillRow("保存", current: st.lapseKeep.flatMap { keep in
                OSMOA4.lapseSaveModes.first { $0.code == keep }?.name
            }, options: OSMOA4.lapseSaveModes.map(\.name)) { i in
                pickLapseSave(i)
            }
        } else if st.captureMode == OSMOA4.modeHyperlapse {
            pillWheelRow("延时速率", current: st.lapseSpeed.map { $0 == 0 ? "自动" : "\($0)×" },
                         options: OSMOA4.hyperlapseSpeeds.map { $0 == 0 ? "自动" : "\($0)×" },
                         initialIndex: st.lapseSpeed.flatMap { v in OSMOA4.hyperlapseSpeeds.firstIndex(of: v) },
                         onPick: { pickHyperlapseSpeed($0) },
                         onClose: { flow.refreshOSMOQueries() })
        }
    }
    private func pickLapseInterval(_ i: Int) {
        guard i < OSMOA4.timelapseIntervalsTenths.count else { return }
        let keep = st.lapseKeep ?? 0
        let dur = st.lapseDurationS ?? 0
        Task { _ = await flow.osmoCommand("延时间隔") { try await $0.setTimelapse(save: keep,
            intervalTenths: OSMOA4.timelapseIntervalsTenths[i], durationS: dur) } }
    }
    private func pickLapseDuration(_ i: Int) {
        guard i < OSMOA4.timelapseDurationsS.count else { return }
        let keep = st.lapseKeep ?? 0
        let interval = st.lapseIntervalDeciS ?? 20
        Task { _ = await flow.osmoCommand("拍摄时长") { try await $0.setTimelapse(save: keep,
            intervalTenths: interval, durationS: OSMOA4.timelapseDurationsS[i]) } }
    }
    private func pickLapseSave(_ i: Int) {
        guard i < OSMOA4.lapseSaveModes.count else { return }
        Task {
            let ok = await flow.osmoCommand("延时保存") { link in
                try await link.setTimelapse(save: OSMOA4.lapseSaveModes[i].code,
                                            intervalTenths: st.lapseIntervalDeciS ?? 20,
                                            durationS: st.lapseDurationS ?? 0)
            }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }
    private func pickHyperlapseSpeed(_ i: Int) {
        guard i < OSMOA4.hyperlapseSpeeds.count else { return }
        Task { _ = await flow.osmoCommand("延时速率") { try await $0.setHyperlapseSpeed(OSMOA4.hyperlapseSpeeds[i]) } }
    }

    /// 延时间隔显示：整秒不带小数（0.5s / 1s / 2s …）
    static func intervalText(_ tenths: UInt16) -> String {
        tenths % 10 == 0 ? "\(tenths / 10)s" : String(format: "%.1fs", Double(tenths) / 10)
    }

    private var slowmoCurrent: String? {
        guard let res = st.videoResolutionCode, let fps = st.videoFpsCode else { return nil }
        return OSMOA4.slowmoFormats.first { $0.res == res && $0.fps == fps }
            .map { Self.slowmoText($0) }
    }

    private static func slowmoText(_ f: (res: UInt8, fps: UInt8, factor: UInt8)) -> String {
        "\(OSMOA4.resolutionNames[f.res] ?? "?") · \(OSMOA4.fpsNames[f.fps] ?? 0)fps · \(f.factor)×"
    }

    private static func shutterText(_ raw: UInt32) -> String {
        OSMOA4.shutterText(raw: raw)   // 统一显示（含 <1s → 1/x 形式）
    }

    // MARK: 底部操作栏（左素材浏览 / 中快门 / 右录制模式图标，固定页面底部）

    private var bottomBar: some View {
        HStack {
            Button(action: onMedia) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 17))
                    .foregroundStyle(Color(hex: 0xC7C7CC))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("素材浏览")
            Spacer()
            shutterButton
            Spacer()
            Button {
                liveNotice = nil
                showModeSheet = true
            } label: {
                Image(systemName: modeSymbol(st.captureMode))
                    .font(.system(size: 17))
                    .foregroundStyle(Color(hex: 0xC7C7CC))
                    .padding(6)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("录制模式")
        }
        .padding(.horizontal, 22)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .background(OC.bg)
    }

    /// 快门/录制按钮：照片=拍照；延时=启停（02/01）；视频类=录制启停（02/02）。
    /// 形态与 02/80 推送的录制状态实时同步（specs「录制控制」）。
    private var shutterButton: some View {
        Button {
            Task { await flow.toggleRecord() }
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(st.recordState == 2 ? OC.recRed : Color.white, lineWidth: 3)
                    .frame(width: 66, height: 66)
                if st.recordState == 2 {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(OC.recRed)
                        .frame(width: 24, height: 24)
                } else if st.captureMode == OSMOA4.modePhoto {
                    Circle().fill(Color.white).frame(width: 52, height: 52)
                } else {
                    Circle().fill(OC.recRed).frame(width: 52, height: 52)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(flow.osmoBusy || flow.state != .success)
        .accessibilityLabel(shutterAccessibility)
    }

    private var shutterAccessibility: String {
        if st.captureMode == OSMOA4.modePhoto { return "拍照" }
        return st.recordState == 2 ? "停止录制" : "开始录制"
    }

    // MARK: 录制模式弹窗（六模式 + 直播展示项；当前高亮，选择后收起并联动右下角图标）

    private var modeSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text("录制模式")
                    .font(.headline)
                    .foregroundStyle(OC.textPrimary)
                Spacer()
                Button("取消") { showModeSheet = false }
                    .font(.footnote)
                    .foregroundStyle(OC.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(OC.pill))
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 9),
                                GridItem(.flexible(), spacing: 9)],
                      spacing: 9) {
                ForEach(OSMOA4.modeNames, id: \.code) { m in
                    modeTile(code: m.code, name: m.name, symbol: modeSymbol(m.code))
                }
                liveTile
            }
            if let notice = liveNotice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(OC.recRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .presentationDetents([.height(360)])
        .presentationDragIndicator(.hidden)
        .onAppear { liveNotice = nil }
    }

    private func modeTile(code: UInt8, name: String, symbol: String) -> some View {
        let current = st.captureMode == code
        return Button {
            showModeSheet = false
            Task { await flow.switchMode(code) }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                    .foregroundStyle(current ? OC.accent : OC.textSecondary)
                Text(name)
                    .font(.subheadline)
                    .foregroundStyle(OC.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(current ? OC.accent.opacity(0.14) : OC.pill))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(current ? OC.accent : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(flow.osmoBusy)
        .accessibilityLabel(name)
    }

    private var liveTile: some View {
        Button {
            // 直播不在实现范围：不发任何命令，明确提示（specs「模式切换」）
            liveNotice = "直播未实现：OA4 不支持直播模式，当前拍摄模式保持不变"
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 15))
                    .foregroundStyle(OC.textTertiary)
                Text("直播")
                    .font(.subheadline)
                    .foregroundStyle(OC.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(OC.pill.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("直播（未实现）")
    }

    private func modeSymbol(_ code: UInt8?) -> String {
        switch code {
        case OSMOA4.modePhoto: return "camera.fill"
        case OSMOA4.modeSuperNight: return "moon.fill"
        case OSMOA4.modeSlowmo: return "tortoise.fill"
        case OSMOA4.modeTimelapse: return "timer"
        case OSMOA4.modeHyperlapse: return "gauge"
        default: return "video.fill"
        }
    }

    // MARK: 相机状态详情弹窗（全量遥测 + 诊断 + 断开连接；从顶部状态区进入）

    private var detailSheet: some View {
        VStack(spacing: 10) {
            HStack {
                Text("相机状态详情")
                    .font(.headline)
                    .foregroundStyle(OC.textPrimary)
                Spacer()
                Button("关闭") { showDetail = false }
                    .font(.footnote)
                    .foregroundStyle(OC.textSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(OC.pill))
            }
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(detailRows, id: \.0) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.0)
                                .font(.caption)
                                .foregroundStyle(OC.textSecondary)
                                .frame(width: 72, alignment: .leading)
                            Text(row.1)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(OC.textPrimary)
                            Spacer(minLength: 0)
                        }
                    }
                    if !st.queryErrors.isEmpty {
                        Text("查询错误: " + st.queryErrors
                            .map { "\($0.key)=0x\(String(format: "%02X", $0.value))" }
                            .joined(separator: " "))
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    // 未知信号（未解析主题/参数的原始记录，供抓包 diff；unknown-signals-report）
                    if !st.rawParams.isEmpty || !st.rawTopicSamples.isEmpty {
                        Divider().overlay(OC.stroke).padding(.vertical, 6)
                        Text("未知信号（原始记录）")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(OC.textSecondary)
                        ForEach(st.rawParams.sorted(by: { $0.key < $1.key }), id: \.key) { pid, hex in
                            Text("pid \(String(format: "0x%04X", pid)) = \(hex)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(OC.textTertiary)
                        }
                        ForEach(st.rawTopicSamples.sorted(by: { $0.key < $1.key }), id: \.key) { name, hex in
                            Text("\(name): \(hex)")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(OC.textTertiary)
                                .lineLimit(2)
                        }
                    }
                    Divider().overlay(OC.stroke).padding(.vertical, 6)
                    Text("诊断日志")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(OC.textSecondary)
                    ForEach(Array(diagnostics.lines.suffix(30).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(OC.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(OC.pill.opacity(0.4)))
            }
            HStack {
                CopyDiagnosticsButton(snapshotProvider: { diagnostics.snapshot() })
                Spacer()
                Button("断开连接") {
                    showDetail = false
                    onDisconnect()
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 12).fill(OC.recRed))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .presentationDetents([.medium, .large])
    }

    private var detailRows: [(String, String)] {
        [
            ("拍摄模式", st.captureModeName ?? "—"),
            ("工作状态", st.workModeName ?? "—"),
            ("录制状态", st.recordStateName ?? "—"),
            ("已录时长", st.recordSeconds.map { Self.durationText(Int64($0)) }
                ?? st.clipSeconds.map { Self.durationText($0) } ?? "—"),
            ("写文件", st.isWritingFile ? "是" : "否"),
            ("媒体库模式", st.mediaMode ? "开" : "关"),
            ("剩余可录", st.videoSecondsLeft.map { Self.durationText($0) } ?? "—"),
            ("剩余张数", st.photosLeft.map(String.init) ?? "—"),
            ("视频格式", [st.videoResolutionName, st.videoFpsName.map { "\($0)fps" }]
                .compactMap { $0 }.joined(separator: " ")),
            ("曝光模式", st.exposureModeName ?? "—"),
            ("ISO", st.isoName ?? "—"),
            ("快门", st.shutterName ?? "—"),
            ("EV 补偿", st.expoCompName ?? "—"),
            ("测光", st.lightMeterName ?? "—"),
            ("生效 ISO", st.effectiveISO.map { $0 == 0 ? "自动" : String($0) } ?? "—"),
            ("ISO 档码", st.isoStepCode.map { String(format: "0x%02X", $0) } ?? "—"),
            ("生效快门", st.effectiveShutterName ?? "—"),
            ("拍照快门", st.photoShutterName ?? "—"),
            ("数字增益", st.digitalGain.map {
                "\($0)." + (st.digitalGainFine.map(String.init) ?? "?")
            } ?? "—"),
            ("白平衡", st.wbName ?? "—"),
            ("色彩档位", st.colorProfileName ?? "—"),
            ("锐度", st.sharpness.map(String.init) ?? "—"),
            ("降噪", st.denoise.map(String.init) ?? "—"),
            ("SD 卡", st.sdTotalMB.map { "共 \($0/1024)GB · 余 \(st.sdFreeMB.map { "\($0/1024)" } ?? "?")GB" } ?? "—"),
            ("内置存储", st.internalTotalMB.map { "共 \($0/1024)GB · 余 \(st.internalFreeMB.map { "\($0/1024)" } ?? "?")GB" } ?? "—"),
            ("电池电压", st.batteryVoltageMV.map { "\($0) mV" } ?? "—"),
            ("电池电流", st.batteryCurrentMA.map { $0 < 0 ? "放电 \(-$0) mA" : "充电 \($0) mA" } ?? "—"),
            ("电池温度", st.batteryTempDeciC.map { String(format: "%.1f °C", Double($0) / 10) } ?? "—"),
            ("相机朝向", st.orientationCode.map { ["上", "左横置", "下", "右横置"][Int($0) % 4] } ?? "—"),
            ("弱光增稳", st.lowLightCode.map { $0 == 1 ? "开" : "关" } ?? "—"),
            ("延时设置", lapseText),
            ("预览帧数", "\(flow.osmoFrameCount)"),
            ("状态更新", st.lastUpdate.map { Self.timeText($0) } ?? "—"),
        ]
    }

    private var lapseText: String {
        guard st.lapseIntervalDeciS != nil || st.lapseDurationS != nil || st.lapseSpeed != nil else { return "—" }
        var parts: [String] = []
        if let iv = st.lapseIntervalDeciS { parts.append(String(format: "间隔 %.1fs", Double(iv) / 10)) }
        if let du = st.lapseDurationS, du > 0 { parts.append("时长 \(Self.durationText(Int64(du)))") }
        if let du = st.lapseDurationS, du == 0 { parts.append("时长 不限") }
        if let sp = st.lapseSpeed, sp > 0 { parts.append("\(sp)×") }
        if let keep = st.lapseKeepName { parts.append(keep) }
        return parts.joined(separator: " · ")
    }

    private static func durationText(_ s: Int64) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60)
                  : String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static func timeText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

/// 长档位滚轮弹窗上下文（选项 ≥5 的控制项；EV/变焦有专属实现，不走此通用通道）
private struct WheelSheetContext: Identifiable {
    let id = UUID()
    let title: String
    let options: [String]
    let initialIndex: Int
    /// true：滚动跨档即下发（200ms 节流）；false：仅关闭时下发（格式类命令会重启编码器）
    let live: Bool
    let rowWidth: CGFloat
    let onPick: (Int) -> Void
    let onClose: (() -> Void)?
}

/// 滚轮弹窗视图（系统 wheel + 逐档震动/音效；关闭必发一次最终选择 + 回读校准）
private struct WheelSheetView: View {
    let ctx: WheelSheetContext
    @State private var index: Int
    @State private var lastSent = Date.distantPast
    private let selectionHaptic = UISelectionFeedbackGenerator()

    init(ctx: WheelSheetContext) {
        self.ctx = ctx
        _index = State(initialValue: min(max(ctx.initialIndex, 0), max(ctx.options.count - 1, 0)))
    }

    var body: some View {
        VStack(spacing: 8) {
            Text(ctx.title)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(OC.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Picker(ctx.title, selection: $index) {
                ForEach(ctx.options.indices, id: \.self) { i in
                    Text(ctx.options[i])
                        .font(.system(size: 16, weight: .medium).monospacedDigit())
                        .minimumScaleFactor(0.6)   // 长文本（1/8000 s）缩放收纳
                        .lineLimit(1)
                        .frame(width: ctx.rowWidth, alignment: .trailing)
                        .tag(i)
                }
            }
            .pickerStyle(.wheel)
            .frame(height: 170)
            .padding(.horizontal, -8)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.hidden)
        .onChange(of: index) { i in
            selectionHaptic.selectionChanged()
            AudioServicesPlaySystemSound(1104)
            guard ctx.live, Date().timeIntervalSince(lastSent) > 0.2 else { return }
            lastSent = Date()
            ctx.onPick(i)
        }
        .onDisappear {
            ctx.onPick(index)
            ctx.onClose?()
        }
    }
}
