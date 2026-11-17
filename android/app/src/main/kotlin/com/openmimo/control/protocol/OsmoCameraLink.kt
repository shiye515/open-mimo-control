package com.openmimo.control.protocol

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import java.io.Closeable
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.Date
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** 控制命令错误——应答首字节结果码统一映射（移植自 iOS OSMOCommandError）。 */
sealed class OsmoCommandError : Exception() {
    object LinkDown : OsmoCommandError() { override val message = "未连接相机" }
    object Timeout : OsmoCommandError() { override val message = "命令超时（相机未应答）" }
    class Result(val code: Int) : OsmoCommandError() {
        override val message = when (code) {
            0xE0 -> "命令不支持（E0）"
            0xE3 -> "参数非法或当前状态不允许（E3）"
            0xDF -> "当前不可用（DF，如照片模式下查视频格式）"
            0xD8 -> "存储不可用（D8，如未插 SD 卡）"
            else -> "命令失败（结果码 0x%02X）".format(code)
        }
    }
}

/**
 * OSMO 实时画面 datalink（osmocam 协议；移植自 iOS OSMOCameraLink，协程化）。
 *
 * - 视频流为未加密 H.265 Annex-B（Action 4: 1280x720），经 UDP 9004 传输
 * - TCP 7001 poke（配对身份）→ UDP 握手 → 收发循环 → 心跳/保活 → 状态订阅与轮询
 * - 控制命令单发等应答（按 seq 匹配派发，ack 循环清扫超时）
 */
class OsmoCameraLink(
    private val externalScope: CoroutineScope,
    private val host: String = "192.168.2.1",
) : Closeable {

    // MARK: 常量（实例级，移植自 iOS）

    private val videoHeaderSize = 20
    private val seqStep = 8
    private val ackIntervalMs = 25L
    private val heartbeatIntervalMs = 200L
    private val datalinkPort = 9004
    private val pokePort = 7001

    private val addrApp: Byte = 0x02
    private val addrCamera: Byte = 0x01
    private val addrWiFi: Byte = 0x07
    private val addrLiveView: Byte = 0x41
    private val addrEncoder1: Byte = 0x28
    private val addrEncoder2: Byte = 0x48
    private val addrTopics: Byte = 0x28

    private val appIdentity = "284ae5b8d76b3375a04a6417ad71bea3"
    private val pairToken = "osmo"

    // MARK: 状态

    private val stopped = AtomicBoolean(true)
    private val readyFlag = AtomicBoolean(false)

    private var session: Int = 0
    private var baseSeq: Int = 0
    private var linkSeq = 0
    private var dataSeq = 0
    private var dataCount = 0
    private val messageSeq = AtomicInteger(0xA000)
    private val cursors = IntArray(3)
    private var heartbeatTick = 0
    private var flowRound = 0
    private var ackedCursor = -1
    private var acksSeen = false

    private val lock = Any()
    private val unacked = mutableListOf<Triple<Int, ByteArray, Long>>()   // seq, packet, sentAt
    private val pendingRequests = mutableListOf<PendingRequest>()

    private var socket: DatagramSocket? = null
    private var pokeSocket: Socket? = null
    private val jobs = mutableListOf<Job>()
    private val lastStatusEmitLock = Any()
    private var lastStatusEmitNs = 0L
    private var lastPassedContent: OsmoStatusSnapshot? = null
    private var lastStatsLogAt = 0L
    private var lastResendLogAt = 0L
    private var lastTimeoutLogAt = 0L
    private var lastQueryWaveLogAt = 0L
    private var replyCount = 0
    private var replySumMs = 0
    private var replyMaxMs = 0
    private var timeoutCount = 0
    private var netStatsStart = 0L

    /** 全局唯一活动实例：新实例 start 时停掉旧实例（双会话会互相竞争 UDP 9004 应答） */
    companion object {
        @Volatile private var active: OsmoCameraLink? = null
        private fun le16(out: ByteArray, pos: Int, v: Int) {
            out[pos] = (v and 0xFF).toByte()
            out[pos + 1] = ((v shr 8) and 0xFF).toByte()
        }
        private fun le32(out: ByteArray, pos: Int, v: Long) {
            out[pos] = (v and 0xFF).toByte()
            out[pos + 1] = ((v shr 8) and 0xFF).toByte()
            out[pos + 2] = ((v shr 16) and 0xFF).toByte()
            out[pos + 3] = ((v shr 24) and 0xFF).toByte()
        }
    }

    // MARK: 回调

    var onVideo: ((ByteArray) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null
    /** 相机状态快照变化（内容门控 + ≤0.5s 节流；内容不变不送达——iOS P0 修复移植） */
    var onStatus: ((OsmoStatusSnapshot) -> Unit)? = null
    /** 事件回调（00/76 失败事件由上层 toast） */
    var onEventFailure: ((String) -> Unit)? = null

    /** 状态跟踪：解析推送与查询应答（datalink 协程串行喂数据） */
    val statusTracker = OsmoStatusTracker()

    private fun log(msg: String) { onLog?.invoke(msg) }

    // MARK: 固定载荷（移植自 iOS registerPayload / appInfoReply / encoderRegister）

    private val registerPayload: ByteArray = run {
        val d = mutableListOf<Byte>(0x00)
        d.addAll("APP".toByteArray(Charsets.UTF_8).toList())
        repeat(38) { d.add(0) }
        d.add(0x02)
        repeat(8) { d.add(0) }
        d.add(0x02); d.add(0x08)
        repeat(11) { d.add(0) }
        d.toByteArray()
    }

    private val appInfoReply: ByteArray = run {
        val d = mutableListOf<Byte>(0x00)
        d.addAll("APP".toByteArray(Charsets.UTF_8).toList())
        repeat(37) { d.add(0) }
        d.add(0x02)
        repeat(8) { d.add(0) }
        d.add(0x02); d.add(0x08)
        repeat(10) { d.add(0) }
        d.toByteArray()
    }

    private val encoderRegister = byteArrayOf(
        0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    )

    private val channelParams = listOf(100 to 100, 256 to 400, 20 to 100)
    private val handshakeTail = byteArrayOf(1, 1, 4, 1, 2)

    // MARK: 帧组装器（移植自 iOS FrameAssembler）

    private val assembler = FrameAssembler()

    inner class FrameAssembler {
        var data = ByteArray(0)
        var need = 0
        var synced = false
        var nextSeq: Int? = null
        var params: ByteArray? = null
        var truncated = 0

        fun add(seq: Int, chunk: ByteArray) {
            val lost = nextSeq != null && seq != nextSeq
            nextSeq = (seq + seqStep) and 0xFFFF

            var d = chunk
            val magic = byteArrayOf(0x00, 0x00, 0x01, 0xFF.toByte())
            if (d.size >= 12 && d.copyOfRange(0, 4).contentEquals(magic)) {
                if (data.isNotEmpty()) finish(short = true)
                else if (lost) truncated++
                val needVal = (d[4].toInt() and 0xFF) or ((d[5].toInt() and 0xFF) shl 8) or
                    ((d[6].toInt() and 0xFF) shl 16) or ((d[7].toInt() and 0xFF) shl 24)
                need = needVal
                // 长度域损坏防护：AU 上限 2MB（4K 码率下 IDR ~100KB），超限视为脏数据丢弃
                if (need < 1 || need > 2_000_000) { need = 0; data = ByteArray(0); return }
                var hdrSize = d[8].toInt() and 0x3F
                if (hdrSize < 12 || hdrSize > d.size) hdrSize = 16
                if (d.size > hdrSize) d = d.copyOfRange(hdrSize, d.size)
                data = data + d
                need -= d.size
            } else if (need > 0) {
                if (lost) { finish(short = true); return }
                val take = minOf(d.size, need)
                data = data + d.copyOfRange(0, take)
                need -= take
            } else {
                return
            }
            if (need <= 0 && data.isNotEmpty()) finish()
        }

        private fun finish(short: Boolean = false) {
            val d = data
            data = ByteArray(0)
            need = 0
            if (short) truncated++
            if (d.isEmpty()) return
            val spsPattern = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x42, 0x01)
            val vpsPattern = byteArrayOf(0x00, 0x00, 0x00, 0x01, 0x40, 0x01)
            val isParams = indexOf(d, spsPattern) >= 0 && indexOf(d, vpsPattern) >= 0 && d.size < 200
            if (isParams) { params = d; return }
            val p = params
            if (p != null) {
                onVideo?.invoke(p + d)
                params = null
            } else {
                onVideo?.invoke(d)
            }
            if (indexOf(d, spsPattern) >= 0) synced = true
        }

        private fun indexOf(haystack: ByteArray, needle: ByteArray): Int {
            outer@ for (i in 0..haystack.size - needle.size) {
                for (j in needle.indices) {
                    if (haystack[i + j] != needle[j]) continue@outer
                }
                return i
            }
            return -1
        }
    }

    // MARK: 初始化

    init {
        session = 0x1000 + (0..0xEFFD).random()
        baseSeq = ((0x1000 + (0..0xDFFF).random()) and 0xFFF8)
        linkSeq = baseSeq
        cursors[1] = baseSeq
        cursors[2] = baseSeq
        statusTracker.onLog = { line -> log("[status] $line") }
        statusTracker.onChanged = { snap ->
            if (!stopped.get()) {
                // 内容门控 + ≤0.5s 时间节流（iOS P0 修复移植）：内容不变不送达
                var content = snap.copy(lastUpdate = null)
                val changed = content != lastPassedContent
                if (changed) {
                    val nowNs = System.nanoTime()
                    synchronized(lastStatusEmitLock) {
                        if (nowNs - lastStatusEmitNs < 500_000_000L) return@synchronized
                        lastStatusEmitNs = nowNs
                        lastPassedContent = content
                        onStatus?.invoke(snap)
                    }
                }
            }
        }
        statusTracker.onCaptureModeChanged = { _ ->
            externalScope.launch {
                delay(500)
                if (!stopped.get()) sendStatusQueries()
            }
        }
        statusTracker.onEvent = { eventId, dict ->
            log("[event] $eventId")
            val failed = (dict.optBoolean("is_success", true) == false) ||
                (dict.optInt("success", 1) == 0)
            if (failed) {
                val name = dict.optString("action", eventId)
                onEventFailure?.invoke("相机动作失败：$name")
            }
        }
    }

    // MARK: 生命周期

    fun start() {
        if (active != null && active !== this) {
            active?.log("[osmo] 新 datalink 启动，停掉旧会话")
            active?.stop()
        }
        active = this
        stopped.set(false)
        readyFlag.set(false)
        flowRound = 0
        externalScope.launch { pokeThenRun() }
    }

    override fun close() {
        stopped.set(true)
        if (active === this) active = null
        synchronized(lock) {
            jobs.forEach { it.cancel() }
            jobs.clear()
            pendingRequests.forEach { it.completion(Result.failure(OsmoCommandError.LinkDown)) }
            pendingRequests.clear()
        }
        try { socket?.close() } catch (_: Exception) {}
        try { pokeSocket?.close() } catch (_: Exception) {}
        socket = null
        pokeSocket = null
    }

    fun stop() = close()

    val isReady: Boolean get() = readyFlag.get()

    // MARK: TCP poke

    /** pcap 实证：相机 datalink 未就绪时 TCP 7001 不接听，需持续重试直至就绪（~40s） */
    private suspend fun pokeThenRun() {
        val job = externalScope.launch(Dispatchers.IO) {
            while (!stopped.get() && readyFlag.get() == false) {
                try {
                    val sock = Socket()
                    pokeSocket = sock
                    sock.connect(InetSocketAddress(host, pokePort), 3000)
                    if (stopped.get()) { sock.close(); return@launch }
                    log("[osmo] TCP poke connected")
                    val payload = pairingPayload()
                    val msg = Duml.encode(addrApp, addrWiFi, 0x8092, 0x40, 0x07, 0x45, payload)
                    sock.getOutputStream().use { it.write(msg); it.flush() }
                    log("[osmo] poke sent, closing TCP, starting datalink")
                    delay(400)
                    sock.close()
                    startDatalink()
                    return@launch
                } catch (e: Exception) {
                    log("[osmo] poke failed (${e.message}), retry in 1s")
                    try { pokeSocket?.close() } catch (_: Exception) {}
                    delay(1000)
                }
            }
        }
        jobs.add(job)
    }

    private fun pairingPayload(): ByteArray {
        val identity = appIdentity.toByteArray(Charsets.UTF_8)
        val token = pairToken.toByteArray(Charsets.UTF_8)
        val d = ByteArray(1 + identity.size + 1 + token.size)
        d[0] = identity.size.toByte()
        identity.copyInto(d, 1)
        d[1 + identity.size] = token.size.toByte()
        token.copyInto(d, 2 + identity.size)
        return d
    }

    // MARK: UDP datalink

    private suspend fun startDatalink() {
        log("[osmo] starting UDP datalink → $host:$datalinkPort")
        val job = externalScope.launch(Dispatchers.IO) {
            try {
                val sock = DatagramSocket(null as InetSocketAddress?)
                sock.reuseAddress = true
                socket = sock
                sock.send(makeHandshakePacket())
                log("[osmo] 收到包前先进入接收循环（握手应答由 processPacket 捕获）")
                receiveLoop()
            } catch (e: Exception) {
                if (!stopped.get()) log("[osmo] UDP failed: ${e.message}")
            }
        }
        jobs.add(job)
        // 握手重试循环：30 次 × 0.35s；外层失败重新 poke（相机释放上一客户端会话需要时间）
        externalScope.launch(Dispatchers.IO) {
            var attempt = 1
            while (!stopped.get() && !readyFlag.get()) {
                if (attempt > 30) {
                    flowRound++
                    log("[osmo] 第 $flowRound 轮握手无应答，2s 后重新 poke")
                    try { socket?.close() } catch (_: Exception) {}
                    delay(2000)
                    if (stopped.get() || readyFlag.get()) return@launch
                    pokeThenRun()
                    return@launch
                }
                try {
                    socket?.send(makeHandshakePacket())
                    linkSeq = (linkSeq + seqStep) and 0xFFFF
                } catch (e: Exception) {
                    if (!stopped.get()) log("[osmo] 握手发送失败: ${e.message}")
                }
                attempt++
                delay(350)
            }
        }.let { jobs.add(it) }
    }

    private fun makeHandshakePacket(): DatagramPacket {
        val body = handshakeBody()
        val pkt = makeLinkPacket(type = 0, seq = linkSeq, body = body)
        return DatagramPacket(pkt, pkt.size, InetAddress.getByName(host), datalinkPort)
    }

    private fun handshakeBody(): ByteArray {
        // osmocam struct.pack("<HHHHBH", ...)：20 是 u16；此前 iOS 写 1B 被相机丢弃（实证修正）
        val body = ByteArray(2 + channelParams.size * 11 + handshakeTail.size)
        var pos = 0
        le16(body, pos, baseSeq); pos += 2
        for ((first, second) in channelParams) {
            le16(body, pos, first); pos += 2
            le16(body, pos, second); pos += 2
            le16(body, pos, 1472); pos += 2
            le16(body, pos, 20); pos += 2
            body[pos] = 0; pos += 1
            le16(body, pos, 100); pos += 2
        }
        handshakeTail.copyInto(body, pos)
        return body
    }

    private fun handshakeComplete() {
        if (readyFlag.get()) return
        readyFlag.set(true)
        linkSeq = (baseSeq + seqStep) and 0xFFFF
        dataSeq = linkSeq
        log("[osmo] handshake OK")
        startLiveView()
        startAckLoop()
        startHeartbeatLoop()
    }

    // MARK: 链路包（makeLinkPacket）

    private fun makeLinkPacket(type: Int, seq: Int, body: ByteArray): ByteArray {
        val totalLen = 8 + body.size
        val head = ByteArray(8)
        val lenField = 0x8000 or (totalLen and 0x3FFF)
        le16(head, 0, lenField)
        le16(head, 2, session)
        le16(head, 4, seq)
        head[6] = type.toByte()
        var xor = 0
        for (b in head) xor = xor xor b.toInt()
        head[7] = xor.toByte()
        return head + body
    }

    private fun ackBody(video: Int, data: Int, extra: Int): ByteArray {
        val d = ByteArray(14)
        var pos = 0
        for (cursor in listOf(video, data, extra)) {
            le16(d, pos, cursor); pos += 2
            le16(d, pos, cursor); pos += 2
            pos += 4   // 00×4
        }
        // 末尾 00×2 由 ByteArray 零值保证
        return d
    }

    // MARK: 发送

    /** 单发命令帧。flags 恒为 0x40（请求位）。 */
    fun send(cmdSet: Int, cmdId: Int, payload: ByteArray = ByteArray(0), receiver: Byte? = null) {
        val recv = receiver ?: (if (cmdSet == 0x09 && cmdId == 0xA8) addrLiveView else addrCamera)
        val seq = messageSeq.getAndUpdate { v -> (v + 1) and 0xFFFF }
        val msg = Duml.encode(addrApp, recv, seq, 0x40, cmdSet.toByte(), cmdId.toByte(), payload)
        sendDataPacket(msg)
    }

    private fun sendDataPacket(msg: ByteArray) {
        val sock = socket ?: return
        synchronized(lock) {
            val seq = dataSeq
            val routing = ByteArray(12)
            le16(routing, 0, (seq - seqStep) and 0xFFFF)
            le16(routing, 2, seq)
            // [0,0,0,0] 填充 + dataCount + 1 + [0,0] 由零值数组保证非零两字节：
            routing[8] = dataCount.toByte()
            routing[9] = 1
            val pkt = makeLinkPacket(type = 5, seq = seq, body = routing + msg)
            try {
                sock.send(DatagramPacket(pkt, pkt.size, InetAddress.getByName(host), datalinkPort))
            } catch (e: Exception) {
                if (!stopped.get()) log("[osmo] 发送失败: ${e.message}")
            }
            unacked.add(Triple(seq, pkt, System.currentTimeMillis()))
            if (unacked.size > 256) {
                repeat(unacked.size - 256) { unacked.removeAt(0) }
            }
            dataSeq = (seq + seqStep) and 0xFFFF
            dataCount = (dataCount + 1) and 0xFF
        }
    }

    // MARK: 请求-应答（控制命令层）

    private class PendingRequest(
        val seq: Int, val cmdSet: Int, val cmdId: Int,
        val sentAt: Long, val timeoutMs: Long,
        val completion: (Result<ByteArray>) -> Unit,
    )

    /**
     * 发送控制命令并等待应答（完成回调在调用协程）。UI 层经 ConnectionFlow 串行化。
     * 超时由 ack 循环清扫（25ms tick）。
     */
    suspend fun request(
        cmdSet: Int, cmdId: Int, payload: ByteArray = ByteArray(0),
        receiver: Byte? = null, timeoutMs: Long = 3000,
    ): ByteArray {
        if (!readyFlag.get() || stopped.get()) throw OsmoCommandError.LinkDown
        val result = withTimeoutOrNull(timeoutMs + 2000L) {
            kotlinx.coroutines.suspendCancellableCoroutine<ByteArray> { cont ->
                val recv = receiver ?: (if (cmdSet == 0x09 && cmdId == 0xA8) addrLiveView else addrCamera)
                val seq = messageSeq.getAndUpdate { v -> (v + 1) and 0xFFFF }
                val msg = Duml.encode(addrApp, recv, seq, 0x40, cmdSet.toByte(), cmdId.toByte(), payload)
                var accepted = false
                synchronized(lock) {
                    if (pendingRequests.size < 8) {
                        pendingRequests.add(
                            PendingRequest(seq, cmdSet, cmdId, System.currentTimeMillis(), timeoutMs) { result ->
                                if (cont.isActive) cont.resumeWith(result)
                            },
                        )
                        accepted = true
                    }
                }
                if (accepted) {
                    sendDataPacket(msg)
                } else {
                    cont.resumeWith(Result.failure(OsmoCommandError.Timeout))
                }
                cont.invokeOnCancellation {
                    synchronized(lock) { pendingRequests.removeAll { it.seq == seq } }
                }
            }
        } ?: throw OsmoCommandError.Timeout
        return result
    }

    /** parseDUML 内调用：flags 0x80 的帧按 seq 派发给在途请求 */
    private fun dispatchReply(seq: Int, cmdSet: Int, cmdId: Int, flags: Int, payload: ByteArray) {
        if (flags and 0x80 == 0) return
        var req: PendingRequest? = null
        synchronized(lock) {
            val idx = pendingRequests.indexOfFirst { it.seq == seq }
            if (idx >= 0) req = pendingRequests.removeAt(idx)
        }
        req?.let {
            val rttMs = System.currentTimeMillis() - it.sentAt
            replyCount++
            replySumMs += rttMs.toInt()
            replyMaxMs = maxOf(replyMaxMs, rttMs.toInt())
            val code = payload.firstOrNull()?.toInt() ?: 0xFF
            if (code == 0x00) it.completion(Result.success(payload))
            else it.completion(Result.failure(OsmoCommandError.Result(code)))
        }
    }

    /** ack 循环内调用：清扫超时请求（限频日志，移植自 iOS 诊断埋点） */
    private fun sweepRequestTimeouts() {
        val expired = mutableListOf<PendingRequest>()
        synchronized(lock) {
            if (pendingRequests.isEmpty()) return
            val now = System.currentTimeMillis()
            pendingRequests.removeAll { req ->
                if (now - req.sentAt > req.timeoutMs) { expired.add(req); true } else false
            }
        }
        if (expired.isEmpty()) return
        timeoutCount += expired.size
        val nowNs = System.nanoTime()
        if (lastTimeoutLogAt == 0L || nowNs - lastTimeoutLogAt > 5_000_000_000L) {
            lastTimeoutLogAt = nowNs
            val names = expired.joinToString(",") { "%02X/%02X".format(it.cmdSet, it.cmdId) }
            log("[net] ⏱ 命令超时 $names（累计 $timeoutCount 次）")
        }
        expired.forEach { it.completion(Result.failure(OsmoCommandError.Timeout)) }
    }

    /** 每 5s 汇总一次应答 RTT / 超时统计（诊断） */
    private fun maybeEmitNetStats() {
        val nowNs = System.nanoTime()
        if (netStatsStart == 0L) { netStatsStart = nowNs; return }
        if (nowNs - netStatsStart < 5_000_000_000L) return
        netStatsStart = nowNs
        if (replyCount > 0 || timeoutCount > 0) {
            val avg = if (replyCount > 0) replySumMs / replyCount else 0
            log("[net] 5s统计: 应答${replyCount}条 avg=${avg}ms max=${replyMaxMs}ms 超时=$timeoutCount")
        }
        replyCount = 0; replySumMs = 0; replyMaxMs = 0; timeoutCount = 0
    }

    // MARK: 接收循环

    private fun receiveLoop() {
        val buf = ByteArray(65536)
        val packet = DatagramPacket(buf, buf.size)
        while (!stopped.get()) {
            try {
                val sock = socket ?: break
                if (sock.isClosed) break
                sock.receive(packet)
                val len = packet.length
                if (len < 8) continue
                processPacket(buf.copyOfRange(0, len))
                // 每 30s 一条收包统计
                val nowNs = System.nanoTime()
                if (lastStatsLogAt != 0L && nowNs - lastStatsLogAt > 30_000_000_000L) {
                    lastStatsLogAt = nowNs
                } else if (lastStatsLogAt == 0L) {
                    lastStatsLogAt = nowNs
                }
            } catch (e: Exception) {
                if (!stopped.get()) log("[osmo] 接收循环退出: ${e.message}")
                break
            }
        }
    }

    private fun processPacket(data: ByteArray) {
        val kind = data[6].toInt()
        when (kind) {
            0 -> handshakeComplete()
            2 -> {
                if (data.size <= videoHeaderSize) return
                val seq = (data[4].toInt() and 0xFF) or ((data[5].toInt() and 0xFF) shl 8)
                cursors[0] = seq
                assembler.add(seq, data.copyOfRange(videoHeaderSize, data.size))
            }
            1 -> {
                if (data.size < 34) return
                cursors[0] = (data[10].toInt() and 0xFF) or ((data[11].toInt() and 0xFF) shl 8)
                cursors[1] = (data[18].toInt() and 0xFF) or ((data[19].toInt() and 0xFF) shl 8)
                cursors[2] = (data[26].toInt() and 0xFF) or ((data[27].toInt() and 0xFF) shl 8)
                synchronized(lock) {
                    if (cursors[2] != ackedCursor) {
                        ackedCursor = cursors[2]
                        val idx = unacked.indexOfFirst { it.first == cursors[2] }
                        if (idx >= 0) {
                            repeat(idx + 1) { unacked.removeAt(0) }
                            acksSeen = true
                        }
                    }
                }
                parseDUML(data)
            }
            3 -> {
                if (data.size > 5) {
                    cursors[1] = (data[4].toInt() and 0xFF) or ((data[5].toInt() and 0xFF) shl 8)
                }
                parseDUML(data)
            }
            else -> parseDUML(data)
        }
    }

    private fun parseDUML(data: ByteArray) {
        if (data.size <= 8) return
        val bytes = data.copyOfRange(8, data.size)
        var offset = 0
        while (offset + 13 <= bytes.size) {
            if (bytes[offset] != Duml.SOF) { offset += 1; continue }
            val parsed = Duml.parse(bytes, offset)
            if (parsed == null) { offset += 1; continue }
            val (frame, frameLen) = parsed
            val flags = frame.cmdType.toInt() and 0xFF
            if (flags == 0x40) answerRequest(frame.cmdSet.toInt(), frame.cmdId.toInt(), frame.sender)
            dispatchReply(frame.sequence, frame.cmdSet.toInt(), frame.cmdId.toInt(), flags, frame.payload)
            feedStatus(frame.cmdSet.toInt(), frame.cmdId.toInt(), frame.sender, frame.payload)
            offset += frameLen
        }
    }

    /** DUML 帧 → 状态跟踪器（直接在 datalink 协程执行，天然串行） */
    private fun feedStatus(cmdSet: Int, cmdId: Int, sender: Byte, payload: ByteArray) {
        statusTracker.handle(cmdSet, cmdId, sender, payload)
    }

    /** 相机请求应答（flags 0x40 → 回 0x80）：00/81 回 appInfoReply、00/88 回 1A 00000000、其余 [00] */
    private fun answerRequest(cmdSet: Int, cmdId: Int, sender: Byte) {
        val payload: ByteArray = when (cmdSet to cmdId) {
            0x00 to 0x81 -> appInfoReply
            0x00 to 0x88 -> byteArrayOf(0x1A, 0x00, 0x00, 0x00, 0x00)
            else -> byteArrayOf(0x00)
        }
        val seq = messageSeq.getAndUpdate { v -> (v + 1) and 0xFFFF }
        val msg = Duml.encode(addrApp, sender, seq, 0x80.toByte(), cmdSet.toByte(), cmdId.toByte(), payload)
        sendDataPacket(msg)
    }

    // MARK: 定时循环（ack / 心跳 / 轮询）

    private fun startAckLoop() {
        val job = externalScope.launch(Dispatchers.IO) {
            while (!stopped.get() && isActive) {
                delay(ackIntervalMs)
                sendAck()
                resendUnacked()
                sweepRequestTimeouts()
                maybeEmitNetStats()
            }
        }
        jobs.add(job)
    }

    private fun startHeartbeatLoop() {
        val job = externalScope.launch(Dispatchers.IO) {
            while (!stopped.get() && isActive) {
                delay(heartbeatIntervalMs)
                if (stopped.get()) break
                heartbeatTick++
                // Swift UInt8(Int) 严格转换曾致 SIGTRAP——(tick / 2) & 0xFF 保持一致
                val p = byteArrayOf(
                    1, 0, ((heartbeatTick / 2) and 0xFF).toByte(), 0, 0,
                    0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(), 0xFF.toByte(),
                )
                send(0x00, 0x4F, p, receiver = addrEncoder2)
                // 老协议 statusPoll 保活组合（缺失时相机视频掉到 3 帧/min）
                send(0x00, 0x51, byteArrayOf(0x04), receiver = addrEncoder2)
                send(0x00, 0x82, byteArrayOf(), receiver = addrEncoder2)
                if (heartbeatTick % 5 == 0) {
                    send(0x00, 0x88, encoderRegister, receiver = addrEncoder1)
                }
                if (heartbeatTick % 20 == 0) {
                    send(0x00, 0x00, byteArrayOf(), receiver = addrTopics)
                }
                if (heartbeatTick % 10 == 0) {
                    send(0x00, 0x81, appInfoReply, receiver = addrEncoder2)
                    send(0x00, 0x82, byteArrayOf(0x00), receiver = addrEncoder2)
                }
            }
        }
        jobs.add(job)
    }

    private fun sendAck() {
        val sock = socket ?: return
        val body = ackBody(cursors[0], cursors[1], cursors[2])
        val pkt = makeLinkPacket(type = 4, seq = linkSeq, body = body)
        try {
            sock.send(DatagramPacket(pkt, pkt.size, InetAddress.getByName(host), datalinkPort))
            linkSeq = (linkSeq + seqStep) and 0xFFFF
        } catch (_: Exception) {}
    }

    private fun resendUnacked() {
        synchronized(lock) {
            if (unacked.isEmpty() || !acksSeen) return
            val now = System.currentTimeMillis()
            if (now - unacked[0].third <= 300) return
            if (lastResendLogAt == 0L || now - lastResendLogAt > 5000) {
                lastResendLogAt = now
                log("[net] ↻ 重发 ${unacked.size} 包（300ms 无 ack）")
            }
            val sock = socket ?: return
            for (item in unacked) {
                try {
                    sock.send(DatagramPacket(item.second, item.second.size, InetAddress.getByName(host), datalinkPort))
                } catch (_: Exception) {}
            }
        }
    }

    // MARK: 状态订阅与查询

    /** 订阅命名状态主题（官方 Mimo 同款 20 主题 + 能力表探测） */
    val telemetryTopics = listOf(
        "cam_status", "cam_record_time", "cam_storage", "cam_fov", "cam_photo_param",
        "cam_lapse_param", "cam_video_param_v2", "cam_expo_param", "cam_lens_state",
        "cam_image_effect", "shutter_param", "camcap_common", "cam_custom_mode_params",
        "cam_magnifier_status", "v_quality_enhance_status", "cam_audio_status_v2",
        "audio_timecode_status", "timecode_info", "temp_curve", "cam_imu_calib_info",
    )

    val capabilityProbeTopics = listOf("camcap_common")

    /** osmocam topic_subscription：`02 02 00 00` + id u32 LE + 3×00 + (nameLen+6) u16 + nameLen u16 + name + 00×4 */
    fun topicSubscription(name: String, id: Int): ByteArray {
        val raw = name.toByteArray(Charsets.UTF_8)
        val d = ByteArray(4 + 4 + 3 + 2 + 2 + raw.size + 4)
        var pos = 0
        d[0] = 0x02; d[1] = 0x02; d[2] = 0x00; d[3] = 0x00; pos = 4
        le32(d, pos, id.toLong() and 0xFFFFFFFFL); pos += 4
        pos += 3   // 00×3
        le16(d, pos, raw.size + 6); pos += 2
        le16(d, pos, raw.size); pos += 2
        raw.copyInto(d, pos); pos += raw.size
        // 尾 4×00 已由零值保证
        return d
    }

    private fun sendStatusSubscriptions() {
        statusTracker.expectSubscriptionAcks(telemetryTopics + capabilityProbeTopics)
        telemetryTopics.forEachIndexed { i, name ->
            send(0x00, 0x99, topicSubscription(name, 0x6A00 + i), receiver = addrTopics)
        }
        log("[osmo] 已订阅 ${telemetryTopics.size} 个状态主题")
        capabilityProbeTopics.forEachIndexed { i, name ->
            send(0x00, 0x99, topicSubscription(name, 0x6B00 + i), receiver = addrTopics)
        }
        log("[osmo] 已订阅 ${capabilityProbeTopics.size} 个能力主题（探测）")
    }

    /** 当前拍摄模式下的参数查询（一次一条，间隔 0.3s——osmocam §5.9：单发等应答） */
    private fun sendStatusQueries() {
        val mode = statusTracker.snapshot.captureMode
        var queries: MutableList<Triple<Int, Int, ByteArray>> = mutableListOf(
            Triple(0x02, 0x2D, ByteArray(0)),   // 白平衡
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(OsmoA4.PARAM_FOV)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(OsmoA4.PARAM_EIS)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(OsmoA4.PARAM_ISO_MAX)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(OsmoA4.PARAM_PRO)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(OsmoA4.PARAM_LOW_LIGHT)),
            // 未解析 pid 轮询（诊断观测）
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(0x000A)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(0x0018)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(0x0020)),
            Triple(0x02, 0x8E, OsmoA4.parameterGetPayload(0x0029)),
        )
        if (mode == OsmoA4.MODE_PHOTO) {
            queries.add(0, Triple(0x02, 0x13, ByteArray(0)))   // 照片格式（仅照片模式）
        }
        // 回读波次边界日志（限频 10s；3s 轮询与设置后 0.5s 校准共用此入口）
        val nowNs = System.nanoTime()
        if (lastQueryWaveLogAt == 0L || nowNs - lastQueryWaveLogAt > 10_000_000_000L) {
            lastQueryWaveLogAt = nowNs
            val modeName = OsmoA4.MODE_NAMES.firstOrNull { it.first == mode }?.second ?: "$mode"
            log("[net] 回读波次 ${queries.size} 条（模式 $modeName）")
        }
        queries.forEachIndexed { i, q ->
            externalScope.launch(Dispatchers.IO) {
                delay(i * 300L)
                if (stopped.get()) return@launch
                if (q.first == 0x02 && q.second == 0x8E && q.third.size >= 4) {
                    // pid 在 GET 载荷的 [2],[3]（[0]=读操作 00，[1]=01 常量）
                    statusTracker.noteParameterRequest(
                        (q.third[2].toInt() and 0xFF) or ((q.third[3].toInt() and 0xFF) shl 8),
                    )
                }
                send(q.first, q.second, q.third)
            }
        }
    }

    /** 外部触发的回读（设置成功后 0.5s 校准） */
    fun refreshStatusQueries() {
        externalScope.launch(Dispatchers.IO) {
            delay(500)
            if (!stopped.get()) sendStatusQueries()
        }
    }

    // MARK: 实时预览注册（直播流请求序列）

    /** 公开给媒体模式退出后恢复实时预览（重发注册/订阅序列，相机容忍重复注册） */
    fun startLiveView() {
        if (!readyFlag.get()) return
        send(0x00, 0x81, registerPayload)
        sendStatusSubscriptions()
        send(0x02, 0x09, ByteArray(10) + byteArrayOf(0x03))
        requestKeyframe()
        send(0x00, 0x81, appInfoReply, receiver = addrEncoder2)
        send(0x00, 0x88, encoderRegister, receiver = addrEncoder1)
        send(0x00, 0x81, appInfoReply, receiver = addrEncoder2)
        send(0x00, 0x82, byteArrayOf(0x00), receiver = addrEncoder2)
        log("[osmo] live view requested (Action)")
        // 注册/订阅落定后再查询当前参数（应答由 parseDUML → statusTracker 捕获）
        externalScope.launch(Dispatchers.IO) {
            delay(1000)
            if (!stopped.get()) sendStatusQueries()
        }
        // 相机端改动同步：参数 GET 每 3s 一轮 + 朝向 1s 快轮询
        jobs.add(externalScope.launch(Dispatchers.IO) {
            while (!stopped.get()) {
                delay(3000)
                if (stopped.get() || !readyFlag.get()) break
                sendStatusQueries()
            }
        })
        jobs.add(externalScope.launch(Dispatchers.IO) {
            while (!stopped.get()) {
                delay(1000)
                if (stopped.get() || !readyFlag.get()) break
                statusTracker.noteParameterRequest(OsmoA4.PARAM_ORIENTATION)
                send(0x02, 0x8E, OsmoA4.parameterGetPayload(OsmoA4.PARAM_ORIENTATION))
            }
        })
    }

    /** 素材浏览维持心跳：00/88 APP_PRESENCE（14B）→ 编码器 0x28 */
    fun sendAppPresenceBeat() {
        send(0x00, 0x88, OsmoMedia.PLAYBACK_BEAT_PAYLOAD, receiver = addrEncoder1)
    }

    // MARK: 关键帧请求

    fun requestKeyframe() {
        send(0x09, 0xA8, byteArrayOf(0, 4, 2, 0, 0, 0, 0, 0, 0, 0))
    }

    // MARK: 控制命令（移植自 iOS OSMOA4 extension；串行化由 UI 层 await 链保证）

    /** 切换拍摄模式（02/E1；预览暂停 ~1s，成功后链接层自动重查该模式参数） */
    suspend fun setCaptureMode(mode: Int) {
        request(0x02, 0xE1, byteArrayOf(mode.toByte()), timeoutMs = 4000)
    }

    /** 绝对变焦位置（1.0x–4.0x；lens = 126 × 倍率） */
    suspend fun setZoomPosition(factor: Double) {
        val f = factor.coerceIn(1.0, 4.0)
        val lens = Math.round(126.0 * f).toInt().coerceAtMost(0xFFFF)
        val payload = byteArrayOf(0x0A, 0x4E, (lens and 0xFF).toByte(), ((lens shr 8) and 0xFF).toByte(), 0x00)
        request(0x02, 0xB8, payload, timeoutMs = 2000)
    }

    /** 方向增量变焦（捏合按住期间 ~10Hz 重复调用） */
    fun zoomMove(zoomIn: Boolean, rate: Int = 0x4A) {
        send(0x02, 0xB8, byteArrayOf(0x01, rate.toByte(), (if (zoomIn) 1 else 0).toByte(), 0x00))
    }

    /** 停止变焦（松手必发，否则相机持续变焦） */
    fun zoomStop() {
        send(0x02, 0xB8, byteArrayOf(0xFF.toByte(), 0x00, 0x00, 0x00))
    }

    /** 拍照 / 延时启停（02/01） */
    suspend fun takePhoto() {
        request(0x02, 0x01, byteArrayOf(0x01), timeoutMs = 4000)
    }

    suspend fun stopTimelapse() {
        request(0x02, 0x01, byteArrayOf(0x00), timeoutMs = 4000)
    }

    /** 录制启停（02/02；延时模式走 02/01） */
    suspend fun setRecord(start: Boolean, mode: Int) {
        val cmdId = OsmoA4.recordCommand(mode)
        request(0x02, cmdId, byteArrayOf((if (start) 0x01 else 0x00).toByte()), timeoutMs = 4000)
    }

    suspend fun setExposureMode(auto: Boolean) {
        request(0x02, 0x1E, byteArrayOf((if (auto) 0x01 else 0x04).toByte(), 0x00))
    }

    suspend fun setISO(code: Int) {
        request(0x02, 0x2A, byteArrayOf(code.toByte()))
    }

    suspend fun setShutter(raw: Long) {
        request(0x02, 0x28, OsmoA4.shutterPayload(raw))
    }

    /** EV 补偿（码 16 = 0EV，仅自动曝光） */
    suspend fun setEV(value: Int) {
        request(0x02, 0x2E, byteArrayOf(value.toByte()))
    }

    suspend fun setWhiteBalance(manual: Boolean, kelvin: Int) {
        request(0x02, 0x2C, OsmoA4.wbPayload(manual, kelvin))
    }

    suspend fun setColorProfile(code: Int) {
        request(0x02, 0x42, byteArrayOf(code.toByte()))
    }

    suspend fun setSharpness(v: Int) {
        request(0x02, 0x38, byteArrayOf(v.toByte()))
    }

    suspend fun setDenoise(v: Int) {
        request(0x02, 0x44, byteArrayOf(v.toByte()))
    }

    /** FOV / EIS（02/8E 参数 TLV；可能重启编码器） */
    suspend fun setFOV(code: Int) {
        request(0x02, 0x8E, OsmoA4.parameterSetPayload(OsmoA4.PARAM_FOV, code), timeoutMs = 4000)
    }

    suspend fun setEIS(code: Int) {
        request(0x02, 0x8E, OsmoA4.parameterSetPayload(OsmoA4.PARAM_EIS, code), timeoutMs = 4000)
    }

    /** 通用参数写（02/8E SET） */
    suspend fun writeParameter(type: Int, value: Int) {
        request(0x02, 0x8E, OsmoA4.parameterSetPayload(type, value), timeoutMs = 4000)
    }

    suspend fun setPro(enabled: Boolean) {
        writeParameter(OsmoA4.PARAM_PRO, if (enabled) 0x01 else 0x00)
    }

    suspend fun setISOMax(code: Int) {
        writeParameter(OsmoA4.PARAM_ISO_MAX, code)
    }

    suspend fun setLowLight(enabled: Boolean) {
        writeParameter(OsmoA4.PARAM_LOW_LIGHT, if (enabled) 0x01 else 0x00)
    }

    suspend fun readParameter(type: Int): Int? {
        val reply = request(0x02, 0x8E, OsmoA4.parameterGetPayload(type))
        return OsmoA4.parameterValue(reply, type)
    }

    /** 视频格式（02/18；编码器重启 2-5s） */
    suspend fun setVideoFormat(res: Int, fps: Int, factor: Int = 0) {
        request(0x02, 0x18, OsmoA4.videoFormatPayload(res, fps, factor), timeoutMs = 6000)
    }

    /** 照片格式（02/12 [size, ratio]；仅照片模式） */
    suspend fun setPhotoFormat(size: Int, ratio: Int) {
        request(0x02, 0x12, byteArrayOf(size.toByte(), ratio.toByte()))
    }

    /** 相机 RTC 对时（00/4A → 0x28；连接成功后调用一次） */
    suspend fun setCameraClock(nowMs: Long) {
        request(0x00, 0x4A, OsmoA4.cameraClockPayload(nowMs), receiver = 0x28)
    }

    /** 拍照倒计时（02/4A；载荷 [00 01, 秒 u16 LE, 毫秒 u16 LE]，0/0=关闭） */
    suspend fun setCountdown(seconds: Int, millis: Int) {
        val p = ByteArray(6)
        p[0] = 0x00; p[1] = 0x01
        le16(p, 2, seconds)
        le16(p, 4, millis)
        request(0x02, 0x4A, p)
    }

    /** 延时参数（02/6C timelapse 形） */
    suspend fun setTimelapse(save: Int, intervalTenths: Int, durationS: Long) {
        request(0x02, 0x6C, OsmoA4.timelapsePayload(save, intervalTenths, durationS))
    }

    /** 运动延时速度（02/6C hyperlapse 形；0=自动） */
    suspend fun setHyperlapseSpeed(ratio: Int) {
        request(0x02, 0x6C, OsmoA4.hyperlapsePayload(ratio))
    }
}
