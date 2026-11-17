package com.openmimo.control.protocol

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.net.wifi.WifiNetworkSuggestion
import androidx.core.content.ContextCompat
import kotlinx.coroutines.delay

/**
 * 相机 Wi-Fi 自动入网（移植自 iOS CameraWifiJoiner；平台差异适配）：
 *
 * iOS 用 NEHotspotConfiguration 直接登记热点；Android 10+ 的等效路径为
 * WifiNetworkSuggestion（登记后系统在相机热点出现时自动接入，无需用户每次确认）：
 * 1. 当前网络已是相机热点 → 直接可用；
 * 2. BLE 凭据到手 → addNetworkSuggestions 登记（覆盖此前对同一 SSID 的建议）；
 * 3. 轮询当前 SSID 等待系统接入（12s 超时，与 iOS autoConnect 相同节奏）。
 */
class CameraWifiJoiner(private val context: Context) {

    companion object {
        /** 相机热点 SSID 前缀（Osmo 系列出厂命名） */
        val CAMERA_SSID_PREFIXES = listOf("OSMO", "Osmo", "osmo", "DJ")
    }

    var logSink: ((String) -> Unit)? = null

    private val prefs by lazy {
        context.getSharedPreferences("openmimo", Context.MODE_PRIVATE)
    }

    private val wifiManager: WifiManager?
        get() = context.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private fun log(line: String) { logSink?.invoke("[wifi] $line") }

    fun hasLocationPermission(): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
            PackageManager.PERMISSION_GRANTED

    fun isCameraSSID(ssid: String): Boolean =
        CAMERA_SSID_PREFIXES.any { ssid.startsWith(it) }

    /** 读取当前 SSID（需要定位权限；未授权返回 null） */
    fun currentSSID(): String? {
        val wm = wifiManager ?: return null
        if (!hasLocationPermission()) return null
        return try {
            val info = wm.connectionInfo
            val ssid = info?.ssid ?: return null
            if (ssid == "<unknown ssid>" || ssid.isEmpty()) null else ssid.removeSurrounding("\"")
        } catch (_: SecurityException) {
            null
        }
    }

    /** 登记相机热点建议网络（Android 10+；用户会收到一次系统提示，批准后自动接入） */
    fun suggest(ssid: String, passphrase: String?): Boolean {
        val wm = wifiManager ?: return false
        val builder = WifiNetworkSuggestion.Builder()
            .setSsid(ssid)
            .setIsAppInteractionRequired(true)   // 相机热点出现时优先自动接入
        if (!passphrase.isNullOrEmpty()) builder.setWpa2Passphrase(passphrase)
        val suggestion = builder.build()
        val previous = prefs.getString("camera.ssid", null)
        val list = mutableListOf(suggestion)
        // 保留此前登记的其它相机热点建议（多相机切换场景）
        previous?.takeIf { it != ssid }?.let { other ->
            val otherPwd = readPassword(other)
            val b = WifiNetworkSuggestion.Builder().setSsid(other)
            if (!otherPwd.isNullOrEmpty()) b.setWpa2Passphrase(otherPwd)
            list.add(b.build())
        }
        val res = wm.addNetworkSuggestions(list)
        log("addNetworkSuggestions($ssid) → $res")
        return res == WifiManager.STATUS_NETWORK_SUGGESTIONS_SUCCESS
    }

    /** 移除某 SSID 的建议登记（冲突恢复） */
    fun removeSuggestion(ssid: String) {
        val wm = wifiManager ?: return
        val b = WifiNetworkSuggestion.Builder().setSsid(ssid)
        readPassword(ssid)?.let { b.setWpa2Passphrase(it) }
        wm.removeNetworkSuggestions(listOf(b.build()))
    }

    /**
     * 等待系统接入热点（12s 快速轮询，移植自 iOS autoConnect）。
     * 返回是否已在目标网络。已在网络直接返回 true。
     */
    suspend fun awaitJoin(targetSsid: String, timeoutMs: Long = 12_000): Boolean {
        val current = currentSSID()
        if (current == targetSsid) {
            log("autoConnect: 已接入 $targetSsid ✓")
            return true
        }
        var lastSeenNetwork: String? = current
        val deadline = System.currentTimeMillis() + timeoutMs
        while (System.currentTimeMillis() < deadline) {
            delay(500)
            val ssid = currentSSID()
            if (ssid == targetSsid) {
                log("autoConnect: 已接入 $targetSsid ✓")
                return true
            }
            if (ssid != null) lastSeenNetwork = ssid
        }
        log("autoConnect: ${timeoutMs / 1000}s 内未接入 $targetSsid（手机始终在 ${lastSeenNetwork ?: "nil"}；热点未广播或建议未批准）")
        return false
    }

    /** 记忆凭据（对齐 iOS remember；密码明文存私有 prefs） */
    fun remember(ssid: String, passphrase: String?) {
        prefs.edit().putString("camera.ssid", ssid).apply()
        if (passphrase != null) {
            prefs.edit().putString("camera.pwd.$ssid", passphrase).apply()
        }
    }

    fun readPassword(ssid: String): String? =
        prefs.getString("camera.pwd.$ssid", null)
}
