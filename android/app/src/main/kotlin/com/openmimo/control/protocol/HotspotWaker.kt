package com.openmimo.control.protocol

import android.Manifest
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothManager
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/**
 * OA4 热点唤醒（移植自 iOS HotspotWaker）：相机休眠时热点关闭，手机反向广播
 * `WKP + 相机MAC反序` 持续 2.5s/轮 ×2 轮（相机侧按 "WKP" 模式扫描，两种偏移各试）。
 * Android 经 BluetoothLeAdvertiser 广播 manufacturer data（OTA 自动带 2 字节 CID 前缀）。
 */
class HotspotWaker(private val context: Context) {

    var logSink: ((String) -> Unit)? = null

    private var advertiser: android.bluetooth.le.BluetoothLeAdvertiser? = null

    private fun log(line: String) { logSink?.invoke(line) }

    fun wakeCamera(macReversed: ByteArray, rounds: Int = 2) {
        val adapter = (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        val adv = adapter?.bluetoothLeAdvertiser
        if (adv == null) {
            log("[wake] ✗ 设备不支持 BLE 广播")
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADVERTISE) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            log("[wake] ✗ 广播权限未授予（BLUETOOTH_ADVERTISE）")
            return
        }
        advertiser = adv
        val wkp = byteArrayOf(0x57, 0x4B, 0x50)   // "WKP"
        val waker = adv
        scopeLaunch(rounds) { round ->
            // 变体 A：WKP+MAC反序（CID 占位 0）；变体 B：额外 2 字节占位 + WKP+MAC
            // （iOS CBPeripheralManager 自动加 CID 前缀的两种偏移补偿）
            val payload = if (round % 2 == 0) {
                byteArrayOf(0x00, 0x00) + wkp + macReversed
            } else {
                wkp + macReversed
            }
            log("[wake] 发起广播 round=$round payload=${payload.toHexString()}")
            val settings = AdvertiseSettings.Builder()
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
                .setConnectable(false)
                .setTimeout(2500)
                .build()
            val data = AdvertiseData.Builder()
                .addManufacturerData(0x0000, payload)
                .setIncludeDeviceName(false)
                .setIncludeTxPowerLevel(false)
                .build()
            waker.startAdvertising(settings, data, advertiseCallback)
        }
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings?) {
            log("[wake] ✓ 广播已启动")
        }

        override fun onStartFailure(errorCode: Int) {
            log("[wake] ✗ 广播启动失败: errorCode=$errorCode（payload 长度? 权限?）")
        }
    }

    private fun scopeLaunch(rounds: Int, body: (Int) -> Unit) {
        Thread {
            for (round in 1..rounds) {
                body(round)
                try { Thread.sleep(2500) } catch (_: InterruptedException) { return@Thread }
            }
        }.apply { isDaemon = true; name = "osmo-wake-adv"; start() }
    }
}
