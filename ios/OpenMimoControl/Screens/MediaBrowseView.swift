import SwiftUI
import AVKit
import OpenMimoProtocol

// MARK: - 素材浏览页（设计稿 ⑦；media-files 协议接入：清单/缩略图/下载/删除）

struct MediaBrowseView: View {
    let onBack: () -> Void
    @ObservedObject var flow: ConnectionFlow
    @StateObject private var model = MediaLibraryModel()
    @State private var selected: OSMOMediaFile?
    @State private var deleteConfirm = false
    @State private var player: AVPlayer?

    /// 显式正方形尺寸：LazyVGrid 的行高提议是无限的，aspectRatio(.fit) 在其下失效，
    /// 格子高度会退化为内容高度（照片与视频不一致）——必须写死宽高
    private var cellSize: CGFloat {
        (UIScreen.main.bounds.width - 24 - 12) / 3   // 页面左右 12×2 + 列间隙 6×2
    }

    private let columns = [GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6),
                           GridItem(.flexible(), spacing: 6)]

    var body: some View {
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(OC.bg.ignoresSafeArea())
        .ocToast($model.notice)
        .onAppear {
            model.start(flow: flow)
            model.onBackRequested = { onBack() }
            // 自动化/UI 调试钩子：--auto-detail 等清单就绪后自动弹出最新视频的详情（验证播放器）
            if ProcessInfo.processInfo.arguments.contains("--auto-detail") {
                Task {
                    for _ in 0..<40 {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        if let f = model.files.first(where: \.isVideo) {
                            selected = f
                            break
                        }
                    }
                }
            }
        }
        .onDisappear { model.stop(flow: flow) }
        .sheet(item: $selected) { file in
            detailSheet(file)
        }
        .alert("删除文件", isPresented: $deleteConfirm, presenting: selected) { file in
            Button("删除", role: .destructive) {
                Task { await model.delete(file) }
                selected = nil
            }
            Button("取消", role: .cancel) {}
        } message: { file in
            Text("该操作不可恢复，相机上的 \(file.name) 将被删除。")
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(OC.accent)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(OC.card))
            }
            .accessibilityLabel("返回")
            Text("素材浏览")
                .font(.headline)
                .foregroundStyle(OC.textPrimary)
            Spacer()
            Text(sdFreeText)
                .font(.footnote.monospacedDigit())
                .foregroundStyle(OC.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var sdFreeText: String {
        var text = "SD 余 —"
        if let free = flow.osmoStatus.sdFreeMB {
            text = String(format: "SD 余 %.1fGB", Double(free) / 1024)
        }
        // 自动化/调试钩子：mock 模式下标记二进制版本，防止误判旧包
        if MediaLibraryModel.isMock { text += " · MOCK" }
        return text
    }

    // MARK: 内容三态

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .entering:
            stateView(icon: "arrow.triangle.2.circlepath", title: "正在进入媒体模式…")
        case .loading:
            stateView(icon: "photo.stack", title: "正在读取相机文件…")
        case .failed(let msg):
            VStack(spacing: 12) {
                stateView(icon: "exclamationmark.triangle", title: msg)
                Button("重试") { Task { await model.loadFirst() } }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(OC.accent))
            }
        case .empty:
            VStack(spacing: 10) {
                stateView(icon: "photo.on.rectangle.angled", title: "相机上没有文件")
                Text("拍一段视频或照片后回到这里")
                    .font(.caption)
                    .foregroundStyle(OC.textTertiary)
            }
        case .loaded:
            fileGrid
        }
    }

    private func stateView(icon: String, title: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(OC.textTertiary)
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(OC.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    // MARK: 文件网格

    private var fileGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(model.files) { file in
                    cell(file)
                        .onTapGesture { if model.busyFile == nil { selected = file } }
                        .overlay {
                            if model.savedToPhotos.contains(file.path) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(OC.okGreen)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                    .padding(5)
                            }
                        }
                }
                footerCell
            }
            .padding(.horizontal, 12)
            Spacer(minLength: 30)
        }
    }

    @ViewBuilder
    private var footerCell: some View {
        if !model.endReached {
            Button {
                Task { await model.loadOlder() }
            } label: {
                Group {
                    if model.loadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("加载更早", systemImage: "clock.arrow.circlepath")
                            .font(.caption.weight(.medium))
                    }
                }
                .foregroundStyle(OC.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 9).fill(OC.card))
            }
            .buttonStyle(.plain)
        }
    }

    /// 网格项：正方形格子、无圆角，预览图 cover 模式填充。
    /// GeometryReader 给出格子真实尺寸，每层显式 frame——彻底排除 scaledToFill
    /// 理想尺寸参与布局导致的撑大/居中问题。
    private func cell(_ file: OSMOMediaFile) -> some View {
        Rectangle()
            .fill(LinearGradient(colors: [OC.stroke, OC.card],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: cellSize, height: cellSize)
            .overlay {
                GeometryReader { geo in
                    ZStack(alignment: .bottomLeading) {
                        if MediaLibraryModel.isMock {
                            Text("\(Int(geo.size.width))×\(Int(geo.size.height))")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.yellow)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                .padding(4)
                        }
                        if let image = model.thumbnails[file.path] {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                        }
                        if file.isVideo {
                            Image(systemName: "play.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.9))
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                        if let p = model.downloads[file.path] {
                            ZStack(alignment: .leading) {
                                Color.black.opacity(0.55)
                                Rectangle().fill(OC.accent).frame(width: geo.size.width * p)
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.name)
                                .font(.system(size: 9.5).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.9))
                            if file.isVideo, file.durationSec > 0 {
                                Text(Self.durationText(file.durationSec))
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.7))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                        .frame(width: geo.size.width, alignment: .leading)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                                   startPoint: .top, endPoint: .bottom),
                                    alignment: .bottom)
                        if model.busyFile == file.path {
                            ProgressView().tint(.white)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .clipped()
            .opacity(model.busyFile == file.path ? 0.75 : 1)
    }

    // MARK: 文件详情（下载 / 删除）

    private func detailSheet(_ file: OSMOMediaFile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            previewArea(file)
            VStack(alignment: .leading, spacing: 5) {
                detailRow("文件名", file.name)
                detailRow("大小", Self.byteText(file.sizeBytes))
                if file.isVideo {
                    detailRow("时长", Self.durationText(file.durationSec))
                }
                if let date = file.capturedAt {
                    detailRow("拍摄时间", Self.dateText(date))
                }
                detailRow("存储", file.storageIndex == 1 ? "内置存储" : "SD 卡")
            }
            .font(.caption.monospacedDigit())

            if let p = model.downloads[file.path] {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: p)
                        .tint(OC.accent)
                    Text("取回中 \(Int(p * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(OC.textSecondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await model.saveToPhotos(file) }
                } label: {
                    Label(model.savedToPhotos.contains(file.path) ? "已保存到相册" : "保存到相册",
                          systemImage: model.savedToPhotos.contains(file.path)
                              ? "checkmark.circle.fill" : "square.and.arrow.down.fill")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(model.savedToPhotos.contains(file.path) ? OC.okGreen : .white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12).fill(
                            model.savedToPhotos.contains(file.path)
                                ? AnyShapeStyle(OC.okGreen.opacity(0.14)) : AnyShapeStyle(OC.accent)))
                }
                .disabled(model.busyFile == file.path || model.savedToPhotos.contains(file.path))
                Button(role: .destructive) {
                    deleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(OC.recRed)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(RoundedRectangle(cornerRadius: 12).fill(OC.recRed.opacity(0.12)))
                }
                .disabled(model.busyFile == file.path)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OC.card, ignoresSafeAreaEdges: .bottom)
        .ocToast($model.notice)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .onAppear {
            if file.isVideo {
                Task {
                    if let p = await model.videoPreviewPlayer(file) {
                        player = p
                        p.automaticallyWaitsToMinimizeStalling = false
                        p.play()
                        // 播放器状态诊断：定位"不能播放"是缓冲停滞还是已在播放
                        for _ in 0..<10 {
                            try? await Task.sleep(nanoseconds: 1_000_000_000)
                            guard player === p, let item = p.currentItem else { return }
                            let loaded = item.loadedTimeRanges.first?.timeRangeValue
                            AppDiagnostics.shared.add(String(
                                format: "[media] player t=%.1fs tc=%d status=%d loaded=%.1fs",
                                CMTimeGetSeconds(p.currentTime()),
                                p.timeControlStatus.rawValue,
                                p.status.rawValue,
                                loaded.map { CMTimeGetSeconds($0.duration) } ?? -1))
                        }
                    }
                }
            } else {
                Task { await model.loadPreviewImage(file) }
            }
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    /// 详情顶部大图预览：正方形区域、contain 布局；视频为可直接播放的播放器
    private func previewArea(_ file: OSMOMediaFile) -> some View {
        let side = UIScreen.main.bounds.width - 32
        return ZStack {
            Color.black
            if file.isVideo {
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView().tint(.white)
                }
            } else if let data = model.previewImageData[file.path], let img = UIImage(data: data) {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
            } else if let thumb = model.thumbnails[file.path] {
                Image(uiImage: thumb)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: side, height: side)
        .overlay(alignment: .topTrailing) {
            Button {
                selected = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(Color.black.opacity(0.55)))
            }
            .padding(8)
            .accessibilityLabel("关闭")
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(OC.textSecondary).frame(width: 60, alignment: .leading)
            Text(value).foregroundStyle(OC.textPrimary)
            Spacer(minLength: 0)
        }
    }

    // MARK: 格式化

    static func durationText(_ s: Int) -> String {
        String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func byteText(_ bytes: Int64) -> String {
        bytes >= 1 << 30 ? String(format: "%.2f GB", Double(bytes) / Double(1 << 30))
            : bytes >= 1 << 20 ? String(format: "%.1f MB", Double(bytes) / Double(1 << 20))
            : String(format: "%.0f KB", Double(bytes) / Double(1 << 10))
    }

    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
