import Foundation

/// 相机控制协议编解码层（clean-room：仅依据 docs/protocol/ 提炼的协议事实实现）。
///
/// 当前为占位骨架：协议文档定案（任务 2.2–2.5）前不写入任何具体帧格式或命令号。
/// 协议结论的原始线索见 openspec/changes/extract-remote-control-to-ios 与逆向笔记。
public enum OpenMimoProtocol {
    /// 协议层版本，随协议文档定案推进。
    public static let protocolDraftVersion = 0
}
