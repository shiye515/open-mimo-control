import Foundation

/// 素材会话编排：媒体（回放）模式进入/维持、分页清单、缩略图、下载、删除。
/// 复用既有的控制 datalink（相机单客户端，不新建链路）；HTTP 直连相机 80 端口。
/// 00/27 分块由 app 层从 `OSMOCameraLink.onMessage` 转发给 `feed`（单槽回调需链式）。
public final class OSMOMediaSession {

    public enum MediaError: Error, CustomStringConvertible {
        case linkDown
        case playbackNotConfirmed
        case listIncomplete
        case emptyStore
        case deleteFailed(code: [UInt8])
        case badResponse

        public var description: String {
            switch self {
            case .linkDown: return "数据链路未就绪"
            case .playbackNotConfirmed: return "媒体模式未确认"
            case .listIncomplete: return "清单接收不完整"
            case .emptyStore: return "存储未就绪（空流）"
            case .deleteFailed(let code): return "删除被拒绝: " + code.map { String(format: "%02X", $0) }.joined()
            case .badResponse: return "相机应答异常"
            }
        }
    }

    public var onLog: ((String) -> Void)?

    private let link: OSMOCameraLink
    private let host: String
    private var cmdCounter: UInt32 = 0
    private var collector: OSMOMediaListCollector?
    private var beatTimer: DispatchSourceTimer?
    private let beatQueue = DispatchQueue(label: "osmo.media.beat")
    private var thumbCache = NSCache<NSString, NSData>()
    /// 尽力进入媒体模式只尝试一轮（失败由相机应答裁决，不阻断读操作）
    private var playbackEnterAttempted = false
    private var playbackHeld = false

    /// 最近一次成功清单是否带库结尾标记（`0c 01`）
    public private(set) var lastPageReachedEnd = false

    public init(link: OSMOCameraLink, host: String = "192.168.2.1") {
        self.link = link
        self.host = host
        thumbCache.countLimit = 600
    }

    private func log(_ line: String) { onLog?(line) }

    private func nextCounter() -> UInt32 {
        cmdCounter = (cmdCounter &+ 1) & 0xFFFF
        if cmdCounter == 0 { cmdCounter = 1 }
        return cmdCounter
    }

    // MARK: - 媒体模式

    /// 进入媒体（回放）模式：先试 02/0C，1s 内 mediaMode 未置位走 OA4 的 01/01 双脉冲；
    /// `isConfirmed` 由调用方提供（读 02/80 快照 mediaMode 位，唯一完成信号）。
    public func enterPlayback(isConfirmed: @escaping () async -> Bool) async throws {
        // 1. 尝试 02/0C（OA4 实测一律 E0，仍按 osmosis 建议先试）
        if let resp = try? await link.request(cmdSet: 0x02, cmdId: 0x0C,
                                              payload: OSMOMedia.mediaModeEnterPayload, timeout: 1.0),
           resp.first == 0x00 {
            log("[media] 02/0C accepted")
            if await isConfirmed() { startBeat(); return }
        } else {
            log("[media] 02/0C rejected/timeout → 01/01 pulses")
        }
        // 2. OA4/Pocket 路线：01/01 脉冲 A ×6 @20Hz → 脉冲 B @20Hz 直至确认（≤3s）
        for _ in 0..<6 {
            link.send(cmdSet: 0x01, cmdId: 0x01, payload: OSMOMedia.playbackPulseA)
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            link.send(cmdSet: 0x01, cmdId: 0x01, payload: OSMOMedia.playbackPulseB)
            if await isConfirmed() {
                log("[media] playback confirmed via 01/01 pulses")
                startBeat()
                return
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        throw MediaError.playbackNotConfirmed
    }

    /// 1Hz `00/88` APP_PRESENCE 维持心跳（→ 编码器 0x28）——停止后相机自行脱离媒体/浏览状态
    public func startBeat() {
        stopBeat()
        let timer = DispatchSource.makeTimerSource(queue: beatQueue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.link.sendAppPresenceBeat()
        }
        timer.resume()
        beatTimer = timer
        log("[media] presence beat started")
    }

    public func stopBeat() {
        beatTimer?.cancel()
        beatTimer = nil
    }

    /// 退出媒体/回放模式。OA4 无被证实的退出命令（osmosis：相机在**链路断开**后才自行返回拍摄，
    /// 仅停心跳不够——链路仍活着时相机会一直停在回放、不再推流）。全程免应答发送
    /// （回放模式下写命令可能不应答）：
    /// 1) `01/01` 反向脉冲（B 尾字节 1→0，对齐 02/0C enter/leave 的尾字节开关）
    /// 2) `02/0C [01 01 00 00]` leave
    /// 3) `02/E1` 工作模式切换回拍摄（OA4 实测可用的命令，切换会重启编码器）
    /// 调用方随后恢复实时预览。
    public func leavePlayback(preferredMode: UInt8) async {
        stopBeat()
        log("[media] leaving playback (mode target 0x\(String(preferredMode, radix: 16)))")
        for _ in 0..<6 {
            // 参考实现 osmosis 此帧带 flags 0x00；OA4 真机以链路层恒定 0x40 验证通过
            link.send(cmdSet: 0x01, cmdId: 0x01,
                      payload: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00]))
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        link.send(cmdSet: 0x02, cmdId: 0x0C, payload: Data([0x01, 0x01, 0x00, 0x00]))
        link.send(cmdSet: 0x02, cmdId: 0xE1, payload: Data([preferredMode]))
        playbackHeld = false
        playbackEnterAttempted = false
        log("[media] leave sequence sent")
    }

    /// 00/27 分块喂入口（app 层从 link.onMessage 链式转发）
    public func feed(cmdSet: UInt8, cmdId: UInt8, payload: Data) {
        collector?.accept(cmdSet: cmdSet, cmdId: cmdId, payload: payload)
    }

    // MARK: - 文件清单

    /// 最新一页（osmosis queryNewestPage：**无需媒体模式**，3 命令序列——
    /// query(SD 最新) → ~800ms → trigger → 等该 counter 流结束；OA4 实测可用）
    public func fetchNewestPage() async throws -> [OSMOMediaFile] {
        try await queryAndCollect(cursor: 0x0000_0001, sendTrigger: true)
    }

    /// 指定游标查询
    public func fetchPage(cursor: UInt32) async throws -> [OSMOMediaFile] {
        try await queryAndCollect(cursor: cursor, sendTrigger: false)
    }

    /// 更早一页：需要媒体模式（尽力进入），随后 osmosis 分页三帧
    public func fetchOlderPage(cursor: UInt32) async throws -> [OSMOMediaFile] {
        tryEnterPlaybackBestEffort()
        let c1 = nextCounter()
        collector = OSMOMediaListCollector(counter: c1)
        _ = try await link.request(cmdSet: 0x00, cmdId: 0x26,
                                   payload: OSMOMedia.listQueryPayload(counter: c1, cursor: 0x0000_0001),
                                   timeout: 5.0)
        link.send(cmdSet: 0x00, cmdId: 0x26, payload: OSMOMedia.paginationTriggerPayload)
        return try await queryAndCollect(cursor: cursor, sendTrigger: false)
    }

    /// 尽力进入媒体模式（删除/翻页等写操作前付费；失败不阻断，由相机应答裁决）
    public func tryEnterPlaybackBestEffort() {
        guard !playbackEnterAttempted else { return }
        playbackEnterAttempted = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.enterPlayback(isConfirmed: { false }) // 无状态观测：仅发脉冲
                await MainActor.run { self.playbackHeld = true }
            } catch {
                self.log("[media] playback entry not confirmed (continuing): \(error)")
            }
        }
    }

    private func queryAndCollect(cursor: UInt32, sendTrigger: Bool) async throws -> [OSMOMediaFile] {
        guard link.isReady else { throw MediaError.linkDown }
        var attempt = 0
        while true {
            attempt += 1
            let c = nextCounter()
            let col = OSMOMediaListCollector(counter: c)
            collector = col
            _ = try await link.request(cmdSet: 0x00, cmdId: 0x26,
                                       payload: OSMOMedia.listQueryPayload(counter: c, cursor: cursor),
                                       timeout: 5.0)
            // 收集期间按 ~1Hz 拍维持心跳；~1.6s 处发 trigger（osmosis 快速首页序列）
            let started = Date()
            let deadline = started.addingTimeInterval(8.0)
            var beatAt = started.addingTimeInterval(0.8)
            var triggerSent = false
            while Date() < deadline, !col.isComplete {
                if !triggerSent, sendTrigger, Date() >= started.addingTimeInterval(1.6) {
                    link.send(cmdSet: 0x00, cmdId: 0x26, payload: OSMOMedia.paginationTriggerPayload)
                    triggerSent = true
                }
                if Date() >= beatAt {
                    link.sendAppPresenceBeat()
                    beatAt = beatAt.addingTimeInterval(1.0)
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            collector = nil
            if col.isComplete {
                let files = OSMOMediaManifest.decode(col.manifest)
                lastPageReachedEnd = OSMOMediaManifest.reachedEnd(col.manifest)
                log("[media] page cursor=0x\(String(cursor, radix: 16)) → \(files.count) files, \(col.dataBytes)B manifest, end=\(lastPageReachedEnd)")
                return files
            }
            // 空流（仅 start）：存储未挂载/正忙——延迟重试至多 2 次，不判定为无文件
            if col.isEmptyStream && attempt < 3 {
                log("[media] empty stream, retry \(attempt)/2 after 1s")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                continue
            }
            throw MediaError.listIncomplete
        }
    }

    // MARK: - 缩略图 / 下载 / 删除（HTTP 80 + datalink）

    public static func downloadURL(host: String, storage: Int, path: String) -> URL? {
        // path 保留 '/' 字面量，其余按查询串转义
        let escaped = path.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "/").union(.alphanumerics).union(CharacterSet(charactersIn: "._-"))) ?? path
        return URL(string: "http://\(host)/v2?storage=\(storage)&path=\(escaped)")
    }

    /// 缩略图 JPEG（缩略图路径 + .THM，256px），内存缓存
    public func fetchThumbnail(for file: OSMOMediaFile) async throws -> Data {
        if let cached = thumbCache.object(forKey: file.path as NSString) { return cached as Data }
        guard var thumb = file.thumbPath, !thumb.isEmpty else { throw MediaError.badResponse }
        thumb += ".THM"
        guard let url = Self.downloadURL(host: host, storage: file.storageIndex, path: thumb) else {
            throw MediaError.badResponse
        }
        let (data, resp) = try await urlSession.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw MediaError.badResponse
        }
        thumbCache.setObject(data as NSData, forKey: file.path as NSString)
        return data
    }

    /// 原文件下载（Range 断点续传），URLSessionDownloadTask + delegate 进度；progress 0...1
    public func download(file: OSMOMediaFile, destination: URL,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let fm = FileManager.default
        let partial = destination.appendingPathExtension("part")
        let scratch = destination.appendingPathExtension("dl")
        var offset: Int64 = 0
        if fm.fileExists(atPath: partial.path) {
            offset = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        }
        guard let url = Self.downloadURL(host: host, storage: file.storageIndex,
                                         path: "\(file.path).\(file.ext)") else {
            throw MediaError.badResponse
        }
        var req = URLRequest(url: url)
        if offset > 0 { req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }
        let total = Int64(file.sizeBytes)

        let delegate = MediaDownloadDelegate(progress: progress, total: total, startOffset: offset)
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let temp = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            delegate.continuation = cont
            session.downloadTask(with: req).resume()
        }

        // 200 = 服务器忽略了 Range：丢弃旧半包从头开始；206 = 追加余量
        let status = delegate.responseStatus ?? 200
        if status == 200 && offset > 0 {
            try? fm.removeItem(at: partial)
            offset = 0
        }
        if fm.fileExists(atPath: scratch.path) { try? fm.removeItem(at: scratch) }
        try fm.moveItem(at: temp, to: scratch)
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        let segment = try Data(contentsOf: scratch)
        try handle.write(contentsOf: segment)
        try? fm.removeItem(at: scratch)
        let written = offset + Int64(segment.count)
        progress(1.0)
        log("[media] downloaded \(file.name) \(written)B (status \(status))")

        guard total <= 0 || written == total else { throw MediaError.listIncomplete }
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: partial, to: destination)
    }

    /// 删除（00/28，应答 0000=成功；同一句柄不得重复发送）。删除为写操作，先尽力进入媒体模式
    public func delete(file: OSMOMediaFile) async throws {
        tryEnterPlaybackBestEffort()
        try? await Task.sleep(nanoseconds: 400_000_000) // 给脉冲一点生效窗口
        let resp = try await link.request(cmdSet: 0x00, cmdId: 0x28,
                                          payload: OSMOMedia.deletePayload(handles: [file.handle],
                                                                           counter: nextCounter()),
                                          timeout: 5.0)
        guard resp.count >= 2, resp[0] == 0x00, resp[1] == 0x00 else {
            throw MediaError.deleteFailed(code: [UInt8](resp.prefix(4)))
        }
        log("[media] deleted \(file.name) handle=0x\(String(file.handle, radix: 16))")
    }

    private var urlSession: URLSession { .shared }

    // MARK: - 播放 / 大图预览地址

    /// 原文件 URL（视频播放用；相机 HTTP 支持 Range，AVPlayer 可渐进播放）
    public func originalMediaURL(for file: OSMOMediaFile) -> URL? {
        Self.downloadURL(host: host, storage: file.storageIndex, path: "\(file.path).\(file.ext)")
    }

    /// 视频低清代理 .LRF（720p H.264，osmosis §下载；OA4 上是否存在需探测）
    public func proxyMediaURL(for file: OSMOMediaFile) -> URL? {
        Self.downloadURL(host: host, storage: file.storageIndex, path: "\(file.path).LRF")
    }

    public func headOK(_ url: URL) async -> Bool {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 3.0
        guard let (_, resp) = try? await urlSession.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    /// 任意 GET（照片大图预览等）
    public func fetchData(_ url: URL) async throws -> Data {
        let (data, resp) = try await urlSession.data(from: url)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else {
            throw MediaError.badResponse
        }
        return data
    }
}

/// 下载进度桥接：didWriteData → progress；didFinish → 把临时段交给调用方拼接
private final class MediaDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let progress: @Sendable (Double) -> Void
    let total: Int64
    let startOffset: Int64
    var continuation: CheckedContinuation<URL, Error>?
    var responseStatus: Int?
    private var lastReported = 0.0

    init(progress: @escaping @Sendable (Double) -> Void, total: Int64, startOffset: Int64) {
        self.progress = progress
        self.total = total
        self.startOffset = startOffset
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        lastReported = Double(startOffset + totalBytesWritten)
        if total > 0 { progress(min(1.0, lastReported / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        responseStatus = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("oc-media-\(UUID().uuidString)")
        do {
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try FileManager.default.moveItem(at: location, to: target)
            continuation?.resume(returning: target)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // 正常结束（下载任务成功也走此回调，error 为 nil）
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
