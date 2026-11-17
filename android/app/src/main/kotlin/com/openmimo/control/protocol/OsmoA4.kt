package com.openmimo.control.protocol

/**
 * Osmo Action 4 参数表与控制命令载荷（移植自 iOS OSMOA4；字节布局逐条对齐）。
 *
 * 命令集 0x02 → receiver 0x01；OA4 能力表仅 camcap_common 有推送——各模式值域由本表硬编码驱动。
 */
object OsmoA4 {

    // MARK: 模式与结果码

    const val MODE_PHOTO: Int = 0x05
    const val MODE_VIDEO: Int = 0x01
    const val MODE_SUPER_NIGHT: Int = 0x28
    const val MODE_SLOWMO: Int = 0x00
    const val MODE_TIMELAPSE: Int = 0x02
    const val MODE_HYPERLAPSE: Int = 0x0A

    val MODE_NAMES: List<Pair<Int, String>> = listOf(
        MODE_PHOTO to "照片", MODE_VIDEO to "视频", MODE_SUPER_NIGHT to "超级夜景",
        MODE_SLOWMO to "慢动作", MODE_TIMELAPSE to "延时摄影", MODE_HYPERLAPSE to "运动延时",
    )

    /** 录制命令按模式分派：延时为间隔拍摄走拍照命令 02/01；其余视频类用 02/02。 */
    fun recordCommand(mode: Int): Int = if (mode == MODE_TIMELAPSE) 0x01 else 0x02

    // MARK: 视频格式（02/18 [res, fps, 00, 00, 慢动作倍速]）

    val RESOLUTION_NAMES: Map<Int, String> = mapOf(
        0x10 to "4K 16:9", 0x2D to "2.7K 16:9", 0x0A to "1080p 16:9",
        0x67 to "4K 4:3", 0x5F to "2.7K 4:3",
    )

    val FPS_NAMES: Map<Int, Int> = mapOf(
        1 to 24, 2 to 25, 3 to 30, 4 to 48, 5 to 50, 6 to 60,
        7 to 120, 8 to 240, 0x0A to 100, 0x13 to 200,
    )

    val MODE_RESOLUTIONS: Map<Int, List<Int>> = mapOf(
        MODE_VIDEO to listOf(0x10, 0x2D, 0x0A, 0x67, 0x5F),
        MODE_SUPER_NIGHT to listOf(0x10, 0x2D, 0x0A),
        MODE_TIMELAPSE to listOf(0x10, 0x2D, 0x0A),
        MODE_HYPERLAPSE to listOf(0x10, 0x2D, 0x0A),
    )

    private val FAST = listOf(1, 2, 3, 4, 5, 6, 0x0A, 7)

    val MODE_FPS: Map<Int, List<Int>> = mapOf(
        MODE_VIDEO to listOf(1, 2, 3, 4, 5, 6),
        MODE_SUPER_NIGHT to listOf(1, 2, 3),
        MODE_TIMELAPSE to listOf(2, 3),
        MODE_HYPERLAPSE to listOf(3),
    )

    /** 分辨率级帧率覆盖（视频模式）：4K/2.7K 16:9 至 120、1080p 至 240、4K 4:3 至 60 */
    val FPS_BY_RESOLUTION: Map<Int, List<Int>> = mapOf(
        0x10 to FAST, 0x2D to FAST, 0x67 to listOf(1, 2, 3, 4, 5, 6),
        0x0A to FAST + listOf(0x13, 8),
    )

    /** 当前模式下某分辨率的可选帧率码 */
    fun fpsOptions(mode: Int, res: Int): List<Int> {
        if (mode == MODE_VIDEO) FPS_BY_RESOLUTION[res]?.let { return it }
        return MODE_FPS[mode] ?: listOf(1, 2, 3)
    }

    /** 慢动作可选档（分辨率, 帧率码, 倍速） */
    val SLOWMO_FORMATS: List<Triple<Int, Int, Int>> = listOf(
        Triple(0x10, 7, 4), Triple(0x2D, 7, 4), Triple(0x0A, 7, 4), Triple(0x0A, 8, 8),
    )

    /** 视频格式载荷（OA4：慢动作倍速在末字节；非慢动作 factor=0） */
    fun videoFormatPayload(res: Int, fps: Int, factor: Int = 0): ByteArray =
        byteArrayOf(res.toByte(), fps.toByte(), 0x00, 0x00, factor.toByte())

    // MARK: 照片格式（02/12 [size, ratio]，仅照片模式）

    val PHOTO_FORMATS: List<Triple<Int, Int, String>> = listOf(
        Triple(0, 0, "10MP 4:3"), Triple(0, 1, "10MP 16:9"),
    )

    // MARK: 曝光

    val ISO_CODES: List<Pair<Int, Int>> = listOf(
        0x03 to 100, 0x04 to 200, 0x05 to 400, 0x06 to 800, 0x07 to 1600,
        0x08 to 3200, 0x09 to 6400, 0x0A to 12800,   // OA4 上限 12800
    )
    const val ISO_AUTO: Int = 0x00

    /** 快门速度表（u16 | 小数<<16；bit15=1 → 1/(u16+小数)，否则为秒值），1/8000s-30s */
    val SHUTTER_SPEEDS: LongArray = longArrayOf(
        0x9F40L, 0x9900L, 0x9388L, 0x8FA0L, 0x8C80L, 0x89C4L, 0x87D0L, 0x8640L, 0x84E2L, 0x83E8L,
        0x8320L, 0x8280L, 0x81F4L, 0x8190L, 0x8140L, 0x80FAL, 0x80C8L, 0x80A0L, 0x807DL, 0x8064L,
        0x8050L, 0x803CL, 0x8032L, 0x8028L, 0x801EL, 0x8019L, 0x8014L, 0x800FL, 0x5800CL, 0x800AL,
        0x8008L, 0x8005L, 0x8004L, 0x8003L, 0x58002L, 0x8002L, 0x438001L, 0x198001L,
        0x0001L, 0x30001L, 0x60001L, 0x0002L,
        0x50002L, 0x0003L, 0x20003L, 0x0004L, 0x0005L, 0x0006L, 0x0007L, 0x0008L, 0x0009L, 0x000AL,
        0x000DL, 0x000FL, 0x0014L, 0x0019L, 0x001EL,
    )

    /** 小数字节 → 小数（双粒度：≤9 十分位，≥10 百分位） */
    private fun shutterFraction(dec: Int): Double {
        val d = dec.toDouble()
        return if (d >= 10) d / 100 else d / 10
    }

    private fun denominatorText(x: Double): String {
        val two = "%.2f".format(x)
        return if (two.endsWith("0")) "%.1f".format(x) else two
    }

    /** 快门显示（官方 Mimo 同款）：分数形式 "1/x s"；秒形式 <1s 显示为 1/x，≥1s 显示秒 */
    fun shutterText(raw: Long): String {
        val u16 = (raw and 0xFFFF).toInt()
        val decimal = ((raw shr 16) and 0xFF).toInt()
        return if (u16 and 0x8000 != 0) {
            val x = (u16 and 0x7FFF) + shutterFraction(decimal)
            val txt = if (x == kotlin.math.round(x)) x.toInt().toString() else denominatorText(x)
            "1/$txt s"
        } else {
            val s = u16 + shutterFraction(decimal)
            if (s > 0 && s < 1) {
                val inv = 1 / s
                val txt = if (inv == kotlin.math.round(inv)) inv.toInt().toString() else denominatorText(inv)
                "1/$txt s"
            } else if (decimal == 0) {
                "${s.toInt()} s"
            } else {
                "%.1f s".format(s)
            }
        }
    }

    /** 快门载荷 `02/28 [01, u16 LE, 十分位, 00, 00, 00]` */
    fun shutterPayload(raw: Long): ByteArray {
        val d = ByteArray(6)
        d[0] = 0x01
        d[1] = (raw and 0xFF).toByte()
        d[2] = ((raw shr 8) and 0xFF).toByte()
        d[3] = ((raw shr 16) and 0xFF).toByte()
        // d[4..5] = 00 00
        return d
    }

    /** 快门原始码对应的实际曝光时长（秒）；无法解析返回 null */
    fun shutterSeconds(raw: Long): Double? {
        val u16 = (raw and 0xFFFF).toInt()
        val v = (u16 and 0x7FFF) + shutterFraction(((raw shr 16) and 0xFF).toInt())
        if (v <= 0) return null
        return if (u16 and 0x8000 != 0) 1 / v else v
    }

    /** 相机 RTC 对时载荷（00/4A → 0x28）：`[年 u16 LE, 月, 日, 时, 分, 秒, 毫秒 u16 LE]` */
    fun cameraClockPayload(millis: Long): ByteArray {
        val cal = java.util.Calendar.getInstance()
        cal.timeInMillis = millis
        val d = ByteArray(9)
        val year = cal.get(java.util.Calendar.YEAR)
        d[0] = (year and 0xFF).toByte()
        d[1] = ((year shr 8) and 0xFF).toByte()
        d[2] = (cal.get(java.util.Calendar.MONTH) + 1).toByte()
        d[3] = cal.get(java.util.Calendar.DAY_OF_MONTH).toByte()
        d[4] = cal.get(java.util.Calendar.HOUR_OF_DAY).toByte()
        d[5] = cal.get(java.util.Calendar.MINUTE).toByte()
        d[6] = cal.get(java.util.Calendar.SECOND).toByte()
        val ms = cal.get(java.util.Calendar.MILLISECOND)
        d[7] = (ms and 0xFF).toByte()
        d[8] = ((ms shr 8) and 0xFF).toByte()
        return d
    }

    /** EV 补偿：单字节码 07h–19h，码 16(10h)=0EV，每码 1/3EV，共 19 档 */
    val EV_STEPS: List<Int> = (0x07..0x19).toList()

    fun evName(v: Int): String {
        val thirds = v - 16          // 码 16 = 0EV
        val sign = if (thirds < 0) "-" else "+"
        val a = kotlin.math.abs(thirds)
        val tenth = when (a % 3) { 1 -> "3"; 2 -> "7"; else -> "0" }
        return "$sign${a / 3}.$tenth"
    }

    // MARK: 白平衡（02/2C [mode, kelvin/100, 00, 00, 00]）

    const val WB_AUTO: Int = 0x00
    const val WB_MANUAL: Int = 0x06

    val WB_KELVINS: List<Int> = (2000..10000 step 100).toList()

    fun wbPayload(manual: Boolean, kelvin: Int): ByteArray =
        byteArrayOf(
            (if (manual) WB_MANUAL else WB_AUTO).toByte(),
            (kelvin / 100).toByte(), 0x00, 0x00, 0x00,
        )

    // MARK: 色彩 / 锐度 / 降噪

    /** 色彩档位（OA4 实测：仅 普通 与 D-Log M(0x34) 两档） */
    val COLOR_MODES: List<Pair<Int, String>> = listOf(0x00 to "普通", 0x34 to "D-Log M")
    val SHARPNESS_RANGE: List<Int> = listOf(-2, -1, 0, 1, 2)
    val DENOISE_RANGE: List<Int> = listOf(-2, -1, 0, 1)

    // MARK: 02/8E 参数 TLV

    const val PARAM_FOV: Int = 0x0009
    const val PARAM_EIS: Int = 0x0008
    const val PARAM_PRO: Int = 0x0000
    const val PARAM_ISO_MAX: Int = 0x000F
    const val PARAM_LOW_LIGHT: Int = 0x0030
    const val PARAM_ORIENTATION: Int = 0x0014

    val FOV_MODES: List<Pair<Int, String>> = listOf(
        0x00 to "超广", 0x01 to "广角", 0x02 to "标准（畸变校正）", 0x03 to "窄",
    )
    val EIS_MODES: List<Pair<Int, String>> = listOf(
        0x00 to "关闭", 0x01 to "超强增稳", 0x03 to "超强增稳+",
        0x02 to "地平线增稳", 0x04 to "地平矫正",
    )

    fun fovName(code: Int): String? = FOV_MODES.firstOrNull { it.first == code }?.second
    fun eisName(code: Int): String? = EIS_MODES.firstOrNull { it.first == code }?.second

    /** ISO 上限码表（02/8E pid 0x000F；01=100 保留，值域从 200 起） */
    val ISO_MAX_STEPS: List<Pair<Int, String>> = listOf(
        0x02 to "200", 0x03 to "400", 0x04 to "800", 0x05 to "1600",
        0x06 to "3200", 0x07 to "6400", 0x08 to "12800",
    )

    fun isoMaxName(code: Int): String? = ISO_MAX_STEPS.firstOrNull { it.first == code }?.second

    /** 写参数：`01 01 <type u16 LE> 01 <value>` */
    fun parameterSetPayload(type: Int, value: Int): ByteArray =
        byteArrayOf(0x01, 0x01, (type and 0xFF).toByte(), ((type shr 8) and 0xFF).toByte(), 0x01, value.toByte())

    /** 读参数：`00 01 <type u16 LE>`（应答 `00 00 01 <type> 01 <value>`，值在 [6]） */
    fun parameterGetPayload(type: Int): ByteArray =
        byteArrayOf(0x00, 0x01, (type and 0xFF).toByte(), ((type shr 8) and 0xFF).toByte())

    /** 解析 02/8E 参数读取应答（值在 [6]） */
    fun parameterValue(reply: ByteArray, type: Int): Int? {
        if (reply.size < 7) return null
        if (reply[0].toInt() != 0x00 || reply[1].toInt() != 0x00 || reply[2].toInt() != 0x01) return null
        val replyType = (reply[3].toInt() and 0xFF) or ((reply[4].toInt() and 0xFF) shl 8)
        if (replyType != type) return null
        return reply[6].toInt() and 0xFF
    }

    // MARK: 延时 / 运动延时（02/6C）

    val LAPSE_SAVE_MODES: List<Pair<Int, String>> = listOf(
        0x00 to "仅视频", 0x02 to "JPEG+视频", 0x03 to "RAW+视频",
    )

    /** 延时载荷：`04 00 <save> <间隔 u16 LE, 0.1s> <时长 u32 LE, s> 00×7` */
    fun timelapsePayload(save: Int, intervalTenths: Int, durationS: Long): ByteArray {
        val d = ByteArray(3 + 2 + 4 + 7)
        d[0] = 0x04
        d[1] = 0x00
        d[2] = save.toByte()
        d[3] = (intervalTenths and 0xFF).toByte()
        d[4] = ((intervalTenths shr 8) and 0xFF).toByte()
        for (shift in 0..24 step 8) {
            d[5 + shift / 8] = ((durationS shr shift) and 0xFF).toByte()
        }
        return d
    }

    /** 运动延时速载荷：`0B 00 00 <速度 u16 LE, 0=auto> 00×11` */
    fun hyperlapsePayload(ratio: Int): ByteArray {
        val d = ByteArray(3 + 2 + 11)
        d[0] = 0x0B
        d[1] = 0x00
        d[2] = 0x00
        d[3] = (ratio and 0xFF).toByte()
        d[4] = ((ratio shr 8) and 0xFF).toByte()
        return d
    }

    val HYPERLAPSE_SPEEDS: List<Int> = listOf(0, 2, 5, 10, 15, 30)

    /** 延时间隔（0.1s 单位）：0.5 / 1 / 2 / 3 / 4 / 5 / 6 / 8 / 10 / 15 / 20 / 25 / 30 / 40 秒 */
    val TIMELAPSE_INTERVALS_TENTHS: List<Int> = listOf(
        5, 10, 20, 30, 40, 50, 60, 80, 100, 150, 200, 250, 300, 400,
    )

    /** 延时时长（秒，0=不限）：不限 / 5 / 10 / 20 / 30 / 60 / 120 / 180 / 300 分钟 */
    val TIMELAPSE_DURATIONS_S: List<Long> = listOf(
        0L, 300L, 600L, 1200L, 1800L, 3600L, 7200L, 10800L, 18000L,
    )

    // MARK: 小端读写（移植自 iOS OSMOStatus le16/le32 与 OSMOMedia appendLE*）

    fun le16(b: ByteArray, i: Int): Int =
        (b[i].toInt() and 0xFF) or ((b[i + 1].toInt() and 0xFF) shl 8)

    fun le32(b: ByteArray, i: Int): Long =
        (b[i].toLong() and 0xFF) or ((b[i + 1].toLong() and 0xFF) shl 8) or
            ((b[i + 2].toLong() and 0xFF) shl 16) or ((b[i + 3].toLong() and 0xFF) shl 24)
}
