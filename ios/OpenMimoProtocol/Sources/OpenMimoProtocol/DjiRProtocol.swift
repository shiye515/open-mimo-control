import Foundation

/// DJI R SDK 协议帧（0xAA，BLE 通道；格式见 docs/reference/osmo-gps-controller/protocol_CN.md）：
/// `AA | VerLen(2) | cmdType | enc | res(3) | seq(2 LE) | crc16(2 LE) | cmdSet | cmdId | payload | crc32(4 LE)`
/// CRC16：init 0x3AA3、poly 0xA001(反射)，覆盖 SOF..SEQ 前 10 字节；
/// CRC32：init 0x00003AA3、反射 poly 0xEDB88320、无终态异或，覆盖 SOF..payload。
/// 已用官方文档示例帧（切换运动延时）逐字节验证。
public enum DjiRProtocol {
    public static let sof: UInt8 = 0xAA
    public static let headerLength = 12
    public static let minimumLength = headerLength + 4

    public static func crc16(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0x3AA3
        for b in data {
            crc ^= UInt16(b)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }

    public static func crc32(_ data: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0x0000_3AA3
        for b in data {
            crc ^= UInt32(b)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
            }
        }
        return crc
    }

    public struct Frame: Equatable, Sendable {
        public let cmdType: UInt8
        public let cmdSet: UInt8
        public let cmdId: UInt8
        public let sequence: UInt16
        public let payload: Data
        /// cmdType bit5 = 应答帧标志
        public var isAck: Bool { cmdType & 0x20 != 0 }
    }

    public static func parse(_ data: Data) -> Frame? {
        let b = [UInt8](data)
        guard b.count >= minimumLength, b[0] == sof else { return nil }
        let frameLen = Int(b[1]) | (Int(b[2]) & 0x03) << 8
        guard frameLen == b.count, frameLen >= minimumLength else { return nil }
        let headerCRC = crc16(Array(b[0..<10]))
        guard headerCRC == (UInt16(b[10]) | UInt16(b[11]) << 8) else { return nil }
        let fullCRC = crc32(Array(b[0..<(frameLen - 4)]))
        guard fullCRC == (UInt32(b[frameLen - 4]) | UInt32(b[frameLen - 3]) << 8
            | UInt32(b[frameLen - 2]) << 16 | UInt32(b[frameLen - 1]) << 24) else { return nil }
        return Frame(
            cmdType: b[3],
            cmdSet: b[12],
            cmdId: b[13],
            sequence: UInt16(b[8]) | UInt16(b[9]) << 8,
            payload: Data(b[14..<(frameLen - 4)])
        )
    }

    /// 构造 R 协议命令帧（与官方文档示例帧逐字节一致，见 MimoFixturesTests）。
    public static func buildFrame(cmdType: UInt8, cmdSet: UInt8, cmdId: UInt8,
                                  payload: [UInt8], sequence: UInt16) -> [UInt8] {
        let dataLength = 2 + payload.count
        let frameLength = headerLength + dataLength + 4
        var f: [UInt8] = [sof]
        f.append(UInt8(frameLength & 0xFF))
        f.append(UInt8((frameLength >> 8) & 0x03)) // 版本 0
        f.append(cmdType)
        f.append(0x00) // 不加密
        f.append(contentsOf: [0x00, 0x00, 0x00]) // 保留
        f.append(UInt8(sequence & 0xFF))
        f.append(UInt8(sequence >> 8))
        let h = crc16(Array(f[0..<10]))
        f.append(UInt8(h & 0xFF))
        f.append(UInt8(h >> 8))
        f.append(cmdSet)
        f.append(cmdId)
        f.append(contentsOf: payload)
        let c = crc32(f)
        f.append(UInt8(c & 0xFF))
        f.append(UInt8((c >> 8) & 0xFF))
        f.append(UInt8((c >> 16) & 0xFF))
        f.append(UInt8(c >> 24))
        return f
    }

    // MARK: - 认证与电源命令（BLE 唤醒流程）

    /// 连接请求（CmdSet 0x00 / CmdID 0x19）：controller device_id=1 + 占位 MAC + verifyMode 1（首次配对）。
    /// 官方文档：verify_mode=1 相机弹窗显示 verify_data 校验码，用户确认后进入 pairing；
    /// verify_mode=0 相机查配对历史——第三方手机 MAC 不在历史里会被拒（实测 0x978 后相机零推送）。
    public static func buildConnectionRequest(sequence: UInt16,
                                              controllerDeviceId: UInt32 = 0x0000_0001,
                                              mac: [UInt8] = [0x11, 0x22, 0x33, 0x44, 0x55, 0x66],
                                              verifyMode: UInt8 = 1,
                                              verifyData: UInt16 = 0x1234) -> [UInt8] {
        var payload: [UInt8] = []
        payload.append(UInt8(controllerDeviceId & 0xFF))
        payload.append(UInt8((controllerDeviceId >> 8) & 0xFF))
        payload.append(UInt8((controllerDeviceId >> 16) & 0xFF))
        payload.append(UInt8((controllerDeviceId >> 24) & 0xFF))
        let macBytes = Array(mac.prefix(16))
        payload.append(UInt8(macBytes.count))
        payload.append(contentsOf: macBytes)
        payload.append(contentsOf: [UInt8](repeating: 0x00, count: 16 - macBytes.count))
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // 固件版本占位
        payload.append(0x00) // conidx
        payload.append(verifyMode) // 1=需要校验（首次配对）
        payload.append(UInt8(verifyData & 0xFF))
        payload.append(UInt8(verifyData >> 8))
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        // cmdType=0x02（CMD_WAIT_RESULT）：官方连接请求必须等应答
        return buildFrame(cmdType: 0x02, cmdSet: 0x00, cmdId: 0x19, payload: payload, sequence: sequence)
    }

    /// 连接 ACK（对相机 verifyMode=2 请求的应答）。
    /// 官方文档布局 9B：device_id(4) + ret_code(1)=0 + reserved(4)=相机编号（单机 0）。
    /// sequence 必须回显相机连接请求帧的 seq（官方 connect_logic 用 received_seq）——
    /// 相机按 seq 关联应答；用自增 seq 相机视为未确认，0x1292 加密管线不开启。
    public static func buildConnectionAck(requestSequence: UInt16, cameraDeviceId: UInt32,
                                          cameraIndex: UInt32 = 0) -> [UInt8] {
        let sequence = requestSequence
        var payload: [UInt8] = []
        payload.append(UInt8(cameraDeviceId & 0xFF))
        payload.append(UInt8((cameraDeviceId >> 8) & 0xFF))
        payload.append(UInt8((cameraDeviceId >> 16) & 0xFF))
        payload.append(UInt8((cameraDeviceId >> 24) & 0xFF))
        payload.append(0x00) // ret_code: 0 成功
        payload.append(UInt8(cameraIndex & 0xFF))
        payload.append(UInt8((cameraIndex >> 8) & 0xFF))
        payload.append(UInt8((cameraIndex >> 16) & 0xFF))
        payload.append(UInt8((cameraIndex >> 24) & 0xFF))
        return buildFrame(cmdType: 0x20, cmdSet: 0x00, cmdId: 0x19, payload: payload, sequence: sequence)
    }

    /// 电源模式命令（CmdSet 0x00 / CmdID 0x1A）：0=正常（唤醒，热点开始广播），3=休眠
    public static func buildPowerModeCommand(_ powerMode: UInt8, sequence: UInt16) -> [UInt8] {
        buildFrame(cmdType: 0x01, cmdSet: 0x00, cmdId: 0x1A, payload: [powerMode], sequence: sequence)
    }

    /// 从缓冲扫描一帧（帧长自洽 + 双 CRC 校验），返回消耗后的剩余缓冲。
    public static func scanFrame(from buffer: [UInt8]) -> (frame: Frame, remaining: [UInt8])? {
        guard buffer.count >= 3, buffer[0] == sof else { return nil }
        let frameLen = Int(buffer[1]) | (Int(buffer[2]) & 0x03) << 8
        guard frameLen >= minimumLength, buffer.count >= frameLen else { return nil }
        guard let frame = parse(Data(buffer[0..<frameLen])) else { return nil }
        return (frame, Array(buffer[frameLen...]))
    }
}
