package com.openmimo.control.protocol

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * BLE 唤醒 + 凭据获取一体机（移植自 iOS CameraBleWaker，复刻 Mimo 完整连接流程）：
 * 1. 扫描 "Osmo/OA4/OA5" 前缀外设
 * 2. BLE 连接 → FFF0 服务 → 特征就绪（FFF4 notify / FFF5 write）
 * 3. 配对状态机（osmo-client 逐行比对）：握手 → 配对(osmo 身份) → 等相机批准
 * 4. 配对后：唤醒 → TOKEN → 配置 → 订阅/查询 → get_ssid → get_password
 * 5. 凭据应答为明文（pklg 实证 Mimo 不走 R 认证无 ECDH）
 * 6. keepBLEAlive：60s 保活（00/2b [01 01]）——WiFi datalink 期间相机依赖此 BLE 会话
 */
class CameraBleWaker(private val context: Context, private val scope: CoroutineScope) {

    companion object {
        val SERVICE_UUID: UUID = UUID.fromString("0000FFF0-0000-1000-8000-00805F9B34FB")
        val WRITE_CHAR_UUID: UUID = UUID.fromString("0000FFF5-0000-1000-8000-00805F9B34FB")
        val NOTIFY_CHAR_UUID: UUID = UUID.fromString("0000FFF4-0000-1000-8000-00805F9B34FB")
        val FFF3_CHAR_UUID: UUID = UUID.fromString("0000FFF3-0000-1000-8000-00805F9B34FB")
        val CCC_DESCRIPTOR_UUID: UUID = UUID.fromString("00002902-0000-1000-8000-00805F9B34FB")
        val NAME_PREFIXES = listOf("Osmo", "OA4", "OA5")

        private val DEFAULT_TOKEN_BYTES = byteArrayOf(
            0x20, 0x63, 0x33, 0x38, 0x32, 0x66, 0x65, 0x34, 0x34, 0x36, 0x30, 0x35,
            0x36, 0x61, 0x32, 0x37, 0x66, 0x36, 0x30, 0x66, 0x62, 0x31, 0x30, 0x38,
            0x39, 0x63, 0x30, 0x38, 0x63, 0x61, 0x64, 0x35, 0x33, 0x04, 0x37, 0x33,
            0x34, 0x30, 0x01, 0x01,
        )
    }

    data class CredentialResult(val ssid: String, val password: String)

    /** 统一诊断（宿主注入；所有 BLE 日志含收发帧 hex 流入诊断面板） */
    var logSink: ((String) -> Unit)? = null
    @Volatile var status: String = "空闲"; private set

    private val prefs by lazy {
        context.getSharedPreferences("openmimo", Context.MODE_PRIVATE)
    }

    private val adapter: BluetoothAdapter?
        get() = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter

    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var fff3Char: BluetoothGattCharacteristic? = null
    private val frameBuffer = mutableListOf<Byte>()
    private var frameSeq = 0x100
    private val inFlight = AtomicBoolean(false)
    private var credentialJob: Job? = null
    private var keepAliveOn = AtomicBoolean(false)
    private var keepaliveJob: Job? = null
    private var macScanCallback: ((ByteArray?) -> Unit)? = null
    private val sequenceStarted = AtomicBoolean(false)
    private val appIdentity = "284ae5b8d76b3375a04a6417ad71bea3"

    // 配对状态机
    private var pairingDone = false
    private var pairStatusReceived = false
    private var postPairingSent = false
    private var pairPayload: ByteArray? = null
    private var token: ByteArray = ByteArray(0)

    private var ssidResult: String? = null
    private var passwordResult: String? = null
    private var currentCompletion: ((CredentialResult?) -> Unit)? = null

    private fun log(line: String) {
        status = line
        logSink?.invoke(line)
    }

    private fun logFrame(direction: String, data: ByteArray) {
        log("${direction}帧 hex[${data.size}B]: ${data.toHexString()}")
    }

    private fun nextSeq(): Int {
        frameSeq = (frameSeq + 1) and 0xFFFF
        return frameSeq
    }

    // MARK: 权限

    fun hasBluetoothPermissions(): Boolean {
        val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            listOf(
                Manifest.permission.BLUETOOTH,
                Manifest.permission.BLUETOOTH_ADMIN,
                Manifest.permission.ACCESS_FINE_LOCATION,
            )
        }
        return perms.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    fun requiredBluetoothPermissions(): List<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
        } else {
            listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    private fun assertConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    // MARK: 公开接口

    /** 扫描→连接→配对→凭据。返回 null = 失败（iOS connectAndGetCredentials 语义）。 */
    suspend fun connectAndGetCredentials(timeoutMs: Long = 60_000): CredentialResult? {
        if (!inFlight.compareAndSet(false, true)) return null
        pairingDone = false
        pairStatusReceived = false
        postPairingSent = false
        sequenceStarted.set(false)
        ssidResult = null
        passwordResult = null
        synchronized(frameBuffer) { frameBuffer.clear() }
        writeChar = null
        notifyChar = null
        gatt = null

        val adapter = adapter
        if (adapter == null || !adapter.isEnabled) {
            log("✗ 手机蓝牙未开启——请到控制中心打开蓝牙")
            inFlight.set(false)
            return null
        }
        if (!hasBluetoothPermissions()) {
            log("✗ 蓝牙权限未授予（扫描/连接）")
            inFlight.set(false)
            return null
        }

        try {
            val result = suspendCancellableCoroutine { cont ->
                currentCompletion = { r -> if (cont.isActive) cont.resumeWith(Result.success(r)) }
                log("启动 BLE 流程：扫描→连接→配对→凭据")
                startScan()

                // 总超时
                credentialJob = scope.launch {
                    delay(timeoutMs)
                    if (inFlight.get()) {
                        log("⏱ 超时（${timeoutMs / 1000}s）。阶段: $status；已配对=$pairingDone ssid=${ssidResult ?: "nil"}")
                        log("提示：若停在'发现相机'→检查相机蓝牙；配对需在相机屏幕确认")
                        finish(null)
                    }
                }
            }
            return result
        } finally {
            currentCompletion = null
            credentialJob?.cancel()
            credentialJob = null
            inFlight.set(false)
        }
    }

    private fun finish(result: CredentialResult?) {
        if (result != null) log("成功：SSID=${result.ssid} ✓") else log("BLE 流程未完成：$status")
        // keepalive 开启时不断开：WiFi datalink 依赖此 BLE 会话（osmocam §3.3）
        if (!keepAliveOn.get()) {
            try { gatt?.disconnect() } catch (_: Exception) {}
        }
        val cb = currentCompletion
        currentCompletion = null
        cb?.invoke(result)
    }

    /** BLE 会话是否已建立（连接 + 写特征就绪）——复用直连路径据此跳过冗余扫描 */
    val bleSessionReady: Boolean
        get() = keepAliveOn.get() && gatt != null && writeChar != null

    /** keepBLEAlive(true)：置位并启动 60s 保活循环 */
    fun keepBLEAlive(on: Boolean) {
        keepAliveOn.set(on)
        keepaliveJob?.cancel()
        if (on) {
            keepaliveJob = scope.launch(Dispatchers.IO) {
                // iOS：60s 节奏真机 A/B 实测流畅（5s/30s/60s 均无中断）
                while (keepAliveOn.get()) {
                    delay(60_000)
                    if (!keepAliveOn.get()) break
                    sendKeepaliveTick()
                }
            }
        }
    }

    private fun sendKeepaliveTick() {
        val wc = writeChar ?: return
        val frame = Duml.encode(
            0x02.toByte(), 0xF0.toByte(), 0x802B, 0x40.toByte(), 0x00, 0x2B,
            byteArrayOf(0x01, 0x01), Duml.Variant.BLE,
        )
        sendVia(frame, wc, "BLE-keepalive(00,2b)")
    }

    /** 轻量 MAC 扫描（ConnectionFlow waking 步骤用）：只取 MAC 不建链 */
    suspend fun scanOnceForMAC(timeoutMs: Long): ByteArray? {
        val adapter = adapter ?: return null
        if (!hasBluetoothPermissions()) return null
        macScanCallback = null
        val scanner = adapter.bluetoothLeScanner ?: return null
        try {
            scanner.startScan(scanCallback)
        } catch (e: Exception) {
            log("✗ MAC 扫描启动失败: ${e.message}")
            return null
        }
        return suspendCancellableCoroutine { cont ->
            macScanCallback = { mac ->
                if (cont.isActive) cont.resumeWith(Result.success(mac))
            }
            scope.launch {
                delay(timeoutMs)
                if (macScanCallback != null) {
                    try { scanner.stopScan(scanCallback) } catch (_: Exception) {}
                    val cb = macScanCallback
                    macScanCallback = null
                    cb?.invoke(null)
                }
            }
        }
    }

    // MARK: 扫描

    private val scanCallback: android.bluetooth.le.ScanCallback = object : android.bluetooth.le.ScanCallback() {
        override fun onScanResult(callbackType: Int, result: android.bluetooth.le.ScanResult) {
            val device = result.device ?: return
            val name = device.name ?: result.scanRecord?.deviceName ?: ""
            // 纯 MAC 扫描路径：manufacturer data 尾 6 字节 = 相机 MAC
            val mf = result.scanRecord?.manufacturerSpecificData
            if (macScanCallback != null) {
                if (mf != null && mf.size() >= 6) {
                    try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) {}
                    val arr = mf.valueAt(0)
                    val mac = arr.copyOfRange(arr.size - 6, arr.size)
                    prefs.edit().putString("camera.mac", mac.toHexString()).apply()
                    val cb = macScanCallback
                    macScanCallback = null
                    cb?.invoke(mac)
                }
                return
            }
            if (!inFlight.get() || gatt != null) return
            if (NAME_PREFIXES.none { name.startsWith(it) }) return
            log("发现相机 $name（RSSI ${result.rssi}）")
            result.scanRecord?.manufacturerSpecificData?.let { mf ->
                if (mf.size() >= 6) {
                    val arr = mf.valueAt(0)
                    val mac = arr.copyOfRange(arr.size - 6, arr.size)
                    prefs.edit().putString("camera.mac", mac.toHexString()).apply()
                    log("相机 MAC=${mac.toHexString()}")
                }
            }
            try { adapter?.bluetoothLeScanner?.stopScan(scanCallback) } catch (_: Exception) {}
            connectDevice(device)
        }
    }

    private fun startScan() {
        val scanner = adapter?.bluetoothLeScanner
        if (scanner == null) {
            log("✗ BLE 扫描器不可用")
            finish(null)
            return
        }
        log("蓝牙就绪，扫描相机…")
        try {
            scanner.startScan(scanCallback)
        } catch (e: SecurityException) {
            log("✗ 扫描失败（权限）: ${e.message}")
            finish(null)
        }
    }

    // MARK: 连接与 GATT

    private fun connectDevice(device: BluetoothDevice) {
        if (!assertConnectPermission()) { finish(null); return }
        log("BLE 连接中…")
        gatt = device.connectGatt(context, false, gattCallback, BluetoothDevice.TRANSPORT_LE)
    }

    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    if (!inFlight.get()) { startKeepaliveLoopIfReady(); return }
                    log("BLE 已连接，发现服务…")
                    try { g?.discoverServices() } catch (_: SecurityException) {}
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    log("BLE 断开")
                    if (!keepAliveOn.get()) {
                        try { g.close() } catch (_: Exception) {}
                    }
                    if (inFlight.get()) {
                        val s = ssidResult
                        finish(if (s != null) CredentialResult(s, passwordResult ?: "") else null)
                    }
                }
            }
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            if (!inFlight.get()) return
            val service = g.getService(SERVICE_UUID)
            if (service == null) {
                log("未找到 FFF0 服务")
                gatt?.disconnect()
                finish(null)
                return
            }
            // Android discoverServices 一次性带回全部特征；直接接线 FFF4/FFF5/FFF3
            for (c in service.characteristics) {
                when (c.uuid) {
                    NOTIFY_CHAR_UUID -> {
                        notifyChar = c
                        try {
                            g.setCharacteristicNotification(c, true)
                            c.getDescriptor(CCC_DESCRIPTOR_UUID)?.let {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                    g.writeDescriptor(it, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                                } else {
                                    @Suppress("DEPRECATION")
                                    g.writeDescriptor(it, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                                }
                            }
                        } catch (_: SecurityException) {}
                    }
                    WRITE_CHAR_UUID -> writeChar = c
                    FFF3_CHAR_UUID -> {
                        fff3Char = c
                        try {
                            g.setCharacteristicNotification(c, true)
                            c.getDescriptor(CCC_DESCRIPTOR_UUID)?.let {
                                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                    g.writeDescriptor(it, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                                } else {
                                    @Suppress("DEPRECATION")
                                    g.writeDescriptor(it, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                                }
                            }
                        } catch (_: SecurityException) {}
                    }
                }
            }
        }

        override fun onCharacteristicRead(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
            onCharacteristicChangedCommon(c, value)
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            // 写完成（withResponse）；帧序按序发送，无需额外动作
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            // FFF4/FFF3 订阅完成：首个订阅落定即启动帧序（iOS 在特征发现后立即发，不等订阅）
            if (notifyChar != null && writeChar != null && !sequenceStarted.getAndSet(true)) {
                log("特征就绪，发送 DUML 帧序（Mimo 实测配对流程）…")
                scope.launch(Dispatchers.IO) {
                    delay(200)
                    startDUMLSequence()
                }
            }
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            onCharacteristicChangedCommon(c, value)
        }

        private fun onCharacteristicChangedCommon(c: BluetoothGattCharacteristic, value: ByteArray) {
            if (!inFlight.get()) return
            logFrame("RX-通知原始@${c.uuid}", value)
            synchronized(frameBuffer) {
                frameBuffer.addAll(value.toList())
                processBuffer()
            }
        }
    }

    private fun startKeepaliveLoopIfReady() {
        // 断线重连后恢复保活（keepAliveOn 已置位时 GATT 重连场景）
        if (keepAliveOn.get()) keepBLEAlive(true)
    }

    // MARK: 发送

    private fun send(frame: ByteArray, label: String) {
        val wc = writeChar ?: run {
            log("✗ 发送失败（写特征未就绪）：$label")
            return
        }
        sendVia(frame, wc, label)
    }

    private fun sendVia(frame: ByteArray, char: BluetoothGattCharacteristic, label: String) {
        val g = gatt ?: return
        if (!assertConnectPermission()) return
        log("→ 发送$label [${frame.size}B] via ${char.uuid}")
        logFrame("TX-$label", frame)
        try {
            char.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                g.writeCharacteristic(char, frame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            } else {
                @Suppress("DEPRECATION")
                g.writeCharacteristic(char, frame, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            }
        } catch (e: SecurityException) {
            log("✗ 发送失败（权限）: ${e.message}")
        }
    }

    // MARK: 配对状态机（移植自 iOS startDUMLSequence / runPostPairingSequence）

    private fun startDUMLSequence() {
        val tokenBytes = prefs.getString("camera.wms_token", null)
            ?.hexToBytes() ?: DEFAULT_TOKEN_BYTES
        prefs.edit().putString("camera.wms_token", tokenBytes.toHexString()).apply()
        // 落盘：WiFi datalink 的 poke（OsmoCameraLink）用同一 token 作已配对身份
        token = tokenBytes

        val identity = appIdentity.toByteArray(Charsets.US_ASCII)
        val pairPl = ByteArray(1 + identity.size + 1 + 4)
        pairPl[0] = identity.size.toByte()
        identity.copyInto(pairPl, 1)
        pairPl[1 + identity.size] = 4
        "osmo".toByteArray(Charsets.US_ASCII).copyInto(pairPl, 2 + identity.size)
        pairPayload = pairPl

        fun sendBleDuml(dst: Int, set: Int, id: Int, payload: ByteArray, seq: Int, name: String) {
            val frame = Duml.encode(
                0x02.toByte(), dst.toByte(), seq, 0x40.toByte(),
                set.toByte(), id.toByte(), payload, Duml.Variant.BLE,
            )
            send(frame, "DUML-$name [${frame.size}B] via FFF5")
        }

        scope.launch(Dispatchers.IO) {
            delay(500)
            var seq = 0x31D3
            // 阶段A：仅两帧（收到 0002 后相机屏幕弹提示，此期间发其他 07/45 会顶掉提示）
            sendBleDuml(0xF0, 0x00, 0x2B, byteArrayOf(0x04, 0x00), seq, "握手")
            seq = (seq + 1) and 0xFFFF
            sendBleDuml(0x07, 0x07, 0x45, pairPl, seq, "配对(osmo)")
            seq = (seq + 1) and 0xFFFF
            // 参考实现 _wait_for_pairing：完全无应答才在 2.5s/5s 重发；有状态(0002)则静默等批准
            launch {
                repeat(2) { round ->
                    delay(if (round == 0) 2500 else 2500)
                    if (!pairingDone && !pairStatusReceived) {
                        val f = Duml.encode(
                            0x02.toByte(), 0x07.toByte(), 0x8092, 0x40.toByte(),
                            0x07, 0x45, pairPl, Duml.Variant.BLE,
                        )
                        send(f, "DUML-配对重发(40,7,45)")
                    }
                }
            }
            // 配对门总闸：90s（参考实现 approve_timeout 默认值）
            launch {
                delay(90_000)
                if (!pairingDone) {
                    log("✗ 配对未在 90s 内完成（相机屏幕提示 20s/次，确认后自动继续）")
                }
            }
            log("配对门：等待相机应答（0001=已配对 / 0002=请在相机屏幕按确认，20s 内）")
        }
    }

    /** 阶段B：配对完成后才允许发（批准 → wake → keepalive → 凭据查询） */
    private fun runPostPairingSequence() {
        if (postPairingSent) return
        postPairingSent = true
        log("▶ 配对完成，继续 BLE 流程（唤醒→凭据）")
        val queries = listOf(
            listOf(0x1C, 0x53, 0x10) to (byteArrayOf(0x00, 0x00, 0x00, 0x00) to "唤醒(53,10)"),
            listOf(0x07, 0x07, 0x45) to (token to "TOKEN"),
            listOf(0x88, 0x00, 0x32) to (byteArrayOf(0x31, 0x31, 0x00, 0x00, 0x00) to "配置(00,32)"),
            listOf(0x88, 0x00, 0x32) to (byteArrayOf(0x31, 0x31, 0x00, 0x00, 0x00) to "配置(00,32)#2"),
            listOf(0x08, 0x02, 0x8E) to (byteArrayOf(0x00, 0x01, 0x1C, 0x00) to "订阅(02,8e)"),
            listOf(0x08, 0x08, 0x79) to (byteArrayOf(0x00) to "查询(08,79)"),
            listOf(0x07, 0x07, 0x07) to (byteArrayOf(0x00) to "get_ssid"),
            listOf(0x07, 0x07, 0x0E) to (byteArrayOf(0x00) to "get_password"),
        )
        scope.launch(Dispatchers.IO) {
            var seq = 0x31E0
            for ((addrSpec, payloadSpec) in queries) {
                val dst = addrSpec[0]
                val set = addrSpec[1]
                val id = addrSpec[2]
                val (payload, name) = payloadSpec
                val frame = Duml.encode(
                    0x02.toByte(), dst.toByte(), seq, 0x40.toByte(),
                    set.toByte(), id.toByte(), payload, Duml.Variant.BLE,
                )
                send(frame, "DUML-$name [${frame.size}B] via FFF5")
                seq = (seq + 1) and 0xFFFF
            }
            log("DUML 帧序发送完成（${queries.size} 条），等待 FFF4 应答…")
        }
    }

    // MARK: DUML 0x55 帧处理

    private fun processBuffer() {
        while (frameBuffer.size >= 3) {
            val sof = frameBuffer[0].toInt() and 0xFF
            if (sof != Duml.SOF.toInt()) {
                // 未知帧头：记录前 16 字节便于观察协议形态
                val head = frameBuffer.take(16).map { it.toByte() }.toByteArray().toHexString()
                log("⚠ 未识别帧头 0x${Integer.toHexString(sof)}，数据头: $head")
                frameBuffer.removeAt(0)
                continue
            }
            val frameLen = (frameBuffer[1].toInt() and 0xFF) or
                ((frameBuffer[2].toInt() and 0x03) shl 8)
            if (frameBuffer.size < frameLen) break
            val chunk = frameBuffer.take(frameLen).map { it.toByte() }.toByteArray()
            val parsed = Duml.parse(chunk, 0)
            if (parsed == null) {
                log("◇ RX 未识别帧 [${frameLen}B]: ${chunk.toHexString()}")
                repeat(maxOf(frameLen, 1)) { if (frameBuffer.isNotEmpty()) frameBuffer.removeAt(0) }
                continue
            }
            repeat(frameLen) { if (frameBuffer.isNotEmpty()) frameBuffer.removeAt(0) }
            val frame = parsed.first
            log("◇ RX DUML 帧: src=0x${Integer.toHexString(frame.sender.toInt() and 0xFF)} dst=0x${Integer.toHexString(frame.receiver.toInt() and 0xFF)} ct=0x${Integer.toHexString(frame.cmdType.toInt() and 0xFF)} set=0x${Integer.toHexString(frame.cmdSet.toInt() and 0xFF)} id=0x${Integer.toHexString(frame.cmdId.toInt() and 0xFF)} payload[${frame.payload.size}B]=${frame.payload.toHexString()}")
            handleDumlFrame(frame)
        }
    }

    /** DUML 帧路由（移植自 iOS handleDumlFrame 的可用路径）：配对状态机 + 凭据应答 + 电量推送 */
    private fun handleDumlFrame(f: Duml.Frame) {
        val p = f.payload
        val set = f.cmdSet.toInt() and 0xFF
        val id = f.cmdId.toInt() and 0xFF
        val ct = f.cmdType.toInt() and 0xFF

        // 配对状态机：07/45 应答 payload[1]: 01=已配对 02=待批准；07/46 payload[0]: 01=已批准
        if (set == 0x07 && id == 0x45 && p.size >= 2) {
            pairStatusReceived = true
            when (p[1].toInt()) {
                0x01 -> {
                    log("✅ 配对状态: 该身份已配对")
                    pairingDone = true
                    runPostPairingSequence()
                }
                0x02 -> log("⚠️ 配对门：请在相机屏幕上按确认（OSMO 提示，20s 内；错过会再弹）")
                else -> log("配对状态: 0x${Integer.toHexString(p[1].toInt() and 0xFF)}")
            }
            // 状态回显（ct 0x40 请求 → 0xC0）
            if (ct and 0x40 != 0 && ct and 0x80 == 0) {
                val echo = Duml.encode(0x02.toByte(), f.sender, nextSeq(), 0xC0.toByte(), 0x07, 0x45, p, Duml.Variant.BLE)
                send(echo, "配对状态回显(0xC0)")
            }
            return
        }
        if (set == 0x07 && id == 0x46) {
            if (p.firstOrNull()?.toInt() == 0x01) {
                log("✅ 相机屏幕已批准配对！→ 继续流程")
                prefs.edit().putBoolean("camera.osmo_paired", true).apply()
                pairingDone = true
                runPostPairingSequence()
            } else {
                log("❌ 配对未批准（拒绝或 20s 超时）——下一轮配对帧会重新弹提示，请及时按")
                postPairingSent = false
            }
            return
        }
        if (set == 0x07 && (id == 0x07 || id == 0x0E)) {
            handleCredentialResponse(id, p)
            return
        }
        // BLE 电量推送 (0x0d,0x02)：@20 u16 LE = 电量百分比
        if (set == 0x0D && id == 0x02) {
            if (p.size >= 22) {
                val pct = OsmoA4.le16(p, 20)
                if (pct in 0..100) {
                    prefs.edit().putInt("camera.battery_percent", pct).apply()
                    log("✓ BLE 电量(0d,02)=$pct%（@20 u16 LE）")
                } else {
                    log("◇ BLE 电量推送(0d,02) @20=$pct 超域，原始=${p.toHexString()}")
                }
            } else {
                log("◇ BLE 电量推送(0d,02) 仅${p.size}B，原始=${p.toHexString()}")
            }
            return
        }
        // (0x02,0xdc) 相机变体推送（诊断观察）
        if (set == 0x02 && id == 0xDC) {
            log("◇ BLE 相机推送(02,dc) [${p.size}B]=${p.toHexString()}")
            return
        }
    }

    /** 凭据应答：payload = [ret:1][len:1][明文数据]（pklg 实证明文，无 ECDH） */
    private fun handleCredentialResponse(cmdId: Int, p: ByteArray) {
        if (p.size < 2) {
            log("⚠ 凭据应答过短（${p.size}B）")
            return
        }
        val ret = p[0].toInt() and 0xFF
        val dataLen = p[1].toInt() and 0xFF
        if (ret != 0 || 2 + dataLen > p.size) {
            log("⚠ 凭据应答异常 ret=0x${Integer.toHexString(ret)} len=$dataLen 实际${p.size}B")
            return
        }
        val text = String(p, 2, dataLen, Charsets.UTF_8)
        if (cmdId == 0x07) {
            ssidResult = text.ifEmpty { null }
            log("✓ SSID: ${ssidResult ?: "?"}")
            prefs.edit().putString("camera.ssid", ssidResult).apply()
        } else {
            passwordResult = text.ifEmpty { null }
            log("✓ PASSWORD: ${passwordResult ?: "?"}（${dataLen}B 明文）")
            passwordResult?.let { prefs.edit().putString("camera.wifi_password", it).apply() }
        }
        val s = ssidResult
        val pw = passwordResult
        if (s != null && pw != null) finish(CredentialResult(s, pw))
    }

    // MARK: 便利读取（对齐 iOS cachedBatteryPercent）

    fun cachedBatteryPercent(): Int? =
        prefs.getInt("camera.battery_percent", -1).takeIf { it >= 0 }

    fun readSSID(): String? = prefs.getString("camera.ssid", null)
    fun readPassword(): String? = prefs.getString("camera.wifi_password", null)
    fun readCameraMacHex(): String? = prefs.getString("camera.mac", null)
}
