import SwiftUI
import OpenMimoProtocol

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
        .ocToast($toast)
        .sheet(isPresented: $showDetail) { detailSheet }
        .sheet(isPresented: $showModeSheet) { modeSheet }
        .sheet(isPresented: $showZoomSlider) { zoomSliderSheet }
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

    /// 4:3 取景区（设计稿修订）；16:9 码流由 resizeAspect 自动上下加黑边
    private var previewHeight: CGFloat {
        (UIScreen.main.bounds.width - 24) * 3 / 4
    }

    private var previewCard: some View {
        ZStack(alignment: .topLeading) {
            LivePreviewView(flow: flow)
                .frame(height: previewHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            if st.recordState == 2 {
                RecBadge(seconds: st.clipSeconds ?? 0)
                    .padding(8)
            }
            if displayZoom > 1.01 {
                Text(String(format: "%.1fx", displayZoom))
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }
        }
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(OC.textSecondary)
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text(String(format: "%.1fx", displayZoom))
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(OC.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(OC.textSecondary)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
        }
        .buttonStyle(.plain)
    }

    /// 变焦轮盘弹窗（0.1x 刻度 + 整数焦段磁吸；拍照 1.0–4.0 / 视频 1.0–2.0）
    private var zoomSliderSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("变焦")
                    .font(.headline)
                    .foregroundStyle(OC.textPrimary)
                Spacer()
                Button {
                    showZoomSlider = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(OC.textTertiary)
                }
            }
            ZoomWheelView(
                range: zoomRange ?? 1.0...4.0,
                snapPoints: (zoomRange?.upperBound ?? 4.0) <= 2.0 ? [1.0, 2.0] : [1.0, 2.0, 3.0, 4.0],
                value: $zoomLevel,
                onTickChange: { throttledZoomPosition($0) },
                onCommit: { level in Task { await flow.setZoomPosition(level) } }
            )
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .interactiveDismissDisabled(true)
        .presentationDetents([.height(320)])
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
                if let range = zoomRange {
                    groupLabel("变焦")
                    zoomEntryButton(range)
                }
                groupLabel("曝光")
                pillGrid { exposurePills }
                groupLabel("图像")
                pillGrid { imagePills }
                groupLabel("格式")
                pillGrid { formatPills }
                lapsePills
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
                  spacing: 6) { pills() }
    }

    /// 参数胶囊：Menu 选择器 + 回读值（specs「拍摄参数设置」：显示值来自回读，成功后 refresh 校准）
    private func pillRow(_ title: String, current: String?, options: [String],
                         disabled: Bool = false,
                         action: @escaping (Int) async -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(OC.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Menu {
                ForEach(options.indices, id: \.self) { i in
                    Button(options[i]) { Task { await action(i) } }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(current ?? "—")
                        .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(disabled ? OC.textTertiary : OC.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(OC.textSecondary)
                }
            }
            .disabled(disabled || flow.osmoBusy)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(OC.pill))
    }

    /// 曝光组（specs 表：02/1E 手动下才能设 ISO/快门；自动下才能设 EV——E3/DF 由相机裁决）
    @ViewBuilder
    private var exposurePills: some View {
        let manual = st.exposureMode == 0x04
        pillRow("曝光模式", current: st.exposureModeName,
                options: ["自动", "手动"]) { i in
            let ok = await flow.osmoCommand("曝光模式") { link in try await link.setExposureMode(auto: i == 0) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("ISO", current: st.isoName,
                options: ["自动"] + OSMOA4.isoCodes.map { "\($0.value)" },
                disabled: !manual) { i in
            let code = i == 0 ? UInt8(0) : OSMOA4.isoCodes[i - 1].code
            let ok = await flow.osmoCommand("ISO") { link in try await link.setISO(code) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("快门", current: st.shutterName,
                options: OSMOA4.shutterSpeeds.map { Self.shutterText($0) },
                disabled: !manual) { i in
            let ok = await flow.osmoCommand("快门") { link in try await link.setShutter(raw: OSMOA4.shutterSpeeds[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("EV 补偿", current: st.expoCompName,
                options: OSMOA4.evSteps.map { OSMOA4.evName($0) },
                disabled: manual) { i in
            let ok = await flow.osmoCommand("EV 补偿") { link in try await link.setEV(OSMOA4.evSteps[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }

    /// 视角值域按模式约束（OA4，官方 Mimo 抓包实锤）：视频仅 窄(03)/标准（畸变校正）(02)；
    /// 其他模式仅 标准（畸变校正）(02)/广角(01)
    private var fovOptions: [(code: UInt8, name: String)] {
        st.captureMode == OSMOA4.modeVideo
            ? [(0x03, "窄"), (0x02, "标准（畸变校正）")]
            : [(0x02, "标准（畸变校正）"), (0x01, "广角")]
    }

    /// 图像组（02/2C/42/38/44/8E×2；FOV 兼作视场角展示）
    @ViewBuilder
    private var imagePills: some View {
        pillRow("白平衡", current: st.wbName,
                options: ["自动"] + OSMOA4.wbKelvins.map { "\($0)K" }) { i in
            let ok = await flow.osmoCommand("白平衡") { link in
                try await link.setWhiteBalance(manual: i > 0,
                                               kelvin: i > 0 ? OSMOA4.wbKelvins[i - 1] : 5600)
            }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("色彩", current: st.colorProfileName,
                options: OSMOA4.colorModes.map(\.name)) { i in
            let ok = await flow.osmoCommand("色彩档位") { link in try await link.setColorProfile(OSMOA4.colorModes[i].code) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("锐度", current: st.sharpness.map(String.init),
                options: OSMOA4.sharpnessRange.map(String.init)) { i in
            let ok = await flow.osmoCommand("锐度") { link in try await link.setSharpness(OSMOA4.sharpnessRange[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("降噪", current: st.denoise.map(String.init),
                options: OSMOA4.denoiseRange.map(String.init)) { i in
            let ok = await flow.osmoCommand("降噪") { link in try await link.setDenoise(OSMOA4.denoiseRange[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("视角", current: st.fovValue.flatMap { OSMOA4.fovName($0) },
                options: fovOptions.map(\.name)) { i in
            let codes = fovOptions.map(\.code)
            guard i < codes.count else { return }
            let ok = await flow.osmoCommand("视角") { link in try await link.setFOV(codes[i]) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
        pillRow("防抖", current: st.eisValue.flatMap { OSMOA4.eisName($0) },
                options: OSMOA4.eisModes.map(\.name)) { i in
            let ok = await flow.osmoCommand("防抖") { link in try await link.setEIS(OSMOA4.eisModes[i].code) }
            if ok != nil {
                await MainActor.run { flow.refreshOSMOQueries() }
            }
        }
    }

    /// 格式组（02/18/02/12；慢动作展示 (分辨率,帧率,倍速) 组合；照片模式只有比例）
    @ViewBuilder
    private var formatPills: some View {
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
            pillRow("分辨率", current: st.videoResolutionName,
                    options: (OSMOA4.modeResolutions[mode ?? OSMOA4.modeVideo] ?? [])
                        .compactMap { OSMOA4.resolutionNames[$0] }) { i in
                let codes = OSMOA4.modeResolutions[mode ?? OSMOA4.modeVideo] ?? []
                guard i < codes.count else { return }
                let res = codes[i]
                let fps = st.videoFpsCode ?? 3
                _ = await flow.osmoFormatCommand("分辨率") { link in try await link.setVideoFormat(res: res, fps: fps) }
            }
            pillRow("帧率", current: st.videoFpsName.map { "\($0)fps" },
                    options: OSMOA4.fpsOptions(mode: mode ?? OSMOA4.modeVideo,
                                               res: st.videoResolutionCode ?? 0x0A)
                        .compactMap { OSMOA4.fpsNames[$0].map { "\($0)fps" } }) { i in
                let codes = OSMOA4.fpsOptions(mode: mode ?? OSMOA4.modeVideo,
                                              res: st.videoResolutionCode ?? 0x0A)
                guard i < codes.count else { return }
                let res = st.videoResolutionCode ?? 0x0A
                _ = await flow.osmoFormatCommand("帧率") { link in try await link.setVideoFormat(res: res, fps: codes[i]) }
            }
        } else {
            pillRow("照片比例", current: st.photoRatioCode.map { $0 == 1 ? "16:9" : "4:3" },
                    options: ["4:3", "16:9"]) { i in
                _ = await flow.osmoFormatCommand("照片比例") { link in try await link.setPhotoFormat(size: 0, ratio: UInt8(i)) }
            }
        }
    }

    /// 延时组（02/6C 双形态；当前值来自 cam_lapse_param 回读）
    @ViewBuilder
    private var lapsePills: some View {
        if st.captureMode == OSMOA4.modeTimelapse {
            groupLabel("延时")
            pillGrid {
                pillRow("延时间隔", current: st.lapseIntervalDeciS.map { Self.intervalText($0) },
                        options: OSMOA4.timelapseIntervalsTenths.map { Self.intervalText($0) }) { i in
                    let ok = await flow.osmoCommand("延时间隔") { link in
                        try await link.setTimelapse(save: st.lapseKeep ?? 0,
                                                    intervalTenths: OSMOA4.timelapseIntervalsTenths[i],
                                                    durationS: st.lapseDurationS ?? 0)
                    }
                    if ok != nil {
                        await MainActor.run { flow.refreshOSMOQueries() }
                    }
                }
                pillRow("延时长度", current: st.lapseDurationS.map { $0 == 0 ? "不限" : "\(Int($0) / 60)分" },
                        options: OSMOA4.timelapseDurationsS.map { $0 == 0 ? "不限" : "\(Int($0) / 60)分" }) { i in
                    let ok = await flow.osmoCommand("延时长度") { link in
                        try await link.setTimelapse(save: st.lapseKeep ?? 0,
                                                    intervalTenths: st.lapseIntervalDeciS ?? 20,
                                                    durationS: OSMOA4.timelapseDurationsS[i])
                    }
                    if ok != nil {
                        await MainActor.run { flow.refreshOSMOQueries() }
                    }
                }
                pillRow("保存", current: st.lapseKeep.flatMap { keep in
                    OSMOA4.lapseSaveModes.first { $0.code == keep }?.name
                }, options: OSMOA4.lapseSaveModes.map(\.name)) { i in
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
        } else if st.captureMode == OSMOA4.modeHyperlapse {
            groupLabel("运动延时")
            pillGrid {
                pillRow("速度", current: st.lapseSpeed.map { $0 == 0 ? "自动" : "\($0)×" },
                        options: OSMOA4.hyperlapseSpeeds.map { $0 == 0 ? "自动" : "\($0)×" }) { i in
                    let ok = await flow.osmoCommand("运动延时速度") { link in try await link.setHyperlapseSpeed(OSMOA4.hyperlapseSpeeds[i]) }
                    if ok != nil {
                        await MainActor.run { flow.refreshOSMOQueries() }
                    }
                }
            }
        }
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
        let u16 = UInt16(truncatingIfNeeded: raw)
        let decimal = Int((raw >> 16) & 0xFF)
        if u16 & 0x8000 != 0 {
            let x = Double(u16 & 0x7FFF) + Double(decimal) / 10
            let txt = x == x.rounded() ? String(Int(x)) : String(format: "%.1f", x)
            return "1/\(txt) s"
        }
        let s = Double(u16) + Double(decimal) / 10
        return decimal == 0 ? "\(Int(s)) s" : String(format: "%.1f s", s)
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
            ("已录时长", st.clipSeconds.map { Self.durationText($0) } ?? "—"),
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
            ("生效快门", st.effectiveShutterName ?? "—"),
            ("白平衡", st.wbName ?? "—"),
            ("色彩档位", st.colorProfileName ?? "—"),
            ("锐度", st.sharpness.map(String.init) ?? "—"),
            ("降噪", st.denoise.map(String.init) ?? "—"),
            ("SD 卡", st.sdTotalMB.map { "共 \($0/1024)GB · 余 \(st.sdFreeMB.map { "\($0/1024)" } ?? "?")GB" } ?? "—"),
            ("内置存储", st.internalTotalMB.map { "共 \($0/1024)GB · 余 \(st.internalFreeMB.map { "\($0/1024)" } ?? "?")GB" } ?? "—"),
            ("电池电压", st.batteryVoltageMV.map { "\($0) mV" } ?? "—"),
            ("电池电流", st.batteryCurrentMA.map { $0 < 0 ? "放电 \(-$0) mA" : "充电 \($0) mA" } ?? "—"),
            ("电池温度", st.batteryTempDeciC.map { String(format: "%.1f °C", Double($0) / 10) } ?? "—"),
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
