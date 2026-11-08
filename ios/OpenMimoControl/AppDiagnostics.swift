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
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let stamped = "[\(fmt.string(from: Date()))] \(line)"
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

    /// 追加写沙盒文件（异步、工具队列；超 256KB 重建）。devicectl 可直接拉取。
    private func appendToFile(_ line: String) {
        let url = Self.fileURL
        DispatchQueue.global(qos: .utility).async {
            do {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    let size = (try? handle.seekToEndOfFile()) ?? 0
                    if size > Self.maxFileBytes {
                        handle.truncateFile(atOffset: 0)
                    }
                    handle.seekToEndOfFile()
                    handle.write(Data((line + "\n").utf8))
                } else {
                    try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
                }
            } catch {
                // 落盘失败不影响 UI 日志
            }
        }
    }
}
