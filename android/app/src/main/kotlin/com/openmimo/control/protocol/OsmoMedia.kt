package com.openmimo.control.protocol

import java.util.Calendar
import java.util.Date

/** 相机媒体文件记录（移植自 iOS OSMOMediaFile；清单解析为纯函数）。 */
data class OsmoMediaFile(
    val path: String,        // 媒体路径（无扩展名，DCIM/…）
    val name: String,        // 文件名（含扩展名，TLV 0d）
    val ext: String,         // 大写扩展名（MP4/JPG）
    val thumbPath: String?,  // 缩略图路径（MISC/THM/…，下载时补 .THM）
    val handle: Long,        // 删除/翻页句柄（清单 T-10）
    val sizeBytes: Long,
    val durationSec: Int,    // 照片为 0
    val isVideo: Boolean,
    val resCode: Int,
    val fpsCode: Int,
    val seq: Int,            // 文件名 _NNNN_ 段
    val capturedAt: Date?,
) {
    /** OA4 仅 SD 卡：storage=0；句柄 bit30 置位为内置存储（storage=1，其他机型） */
    val storageIndex: Int get() = if (handle and 0x40000000L != 0L) 1 else 0
}

/** 载荷构造（字节布局以 osmosis MEDIA_PROTOCOL 为准，移植自 iOS OSMOMedia）。 */
object OsmoMedia {

    private fun putLE16(out: ByteArray, pos: Int, v: Int) {
        out[pos] = (v and 0xFF).toByte()
        out[pos + 1] = ((v shr 8) and 0xFF).toByte()
    }

    private fun putLE32(out: ByteArray, pos: Int, v: Long) {
        out[pos] = (v and 0xFF).toByte()
        out[pos + 1] = ((v shr 8) and 0xFF).toByte()
        out[pos + 2] = ((v shr 16) and 0xFF).toByte()
        out[pos + 3] = ((v shr 24) and 0xFF).toByte()
    }

    /**
     * `00/26` 列表查询载荷（38B）：@4 counter · @10 cursor · @14 页大小 u16 ·
     * @16 清单模式 · @18 仅收藏 · @19-26 视频/照片类型掩码 · @37 仅精彩时刻
     */
    fun listQueryPayload(counter: Long, cursor: Long, pageSize: Int = 0x2D): ByteArray {
        val p = ByteArray(42)
        p[0] = 0x4A; p[1] = 0x00; p[2] = 0x2A; p[3] = 0x10
        putLE32(p, 4, counter)
        p[8] = 0x00; p[9] = 0x00
        putLE32(p, 10, cursor)
        p[14] = pageSize.toByte()
        p[15] = 0x00
        p[16] = 0x0D      // 全清单
        p[17] = 0x01
        p[18] = 0x00      // 不过滤收藏
        // 视频掩码：全部 FF×4；照片掩码：全部 FF×4
        for (i in 19..26) p[i] = 0xFF.toByte()
        // @27-34: 00 01 00 00 00 00 00 00（iOS 逐字节常量）
        p[28] = 0x01
        // @34-36: 00 00 00；@37 高亮过滤：全部（iOS 三个 00 字节常量 + 空）
        return p
    }

    /** `00/26` 分页触发帧（先查 cursor=1 再查页游标，两查询 counter 不同） */
    fun paginationTriggerPayload(): ByteArray {
        val p = ByteArray(14)
        p[0] = 0x4A; p[1] = 0x04; p[2] = 0x0E; p[3] = 0x10
        putLE32(p, 4, 1)
        p[8] = 0x00; p[9] = 0x00
        putLE32(p, 10, 1)
        return p
    }

    /** `00/28` 删除（应答 0000=成功；同一句柄禁止重复发送） */
    fun deletePayload(handles: List<Long>, counter: Long): ByteArray {
        val p = ByteArray(1 + handles.size * 4 + 4 + 1 + 4 + 4)
        var pos = 0
        p[0] = handles.size.toByte()
        pos = 1
        for (h in handles) { putLE32(p, pos, h); pos += 4 }
        putLE32(p, pos, counter); pos += 4
        p[pos] = 0x00; pos += 1
        putLE32(p, pos, handles.size.toLong()); pos += 4
        p[pos] = 0x01; p[pos + 1] = 0x01
        // 尾部 00×2 由零值保证
        return p
    }

    /** 媒体模式尝试（OA4 以 E0 拒绝，仍按 osmosis 建议先试） */
    val MEDIA_MODE_ENTER_PAYLOAD = byteArrayOf(0x01, 0x01, 0x00, 0x01)

    /** `01/01` 回放脉冲 A（~6 帧 @20Hz） */
    val PLAYBACK_PULSE_A = byteArrayOf(
        0x03, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x07, 0x01,
    )

    /** `01/01` 回放脉冲 B（~20Hz 直至 mediaMode 置位） */
    val PLAYBACK_PULSE_B = byteArrayOf(
        0x00, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x04, 0x01,
    )

    /** `00/88` 子命令 0x17 维持心跳（14B，'APP' @5-7） */
    val PLAYBACK_BEAT_PAYLOAD = byteArrayOf(
        0x17, 0x00, 0x46, 0x23, 0x7C, 0x41, 0x50, 0x50, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
    )
}

/**
 * 00/27 分块收集器（移植自 iOS OSMOMediaListCollector）。
 * 子头 `4A <type> <len u16> <counter u16> <seq u16> 00 00`，type 04=start / 01=data / 03=end。
 * 必须按 DUML 命令（00/27）+ counter 过滤——`4A 01` 前缀同时匹配参数推送。
 */
class OsmoMediaListCollector(private val counter: Long) {

    private val chunks = sortedMapOf<Int, ByteArray>()
    var sawStart = false; private set
    var sawEnd = false; private set
    var dataBytes = 0; private set
    private var lastSeq = -1

    /** 返回 true 表示该帧被消费。 */
    fun accept(cmdSet: Int, cmdId: Int, payload: ByteArray): Boolean {
        if (cmdSet != 0x00 || cmdId != 0x27 || payload.size < 10) return false
        if (payload[0].toInt() != 0x4A) return false
        val echoed = OsmoA4.le16(payload, 4)
        if (echoed != (counter and 0xFFFF).toInt()) return false
        val type = payload[1].toInt() and 0xFF
        val len = OsmoA4.le16(payload, 2)
        val seq = OsmoA4.le16(payload, 6)
        when (type) {
            0x04 -> sawStart = true
            0x03 -> sawEnd = true
            0x01 -> {
                val dataLen = maxOf(0, (len and 0x0FFF) - 10)   // len 含 10B 子头
                val isLast = len and 0x1000 != 0
                chunks[seq] = if (dataLen > 0) payload.copyOfRange(10, 10 + dataLen) else ByteArray(0)
                dataBytes += dataLen
                if (isLast) lastSeq = seq
            }
        }
        return true
    }

    /** 清单完整（最后数据块及之前全部到齐）。空存储只有 start、无数据，永远不完整。 */
    val isComplete: Boolean
        get() {
            val last = lastSeq
            if (last < 0) return false
            for (s in 0..last) if (!chunks.containsKey(s)) return false
            return true
        }

    /** 存储未挂载/正忙的特征：有 start、无任何数据（查询过早） */
    val isEmptyStream: Boolean get() = sawStart && chunks.isEmpty()

    val manifest: ByteArray get() = chunks.values.reduce { acc, b -> acc + b }
}

/** 清单解码（osmosis decode_manifest 参考实现的移植）。 */
object OsmoMediaManifest {

    /** 清单是否包含库结尾标记（`0c 01` TLV） */
    fun reachedEnd(buf: ByteArray): Boolean {
        for (i in 0 until buf.size - 1) {
            if (buf[i].toInt() == 0x0C && buf[i + 1].toInt() == 0x01) return true
        }
        return false
    }

    fun decode(buf: ByteArray): List<OsmoMediaFile> {
        // 1. 以媒体路径 TLV（1a total 00 00 00 01 <ascii "DCIM/…">）划记录边界
        data class MediaRecord(val pos: Int, val end: Int, val path: String)
        val medias = mutableListOf<MediaRecord>()
        var i = 0
        while (i + 6 <= buf.size) {
            if (buf[i].toInt() == 0x1A && buf[i + 2].toInt() == 0x00 && buf[i + 3].toInt() == 0x00 &&
                buf[i + 4].toInt() == 0x00 && buf[i + 5].toInt() == 0x01
            ) {
                val total = buf[i + 1].toInt() and 0xFF
                val slen = total - 6
                if (slen > 5 && i + 6 + slen <= buf.size) {
                    val value = String(buf, i + 6, slen, Charsets.ISO_8859_1)
                    if (value.startsWith("DCIM/")) {
                        medias.add(MediaRecord(i, i + 6 + slen, value))
                        i = i + 6 + slen
                        continue
                    }
                }
            }
            i += 1
        }

        // 2. 每条记录在 [前一 path 之后, 下一 path 之前) 内解析
        val files = mutableListOf<OsmoMediaFile>()
        for (k in medias.indices) {
            val lo = if (k == 0) 0 else medias[k - 1].end
            val hi = if (k + 1 < medias.size) medias[k + 1].pos else buf.size
            val path = medias[k].path
            val base = path.substringAfterLast('/')

            // 扩展名：0d <len> <base.ext>，仅文件名字段带扩展名
            var ext = ""
            var j = lo
            while (j < hi - 2) {
                if (buf[j].toInt() == 0x0D) {
                    val flen = buf[j + 1].toInt() and 0xFF
                    if (flen > base.length && j + 2 + flen <= hi) {
                        val head = String(buf, j + 2, base.length, Charsets.ISO_8859_1)
                        if (head == base) {
                            ext = String(buf, j + 2 + base.length, flen - base.length, Charsets.ISO_8859_1)
                            break
                        }
                    }
                }
                j += 1
            }

            // `19 06` 标记锚点：视频 `03 ff 19 06`，照片 `00 [ff|fe|f6|c7|e5|e7] 19 06`，全景 04
            var t = -1
            var typeByte: Int = 0
            var m = lo + 2
            while (m + 1 < hi) {
                if (buf[m].toInt() == 0x19 && buf[m + 1].toInt() == 0x06 && m >= lo + 2) {
                    val t2 = buf[m - 2].toInt() and 0xFF
                    if (t2 == 0x03 || t2 == 0x00 || t2 == 0x04) {
                        t = m
                        typeByte = t2
                        break
                    }
                }
                m += 1
            }

            var handle = 0L
            var size = 0L
            var duration = 0
            var res = 0
            var fps = 0
            var capturedAt: Date? = null
            if (t >= 18) {
                handle = OsmoA4.le32(buf, t - 10)
                size = OsmoA4.le32(buf, t - 14)
                duration = OsmoA4.le16(buf, t - 6)
                res = buf[t - 3].toInt() and 0xFF
                fps = buf[t - 4].toInt() and 0xFF
                capturedAt = fatDate(OsmoA4.le32(buf, t - 18))
            }

            // 缩略图路径：1a … 00 00 00 02（MISC/THM/…），仅在本记录范围内找
            var thumb: String? = null
            j = medias[k].end
            while (j < hi - 6) {
                if (buf[j].toInt() == 0x1A && buf[j + 2].toInt() == 0x00 && buf[j + 3].toInt() == 0x00 &&
                    buf[j + 4].toInt() == 0x00 && buf[j + 5].toInt() == 0x02
                ) {
                    val total = buf[j + 1].toInt() and 0xFF
                    val slen = total - 6
                    if (slen > 0 && j + 6 + slen <= hi) {
                        val value = String(buf, j + 6, slen, Charsets.ISO_8859_1)
                        if (value.startsWith("MISC/")) { thumb = value; break }
                    }
                }
                j += 1
            }

            val extU = (if (ext.startsWith(".")) ext.drop(1) else ext).uppercase()
            val name = if (extU.isEmpty()) base else "$base.$extU"
            files.add(
                OsmoMediaFile(
                    path = path, name = name, ext = extU, thumbPath = thumb,
                    handle = handle, sizeBytes = size, durationSec = duration,
                    isVideo = typeByte == 0x03, resCode = res, fpsCode = fps,
                    seq = fileSeq(base), capturedAt = capturedAt,
                ),
            )
        }
        return files
    }

    /** 文件名 `_NNNN_` 段 → 相机文件序号 */
    private fun fileSeq(base: String): Int {
        base.split("_").forEach { part ->
            if (part.length == 4 && part.all { it.isDigit() }) return part.toIntOrNull() ?: 0
        }
        return 0
    }

    /** FAT/DOS 打包时间（date<<16 | time），2s 分辨率 */
    private fun fatDate(v: Long): Date? {
        val rawDate = (v shr 16).toInt()
        val rawTime = (v and 0xFFFF).toInt()
        val year = ((rawDate shr 9) and 0x7F) + 1980
        val month = (rawDate shr 5) and 0x0F
        val day = rawDate and 0x1F
        val hour = (rawTime shr 11) and 0x1F
        val minute = (rawTime shr 5) and 0x3F
        val second = (rawTime and 0x1F) * 2
        if (year <= 1980 || month !in 1..12 || day !in 1..31) return null
        val cal = Calendar.getInstance()
        cal.set(year, month - 1, day, hour, minute, second)
        cal.set(Calendar.MILLISECOND, 0)
        return cal.time
    }
}
