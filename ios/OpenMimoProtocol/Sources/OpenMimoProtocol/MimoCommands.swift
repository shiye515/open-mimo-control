import Foundation

/// 拍摄模式（权威定义：DJI 官方 Osmo GPS Controller Demo 文档 1D02/1D04，
/// 见 docs/reference/osmo-gps-controller/protocol_data_segment_CN.md）
public enum CameraMode: UInt8, Sendable, CaseIterable {
    case slowMotion = 0x00   // 慢动作
    case video = 0x01        // 视频
    case timelapse = 0x02    // 延时摄影
    case photo = 0x05        // 照片
    case hyperlapse = 0x0A   // 运动延时
    case live = 0x1A         // 直播（本应用暂不启用其推流）
}

/// 命令构造器（docs/protocol/control-channel.md §4/§5，DUML 布局）。
/// 命令空间与 APK 静态分析三元组 (ver, CmdSet, CmdId) 一一对应。
public enum MimoCommand {
    /// cmdType：0x40 = 请求帧（需应答）
    static let request: UInt8 = 0x40

    // ---- 已证实命令（samples/ fixture 与 CRC 双重验证）----

    /// 模式切换：CmdSet 0x02 / CmdId 0xE1，payload [mode]（= 静态分析 (1,2,225) set_mode_profile）
    public static func modeSwitch(_ mode: CameraMode, sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x01, sequence: sequence, cmdType: request,
                  cmdSet: 0x02, cmdId: 0xE1, payload: Data([mode.rawValue]))
    }

    /// 录制开始：CmdSet 0x02 / CmdId 0x02，payload [0x00]（= 静态分析 (1,2,2) record_video；
    /// payload 语义同官方 1D03：0=开始，1=停止）
    public static func recordStart(sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x01, sequence: sequence, cmdType: request,
                  cmdSet: 0x02, cmdId: 0x02, payload: Data([0x00]))
    }

    /// 录制停止：payload [0x01]（官方 1D03：1=停止拍录；真机验证待补）
    public static func recordStop(sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x01, sequence: sequence, cmdType: request,
                  cmdSet: 0x02, cmdId: 0x02, payload: Data([0x01]))
    }

    /// 按主题名订阅：CmdSet 0x00 / CmdId 0x99（= 静态分析 (1,0,153) united_pub_sub_agent）
    /// payload = `02 02 00 00 | reqId(2 LE) | 00 00 00 00 | total(2 BE)=name.count+6 | nameLen(2 BE) | 00 | name | 00 00 00 00`
    public static func subscribe(topic: String, requestID: UInt16, sequence: UInt16) -> MimoFrame {
        let name = Data(topic.utf8)
        var payload = Data([0x02, 0x02, 0x00, 0x00])
        payload.append(UInt8(requestID & 0xFF))
        payload.append(UInt8(requestID >> 8))
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        payload.append(UInt8((name.count + 6) >> 8))
        payload.append(UInt8((name.count + 6) & 0xFF))
        payload.append(UInt8(name.count >> 8))
        payload.append(UInt8(name.count & 0xFF))
        payload.append(0x00)
        payload.append(name)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return MimoFrame(sender: 0x02, receiver: 0x28, sequence: sequence, cmdType: request,
                         cmdSet: 0x00, cmdId: 0x99, payload: payload)
    }

    // ---- 周期性帧（已证实形态；官方 App 以此组合作保活，抓包 §4.4）----

    /// 轮询 1（~1s）：(0x40, 0x00, 0x51) payload [0x04]，dst=0x48
    public static func statusPoll(sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x48, sequence: sequence, cmdType: request,
                  cmdSet: 0x00, cmdId: 0x51, payload: Data([0x04]))
    }

    /// 轮询 2（~1s）：(0x80, 0x00, 0x82) 空 payload，dst=0x48
    public static func statusPoll2(sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x48, sequence: sequence, cmdType: 0x80,
                  cmdSet: 0x00, cmdId: 0x82, payload: Data())
    }

    /// 轮询 3（~4s）：(0xC0, 0x00, 0x00) 空 payload，dst=0x28
    public static func statusPoll3(sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x28, sequence: sequence, cmdType: 0xC0,
                  cmdSet: 0x00, cmdId: 0x00, payload: Data())
    }

    /// 连接握手首帧（抓包 19:52:35.451 原样；完整握手序列见 control-channel.md §5）
    public static func handshakeIntro(sequence: UInt16) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0xF0, sequence: sequence, cmdType: request,
                  cmdSet: 0x00, cmdId: 0x2B, payload: Data([0x04, 0x00]))
    }

    /// 实时预览传输控制（pcap 54.69s 实证：视频大包开始前 120ms 首发，共 2 次；
    /// 对应 native `dji_ofdm_set_liveview_transmit_ctrl_rsp` / `core22liveview_transmit_ctrl`）。
    /// payload 前 4B `0000794c` 恒定，后 2B 两次观测为 95ac/1f00（参数或 seq，语义未定）。
    public static func liveViewTransmitCtrl(sequence: UInt16, param: UInt16 = 0x95ac) -> MimoFrame {
        MimoFrame(sender: 0x02, receiver: 0x1C, sequence: sequence, cmdType: request,
                  cmdSet: 0xEE, cmdId: 0x2F,
                  payload: Data([0x00, 0x00, 0x79, 0x4C,
                                 UInt8(param >> 8), UInt8(param & 0xFF)]))
    }

    /// 预览参数帧 (0x40,0x00,0x74) dst=0x28（pcap 54.786s 实测 213B，逐字节重放）。
    /// 内容 = 24B 头 + 6 个 wtm TLV 条目（tag 0x6d74 97xx/9axx 家族）。
    /// 静态重放：单次抓包无从分辨随时间变化字段；若相机校验时间类字段需后续按规则生成。
        public static func liveViewParams(sequence: UInt16) -> MimoFrame {
        // Mimo 原始 (00,74) 载荷 202B（pcap #461 逐字节回放；含 native 指针，相机可能只解析非指针字段）
        let payload = Self.hx("""
210000010000000048d7686f01000000050000000000000048d7686f01000000a8b29e40000c0000\
300100000000000080db9b5c01000000d300f56cc37f95b1e8d6686f01000000d8dc9b5c01000000\
30d7686f0100000060bb7a020100000080d4d25201000000b03b9a0a01000000b0725103010000\
00ff000000000000000000000000000000d300f56cc37f95b180da686f01000000a8da686f0100\
000080da686f0100000098d7686f0100000060d7686f01000000dcb67a02010000000600000001\
0000005124
""")
        return MimoFrame(sender: 0x02, receiver: 0x28, sequence: sequence, cmdType: request,
                         cmdSet: 0x00, cmdId: 0x74, payload: payload)
    }
    
    private static func hx(_ hex: String) -> Data {
        var bytes: [UInt8] = []
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return Data(bytes)
    }
}
