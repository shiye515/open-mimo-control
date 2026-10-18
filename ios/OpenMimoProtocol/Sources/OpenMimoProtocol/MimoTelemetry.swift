import Foundation

/// 遥测推送解析结果（docs/protocol/telemetry.md §2）：body 内嵌主题名与值。
public struct TelemetryPush: Equatable, Sendable {
    public let topic: String
    public let value: Data
}

public enum MimoTelemetry {
    /// 从推送帧 payload 提取 `[nameLen(2 BE)] 00 [name] …值` 形态的主题推送。
    /// 仅接受长度自洽的 ASCII 主题名（小写字母/数字/下划线）。
    public static func parsePush(_ frame: MimoFrame) -> TelemetryPush? {
        let bytes = [UInt8](frame.payload)
        var i = 0
        while i < bytes.count - 3 {
            let nameLen = Int(bytes[i]) << 8 | Int(bytes[i + 1])
            guard nameLen >= 5, nameLen <= 40,
                  bytes[i + 2] == 0x00,
                  i + 3 + nameLen <= bytes.count
            else { i += 1; continue }
            let nameBytes = bytes[(i + 3)..<(i + 3 + nameLen)]
            guard nameBytes.allSatisfy({ $0 == 0x5F || (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) })
            else { i += 1; continue }
            let topic = String(bytes: nameBytes, encoding: .utf8) ?? ""
            let value = Data(bytes[(i + 3 + nameLen)...])
            return TelemetryPush(topic: topic, value: value)
        }
        return nil
    }
}

/// cam_status 值（9B：`55 [mode] [target] 00 [zoomIdx] [state] 00`，telemetry.md §4）。
public struct CameraStatus: Equatable, Sendable {
    public let mode: UInt8
    public let targetMode: UInt8
    public let zoomIndex: UInt8
    public let state: UInt8

    public init?(value: Data) {
        let b = [UInt8](value)
        guard b.count >= 7, b[0] == 0x55, b[3] == 0x00, b[6] == 0x00 else { return nil }
        mode = b[1]
        targetMode = b[2]
        zoomIndex = b[4]
        state = b[5]
    }

    /// 子状态语义（观测值，telemetry.md §4）
    public enum State: Equatable {
        case idle, preview, switching, recording, other(UInt8)

        public init(_ raw: UInt8) {
            switch raw {
            case 0x00: self = .idle
            case 0x01: self = .preview
            case 0x02: self = .switching
            case 0x03: self = .recording
            case let raw: self = .other(raw)
            }
        }
    }

    public var stateKind: State { State(state) }
}

/// cam_fov 值：等效焦距 ×100（mm，u32 LE），如 0x096D=2413（24.13mm ≈ 1.0x）。
public struct CameraFOV: Equatable, Sendable {
    public let focalLengthX100: UInt32

    /// 变焦倍率（以 24.13mm 为 1.0x 基准，四舍五入到 0.1）。
    public var zoomFactor: Double {
        let base = 2413.0
        return (Double(focalLengthX100) / base * 10).rounded() / 10
    }

    public init?(value: Data) {
        let b = [UInt8](value)
        guard b.count >= 4 else { return nil }
        focalLengthX100 = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
    }
}

/// (0x02,0x80) 相机设备状态推送（~60B，会话建立后相机主动推、无需订阅；BLE 与 UDP 同构）。
/// 布局（2026-10-28 实测）：`[01][02][80][00 00]` + cam_storage 三元组 @5/9/13
/// （total_mb / free_mb / remain_photo，u32 LE）+ 尾部 `55` 起的 cam_status 形态块；电量不在其中。
public struct CameraDeviceState: Equatable, Sendable {
    public let totalMB: Int
    public let freeMB: Int
    public let remainPhotoCount: Int

    public init?(value: Data) {
        let b = [UInt8](value)
        guard b.count >= 17 else { return nil }
        func u32(_ o: Int) -> Int {
            Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        totalMB = u32(5)
        freeMB = u32(9)
        remainPhotoCount = u32(13)
    }
}

/// 官方遥控器 1D02 相机状态推送（38B，docs/reference/osmo-gps-controller/protocol_data_segment_CN.md）。
/// 备选遥测路径：通道上发 (0x40,0x1D,0x05) 订阅（push_mode=3 周期+变化，push_freq=20=2Hz）后，
/// 相机以 (0x1D,0x02) 周期推送。**这是唯一已知含电量百分比（@37）的状态结构**——
/// WiFi 主题空间（48 个 cam_* 主题）与 pcap 全程均无电量主题，Mimo 的电量显示不走主题订阅。
public struct CameraStatusV2: Equatable, Sendable {
    public let mode: UInt8              // @0  camera_mode（值域同 CameraMode + 扩展）
    public let cameraState: UInt8       // @1  camera_status（0 屏幕关/1 直播/2 回放/3 拍摄中/5 预录制）
    public let resolution: UInt8        // @2  video_resolution（10=1080P 16=4K 45=2.7K…）
    public let fpsIndex: UInt8          // @3  fps_idx
    public let eisMode: UInt8           // @4  EIS_mode
    public let recordTime: Int          // @5  u16 LE 秒
    public let remainCapacityMB: Int    // @15 u32 LE SD 剩余 MB
    public let remainPhotoCount: Int    // @19 u32 LE
    public let remainRecordSeconds: Int // @23 u32 LE
    public let userMode: UInt8          // @27
    public let powerMode: UInt8         // @28 0 正常 / 3 休眠
    public let tempOver: UInt8          // @30 0 正常 / 1 警告 / 2 不可录 / 3 将关机
    public let batteryPercent: Int      // @37 camera_bat_percentage 0~100

    public init?(value: Data) {
        let b = [UInt8](value)
        guard b.count >= 38 else { return nil }
        mode = b[0]
        cameraState = b[1]
        resolution = b[2]
        fpsIndex = b[3]
        eisMode = b[4]
        recordTime = Int(b[5]) | Int(b[6]) << 8
        remainCapacityMB = Int(b[15]) | Int(b[16]) << 8 | Int(b[17]) << 16 | Int(b[18]) << 24
        remainPhotoCount = Int(b[19]) | Int(b[20]) << 8 | Int(b[21]) << 16 | Int(b[22]) << 24
        remainRecordSeconds = Int(b[23]) | Int(b[24]) << 8 | Int(b[25]) << 16 | Int(b[26]) << 24
        userMode = b[27]
        powerMode = b[28]
        tempOver = b[30]
        batteryPercent = Int(b[37])
    }
}
