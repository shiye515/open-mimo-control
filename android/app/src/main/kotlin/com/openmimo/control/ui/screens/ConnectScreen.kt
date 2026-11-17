package com.openmimo.control.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material.icons.outlined.Bluetooth
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openmimo.control.app.ConnectionStep
import com.openmimo.control.app.FlowState
import com.openmimo.control.app.OsmoSession
import com.openmimo.control.protocol.CameraBleWaker
import com.openmimo.control.ui.common.DiagnosticsLogView
import com.openmimo.control.ui.common.copyDiagnostics
import com.openmimo.control.ui.theme.OC
import com.openmimo.control.ui.theme.OcMetrics

/**
 * 连接页（移植自 iOS ConnectScreenView）：权限行（蓝牙/定位/本地网络）、连接按钮、
 * 三步进度可视化、步骤日志（可复制导出）。
 */
@Composable
fun ConnectScreen(
    session: OsmoSession,
    onConnected: () -> Unit,
    onRequestPermissions: (com.openmimo.control.app.PermissionKind) -> Unit,
) {
    val state by session.state.collectAsState()
    val entries by com.openmimo.control.app.StepLogger.entries.collectAsState()
    val clipboard = LocalClipboardManager.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(OC.bg)
            .verticalScroll(rememberScrollState())
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Spacer(Modifier.height(8.dp))
        Text("OpenMimoControl", fontSize = 24.sp, fontWeight = FontWeight.Bold, color = OC.textPrimary)
        Text(
            "Osmo Action 远程控制（蓝牙唤醒 · H.265 预览 · 全量参数 · 素材浏览）",
            fontSize = 12.sp,
            color = OC.textSecondary,
        )

        // 权限行（对齐 iOS permissionRow：蓝牙/定位/本地网络）
        PermissionRow(
            icon = Icons.Outlined.Bluetooth,
            title = "蓝牙",
            purpose = "扫描/唤醒相机、获取热点凭据",
            granted = session.bleWaker.hasBluetoothPermissions(),
            onRequest = { onRequestPermissions(com.openmimo.control.app.PermissionKind.BLUETOOTH) },
        )
        PermissionRow(
            icon = Icons.Filled.LocationOn,
            title = "定位",
            purpose = "读取当前 SSID 与 WiFi 建议（系统要求）",
            granted = session.wifiJoiner.hasLocationPermission(),
            onRequest = { onRequestPermissions(com.openmimo.control.app.PermissionKind.LOCATION) },
        )
        PermissionRow(
            icon = Icons.Filled.Wifi,
            title = "相机热点",
            purpose = "接入相机热点（BLE 凭据 → 系统建议网络）",
            granted = session.wifiJoiner.currentSSID()?.let { session.wifiJoiner.isCameraSSID(it) } == true,
            onRequest = {
                // 触发建议登记（BLE 凭据到位后系统才会弹授权提示）
                session.wifiJoiner.logSink?.invoke("[wifi] 提示：先连接相机获取凭据，登记建议网络后自动接入")
            },
        )

        // 连接按钮
        Button(
            onClick = { session.startFlow() },
            enabled = !stateIsRunning(state),
            modifier = Modifier.fillMaxWidth().height(52.dp),
            shape = RoundedCornerShape(16.dp),
            colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                containerColor = OC.accent,
                contentColor = Color.White,
            ),
        ) {
            Text(
                when (state) {
                    is FlowState.Running -> "连接中…"
                    FlowState.Success -> "已连接（点击重新连接）"
                    else -> "连接相机"
                },
                fontSize = 16.sp,
                fontWeight = FontWeight.Medium,
            )
        }

        // 进度卡（三步可视化）
        when (val s = state) {
            is FlowState.Running -> ProgressCard(s.step)
            is FlowState.Failed -> Box(
                Modifier
                    .fillMaxWidth()
                    .background(OC.card, RoundedCornerShape(14.dp))
                    .padding(14.dp),
            ) {
                Column {
                    Text("连接失败：${s.reason}", color = OC.recRed, fontSize = 13.sp)
                    Text("点「连接相机」重试", color = OC.textSecondary, fontSize = 12.sp)
                }
            }
            FlowState.Success -> Box(
                Modifier
                    .fillMaxWidth()
                    .background(OC.card, RoundedCornerShape(14.dp))
                    .padding(14.dp),
            ) {
                Text("✓ 已连接相机", color = OC.okGreen, fontSize = 13.sp)
            }
            FlowState.Idle -> Unit
        }

        // 步骤日志（对齐 iOS logDisclosure：可展开 + 复制）
        if (entries.isNotEmpty()) {
            Column(
                Modifier
                    .fillMaxWidth()
                    .background(OC.card, RoundedCornerShape(14.dp))
                    .padding(12.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text("步骤日志（${entries.size}）", fontSize = 13.sp, color = OC.textSecondary)
                    Spacer(Modifier.weight(1f))
                    Icon(
                        Icons.Filled.ContentCopy,
                        contentDescription = "复制诊断信息",
                        tint = OC.accent,
                        modifier = Modifier
                            .size(20.dp)
                            .clickable {
                                clipboard.setText(AnnotatedString(copyDiagnostics(entries.map {
                                    "${it.time} | ${it.step} | ${it.purpose} | ${it.content}"
                                })))
                            },
                    )
                }
                Spacer(Modifier.height(6.dp))
                Box(Modifier.heightIn(max = 200.dp)) {
                    DiagnosticsLogView(
                        lines = entries.map { "${it.time} | ${it.step} | ${it.purpose} | ${it.content}" },
                        fontSize = 10,
                        textColor = OC.textSecondary,
                    )
                }
            }
        }

        // 连接成功自动进入控制页
        if (state is FlowState.Success) {
            onConnected()
        }
    }
}

private fun stateIsRunning(state: FlowState): Boolean = state is FlowState.Running

@Composable
private fun PermissionRow(
    icon: ImageVector,
    title: String,
    purpose: String,
    granted: Boolean,
    onRequest: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(OC.card, RoundedCornerShape(14.dp))
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier
                .size(30.dp)
                .background(OC.pill, RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(icon, contentDescription = null, tint = OC.accent, modifier = Modifier.size(16.dp))
        }
        Column(Modifier.weight(1f)) {
            Text(title, fontSize = 15.sp, color = OC.textPrimary)
            Text(purpose, fontSize = 10.sp, color = OC.textSecondary)
        }
        if (granted) {
            Icon(Icons.Filled.CheckCircle, contentDescription = null, tint = OC.okGreen, modifier = Modifier.size(18.dp))
            Text("已授权", fontSize = 12.sp, color = OC.okGreen)
        } else {
            Text(
                "申请",
                fontSize = 12.sp,
                fontWeight = FontWeight.Medium,
                color = Color.White,
                modifier = Modifier
                    .heightIn(min = OcMetrics.RowHeight)
                    .background(OC.accent, CircleShape)
                    .clickable { onRequest() }
                    .padding(horizontal = 12.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun ProgressCard(current: ConnectionStep) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(OC.card, RoundedCornerShape(14.dp))
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val steps = listOf(
            ConnectionStep.WAKING, ConnectionStep.QUERYING, ConnectionStep.JOINING, ConnectionStep.CONNECTING,
        )
        steps.forEach { step ->
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                if (step == current) {
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), color = OC.accent, strokeWidth = 2.dp)
                } else {
                    Box(Modifier.size(14.dp))
                }
                Text(
                    step.label,
                    fontSize = 13.sp,
                    color = if (step == current) OC.textPrimary else OC.textTertiary,
                    fontWeight = if (step == current) FontWeight.Medium else FontWeight.Normal,
                )
            }
        }
    }
}
