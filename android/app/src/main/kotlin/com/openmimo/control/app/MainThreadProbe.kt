package com.openmimo.control.app

import android.os.Handler
import android.os.Looper

/**
 * 主线程健康探针（移植自 iOS AppDiagnostics.startMainThreadProbe）：
 * 0.5s 心跳投递在主线程 Handler 上，实际触发间隔超出预期 200ms 即判定主线程被占
 * （SwiftUI/Compose 重建 / 系统动画 / 回调风暴）。限频 5s 一条，避免卡顿时刷屏。
 */
object MainThreadProbe {

    private const val INTERVAL_MS = 500L
    private const val DRIFT_THRESHOLD_MS = 200L
    private const val LOG_LIMIT_MS = 5_000L

    private val handler = Handler(Looper.getMainLooper())
    private var lastFireAt = 0L
    private var lastLogAt = 0L
    private var running = false

    private val tick = object : Runnable {
        override fun run() {
            val now = System.currentTimeMillis()
            if (lastFireAt != 0L) {
                val drift = now - lastFireAt - INTERVAL_MS
                if (drift > DRIFT_THRESHOLD_MS && now - lastLogAt > LOG_LIMIT_MS) {
                    lastLogAt = now
                    AppDiagnostics.add("[main] 主线程卡顿 ~${drift}ms（0.5s 探针漂移）")
                }
            }
            lastFireAt = now
            handler.postDelayed(this, INTERVAL_MS)
        }
    }

    fun start() {
        if (running) return
        running = true
        AppDiagnostics.add("[main] 主线程探针启动（0.5s 心跳，>200ms 漂移记录）")
        handler.post(tick)
    }
}
