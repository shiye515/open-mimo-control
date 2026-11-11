import Foundation

/// OSMO 相机状态快照——datalink 上全部可获取状态的汇总（osmocam PROTOCOL.md §6/§7/§8）。
///
/// 数据来源：
/// - `02/80` 推送 ~10/s：录制态/工作态/存储总量剩余/剩余张数秒数/已录秒数/拍摄模式
/// - `0D/02` 推送 ~1/s：电池电压/电流/温度/电量百分比
/// - `02/DC` 推送（变化时）：microSD 与内置存储 总量/剩余 MB
/// - `00/99` 命名主题推送：cam_expo_param（ISO/快门/EV 补偿/测光）、
///   cam_image_effect（色彩档位/锐度/降噪）、cam_lapse_param（延时间隔等）
/// - 查询应答（首字节 00=OK）：`02/19` 视频格式、`02/1F` 曝光模式、`02/2B` ISO、
///   `02/29` 快门、`02/2D` 白平衡
public struct OSMOStatusSnapshot: Equatable {

    // MARK: 02/80 相机状态推送

    /// 录制状态：0 空闲 1 启动中 2 录制中 3 停止中
    public var recordState: Int?
    /// 正在写文件（bit 0x08）
    public var isWritingFile = false
    /// 媒体库模式开启（bit 0x40）
    public var mediaMode = false
    /// 工作状态：0 照片/延时 1 视频 2 相机本地回放
    public var workMode: Int?
    public var totalStorageMB: Int64?
    public var freeStorageMB: Int64?
    /// 剩余可拍张数（视频模式为 0；延时模式为剩余帧数）
    public var photosLeft: Int64?
    /// 当前格式下剩余可录秒数（照片模式为 0）
    public var videoSecondsLeft: Int64?
    /// 当前片段已录秒数
    public var clipSeconds: Int64?
    /// 拍摄模式（02/E1 码，见 captureModeName）
    public var captureMode: UInt8?

    // MARK: 0D/02 电池推送

    public var batteryPercent: Int?
    /// 电压 mV
    public var batteryVoltageMV: Int?
    /// 电流 mA，负值=放电
    public var batteryCurrentMA: Int?
    /// 温度，0.1 °C（除 10 得 °C）
    public var batteryTempDeciC: Int?

    // MARK: 02/DC 存储推送

    public var sdTotalMB: Int64?
    public var sdFreeMB: Int64?
    public var internalTotalMB: Int64?
    public var internalFreeMB: Int64?

    // MARK: 查询应答（02/19 / 02/1F / 02/2B / 02/29 / 02/2D）

    /// 视频分辨率码（见 videoResolutionName）
    public var videoResolutionCode: UInt8?
    /// 视频 fps 码（见 videoFpsName）
    public var videoFpsCode: UInt8?
    /// 曝光模式（01 自动 04 手动）
    public var exposureMode: UInt8?
    /// ISO 码（00=自动；见 isoCodeName）
    public var isoCode: UInt8?
    /// 快门原始值：u16 | 十分位<<16（见 shutterName）
    public var shutterRaw: UInt32?
    /// 白平衡模式（00 自动 06 手动色温）
    public var wbMode: UInt8?
    /// 白平衡色温 K
    public var wbKelvin: Int?
    /// 查询结果码非 00 时记录（E0 不支持 / DF 当前不可用 / E3 参数非法）
    public var queryErrors: [String: UInt8] = [:]
    /// 02/13 照片格式回读（照片模式才有；尺寸/比例）
    public var photoSizeCode: UInt8?
    public var photoRatioCode: UInt8?
    /// 02/8E 参数回读（FOV 0x0009 / EIS 0x0008 / ISO 上限 0x000F）
    public var fovValue: UInt8?
    public var eisValue: UInt8?
    /// auto 曝光下的 ISO 上限（02/8E pid 0x000F 回读，码见 OSMOA4.isoMaxSteps）
    public var isoMaxCode: UInt8?
    /// 弱光增稳（02/8E pid 0x0030 回读：01 开 / 00 关）
    public var lowLightCode: UInt8?
    /// 画面旋转象限（02/8E pid 0x0014 回读：0/1/2/3 = 逆时针 90° 象限数）
    public var orientationCode: UInt8?
    /// Pro 模式（02/8E pid 0x0000 回读：01 开 / 00 关；连接即查，控制专业参数显隐）
    public var proOnCode: UInt8?
    /// 录制累计秒（cam_record_time 主题推送 u32 @0；推送优先于 02/80 内的 clipSeconds）
    public var recordSeconds: UInt32?
    /// 未确认布局主题的原始数据段（hex，值变化才更新；诊断面板展示供抓包 diff）
    public var rawTopicSamples: [String: String] = [:]
    /// 未解析 02/8E 参数 pid 的原始回读值（hex，诊断面板展示）
    public var rawParams: [UInt16: String] = [:]
    /// pid 0x000A 最新回读（诊断定位：01↔00 翻转语义未知）
    public var rawParam0A: UInt8?
    /// 相机竖拍模式（cam_portrait_mode 主题，竖拍安装时用于预览方向矫正）
    public var portraitMode: Bool?
    /// 数码变焦倍率（cam_lens_state @14 ÷ 126；相机端变焦同步）
    public var zoomFactor: Double?

    // MARK: 00/99 命名主题推送

    /// EV 补偿原始值（10 + 三分之一档；见 expoCompName）
    public var expoCompValue: UInt8?
    /// 相机测光（同一编码，指示画面偏离正确曝光的程度）
    public var lightMeterValue: UInt8?
    /// cam_expo_param 里实际生效的 ISO（自动模式下为具体值）
    public var effectiveISO: UInt32?
    /// cam_expo_param 里实际生效的快门（u16）
    public var effectiveShutter: UInt16?
    /// 色彩档位（02/42 码：00 Normal / 3F Normal 10-bit / 3D D-Log M …）
    public var colorProfile: UInt8?
    /// 锐度（s8）
    public var sharpness: Int8?
    /// 降噪（s8）
    public var denoise: Int8?
    /// 延时/运动延时参数
    public var lapseKeep: UInt8?
    public var lapseIntervalDeciS: UInt16?
    public var lapseDurationS: UInt32?
    public var lapseSpeed: UInt16?

    /// 最近一次任意状态更新的时间
    public var lastUpdate: Date?

    public init() {}
}

// MARK: - 码值 → 展示名（osmocam §6/§7 表）

extension OSMOStatusSnapshot {

    public var recordStateName: String? {
        switch recordState {
        case 0: "空闲"
        case 1: "启动中"
        case 2: "录制中"
        case 3: "停止中"
        default: nil
        }
    }

    public var workModeName: String? {
        switch workMode {
        case 0: "照片/延时"
        case 1: "视频"
        case 2: "回放"
        default: nil
        }
    }

    /// 拍摄模式（02/E1 码；OA4 与 Nano/Pocket 同表，osmocam §6）
    public var captureModeName: String? {
        switch captureMode {
        case 0x05: "照片"
        case 0x01: "视频"
        case 0x28: "超级夜景"
        case 0x00: "慢动作"
        case 0x02: "延时摄影"
        case 0x0A: "运动延时"
        default: captureMode.map { String(format: "0x%02X", $0) }
        }
    }

    /// 视频分辨率码（osmocam §7.2）
    public var videoResolutionName: String? {
        switch videoResolutionCode {
        case 0x10: "4K 16:9"
        case 0x2D: "2.7K 16:9"
        case 0x0A: "1080p 16:9"
        case 0x67: "4K 4:3"
        case 0x5F: "2.7K 4:3"
        case 0x0C: "1080p 4:3"
        case 0x42: "1080p 9:16"
        default: videoResolutionCode.map { String(format: "0x%02X", $0) }
        }
    }

    /// fps 码（osmocam §7.2）
    public var videoFpsName: String? {
        switch videoFpsCode {
        case 1: "24"
        case 2: "25"
        case 3: "30"
        case 4: "48"
        case 5: "50"
        case 6: "60"
        case 7: "120"
        case 8: "240"
        case 0x0A: "100"
        default: videoFpsCode.map { String($0) }
        }
    }

    /// ISO 码（osmocam §7.1；00=自动）
    public var isoName: String? {
        switch isoCode {
        case 0x00: "自动"
        case 0x01, 0x02, 0x03: "100"
        case 0x04: "200"
        case 0x05: "400"
        case 0x06: "800"
        case 0x07: "1600"
        case 0x08: "3200"
        case 0x09: "6400"
        case 0x0A: "12800"
        case 0x0B: "25600"
        case 0x0C, 0x0D: "51200"
        default: isoCode.map { String(format: "0x%02X", $0) }
        }
    }

    /// 快门原始值 → "1/25 s" / "1.3 s" / "2 s"（osmocam §7.1：bit15=1 → 1/x 秒，否则整秒 + 十分位）
    public var shutterName: String? {
        guard let raw = shutterRaw else { return nil }
        let u16 = UInt16(truncatingIfNeeded: raw)
        let decimal = Int((raw >> 16) & 0xFF)
        return Self.formatShutter(u16: u16, decimal: decimal)
    }

    /// cam_expo_param 实际生效快门（同编码但无十分位）
    public var effectiveShutterName: String? {
        guard let u16 = effectiveShutter else { return nil }
        return Self.formatShutter(u16: u16, decimal: 0)
    }

    /// cam_expo_param 实际生效 ISO（自动曝光下相机自计算值）
    public var effectiveISOName: String? {
        effectiveISO.map { "\($0)" }
    }

    private static func formatShutter(u16: UInt16, decimal: Int) -> String {
        // 小数字节双粒度（2026-11-10 抓包实锤）：≤9 十分位（0x800C+5=1/12.5s、0x0001+3=1.3s），
        // ≥10 百分位（0x8001+0x43=1/1.67s、0x8001+0x19=1/1.25s）；<1s 显示为 1/x
        let digit = OSMOA4.shutterFraction(UInt32(decimal))
        if u16 & 0x8000 != 0 {
            let x = Double(u16 & 0x7FFF) + digit
            let txt = x == x.rounded() ? String(Int(x)) : OSMOA4.shutterDenominatorText(x)
            return "1/\(txt) s"
        }
        let s = Double(u16) + digit
        if s > 0, s < 1 {
            let inv = 1 / s
            let txt = inv == inv.rounded() ? String(Int(inv)) : OSMOA4.shutterDenominatorText(inv)
            return "1/\(txt) s"
        }
        let txt = decimal == 0 ? String(Int(s)) : String(format: "%.1f", s)
        return "\(txt) s"
    }

    /// 曝光模式（osmocam §7.1）
    public var exposureModeName: String? {
        switch exposureMode {
        case 0x01: "自动"
        case 0x04: "手动"
        default: exposureMode.map { String(format: "0x%02X", $0) }
        }
    }

    /// EV 补偿显示（与菜单枚举同源 OSMOA4.evName：码 16=0EV，一位小数，零为 "+0"）
    public var expoCompName: String? {
        expoCompValue.map { OSMOA4.evName($0) }
    }

    /// 测光偏离（同一编码；诊断面板附 " EV" 后缀）
    public var lightMeterName: String? {
        lightMeterValue.map { OSMOA4.evName($0) + " EV" }
    }

    /// 白平衡名称
    public var wbName: String? {
        switch wbMode {
        case 0x00: "自动"
        case 0x06: wbKelvin.map { "\($0)K" } ?? "手动色温"
        default: wbMode.map { String(format: "0x%02X", $0) }
        }
    }

    /// 色彩档位（osmocam §7.5）
    public var colorProfileName: String? {
        switch colorProfile {
        case 0x00: "普通"
        case 0x34: "D-Log M"
        case 0x3C: "HLG"
        case 0x17: "D-Log"
        case 0x41: "D-Log2"
        default: colorProfile.map { String(format: "0x%02X", $0) }
        }
    }

    /// 延时保存类型（osmocam §7.6）
    public var lapseKeepName: String? {
        switch lapseKeep {
        case 0x00: "不保存"
        case 0x02: "JPEG"
        case 0x03: "RAW"
        default: nil
        }
    }
}

// MARK: - 状态跟踪器

/// 接收 datalink 解出的 DUML 帧，解析推送与查询应答，维护 OSMOStatusSnapshot。
/// 全部方法须在 datalink queue 上调用（OSMOCameraLink 持有并喂数据）。
public final class OSMOStatusTracker {

    public private(set) var snapshot = OSMOStatusSnapshot()
    /// 快照变化（datalink 线程；OSMOCameraLink 节流后转 onStatus）
    public var onChanged: ((OSMOStatusSnapshot) -> Void)?
    /// 拍摄模式变化（该模式下格式/曝光需重新查询，osmocam §7）
    public var onCaptureModeChanged: ((UInt8) -> Void)?

    /// 未知主题名 → 首次出现日志一次
    private var loggedUnknownTopics: Set<String> = []
    /// 已首见推送的主题（订阅生效验证：每主题日志一次）
    private var firstReceipts: Set<String> = []
    /// 诊断日志（datalink 线程；OSMOCameraLink 接线）
    public var onLog: ((String) -> Void)?
    /// 固件动作事件（00/76 JSON event_id + 完整字典；OSMOCameraLink 接线到 StepLogger/失败提示）
    public var onEvent: ((String, [String: Any]) -> Void)?
    /// 待确认的订阅主题名队列（应答按订阅顺序回来）
    private var pendingTopicAcks: [String] = []
    /// 最近一次 8E 参数 GET 的 pid（负响应归因到具体 pid；链路发送时登记）
    var pendingParamType: UInt16?
    /// pid 0x000A 上次回读值（翻转检测）
    private var lastParam0A: UInt8?
    /// 语义已实锤的参数 pid（不进未知信号区；unknown-signals-report）
    private let knownParameterPids: Set<UInt16> = [
        OSMOA4.paramPro, OSMOA4.paramEIS, OSMOA4.paramFOV, OSMOA4.paramISOMax,
        OSMOA4.paramLowLight, OSMOA4.paramOrientation,
    ]

    public init() {}

    /// 订阅前登记主题名（应答 00=已订阅 / 01=该型号无此主题，按序匹配记录）
    public func expectSubscriptionAcks(_ topics: [String]) {
        pendingTopicAcks = topics
    }

    /// 链路发送 8E GET 前登记 pid（负响应单字节无 pid，归因到最近 GET——诊断用途）
    public func noteParameterRequest(_ type: UInt16) {
        pendingParamType = type
    }

    /// parseDUML 解出的每条 DUML 帧（推送与查询应答都从这里进）
    public func handle(cmdSet: UInt8, cmdId: UInt8, sender: UInt8, payload: Data) {
        switch (cmdSet, cmdId) {
        case (0x02, 0x80): parseCameraStatus(payload)
        case (0x0D, 0x02): parseBattery(payload)
        case (0x02, 0xDC): parseStorage(payload)
        case (0x00, 0x76): parseActionEvent(payload)
        case (0x00, 0x99):
            // 订阅应答（1B：00 已订阅 / 01 无此主题）vs 主题推送（长帧带名字）
            if payload.count <= 2 {
                let name = pendingTopicAcks.isEmpty ? "?" : pendingTopicAcks.removeFirst()
                onLog?("订阅 \(name) → \(payload.first == 0x00 ? "已订阅" : "无此主题(\(payload.first.map { String(format: "%02X", $0) } ?? "?"))")")
            } else {
                parseTopicPush(payload)
            }
        case (0x02, 0x19): parseVideoFormatReply(payload)
        case (0x02, 0x1F): parseExposureModeReply(payload)
        case (0x02, 0x2B): parseISOReply(payload)
        case (0x02, 0x29): parseShutterReply(payload)
        case (0x02, 0x2D): parseWBReply(payload)
        case (0x02, 0x13): parsePhotoFormatReply(payload)
        case (0x02, 0x8E): parseParameterReply(payload)
        default: break
        }
        emit()
    }

    private func emit() {
        snapshot.lastUpdate = Date()
        onChanged?(snapshot)
    }

    private func setQueryError(_ key: String, _ result: UInt8) {
        if result == 0x00 { snapshot.queryErrors.removeValue(forKey: key) }
        else { snapshot.queryErrors[key] = result }
    }

    // MARK: 02/80 相机状态（osmocam §8.1）

    private func parseCameraStatus(_ p: Data) {
        guard p.count >= 58 else { return }
        let b = [UInt8](p)
        func u32(_ i: Int) -> Int64 {
            Int64(b[i]) | Int64(b[i+1]) << 8 | Int64(b[i+2]) << 16 | Int64(b[i+3]) << 24
        }
        snapshot.recordState = Int(b[0] >> 6)
        snapshot.isWritingFile = b[2] & 0x08 != 0
        snapshot.mediaMode = b[3] & 0x40 != 0
        snapshot.workMode = Int(b[4])
        // 回放时 5-20 读 0：保留上次非零值
        if u32(5) > 0 { snapshot.totalStorageMB = u32(5) }
        if u32(9) > 0 { snapshot.freeStorageMB = u32(9) }
        if u32(13) > 0 { snapshot.photosLeft = u32(13) }
        if u32(17) > 0 { snapshot.videoSecondsLeft = u32(17) }
        snapshot.clipSeconds = u32(29)
        let mode = b[57]
        if mode != snapshot.captureMode {
            snapshot.captureMode = mode
            onChanged?(snapshot)
            onCaptureModeChanged?(mode)
        }
    }

    // MARK: 0D/02 电池（osmocam §8.2）

    private func parseBattery(_ p: Data) {
        guard p.count >= 21 else { return }
        let b = [UInt8](p)
        func s32(_ i: Int) -> Int {
            Int(Int32(bitPattern:
                UInt32(b[i]) | UInt32(b[i+1]) << 8 | UInt32(b[i+2]) << 16 | UInt32(b[i+3]) << 24))
        }
        snapshot.batteryVoltageMV = s32(1)
        snapshot.batteryCurrentMA = s32(5)
        snapshot.batteryTempDeciC = Int(b[17]) | Int(b[18]) << 8
        snapshot.batteryPercent = Int(b[20])
    }

    // MARK: 02/DC 存储明细（osmocam §8.5）

    private func parseStorage(_ p: Data) {
        guard p.count >= 32 else { return }
        let b = [UInt8](p)
        func u32(_ i: Int) -> Int64 {
            Int64(b[i]) | Int64(b[i+1]) << 8 | Int64(b[i+2]) << 16 | Int64(b[i+3]) << 24
        }
        // 回放时 microSD 字段可能读 0：保留上次非零值
        if u32(6) > 0 { snapshot.sdTotalMB = u32(6) }
        if u32(10) > 0 { snapshot.sdFreeMB = u32(10) }
        if p.count >= 32, u32(24) > 0 { snapshot.internalTotalMB = u32(24) }
        if p.count >= 32, u32(28) > 0 { snapshot.internalFreeMB = u32(28) }
    }

    // MARK: 00/76 固件动作事件（JSON：拍照/录制/延时动作结果，三方无记录）
    // 载荷形如 [长度头][00][{...}]：从首个 '{' 起 JSON 解析（实测 4 种 event_id 均可提取）

    private func parseActionEvent(_ p: Data) {
        guard let start = p.firstIndex(of: UInt8(ascii: "{")),
              let end = p.lastIndex(of: UInt8(ascii: "}")), start < end else { return }
        let obj = try? JSONSerialization.jsonObject(with: Data(p[start...end]))
        guard let dict = obj as? [String: Any],
              let eventID = dict["event_id"] as? String else { return }
        onEvent?(eventID, dict)
    }

    // MARK: 00/99 命名主题推送（osmocam §8.3）
    // 布局：02 06 00 00 <seq u16> 00×5 <rest u16> <nameLen u16> <name> 00×6 <dataLen u16> <data>

    private func parseTopicPush(_ p: Data) {
        guard p.count >= 17 else { return }
        let b = [UInt8](p)
        let nameLen = Int(b[13]) | Int(b[14]) << 8
        guard nameLen > 0, 15 + nameLen + 6 + 2 <= p.count else { return }
        let name = String(bytes: b[15..<15+nameLen], encoding: .utf8) ?? ""
        let dataStart = 15 + nameLen + 6
        let dataLen = Int(b[dataStart]) | Int(b[dataStart+1]) << 8
        let start = dataStart + 2
        guard start + dataLen <= p.count else { return }
        let data = Array(b[start..<start+dataLen])
        // 首次收到任一主题推送时记录（验证订阅生效：20 主题应各出现一次「首见推送」）
        if firstReceipts.insert(name).inserted {
            onLog?("首见推送 \(name)（\(data.count)B）")
        }
        // 临时诊断：cam_expo_param / cam_lapse_param 在 20 主题会话中零推送（其余 18 正常），
        // 逐帧记录以定位是「相机未推」还是「解析丢弃」
        if name == "cam_expo_param" || name == "cam_lapse_param" {
            onLog?("[diag] \(name) 推送 \(data.count)B: \(data.map { String(format: "%02x", $0) }.joined().prefix(40))")
        }
        switch name {
        case "cam_expo_param": parseExpoParam(data)
        case "cam_image_effect": parseImageEffect(data)
        case "cam_lapse_param": parseLapseParam(data)
        case "cam_portrait_mode":
            onLog?("cam_portrait_mode 推送 \(data.count)B: \(data.map { String(format: "%02x", $0) }.joined().prefix(24))")
            if !data.isEmpty { snapshot.portraitMode = data[0] != 0 }
        case "cam_lens_state":
            // lens position u16 @14 ÷ 126 = 变焦倍率（osmo-client zoom_from_lens_state；OA4 单位 126）
            if data.count >= 16 {
                let lens = Int(data[14]) | (Int(data[15]) << 8)
                if lens >= 63, lens <= 1008 {
                    snapshot.zoomFactor = (Double(lens) / 126.0 * 10).rounded() / 10
                }
            }
        case "cam_record_time":
            // u32 秒 @0（2026-11-08 抓包实锤：录制中逐秒递增，39 次变化与启停对齐）
            if data.count >= 4 {
                snapshot.recordSeconds = UInt32(data[0]) | UInt32(data[1]) << 8
                    | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
            }
        case "cam_fov", "shutter_param", "cam_photo_param", "cam_photo_param_new",
             "temp_curve", "camcap_common":
            // 语义未实锤的主题：原始数据段记录（值变化才更新），诊断面板展示供抓包 diff
            recordRawTopic(name, data)
        case "cam_audio_status_v2", "cam_imu_calib_info", "cam_video_param_v2", "cam_storage",
             "cam_status", "cam_custom_mode_params", "cam_magnifier_status",
             "v_quality_enhance_status", "audio_timecode_status", "timecode_info":
            // 语义已明确的录制态/校准类主题（音频电平表、录制时码、容量更新等），
            // 不进未知信号区；具体字段布局待后续抓包 diff，需要时在此接入专有解析
            break
            // 布局未实锤：原始数据段记录（值变化才更新），诊断面板展示供抓包 diff
            recordRawTopic(name, data)
        default:
            if !loggedUnknownTopics.contains(name) {
                loggedUnknownTopics.insert(name)
                onLog?("主题 \(name) 推送 \(data.count)B: \(data.map { String(format: "%02x", $0) }.joined().prefix(28))（未解析，首见记录）")
            }
        }
    }

    /// 未确认布局主题：原始数据段记录到快照（值变化才更新；诊断面板展示，供抓包 diff）
    private func recordRawTopic(_ name: String, _ data: [UInt8]) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        guard snapshot.rawTopicSamples[name] != hex else { return }
        snapshot.rawTopicSamples[name] = hex
        onChanged?(snapshot)
    }

    /// cam_expo_param：ISO u32 @16、快门 u16 @20、EV 补偿 @6、测光 @15（osmocam §8.3）
    private func parseExpoParam(_ d: [UInt8]) {
        guard d.count >= 22 else { return }
        snapshot.effectiveISO = UInt32(d[16]) | UInt32(d[17]) << 8 | UInt32(d[18]) << 16 | UInt32(d[19]) << 24
        snapshot.effectiveShutter = UInt16(d[20]) | UInt16(d[21]) << 8
        snapshot.expoCompValue = d[6]
        snapshot.lightMeterValue = d[15]
    }

    /// cam_image_effect：色彩档位 @2、降噪 s8 @14、锐度 s8 @15（osmocam §8.3）
    private func parseImageEffect(_ d: [UInt8]) {
        guard d.count >= 16 else { return }
        snapshot.colorProfile = d[2]
        snapshot.denoise = Int8(bitPattern: d[14])
        snapshot.sharpness = Int8(bitPattern: d[15])
    }

    /// cam_lapse_param：keep @0、间隔 u16 @1（0.1s）、时长 u32 @5（s）、速度 u16 @9（osmocam §8.3）
    private func parseLapseParam(_ d: [UInt8]) {
        guard d.count >= 11 else { return }
        snapshot.lapseKeep = d[0]
        snapshot.lapseIntervalDeciS = UInt16(d[1]) | UInt16(d[2]) << 8
        snapshot.lapseDurationS = UInt32(d[5]) | UInt32(d[6]) << 8 | UInt32(d[7]) << 16 | UInt32(d[8]) << 24
        snapshot.lapseSpeed = UInt16(d[9]) | UInt16(d[10]) << 8
    }

    // MARK: 查询应答（首字节 = 结果码，00=OK）

    /// 02/19 → `00 <res> <fps> 00 00 <factor>`（osmocam §7.2）
    private func parseVideoFormatReply(_ p: Data) {
        let result = p.first ?? 0xE0
        setQueryError("video_format", result)
        guard result == 0x00, p.count >= 3 else { return }
        let b = [UInt8](p)
        snapshot.videoResolutionCode = b[1]
        snapshot.videoFpsCode = b[2]
    }

    /// 02/1F → `00 <mode> 00`（osmocam §7.1）
    private func parseExposureModeReply(_ p: Data) {
        let result = p.first ?? 0xE0
        setQueryError("exposure_mode", result)
        guard result == 0x00, p.count >= 2 else { return }
        snapshot.exposureMode = [UInt8](p)[1]
    }

    /// 02/2B → `00 <code>`（osmocam §7.1）
    private func parseISOReply(_ p: Data) {
        let result = p.first ?? 0xE0
        setQueryError("iso", result)
        guard result == 0x00, p.count >= 2 else { return }
        snapshot.isoCode = [UInt8](p)[1]
    }

    /// 02/29 → `00 01 <u16> <decimal>`；自动曝光下 DF（osmocam §7.1）
    private func parseShutterReply(_ p: Data) {
        let result = p.first ?? 0xE0
        setQueryError("shutter", result)
        guard result == 0x00, p.count >= 5 else { return }
        let b = [UInt8](p)
        let u16 = UInt16(b[2]) | UInt16(b[3]) << 8
        snapshot.shutterRaw = UInt32(u16) | UInt32(b[4]) << 16
    }

    /// 02/2D 白平衡读取。布局文档未给全：按 `00 <mode> <kelvin/100 u16>` 防御性解析。
    private func parseWBReply(_ p: Data) {
        let result = p.first ?? 0xE0
        setQueryError("wb", result)
        guard result == 0x00, p.count >= 4 else { return }
        let b = [UInt8](p)
        snapshot.wbMode = b[1]
        snapshot.wbKelvin = (Int(b[2]) | Int(b[3]) << 8) * 100
    }

    /// 02/13 照片格式读取 → `00 <size> <ratio>`（仅照片模式；其他模式 DF）
    private func parsePhotoFormatReply(_ p: Data) {
        let result = p.first ?? 0xE0
        setQueryError("photo_format", result)
        guard result == 0x00, p.count >= 3 else { return }
        let b = [UInt8](p)
        snapshot.photoSizeCode = b[1]
        snapshot.photoRatioCode = b[2]
    }

    /// 02/8E 参数读取应答 `00 00 01 <type u16> 01 <value>`（osmo-client parameter_value）；
    /// 写命令的应答仅 1B 结果码。
    private func parseParameterReply(_ p: Data) {
        guard let result = p.first else { return }
        // 成功应答内嵌 pid；负响应单字节无 pid——用链路登记的最近 GET pid 归因（诊断用途）
        let replyPid: UInt16? = (p.count >= 5 && p[1] == 0x00 && p[2] == 0x01)
            ? UInt16(p[3]) | (UInt16(p[4]) << 8) : nil
        let type = replyPid ?? pendingParamType ?? 0xFFFF
        let pidKey = "param-\(String(format: "%04X", type))"
        guard result == 0x00 else {
            setQueryError(pidKey, result)
            return
        }
        snapshot.queryErrors.removeValue(forKey: pidKey)
        snapshot.queryErrors.removeValue(forKey: "param")
        guard p.count >= 7, p[1] == 0x00, p[2] == 0x01 else { return }
        let valLen = Int(p[5])
        if valLen > 0, p.count >= 6 + valLen, !knownParameterPids.contains(type) {
            // 仅语义未明确的 pid 记录原始回读（语义已实锤的进快照专属字段，不进未知区）
            snapshot.rawParams[type] = p[6..<6+valLen].map { String(format: "%02x", $0) }.joined()
        }
        if type == 0x000A, p.count >= 7 {
            if lastParam0A != p[6] {
                onLog?("[diag] pid 000A 翻转 → 0x\(String(p[6], radix: 16))")
                lastParam0A = p[6]
            }
            snapshot.rawParam0A = p[6]
        }
        switch type {
        case OSMOA4.paramFOV: snapshot.fovValue = p[6]
        case OSMOA4.paramEIS: snapshot.eisValue = p[6]
        case OSMOA4.paramISOMax: snapshot.isoMaxCode = p[6]
        case OSMOA4.paramPro: snapshot.proOnCode = p[6]
        case OSMOA4.paramLowLight: snapshot.lowLightCode = p[6]
        case OSMOA4.paramOrientation:
            // 3 字节值 [0, 象限, 0]（2026-11-10 旋转抓包实锤）；象限=逆时针 90° 计数
            if p.count >= 8 { snapshot.orientationCode = p[7] }
        default: break
        }
    }
}
