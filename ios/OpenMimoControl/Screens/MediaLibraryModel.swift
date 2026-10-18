import SwiftUI
import Combine
import Photos
import AVFoundation
import OpenMimoProtocol

/// 素材页数据编排：媒体模式生命周期、分页清单、缩略图缓存、下载/删除状态。
/// 协议在 OpenMimoProtocol（OSMOMediaSession），此处只做 app 侧粘合与状态发布。
@MainActor
final class MediaLibraryModel: ObservableObject {

    enum Phase: Equatable {
        case idle        // 未开始（无会话）
        case entering    // 进入媒体模式
        case loading     // 拉取清单
        case loaded
        case empty
        case failed(String)
    }

    @Published var phase: Phase = .idle
    @Published var files: [OSMOMediaFile] = []
    @Published var endReached = false
    @Published var thumbnails: [String: UIImage] = [:]
    @Published var loadingMore = false
    /// path → 下载进度 0...1（保存到相册时的取回进度）
    @Published var downloads: [String: Double] = [:]
    /// 已完整落盘（本地缓存）的文件 path
    @Published var downloaded: Set<String> = []
    /// 已保存到系统相册的文件 path
    @Published var savedToPhotos: Set<String> = []
    /// 照片大图预览（原图 JPG；视频用播放器）
    @Published var previewImageData: [String: Data] = [:]
    /// 正在删除/下载的文件 path
    @Published var busyFile: String?
    /// 非致命错误横幅（加载更早/删除/下载失败不打断网格）
    @Published var notice: String?

    /// --mock-media 离线调试模式（cell 内显示几何尺寸标记）
    static let isMock = ProcessInfo.processInfo.arguments.contains("--mock-media")

    private(set) var session: OSMOMediaSession?
    /// 素材页请求返回控制页（--auto-back 自动化钩子）
    var onBackRequested: (() -> Void)?
    private var chainedOnMessage: ((UInt8, UInt8, UInt8, Data) -> Void)?
    private var weakLink: OSMOCameraLink?
    private var thumbTasks: [String: Task<Void, Never>] = [:]

    /// 下载落盘目录 Documents/Media/
    var mediaDirectory: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Media", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func downloadedFileURL(_ file: OSMOMediaFile) -> URL {
        mediaDirectory.appendingPathComponent(file.name)
    }

    // MARK: 生命周期

    func start(flow: ConnectionFlow) {
        guard session == nil else { return }
        // 自动化/UI 调试钩子：--mock-media 无相机离线渲染网格（OA4 golden 文件名）
        if ProcessInfo.processInfo.arguments.contains("--mock-media") {
            files = Self.mockFiles()
            endReached = true
            phase = .loaded
            return
        }
        guard let link = flow.activeOSMOLink, flow.state == .success else {
            phase = .failed("未连接相机——请先建立连接再浏览素材")
            return
        }
        weakLink = link
        let s = OSMOMediaSession(link: link)
        s.onLog = { AppDiagnostics.shared.add("[media] \($0)") }
        AppDiagnostics.shared.add("[media] start (session ready)")
        // link.onMessage 是单槽：链式保留既有处理器
        chainedOnMessage = link.onMessage
        link.onMessage = { [weak self] cmdSet, cmdId, sender, payload in
            self?.session?.feed(cmdSet: cmdSet, cmdId: cmdId, payload: payload)
            self?.chainedOnMessage?(cmdSet, cmdId, sender, payload)
        }
        session = s
        Task { await enterAndLoad(flow: flow) }
    }

    func stop(flow: ConnectionFlow) {
        guard let s = session else { return }
        session = nil
        thumbTasks.values.forEach { $0.cancel() }
        thumbTasks.removeAll()
        weakLink?.onMessage = chainedOnMessage
        weakLink = nil
        let targetMode = flow.osmoStatus.captureMode ?? OSMOA4.modeVideo
        Task { [weak flow] in
            // 主动退出回放（链路仍活着的相机不会自行返回拍摄），再恢复实时预览
            await s.leavePlayback(preferredMode: targetMode)
            try? await Task.sleep(nanoseconds: 800_000_000)
            flow?.resumeOSMOLiveView()
        }
    }

    // MARK: 进入 + 首页

    private func enterAndLoad(flow: ConnectionFlow) async {
        phase = .entering
        guard let s = session else { return }
        // 最新一页无需媒体模式（osmosis 快速首页序列，OA4 实测）；**不进入回放**——
        // 01/01 脉冲会让相机进入回放且链路存活期间不退出，返回控制页后预览不可恢复。
        // 维持心跳仍需启动（浏览客户端身份），离开时由 stop() 发退出序列。
        s.startBeat()
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        await loadFirst()
    }

    func loadFirst() async {
        phase = .loading
        guard let s = session else { return }
        do {
            let page = try await s.fetchNewestPage()
            files = page
            endReached = s.lastPageReachedEnd
            phase = files.isEmpty ? .empty : .loaded
            prefetchThumbnails()
            // 自动化测试钩子：--auto-download 取回第一个文件验证 HTTP 通道
            if ProcessInfo.processInfo.arguments.contains("--auto-download"), let first = page.first {
                Task { await saveToPhotos(first) }
            }
            // 自动化测试钩子：--auto-back 浏览 15s 后自动返回控制页（验证回退后流恢复）
            if ProcessInfo.processInfo.arguments.contains("--auto-back") {
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await MainActor.run { self?.onBackRequested?() }
                }
            }
        } catch {
            phase = .failed("读取文件列表失败：\(error)")
        }
    }

    /// 「加载更早」：游标 = 当前列表最旧的视频句柄
    func loadOlder() async {
        guard !loadingMore, !endReached, let s = session else { return }
        guard let oldestVideo = files.last(where: { $0.isVideo && $0.handle != 0 }) else {
            endReached = true
            return
        }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await s.fetchOlderPage(cursor: oldestVideo.handle)
            let known = Set(files.map(\.path))
            let fresh = page.filter { !known.contains($0.path) }
            files.append(contentsOf: fresh)
            endReached = s.lastPageReachedEnd || fresh.isEmpty
            prefetchThumbnails()
        } catch {
            notice = "加载更早文件失败：\(error)"
        }
    }

    // MARK: 缩略图

    private func prefetchThumbnails() {
        for f in files where thumbnails[f.path] == nil && thumbTasks[f.path] == nil {
            guard let s = session else { return }
            let path = f.path
            let task = Task { [weak self] in
                defer { Task { await MainActor.run { self?.thumbTasks[path] = nil } } }
                if let data = try? await s.fetchThumbnail(for: f),
                   let image = UIImage(data: data) {
                    await MainActor.run { self?.thumbnails[path] = image }
                } else {
                    AppDiagnostics.shared.add("[media] thumbnail failed: \(path)")
                }
            }
            thumbTasks[path] = task
        }
    }

    // MARK: 保存到相册 / 删除

    /// 保存到相册 = 取回原文件（已有缓存则秒存）→ 写入系统相册
    func saveToPhotos(_ file: OSMOMediaFile) async {
        guard busyFile == nil else { return }
        busyFile = file.path
        downloads[file.path] = 0
        defer { busyFile = nil }
        do {
            let dest = downloadedFileURL(file)
            if !FileManager.default.fileExists(atPath: dest.path), let s = session {
                try await s.download(file: file, destination: dest) { [weak self] p in
                    Task { @MainActor in self?.downloads[file.path] = p }
                }
            }
            downloaded.insert(file.path)
            try await saveLocalFileToPhotos(file: file, url: dest)
            savedToPhotos.insert(file.path)
            downloads[file.path] = nil
        } catch {
            notice = "保存到相册失败：\(error)"
            downloads[file.path] = nil
        }
    }

    private func saveLocalFileToPhotos(file: OSMOMediaFile, url: URL) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            if file.isVideo {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } else {
                PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
            }
        }
    }

    /// 视频预览播放器：候选地址链（原文件优先——moov 后置但服务器支持 Range；
    /// .LRF 低清为退路），以「就绪 + 时长有效」为判据逐一回退，全过程写 diag 便于真机排查
    func videoPreviewPlayer(_ file: OSMOMediaFile) async -> AVPlayer? {
        guard let s = session else { return nil }
        var candidates: [URL] = []
        if let orig = s.originalMediaURL(for: file) { candidates.append(orig) }
        if let lrf = s.proxyMediaURL(for: file) { candidates.append(lrf) }
        for url in candidates {
            AppDiagnostics.shared.add("[media] player trying \(url.absoluteString)")
            let player = AVPlayer(url: url)
            let playable = await Self.waitPlayable(player, timeout: 10)
            let dur = CMTimeGetSeconds(player.currentItem?.asset.duration ?? .invalid)
            AppDiagnostics.shared.add(String(
                format: "[media] player playable=%d status=%d dur=%.1f err=%@ url=%@",
                playable ? 1 : 0, player.status.rawValue, dur,
                player.error?.localizedDescription ?? "-", url.lastPathComponent))
            if playable { return player }
        }
        return nil
    }

    /// 就绪判定：readyToPlay 且资产时长有效（假就绪的路径会 readyToPlay 但 duration/loaded 为 NaN）
    private nonisolated static func waitPlayable(_ player: AVPlayer, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if player.status == .failed { return false }
            if player.status == .readyToPlay {
                let seconds = CMTimeGetSeconds(player.currentItem?.asset.duration ?? .invalid)
                if seconds.isFinite && seconds > 0 { return true }
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    /// 照片大图预览：原图 JPG（.THM 只有 256px，放大失真）
    func loadPreviewImage(_ file: OSMOMediaFile) async {
        guard file.isVideo == false, previewImageData[file.path] == nil, let s = session else { return }
        guard let url = s.originalMediaURL(for: file) else { return }
        if let data = try? await s.fetchData(url) {
            previewImageData[file.path] = data
        }
    }

    func delete(_ file: OSMOMediaFile) async {
        guard let s = session, busyFile == nil else { return }
        busyFile = file.path
        defer { busyFile = nil }
        do {
            try await s.delete(file: file)
            withAnimation { files.removeAll { $0.path == file.path } }
            if files.isEmpty { phase = .empty }
        } catch {
            notice = "删除失败：\(error)"
        }
    }

    /// --mock-media：离线网格样例（含超长文件名验证折行；无缩略图时显示底色）
    static func mockFiles() -> [OSMOMediaFile] {
        let specs: [(String, String, Bool, Int)] = [
            ("DCIM/100MEDIA/DJI_20261107180612_0030_D", "DJI_20261107180612_0030_D.MP4", true, 921),
            ("DCIM/100MEDIA/DJI_20260812131032_0006_D", "DJI_20260812131032_0006_D.MP4", true, 276),
            ("DCIM/100MEDIA/DJI_20260812130449_0005_D", "DJI_20260812130449_0005_D.MP4", true, 38),
            ("DCIM/100MEDIA/DJI_20260812125237_0004_D", "DJI_20260812125237_0004_D.MP4", true, 160),
            ("DCIM/100MEDIA/DJI_20260811205751_0002_D", "DJI_20260811205751_0002_D.JPG", false, 0),
            ("DCIM/100MEDIA/DJI_20260810094824_0001_D", "DJI_20260810094824_0001_D.JPG", false, 0),
        ]
        return specs.enumerated().map { i, s in
            OSMOMediaFile(path: s.0, name: s.1, ext: s.2 ? "MP4" : "JPG",
                          thumbPath: nil, handle: UInt32(0x00040000 + i * 0x10),
                          sizeBytes: 1_000_000, durationSec: s.3, isVideo: s.2,
                          resCode: 0, fpsCode: 0, seq: 30 - i, capturedAt: nil)
        }
    }
}
