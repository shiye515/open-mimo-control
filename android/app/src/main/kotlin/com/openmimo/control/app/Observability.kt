package com.openmimo.control.app

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 全局统一的诊断日志（移植自 iOS AppDiagnostics）：连接页/控制页显示同一份内容，
 * 复制按钮复制的内容与所见完全一致。同时落盘沙盒 diag.log（adb 可直接拉取）。
 */
object AppDiagnostics {

    private const val MAX_LINES = 120
    private const val MAX_FILE_BYTES = 256 * 1024

    private val linesMutable = MutableStateFlow<List<String>>(emptyList())
    val lines: StateFlow<List<String>> = linesMutable

    /** 时间戳格式化器（DateFormatter 构造开销大；日志热路径逐行复用） */
    private val timestampFormatter = SimpleDateFormat("HH:mm:ss.SSS", Locale.US)

    private var logFile: File? = null
    private val fileLock = Any()

    fun init(context: Context) {
        if (logFile == null) {
            logFile = File(context.filesDir, "diag.log")
            appendToFile("════ OpenMimoControl 诊断会话开始 ════")
        }
    }

    fun add(line: String) {
        val stamped = "[${timestampFormatter.format(Date())}] $line"
        val list = linesMutable.value.toMutableList()
        list.add(stamped)
        if (list.size > MAX_LINES) {
            repeat(list.size - MAX_LINES) { list.removeAt(0) }
        }
        linesMutable.value = list
        appendToFile(stamped)
    }

    /** 共享时间戳读取（StepLogger 复用；HH:mm:ss.SSS） */
    fun timestamp(): String = timestampFormatter.format(Date())

    /** 复制内容 = 所见内容 */
    fun snapshot(extra: List<String> = emptyList()): String =
        (extra + "-- 诊断日志 --" + linesMutable.value).joinToString("\n")

    /** 追加写沙盒文件（synchronized 串行；超 256KB 环形重建——保留尾部 3/4） */
    private fun appendToFile(line: String) {
        val file = logFile ?: return
        synchronized(fileLock) {
            try {
                if (file.length() > MAX_FILE_BYTES) {
                    val keep = MAX_FILE_BYTES * 3 / 4
                    val content = file.readBytes()
                    file.writeBytes(content.copyOfRange(content.size - keep, content.size))
                }
                file.appendText(line + "\n")
            } catch (_: Exception) {
            }
        }
    }
}

/**
 * 连接流程步骤日志（移植自 iOS StepLogger）：
 * 每步指令固定格式 `时间戳 | 步骤名 | 目的 | 内容`，复用 AppDiagnostics 面板。
 */
object StepLogger {

    data class Entry(
        val id: Long,
        val time: String,
        val step: String,
        val purpose: String,
        val content: String,
    )

    private val entriesMutable = MutableStateFlow<List<Entry>>(emptyList())
    val entries: StateFlow<List<Entry>> = entriesMutable
    private var nextId = 1L

    /** 记录一条步骤日志。direction: "→" 发送 / "←" 接收 / "·" 状态 */
    fun log(step: String, purpose: String, direction: String = "·", content: String) {
        val entry = Entry(
            id = nextId++,
            time = AppDiagnostics.timestamp(),
            step = step,
            purpose = "$direction $purpose",
            content = content,
        )
        val list = entriesMutable.value.toMutableList()
        list.add(entry)
        if (list.size > 200) repeat(list.size - 200) { list.removeAt(0) }
        entriesMutable.value = list
        AppDiagnostics.add("[step] ${entry.time} | $step | ${entry.purpose} | $content")
    }

    /** 记录指令帧（内容为 hex） */
    fun logFrame(step: String, direction: String, frame: ByteArray, purpose: String) {
        log(step = step, purpose = purpose, direction = direction, content = "${frame.size}B ${frame.toHexString()}")
    }

    fun clear() {
        entriesMutable.value = emptyList()
    }

    /** 导出全部日志为纯文本 */
    fun export(): String =
        entriesMutable.value.joinToString("\n") { "${it.time} | ${it.step} | ${it.purpose} | ${it.content}" }
}
