package com.openmimo.control.protocol

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder

/** 素材会话错误（移植自 iOS OSMOMediaSession.MediaError）。 */
sealed class OsmoMediaError(msg: String) : Exception(msg) {
    object LinkDown : OsmoMediaError("数据链路未就绪")
    object PlaybackNotConfirmed : OsmoMediaError("媒体模式未确认")
    object ListIncomplete : OsmoMediaError("清单接收不完整")
    object EmptyStore : OsmoMediaError("存储未就绪（空流）")
    class DeleteFailed(code: ByteArray) : OsmoMediaError("删除被拒绝: " + code.toHexString())
    object BadResponse : OsmoMediaError("相机应答异常")
}

/**
 * 素材会话编排：媒体（回放）模式进入/维持、分页清单、缩略图、下载、删除。
 * 复用既有控制 datalink（相机单客户端，不新建链路）；HTTP 直连相机 80 端口。
 * 00/27 分块由 app 层从 onMessage 转发给 feed。
 */
class OsmoMediaSession(
    private val link: OsmoCameraLink,
    private val host: String = "192.168.2.1",
    private val scope: kotlinx.coroutines.CoroutineScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + Dispatchers.IO,
    ),
) {

    var onLog: ((String) -> Unit)? = null

    private var cmdCounter = 0
    private var collector: OsmoMediaListCollector? = null
    @Volatile private var beatRunning = false
    private val thumbCache = object : LinkedHashMap<String, ByteArray>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, ByteArray>): Boolean =
            size > 600
    }

    /** 最近一次成功清单是否带库结尾标记（`0c 01`） */
    @Volatile var lastPageReachedEnd = false; private set

    private fun log(line: String) { onLog?.invoke(line) }

    private fun nextCounter(): Long {
        cmdCounter = (cmdCounter + 1) and 0xFFFF
        if (cmdCounter == 0) cmdCounter = 1
        return cmdCounter.toLong()
    }

    // MARK: 媒体模式

    /**
     * 进入媒体（回放）模式：先试 02/0C，1s 内 mediaMode 未置位走 OA4 的 01/01 双脉冲；
     * isConfirmed 由调用方提供（读 02/80 快照 mediaMode 位，唯一完成信号）。
     */
    suspend fun enterPlayback(isConfirmed: suspend () -> Boolean) {
        // 1. 尝试 02/0C（OA4 实测一律 E0，仍按 osmosis 建议先试）
        try {
            val resp = link.request(0x02, 0x0C, OsmoMedia.MEDIA_MODE_ENTER_PAYLOAD, timeoutMs = 1000)
            if (resp.firstOrNull()?.toInt() == 0x00) {
                log("[media] 02/0C accepted")
                if (isConfirmed()) { startBeat(); return }
            }
        } catch (_: Exception) {
            log("[media] 02/0C rejected/timeout → 01/01 pulses")
        }
        // 2. OA4/Pocket 路线：01/01 脉冲 A ×6 @20Hz → 脉冲 B @20Hz 直至确认（≤3s）
        repeat(6) {
            link.send(0x01, 0x01, OsmoMedia.PLAYBACK_PULSE_A)
            delay(50)
        }
        val deadline = System.currentTimeMillis() + 3000
        while (System.currentTimeMillis() < deadline) {
            link.send(0x01, 0x01, OsmoMedia.PLAYBACK_PULSE_B)
            if (isConfirmed()) {
                log("[media] playback confirmed via 01/01 pulses")
                startBeat()
                return
            }
            delay(50)
        }
        throw OsmoMediaError.PlaybackNotConfirmed
    }

    /** 1Hz `00/88` APP_PRESENCE 维持心跳（→ 编码器 0x28）——停止后相机自行脱离媒体/浏览状态 */
    private fun startBeat() {
        stopBeat()
        beatRunning = true
        Thread {
            while (beatRunning) {
                link.sendAppPresenceBeat()
                try { Thread.sleep(1000) } catch (_: InterruptedException) { break }
            }
        }.apply { isDaemon = true; name = "osmo-media-beat"; start() }
        log("[media] presence beat started")
    }

    private fun stopBeat() {
        beatRunning = false
    }

    /**
     * 退出媒体/回放模式。OA4 无被证实的退出命令（相机在链路断开后才自行返回拍摄）。
     * 全程免应答发送：01/01 反向脉冲 → 02/0C leave → 02/E1 工作模式切换回拍摄。
     */
    suspend fun leavePlayback(preferredMode: Int) {
        stopBeat()
        log("[media] leaving playback (mode target 0x${Integer.toHexString(preferredMode)})")
        repeat(6) {
            link.send(0x01, 0x01, byteArrayOf(
                0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x00,
            ))
            delay(50)
        }
        link.send(0x02, 0x0C, byteArrayOf(0x01, 0x01, 0x00, 0x00))
        link.send(0x02, 0xE1, byteArrayOf(preferredMode.toByte()))
        playbackEnterAttempted = false
        log("[media] leave sequence sent")
    }

    /** 00/27 分块喂入口（app 层从 link.onMessage 链式转发） */
    fun feed(cmdSet: Int, cmdId: Int, payload: ByteArray) {
        collector?.accept(cmdSet, cmdId, payload)
    }

    // MARK: 文件清单

    /** 最新一页（无需媒体模式，3 命令序列——query(SD 最新) → ~800ms → trigger → 等流结束） */
    suspend fun fetchNewestPage(): List<OsmoMediaFile> =
        queryAndCollect(cursor = 0x00000001L, sendTrigger = true)

    /** 指定游标查询 */
    suspend fun fetchPage(cursor: Long): List<OsmoMediaFile> =
        queryAndCollect(cursor = cursor, sendTrigger = false)

    /** 更早一页：需要媒体模式（尽力进入），随后 osmosis 分页三帧 */
    suspend fun fetchOlderPage(cursor: Long): List<OsmoMediaFile> {
        tryEnterPlaybackBestEffort()
        val c1 = nextCounter()
        collector = OsmoMediaListCollector(c1)
        runCatching { link.request(0x00, 0x26, OsmoMedia.listQueryPayload(c1, 0x00000001L), timeoutMs = 5000) }
        link.send(0x00, 0x26, OsmoMedia.paginationTriggerPayload())
        return queryAndCollect(cursor = cursor, sendTrigger = false)
    }

    /** 尽力进入媒体模式（删除/翻页等写操作前付费；失败不阻断） */
    private var playbackEnterAttempted = false

    fun tryEnterPlaybackBestEffort() {
        if (playbackEnterAttempted) return
        playbackEnterAttempted = true
        scope.launch {
            try {
                enterPlayback { false }   // 无状态观测：仅发脉冲
                log("[media] playback entered (best effort)")
            } catch (e: Exception) {
                log("[media] playback entry not confirmed (continuing): ${e.message}")
            }
        }
    }

    private suspend fun queryAndCollect(cursor: Long, sendTrigger: Boolean): List<OsmoMediaFile> {
        if (!link.isReady) throw OsmoMediaError.LinkDown
        var attempt = 0
        while (true) {
            attempt++
            val c = nextCounter()
            val col = OsmoMediaListCollector(c)
            collector = col
            runCatching {
                link.request(0x00, 0x26, OsmoMedia.listQueryPayload(c, cursor), timeoutMs = 5000)
            }
            // 收集期间按 ~1Hz 拍维持心跳；~1.6s 处发 trigger（osmosis 快速首页序列）
            val started = System.currentTimeMillis()
            val deadline = started + 8000
            var beatAt = started + 800
            var triggerSent = false
            while (System.currentTimeMillis() < deadline && !col.isComplete) {
                if (!triggerSent && sendTrigger && System.currentTimeMillis() >= started + 1600) {
                    link.send(0x00, 0x26, OsmoMedia.paginationTriggerPayload())
                    triggerSent = true
                }
                if (System.currentTimeMillis() >= beatAt) {
                    link.sendAppPresenceBeat()
                    beatAt += 1000
                }
                delay(100)
            }
            collector = null
            if (col.isComplete) {
                val files = OsmoMediaManifest.decode(col.manifest)
                lastPageReachedEnd = OsmoMediaManifest.reachedEnd(col.manifest)
                log("[media] page cursor=0x${Integer.toHexString(cursor.toShort().toInt())} → ${files.size} files, ${col.dataBytes}B manifest, end=$lastPageReachedEnd")
                return files
            }
            // 空流（仅 start）：存储未挂载/正忙——延迟重试至多 2 次
            if (col.isEmptyStream && attempt < 3) {
                log("[media] empty stream, retry $attempt/2 after 1s")
                delay(1000)
                continue
            }
            throw OsmoMediaError.ListIncomplete
        }
    }

    // MARK: 缩略图 / 下载 / 删除（HTTP 80 + datalink）

    /** 下载 URL（path 保留 '/' 字面量，其余按查询串转义） */
    fun downloadURL(storage: Int, path: String): URL {
        val allowed = "/._-".toSet() + ('a'..'z') + ('A'..'Z') + ('0'..'9')
        val escaped = buildString {
            for (ch in path) {
                if (ch in allowed) append(ch) else append(URLEncoder.encode(ch.toString(), "UTF-8"))
            }
        }
        return URL("http://$host/v2?storage=$storage&path=$escaped")
    }

    /** 缩略图 JPEG（缩略图路径 + .THM，256px），内存缓存 */
    suspend fun fetchThumbnail(file: OsmoMediaFile): ByteArray {
        synchronized(thumbCache) { thumbCache[file.path] }?.let { return it }
        val thumbRaw = file.thumbPath ?: throw OsmoMediaError.BadResponse
        if (thumbRaw.isEmpty()) throw OsmoMediaError.BadResponse
        val url = downloadURL(file.storageIndex, "$thumbRaw.THM")
        val data = httpGet(url) ?: throw OsmoMediaError.BadResponse
        synchronized(thumbCache) { thumbCache[file.path] = data }
        return data
    }

    /**
     * 原文件下载（Range 断点续传）到 destination；progress 0…1。
     * 200 = 服务器忽略 Range：从头开始；206 = 追加余量。
     */
    suspend fun download(file: OsmoMediaFile, destination: File, progress: (Double) -> Unit) {
        withContext(Dispatchers.IO) {
            val partial = File(destination.parentFile, destination.name + ".part")
            var offset = if (partial.exists()) partial.length() else 0L
            val total = file.sizeBytes
            val url = downloadURL(file.storageIndex, "${file.path}.${file.ext}")
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 15000
                instanceFollowRedirects = false
                if (offset > 0) setRequestProperty("Range", "bytes=$offset-")
            }
            val status = try { conn.responseCode } catch (e: Exception) {
                conn.disconnect(); throw e
            }
            if (status !in 200..299) {
                conn.disconnect()
                throw OsmoMediaError.BadResponse
            }
            if (status == 200 && offset > 0) {
                partial.delete()
                offset = 0
            }
            conn.inputStream.use { input ->
                FileOutputStream(partial, offset > 0).use { out ->
                    val buf = ByteArray(64 * 1024)
                    var written = offset
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        out.write(buf, 0, n)
                        written += n
                        if (total > 0) progress(minOf(1.0, written.toDouble() / total))
                    }
                }
            }
            conn.disconnect()
            progress(1.0)
            log("[media] downloaded ${file.name} ${partial.length()}B (status $status)")
            if (total > 0 && partial.length() != total) throw OsmoMediaError.ListIncomplete
            if (destination.exists()) destination.delete()
            if (!partial.renameTo(destination)) {
                partial.copyTo(destination, overwrite = true)
                partial.delete()
            }
        }
    }

    /** 删除（00/28，应答 0000=成功；同一句柄不得重复发送）。删除为写操作，先尽力进入媒体模式 */
    suspend fun delete(file: OsmoMediaFile) {
        tryEnterPlaybackBestEffort()
        delay(400)   // 给脉冲一点生效窗口
        val resp = link.request(
            0x00, 0x28,
            OsmoMedia.deletePayload(listOf(file.handle), nextCounter()),
            timeoutMs = 5000,
        )
        if (resp.size < 2 || resp[0].toInt() != 0x00 || resp[1].toInt() != 0x00) {
            throw OsmoMediaError.DeleteFailed(resp.copyOfRange(0, minOf(4, resp.size)))
        }
        log("[media] deleted ${file.name} handle=0x${Integer.toHexString(file.handle.toShort().toInt())}")
    }

    // MARK: 播放 / 大图预览地址

    /** 原文件 URL（视频播放用；相机 HTTP 支持 Range） */
    fun originalMediaURL(file: OsmoMediaFile): URL =
        downloadURL(file.storageIndex, "${file.path}.${file.ext}")

    /** 视频低清代理 .LRF（720p H.264；OA4 上是否存在需探测） */
    fun proxyMediaURL(file: OsmoMediaFile): URL =
        downloadURL(file.storageIndex, "${file.path}.LRF")

    /** HEAD 探测 */
    suspend fun headOK(url: URL): Boolean = withContext(Dispatchers.IO) {
        try {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                requestMethod = "HEAD"
                connectTimeout = 3000
                readTimeout = 3000
            }
            val code = conn.responseCode
            conn.disconnect()
            code in 200..299
        } catch (_: Exception) {
            false
        }
    }

    /** 任意 GET（照片大图预览等） */
    suspend fun fetchData(url: URL): ByteArray =
        httpGet(url) ?: throw OsmoMediaError.BadResponse

    private suspend fun httpGet(url: URL): ByteArray? = withContext(Dispatchers.IO) {
        try {
            val conn = (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = 5000
                readTimeout = 10000
            }
            val data = if (conn.responseCode in 200..299) {
                conn.inputStream.use { it.readBytes() }
            } else null
            conn.disconnect()
            data?.takeIf { it.isNotEmpty() }
        } catch (_: Exception) {
            null
        }
    }
}
