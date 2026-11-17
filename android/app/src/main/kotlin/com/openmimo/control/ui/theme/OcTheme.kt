package com.openmimo.control.ui.theme

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp

/**
 * 设计令牌（移植自 iOS DesignTokens.swift：黑红方圆深色主题）。
 * 页面背景 0x0E0E11 / 卡片 0x1C1C1E / 胶囊 0x2C2C2E / 主色红 0xFF3B30。
 */
object OC {
    val bg = Color(0xFF0E0E11)          // 页面背景
    val card = Color(0xFF1C1C1E)        // 卡片 / 面板
    val pill = Color(0xFF2C2C2E)        // 参数胶囊 / 次级底
    val accent = Color(0xFFFF3B30)      // 主色（红）
    val recRed = Color(0xFFFF3B30)      // 录制红
    val okGreen = Color(0xFF34C759)
    val textPrimary = Color(0xFFF2F2F7)
    val textSecondary = Color(0xFFAEAEB2)
    val textTertiary = Color(0xFF7C7C80)
    val stroke = Color(0xFF38383A)
}

/** 统一交互尺寸（对齐 iOS 弹窗/行高体系；dp 而非 pt，与 iOS 视觉 1:1 近似）。 */
object OcMetrics {
    /** 可点击行统一高度（控制区胶囊 / 弹窗选项行 / 底栏图标） */
    val RowHeight: Dp = 44.dp
    /** 底部选择弹窗统一总高：12 头部留白 + 32 标题栏 + 8 间距 + (5×44 + 4×8 行距) + 8 底部 */
    val SelectionSheetHeight: Dp = 312.dp
    val TitleRowHeight: Dp = 32.dp
    val OptionRowSpacing: Dp = 8.dp
}
