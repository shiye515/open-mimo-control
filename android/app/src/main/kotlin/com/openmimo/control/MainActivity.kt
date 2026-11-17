package com.openmimo.control

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openmimo.control.app.OsmoSession
import com.openmimo.control.app.PermissionKind
import com.openmimo.control.ui.common.OcToastView
import com.openmimo.control.ui.screens.ConnectScreen
import com.openmimo.control.ui.screens.ControlScreen
import com.openmimo.control.ui.screens.MediaBrowseScreen
import com.openmimo.control.app.AppDiagnostics
import com.openmimo.control.ui.theme.OC

/**
 * 顶层路由（对齐 iOS ContentView）：连接页 ↔ 控制页 ↔ 素材页。
 * 权限请求经 ActivityResult 统一入口。
 */
class MainActivity : ComponentActivity() {

    private val session by lazy { OsmoSession(this) }



    private val permissionLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions(),
    ) { }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            AppRoot(session, intent?.getStringExtra("args")) { kind ->
                val perms = session.permissionState.requiredPermissions(kind)
                if (perms.isNotEmpty()) {
                    permissionLauncher.launch(perms.toTypedArray())
                }
            }
        }
        // 自动化钩子：--auto-connect 启动即触发连接流程（锁屏下屏幕点亮时 BLE 扫描可用，
        // 流程各层表现由 diag.log 完整记录——端到端验证无需解锁 UI）
        if (intent?.getStringExtra("args")?.contains("--auto-connect") == true) {
            session.startFlow()
        }
    }
}

@Composable
private fun AppRoot(session: OsmoSession, launchArgs: String?, onRequestPermissions: (PermissionKind) -> Unit) {
    // 顶层路由：connect / control / media
    // 自动化钩子（对齐 iOS --route-* 参数）：launch 时带 --route-control/--route-media 直接开页
    var route by remember {
        val args = launchArgs ?: ""
        mutableStateOf(
            when {
                args.contains("--route-media") -> Route.MEDIA
                args.contains("--route-control") || args.contains("--auto-connect") -> Route.CONTROL
                else -> Route.CONNECT
            },
        )
    }
    val osmoError by session.osmoError.collectAsState()
    val flowState by session.state.collectAsState()

    // 路由变化记录（诊断验证用：自动化钩子/连接成功切换均可见）
    androidx.compose.runtime.LaunchedEffect(route) {
        AppDiagnostics.add("[route] → $route")
    }

    // 连接成功自动进入控制页（对齐 iOS onFlowCompleted）
    androidx.compose.runtime.LaunchedEffect(flowState) {
        if (flowState is com.openmimo.control.app.FlowState.Success && route == Route.CONNECT) {
            route = Route.CONTROL
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(OC.bg),
    ) {
        when (route) {
            Route.CONNECT -> ConnectScreen(
                session = session,
                onConnected = { route = Route.CONTROL },
                onRequestPermissions = onRequestPermissions,
            )
            Route.CONTROL -> ControlScreen(
                session = session,
                onDisconnect = {
                    session.stopLink()
                    route = Route.CONNECT
                },
                onMedia = { route = Route.MEDIA },
            )
            Route.MEDIA -> MediaBrowseScreen(
                session = session,
                onBack = { route = Route.CONTROL },
            )
        }

        // 错误 toast 浮层（顶层统一；对齐 iOS ocToast）
        osmoError?.let { err ->
            OcToastView(
                text = err,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(top = 24.dp)
                    .clickable { session.clearError() },
            )
        }
    }
}

private enum class Route { CONNECT, CONTROL, MEDIA }
