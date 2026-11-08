import Foundation

// MARK: - 素材文件模型（osmosis MEDIA_PROTOCOL §MediaFile / osmocam §9；OA4 实测布局）

/// 相机媒体文件记录。清单解析为纯函数，golden 样本单测锁定字段布局。
public struct OSMOMediaFile: Identifiable, Equatable {
    /// 测试/离线调试用构造器（--mock-media 离线网格）
    public init(path: String, name: String, ext: String, thumbPath: String?, handle: UInt32,
                sizeBytes: Int64, durationSec: Int, isVideo: Bool, resCode: UInt8, fpsCode: UInt8,
                seq: Int, capturedAt: Date?) {
        self.path = path; self.name = name; self.ext = ext; self.thumbPath = thumbPath
        self.handle = handle; self.sizeBytes = sizeBytes; self.durationSec = durationSec
        self.isVideo = isVideo; self.resCode = resCode; self.fpsCode = fpsCode
        self.seq = seq; self.capturedAt = capturedAt
    }

    /// 媒体路径（无扩展名，DCIM/…）
    public let path: String
    /// 文件名（含扩展名，TLV 0d）
    public let name: String
    /// 大写扩展名（如 MP4/JPG）
    public let ext: String
    /// 缩略图路径（MISC/THM/…，下载时补 .THM）
    public let thumbPath: String?
    /// 删除/翻页句柄（清单 T-10）
    public let handle: UInt32
    public let sizeBytes: Int64
    /// 时长秒（照片为 0）
    public let durationSec: Int
    public let isVideo: Bool
    public let resCode: UInt8
    public let fpsCode: UInt8
    /// 相机文件序号（文件名 _NNNN_ 段）
    public let seq: Int
    /// FAT 打包时间解码（可能偏差 1 小时，文件名携带本地时间）
    public let capturedAt: Date?

    public var id: String { path }

    /// OA4 仅 SD 卡：storage=0；句柄 bit30 置位为内置存储（storage=1，其他机型）
    public var storageIndex: Int { (handle & 0x4000_0000) != 0 ? 1 : 0 }
}

// MARK: - 载荷构造（字节布局以 osmosis MEDIA_PROTOCOL 为准，逐段对照）

public enum OSMOMedia {

    static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    static func appendLE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    /// `00/26` 列表查询载荷（38B，参考载荷 `4a002a10…`）：
    /// @4 counter · @10 cursor · @14 页大小 u16 · @16 清单模式 · @18 仅收藏 ·
    /// @19-26 视频/照片类型掩码 · @37 仅精彩时刻
    public static func listQueryPayload(counter: UInt32, cursor: UInt32, pageSize: UInt8 = 0x2D) -> Data {
        var p = Data([0x4A, 0x00, 0x2A, 0x10])
        appendLE32(&p, counter)
        p.append(contentsOf: [0x00, 0x00])
        appendLE32(&p, cursor)
        p.append(pageSize)
        p.append(0x00)
        p.append(0x0D)      // 全清单
        p.append(0x01)
        p.append(0x00)      // 不过滤收藏
        p.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // 视频掩码：全部
        p.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF]) // 照片掩码：全部
        p.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        p.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        p.append(contentsOf: [0x00, 0x00, 0x00])       // @37 高亮过滤：全部
        return p
    }

    /// `00/26` 分页触发帧（先查 cursor=1 再查页游标，两查询 counter 不同）
    public static var paginationTriggerPayload: Data {
        var p = Data([0x4A, 0x04, 0x0E, 0x10])
        appendLE32(&p, 1)
        p.append(contentsOf: [0x00, 0x00])
        appendLE32(&p, 1)
        return p
    }

    /// `00/28` 删除（应答 0000=成功；同一句柄禁止重复发送）
    public static func deletePayload(handles: [UInt32], counter: UInt32) -> Data {
        var p = Data()
        p.append(UInt8(handles.count))
        for h in handles { appendLE32(&p, h) }
        appendLE32(&p, counter)
        p.append(0x00)
        appendLE32(&p, UInt32(handles.count))
        p.append(contentsOf: [0x01, 0x01, 0x00, 0x00])
        return p
    }

    /// 媒体模式尝试（OA4 以 E0 拒绝，仍按 osmosis 建议先试）
    public static let mediaModeEnterPayload = Data([0x01, 0x01, 0x00, 0x01])

    /// `01/01` 回放脉冲 A（~6 帧 @20Hz）
    public static let playbackPulseA = Data([0x03, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x07, 0x01])
    /// `01/01` 回放脉冲 B（~20Hz 直至 mediaMode 置位）
    public static let playbackPulseB = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x01])

    /// `00/88` 子命令 0x17 维持心跳（14B，'APP' @5-7）
    public static let playbackBeatPayload = Data([
        0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    ])
}

// MARK: - 00/27 分块收集器

/// 收集一次 `00/26` 查询的 `00/27` 分块流：子头 `4A <type> <len u16> <counter u16> <seq u16> 00 00`，
/// type 04=start / 01=data / 03=end。必须（SHALL）按 DUML 命令（00/27）+ counter 过滤——
/// `4A 01` 前缀同时匹配参数推送，仅按前缀过滤会污染清单（osmosis WARNING）。
/// 完整 = 最后数据块（len bit12 置位）及其前全部序号到齐（end 可能先到、会重复发）。
public final class OSMOMediaListCollector {
    private let counter: UInt32
    private var chunks: [UInt16: Data] = [:]
    public private(set) var sawStart = false
    public private(set) var sawEnd = false
    public private(set) var dataBytes = 0
    private var lastSeq: UInt16?

    public init(counter: UInt32) { self.counter = counter }

    /// 返回 true 表示该帧被消费。
    @discardableResult
    public func accept(cmdSet: UInt8, cmdId: UInt8, payload: Data) -> Bool {
        guard cmdSet == 0x00, cmdId == 0x27, payload.count >= 10 else { return false }
        let b = [UInt8](payload)
        guard b[0] == 0x4A else { return false }
        let echoed = UInt16(b[4]) | (UInt16(b[5]) << 8)
        guard echoed == UInt16(truncatingIfNeeded: counter) else { return false }
        let type = b[1]
        let len = Int(b[2]) | (Int(b[3]) << 8)
        let seq = UInt16(b[6]) | (UInt16(b[7]) << 8)
        switch type {
        case 0x04:
            sawStart = true
        case 0x03:
            sawEnd = true
        case 0x01:
            let dataLen = max(0, (len & 0x0FFF) - 10)   // len 含 10B 子头
            let isLast = len & 0x1000 != 0
            chunks[seq] = dataLen > 0 ? Data(b[10..<10 + dataLen]) : Data()
            dataBytes += dataLen
            if isLast { lastSeq = seq }
        default:
            break
        }
        return true
    }

    /// 清单完整（最后数据块及之前全部到齐）。空存储只有 start、无数据，永远不完整。
    public var isComplete: Bool {
        guard let last = lastSeq else { return false }
        for s in 0...last where chunks[UInt16(s)] == nil { return false }
        return true
    }

    /// 存储未挂载/正忙的特征：有 start、无任何数据（osmosis IMPORTANT：查询过早）
    public var isEmptyStream: Bool { sawStart && chunks.isEmpty }

    public var manifest: Data {
        chunks.sorted { $0.key < $1.key }.reduce(into: Data()) { $0.append($1.value) }
    }
}

// MARK: - 清单解码（osmosis decode_manifest 参考实现的 Swift 移植）

public enum OSMOMediaManifest {

    /// 清单是否包含库结尾标记（`0c 01` TLV）
    public static func reachedEnd(_ buf: Data) -> Bool {
        let b = [UInt8](buf)
        guard b.count > 1 else { return false }
        for i in 0..<(b.count - 1) where b[i] == 0x0C && b[i + 1] == 0x01 { return true }
        return false
    }

    public static func decode(_ buf: Data) -> [OSMOMediaFile] {
        let b = [UInt8](buf)

        // 1. 以媒体路径 TLV（1a total 00 00 00 01 <ascii "DCIM/…">）划记录边界。
        //    字段顺序存在两种布局，路径 TLV 定界对两种都不敏感（osmosis WARNING）。
        var medias: [(pos: Int, end: Int, path: String)] = []
        var i = 0
        while i + 6 <= b.count {
            if b[i] == 0x1A, b[i + 2] == 0x00, b[i + 3] == 0x00, b[i + 4] == 0x00, b[i + 5] == 0x01 {
                let total = Int(b[i + 1])
                let slen = total - 6
                if slen > 5, i + 6 + slen <= b.count,
                   let val = String(bytes: b[(i + 6)..<(i + 6 + slen)], encoding: .ascii),
                   val.hasPrefix("DCIM/") {
                    medias.append((i, i + 6 + slen, val))
                    i = i + 6 + slen
                    continue
                }
            }
            i += 1
        }

        // 2. 每条记录在 [前一 path 之后, 下一 path 之前) 内解析
        var files: [OSMOMediaFile] = []
        for k in medias.indices {
            let lo = k == 0 ? 0 : medias[k - 1].end
            let hi = k + 1 < medias.count ? medias[k + 1].pos : b.count
            let path = medias[k].path
            let base = path.split(separator: "/").last.map(String.init) ?? path

            // 扩展名：0d <len> <base.ext>，仅文件名字段带扩展名
            var ext = ""
            var j = lo
            while j < hi - 2 {
                if b[j] == 0x0D {
                    let flen = Int(b[j + 1])
                    if flen > base.count, j + 2 + flen <= hi,
                       Array(b[(j + 2)..<(j + 2 + base.count)]) == Array(base.utf8) {
                        ext = String(bytes: b[(j + 2 + base.count)..<(j + 2 + flen)], encoding: .ascii) ?? ""
                        break
                    }
                }
                j += 1
            }

            // `19 06` 标记锚点：视频 `03 ff 19 06`，照片 `00 [ff|fe|f6|c7|e5|e7] 19 06`，全景 04
            var t = -1
            var typeByte: UInt8 = 0
            var m = lo + 2
            while m + 1 < hi {
                if b[m] == 0x19, b[m + 1] == 0x06, m >= lo + 2 {
                    let t2 = b[m - 2]
                    if t2 == 0x03 || t2 == 0x00 || t2 == 0x04 {
                        t = m
                        typeByte = t2
                        break
                    }
                }
                m += 1
            }

            var handle: UInt32 = 0
            var size: Int64 = 0
            var duration = 0
            var res: UInt8 = 0
            var fps: UInt8 = 0
            var capturedAt: Date? = nil
            if t >= 18 {
                handle = readU32(b, t - 10)
                size = Int64(readU32(b, t - 14))
                duration = Int(readU16(b, t - 6))
                res = b[t - 3]
                fps = b[t - 4]
                capturedAt = Self.fatDate(readU32(b, t - 18))
            }

            // 缩略图路径：1a … 00 00 00 02（MISC/THM/…），仅在本记录范围内找
            var thumb: String? = nil
            j = medias[k].end
            while j < hi - 6 {
                if b[j] == 0x1A, b[j + 2] == 0x00, b[j + 3] == 0x00, b[j + 4] == 0x00, b[j + 5] == 0x02 {
                    let total = Int(b[j + 1])
                    let slen = total - 6
                    if slen > 0, j + 6 + slen <= hi,
                       let val = String(bytes: b[(j + 6)..<(j + 6 + slen)], encoding: .ascii),
                       val.hasPrefix("MISC/") {
                        thumb = val
                        break
                    }
                }
                j += 1
            }

            let extU = ext.hasPrefix(".") ? String(ext.dropFirst()).uppercased() : ext.uppercased()
            let name = extU.isEmpty ? base : "\(base).\(extU)"
            files.append(OSMOMediaFile(
                path: path,
                name: name,
                ext: extU,
                thumbPath: thumb,
                handle: handle,
                sizeBytes: size,
                durationSec: duration,
                isVideo: typeByte == 0x03,
                resCode: res,
                fpsCode: fps,
                seq: Self.fileSeq(base),
                capturedAt: capturedAt,
            ))
        }
        return files
    }

    /// 文件名 `_NNNN_` 段 → 相机文件序号
    static func fileSeq(_ base: String) -> Int {
        let parts = base.split(separator: "_").map(String.init)
        for p in parts where p.count == 4 && p.allSatisfy(\.isNumber) {
            return Int(p) ?? 0
        }
        return 0
    }

    /// FAT/DOS 打包时间（date<<16 | time），2s 分辨率
    static func fatDate(_ v: UInt32) -> Date? {
        let rawDate = v >> 16
        let rawTime = v & 0xFFFF
        let year = Int((rawDate >> 9) & 0x7F) + 1980
        let month = Int((rawDate >> 5) & 0x0F)
        let day = Int(rawDate & 0x1F)
        let hour = Int((rawTime >> 11) & 0x1F)
        let minute = Int((rawTime >> 5) & 0x3F)
        let second = Int((rawTime & 0x1F) * 2)
        guard year > 1980, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return Calendar(identifier: .gregorian).date(from: comps)
    }

    private static func readU32(_ b: [UInt8], _ off: Int) -> UInt32 {
        guard off >= 0, off + 4 <= b.count else { return 0 }
        return UInt32(b[off]) | (UInt32(b[off + 1]) << 8) | (UInt32(b[off + 2]) << 16) | (UInt32(b[off + 3]) << 24)
    }

    private static func readU16(_ b: [UInt8], _ off: Int) -> UInt16 {
        guard off >= 0, off + 2 <= b.count else { return 0 }
        return UInt16(b[off]) | (UInt16(b[off + 1]) << 8)
    }
}
