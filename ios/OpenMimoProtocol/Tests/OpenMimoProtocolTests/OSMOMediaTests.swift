import XCTest
@testable import OpenMimoProtocol

/// 素材协议单元测试：
/// - golden：osmosis Oa4ManifestTest 的真实 OA4 清单样本（2026-08-24 测试者会话，6 个文件），
///   字段断言与其 Kotlin 测试一一对应；
/// - 00/27 收集器：乱序、end 先到、counter 过滤、空流；
/// - 分页去重。
final class OSMOMediaTests: XCTestCase {

    private func oa4Manifest() throws -> Data {
        let url = Bundle.module.url(forResource: "oa4_6", withExtension: "bin")!
        return try Data(contentsOf: url)
    }

    // MARK: OA4 golden manifest

    func testOA4GoldenDecode() throws {
        let files = OSMOMediaManifest.decode(try oa4Manifest())
        XCTAssertEqual(files.count, 6)
        XCTAssertEqual(6, Set(files.map(\.path)).count, "every path distinct")
        XCTAssertEqual(files.filter { $0.ext == "MP4" }.count, 4)
        XCTAssertEqual(files.filter { $0.ext == "JPG" }.count, 2)
        XCTAssertTrue(files.allSatisfy { $0.name.hasPrefix("DJI_") })
        XCTAssertTrue(files.allSatisfy { $0.sizeBytes > 0 })
    }

    func testOA4RecordsNewestFirst() throws {
        let files = OSMOMediaManifest.decode(try oa4Manifest())
        XCTAssertEqual(files.map(\.name), [
            "DJI_20260812131032_0006_D.MP4",
            "DJI_20260812130449_0005_D.MP4",
            "DJI_20260812125237_0004_D.MP4",
            "DJI_20260811205805_0003_D.MP4",
            "DJI_20260811205751_0002_D.JPG",
            "DJI_20260810094824_0001_D.JPG",
        ])
        XCTAssertEqual(files.map(\.seq), [6, 5, 4, 3, 2, 1])
    }

    /// OA4 句柄几何：base 0x00040000，步进 0x10（Xtra SD 几何，全部唯一）
    func testOA4HandlesStepped() throws {
        let files = OSMOMediaManifest.decode(try oa4Manifest())
        XCTAssertEqual(6, Set(files.map(\.handle)).count)
        for f in files {
            XCTAssertEqual(UInt32(0x00040000) + UInt32(f.seq) * 0x10, f.handle, f.name)
        }
        let bySeq = Dictionary(uniqueKeysWithValues: files.map { ($0.seq, $0) })
        XCTAssertEqual(bySeq[2]?.handle, 0x00040020)
        XCTAssertEqual(bySeq[1]?.handle, 0x00040010)
        // 照片同样可删（osmosis 回归点：JPG 句柄曾因扫描拒绝被读成 0）
        XCTAssertEqual(files.filter { !$0.isVideo }.count, 2)
        XCTAssertTrue(files.filter { !$0.isVideo }.allSatisfy { $0.handle != 0 })
    }

    /// 超过 Int.MAX 的 2.27GB 视频必须保真（Int 溢出会截断下载）
    func testOA4LargeSizeAndDuration() throws {
        let files = OSMOMediaManifest.decode(try oa4Manifest())
        let big = files.first { $0.seq == 3 }
        XCTAssertNotNil(big)
        XCTAssertEqual(big?.sizeBytes, 2_269_994_910)
        XCTAssertEqual(big?.durationSec, 921)
        XCTAssertTrue(big.map { $0.sizeBytes > Int64(Int32.max) } ?? false)
    }

    func testOA4PerRecordSizeAndDuration() throws {
        let files = OSMOMediaManifest.decode(try oa4Manifest())
        let bySeq = Dictionary(uniqueKeysWithValues: files.map { ($0.seq, $0) })
        XCTAssertEqual(bySeq[6]?.sizeBytes, 276_560_514)
        XCTAssertEqual(bySeq[5]?.sizeBytes, 381_422_703)
        XCTAssertEqual(bySeq[4]?.sizeBytes, 160_212_194)
        XCTAssertEqual(bySeq[2]?.sizeBytes, 4_784_128)
        XCTAssertEqual(bySeq[1]?.sizeBytes, 5_259_264)
        XCTAssertEqual(bySeq[6]?.isVideo, true)
        XCTAssertEqual(bySeq[1]?.isVideo, false)
        XCTAssertTrue(files.allSatisfy { $0.thumbPath?.hasPrefix("MISC/") ?? false })
    }

    // MARK: 00/27 收集器

    private static func chunk(counter: UInt16, seq: UInt16, data: Data, last: Bool) -> Data {
        var p = Data([0x4A, 0x01])
        let len = 10 + data.count
        var lenV = UInt16(len)
        if last { lenV |= 0x1000 }
        p.append(UInt8(lenV & 0xFF)); p.append(UInt8(lenV >> 8))
        p.append(UInt8(counter & 0xFF)); p.append(UInt8(counter >> 8))
        p.append(UInt8(seq & 0xFF)); p.append(UInt16(seq).bigEndian == 0 ? 0 : UInt8((seq >> 8) & 0xFF))
        p.append(contentsOf: [0x00, 0x00])
        p.append(data)
        return p
    }

    private static func control(_ type: UInt8, counter: UInt16) -> Data {
        Data([0x4A, type, 0x0A, 0x00, UInt8(counter & 0xFF), UInt8(counter >> 8), 0x00, 0x00, 0x00, 0x00])
    }

    func testCollectorReassemblesOutOfOrderAndCompletes() {
        let col = OSMOMediaListCollector(counter: 1)
        let payload = Data("hello manifest".utf8)
        let head = payload.prefix(6), tail = payload.dropFirst(6)
        XCTAssertTrue(col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.control(0x04, counter: 1)))
        XCTAssertTrue(col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.chunk(counter: 1, seq: 1, data: Data(tail), last: true)))
        XCTAssertTrue(col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.chunk(counter: 1, seq: 0, data: Data(head), last: false)))
        XCTAssertTrue(col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.control(0x03, counter: 1)))
        XCTAssertTrue(col.isComplete)
        XCTAssertEqual(col.manifest, payload)
        XCTAssertTrue(col.sawEnd)
    }

    func testCollectorFiltersByCounterAndCommand() {
        let col = OSMOMediaListCollector(counter: 2)
        // 其他 counter / 其他命令的 4A 帧不得进入
        XCTAssertFalse(col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.chunk(counter: 1, seq: 0, data: Data([0xAA]), last: false)))
        XCTAssertFalse(col.accept(cmdSet: 0x02, cmdId: 0x80, payload: Self.chunk(counter: 2, seq: 0, data: Data([0xBB]), last: false)))
        XCTAssertTrue(col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.chunk(counter: 2, seq: 0, data: Data([0x01, 0x02]), last: true)))
        XCTAssertTrue(col.isComplete)
        XCTAssertEqual(col.manifest, Data([0x01, 0x02]))
    }

    func testEmptyStreamNeverCompletes() {
        let col = OSMOMediaListCollector(counter: 3)
        col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.control(0x04, counter: 3))
        col.accept(cmdSet: 0x00, cmdId: 0x27, payload: Self.control(0x03, counter: 3))
        XCTAssertFalse(col.isComplete)
        XCTAssertTrue(col.isEmptyStream)
    }

    // MARK: 分页去重 / 载荷

    func testListQueryPayloadLayout() {
        let p = [UInt8](OSMOMedia.listQueryPayload(counter: 1, cursor: 0x0000_0001))
        // 与 osmosis 参考载荷逐字节一致
        XCTAssertEqual(p, Array(hex: "4a002a10010000000000010000002d000d0100ffffffffffffffff000100000000000000000000000000"))
    }

    func testDeletePayloadLayout() {
        let p = [UInt8](OSMOMedia.deletePayload(handles: [0x0004_0480], counter: 1))
        XCTAssertEqual(p, Array(hex: "018004040001000000000100000001010000"))
    }

    func testDedupeByPath() {
        let a = makeFile(path: "DCIM/100MEDIA/DJI_A", name: "DJI_A.MP4", handle: 0x00040010)
        let a2 = makeFile(path: "DCIM/100MEDIA/DJI_A", name: "DJI_A.MP4", handle: 0x00040010)
        let b = makeFile(path: "DCIM/100MEDIA/DJI_B", name: "DJI_B.MP4", handle: 0x00040020)
        let merged = [a] + [a2, b].filter { f in !Set([a.path]).contains(f.path) }
        XCTAssertEqual(merged.map(\.path), [a.path, b.path])
    }

    private func makeFile(path: String, name: String, handle: UInt32) -> OSMOMediaFile {
        OSMOMediaFile(path: path, name: name, ext: "MP4", thumbPath: "MISC/THM/X",
                      handle: handle, sizeBytes: 1, durationSec: 3, isVideo: true,
                      resCode: 0, fpsCode: 0, seq: 1, capturedAt: nil)
    }
}

private func Array(hex s: String) -> [UInt8] {
    var out: [UInt8] = []
    var it = s.makeIterator()
    while let hi = it.next(), let lo = it.next() {
        out.append(UInt8(String([hi, lo]), radix: 16)!)
    }
    return out
}
