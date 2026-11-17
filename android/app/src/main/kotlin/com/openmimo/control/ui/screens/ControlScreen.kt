package com.openmimo.control.ui.screens

import android.view.TextureView
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.calculateZoom
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.DarkMode
import androidx.compose.material.icons.filled.PhotoCamera
import androidx.compose.material.icons.filled.PhotoLibrary
import androidx.compose.material.icons.filled.AvTimer
import androidx.compose.material.icons.filled.SlowMotionVideo
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.Videocam
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke as DrawStroke
import androidx.compose.ui.graphics.vector.ImageVector
import android.view.Surface
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import com.openmimo.control.app.OsmoSession
import kotlinx.coroutines.launch
import com.openmimo.control.protocol.OsmoA4
import com.openmimo.control.ui.common.OcOptionRow
import com.openmimo.control.ui.common.copyDiagnostics
import com.openmimo.control.ui.common.OcSelectionSheet
import com.openmimo.control.ui.common.PillRow
import com.openmimo.control.ui.theme.OC
import com.openmimo.control.ui.theme.OcMetrics

/**
 * 控制主界面（移植自 iOS ControlScreenView）：顶部两行状态 + 固定预览卡 +
 * 参数平铺面板 + 底部三键操作栏；弹窗统一 OCSelectionSheet 结构 + 唯一 ModalBottomSheet。
 * 两选项控制项直切（不弹层）；>5 档双列；>10 档滚轮——与 iOS 分流一致。
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ControlScreen(
    session: OsmoSession,
    onDisconnect: () -> Unit,
    onMedia: () -> Unit,
) {
    val st by session.osmoStatus.collectAsState()
    val frameCount by session.osmoFrameCount.collectAsState()
    val osmoError by session.osmoError.collectAsState()
    val osmoBusy by session.osmoBusy.collectAsState()
    val logs by session.logs.collectAsState()
    val clipboard = LocalClipboardManager.current

    var activeSheet by remember { mutableStateOf<SheetRoute?>(null) }

    // 本地即时覆盖 / 草稿（对齐 iOS proOverride / lowLightOverride / evDraft / zoomDraft）
    var proOverride by remember { mutableStateOf<Boolean?>(null) }
    var lowLightOverride by remember { mutableStateOf<Boolean?>(null) }
    var evDraft by remember { mutableStateOf<Int?>(null) }
    var zoomDraft by remember { mutableStateOf<Int?>(null) }
    var liveNotice by remember { mutableStateOf<String?>(null) }
    var gridMode by remember { mutableStateOf(0) }
    var imageTune by remember { mutableStateOf(0) }
    var photoCountdown by remember { mutableStateOf(0) }
    var zoomLevel by remember { mutableStateOf(1.0) }

    val proOn = proOverride ?: (st.proOnCode == 1)
    val displayZoom = st.zoomFactor ?: zoomLevel
    val manual = st.exposureMode == 0x04
    val countdownModes = listOf("关闭", "0.5s", "1s", "2s", "3s", "5s", "10s")
    val countdownMillis = intArrayOf(0, 500, 1000, 2000, 3000, 5000, 10000)

    DisposableEffect(Unit) { onDispose { session.detachRenderSurface() } }

    /** 选项弹窗分流（移植自 iOS pillWheelRow 阈值）：≤10 档列表（>5 双列），>10 档滚轮
     *  （live=true：滚动跨档 200ms 节流下发，关闭补发终档）。 */
    fun presentOptions(
        title: String,
        options: List<String>,
        initialIndex: Int,
        live: Boolean = true,
        onClose: (() -> Unit)? = null,
        onPick: (Int) -> Unit,
    ) {
        activeSheet = if (options.size > 10) {
            SheetRoute.Wheel(title, options.indices.toList(), options, initialIndex, live, onPick, onClose)
        } else {
            SheetRoute.Options(title, options, initialIndex, onPick)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(OC.bg),
    ) {
        Column(Modifier.fillMaxSize()) {
            TopStatus(st, onTapDetail = { activeSheet = SheetRoute.Detail })

            PreviewCard(
                session = session,
                frameCount = frameCount,
                orientationCode = st.orientationCode,
                zoomFactor = displayZoom,
                recordState = st.recordState,
                recordSeconds = st.recordSeconds ?: st.clipSeconds,
                captureMode = st.captureMode,
                gridMode = gridMode,
                onTapDouble = {
                    zoomLevel = 1.0
                    session.launchPublic { session.setZoomPosition(1.0) }
                },
                onPinch = { zoomIn -> session.zoomMove(zoomIn) },
                onPinchEnd = { session.zoomStop() },
            )

            // MARK: 参数面板（无折叠，直接平铺；超出在面板内滚动）
            Column(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp)
                    .background(OC.card, RoundedCornerShape(14.dp))
                    .verticalScroll(rememberScrollState())
                    .padding(14.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                GroupLabel("通用设置")
                val mode = st.captureMode ?: OsmoA4.MODE_VIDEO
                if (st.captureMode == OsmoA4.MODE_SLOWMO) {
                    val formats = OsmoA4.SLOWMO_FORMATS.map { (res, fps, factor) ->
                        "${OsmoA4.RESOLUTION_NAMES[res] ?: "?"} · ${OsmoA4.FPS_NAMES[fps] ?: 0}fps · ${factor}×"
                    }
                    val currentFormat = st.videoResolutionCode?.let { res ->
                        st.videoFpsCode?.let { fps ->
                            OsmoA4.SLOWMO_FORMATS.indexOfFirst { it.first == res && it.second == fps }
                        }
                    }
                    PillRow(
                        title = "慢动作",
                        current = currentFormat?.takeIf { it >= 0 }?.let { formats[it] },
                        disabled = osmoBusy,
                        onTap = {
                            activeSheet = SheetRoute.Options("慢动作", formats, currentFormat?.takeIf { it >= 0 } ?: 0) { i ->
                                val f = OsmoA4.SLOWMO_FORMATS.getOrNull(i) ?: return@Options
                                session.launchPublic {
                                    session.osmoFormatCommand("慢动作格式") {
                                        it.setVideoFormat(f.first, f.second, f.third)
                                        true
                                    }
                                }
                            }.also { activeSheet = it }
                        },
                    )
                } else if (st.captureMode != OsmoA4.MODE_PHOTO) {
                    val resCodes = OsmoA4.MODE_RESOLUTIONS[mode] ?: emptyList()
                    PillRow(
                        title = "分辨率",
                        current = st.videoResolutionName,
                        disabled = osmoBusy,
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "分辨率", resCodes.mapNotNull { OsmoA4.RESOLUTION_NAMES[it] },
                                resCodes.indexOf(st.videoResolutionCode ?: -1).coerceAtLeast(0),
                            ) { i ->
                                val res = resCodes.getOrNull(i) ?: return@Options
                                val fps = st.videoFpsCode ?: 3
                                session.launchPublic {
                                    session.osmoFormatCommand("分辨率") {
                                        it.setVideoFormat(res, fps)
                                        true
                                    }
                                }
                            }
                        },
                    )
                    val fpsCodes = OsmoA4.fpsOptions(mode, st.videoResolutionCode ?: 0x0A)
                    PillRow(
                        title = "帧率",
                        current = st.videoFpsName?.let { "${it}fps" },
                        disabled = osmoBusy,
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "帧率", fpsCodes.mapNotNull { OsmoA4.FPS_NAMES[it]?.let { f -> "${f}fps" } },
                                fpsCodes.indexOf(st.videoFpsCode ?: -1).coerceAtLeast(0),
                            ) { i ->
                                val fps = fpsCodes.getOrNull(i) ?: return@Options
                                val res = st.videoResolutionCode ?: 0x0A
                                session.launchPublic {
                                    session.osmoFormatCommand("帧率") {
                                        it.setVideoFormat(res, fps)
                                        true
                                    }
                                }
                            }
                        },
                    )
                }
                PillRow(
                    title = "视角",
                    current = st.fovValue?.let { OsmoA4.fovName(it) },
                    disabled = osmoBusy,
                    onTap = {
                        val options = OsmoA4.FOV_MODES.map { it.second }
                        activeSheet = SheetRoute.Options(
                            "视角", options,
                            OsmoA4.FOV_MODES.indexOfFirst { it.first == st.fovValue }.coerceAtLeast(0),
                        ) { i ->
                            val code = OsmoA4.FOV_MODES.getOrNull(i)?.first ?: return@Options
                            session.launchPublic {
                                session.osmoCommand("视角") { it.setFOV(code) }
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                if (st.captureMode == OsmoA4.MODE_VIDEO || st.captureMode == OsmoA4.MODE_PHOTO) {
                    PillRow(
                        title = "变焦",
                        current = String.format("%.1fx", displayZoom),
                        onTap = { activeSheet = SheetRoute.ZoomWheel },
                    )
                }
                if (st.captureMode == OsmoA4.MODE_VIDEO) {
                    PillRow(
                        title = "电子增稳",
                        current = st.eisValue?.let { OsmoA4.eisName(it) },
                        disabled = osmoBusy,
                        onTap = {
                            val options = OsmoA4.EIS_MODES.map { it.second }
                            activeSheet = SheetRoute.Options(
                                "电子增稳", options,
                                OsmoA4.EIS_MODES.indexOfFirst { it.first == st.eisValue }.coerceAtLeast(0),
                            ) { i ->
                                val code = OsmoA4.EIS_MODES.getOrNull(i)?.first ?: return@Options
                                session.launchPublic { session.osmoCommand("电子增稳") { it.setEIS(code) } }
                            }
                        },
                    )
                    PillRow(
                        title = "弱光增稳",
                        current = lowLightOverride?.let { if (it) "开启" else "关闭" }
                            ?: (if (st.lowLightCode == 1) "开启" else if (st.lowLightCode == 0) "关闭" else null),
                        disabled = osmoBusy,
                        showChevron = false,
                        onTap = {
                            val turnOn = st.lowLightCode != 1
                            session.launchPublic {
                                val ok = session.osmoCommand("弱光增稳") { it.setLowLight(turnOn) }
                                if (ok != null) {
                                    lowLightOverride = turnOn
                                    session.refreshOSMOQueries()
                                }
                            }
                        },
                    )
                }
                PillRow(
                    title = "网格",
                    current = listOf("关闭", "网格线", "网格线和对角线").getOrNull(gridMode),
                    showChevron = false,
                    onTap = { gridMode = (gridMode + 1) % 3 },
                )
                if (st.captureMode == OsmoA4.MODE_PHOTO) {
                    PillRow(
                        title = "拍照倒计时",
                        current = countdownModes.getOrNull(photoCountdown),
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "拍照倒计时", countdownModes, photoCountdown,
                            ) { i ->
                                photoCountdown = i
                                val ms = countdownMillis[i]
                                session.launchPublic {
                                    session.osmoCommand("拍照倒计时") { it.setCountdown(ms / 1000, ms % 1000) }
                                }
                            }
                        },
                    )
                }

                GroupLabel("图像")
                PillRow(
                    title = "PRO",
                    current = if (proOn) "开" else "关",
                    disabled = osmoBusy,
                    showChevron = false,
                    onTap = {
                        val turnOn = !proOn
                        session.launchPublic {
                            val ok = session.osmoCommand("Pro 开关") { it.setPro(turnOn) }
                            if (ok != null) {
                                proOverride = turnOn
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                if (proOn) {
                    PillRow(
                        title = "曝光",
                        current = st.exposureModeName,
                        disabled = osmoBusy,
                        showChevron = false,
                        onTap = {
                            val auto = st.exposureMode != 0x01
                            session.launchPublic {
                                session.osmoCommand("曝光模式") { it.setExposureMode(auto = auto) }
                                session.refreshOSMOQueries()
                            }
                        },
                    )
                    PillRow(
                        title = "EV",
                        current = evDraft?.let { OsmoA4.evName(it) } ?: st.expoCompName,
                        onTap = { activeSheet = SheetRoute.EvWheel },
                    )
                    val raws = shutterRawsFor(st.captureMode)
                    PillRow(
                        title = "快门",
                        current = st.effectiveShutterName ?: st.shutterName,
                        disabled = !manual,
                        onTap = {
                            presentOptions(
                                "快门", raws.map { OsmoA4.shutterText(it) },
                                st.shutterRaw?.let { r -> raws.indexOf(r) }?.coerceAtLeast(0) ?: 0,
                                live = true,
                                onClose = { session.refreshOSMOQueries() },
                            ) { i ->
                                val raw = raws.getOrNull(i) ?: return@presentOptions
                                session.launchPublic { session.osmoCommand("快门") { it.setShutter(raw) } }
                            }
                        },
                    )
                    val isoNames = listOf("自动") + OsmoA4.ISO_CODES.map { "${it.second}" }
                    PillRow(
                        title = "ISO",
                        current = if (manual) st.isoName else (st.effectiveISOName ?: st.isoName),
                        disabled = !manual,
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "ISO", isoNames,
                                st.isoCode?.let { c ->
                                    if (c == 0) 0 else OsmoA4.ISO_CODES.indexOfFirst { it.first == c } + 1
                                }?.coerceAtLeast(0) ?: 0,
                            ) { i ->
                                val code = if (i == 0) 0 else OsmoA4.ISO_CODES.getOrNull(i - 1)?.first ?: return@Options
                                session.launchPublic { session.osmoCommand("ISO") { it.setISO(code) } }
                            }
                        },
                    )
                    PillRow(
                        title = "ISO MAX",
                        current = st.isoMaxCode?.let { OsmoA4.isoMaxName(it) },
                        onTap = {
                            val options = OsmoA4.ISO_MAX_STEPS.map { it.second }
                            activeSheet = SheetRoute.Options(
                                "ISO MAX", options,
                                OsmoA4.ISO_MAX_STEPS.indexOfFirst { it.first == st.isoMaxCode }.coerceAtLeast(0),
                            ) { i ->
                                val code = OsmoA4.ISO_MAX_STEPS.getOrNull(i)?.first ?: return@Options
                                session.launchPublic { session.osmoCommand("ISO MAX") { it.setISOMax(code) } }
                            }
                        },
                    )
                }
                PillRow(
                    title = "白平衡",
                    current = st.wbName,
                    disabled = osmoBusy,
                    onTap = {
                        val options = listOf("自动") + OsmoA4.WB_KELVINS.map { "${it}K" }
                        presentOptions(
                            "白平衡", options,
                            if (st.wbMode == 0x00) 0
                            else st.wbKelvin?.let { k -> OsmoA4.WB_KELVINS.indexOf(k) + 1 } ?: 0,
                            live = true,
                            onClose = { session.refreshOSMOQueries() },
                        ) { i ->
                            val manualWb = i > 0
                            val kelvin = if (i > 0) OsmoA4.WB_KELVINS.getOrNull(i - 1) ?: 5600 else 5600
                            session.launchPublic {
                                session.osmoCommand("白平衡") { it.setWhiteBalance(manualWb, kelvin) }
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                PillRow(
                    title = "色彩",
                    current = st.colorProfileName,
                    disabled = osmoBusy,
                    onTap = {
                        val options = OsmoA4.COLOR_MODES.map { it.second }
                        activeSheet = SheetRoute.Options(
                            "色彩", options,
                            OsmoA4.COLOR_MODES.indexOfFirst { it.first == st.colorProfile }.coerceAtLeast(0),
                        ) { i ->
                            val code = OsmoA4.COLOR_MODES.getOrNull(i)?.first ?: return@Options
                            session.launchPublic {
                                session.osmoCommand("色彩档位") { it.setColorProfile(code) }
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                PillRow(
                    title = "图像调节",
                    current = listOf("默认", "人像", "自定义").getOrNull(imageTune),
                    showChevron = false,
                    onTap = {
                        imageTune = (imageTune + 1) % 3
                        if (imageTune < 2) {
                            val denoise = if (imageTune == 0) 0 else 1
                            session.launchPublic {
                                session.osmoCommand("图像调节") {
                                    it.setSharpness(0)
                                    it.setDenoise(denoise)
                                    1
                                }
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                PillRow(
                    title = "锐度",
                    current = st.sharpness?.toString(),
                    disabled = imageTune != 2 || osmoBusy,
                    onTap = {
                        val options = OsmoA4.SHARPNESS_RANGE.map { it.toString() }
                        activeSheet = SheetRoute.Options(
                            "锐度", options,
                            OsmoA4.SHARPNESS_RANGE.indexOf(st.sharpness ?: 0).coerceAtLeast(0),
                        ) { i ->
                            val v = OsmoA4.SHARPNESS_RANGE.getOrNull(i) ?: return@Options
                            session.launchPublic {
                                session.osmoCommand("锐度") { it.setSharpness(v) }
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                PillRow(
                    title = "降噪",
                    current = st.denoise?.toString(),
                    disabled = imageTune != 2 || osmoBusy,
                    onTap = {
                        val options = OsmoA4.DENOISE_RANGE.map { it.toString() }
                        activeSheet = SheetRoute.Options(
                            "降噪", options,
                            OsmoA4.DENOISE_RANGE.indexOf(st.denoise ?: 0).coerceAtLeast(0),
                        ) { i ->
                            val v = OsmoA4.DENOISE_RANGE.getOrNull(i) ?: return@Options
                            session.launchPublic {
                                session.osmoCommand("降噪") { it.setDenoise(v) }
                                session.refreshOSMOQueries()
                            }
                        }
                    },
                )
                if (st.captureMode == OsmoA4.MODE_PHOTO) {
                    PillRow(
                        title = "画幅",
                        current = st.photoRatioCode?.let { if (it == 1) "16:9" else "4:3" },
                        disabled = osmoBusy,
                        showChevron = false,
                        onTap = {
                            val ratio = if (st.photoRatioCode == 1) 0 else 1
                            session.launchPublic {
                                session.osmoFormatCommand("画幅") {
                                    it.setPhotoFormat(size = 0, ratio = ratio)
                                    true
                                }
                            }
                        },
                    )
                }
                if (st.captureMode == OsmoA4.MODE_TIMELAPSE) {
                    val intervals = OsmoA4.TIMELAPSE_INTERVALS_TENTHS.map { intervalText(it) }
                    val durations = OsmoA4.TIMELAPSE_DURATIONS_S.map { if (it == 0L) "不限" else "${it / 60}分" }
                    val saves = OsmoA4.LAPSE_SAVE_MODES.map { it.second }
                    PillRow(
                        title = "延时间隔",
                        current = st.lapseIntervalDeciS?.let { intervalText(it) },
                        onTap = {
                            presentOptions(
                                "延时间隔", intervals,
                                OsmoA4.TIMELAPSE_INTERVALS_TENTHS.indexOf(st.lapseIntervalDeciS ?: 20).coerceAtLeast(0),
                                live = true,
                                onClose = { session.refreshOSMOQueries() },
                            ) { i ->
                                val iv = OsmoA4.TIMELAPSE_INTERVALS_TENTHS.getOrNull(i) ?: return@presentOptions
                                val keep = st.lapseKeep ?: 0
                                val dur = st.lapseDurationS ?: 0
                                session.launchPublic { session.osmoCommand("延时间隔") { it.setTimelapse(keep, iv, dur) } }
                            }
                        },
                    )
                    PillRow(
                        title = "拍摄时长",
                        current = st.lapseDurationS?.let { if (it == 0L) "不限" else "${it / 60}分" },
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "拍摄时长", durations,
                                OsmoA4.TIMELAPSE_DURATIONS_S.indexOf(st.lapseDurationS ?: 0).coerceAtLeast(0),
                            ) { i ->
                                val dur = OsmoA4.TIMELAPSE_DURATIONS_S.getOrNull(i) ?: return@Options
                                val keep = st.lapseKeep ?: 0
                                val iv = st.lapseIntervalDeciS ?: 20
                                session.launchPublic { session.osmoCommand("拍摄时长") { it.setTimelapse(keep, iv, dur) } }
                            }
                        },
                    )
                    PillRow(
                        title = "保存",
                        current = st.lapseKeepName,
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "保存", saves,
                                OsmoA4.LAPSE_SAVE_MODES.indexOfFirst { it.first == st.lapseKeep }.coerceAtLeast(0),
                            ) { i ->
                                val code = OsmoA4.LAPSE_SAVE_MODES.getOrNull(i)?.first ?: return@Options
                                val iv = st.lapseIntervalDeciS ?: 20
                                val dur = st.lapseDurationS ?: 0
                                session.launchPublic {
                                    session.osmoCommand("延时保存") { it.setTimelapse(code, iv, dur) }
                                    session.refreshOSMOQueries()
                                }
                            }
                        },
                    )
                } else if (st.captureMode == OsmoA4.MODE_HYPERLAPSE) {
                    val speeds = OsmoA4.HYPERLAPSE_SPEEDS.map { if (it == 0) "自动" else "${it}×" }
                    PillRow(
                        title = "延时速率",
                        current = st.lapseSpeed?.let { if (it == 0) "自动" else "${it}×" },
                        onTap = {
                            activeSheet = SheetRoute.Options(
                                "延时速率", speeds,
                                OsmoA4.HYPERLAPSE_SPEEDS.indexOf(st.lapseSpeed ?: 0).coerceAtLeast(0),
                            ) { i ->
                                val v = OsmoA4.HYPERLAPSE_SPEEDS.getOrNull(i) ?: return@Options
                                session.launchPublic { session.osmoCommand("延时速率") { it.setHyperlapseSpeed(v) } }
                            }
                        },
                    )
                }
            }
        }

        // MARK: 底部操作栏（左素材 / 中快门 / 右录制模式）
        Row(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .background(OC.bg)
                .padding(horizontal = 22.dp, vertical = 10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Filled.PhotoLibrary,
                contentDescription = "素材浏览",
                tint = Color(0xFFC7C7CC),
                modifier = Modifier
                    .size(OcMetrics.RowHeight)
                    .clickable { onMedia() }
                    .padding(10.dp),
            )
            Spacer(Modifier.weight(1f))
            Box(
                Modifier
                    .size(66.dp)
                    .clickable(enabled = !osmoBusy) {
                        session.launchPublic { session.toggleRecord() }
                    },
                contentAlignment = Alignment.Center,
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    drawCircle(
                        color = if (st.recordState == 2) OC.recRed else Color.White,
                        style = DrawStroke(width = 9f),
                    )
                }
                if (st.recordState == 2) {
                    Box(Modifier.size(24.dp).background(OC.recRed, RoundedCornerShape(6.dp)))
                } else if (st.captureMode == OsmoA4.MODE_PHOTO) {
                    Box(Modifier.size(52.dp).background(Color.White, CircleShape))
                } else {
                    Box(Modifier.size(52.dp).background(OC.recRed, CircleShape))
                }
            }
            Spacer(Modifier.weight(1f))
            Icon(
                modeSymbol(st.captureMode),
                contentDescription = "录制模式",
                tint = Color(0xFFC7C7CC),
                modifier = Modifier
                    .size(OcMetrics.RowHeight)
                    .clickable { activeSheet = SheetRoute.Mode }
                    .padding(10.dp),
            )
        }

        // 错误 toast（顶部浮出，点击清除）
        if (osmoError != null) {
            Text(
                osmoError ?: "",
                color = Color.White,
                fontSize = 12.sp,
                maxLines = 3,
                modifier = Modifier
                    .align(Alignment.TopCenter)
                    .padding(horizontal = 20.dp).padding(top = 8.dp)
                    .background(Color.Black.copy(alpha = 0.7f), RoundedCornerShape(50))
                    .clickable { session.clearError() }
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            )
        }
    }

    // MARK: 弹窗层（唯一 ModalBottomSheet；关闭收尾按路由区分）
    val route = activeSheet
    if (route != null) {
        ModalBottomSheet(
            onDismissRequest = {
                when (route) {
                    is SheetRoute.EvWheel -> {
                        val final = evDraft ?: st.expoCompValue ?: 16
                        session.launchPublic { session.osmoCommand("EV") { it.setEV(final) } }
                        evDraft = null
                        session.refreshOSMOQueries()
                    }
                    is SheetRoute.ZoomWheel -> {
                        val final = zoomDraft ?: (displayZoom * 10).toInt()
                        session.launchPublic { session.setZoomPosition(final / 10.0) }
                        zoomDraft = null
                        session.refreshOSMOQueries()
                    }
                    else -> Unit
                }
                activeSheet = null
            },
            containerColor = Color.Transparent,
        ) {
            when (route) {
                is SheetRoute.Wheel -> OcSelectionSheet(title = route.title) {
                    var lastSent by remember { mutableStateOf(0L) }
                    var finalIndex by remember { mutableStateOf(route.initialIndex) }
                    SimpleWheel(
                        items = route.items,
                        selected = finalIndex,
                        label = { route.options[it] },
                        onSelect = { i ->
                            finalIndex = i
                            route.onPick(i)
                        },
                        onCenterChange = { i ->
                            if (route.live) {
                                val now = System.currentTimeMillis()
                                if (now - lastSent > 200) {
                                    lastSent = now
                                    finalIndex = i
                                    route.onPick(i)
                                }
                            } else {
                                finalIndex = i
                            }
                        },
                    )
                    androidx.compose.runtime.DisposableEffect(route) {
                        onDispose {
                            // 关闭补发终档（对齐 iOS WheelSheetView.onDisappear → ctx.onPick(index)）
                            route.onPick(finalIndex)
                            route.onClose?.invoke()
                        }
                    }
                }
                is SheetRoute.Options -> OcSelectionSheet(title = route.title) {
                    // >5 档双列（≤10 档走此列表；>10 档走滚轮——分流与 iOS 一致）
                    if (route.options.size > 5) {
                        LazyVerticalGrid(
                            columns = GridCells.Fixed(2),
                            horizontalArrangement = Arrangement.spacedBy(OcMetrics.OptionRowSpacing),
                            verticalArrangement = Arrangement.spacedBy(OcMetrics.OptionRowSpacing),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            items(route.options.indices.toList()) { i ->
                                OcOptionRow(
                                    route.options[i],
                                    isSelected = i == route.initialIndex,
                                    modifier = Modifier.clickable {
                                        route.onPick(i)
                                        activeSheet = null
                                    },
                                )
                            }
                        }
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(OcMetrics.OptionRowSpacing)) {
                            route.options.forEachIndexed { i, opt ->
                                OcOptionRow(
                                    opt,
                                    isSelected = i == route.initialIndex,
                                    modifier = Modifier.clickable {
                                        route.onPick(i)
                                        activeSheet = null
                                    },
                                )
                            }
                        }
                    }
                }
                SheetRoute.EvWheel -> OcSelectionSheet(title = "EV") {
                    var lastSent by remember { mutableStateOf(0L) }
                    SimpleWheel(
                        items = OsmoA4.EV_STEPS,
                        selected = evDraft ?: st.expoCompValue ?: 16,
                        label = { OsmoA4.evName(it) },
                        onSelect = { v ->
                            evDraft = v
                            session.launchPublic { session.osmoCommand("EV") { it.setEV(v) } }
                        },
                        onCenterChange = { v ->
                            // 滚动跨档节流下发（200ms，与 iOS evPickerBinding 同节奏）
                            val now = System.currentTimeMillis()
                            if (now - lastSent > 200 && v != evDraft) {
                                lastSent = now
                                evDraft = v
                                session.launchPublic { session.osmoCommand("EV") { it.setEV(v) } }
                            }
                        },
                    )
                }
                SheetRoute.ZoomWheel -> OcSelectionSheet(title = "变焦") {
                    val zoomMode = st.captureMode ?: OsmoA4.MODE_VIDEO
                    val range = if (zoomMode == OsmoA4.MODE_PHOTO) 10..40 else 10..20
                    var lastSent by remember { mutableStateOf(0L) }
                    SimpleWheel(
                        items = range.toList(),
                        selected = (zoomDraft ?: (displayZoom * 10).toInt()).coerceIn(range.first, range.last),
                        label = { String.format("%.1fx", it / 10.0) },
                        onSelect = { v ->
                            zoomDraft = v
                            session.launchPublic { session.setZoomPosition(v / 10.0) }
                        },
                        onCenterChange = { v ->
                            val now = System.currentTimeMillis()
                            if (now - lastSent > 150 && v != zoomDraft) {
                                lastSent = now
                                zoomDraft = v
                                session.launchPublic { session.setZoomPosition(v / 10.0) }
                            }
                        },
                    )
                }
                SheetRoute.Detail -> DetailSheet(session, logs) {
                    activeSheet = null
                    onDisconnect()
                }
                SheetRoute.Mode -> OcSelectionSheet(title = "录制模式") {
                    Column(verticalArrangement = Arrangement.spacedBy(OcMetrics.OptionRowSpacing)) {
                        OsmoA4.MODE_NAMES.forEach { (code, name) ->
                            OcOptionRow(
                                title = name,
                                isSelected = st.captureMode == code,
                                icon = modeSymbol(code),
                                modifier = Modifier.clickable {
                                    activeSheet = null
                                    session.launchPublic { session.switchMode(code) }
                                },
                            )
                        }
                        OcOptionRow(
                            title = "直播",
                            isSelected = false,
                            icon = Icons.Filled.WifiTethering,
                            muted = true,
                            modifier = Modifier.clickable {
                                liveNotice = "直播未实现：OA4 不支持直播模式，当前拍摄模式保持不变"
                            },
                        )
                    }
                    if (liveNotice != null) {
                        Text(liveNotice ?: "", color = OC.recRed, fontSize = 12.sp)
                    }
                }
            }
        }
    }
}

// MARK: 顶部状态两行（第一行 电量·温度/SD；第二行 分辨率帧率）

@Composable
private fun TopStatus(st: com.openmimo.control.protocol.OsmoStatusSnapshot, onTapDetail: () -> Unit) {
    Column(
        Modifier
            .fillMaxWidth()
            .clickable { onTapDetail() }
            .padding(horizontal = 14.dp, vertical = 8.dp)
            .heightIn(min = OcMetrics.RowHeight),
    ) {
        val battery = buildString {
            st.batteryPercent?.let { append("电量 $it%") }
            st.batteryTempDeciC?.let {
                if (isNotEmpty()) append(" · ")
                append("%.1f°C".format(it / 10.0))
            }
        }
        val sd = st.sdTotalMB?.let { total ->
            "SD %.1f/%.0fGB".format((st.sdFreeMB ?: 0) / 1024.0, total / 1024.0)
        } ?: "SD —"
        Text(
            listOf(battery, sd).filter { it.isNotEmpty() }.joinToString("  ·  "),
            fontSize = 10.sp,
            color = OC.textSecondary,
            modifier = Modifier.fillMaxWidth(),
            textAlign = TextAlign.End,
        )
        Text(
            "${st.videoResolutionName ?: "—"}/${st.videoFpsName?.let { "${it}fps" } ?: "—"}",
            fontSize = 10.sp,
            color = OC.textSecondary,
        )
    }
}

// MARK: 预览卡（H.265 TextureView + 捏合变焦 + 双击复位 + REC 角标 + 网格）

@Composable
private fun PreviewCard(
    session: OsmoSession,
    frameCount: Int,
    orientationCode: Int?,
    zoomFactor: Double,
    recordState: Int?,
    recordSeconds: Long?,
    captureMode: Int?,
    gridMode: Int,
    onTapDouble: () -> Unit,
    onPinch: (Boolean) -> Unit,
    onPinchEnd: () -> Unit,
) {
    val correction = (((4 - (orientationCode ?: 0)) % 4) * 90).toFloat()
    Box(
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp)
            .aspectRatio(16f / 9f)
            .clip(RoundedCornerShape(14.dp))
            .background(Color.Black)
            .pointerInput(Unit) {
                awaitEachGesture {
                    awaitFirstDown()
                    do {
                        val event = awaitPointerEvent()
                        val zoom = event.calculateZoom()
                        if (zoom != 1f) onPinch(zoom > 1f)
                    } while (event.changes.any { it.pressed })
                    onPinchEnd()
                }
            }
            .pointerInput(Unit) {
                detectTapGestures(onDoubleTap = { onTapDouble() })
            },
    ) {
        if (frameCount > 0) {
            AndroidTextureView(session, correction)
        } else {
            Column(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text("预览待连接", color = OC.textSecondary, fontSize = 12.sp)
            }
        }
        if (recordState == 2) {
            Row(
                Modifier
                    .align(Alignment.TopStart)
                    .padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.65f), RoundedCornerShape(50))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(7.dp).background(OC.recRed, CircleShape))
                Text(
                    "  REC " + formatRec(recordSeconds ?: 0),
                    color = Color.White,
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    fontFamily = FontFamily.Monospace,
                )
            }
        }
        if (zoomFactor > 1.01) {
            Text(
                String.format("%.1fx", zoomFactor),
                color = Color.White,
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .align(Alignment.TopEnd)
                    .padding(8.dp)
                    .background(Color.Black.copy(alpha = 0.55f), RoundedCornerShape(50))
                    .padding(horizontal = 8.dp, vertical = 4.dp),
            )
        }
        if (gridMode >= 1) {
            GridOverlay(mode = gridMode, modifier = Modifier.fillMaxSize())
        }
    }
}

private fun formatRec(seconds: Long): String {
    val s = seconds.coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60)
    else "%02d:%02d".format(s / 60, s % 60)
}

/** 取景网格叠加（App 端叠加，不向相机发送命令） */
@Composable
private fun GridOverlay(mode: Int, modifier: Modifier = Modifier) {
    Canvas(modifier = modifier) {
        val w = size.width
        val h = size.height
        val paint = Color.White.copy(alpha = 0.45f)
        val strokeWidth = 1.5f
        for (i in 1..2) {
            drawLine(paint, Offset(w * i / 3f, 0f), Offset(w * i / 3f, h), strokeWidth)
            drawLine(paint, Offset(0f, h * i / 3f), Offset(w, h * i / 3f), strokeWidth)
        }
        if (mode >= 2) {
            drawLine(paint, Offset(0f, 0f), Offset(w, h), strokeWidth)
            drawLine(paint, Offset(w, 0f), Offset(0f, h), strokeWidth)
        }
    }
}

/** H.265 渲染宿主（TextureView 承载 MediaCodec 输出 Surface；朝向修正旋转） */
@Composable
private fun AndroidTextureView(session: OsmoSession, rotationDegrees: Float) {
    AndroidView(
        modifier = Modifier
            .fillMaxSize()
            .graphicsLayer { rotationZ = rotationDegrees },
        factory = { ctx ->
            TextureView(ctx).also { tv ->
                tv.surfaceTextureListener = object : android.view.TextureView.SurfaceTextureListener {
                    override fun onSurfaceTextureAvailable(st: android.graphics.SurfaceTexture, w: Int, h: Int) {
                        session.attachRenderSurface(Surface(st))
                    }

                    override fun onSurfaceTextureSizeChanged(st: android.graphics.SurfaceTexture, w: Int, h: Int) {}

                    override fun onSurfaceTextureDestroyed(st: android.graphics.SurfaceTexture): Boolean {
                        session.detachRenderSurface()
                        return true
                    }

                    override fun onSurfaceTextureUpdated(st: android.graphics.SurfaceTexture) {}
                }
            }
        },
    )
}

// MARK: 详情弹窗（全量遥测 + 诊断 + 断开）

@Composable
private fun DetailSheet(session: OsmoSession, logs: List<String>, onDisconnect: () -> Unit) {
    val st by session.osmoStatus.collectAsState()
    val clipboard = LocalClipboardManager.current
    val rows = detailRows(st)
    Column(Modifier.fillMaxWidth().padding(16.dp)) {
        Text("相机状态详情", fontSize = 17.sp, fontWeight = FontWeight.Bold, color = OC.textPrimary)
        Spacer(Modifier.height(8.dp))
        rows.forEach { (k, v) ->
            Row(Modifier.fillMaxWidth().padding(vertical = 2.dp)) {
                Text(k, fontSize = 11.sp, color = OC.textSecondary, modifier = Modifier.width(88.dp))
                Text(v, fontSize = 11.sp, color = OC.textPrimary, fontFamily = FontFamily.Monospace)
            }
        }
        Spacer(Modifier.height(8.dp))
        Text("诊断日志", fontSize = 12.sp, fontWeight = FontWeight.Medium, color = OC.textSecondary)
        Spacer(Modifier.height(4.dp))
        DiagnosticsLogViewCompat(lines = logs.takeLast(30))
        Spacer(Modifier.height(10.dp))
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Icon(
                Icons.Filled.ContentCopy,
                contentDescription = "复制诊断信息",
                tint = OC.accent,
                modifier = Modifier
                    .size(24.dp)
                    .clickable {
                        clipboard.setText(AnnotatedString(copyDiagnostics(rows.map { "${it.first}: ${it.second}" })))
                    },
            )
            Text(
                "断开连接",
                color = Color.White,
                fontSize = 13.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier
                    .background(OC.recRed, RoundedCornerShape(12.dp))
                    .clickable { onDisconnect() }
                    .padding(horizontal = 18.dp, vertical = 12.dp),
            )
        }
    }
}

@Composable
private fun DiagnosticsLogViewCompat(lines: List<String>) {
    com.openmimo.control.ui.common.DiagnosticsLogView(lines = lines)
}

private fun detailRows(st: com.openmimo.control.protocol.OsmoStatusSnapshot): List<Pair<String, String>> = listOf(
    "拍摄模式" to (st.captureModeName ?: "—"),
    "工作状态" to (st.workModeName ?: "—"),
    "录制状态" to (st.recordStateName ?: "—"),
    "已录时长" to formatRec(st.recordSeconds ?: st.clipSeconds ?: 0),
    "写文件" to if (st.isWritingFile) "是" else "否",
    "媒体库模式" to if (st.mediaMode) "开" else "关",
    "视频格式" to listOf(st.videoResolutionName, st.videoFpsName?.let { "$it fps" }).filterNotNull().joinToString(" "),
    "曝光模式" to (st.exposureModeName ?: "—"),
    "ISO" to (st.isoName ?: "—"),
    "快门" to (st.shutterName ?: "—"),
    "EV 补偿" to (st.expoCompName ?: "—"),
    "白平衡" to (st.wbName ?: "—"),
    "色彩档位" to (st.colorProfileName ?: "—"),
    "锐度" to (st.sharpness?.toString() ?: "—"),
    "降噪" to (st.denoise?.toString() ?: "—"),
    "电池" to (st.batteryPercent?.let { "$it%" } ?: "—"),
    "电池电压" to (st.batteryVoltageMV?.let { "$it mV" } ?: "—"),
    "电池电流" to (st.batteryCurrentMA?.let { if (it < 0) "放电 ${-it} mA" else "充电 $it mA" } ?: "—"),
    "电池温度" to (st.batteryTempDeciC?.let { "%.1f °C".format(it / 10.0) } ?: "—"),
    "相机朝向" to (st.orientationCode?.let { listOf("上", "左横置", "下", "右横置")[it % 4] } ?: "—"),
    "弱光增稳" to (st.lowLightCode?.let { if (it == 1) "开" else "关" } ?: "—"),
)

// MARK: 简易滚轮（系统 wheel 的 Android 近似：滚动列表 + 点击选择）

@Composable
private fun SimpleWheel(
    items: List<Int>,
    selected: Int,
    label: (Int) -> String,
    onSelect: (Int) -> Unit,
    onCenterChange: (Int) -> Unit = {},
) {
    val listState = androidx.compose.foundation.lazy.rememberLazyListState()
    val initialIndex = items.indexOf(selected).coerceAtLeast(0)
    androidx.compose.runtime.LaunchedEffect(Unit) {
        listState.scrollToItem(initialIndex)
    }
    // 视口中心项（滚动跨档语义，对齐 iOS wheel 逐档回调）
    val centerIndex by androidx.compose.runtime.remember {
        androidx.compose.runtime.derivedStateOf {
            val info = listState.layoutInfo.visibleItemsInfo
            if (info.isEmpty()) null
            else {
                val viewportStart = listState.layoutInfo.viewportStartOffset
                val viewportEnd = listState.layoutInfo.viewportEndOffset
                val center = (viewportStart + viewportEnd) / 2
                info.minByOrNull {
                    kotlin.math.abs((it.offset + it.size / 2) - center)
                }?.index
            }
        }
    }
    androidx.compose.runtime.LaunchedEffect(centerIndex) {
        centerIndex?.let { idx ->
            items.getOrNull(idx)?.let { onCenterChange(it) }
        }
    }
    androidx.compose.foundation.lazy.LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxWidth()
            .height(200.dp),
    ) {
        items(items) { v ->
            val isCenter = v == selected
            Text(
                label(v),
                fontSize = if (isCenter) 18.sp else 15.sp,
                fontWeight = if (isCenter) FontWeight.Bold else FontWeight.Normal,
                color = if (isCenter) OC.textPrimary else OC.textTertiary,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .height(44.dp)
                    .clickable { onSelect(v) }
                    .padding(vertical = 10.dp),
            )
        }
    }
}

@Composable
private fun GroupLabel(text: String) {
    Text(
        text,
        fontSize = 10.sp,
        color = OC.textTertiary,
        modifier = Modifier.padding(top = 8.dp, bottom = 2.dp),
    )
}

// MARK: 辅助

/** 快门原始码列表（视频模式上限 1/25；其余全表） */
private fun shutterRawsFor(captureMode: Int?): List<Long> =
    if (captureMode == OsmoA4.MODE_VIDEO) {
        OsmoA4.SHUTTER_SPEEDS.filter { (OsmoA4.shutterSeconds(it) ?: 0.0) <= 1.0 / 25.0 + 1e-9 }
    } else {
        OsmoA4.SHUTTER_SPEEDS.toList()
    }

private fun intervalText(tenths: Int): String =
    if (tenths % 10 == 0) "${tenths / 10}s" else "%.1fs".format(tenths / 10.0)

/** 弹窗路由（唯一 sheet 的 item：与 iOS ControlSheetRoute 同构）。 */
private sealed class SheetRoute {
    class Options(
        val title: String,
        val options: List<String>,
        val initialIndex: Int,
        val onPick: (Int) -> Unit,
    ) : SheetRoute()
    class Wheel(
        val title: String,
        val items: List<Int>,
        val options: List<String>,
        val initialIndex: Int,
        val live: Boolean,
        val onPick: (Int) -> Unit,
        val onClose: (() -> Unit)? = null,
    ) : SheetRoute()
    object EvWheel : SheetRoute()
    object ZoomWheel : SheetRoute()
    object Detail : SheetRoute()
    object Mode : SheetRoute()
}

/** 模式图标（SF Symbols → Material Icons 映射） */
fun modeSymbol(code: Int?): ImageVector = when (code) {
    OsmoA4.MODE_PHOTO -> Icons.Filled.PhotoCamera
    OsmoA4.MODE_SUPER_NIGHT -> Icons.Filled.DarkMode
    OsmoA4.MODE_SLOWMO -> Icons.Filled.SlowMotionVideo
    OsmoA4.MODE_TIMELAPSE -> Icons.Filled.Timer
    OsmoA4.MODE_HYPERLAPSE -> Icons.Filled.AvTimer
    else -> Icons.Filled.Videocam
}

/** OsmoSession 协程便利扩展（launch 于会话 scope） */
fun OsmoSession.launchPublic(block: suspend () -> Unit) {
    scope.launch { block() }
}
