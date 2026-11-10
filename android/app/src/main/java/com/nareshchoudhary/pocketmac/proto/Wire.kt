package com.nareshchoudhary.pocketmac.proto

/** Malformed or truncated protocol data. */
class WireException(message: String) : Exception(message)

/** Tiny big-endian binary writer used for every PocketMac message (same layout as Shared/Wire.swift). */
class WireWriter(capacity: Int = 64) {
    private var buf = ByteArray(capacity)
    var size = 0
        private set

    private fun ensure(n: Int) {
        if (size + n > buf.size) buf = buf.copyOf(maxOf(buf.size * 2, size + n))
    }

    fun u8(v: Int) {
        ensure(1)
        buf[size++] = v.toByte()
    }

    fun bool(v: Boolean) = u8(if (v) 1 else 0)

    fun u16(v: Int) {
        ensure(2)
        buf[size++] = (v ushr 8).toByte()
        buf[size++] = v.toByte()
    }

    fun u32(v: Long) {
        ensure(4)
        buf[size++] = (v ushr 24).toByte()
        buf[size++] = (v ushr 16).toByte()
        buf[size++] = (v ushr 8).toByte()
        buf[size++] = v.toByte()
    }

    fun u64(v: Long) {
        ensure(8)
        for (i in 7 downTo 0) buf[size++] = (v ushr (i * 8)).toByte()
    }

    fun f32(v: Float) = u32(java.lang.Float.floatToRawIntBits(v).toLong() and 0xFFFFFFFFL)

    fun raw(d: ByteArray, off: Int = 0, len: Int = d.size) {
        ensure(len)
        System.arraycopy(d, off, buf, size, len)
        size += len
    }

    fun blob16(d: ByteArray) {
        val n = minOf(d.size, 0xFFFF)
        u16(n)
        raw(d, 0, n)
    }

    fun blob32(d: ByteArray) {
        u32(d.size.toLong())
        raw(d)
    }

    fun string(s: String) = blob16(s.toByteArray(Charsets.UTF_8))
    fun longString(s: String) = blob32(s.toByteArray(Charsets.UTF_8))

    fun bytes(): ByteArray = buf.copyOf(size)
}

/** Matching reader. Throws [WireException] on truncated input instead of crashing. */
class WireReader(private val data: ByteArray, private var pos: Int = 0, private val end: Int = data.size) {
    val remaining: Int get() = end - pos
    val position: Int get() = pos

    private fun need(n: Int) {
        if (n < 0 || remaining < n) throw WireException("truncated message")
    }

    fun take(n: Int): ByteArray {
        need(n)
        val d = data.copyOfRange(pos, pos + n)
        pos += n
        return d
    }

    fun rest(): ByteArray = take(remaining)

    fun skip(n: Int) {
        need(n)
        pos += n
    }

    fun u8(): Int {
        need(1)
        return data[pos++].toInt() and 0xFF
    }

    fun bool(): Boolean = u8() != 0
    fun i8(): Int = u8().toByte().toInt()

    fun u16(): Int {
        need(2)
        val v = ((data[pos].toInt() and 0xFF) shl 8) or (data[pos + 1].toInt() and 0xFF)
        pos += 2
        return v
    }

    fun u32(): Long {
        need(4)
        var v = 0L
        repeat(4) { v = (v shl 8) or (data[pos++].toLong() and 0xFF) }
        return v
    }

    fun u64(): Long {
        need(8)
        var v = 0L
        repeat(8) { v = (v shl 8) or (data[pos++].toLong() and 0xFF) }
        return v
    }

    fun f32(): Float = java.lang.Float.intBitsToFloat(u32().toInt())
    fun blob16(): ByteArray = take(u16())

    fun blob32(): ByteArray {
        val n = u32()
        if (n > remaining) throw WireException("truncated message")
        return take(n.toInt())
    }

    fun string(): String = String(blob16(), Charsets.UTF_8)
    fun longString(): String = String(blob32(), Charsets.UTF_8)
}
