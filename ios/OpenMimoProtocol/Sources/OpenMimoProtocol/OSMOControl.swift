import Foundation

/// OSMO 控制命令错误——应答首字节结果码统一映射（osmocam §5.9，specs「控制命令应答与错误统一」）。
public enum OSMOCommandError: Error, LocalizedError {
    case linkDown
    case timeout
    case result(UInt8)   // E0 / E3 / DF / D8 / 其他

    public var errorDescription: String? {
        switch self {
        case .linkDown: "未连接相机"
        case .timeout: "命令超时（相机未应答）"
        case .result(0xE0): "命令不支持（E0）"
        case .result(0xE3): "参数非法或当前状态不允许（E3）"
        case .result(0xDF): "当前不可用（DF，如照片模式下查视频格式）"
        case .result(0xD8): "存储不可用（D8，如未插 SD 卡）"
        case .result(let c): String(format: "命令失败（结果码 0x%02X）", c)
        }
    }
}

/// Osmo Action 4 参数表与控制命令封装（osmo-client camlink/camera.py，OA4 实测验证）。
///
/// 命令集 0x02 → receiver 0x01；OA4 不发布 camcap_* 能力主题（全应答 01），
/// 各模式值域由本表硬编码驱动（design D-ctrl）。
public enum OSMOA4 {

    // MARK: 模式与结果码

    public static let modePhoto: UInt8 = 0x05
    public static let modeVideo: UInt8 = 0x01
    public static let modeSuperNight: UInt8 = 0x28
    public static let modeSlowmo: UInt8 = 0x00
    public static let modeTimelapse: UInt8 = 0x02
    public static let modeHyperlapse: UInt8 = 0x0A

    public static let modeNames: [(code: UInt8, name: String)] = [
        (modePhoto, "照片"), (modeVideo, "视频"), (modeSuperNight, "超级夜景"),
        (modeSlowmo, "慢动作"), (modeTimelapse, "延时摄影"), (modeHyperlapse, "运动延时"),
    ]

    /// 录制命令按模式分派：延时摄影为间隔拍摄，启停走拍照命令 02/01
    /// （02/02 在延时下答 DF）；其余视频类模式用 02/02。
    public static func recordCommand(mode: UInt8) -> UInt8 {
        mode == modeTimelapse ? 0x01 : 0x02
    }

    // MARK: 视频格式（02/18 [res, fps, 00, 00, 慢动作倍速]）

    /// 分辨率码 → 名称
    public static let resolutionNames: [UInt8: String] = [
        0x10: "4K 16:9", 0x2D: "2.7K 16:9", 0x0A: "1080p 16:9",
        0x67: "4K 4:3", 0x5F: "2.7K 4:3",
    ]
    /// 帧率码 → fps
    public static let fpsNames: [UInt8: Int] = [
        1: 24, 2: 25, 3: 30, 4: 48, 5: 50, 6: 60, 7: 120, 8: 240, 0x0A: 100, 0x13: 200,
    ]

    /// 各拍摄模式的可选分辨率（OA4：无 camcap_*，osmo-client ACTION4_FORMATS）
    public static let modeResolutions: [UInt8: [UInt8]] = [
        modeVideo: [0x10, 0x2D, 0x0A, 0x67, 0x5F],
        modeSuperNight: [0x10, 0x2D, 0x0A],
        modeTimelapse: [0x10, 0x2D, 0x0A],
        modeHyperlapse: [0x10, 0x2D, 0x0A],
    ]
    /// 各拍摄模式的可选帧率；fpsByRes 覆盖表对应分辨率的高帧率档
    private static let fast: [UInt8] = [1, 2, 3, 4, 5, 6, 0x0A, 7]
    public static let modeFps: [UInt8: [UInt8]] = [
        modeVideo: [1, 2, 3, 4, 5, 6],
        modeSuperNight: [1, 2, 3],
        modeTimelapse: [2, 3],
        modeHyperlapse: [3],
    ]
    /// 分辨率级帧率覆盖（视频模式）：4K/2.7K 16:9 至 120、1080p 至 240、4K 4:3 至 60
    public static let fpsByResolution: [UInt8: [UInt8]] = [
        0x10: fast, 0x2D: fast, 0x67: [1, 2, 3, 4, 5, 6],
        0x0A: fast + [0x13, 8],
    ]
    /// 当前模式下某分辨率的可选帧率码
    public static func fpsOptions(mode: UInt8, res: UInt8) -> [UInt8] {
        if mode == modeVideo, let byRes = fpsByResolution[res] { return byRes }
        return modeFps[mode] ?? [1, 2, 3]
    }
    /// 慢动作可选档（分辨率, 帧率码, 倍速）
    public static let slowmoFormats: [(res: UInt8, fps: UInt8, factor: UInt8)] = [
        (0x10, 7, 4), (0x2D, 7, 4), (0x0A, 7, 4), (0x0A, 8, 8),
    ]

    /// 视频格式载荷（OA4：慢动作倍速在末字节；非慢动作 factor=0；不携带 aspect 写——OA4 拒绝 E3）
    public static func videoFormatPayload(res: UInt8, fps: UInt8, factor: UInt8 = 0) -> Data {
        Data([res, fps, 0x00, 0x00, factor])
    }

    // MARK: 照片格式（02/12 [size, ratio]，仅照片模式）

    /// OA4 单一尺寸（约 10MP，拒绝 L/M），比例 4:3 / 16:9
    public static let photoFormats: [(size: UInt8, ratio: UInt8, name: String)] = [
        (0, 0, "10MP 4:3"), (0, 1, "10MP 16:9"),
    ]

    // MARK: 曝光

    public static let isoCodes: [(code: UInt8, value: Int)] = [
        (0x03, 100), (0x04, 200), (0x05, 400), (0x06, 800), (0x07, 1600),
        (0x08, 3200), (0x09, 6400), (0x0A, 12800),   // OA4 上限 12800
    ]
    public static let isoName: [UInt8: String] = [0x00: "自动"]

    /// 快门速度表（u16 | 小数<<16；bit15=1 → 1/(u16+小数)，否则为秒值），1/8000s-30s。
    /// 小数字节双粒度（2026-11-10 Mimo 抓包实锤 1/1.67=dec 0x43(0.67)、1/1.25=dec 0x19(0.25)）：
    /// dec ≤9 按十分位（1.3s=0x03），dec ≥10 按百分位（0.67→1/1.67、0.25→1/1.25）
    public static let shutterSpeeds: [UInt32] = [
        0x9F40, 0x9900, 0x9388, 0x8FA0, 0x8C80, 0x89C4, 0x87D0, 0x8640, 0x84E2, 0x83E8,
        0x8320, 0x8280, 0x81F4, 0x8190, 0x8140, 0x80FA, 0x80C8, 0x80A0, 0x807D, 0x8064,
        0x8050, 0x803C, 0x8032, 0x8028, 0x801E, 0x8019, 0x8014, 0x800F, 0x5800C, 0x800A,
        0x8008, 0x8005, 0x8004, 0x8003, 0x58002, 0x8002, 0x438001, 0x198001,
        0x0001, 0x30001, 0x60001, 0x0002,
        0x50002, 0x0003, 0x20003, 0x0004, 0x0005, 0x0006, 0x0007, 0x0008, 0x0009, 0x000A,
        0x000D, 0x000F, 0x0014, 0x0019, 0x001E,
    ]

    /// 小数字节 → 小数（双粒度：≤9 十分位，≥10 百分位）
    static func shutterFraction(_ dec: UInt32) -> Double {
        let d = Double(dec)
        return d >= 10 ? d / 100 : d / 10
    }
    /// 分母格式化：最多两位小数、去尾零（12.5 → "12.5"，1.67 → "1.67"，1.25 → "1.25"）
    static func shutterDenominatorText(_ x: Double) -> String {
        let two = String(format: "%.2f", x)
        return two.hasSuffix("0") ? String(format: "%.1f", x) : two
    }

    /// 快门显示（官方 Mimo 同款）：分数形式 "1/x s"；秒形式 <1s 显示为 1/x，≥1s 显示秒
    public static func shutterText(raw: UInt32) -> String {
        let u16 = UInt16(truncatingIfNeeded: raw)
        let decimal = (raw >> 16) & 0xFF
        if u16 & 0x8000 != 0 {
            let x = Double(u16 & 0x7FFF) + shutterFraction(decimal)
            let txt = x == x.rounded() ? String(Int(x)) : Self.shutterDenominatorText(x)
            return "1/\(txt) s"
        }
        let s = Double(u16) + shutterFraction(decimal)
        if s > 0, s < 1 {
            let inv = 1 / s
            let txt = inv == inv.rounded() ? String(Int(inv)) : Self.shutterDenominatorText(inv)
            return "1/\(txt) s"
        }
        return decimal == 0 ? "\(Int(s)) s" : String(format: "%.1f s", s)
    }

    /// 快门载荷 `02/28 [01, u16 LE, 十分位, 00, 00, 00]`
    public static func shutterPayload(raw: UInt32) -> Data {
        var d = Data([0x01])
        d.append(contentsOf: [UInt8(raw & 0xFF), UInt8((raw >> 8) & 0xFF)])
        d.append(UInt8((raw >> 16) & 0xFF))
        d.append(contentsOf: [0x00, 0x00, 0x00])
        return d
    }

    /// 快门原始码对应的实际曝光时长（秒）；无法解析返回 nil
    public static func shutterSeconds(raw: UInt32) -> Double? {
        let u16 = UInt16(truncatingIfNeeded: raw)
        let v = Double(u16 & 0x7FFF) + shutterFraction((raw >> 16) & 0xFF)
        guard v > 0 else { return nil }
        return u16 & 0x8000 != 0 ? 1 / v : v
    }

    /// 相机 RTC 对时载荷（00/4A → 0x28）：`[年 u16 LE, 月, 日, 时, 分, 秒, 毫秒 u16 LE]`。
    /// 2026-10-19 抓包实锤：`ea070a13133424e001` = 2026-10-19 19:52:36 +480ms（三方无记录）
    public static func cameraClockPayload(date: Date, calendar: Calendar = .current) -> Data {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var d = Data()
        let year = UInt16(truncatingIfNeeded: max(0, c.year ?? 0))
        d.append(contentsOf: [UInt8(year & 0xFF), UInt8(year >> 8)])
        for v in [c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0] {
            d.append(UInt8(truncatingIfNeeded: v))
        }
        let ms = UInt16(truncatingIfNeeded: (c.nanosecond ?? 0) / 1_000_000)
        d.append(contentsOf: [UInt8(ms & 0xFF), UInt8(ms >> 8)])
        return d
    }

    /// EV 补偿：单字节码 07h–19h（十进制 7–25），码 16(10h)=0EV，每码 1/3EV，共 19 档。
    /// 2026-11-09 抓包实锤：SET 序列 08→19h 对应 -2⅔→+3；-3(码07) 为默认值未下发。
    /// 显示枚举：统一一位小数补零（"-3.0"/"+0.0"/"+2.7"），等宽字体右对齐展示
    public static let evSteps: [UInt8] = Array(UInt8(0x07)...UInt8(0x19))
    public static func evName(_ v: UInt8) -> String {
        let thirds = Int(v) - 16          // 码 16 = 0EV
        let sign = thirds < 0 ? "-" : "+"
        let a = abs(thirds)
        let tenth = a % 3 == 1 ? "3" : a % 3 == 2 ? "7" : "0"
        return "\(sign)\(a / 3).\(tenth)"
    }

    // MARK: 白平衡（02/2C [mode, kelvin/100, 00, 00, 00]）

    public static let wbAuto: UInt8 = 0x00
    public static let wbManual: UInt8 = 0x06
    public static let wbKelvins: [Int] = stride(from: 2000, through: 10000, by: 100).map { $0 }
    public static func wbPayload(manual: Bool, kelvin: Int) -> Data {
        Data([manual ? wbManual : wbAuto, UInt8(kelvin / 100), 0x00, 0x00, 0x00])
    }

    // MARK: 色彩 / 锐度 / 降噪

    /// 色彩档位（OA4 实测：仅 普通 与 D-Log M(0x34) 两档）
    public static let colorModes: [(code: UInt8, name: String)] = [
        (0x00, "普通"), (0x34, "D-Log M"),
    ]
    public static let sharpnessRange: [Int8] = [-2, -1, 0, 1, 2]
    public static let denoiseRange: [Int8] = [-2, -1, 0, 1]

    // MARK: 02/8E 参数 TLV（FOV 0x0009 / EIS 0x0008）

    public static let paramFOV: UInt16 = 0x0009
    public static let paramEIS: UInt16 = 0x0008
    /// Pro 模式开关（2026-11-09 官方 Mimo 抓包实锤：SET 01 01 0000 01 01 = 开启，
    /// 唯一 SET 且位于模式切换后/EV 调整前；关闭 val=00 已真机实测）
    public static let paramPro: UInt16 = 0x0000
    /// auto 曝光下的 ISO 上限（同包实锤：SET 序列 07→05→02 对应 12800→1600→200，
    /// 初始回读 val=08=12800；码表比主 ISO 表（03=100）偏移 -2）
    public static let paramISOMax: UInt16 = 0x000F
    /// 弱光增稳开关（2026-11-10 官方 Mimo 抓包实锤：4 次开关操作 → SET 01/00/01/00 交替，
    /// 全程唯一 SET 序列；ACK 单字节 00。仅视频模式）
    public static let paramLowLight: UInt16 = 0x0030
    /// 画面旋转象限（2026-11-10 旋转抓包实锤：顺时针转 90/180/270/360° → 值 3/2/1/0，
    /// 即 3 字节值 [0, 象限, 0]，象限 = 逆时针 90° 计数）。轮询驱动（~1s），无推送
    public static let paramOrientation: UInt16 = 0x0014
    /// 视角（FOV，02/8E 参数 0x0009）。OA4 码表经官方 Mimo 抓包实锤
    /// （zoom-capture-20261108：SET 序列 标准=02 → 广角=01 → 标准=02 → 窄=03，2026-11-08）。
    /// 值域按模式约束：视频模式仅 窄(03) / 标准·畸变校正(02)；其他模式仅 标准·畸变校正(02) / 广角(01)。
    public static let fovModes: [(code: UInt8, name: String)] = [
        (0x00, "超广"), (0x01, "广角"), (0x02, "标准（畸变校正）"), (0x03, "窄"),
    ]
    public static let eisModes: [(code: UInt8, name: String)] = [
        (0x00, "关闭"), (0x01, "超强增稳"), (0x03, "超强增稳+"),
        (0x02, "地平线增稳"), (0x04, "地平矫正"),
    ]
    public static func fovName(_ code: UInt8) -> String? {
        fovModes.first { $0.code == code }?.name
    }
    public static func eisName(_ code: UInt8) -> String? {
        eisModes.first { $0.code == code }?.name
    }
    /// ISO 上限码表（02/8E pid 0x000F；01=100 保留，值域从 200 起）
    public static let isoMaxSteps: [(code: UInt8, name: String)] = [
        (0x02, "200"), (0x03, "400"), (0x04, "800"), (0x05, "1600"),
        (0x06, "3200"), (0x07, "6400"), (0x08, "12800"),
    ]
    public static func isoMaxName(_ code: UInt8) -> String? {
        isoMaxSteps.first { $0.code == code }?.name
    }
    /// 写参数：`01 01 <type u16 LE> 01 <value>`
    public static func parameterSetPayload(type: UInt16, value: UInt8) -> Data {
        Data([0x01, 0x01, UInt8(type & 0xFF), UInt8(type >> 8), 0x01, value])
    }
    /// 读参数：`00 01 <type u16 LE>`（应答 `00 00 01 <type> 01 <value>`，值在 [6]）
    public static func parameterGetPayload(type: UInt16) -> Data {
        Data([0x00, 0x01, UInt8(type & 0xFF), UInt8(type >> 8)])
    }
    public static func parameterValue(reply: Data, type: UInt16) -> UInt8? {
        let b = [UInt8](reply)
        guard b.count >= 7, b[0] == 0x00, b[1] == 0x00, b[2] == 0x01,
              UInt16(b[3]) | (UInt16(b[4]) << 8) == type else { return nil }
        return b[6]
    }

    // MARK: 延时 / 运动延时（02/6C）

    public static let lapseSaveModes: [(code: UInt8, name: String)] = [
        (0x00, "仅视频"), (0x02, "JPEG+视频"), (0x03, "RAW+视频"),
    ]
    /// 延时载荷：`04 00 <save> <间隔 u16 LE, 0.1s> <时长 u32 LE, s> 00×7`
    public static func timelapsePayload(save: UInt8, intervalTenths: UInt16, durationS: UInt32) -> Data {
        var d = Data([0x04, 0x00, save])
        d.append(contentsOf: [UInt8(intervalTenths & 0xFF), UInt8(intervalTenths >> 8)])
        for shift in [0, 8, 16, 24] { d.append(UInt8((durationS >> UInt32(shift)) & 0xFF)) }
        d.append(contentsOf: [UInt8](repeating: 0, count: 7))
        return d
    }
    /// 运动延时速载荷：`0B 00 00 <速度 u16 LE, 0=auto> 00×11`
    public static func hyperlapsePayload(ratio: UInt16) -> Data {
        var d = Data([0x0B, 0x00, 0x00])
        d.append(contentsOf: [UInt8(ratio & 0xFF), UInt8(ratio >> 8)])
        d.append(contentsOf: [UInt8](repeating: 0, count: 11))
        return d
    }
    public static let hyperlapseSpeeds: [UInt16] = [0, 2, 5, 10, 15, 30]
    /// 延时间隔（0.1s 单位）：0.5 / 1 / 2 / 3 / 4 / 5 / 6 / 8 / 10 / 15 / 20 / 25 / 30 / 40 秒
    /// （OA4 实测值域，2026-11-08 修订）
    public static let timelapseIntervalsTenths: [UInt16] = [
        5, 10, 20, 30, 40, 50, 60, 80, 100, 150, 200, 250, 300, 400,
    ]
    /// 延时时长（秒，0=不限）：不限 / 5 / 10 / 20 / 30 / 60 / 120 / 180 / 300 分钟
    public static let timelapseDurationsS: [UInt32] = [
        0, 300, 600, 1200, 1800, 3600, 7200, 10800, 18000,
    ]
}

// MARK: - 控制命令（OSMOCameraLink 扩展；串行化由 UI 层 await 链保证）

public extension OSMOCameraLink {

    // 拍摄

    /// 切换拍摄模式（02/E1；预览暂停 ~1s，成功后链接层自动重查该模式参数）
    func setCaptureMode(_ mode: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0xE1, payload: Data([mode]), timeout: 4)
    }

    /// 数码变焦（02/B8，OA4）。三种形态（官方 Mimo 抓包 zoom-capture-20261108 + osmo-client 实证）：
    /// - `0A 4E <lens u16 LE> 00`：绝对位置，lens = 126 × 倍率（OA4；1.0x=126、2.0x=252、4.0x=504）
    /// - `01 <rate> <1 进 / 0 出> 00`：方向+速率增量变焦，按住期间以 ~10Hz 重复发送，
    ///   rate 为速率档（Mimo 渐进加速用了 0x48/0x49/0x4a 三档）
    /// - `ff 00 00 00`：停止变焦（松手必发）
    /// 倍率回读：cam_lens_state 主题 offset 14 的 u16 lens ÷ 126。

    /// 绝对变焦位置（1.0x–4.0x；档位键用）
    func setZoomPosition(_ factor: Double) async throws {
        let f = min(4.0, max(1.0, factor))
        let lens = Int(round(126.0 * f))
        let v = UInt16(clamping: lens)
        let payload = Data([0x0A, 0x4E, UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), 0x00])
        _ = try await request(cmdSet: 0x02, cmdId: 0xB8, payload: payload, timeout: 2)
    }

    /// 方向增量变焦（捏合按住期间 ~10Hz 重复调用；zoomIn=true 长焦 / false 广角）
    func zoomMove(zoomIn: Bool, rate: UInt8 = 0x4A) {
        send(cmdSet: 0x02, cmdId: 0xB8, payload: Data([0x01, rate, zoomIn ? 1 : 0, 0x00]))
    }

    /// 停止变焦（松手必发，否则相机持续变焦）
    func zoomStop() {
        send(cmdSet: 0x02, cmdId: 0xB8, payload: Data([0xFF, 0x00, 0x00, 0x00]))
    }

    /// 拍照 / 延时启停（02/01；延时摄影的启停也走此命令）
    func takePhoto() async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x01, payload: Data([0x01]), timeout: 4)
    }
    func stopTimelapse() async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x01, payload: Data([0x00]), timeout: 4)
    }

    /// 录制启停（02/02；按模式分派：延时模式走 02/01，osmo-client record_command 同款）
    func setRecord(start: Bool, mode: UInt8) async throws {
        let cmdId = OSMOA4.recordCommand(mode: mode)
        _ = try await request(cmdSet: 0x02, cmdId: cmdId, payload: Data([start ? 0x01 : 0x00]),
                              timeout: 4)
    }

    // 曝光（读侧由 statusTracker 的 02/1F/2B/29 查询与 cam_expo_param 推送覆盖）

    func setExposureMode(auto: Bool) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x1E, payload: Data([auto ? 0x01 : 0x04, 0x00]))
    }
    func setISO(_ code: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x2A, payload: Data([code]))
    }
    func setShutter(raw: UInt32) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x28, payload: OSMOA4.shutterPayload(raw: raw))
    }
    /// EV 补偿（10 + 三分之一档；仅自动曝光）
    func setEV(_ value: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x2E, payload: Data([value]))
    }

    // 白平衡 / 图像

    func setWhiteBalance(manual: Bool, kelvin: Int) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x2C,
                              payload: OSMOA4.wbPayload(manual: manual, kelvin: kelvin))
    }
    func setColorProfile(_ code: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x42, payload: Data([code]))
    }
    func setSharpness(_ v: Int8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x38,
                              payload: Data([UInt8(bitPattern: v)]))
    }
    func setDenoise(_ v: Int8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x44,
                              payload: Data([UInt8(bitPattern: v)]))
    }
    /// FOV / EIS（02/8E 参数 TLV；可能重启编码器）
    func setFOV(_ code: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x8E,
                              payload: OSMOA4.parameterSetPayload(type: OSMOA4.paramFOV, value: code),
                              timeout: 4)
    }
    func setEIS(_ code: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x8E,
                              payload: OSMOA4.parameterSetPayload(type: OSMOA4.paramEIS, value: code),
                              timeout: 4)
    }
    /// 通用参数写（02/8E SET）
    func writeParameter(type: UInt16, value: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x8E,
                              payload: OSMOA4.parameterSetPayload(type: type, value: value),
                              timeout: 4)
    }
    /// Pro 模式开关（02/8E pid 0x0000；01 开 / 00 关）
    func setPro(_ enabled: Bool) async throws {
        try await writeParameter(type: OSMOA4.paramPro, value: enabled ? 0x01 : 0x00)
    }
    /// ISO 上限（02/8E pid 0x000F，仅自动曝光下有意义）
    func setISOMax(_ code: UInt8) async throws {
        try await writeParameter(type: OSMOA4.paramISOMax, value: code)
    }
    /// 弱光增稳（02/8E pid 0x0030；01 开 / 00 关，仅视频模式）
    func setLowLight(_ enabled: Bool) async throws {
        try await writeParameter(type: OSMOA4.paramLowLight, value: enabled ? 0x01 : 0x00)
    }
    /// 读回 02/8E 参数（FOV/EIS 当前值；应答值在 [6]）
    func readParameter(type: UInt16) async throws -> UInt8? {
        let reply = try await request(cmdSet: 0x02, cmdId: 0x8E,
                                      payload: OSMOA4.parameterGetPayload(type: type))
        return OSMOA4.parameterValue(reply: reply, type: type)
    }

    // 格式

    /// 视频格式（02/18；OA4 拒绝 aspect 单独写，格式命令单独发送；编码器重启 2-5s）
    func setVideoFormat(res: UInt8, fps: UInt8, factor: UInt8 = 0) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x18,
                              payload: OSMOA4.videoFormatPayload(res: res, fps: fps, factor: factor),
                              timeout: 6)
    }
    /// 照片格式（02/12 [size, ratio]；仅照片模式）
    func setPhotoFormat(size: UInt8, ratio: UInt8) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x12, payload: Data([size, ratio]))
    }

    /// 相机 RTC 对时（00/4A → 0x28；连接成功后调用一次，相机 RTC 断电保持）
    func setCameraClock(date: Date) async throws {
        _ = try await request(cmdSet: 0x00, cmdId: 0x4A,
                              payload: OSMOA4.cameraClockPayload(date: date),
                              receiver: 0x28)
    }

    /// 拍照倒计时（02/4A；载荷 [00 01, 秒 u16 LE, 毫秒 u16 LE]，0/0=关闭。
    /// 2026-11-10 官方 Mimo 抓包实锤：关闭/0.5s/1s/2s/3s/5s/10s/关闭 序列 8 帧，
    /// 载荷 0s+500ms=0.5s、1s+0ms=1s…，全部 ACK 单字节 00；无 GET 回读形态观测）
    func setCountdown(seconds: UInt16, millis: UInt16) async throws {
        var p = Data([0x00, 0x01])
        p.append(contentsOf: [UInt8(seconds & 0xFF), UInt8(seconds >> 8)])
        p.append(contentsOf: [UInt8(millis & 0xFF), UInt8(millis >> 8)])
        _ = try await request(cmdSet: 0x02, cmdId: 0x4A, payload: p)
    }

    // 延时 / 运动延时

    /// 延时参数（02/6C timelapse 形；save/间隔/时长，其余保持相机现值由回读校准）
    func setTimelapse(save: UInt8, intervalTenths: UInt16, durationS: UInt32) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x6C,
                              payload: OSMOA4.timelapsePayload(save: save, intervalTenths: intervalTenths,
                                                               durationS: durationS))
    }
    /// 运动延时速度（02/6C hyperlapse 形；0=自动）
    func setHyperlapseSpeed(_ ratio: UInt16) async throws {
        _ = try await request(cmdSet: 0x02, cmdId: 0x6C,
                              payload: OSMOA4.hyperlapsePayload(ratio: ratio))
    }
}
