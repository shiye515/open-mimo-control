package com.openmimo.control.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat

/** 权限种类（连接页权限行 + 权限请求统一入口）。 */
enum class PermissionKind {
    BLUETOOTH, LOCATION, LOCAL_NETWORK,
}

/** 权限状态与请求（对齐 iOS PermissionStatus；Android 走运行时权限）。 */
class PermissionState(private val context: Context) {

    fun granted(kind: PermissionKind): Boolean = when (kind) {
        PermissionKind.BLUETOOTH -> {
            val perms = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            } else {
                listOf(Manifest.permission.ACCESS_FINE_LOCATION)
            }
            perms.all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }
        }
        PermissionKind.LOCATION ->
            ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) ==
                PackageManager.PERMISSION_GRANTED
        PermissionKind.LOCAL_NETWORK ->
            // Android 无「本地网络」独立权限（INTERNET + 局域网直连即可），视为已授权
            true
    }

    fun requiredPermissions(kind: PermissionKind): List<String> = when (kind) {
        PermissionKind.BLUETOOTH ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                listOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT)
            } else listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        PermissionKind.LOCATION -> listOf(Manifest.permission.ACCESS_FINE_LOCATION)
        PermissionKind.LOCAL_NETWORK -> emptyList()
    }
}
