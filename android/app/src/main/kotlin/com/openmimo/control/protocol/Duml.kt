package com.openmimo.control.protocol

/**
 * DUML 0x55 帧编解码（BLE 与 WiFi datalink 同构；移植自 iOS CameraBleWaker.buildDUML /
 * OSMOCameraLink.encodeDUML / MimoFrame.parse）。
 *
 * 布局：`55 | len u16 LE | crc8 | src | dst | seq u16 LE | ct | set | id | payload | crc16 LE`
 * - crc8：init 0x77，反射多项式 0x8C，覆盖前 3 字节
 * - crc16：init 0x3692，反射多项式 0x8408，覆盖除尾部 crc16 外全部字节
 * - len 字段低 10 位 = 帧总长；高位随通道不同（WiFi：bit10 置位；BLE：bit2 = 版本 1，
 *   且 BLE 长度含尾部 crc16 两个字节）
 */
object Duml {

    const val SOF: Byte = 0x55

    // MARK: CRC（查表版，与 iOS 位循环实现等价）

    private val CRC8_TABLE = IntArray(256).also { table ->
        for (i in 0 until 256) {
            var v = i
            repeat(8) { v = if (v and 1 != 0) (v shr 1) xor 0x8C else v shr 1 }
            table[i] = v
        }
    }

    private val CRC16_TABLE = IntArray(256).also { table ->
        for (i in 0 until 256) {
            var v = i
            repeat(8) { v = if (v and 1 != 0) (v shr 1) xor 0x8408 else v shr 1 }
            table[i] = v
        }
    }

    fun crc8(data: ByteArray, offset: Int = 0, length: Int = data.size, init: Int = 0x77): Byte {
        var crc = init
        for (i in offset until offset + length) {
            crc = CRC8_TABLE[(crc xor data[i].toInt()) and 0xFF]
        }
        return crc.toByte()
    }

    fun crc16(data: ByteArray, offset: Int = 0, length: Int = data.size, init: Int = 0x3692): Int {
        var crc = init
        for (i in offset until offset + length) {
            crc = (crc shr 8) xor CRC16_TABLE[((crc xor data[i].toInt()) and 0xFF)]
        }
        return crc and 0xFFFF
    }

    enum class Variant { WIFI, BLE }

    // MARK: 编码

    /** DUML 帧编码。payload 拷贝进帧体，crc16 追加尾部。 */
    fun encode(
        src: Byte, dst: Byte, seq: Int, ct: Byte,
        cmdSet: Byte, cmdId: Byte, payload: ByteArray = ByteArray(0),
        variant: Variant = Variant.WIFI,
    ): ByteArray {
        // 13 + payload = 含 crc16 的帧总长（与 iOS encodeDUML/buildDUML 完全一致；
        // golden 帧逐字节回环验证：recordStart / recordAck / BLE keepalive 三帧匹配）
        val total = 13 + payload.size
        val out = ByteArray(total)
        out[0] = SOF
        when (variant) {
            Variant.WIFI -> {
                val lenField = (total and 0x3FF) or (1 shl 10)
                out[1] = (lenField and 0xFF).toByte()
                out[2] = ((lenField shr 8) and 0xFF).toByte()
            }
            Variant.BLE -> {
                out[1] = (total and 0xFF).toByte()
                out[2] = (((total shr 8) and 0x03) or (1 shl 2)).toByte()
            }
        }
        out[3] = crc8(out, 0, 3)
        out[4] = src
        out[5] = dst
        out[6] = (seq and 0xFF).toByte()
        out[7] = ((seq shr 8) and 0xFF).toByte()
        out[8] = ct
        out[9] = cmdSet
        out[10] = cmdId
        payload.copyInto(out, 11)
        val crc = crc16(out, 0, total - 2)
        out[total - 2] = (crc and 0xFF).toByte()
        out[total - 1] = ((crc shr 8) and 0xFF).toByte()
        return out
    }

    // MARK: 解析

    /** 解析出的 DUML 帧。 */
    class Frame(
        val sender: Byte,
        val receiver: Byte,
        val sequence: Int,
        val cmdType: Byte,
        val cmdSet: Byte,
        val cmdId: Byte,
        val payload: ByteArray,
    )

    /**
     * 从缓冲区 [offset] 起尝试解析一帧（0x55 帧头 + CRC 校验）。
     * 返回 (帧, 消费长度)；校验失败或长度不足返回 null（调用方按帧头字节跳过重新同步）。
     */
    fun parse(buf: ByteArray, offset: Int = 0): Pair<Frame, Int>? {
        if (offset + 13 > buf.size) return null
        if (buf[offset] != SOF) return null
        val rawLen = (buf[offset + 1].toInt() and 0xFF) or ((buf[offset + 2].toInt() and 0xFF) shl 8)
        val frameLen = rawLen and 0x3FF
        if (frameLen < 13 || offset + frameLen > buf.size) return null
        if (buf[offset + 3] != crc8(buf, offset, 3)) return null
        val expectedCrc16 = crc16(buf, offset, frameLen - 2)
        val actualCrc16 = (buf[offset + frameLen - 2].toInt() and 0xFF) or
            ((buf[offset + frameLen - 1].toInt() and 0xFF) shl 8)
        if (actualCrc16 != expectedCrc16) return null

        val payloadLen = frameLen - 13
        val payload = ByteArray(payloadLen)
        System.arraycopy(buf, offset + 11, payload, 0, payloadLen)
        val frame = Frame(
            sender = buf[offset + 4],
            receiver = buf[offset + 5],
            sequence = (buf[offset + 6].toInt() and 0xFF) or ((buf[offset + 7].toInt() and 0xFF) shl 8),
            cmdType = buf[offset + 8],
            cmdSet = buf[offset + 9],
            cmdId = buf[offset + 10],
            payload = payload,
        )
        return frame to frameLen
    }
}
