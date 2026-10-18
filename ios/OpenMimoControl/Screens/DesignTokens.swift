import SwiftUI

/// 设计稿 docs/design/ui-design-preview.html 的颜色令牌（深色主题）。
enum OC {
    static let bg = Color(hex: 0x0E0E11)          // 页面背景
    static let card = Color(hex: 0x1C1C1E)        // 卡片 / 面板
    static let pill = Color(hex: 0x2C2C2E)        // 参数胶囊 / 次级底
    static let accent = Color(hex: 0x0A84FF)      // 强调蓝
    static let recRed = Color(hex: 0xFF453A)      // 录制红
    static let okGreen = Color(hex: 0x30D158)     // 成功绿
    static let textPrimary = Color(hex: 0xF2F2F7)
    static let textSecondary = Color(hex: 0x98989F)
    static let textTertiary = Color(hex: 0x8E8E93)
    static let stroke = Color(hex: 0x3A3A3C)      // 描边 / 分隔
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0)
    }
}
