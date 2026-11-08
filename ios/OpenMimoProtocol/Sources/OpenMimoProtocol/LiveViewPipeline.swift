import Foundation
import VideoToolbox
import CoreVideo

/// 实时预览解码管线（tasks 5.2）：解封装帧 → VideoToolbox 硬解 → CVPixelBuffer 回调。
///
/// 密钥未解前（VideoDecrypting = PassthroughDecryptor），密文帧不含合法 NALU，
/// 解码器不启动——管线就绪等密钥，UI 可先行接入（显示"等待解密"状态）。
/// 拿到明文 H.264/H.265 AnnexB 流后：SPS/PPS → format description → VTDecompressionSession。
public actor LiveViewPipeline {

    public enum State: Equatable {
        case idle          // 无流
        case waitingKey    // 收到密文帧但无法解密
        case decoding      // 解码运行中
        case failed(String)
    }

    public private(set) var state: State = .idle
    public private(set) var framesReceived = 0
    public private(set) var nalusDetected = 0
    public var framesDecoded: Int { decodedCount.current }

    private var depacketizer: LiveViewDepacketizer
    private var session: VTDecompressionSession?
    private var formatDesc: CMVideoFormatDescription?
    /// 解码回调（UI/渲染层订阅）
    private var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    public init(decryptor: LiveViewDepacketizer.VideoDecrypting = LiveViewDepacketizer.PassthroughDecryptor()) {
        self.depacketizer = LiveViewDepacketizer(decryptor: decryptor)
    }

    public func setPixelBufferHandler(_ handler: @escaping (CVPixelBuffer) -> Void) {
        onPixelBufferBox.set(handler)
    }

    /// 喂入 S2C 大包（CameraSession 入站流分流而来）。
    /// 返回：本包剥离出的内嵌控制帧（交还会话层解析遥测）。
    public func ingest(_ packet: Data) -> [MimoFrame] {
        var controls: [MimoFrame] = []
        var frame: LiveViewDepacketizer.Frame?
        do {
            frame = try depacketizer.ingest(packet) { controls.append($0) }
        } catch {
            state = .failed("depacketize: \(error.localizedDescription)")
            return controls
        }
        guard let frame else { return controls }
        framesReceived += 1

        let nalus = LiveViewDepacketizer.nalus(in: frame.payload)
        guard !nalus.isEmpty else {
            if state != .waitingKey {
                state = .waitingKey // 密文帧（无 NALU 结构）
            }
            return controls
        }
        nalusDetected += nalus.count
        decode(frame.payload)
        return controls
    }

    /// H.264 AnnexB → VideoToolbox。首见 SPS/PPS 建 format description。
    private func decode(_ annexb: Data) {
        // 参数集提取（SPS=0x67/0x27, PPS=0x68/0x28 的 NALU 头字节）
        let nalus = LiveViewDepacketizer.nalus(in: annexb)
        var sps: Data?
        var pps: Data?
        for r in nalus where !r.isEmpty {
            let naluType = annexb[r.lowerBound] & 0x1F
            if naluType == 7 { sps = annexb[r.lowerBound - 4..<r.upperBound] }
            if naluType == 8 { pps = annexb[r.lowerBound - 4..<r.upperBound] }
        }
        if let sps, let pps, session == nil {
            createSession(sps: sps, pps: pps)
        }
        guard session != nil else { return }

        for r in nalus where !r.isEmpty {
            let naluType = annexb[r.lowerBound] & 0x1F
            guard naluType != 7, naluType != 8 else { continue } // 参数集不送解码
            // AnnexB → AVCC（4B 长度前缀）
            var avcc = Data([0, 0, 0, UInt8(r.count)])
            avcc += annexb[r]
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: avcc.count,
                blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
                let block else { continue }
            _ = avcc.withUnsafeBytes { raw in
                CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: avcc.count)
            }
            var sampleSize = avcc.count
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime.invalid,
                                            presentationTimeStamp: CMTime.invalid,
                                            decodeTimeStamp: CMTime.invalid)
            guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block,
                                            formatDescription: formatDesc, sampleCount: 1,
                                            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
                                            sampleBufferOut: &sample) == noErr,
                  let sample else { continue }
            let flags = VTDecodeFrameFlags()
            VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample,
                                              flags: flags, frameRefcon: nil,
                                              infoFlagsOut: nil)
        }
    }

    private func createSession(sps: Data, pps: Data) {
        var desc: CMVideoFormatDescription?
        // 参数集经 extensions 传入（CMVideoFormatDescriptionCreate 无 parameterSet 参数，
        // 用 SampleDescriptionExtensionAtoms 携带 avcC）
        let avcC = makeAVCC(sps: sps, pps: pps)
        let extensions: [String: Any] = [
            kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: [
                "avcC": avcC,
            ],
        ]
        guard CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_H264,
            width: 1920, height: 1080, extensions: extensions as CFDictionary,
            formatDescriptionOut: &desc) == noErr, let desc else { return }
        formatDesc = desc

        let refCon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let callback: VTDecompressionOutputCallback = { refCon, _, _, _, pixelBuffer, _, _ in
            guard let refCon, let pixelBuffer else { return }
            let pipeline = Unmanaged<LiveViewPipeline>.fromOpaque(refCon).takeUnretainedValue()
            pipeline.handleDecoded(pixelBuffer)
        }
        let record = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: callback,
            decompressionOutputRefCon: refCon)
        var sessionOut: VTDecompressionSession?
        let attrs: CFDictionary = [kVTDecompressionPropertyKey_RealTime: true] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: nil,
                                           formatDescription: desc,
                                           decoderSpecification: nil,
                                           imageBufferAttributes: attrs,
                                           outputCallback: [record],
                                           decompressionSessionOut: &sessionOut) == noErr,
              let sessionOut else {
            state = .failed("VTDecompressionSessionCreate 失败")
            return
        }
        session = sessionOut
        state = .decoding
    }

    /// 构造 avcC atom（AVCDecoderConfigurationRecord）：SPS/PPS 打包。
    private func makeAVCC(sps: Data, pps: Data) -> Data {
        var d = Data([0x01, sps[1], sps[2], sps[3], 0xFC | 3, 0xE0 | 1])
        d += UInt16(sps.count).bigEndianBytes
        d += sps
        d += Data([1])
        d += UInt16(pps.count).bigEndianBytes
        d += pps
        return d
    }

    /// VTDecompressionOutputCallback 是 C 函数指针，不能捕获 Swift 上下文——经 refCon 转发。
    fileprivate nonisolated func handleDecoded(_ pb: CVPixelBuffer) {
        // C 回调线程：仅做原子计数与回调转发，不碰 actor 状态
        decodedCount.add(1)
        onPixelBufferBox.value?(pb)
    }
    private let decodedCount = AtomicCounter()
    private let onPixelBufferBox = BoxedHandler()

    /// 简单原子计数（回调线程安全）。
    final class AtomicCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add(_ n: Int) { lock.withLock { value += n } }
        var current: Int { lock.withLock { value } }
    }
    final class BoxedHandler: @unchecked Sendable {
        private let lock = NSLock()
        private var handler: ((CVPixelBuffer) -> Void)?
        func set(_ h: @escaping (CVPixelBuffer) -> Void) { lock.withLock { handler = h } }
        func callAsFunction0() {} 
        var value: ((CVPixelBuffer) -> Void)? { lock.withLock { handler } }
        func invoke(_ pb: CVPixelBuffer) { lock.withLock { handler }?(pb) }
    }

    public func reset() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        formatDesc = nil
        state = .idle
        framesReceived = 0
        nalusDetected = 0
    }
}

extension UInt16 {
    var bigEndianBytes: Data {
        Data([UInt8(self >> 8), UInt8(self & 0xFF)])
    }
}
