import Foundation
import Combine

/// 连接流程步骤日志（tasks 4.3b）：每步指令固定格式
/// `时间戳 | 步骤名 | 目的 | 内容`，复用 AppDiagnostics 面板与复制通道。
@MainActor
final class StepLogger: ObservableObject {
    static let shared = StepLogger()

    /// 一条步骤日志
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        let time: String
        let step: String
        let purpose: String
        let content: String
    }

    @Published private(set) var entries: [Entry] = []

    /// 记录一条步骤日志。direction: "→" 发送 / "←" 接收 / "·" 状态
    func log(step: String, purpose: String, direction: String = "·", content: String) {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss.SSS"
        let entry = Entry(time: fmt.string(from: Date()),
                          step: step,
                          purpose: "\(direction) \(purpose)",
                          content: content)
        entries.append(entry)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        AppDiagnostics.shared.add("[step] \(entry.time) | \(step) | \(purpose) | \(content)")
    }

    /// 记录指令帧（发送/接收均适用），内容为 hex
    func logFrame(step: String, direction: String, frame: Data, purpose: String) {
        let hex = [UInt8](frame).map { String(format: "%02x", $0) }.joined()
        log(step: step, purpose: purpose, direction: direction, content: "\(frame.count)B \(hex)")
    }

    func clear() {
        entries.removeAll()
    }

    /// 导出全部日志为纯文本
    func export() -> String {
        var out = "== 连接流程步骤日志 ==\n"
        for e in entries {
            out += "\(e.time) | \(e.step) | \(e.purpose) | \(e.content)\n"
        }
        return out
    }
}
