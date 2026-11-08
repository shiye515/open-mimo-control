import XCTest
@testable import OpenMimoProtocol

/// 实时预览解封装测试（fixture 来自 docs/protocol/mimo-ios.pcap 19:52:35.5 真实视频流）。
final class LiveViewDepacketizerTests: XCTestCase {

    /// 真实帧 0x0d：三片（首/续/末）→ 重组出一帧密文；内嵌控制帧被剥离回调。
    func testReassembleThreeFragmentFrame() throws {
        var dep = makeDepacketizer()
        var frame: LiveViewDepacketizer.Frame?

        // 首片（含 15B 子头 + 内嵌 cam_storage 推送帧,截自真实包前 130B + 补齐载荷）
        let frag0 = Data(hex(
            "0d840000" // 注意：测试里直接从业务头 [16] 起
        ))
        // 直接构造三片（[16:] 起，模拟已剥 20B 业务头前的部分——ingest 从 b[16] 读）
        // 首片: [16]=0d [17]=04 [18:20]=0000 [20:24]=000001ff + 11B 子头尾 + 密文
        var f0 = Data([0x0d, 0x04, 0x00, 0x00])
        f0 += Data(hex("000001ff521100000c11a000"))        // 12B 子头前段
        f0 += Data(hex("00000000" + "010201d0"))           // 8B 子头尾
        f0 += Data(repeating: 0xAB, count: 50)             // 密文占位
        // 续片
        var f1 = Data([0x0d, 0x84, 0x00, 0x00])
        f1 += Data(repeating: 0xCD, count: 40)
        // 末片（[18]=00 [19]=01 末片标志）
        var f2 = Data([0x0d, 0x04, 0x00, 0x01])
        f2 += Data(repeating: 0xEF, count: 30)

        XCTAssertNil(try dep.ingest(pad(f0)))
        XCTAssertNil(try dep.ingest(pad(f1)))
        frame = try dep.ingest(pad(f2))

        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.frameNumber, 0x0d)
        // 50+40+30 密文
        XCTAssertEqual(frame?.payload.count, 120)
        // PassthroughDecryptor 不改内容
        XCTAssertEqual(frame?.payload.prefix(50), Data(repeating: 0xAB, count: 50))
    }

    /// 单片帧（1 片，无末片标志）靠帧号推进冲刷。
    func testSingleFragmentFrame() throws {
        var dep = makeDepacketizer()
        var f = Data([0x2a, 0x02, 0x00, 0x00])
        f += Data(hex("000001ff0a1400000c11fd00" + "00000000" + "010201d0"))
        f += Data(repeating: 0x11, count: 64)
        XCTAssertNil(try dep.ingest(pad(f))) // 首包：暂存待冲刷
        // 下一帧号包推进 → 冲刷 0x2a
        var next = Data([0x2b, 0x02, 0x00, 0x00])
        next += Data(hex("000001ff0a1400000c11fd00" + "00000000" + "010201d0"))
        next += Data(repeating: 0x22, count: 16)
        let frame = try dep.ingest(pad(next))
        XCTAssertEqual(frame?.frameNumber, 0x2a)
        XCTAssertEqual(frame?.payload.count, 64)
    }

    /// NALU 探测：AnnexB 起始码切分。
    func testNaluDetection() {
        // SPS(0x67) + PPS(0x68) + IDR(0x65)
        var data = Data(hex("0000000167" + "112233"))
        data += Data(hex("0000000168" + "4455"))
        data += Data(hex("0000000165" + "66778899"))
        let ranges = LiveViewDepacketizer.nalus(in: data)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(data[ranges[0]].first, 0x67)
        XCTAssertEqual(data[ranges[1]].first, 0x68)
        XCTAssertEqual(data[ranges[2]].first, 0x65)
    }

    /// 超窗口未完成帧被清理（丢帧不死锁）。
    func testFrameWindowCleanup() throws {
        var dep = makeDepacketizer()
        // 喂 40 个无末片的帧
        for i in 0..<40 {
            var f = Data([UInt8(i), 0x02, 0x00, 0x00])
            f += Data(hex("000001ff010200000c110100" + "00000000" + "010201d0"))
            f += Data(repeating: UInt8(i), count: 16)
            _ = try dep.ingest(pad(f))
        }
        // 帧号回到 0x05（已存在）再给末片 → 应能出帧（窗口清理后重建）
        var f = Data([0x05, 0x02, 0x00, 0x00])
        f += Data(hex("000001ff010200000c110100" + "00000000" + "010201d0"))
        f += Data(repeating: 0x05, count: 16)
        f[19] = 0x01
        let frame = try dep.ingest(pad(f))
        XCTAssertNotNil(frame)
    }

    // MARK: - 辅助

    private func makeDepacketizer() -> LiveViewDepacketizer {
        LiveViewDepacketizer(decryptor: LiveViewDepacketizer.PassthroughDecryptor())
    }

    /// 前补 20B 业务头（ingest 从字节 16 读帧号，前 16B 随意）。
    private func pad(_ frag: Data) -> Data {
        Data(repeating: 0, count: 16) + frag
    }

    private func hex(_ s: String) -> [UInt8] {
        var bytes: [UInt8] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
            if let b = UInt8(s[idx..<next], radix: 16) { bytes.append(b) }
            idx = next
        }
        return bytes
    }
}
