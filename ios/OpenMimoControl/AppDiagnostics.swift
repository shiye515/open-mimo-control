import Foundation
import Combine

/// 全局统一的诊断日志：连接页/控制页显示同一份内容，复制按钮复制的内容与所见完全一致。
/// 同时落盘到沙盒 Documents/diag.log——可用 devicectl 直接拉取（无需人工复制）：
/// xcrun devicectl device copy from --device <UDID> \
///   --source Documents/diag.log \
///   --domain-type appDataContainer --domain-identifier win.service-ai.OpenMimoControl \
///   --destination /tmp/
@MainActor
final class AppDiagnostics: ObservableObject {
    static let shared = AppDiagnostics()

    /// 上限 120 条（BLE 全流程含帧 hex 需要足够容量）；来源前缀：[wifi]/[ble]/[link]/[session]
    @Published private(set) var lines: [String] = []

    private static let fileURL = FileManager.default
        .urls(for: .documentDirectory, in: .userDomainMask).first!
        .appendingPathComponent("diag.log")
    private static let maxFileBytes = 256 * 1024

    init() {
        // 新会话起始行（文件续写，便于跨会话排查）
        appendToFile("════ OpenMimoControl 诊断会话开始 ════")
    }

    func add(_ line: String) {
        let stamped = "[\(Self.timestampFormatter.string(from: Date()))] \(line)"
        lines.append(stamped)
        if lines.count > 120 {
            lines.removeFirst(lines.count - 120)
        }
        appendToFile(stamped)
    }

    /// 复制内容 = 所见内容（完整 30 条日志），可附加上下文行。
    func snapshot(context extra: [String] = []) -> String {
        var all = extra
        all.append("-- 诊断日志 --")
        all.append(contentsOf: lines)
        return all.joined(separator: "\n")
    }

    /// 落盘专用串行队列：并发全局队列上多把 FileHandle 同时 seekToEnd/write 会交错截断
    /// （真机日志出现半行碎片、256KB 重建后写入停滞），必须串行化
    private static let logQueue = DispatchQueue(label: "diag.log.append", qos: .utility)
    /// 时间戳格式化器（DateFormatter 构造开销大，逐行创建是热路径浪费；HH:mm:ss.SSS 固定格式）。
    /// 非 private：StepLogger 等同格式场景直接复用，勿在日志路径逐条 new。
    static let timestampFormatter: DateFormatter = {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        return fmt
    }()

    // MARK: 主线程健康探针（iOS 26 响应慢排查）

    /// 主线程心跳定时器（跑在主 RunLoop）：实际触发间隔超出预期 200ms 即判定主线程被占
    /// （SwiftUI 重建 / 系统动画 / 网络回调风暴）。限频 5s 一条，避免卡顿时刷屏。
    private var probeTimer: Timer?
    private var probeLastFire = Date()
    private var probeLastLogAt = Date.distantPast

    func startMainThreadProbe() {
        guard probeTimer == nil else { return }
        probeLastFire = Date()
        probeTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            let firedAt = Date()   // 主 RunLoop 实际触发时刻（主线程阻塞时此处已迟到）
            Task { @MainActor in
                guard let self else { return }
                let driftMs = firedAt.timeIntervalSince(self.probeLastFire) * 1000 - 500
                self.probeLastFire = firedAt
                guard driftMs > 200, firedAt.timeIntervalSince(self.probeLastLogAt) > 5 else { return }
                self.probeLastLogAt = firedAt
                self.add("[main] 主线程卡顿 ~\(Int(driftMs))ms（0.5s 探针漂移）")
            }
        }
    }

    /// 追加写沙盒文件（串行队列；超 256KB 环形重建——保留尾部 3/4，最近的测试事件
    /// 不因爆量整体丢失）。devicectl 可直接拉取。
    private func appendToFile(_ line: String) {
        let url = Self.fileURL
        Self.logQueue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                let size = (try? handle.seekToEndOfFile()) ?? 0
                if size > Self.maxFileBytes {
                    let keep = Self.maxFileBytes * 3 / 4
                    let data = (try? Data(contentsOf: url)) ?? Data()
                    handle.truncateFile(atOffset: 0)
                    handle.write(data.suffix(keep))
                }
                handle.seekToEndOfFile()
                handle.write(Data((line + "\n").utf8))
            } else {
                try? Data((line + "\n").utf8).write(to: url, options: .atomic)
            }
        }
    }
}
