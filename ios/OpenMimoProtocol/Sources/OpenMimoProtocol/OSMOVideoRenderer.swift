import AVFoundation
import CoreMedia
import VideoToolbox

/// OSMO H.265 AnnexB → AVSampleBufferDisplayLayer（硬解 + 渲染一体）。
///
/// OSMOCameraLink.onVideo 交付的 access unit（AnnexB，参数集已由 FrameAssembler 前缀拼接）
/// → 拆 NALU → 收齐 VPS/SPS/PPS 建 hvcC → CMVideoFormatDescription(HEVC) →
/// AVCC 化 → CMSampleBuffer → layer.enqueue。A12+ 硬解（XS ✓）。
public final class OSMOH265Renderer: NSObject {

    private let lock = NSLock()
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var formatDesc: CMVideoFormatDescription?
    /// 最近一次 SPS 字节（编码器重启后参数集变化 → 重建 format）
    private var lastSPS: Data?
    private var layer: AVSampleBufferDisplayLayer?
    private var frameIndex: Int64 = 0
    /// 当前码流编码尺寸（SPS 解析；竖拍 720x1280 / 横拍 1280x720）
    public private(set) var codedSize: CGSize = .zero
    public private(set) var framesEnqueued = 0
    public private(set) var lastError: String?
    /// 诊断回调（接 StepLogger 用）
    public var onDiag: ((String) -> Void)?
    /// format 因码流参数变化重建后的回调（宿主据此向相机请求新关键帧兜底）
    public var onFormatRebuilt: (() -> Void)?

    private func diag(_ s: String) { onDiag?(s) }

    public func attach(_ layer: AVSampleBufferDisplayLayer) {
        // 不设 controlTimebase：无时基时 enqueue 的 sample 立即渲染（实时流最简路径）
        lock.withLock {
            self.layer = layer
        }
    }

    /// OSMOCameraLink.onVideo 回调直接喂入（任意线程安全）。
    public func feed(annexb: Data) {
        let nalus = splitAnnexB(annexb)
        lock.lock()
        // HEVC NALU type: 32=VPS 33=SPS 34=PPS 35=AUD 39/40=SEI 19/20=IDR
        var sawParams = false
        var containsIDR = false
        for nalu in nalus where nalu.count >= 2 {
            let type = (nalu[nalu.startIndex] >> 1) & 0x3F
            switch type {
            case 32:
                vps = nalu
                sawParams = true
            case 33:
                sps = nalu
                sawParams = true
            case 34:
                pps = nalu
                sawParams = true
            case 19, 20:
                containsIDR = true
            default: break
            }
        }
        // 参数集变化（16:9↔4:3、分辨率切换会重启编码器：新 SPS 与旧 format 不再匹配）。
        // 检测必须先于格式重建：携带新参数集的 AU 同时携带重启后的首个 IDR，必须在该
        // AU 内完成 flush → 重建 → 送帧；若 IDR 被丢弃，后续 P 帧全部不可解（预览冻结，
        // 只能靠进出素材页触发重新注册恢复）。
        if let s = sps, s != lastSPS {
            if lastSPS != nil {
                let dims = Self.parseSPSDims(s).map { "\(Int($0.width))x\(Int($0.height))" } ?? "?"
                diag("[渲染器] SPS 变化（编码器重启，\(dims)）→ flush + 重建 format")
                if Self.parseSPSDims(s) == nil {
                    // 尺寸解析失败：记录 SPS 原始字节，供离线修正解析器
                    let hex = [UInt8](s).prefix(80).map { String(format: "%02x", $0) }.joined()
                    diag("[渲染器] SPS 解析失败 len=\(s.count) hex=\(hex)")
                }
                layer?.flush()
            }
            formatDesc = nil
            lastSPS = s
        }
        if let s = sps, let d = Self.parseSPSDims(s) {
            codedSize = CGSize(width: d.width, height: d.height)
        }
        // 建/重建 format（重建发生在编码器重启后的参数集 AU 内）
        var fireRebuilt = false
        if formatDesc == nil, let v = vps, let s = sps, let p = pps {
            createFormat(vps: v, sps: s, pps: p)
            if framesEnqueued > 0, formatDesc != nil {
                fireRebuilt = true
            }
        }
        guard let desc = formatDesc else {
            lock.unlock()
            return
        }
        // AVCC 化：参数集已进 formatDesc；AUD(35) 剥离，SEI(39/40) 保留
        var avcc = Data()
        for nalu in nalus where nalu.count >= 2 {
            let type = (nalu[nalu.startIndex] >> 1) & 0x3F
            guard type != 35, type != 33, type != 34, type != 32 else { continue }
            var be: UInt32 = UInt32(nalu.count).bigEndian
            avcc.append(contentsOf: withUnsafeBytes(of: &be) { Data($0) })
            avcc += nalu
        }
        if avcc.isEmpty {
            lock.unlock()
            return
        }
        frameIndex += 1
        let idx = frameIndex
        lock.unlock()

        if fireRebuilt {
            diag("[渲染器] format 重建 → 请求关键帧兜底")
            onFormatRebuilt?()
        }
        enqueue(avcc, index: idx, desc: desc, isIDR: containsIDR)
    }

    // MARK: - 内部

    private func createFormat(vps: Data, sps: Data, pps: Data) {
        guard sps.count >= 14 else { return }
        // hvcC（HEVCDecoderConfigurationRecord）：general 部分从 SPS 的 profile_tier_level
        // （NALU 头 2B 之后的 12B）拷贝——社区通用简化，4:2:0 8bit。
        let ptl = sps[sps.startIndex + 2 ..< sps.startIndex + 14]
        var h = Data([0x01])
        h += ptl                                     // space/tier/idc + compat 4B + constraint 6B + level
        h += Data([0xF0, 0x00])                      // reserved + min_spatial_segmentation=0
        h += Data([0xFC])                            // reserved + parallelismType=0
        h += Data([0xFD])                            // reserved + chromaFormat=1 (4:2:0)
        h += Data([0xF8, 0xF8])                      // bitDepthLuma/Chroma=0 (8bit)
        h += Data([0x00, 0x00])                      // avgFrameRate=0
        // constantFrameRate=0, numTemporalLayers=1, temporalIdNested=1, lengthSizeMinusOne=3
        h += Data([0x0F])
        h += Data([0x03])                            // numOfArrays=3
        for (type, nalu) in [(32, vps), (33, sps), (34, pps)] {
            h += Data([0x80 | UInt8(type)])          // array_completeness + NAL_unit_type
            h += Data([0x00, 0x01])                  // numNalus=1
            h += Data([UInt8(nalu.count >> 8), UInt8(nalu.count & 0xFF)])
            h += nalu
        }

        // 实际编码尺寸来自 SPS（竖拍时相机编码 720x1280 而非 1280x720）
        let dims: CGSize
        if codedSize.width > 0 {
            dims = codedSize
        } else if let d = Self.parseSPSDims(sps) {
            dims = CGSize(width: d.width, height: d.height)
        } else {
            dims = CGSize(width: 1280, height: 720)
        }
        codedSize = dims
        var desc: CMVideoFormatDescription?
        let ext: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["hvcC": h],
        ]
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_HEVC,
            width: Int32(dims.width), height: Int32(dims.height), extensions: ext as CFDictionary,
            formatDescriptionOut: &desc)
        guard status == noErr, let desc else {
            lastError = "HEVC formatDesc 失败: \(status)"
            diag(lastError!)
            return
        }
        formatDesc = desc
        diag("[渲染器] HEVC format 创建成功 \(Int(dims.width))x\(Int(dims.height)) (hvcC \(h.count)B)")
    }

    /// HEVC SPS 解析出编码尺寸（pic_width/height_in_luma_samples，exp-golomb）。
    /// 相机竖拍时码流为 720x1280——格式描述必须与实际尺寸一致，否则显示比例错误。
    /// 注意：SPS 按 NALU 原样携带仿真防止字节（00 00 03），解析前必须先剥成 RBSP，
    /// 否则位流错位（4:3 模式 SPS 即因此解析失败）。
    static func parseSPSDims(_ sps: Data) -> (width: Int, height: Int)? {
        let raw = [UInt8](sps)
        guard raw.count >= 22 else { return nil }
        var b: [UInt8] = []
        b.reserveCapacity(raw.count)
        var i = 0
        while i < raw.count {
            if i + 2 < raw.count, raw[i] == 0, raw[i + 1] == 0, raw[i + 2] == 3 {
                b.append(0); b.append(0)
                i += 3
            } else {
                b.append(raw[i])
                i += 1
            }
        }
        guard b.count >= 20 else { return nil }
        var bitPos = 16   // 跳过 NALU 头 2B
        func bit() -> Int? {
            guard bitPos < b.count * 8 else { return nil }
            let v = (b[bitPos / 8] >> (7 - bitPos % 8)) & 1
            bitPos += 1
            return Int(v)
        }
        func bits(_ n: Int) -> Int? {
            var v = 0
            for _ in 0..<n {
                guard let x = bit() else { return nil }
                v = v << 1 | x
            }
            return v
        }
        func ue() -> Int? {
            var zeros = 0
            while true {
                guard let x = bit() else { return nil }
                if x == 1 { break }
                zeros += 1
                if zeros > 32 { return nil }
            }
            var suffix = 0
            for _ in 0..<zeros {
                guard let x = bit() else { return nil }
                suffix = suffix << 1 | x
            }
            return (1 << zeros) - 1 + suffix
        }
        _ = bits(8)          // sps_video_parameter_set_id(4) + max_sub_layers_minus1(3) + nesting(1)
        bitPos += 96         // profile_tier_level（12B，与 hvcC 拷贝段一致）
        guard ue() != nil,   // sps_seq_parameter_set_id
              ue() != nil    // chroma_format_idc（4:2:0 时不带 separate_colour_plane_flag）
        else { return nil }
        guard let w = ue(), let hgt = ue(), w > 0, hgt > 0, w <= 8192, hgt <= 8192 else { return nil }
        return (w, hgt)
    }

    private func enqueue(_ avcc: Data, index: Int64, desc: CMVideoFormatDescription,
                         isIDR: Bool) {
        guard let layer else { return }

        // 背压（崩溃根因①）：解码慢于 25fps 时 CMSampleBuffer 在 layer 内部无限堆积
        // → 内存耗尽 → jetsam 杀进程。非关键帧在 layer 忙时直接丢弃；IDR 必须送
        //（否则后续 P 帧全部不可解），IDR 最多等 0.5s。
        if !layer.isReadyForMoreMediaData {
            if !isIDR { return }
            if lastDropTime.uptimeNanoseconds != 0,
               index - lastDroppedIndex < 15 { return }   // IDR 也要限流：最多 ~0.5s 一次
            lastDroppedIndex = index
        }

        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { return }
        avcc.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
        }
        // 无 B 帧：DTS = PTS（.invalid DTS 对 HEVC inter 帧是未定义行为）
        let ts = CMTime(value: index, timescale: 30)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: ts,
            decodeTimeStamp: ts)
        var sample: CMSampleBuffer?
        var size = avcc.count
        let s2 = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: desc,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard s2 == noErr, let sample else {
            diag("[渲染器] CMSampleBufferCreateReady 失败: \(s2)")
            return
        }
        layer.enqueue(sample)
        framesEnqueued += 1

        // 失败自恢复（崩溃根因②的兜底）：连续失败 → 丢弃 format 重建，
        // 下个参数集 AU 到达时 createFormat 重来
        if layer.status == .failed {
            consecutiveFailures += 1
            if consecutiveFailures <= 2 {
                diag("[渲染器] layer failed: \(layer.error?.localizedDescription ?? "?") → flush")
            }
            layer.flush()
            if consecutiveFailures >= 8 {
                lock.lock()
                formatDesc = nil
                frameIndex = 0
                consecutiveFailures = 0
                lock.unlock()
                diag("[渲染器] 连续失败 8 次，弃置 format 待参数集重建")
            }
        } else {
            consecutiveFailures = 0
        }
    }
    private var consecutiveFailures = 0
    private var lastDropTime = DispatchTime.now()
    private var lastDroppedIndex: Int64 = 0

    /// AnnexB 分割：00 00 01 / 00 00 00 01 start code 之间的 NALU（不含 start code）。
    ///
    /// 注意：不做 trailing-zero 剥离——H.265 slice 合法地以 cabac_zero_words（0x00×2k）
    /// 结尾，剥掉会破坏码流（崩溃根因）。4B start code 时前一 NALU 会多出一个尾随 00，
    /// 这同样等价于一个 cabac_zero_word，解码器接受。
    private func splitAnnexB(_ data: Data) -> [Data] {
        let b = [UInt8](data)
        var marks: [Int] = []   // 0x01 字节的 index（start code 尾字节）
        var i = 0
        while i + 2 < b.count {
            if b[i] == 0, b[i+1] == 0, b[i+2] == 1 {
                marks.append(i + 2)
                i += 3
            } else {
                i += 1
            }
        }
        guard !marks.isEmpty else { return [] }
        var out: [Data] = []
        for (k, m) in marks.enumerated() {
            let naluStart = m + 1
            let end = k + 1 < marks.count ? marks[k + 1] - 2 : b.count   // 回退下一 start code 的 00 00
            guard end > naluStart else { continue }
            out.append(Data(b[naluStart..<end]))
        }
        return out
    }
}
