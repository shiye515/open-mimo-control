package com.openmimo.control.app

import android.content.Context
import android.media.MediaCodec
import android.media.MediaFormat
import android.view.Surface
import com.openmimo.control.protocol.CameraBleWaker
import com.openmimo.control.protocol.hexToBytes
import com.openmimo.control.protocol.OsmoCommandError
import com.openmimo.control.protocol.OsmoA4
import com.openmimo.control.protocol.CameraWifiJoiner
import com.openmimo.control.protocol.HotspotWaker
import com.openmimo.control.protocol.OsmoCameraLink
import com.openmimo.control.protocol.OsmoMediaFile
import com.openmimo.control.protocol.OsmoMediaSession
import com.openmimo.control.protocol.OsmoStatusSnapshot
import com.openmimo.control.protocol.toHexString
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

/** 连接流程状态（移植自 iOS FlowState）。 */
sealed class FlowState {
    object Idle : FlowState()
    data class Running(val step: ConnectionStep) : FlowState()
    object Success : FlowState()
    data class Failed(val step: ConnectionStep, val reason: String) : FlowState()
}

enum class ConnectionStep(val label: String) {
    WAKING("唤醒广播"),       // WKP+MAC反序 反向广播，触发相机热点开启
    JOINING("热点入网"),      // WifiNetworkSuggestion 登记 + 等待接入
    QUERYING("WMS 查询"),     // BLE DUML 帧序（配对→凭据）
    CONNECTING("建立会话"),   // UDP/TCP 控制会话
}

/**
 * 全 App 会话单例（对齐 iOS ConnectionFlow + AppSessionHolder + renderer 组合）：
 * datalink、媒体会话、渲染器、状态流。跨连接复用（相机单客户端）。
 */
class OsmoSession(context: Context) {

    val appContext: Context = context.applicationContext
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    // MARK: 协议层单例

    val diagnostics = AppDiagnostics
    val permissionState = PermissionState(appContext)
    val bleWaker = CameraBleWaker(appContext, scope)
    val wifiJoiner = CameraWifiJoiner(appContext)
    val hotspotWaker = HotspotWaker(appContext)
    var link: OsmoCameraLink? = null; private set
    var mediaSession: OsmoMediaSession? = null; private set

    // MARK: UI 状态流（对齐 iOS @Published）

    private val stateMutable = MutableStateFlow<FlowState>(FlowState.Idle)
    val state: StateFlow<FlowState> = stateMutable

    private val osmoStatusMutable = MutableStateFlow(OsmoStatusSnapshot())
    val osmoStatus: StateFlow<OsmoStatusSnapshot> = osmoStatusMutable

    private val osmoFrameCountMutable = MutableStateFlow(0)
    val osmoFrameCount: StateFlow<Int> = osmoFrameCountMutable

    private val osmoErrorMutable = MutableStateFlow<String?>(null)
    val osmoError: StateFlow<String?> = osmoErrorMutable

    private val osmoBusyMutable = MutableStateFlow(false)
    val osmoBusy: StateFlow<Boolean> = osmoBusyMutable

    private val logsMutable = MutableStateFlow<List<String>>(emptyList())
    val logs: StateFlow<List<String>> = logsMutable

    private val running = MutableStateFlow(false)
    private var flowJob: kotlinx.coroutines.Job? = null

    /** 命令单飞（对齐 iOS osmoBusy：同一时刻至多一条） */
    private val commandMutex = Mutex()
    private var flowCompleted = false

    init {
        AppDiagnostics.init(appContext)
        MainThreadProbe.start()   // 主线程健康探针（0.5s 心跳，卡顿限频记录；对齐 iOS）
        bleWaker.logSink = { line ->
            AppDiagnostics.add("[ble] $line")
            appendLog("[ble] $line")
        }
        wifiJoiner.logSink = { line ->
            AppDiagnostics.add(line)
            appendLog(line)
        }
    }

    private fun appendLog(line: String) {
        val list = logsMutable.value.toMutableList()
        list.add(line)
        if (list.size > 200) repeat(list.size - 200) { list.removeAt(0) }
        logsMutable.value = list
    }

    private fun log(step: String, purpose: String, direction: String = "·", content: String = "") {
        StepLogger.log(step = step, purpose = purpose, direction = direction, content = content)
    }

    // MARK: 连接流程（移植自 iOS ConnectionFlow.run）

    fun startFlow() {
        if (running.value) return
        running.value = true
        flowCompleted = false
        StepLogger.clear()
        flowJob?.cancel()
        log("唤醒广播", "流程开始", content = "用户触发连接")
        stateMutable.value = FlowState.Running(ConnectionStep.WAKING)
        flowJob = scope.launch(Dispatchers.IO) { runFlow() }
    }

    fun cancelFlow() {
        flowJob?.cancel()
        flowJob = null
        running.value = false
        stateMutable.value = FlowState.Idle
        log("唤醒广播", "用户中止流程")
    }

    private suspend fun runFlow() {
        // 步骤 0：复用检测——当前 WiFi 已是相机热点即直连（断线重连全自动，不依赖 BLE）。
        stateMutable.value = FlowState.Running(ConnectionStep.WAKING)
        if (stepReuseJoinedNetwork()) {
            stateMutable.value = FlowState.Running(ConnectionStep.CONNECTING)
            stepConnect()
            stateMutable.value = FlowState.Success
            log("建立会话", "流程完成", content = "复用相机网络直连")
            syncCameraClock()
            flowCompleted = true
            running.value = false
            return
        }

        // waking：蓝牙唤醒广播（触发相机热点开启）
        if (!stepWake()) return

        // BLE 连接 + DUML 配对/凭据
        stateMutable.value = FlowState.Running(ConnectionStep.QUERYING)
        if (!stepBLEDUML()) return

        // 热点入网（建议网络 + 等待接入）
        stateMutable.value = FlowState.Running(ConnectionStep.JOINING)
        if (!stepJoin()) return

        // 建立控制会话
        stateMutable.value = FlowState.Running(ConnectionStep.CONNECTING)
        stepConnect()

        stateMutable.value = FlowState.Success
        log("建立会话", "流程完成", content = "已连接相机")
        syncCameraClock()
        flowCompleted = true
        running.value = false
    }

    private suspend fun stepReuseJoinedNetwork(): Boolean {
        val current = wifiJoiner.currentSSID()
        log("唤醒广播", "复用检测: currentSSID", content = current ?: "nil（不在相机网络）")
        if (current == null || !wifiJoiner.isCameraSSID(current)) return false
        val password = readStoredPassword(current)
        if (password.isNullOrEmpty()) {
            log("唤醒广播", "在相机网络但无记忆密码", content = "走完整流程（BLE 取凭据）")
            return false
        }
        log("唤醒广播", "已在相机网络", content = "跳过唤醒/BLE，直接建立会话")
        // 直连时后台补 BLE 会话（不阻塞主流程）：datalink 开放条件 = 配对被相机屏幕批准；
        // BLE keepalive 是相机持续推流的条件（iOS 实证：无 BLE 会话时相机 1-2 帧后停止推流）
        scope.launch(Dispatchers.IO) {
            bleWaker.keepBLEAlive(true)
            if (bleWaker.bleSessionReady) {
                log("唤醒广播", "BLE 会话已建立", content = "keepalive 保活中 → 视频推流恢复")
                return@launch
            }
            for (round in 1..3) {
                log("唤醒广播", "后台 BLE 会话 第$round/3 轮", content = "若相机屏幕弹 OSMO 提示，请按确认！")
                val cred = bleWaker.connectAndGetCredentials(45_000)
                if (cred != null) {
                    log("唤醒广播", "后台 BLE 会话建立", content = "keepalive 保活中 → 视频推流恢复")
                    return@launch
                }
                if (round < 3) {
                    val macHex = prefs().getString("camera.mac", null)
                    if (macHex == null) break
                    val mac = macHex.hexToBytes() ?: break
                    log("唤醒广播", "BLE 扫描失败，发唤醒广播触发相机恢复广播")
                    hotspotWaker.wakeCamera(mac.reversedArray())
                    kotlinx.coroutines.delay(6000)
                }
            }
            log("唤醒广播", "后台 BLE 会话未建立（3 轮）", content = "相机推流可能停止，可点连接相机重试")
        }
        return true
    }

    /** 步骤 1：BLE 唤醒广播。相机休眠时热点关闭，需反向广播 WKP+MAC反序触发热点开启。 */
    private suspend fun stepWake(): Boolean {
        // MAC 来源：历史记录（SharedPreferences）或 BLE 扫描现场解析（优先缓存）
        var mac: ByteArray? = null
        val cachedHex = prefs().getString("camera.mac", null)
        if (cachedHex != null) {
            mac = cachedHex.hexToBytes()
            log("唤醒广播", "使用缓存 MAC", content = cachedHex)
        }
        if (mac == null) {
            log("唤醒广播", "无缓存 MAC，启动 BLE 扫描解析相机广播")
            for (round in 1..3) {
                log("唤醒广播", "MAC 扫描第$round/3 轮")
                mac = bleWaker.scanOnceForMAC(8000)
                if (mac != null) break
                log("唤醒广播", "扫描未命中", content = "轮次 $round")
            }
        }
        val macBytes = mac
        if (macBytes == null) {
            fail(ConnectionStep.WAKING, "未能在广播中解析相机 MAC（相机是否开机且在附近？）")
            return false
        }
        prefs().edit().putString("camera.mac", macBytes.toHexString()).apply()
        val reversed = macBytes.reversedArray()
        log("唤醒广播", "唤醒广播参数",
            content = "MAC=${macBytes.toHexString()} 反序=${reversed.toHexString()}")

        // 广播 2 轮 × 2.5s
        hotspotWaker.wakeCamera(reversed)
        kotlinx.coroutines.delay(6000)
        log("唤醒广播", "唤醒广播完成", content = "等待相机热点开启")
        return true
    }

    /** 步骤 1.5：BLE 连接相机 → DUML 配对帧序 → 凭据（明文应答） */
    private suspend fun stepBLEDUML(): Boolean {
        log("WMS 查询", "BLE 连接相机并发配对帧序")
        // osmocam §3.3：WiFi datalink 期间 BLE 必须保持连接（保活）
        bleWaker.keepBLEAlive(true)
        val cred = bleWaker.connectAndGetCredentials(120_000)
        if (cred != null) {
            log("WMS 查询", "BLE 凭据获取成功", content = "ssid=${cred.ssid} password=${cred.password}")
            wifiJoiner.remember(cred.ssid, cred.password)
            return true
        }
        // 降级：本地已有记忆凭据（历史成功/手动输入）时继续入网——BLE 仅首次配对必需
        val rememberedSSID = prefs().getString("camera.ssid", null)
        val rememberedPwd = readStoredPassword(rememberedSSID ?: "")
        if (!rememberedPwd.isNullOrEmpty() && rememberedSSID != null) {
            log("WMS 查询", "BLE 未取得凭据，使用本地记忆凭据降级继续",
                content = "ssid=$rememberedSSID（${bleWaker.status}）")
            return true
        }
        fail(ConnectionStep.QUERYING, "BLE 凭据获取失败：${bleWaker.status}")
        return false
    }

    /** 步骤 2：热点入网（建议网络登记 + 等待系统接入） */
    private suspend fun stepJoin(): Boolean {
        val ssid = prefs().getString("camera.ssid", null) ?: run {
            fail(ConnectionStep.JOINING, "无相机热点 SSID（BLE 未取得凭据且无记忆）")
            return false
        }
        val password = readStoredPassword(ssid)
        log("热点入网", "登记建议网络", content = "ssid=$ssid 密码长度=${password?.length ?: 0}")
        wifiJoiner.suggest(ssid, password)
        val joined = wifiJoiner.awaitJoin(ssid)
        if (joined) {
            log("热点入网", "入网成功", content = "currentSSID=$ssid")
            return true
        }
        fail(ConnectionStep.JOINING, "12s 内未接入热点（热点未广播/建议未批准/密码错误；可在系统 WLAN 手动选择一次）")
        return false
    }

    /** 步骤 3：建立 OSMO datalink（复用直连也走此步） */
    private suspend fun stepConnect() {
        stopOSMOLink()   // 每次连接会话都重建链路：复用旧链路会把死连接带回来
        startOSMOLiveView()
    }

    private fun stopOSMOLink() {
        link?.stop()
        link = null
        osmoFrameCountMutable.value = 0
        log("建立会话", "OsmoCameraLink stopped")
    }

    private fun startOSMOLiveView() {
        if (link != null) return
        val newLink = OsmoCameraLink(scope)
        link = newLink
        newLink.onLog = { line ->
            AppDiagnostics.add("[osmo] $line")
            appendLog("[osmo] $line")
            StepLogger.log("建立会话", line, content = "")
        }
        newLink.onVideo = { data ->
            rendererFeed(data)
            scope.launch(Dispatchers.Main) {
                val isFirst = osmoFrameCountMutable.value == 0
                osmoFrameCountMutable.value += 1
                if (isFirst) {
                    log("建立会话", "OSMO 首帧视频", content = "${data.size}B → 解码渲染")
                }
            }
        }
        newLink.onStatus = { snap ->
            osmoStatusMutable.value = snap
        }
        newLink.onEventFailure = { message ->
            osmoErrorMutable.value = message
        }
        newLink.onLog?.invoke("[osmo] OsmoCameraLink started (osmocam protocol, H.265)")
        newLink.start()
        mediaSession = OsmoMediaSession(newLink).also { ms ->
            ms.onLog = { line ->
                AppDiagnostics.add(line)
                appendLog(line)
            }
        }
    }

    private suspend fun syncCameraClock() {
        osmoCommand("相机对时") { it.setCameraClock(System.currentTimeMillis()) }
    }

    private fun fail(step: ConnectionStep, reason: String) {
        stateMutable.value = FlowState.Failed(step, reason)
        log(step.label, "流程失败", content = reason)
    }

    // MARK: 控制命令（对齐 iOS osmoCommand：单飞 + 结果码/超时错误捕获 + StepLogger）

    suspend fun <T> osmoCommand(name: String, op: suspend (OsmoCameraLink) -> T): T? {
        val l = link ?: run {
            osmoErrorMutable.value = OsmoCommandError.LinkDown.message
            log("控制命令", "✗ ${name}失败", content = OsmoCommandError.LinkDown.message ?: "")
            return null
        }
        if (osmoBusy.value) {
            val msg = "上一条命令执行中，请稍候"
            osmoErrorMutable.value = msg
            log("控制命令", "✗ ${name}被拒", content = "单飞：上一条命令在途（用户点击被吞）")
            return null
        }
        osmoBusyMutable.value = true
        try {
            val t0 = System.nanoTime()
            val r = op(l)
            val ms = (System.nanoTime() - t0) / 1_000_000
            osmoErrorMutable.value = null
            log("控制命令", "✓ $name", content = "命令往返 ${ms}ms")
            return r
        } catch (e: OsmoCommandError) {
            val ms = (System.nanoTime()) / 1_000_000
            osmoErrorMutable.value = e.message
            log("控制命令", "✗ ${name}失败", content = "${e.message}")
            return null
        } catch (e: Exception) {
            osmoErrorMutable.value = e.message ?: "命令失败"
            log("控制命令", "✗ ${name}失败", content = "${e.message}")
            return null
        } finally {
            osmoBusyMutable.value = false
        }
    }

    /** 快门/录制按钮：按模式与录制状态分派（specs「录制控制」） */
    suspend fun toggleRecord() {
        val mode = osmoStatus.value.captureMode ?: OsmoA4.MODE_VIDEO
        if (mode == OsmoA4.MODE_PHOTO) {
            osmoCommand("拍照") { it.takePhoto() }
            return
        }
        val recording = osmoStatus.value.recordState == 2
        val name = when {
            mode == OsmoA4.MODE_TIMELAPSE ->
                if (recording) "停止延时" else "开始延时"
            else -> if (recording) "停止录制" else "开始录制"
        }
        osmoCommand(name) { it.setRecord(!recording, mode) }
    }

    /** 模式切换：录制中先停止再切换；成功后链接层自动重查该模式参数 */
    suspend fun switchMode(mode: Int) {
        if (mode == osmoStatus.value.captureMode) return
        if (osmoStatus.value.recordState == 2) {
            val current = osmoStatus.value.captureMode ?: OsmoA4.MODE_VIDEO
            osmoCommand("录制中先停止") { it.setRecord(false, current) }
        }
        osmoCommand("切换模式") { it.setCaptureMode(mode) }
        link?.refreshStatusQueries()   // 双保险：推送未到时也刷新
    }

    /** 设置命令成功后的回读校准（specs「设置 → 应答 → 回读」） */
    fun refreshOSMOQueries() {
        link?.refreshStatusQueries()
    }

    /** 清除错误 toast（点击浮层） */
    fun clearError() {
        osmoErrorMutable.value = null
    }

    /** 停止 datalink（断开连接时调用） */
    fun stopLink() {
        stopOSMOLink()
        mediaSession = null
    }

    /** 错误上报（对齐 iOS osmoError toast 通道） */
    fun reportError(msg: String) {
        osmoErrorMutable.value = msg
        AppDiagnostics.add("[error] $msg")
    }

    /** 格式类命令成功后编码器重启：延迟等起稳后重发 live view 请求恢复预览，并刷新回读 */
    suspend fun osmoFormatCommand(name: String, op: suspend (OsmoCameraLink) -> Boolean): Boolean? {
        val ok = osmoCommand(name, op)
        if (ok == true) {
            scope.launch(Dispatchers.IO) {
                kotlinx.coroutines.delay(2500)
                link?.startLiveView()
                refreshOSMOQueries()
            }
        }
        return ok
    }

    // MARK: 变焦

    fun zoomMove(zoomIn: Boolean) {
        link?.zoomMove(zoomIn)
    }

    fun zoomStop() {
        link?.zoomStop()
    }

    suspend fun setZoomPosition(factor: Double) {
        osmoCommand("变焦") { it.setZoomPosition(factor) }
    }

    // MARK: 媒体

    suspend fun fetchNewestPage(): List<OsmoMediaFile> {
        val ms = mediaSession ?: throw OsmoMediaSessionError("datalink 未建立")
        return ms.fetchNewestPage()
    }

    suspend fun fetchOlderPage(cursor: Long): List<OsmoMediaFile> {
        val ms = mediaSession ?: throw OsmoMediaSessionError("datalink 未建立")
        return ms.fetchOlderPage(cursor)
    }

    suspend fun deleteFile(file: OsmoMediaFile) {
        val ms = mediaSession ?: throw OsmoMediaSessionError("datalink 未建立")
        ms.delete(file)
    }

    class OsmoMediaSessionError(msg: String) : Exception(msg)

    private fun prefs() = appContext.getSharedPreferences("openmimo", Context.MODE_PRIVATE)

    private fun readStoredPassword(ssid: String): String? =
        wifiJoiner.readPassword(ssid) ?: prefs().getString("camera.wifi_password", null)



    // MARK: H.265 渲染（MediaCodec；surface 由 UI attach）

    private val rendererLock = Any()
    private var codec: MediaCodec? = null
    private var codecInputSurfaceSet = false
    private var decodeThread: Thread? = null
    @Volatile private var spsBytes: ByteArray? = null
    @Volatile private var pendingSurface: Surface? = null
    @Volatile private var configuredForSPS: ByteArray? = null
    private val pendingAUs = ArrayDeque<ByteArray>()

    /** UI 挂载 Surface 后启动解码线程 */
    fun attachRenderSurface(surface: Surface) {
        synchronized(rendererLock) {
            pendingSurface = surface
            codecInputSurfaceSet = true
        }
        ensureDecodeThread()
    }

    fun detachRenderSurface() {
        synchronized(rendererLock) {
            pendingSurface = null
            codecInputSurfaceSet = false
            codec?.stop()
            codec?.release()
            codec = null
        }
    }

    private fun rendererFeed(au: ByteArray) {
        synchronized(rendererLock) {
            if (pendingAUs.size < 30) pendingAUs.addLast(au)
        }
        ensureDecodeThread()
    }

    private fun ensureDecodeThread() {
        if (decodeThread?.isAlive == true) return
        decodeThread = Thread {
            decodeLoop()
        }.apply { name = "osmo-h265-decode"; start() }
    }

    /** AnnexB AU 解码循环（MediaCodec 同步模式；SPS 变化重建 codec） */
    private fun decodeLoop() {
        while (true) {
            val surface = synchronized(rendererLock) { pendingSurface }
            if (surface == null) {
                try { Thread.sleep(100) } catch (_: InterruptedException) { return }
                continue
            }
            val au = synchronized(rendererLock) { pendingAUs.removeFirstOrNull() } ?: run {
                try { Thread.sleep(20) } catch (_: InterruptedException) { return }
                continue
            }

            // 参数集检测（SPS 42 01 / VPS 40 01 / PPS 44 01 前导 00 00 00 01）
            val nalus = splitAnnexB(au)
            var vps: ByteArray? = null; var sps: ByteArray? = null; var pps: ByteArray? = null
            var containsIDR = false
            for (n in nalus) {
                if (n.size < 2) continue
                val type = (n[0].toInt() shr 1) and 0x3F
                when (type) {
                    32 -> vps = n
                    33 -> sps = n
                    34 -> pps = n
                    19, 20 -> containsIDR = true
                }
            }
            val paramsAU = vps != null && sps != null && pps != null && au.size < 200
            if (paramsAU || spsBytes == null) {
                if (sps != null && sps != spsBytes) {
                    synchronized(rendererLock) {
                        // 参数集变化（编码器重启）→ flush + 重建 format
                        try { codec?.flush() } catch (_: Exception) {}
                        configuredForSPS = null
                    }
                }
            }
            val currentSps = sps ?: spsBytes
            if (paramsAU && currentSps != null && configuredForSPS == null) {
                synchronized(rendererLock) {
                    if (configuredForSPS == null) {
                        setupCodec(surface, vps!!, sps!!, pps!!)
                        configuredForSPS = sps
                        spsBytes = sps
                    }
                }
                if (!containsIDR) continue   // 参数集 AU 本身不送解码
            }
            val codecRef = synchronized(rendererLock) { codec }
            if (codecRef == null) continue

            try {
                val inIdx = codecRef.dequeueInputBuffer(10_000)
                if (inIdx >= 0) {
                    val inBuf = codecRef.getInputBuffer(inIdx) ?: continue
                    if (au.size <= inBuf.capacity()) {
                        inBuf.clear()
                        inBuf.put(au)
                        val flags = if (containsIDR) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                        codecRef.queueInputBuffer(inIdx, 0, au.size, presentationUs(), flags)
                    }
                }
                val info = MediaCodec.BufferInfo()
                val outIdx = codecRef.dequeueOutputBuffer(info, 10_000)
                when {
                    outIdx >= 0 -> codecRef.releaseOutputBuffer(outIdx, true)
                    outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED ->
                        log("建立会话", "解码 format 变化: ${codecRef.outputFormat}")
                }
            } catch (e: Exception) {
                log("建立会话", "解码异常: ${e.message} → flush 自愈")
                try { codecRef.flush() } catch (_: Exception) {}
            }
        }
    }

    private var presentationBaseUs = -1L
    private var presentationCount = 0L

    /** 30fps 假 PTS（实时流立即渲染；从首个 AU 起计） */
    private fun presentationUs(): Long {
        if (presentationBaseUs < 0) presentationBaseUs = System.nanoTime() / 1000
        presentationCount++
        return presentationBaseUs + presentationCount * 33_333L
    }

    private fun setupCodec(surface: Surface, vps: ByteArray, sps: ByteArray, pps: ByteArray) {
        try {
            val csd = byteArrayOf(0, 0, 0, 1) + vps + byteArrayOf(0, 0, 0, 1) + sps + byteArrayOf(0, 0, 0, 1) + pps
            val format = MediaFormat.createVideoFormat("video/hevc", 1280, 720)
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 1_000_000)
            format.setByteBuffer("csd-0", java.nio.ByteBuffer.wrap(csd))
            val c = MediaCodec.createDecoderByType("video/hevc")
            c.configure(format, surface, null, 0)
            c.start()
            codec = c
            AppDiagnostics.add("[render] HEVC decoder 配置成功（csd ${csd.size}B）")
        } catch (e: Exception) {
            AppDiagnostics.add("[render] HEVC decoder 配置失败: ${e.message}")
            codec = null
        }
    }

    /** AnnexB 分割（00 00 01 / 00 00 00 01 start code 之间的 NALU，不含 start code） */
    private fun splitAnnexB(data: ByteArray): List<ByteArray> {
        val marks = mutableListOf<Int>()
        var i = 0
        while (i + 2 < data.size) {
            if (data[i].toInt() == 0 && data[i + 1].toInt() == 0 && data[i + 2].toInt() == 1) {
                marks.add(i + 2)
                i += 3
            } else {
                i += 1
            }
        }
        if (marks.isEmpty()) return emptyList()
        val out = mutableListOf<ByteArray>()
        for (k in marks.indices) {
            val m = marks[k]
            val naluStart = m + 1
            val end = if (k + 1 < marks.size) marks[k + 1] - 2 else data.size
            if (end > naluStart) out.add(data.copyOfRange(naluStart, end))
        }
        return out
    }

}
