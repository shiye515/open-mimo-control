package com.openmimo.control.protocol

import java.util.Date

/**
 * OSMO 相机状态快照——datalink 上全部可获取状态的汇总（移植自 iOS OSMOStatusSnapshot）。
 *
 * 数据来源：
 * - `02/80` 推送 ~10/s：录制态/工作态/存储/剩余张数秒数/已录秒数/拍摄模式
 * - `0D/02` 推送 ~1/s：电池电压/电流/温度/电量
 * - `02/DC` 推送：microSD 与内置存储
 * - `00/99` 命名主题推送：cam_expo_param / cam_video_param_v2 / cam_image_effect /
 *   cam_lapse_param / cam_record_time / cam_lens_state 等
 * - 查询应答：`02/19` `02/1F` `02/2B` `02/29` `02/2D` `02/13` `02/8E`
 */
data class OsmoStatusSnapshot(
    // 02/80 相机状态推送
    var recordState: Int? = null,        // 0 空闲 1 启动中 2 录制中 3 停止中
    var isWritingFile: Boolean = false,  // bit 0x08
    var mediaMode: Boolean = false,      // bit 0x40
    var workMode: Int? = null,           // 0 照片/延时 1 视频 2 相机本地回放
    var totalStorageMB: Long? = null,
    var freeStorageMB: Long? = null,
    var photosLeft: Long? = null,
    var videoSecondsLeft: Long? = null,
    var clipSeconds: Long? = null,
    var captureMode: Int? = null,
    // 0D/02 电池推送
    var batteryPercent: Int? = null,
    var batteryVoltageMV: Int? = null,
    var batteryCurrentMA: Int? = null,   // 负值=放电
    var batteryTempDeciC: Int? = null,   // 0.1 °C
    // 02/DC 存储推送
    var sdTotalMB: Long? = null,
    var sdFreeMB: Long? = null,
    var internalTotalMB: Long? = null,
    var internalFreeMB: Long? = null,
    // 查询应答
    var videoResolutionCode: Int? = null,
    var videoFpsCode: Int? = null,
    var exposureMode: Int? = null,       // 01 自动 04 手动
    var isoCode: Int? = null,            // 00=自动
    var shutterRaw: Long? = null,        // u16 | 十分位<<16
    var wbMode: Int? = null,             // 00 自动 06 手动色温
    var wbKelvin: Int? = null,
    var queryErrors: MutableMap<String, Int> = mutableMapOf(),
    var photoSizeCode: Int? = null,
    var photoRatioCode: Int? = null,
    var fovValue: Int? = null,
    var eisValue: Int? = null,
    var isoMaxCode: Int? = null,
    var lowLightCode: Int? = null,
    var orientationCode: Int? = null,    // 0 上 / 1 左横置 / 2 下 / 3 右横置
    var proOnCode: Int? = null,
    var recordSeconds: Long? = null,     // cam_record_time 推送 u32 @0
    var rawTopicSamples: Map<String, String> = emptyMap(),
    var rawParams: Map<Int, String> = emptyMap(),
    var topicDecoded: Map<String, String> = emptyMap(),
    var rawParam0A: Int? = null,
    var portraitMode: Boolean? = null,
    var zoomFactor: Double? = null,      // cam_lens_state @14 ÷ 126
    // 00/99 命名主题推送
    var expoCompValue: Int? = null,      // 码 16 = 0EV，07h-19h
    var lightMeterValue: Int? = null,
    var effectiveISO: Long? = null,      // cam_expo_param u16 @16
    var effectiveShutter: Long? = null,  // u16 @20 + 小数<<16
    var photoShutter: Int? = null,       // u16 @2
    var digitalGain: Int? = null,        // u16 @33
    var digitalGainFine: Int? = null,    // @35
    var isoStepCode: Int? = null,        // @11
    var colorProfile: Int? = null,       // 02/42 码
    var sharpness: Int? = null,          // s8
    var denoise: Int? = null,            // s8
    var lapseKeep: Int? = null,
    var lapseIntervalDeciS: Int? = null,
    var lapseDurationS: Long? = null,
    var lapseSpeed: Int? = null,
    var lastUpdate: Date? = null,
) {
    // MARK: 码值 → 展示名（移植自 iOS 扩展）

    val recordStateName: String?
        get() = when (recordState) {
            0 -> "空闲"; 1 -> "启动中"; 2 -> "录制中"; 3 -> "停止中"; else -> null
        }

    val workModeName: String?
        get() = when (workMode) {
            0 -> "照片/延时"; 1 -> "视频"; 2 -> "回放"; else -> null
        }

    val captureModeName: String?
        get() = when (captureMode) {
            0x05 -> "照片"; 0x01 -> "视频"; 0x28 -> "超级夜景"
            0x00 -> "慢动作"; 0x02 -> "延时摄影"; 0x0A -> "运动延时"
            else -> captureMode?.let { "0x%02X".format(it) }
        }

    val videoResolutionName: String?
        get() = when (videoResolutionCode) {
            0x10 -> "4K 16:9"; 0x2D -> "2.7K 16:9"; 0x0A -> "1080p 16:9"
            0x67 -> "4K 4:3"; 0x5F -> "2.7K 4:3"; 0x0C -> "1080p 4:3"
            0x42 -> "1080p 9:16"
            else -> videoResolutionCode?.let { "0x%02X".format(it) }
        }

    val videoFpsName: String?
        get() = videoFpsCode?.let {
            OsmoA4.FPS_NAMES[it]?.toString() ?: it.toString()
        }

    val isoName: String?
        get() = when (isoCode) {
            null -> null
            0x00 -> "自动"
            0x01, 0x02, 0x03 -> "100"
            0x04 -> "200"; 0x05 -> "400"; 0x06 -> "800"; 0x07 -> "1600"
            0x08 -> "3200"; 0x09 -> "6400"; 0x0A -> "12800"; 0x0B -> "25600"
            0x0C, 0x0D -> "51200"
            else -> "0x%02X".format(isoCode)
        }

    val shutterName: String? get() = shutterRaw?.let { OsmoA4.shutterText(it) }
    val effectiveShutterName: String? get() = effectiveShutter?.let { OsmoA4.shutterText(it) }
    val photoShutterName: String? get() = photoShutter?.let { OsmoA4.shutterText(it.toLong()) }
    val effectiveISOName: String? get() = effectiveISO?.toString()

    val exposureModeName: String?
        get() = when (exposureMode) {
            null -> null; 0x01 -> "自动"; 0x04 -> "手动"
            else -> "0x%02X".format(exposureMode)
        }

    val expoCompName: String? get() = expoCompValue?.let { OsmoA4.evName(it) }
    val lightMeterName: String? get() = lightMeterValue?.let { OsmoA4.evName(it) + " EV" }

    val wbName: String?
        get() = when (wbMode) {
            null -> null
            0x00 -> "自动"
            0x06 -> wbKelvin?.let { "${it}K" } ?: "手动色温"
            else -> "0x%02X".format(wbMode)
        }

    val colorProfileName: String?
        get() = when (colorProfile) {
            null -> null; 0x00 -> "普通"; 0x34 -> "D-Log M"; 0x3C -> "HLG"
            0x17 -> "D-Log"; 0x41 -> "D-Log2"
            else -> "0x%02X".format(colorProfile)
        }

    val lapseKeepName: String?
        get() = when (lapseKeep) {
            null -> null; 0x00 -> "不保存"; 0x02 -> "JPEG"; 0x03 -> "RAW"; else -> null
        }
}

/**
 * 接收 datalink 解出的 DUML 帧，解析推送与查询应答，维护快照（移植自 iOS OSMOStatusTracker）。
 * 全部方法须在 datalink 协程上调用。
 *
 * emit 内容门控：与 iOS P0 修复一致——仅在内容真变化（lastUpdate 归一化比对）时回调 onChanged。
 */
class OsmoStatusTracker {

    val snapshot = OsmoStatusSnapshot()

    /** 快照内容变化（datalink 线程；OsmoCameraLink 时间节流后转 onStatus） */
    var onChanged: ((OsmoStatusSnapshot) -> Unit)? = null
    /** 拍摄模式变化（该模式下格式/曝光需重新查询） */
    var onCaptureModeChanged: ((Int) -> Unit)? = null
    var onLog: ((String) -> Unit)? = null
    /** 固件动作事件（00/76 JSON） */
    var onEvent: ((String, org.json.JSONObject) -> Unit)? = null

    private val pendingTopicAcks = ArrayDeque<String>()
    var pendingParamType: Int? = null
    private var lastParam0A: Int? = null

    private val knownParameterPids = setOf(
        OsmoA4.PARAM_PRO, OsmoA4.PARAM_EIS, OsmoA4.PARAM_FOV, OsmoA4.PARAM_ISO_MAX,
        OsmoA4.PARAM_LOW_LIGHT, OsmoA4.PARAM_ORIENTATION,
    )

    // emit 内容门控计数（移植自 iOS 诊断埋点）
    private var lastEmittedContent: OsmoStatusSnapshot? = null
    private var emitCount = 0
    private var unchangedStreak = 0
    private var lastChangeLogAt = 0L

    fun expectSubscriptionAcks(topics: List<String>) {
        pendingTopicAcks.clear()
        pendingTopicAcks.addAll(topics)
    }

    fun noteParameterRequest(type: Int) {
        pendingParamType = type
    }

    /** parseDUML 解出的每条 DUML 帧（推送与查询应答都从这里进） */
    fun handle(cmdSet: Int, cmdId: Int, sender: Byte, payload: ByteArray) {
        when (cmdSet to cmdId) {
            0x02 to 0x80 -> parseCameraStatus(payload)
            0x0D to 0x02 -> parseBattery(payload)
            0x02 to 0xDC -> parseStorage(payload)
            0x00 to 0x76 -> parseActionEvent(payload)
            0x00 to 0x99 -> {
                if (payload.size <= 2) {
                    val name = if (pendingTopicAcks.isEmpty()) "?" else pendingTopicAcks.removeFirstOrNull() ?: "?"
                    val ok = payload.firstOrNull()?.toInt() == 0x00
                    onLog?.invoke("订阅 $name → ${if (ok) "已订阅" else "无此主题"}")
                } else {
                    parseTopicPush(payload)
                }
            }
            0x02 to 0x19 -> parseVideoFormatReply(payload)
            0x02 to 0x1F -> parseExposureModeReply(payload)
            0x02 to 0x2B -> parseISOReply(payload)
            0x02 to 0x29 -> parseShutterReply(payload)
            0x02 to 0x2D -> parseWBReply(payload)
            0x02 to 0x13 -> parsePhotoFormatReply(payload)
            0x02 to 0x8E -> parseParameterReply(payload)
        }
        emit()
    }

    private fun emit() {
        val content = snapshot.copy(lastUpdate = null)
        val changed = content != lastEmittedContent
        lastEmittedContent = content
        emitCount++
        val now = System.nanoTime()
        if (changed) {
            unchangedStreak = 0
            if (lastChangeLogAt == 0L || now - lastChangeLogAt > 2_000_000_000L) {
                lastChangeLogAt = now
                onLog?.invoke("[status] 快照内容变化（emit #$emitCount）")
            }
        } else {
            unchangedStreak++
            if (unchangedStreak % 10 == 0) {
                onLog?.invoke("[status] 连续${unchangedStreak}次 emit 内容无变化（空转重建确认）")
            }
        }
        snapshot.lastUpdate = Date()
        onChanged?.invoke(snapshot)
    }

    private fun setQueryError(key: String, result: Int) {
        if (result == 0x00) snapshot.queryErrors.remove(key) else snapshot.queryErrors[key] = result
    }

    // MARK: 02/80 相机状态（osmocam §8.1）

    private fun parseCameraStatus(p: ByteArray) {
        if (p.size < 58) return
        snapshot.recordState = (p[0].toInt() shr 6) and 0x03
        snapshot.isWritingFile = p[2].toInt() and 0x08 != 0
        snapshot.mediaMode = p[3].toInt() and 0x40 != 0
        snapshot.workMode = p[4].toInt() and 0xFF
        // 回放时 5-20 读 0：保留上次非零值
        OsmoA4.le32(p, 5).takeIf { it > 0 }?.let { snapshot.totalStorageMB = it }
        OsmoA4.le32(p, 9).takeIf { it > 0 }?.let { snapshot.freeStorageMB = it }
        OsmoA4.le32(p, 13).takeIf { it > 0 }?.let { snapshot.photosLeft = it }
        OsmoA4.le32(p, 17).takeIf { it > 0 }?.let { snapshot.videoSecondsLeft = it }
        snapshot.clipSeconds = OsmoA4.le32(p, 29)
        val mode = p[57].toInt() and 0xFF
        if (mode != snapshot.captureMode) {
            snapshot.captureMode = mode
            onChanged?.invoke(snapshot)
            onCaptureModeChanged?.invoke(mode)
        }
    }

    // MARK: 0D/02 电池（osmocam §8.2）

    private fun parseBattery(p: ByteArray) {
        if (p.size < 21) return
        snapshot.batteryVoltageMV = OsmoA4.le32(p, 1).toInt()
        snapshot.batteryCurrentMA = OsmoA4.le32(p, 5).toInt()
        snapshot.batteryTempDeciC = OsmoA4.le16(p, 17)
        snapshot.batteryPercent = p[20].toInt() and 0xFF
    }

    // MARK: 02/DC 存储明细（osmocam §8.5）

    private fun parseStorage(p: ByteArray) {
        if (p.size < 32) return
        // 回放时 microSD 字段可能读 0：保留上次非零值
        OsmoA4.le32(p, 6).takeIf { it > 0 }?.let { snapshot.sdTotalMB = it }
        OsmoA4.le32(p, 10).takeIf { it > 0 }?.let { snapshot.sdFreeMB = it }
        OsmoA4.le32(p, 24).takeIf { it > 0 }?.let { snapshot.internalTotalMB = it }
        OsmoA4.le32(p, 28).takeIf { it > 0 }?.let { snapshot.internalFreeMB = it }
    }

    /** cam_video_param_v2：分辨率码 @0、帧率码 @1 u8（OA4 实测） */
    private fun parseVideoParamV2(d: ByteArray) {
        if (d.size < 9) return
        snapshot.videoResolutionCode = d[0].toInt() and 0xFF
        snapshot.videoFpsCode = d[1].toInt() and 0xFF
        val prev = snapshot.topicDecoded["cam_video_param_v2"]
        val summary = "编码档 @4=${d[4].toInt() and 0xFF} @8=${d[8].toInt() and 0xFF}"
        if (prev == null || prev != summary) {
            snapshot.topicDecoded = snapshot.topicDecoded + ("cam_video_param_v2" to summary)
        }
    }

    // MARK: 00/76 固件动作事件（JSON：拍照/录制/延时动作结果）

    private fun parseActionEvent(p: ByteArray) {
        val text = String(p, Charsets.UTF_8)
        val start = text.indexOf('{')
        val end = text.lastIndexOf('}')
        if (start < 0 || end <= start) return
        try {
            val json = org.json.JSONObject(text.substring(start, end + 1))
            val eventId = json.optString("event_id")
            if (eventId.isNotEmpty()) onEvent?.invoke(eventId, json)
        } catch (_: Exception) {
        }
    }

    // MARK: 00/99 命名主题推送
    // 布局：02 06 00 00 <seq u16> 00×5 <rest u16> <nameLen u16> <name> 00×6 <dataLen u16> <data>

    private fun parseTopicPush(p: ByteArray) {
        if (p.size < 17) return
        val nameLen = OsmoA4.le16(p, 13)
        if (nameLen <= 0 || 15 + nameLen + 6 + 2 > p.size) return
        val name = String(p, 15, nameLen, Charsets.UTF_8)
        val dataStart = 15 + nameLen + 6
        val dataLen = OsmoA4.le16(p, dataStart)
        val start = dataStart + 2
        if (start + dataLen > p.size) return
        val data = p.copyOfRange(start, start + dataLen)
        when (name) {
            "cam_video_param_v2" -> parseVideoParamV2(data)
            "cam_expo_param" -> parseExpoParam(data)
            "cam_image_effect" -> parseImageEffect(data)
            "cam_lapse_param" -> parseLapseParam(data)
            "cam_portrait_mode" -> {
                val on = data.isNotEmpty() && data[0].toInt() != 0
                if (on != snapshot.portraitMode) {
                    onLog?.invoke("cam_portrait_mode → ${if (on) "竖拍" else "横拍"}")
                }
                if (data.isNotEmpty()) snapshot.portraitMode = on
            }
            "cam_lens_state" -> {
                // lens position u16 @14 ÷ 126 = 变焦倍率（OA4 单位 126）
                if (data.size >= 16) {
                    val lens = OsmoA4.le16(data, 14)
                    if (lens in 63..1008) {
                        snapshot.zoomFactor = kotlin.math.round(lens / 126.0 * 10) / 10
                    }
                }
            }
            "cam_record_time" -> {
                if (data.size >= 4) snapshot.recordSeconds = OsmoA4.le32(data, 0)
            }
            "cam_fov" -> decodeFov(data)
            "cam_photo_param" -> decodePhotoParam(data)
            "cam_storage" -> decodeStorage(data)
            "cam_status" -> decodeCamStatus(data)
            "cam_audio_status_v2" -> decodeAudioLevels(data)
            "timecode_info" -> decodeTimecode(data)
            "shutter_param", "cam_photo_param_new", "temp_curve", "camcap_common" ->
                recordRawTopic(name, data)
            "cam_imu_calib_info", "cam_custom_mode_params", "cam_magnifier_status",
            "v_quality_enhance_status", "audio_timecode_status" -> Unit
            else -> onLog?.invoke("主题 $name 推送 ${data.size}B: ${data.toHexString().take(28)}（未解析，首见记录）")
        }
    }

    /** 未确认布局主题：原始数据段记录到快照（值变化才更新） */
    private fun recordRawTopic(name: String, data: ByteArray) {
        val hex = data.toHexString()
        if (snapshot.rawTopicSamples[name] == hex) return
        snapshot.rawTopicSamples = snapshot.rawTopicSamples + (name to hex)
        onChanged?.invoke(snapshot)
    }

    /** cam_expo_param（41B 固定布局，全字段实锤）：EV @6、曝光模式 @7、测光 @15、
     *  ISO u16 @16、快门 u16 @20+dec@22、ISO 档码 @11、数字增益 u16 @33+十分位 @35 */
    private fun parseExpoParam(d: ByteArray) {
        if (d.size < 36) return
        val mode = d[7].toInt() and 0xFF
        if (mode == 0x01 || mode == 0x04) snapshot.exposureMode = mode
        snapshot.isoStepCode = d[11].toInt() and 0xFF
        snapshot.lightMeterValue = d[15].toInt() and 0xFF
        val isoValue = OsmoA4.le16(d, 16)
        snapshot.effectiveISO = isoValue.toLong()
        // 用户 ISO 档位码：手动=设定值精确反查、自动=00
        snapshot.isoCode = when (mode) {
            0x04 -> OsmoA4.ISO_CODES.firstOrNull { it.second == isoValue }?.first
            0x01 -> 0x00
            else -> snapshot.isoCode
        }
        snapshot.effectiveShutter = OsmoA4.le16(d, 20).toLong() or ((d[22].toLong() and 0xFF) shl 16)
        snapshot.digitalGain = OsmoA4.le16(d, 33)
        snapshot.digitalGainFine = d[35].toInt() and 0xFF
        snapshot.photoShutter = OsmoA4.le16(d, 2)
        // EV @6 直读（各模式独立记忆），码域兜底校验（宁缺勿错）
        val ev = d[6].toInt() and 0xFF
        if (ev in 0x07..0x19) {
            if (snapshot.expoCompValue != ev) {
                onLog?.invoke("[diag] EV @6 → 0x${Integer.toHexString(ev)}")
            }
            snapshot.expoCompValue = ev
        }
    }

    /** cam_image_effect：色彩档位 @2、降噪 s8 @14、锐度 s8 @15 */
    private fun parseImageEffect(d: ByteArray) {
        if (d.size < 16) return
        snapshot.colorProfile = d[2].toInt() and 0xFF
        snapshot.denoise = d[14].toInt()
        snapshot.sharpness = d[15].toInt()
        val s7 = d[7].toInt()
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("cam_image_effect" to "统计 ${d[5].toInt() and 0xFF}/${d[6].toInt() and 0xFF}/$s7")
    }

    /** cam_storage 22B：@10-13 u32 剩余可录秒、@14-16 u24 剩余可拍张数、@18-19 折算量 */
    private fun decodeStorage(d: ByteArray) {
        if (d.size < 20) return
        val recSec = OsmoA4.le32(d, 10)
        val photos = (d[14].toInt() and 0xFF) or ((d[15].toInt() and 0xFF) shl 8) or ((d[16].toInt() and 0xFF) shl 16)
        val reserve = OsmoA4.le16(d, 18)
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("cam_storage" to "可录 ${recSec}s · 可拍 $photos 张 · 折算 ${reserve}s")
    }

    /** cam_status 9B 紧凑状态帧：@0 状态位图、@3 管线标志、@4 captureMode、@7 录制状态 */
    private fun decodeCamStatus(d: ByteArray) {
        if (d.size < 8) return
        val recName = listOf("空闲", "启动", "录制", "停止")[(d[7].toInt() and 0x03)]
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("cam_status" to "模式 0x%02x".format(d[4]) + " · 录制 $recName · 位图 0x%02x".format(d[0]))
    }

    /** cam_fov 16B：@0-3/@4-7 读出区宽×高、@12-13 变化域 */
    private fun decodeFov(d: ByteArray) {
        if (d.size < 14) return
        val w = OsmoA4.le32(d, 0)
        val h = OsmoA4.le32(d, 4)
        val z = OsmoA4.le16(d, 12)
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("cam_fov" to "读出区 $w×$h · @12-13=0x%04x".format(z))
    }

    /** cam_photo_param 13B：@11 倒计秒（1Hz 递减至 0）、@0 拍摄动作标志 */
    private fun decodePhotoParam(d: ByteArray) {
        if (d.size < 12) return
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("cam_photo_param" to "倒计 ${d[11].toInt() and 0xFF}s · 动作 0x%02x".format(d[0]))
    }

    /** cam_audio_status_v2：@3/@7/@9 三通道实时电平（0x64=满） */
    private fun decodeAudioLevels(d: ByteArray) {
        if (d.size < 10) return
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("cam_audio_status_v2" to "电平 ${d[3].toInt() and 0xFF}/${d[7].toInt() and 0xFF}/${d[9].toInt() and 0xFF}（满 ${d[11].toInt() and 0xFF}）")
    }

    /** timecode_info 8B：@5 会话秒计数器、@6 递减位 */
    private fun decodeTimecode(d: ByteArray) {
        if (d.size < 7) return
        snapshot.topicDecoded = snapshot.topicDecoded +
            ("timecode_info" to "计 ${d[5].toInt() and 0xFF}s · 递减 ${d[6].toInt() and 0xFF}")
    }

    /** cam_lapse_param：keep @0、间隔 u16 @1（0.1s）、时长 u32 @5（s）、速度 u16 @9 */
    private fun parseLapseParam(d: ByteArray) {
        if (d.size < 11) return
        snapshot.lapseKeep = d[0].toInt() and 0xFF
        snapshot.lapseIntervalDeciS = OsmoA4.le16(d, 1)
        snapshot.lapseDurationS = OsmoA4.le32(d, 5)
        snapshot.lapseSpeed = OsmoA4.le16(d, 9)
    }

    // MARK: 查询应答（首字节 = 结果码，00=OK）

    private fun parseVideoFormatReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: 0xE0
        setQueryError("video_format", result and 0xFF)
        if (result != 0x00 || p.size < 3) return
        snapshot.videoResolutionCode = p[1].toInt() and 0xFF
        snapshot.videoFpsCode = p[2].toInt() and 0xFF
    }

    private fun parseExposureModeReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: 0xE0
        setQueryError("exposure_mode", result and 0xFF)
        if (result != 0x00 || p.size < 2) return
        snapshot.exposureMode = p[1].toInt() and 0xFF
    }

    private fun parseISOReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: 0xE0
        setQueryError("iso", result and 0xFF)
        if (result != 0x00 || p.size < 2) return
        snapshot.isoCode = p[1].toInt() and 0xFF
    }

    private fun parseShutterReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: 0xE0
        setQueryError("shutter", result and 0xFF)
        if (result != 0x00 || p.size < 5) return
        snapshot.shutterRaw = OsmoA4.le16(p, 2).toLong() or ((p[4].toLong() and 0xFF) shl 16)
    }

    /** 02/2D 白平衡读取：按 `00 <mode> <kelvin/100 u16>` 防御性解析 */
    private fun parseWBReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: 0xE0
        setQueryError("wb", result and 0xFF)
        if (result != 0x00 || p.size < 4) return
        snapshot.wbMode = p[1].toInt() and 0xFF
        snapshot.wbKelvin = OsmoA4.le16(p, 2) * 100
    }

    /** 02/13 照片格式读取 → `00 <size> <ratio>`（仅照片模式） */
    private fun parsePhotoFormatReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: 0xE0
        setQueryError("photo_format", result and 0xFF)
        if (result != 0x00 || p.size < 3) return
        snapshot.photoSizeCode = p[1].toInt() and 0xFF
        snapshot.photoRatioCode = p[2].toInt() and 0xFF
    }

    /** 02/8E 参数读取应答 `00 00 01 <type u16> 01 <value>`；写命令应答仅 1B 结果码 */
    private fun parseParameterReply(p: ByteArray) {
        val result = p.firstOrNull()?.toInt() ?: return
        val replyPid: Int? = if (p.size >= 5 && p[1].toInt() == 0x00 && p[2].toInt() == 0x01) {
            (p[3].toInt() and 0xFF) or ((p[4].toInt() and 0xFF) shl 8)
        } else null
        val type = replyPid ?: pendingParamType ?: 0xFFFF
        val pidKey = "param-%04X".format(type)
        if (result != 0x00) {
            setQueryError(pidKey, result)
            return
        }
        snapshot.queryErrors.remove(pidKey)
        snapshot.queryErrors.remove("param")
        if (p.size < 7 || p[1].toInt() != 0x00 || p[2].toInt() != 0x01) return
        val valLen = p[5].toInt() and 0xFF
        if (valLen > 0 && p.size >= 6 + valLen && type !in knownParameterPids) {
            snapshot.rawParams = snapshot.rawParams +
                (type to p.copyOfRange(6, 6 + valLen).toHexString())
        }
        if (type == 0x000A && p.size >= 7) {
            if (lastParam0A != p[6].toInt()) {
                onLog?.invoke("[diag] pid 000A 翻转 → 0x${Integer.toHexString(p[6].toInt() and 0xFF)}")
                lastParam0A = p[6].toInt()
            }
            snapshot.rawParam0A = p[6].toInt() and 0xFF
        }
        when (type) {
            OsmoA4.PARAM_FOV -> snapshot.fovValue = p[6].toInt() and 0xFF
            OsmoA4.PARAM_EIS -> snapshot.eisValue = p[6].toInt() and 0xFF
            OsmoA4.PARAM_ISO_MAX -> snapshot.isoMaxCode = p[6].toInt() and 0xFF
            OsmoA4.PARAM_PRO -> snapshot.proOnCode = p[6].toInt() and 0xFF
            OsmoA4.PARAM_LOW_LIGHT -> snapshot.lowLightCode = p[6].toInt() and 0xFF
            OsmoA4.PARAM_ORIENTATION ->
                // 3 字节值 [0, 朝向, 0]（0 上 / 1 左 / 2 下 / 3 右）
                if (p.size >= 8) snapshot.orientationCode = p[7].toInt() and 0xFF
        }
    }
}
