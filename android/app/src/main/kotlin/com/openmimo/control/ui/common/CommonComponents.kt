package com.openmimo.control.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openmimo.control.app.AppDiagnostics
import com.openmimo.control.ui.theme.OC
import com.openmimo.control.ui.theme.OcMetrics

/** 弹窗内选项行统一样式（移植自 iOS OCOptionRow）：44dp 圆角行，选中态 = accent 加粗 + 对勾。 */
@Composable
fun OcOptionRow(
    title: String,
    isSelected: Boolean,
    modifier: Modifier = Modifier,
    icon: ImageVector? = null,
    muted: Boolean = false,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = OcMetrics.RowHeight)
            .background(
                color = if (isSelected && !muted) OC.accent.copy(alpha = 0.20f)
                else if (muted) Color.White.copy(alpha = 0.07f)
                else Color.White.copy(alpha = 0.13f),
                shape = RoundedCornerShape(10.dp),
            )
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (icon != null) {
            Icon(
                icon,
                contentDescription = null,
                tint = if (isSelected && !muted) OC.accent else if (muted) OC.textTertiary else OC.textSecondary,
                modifier = Modifier.size(18.dp),
            )
        }
        Text(
            text = title,
            fontSize = 15.sp,
            fontWeight = if (isSelected && !muted) FontWeight.SemiBold else FontWeight.Normal,
            color = when {
                muted -> OC.textTertiary
                isSelected -> OC.accent
                else -> OC.textPrimary
            },
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
        if (isSelected && !muted) {
            Icon(
                Icons.Filled.Check,
                contentDescription = null,
                tint = OC.accent,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/**
 * 底部选择弹窗统一容器（移植自 iOS OCSelectionSheet）：标题栏 32dp + 内容顶部对齐，
 * 统一总高 312dp（5×44 选项行 + 4×8 行距），无取消按钮（下滑关闭），
 * 不叠卡片底色——直接用系统 sheet 的半透明底。
 */
@Composable
fun OcSelectionSheet(
    title: String,
    modifier: Modifier = Modifier,
    content: @Composable () -> Unit,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .height(OcMetrics.SelectionSheetHeight)
            .padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(OcMetrics.OptionRowSpacing),
    ) {
        Text(
            title,
            fontSize = 17.sp,
            fontWeight = FontWeight.Bold,
            color = OC.textPrimary,
            modifier = Modifier.height(OcMetrics.TitleRowHeight),
        )
        content()
        Spacer(Modifier.weight(1f, fill = true))
    }
}

/** 等宽逐行诊断日志（连接页步骤日志区 / 控制页详情弹窗共用；移植自 iOS DiagnosticsLogView）。 */
@Composable
fun DiagnosticsLogView(
    lines: List<String>,
    modifier: Modifier = Modifier,
    fontSize: Int = 9,
    textColor: Color = OC.textTertiary,
) {
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        lines.forEach { line ->
            Text(
                line,
                fontSize = fontSize.sp,
                fontFamily = FontFamily.Monospace,
                color = textColor,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/** 参数胶囊行（移植自 iOS PillRowView）：44dp 标准行，title + 当前值 + 可选下拉箭头。 */
@Composable
fun PillRow(
    title: String,
    current: String?,
    modifier: Modifier = Modifier,
    disabled: Boolean = false,
    showChevron: Boolean = true,
    onTap: () -> Unit,
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .heightIn(min = OcMetrics.RowHeight)
            .background(color = OC.pill, shape = RoundedCornerShape(8.dp))
            .clickable(enabled = !disabled) { onTap() }
            .padding(horizontal = 11.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            title,
            fontSize = 13.sp,
            color = OC.textSecondary,
            maxLines = 1,
        )
        Spacer(Modifier.weight(1f))
        Text(
            current ?: "—",
            fontSize = 13.sp,
            fontWeight = FontWeight.Medium,
            color = if (disabled) OC.textTertiary else OC.textPrimary,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (showChevron) {
            Text("▾", fontSize = 10.sp, color = OC.textSecondary)
        }
    }
}

/** 轻提示浮层（移植自 iOS OCToastView）：顶部浮出，点击关闭。 */
@Composable
fun OcToastView(text: String, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .background(Color(0xFFFF3B30).copy(alpha = 0.92f), RoundedCornerShape(50))
            .padding(horizontal = 14.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text("!", color = Color.White, fontWeight = FontWeight.Bold, modifier = Modifier.padding(end = 6.dp))
        Text(
            text,
            color = Color.White,
            fontSize = 12.sp,
            fontWeight = FontWeight.Medium,
            maxLines = 3,
        )
    }
}

// MARK: - 共享格式化工具（对齐 iOS OCFormat）

/** 全 App 共享格式化工具（勿在页面内重复实现） */
object OCFormat {
    /** 秒 → 时长文本：<1h 为 mm:ss（分不截断），≥1h 为 h:mm:ss。三处实现统一（iOS 对齐）。 */
    fun duration(seconds: Long): String {
        val s = seconds.coerceAtLeast(0)
        return if (s >= 3600) {
            "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60)
        } else {
            "%02d:%02d".format(s / 60, s % 60)
        }
    }
}

/** 诊断信息复制（对齐 iOS CopyDiagnosticsButton 的复制语义：所见即所复制） */
fun copyDiagnostics(extra: List<String> = emptyList()): String =
    AppDiagnostics.snapshot(extra)
