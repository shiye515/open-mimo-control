package com.openmimo.control.protocol

/**
 * 十六进制编解码工具：协议调试日志、MAC/凭据解析共用。
 * 对齐 iOS OpenMimoProtocol 的 HexExtensions 语义。
 */
fun ByteArray.toHexString(): String = joinToString("") { "%02x".format(it) }

fun Collection<Byte>.toHexString(): String = joinToString("") { "%02x".format(it) }

/** hex 串 → 字节。两位一组解析，非法字符跳过；结果为空返回 null。 */
fun String.hexToBytes(): ByteArray? {
    val bytes = mutableListOf<Byte>()
    var i = 0
    while (i + 1 < length) {
        substring(i, i + 2).toIntOrNull(16)?.let { bytes.add(it.toByte()) }
        i += 2
    }
    return if (bytes.isEmpty()) null else bytes.toByteArray()
}
