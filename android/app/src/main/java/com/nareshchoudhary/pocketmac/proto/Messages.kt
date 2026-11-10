package com.nareshchoudhary.pocketmac.proto

const val POCKETMAC_PORT = 47800
const val POCKETMAC_SERVICE_TYPE = "_pocketmac._tcp"

enum class VideoCodec(val raw: Int, val mime: String) {
    H264(1, "video/avc"), HEVC(2, "video/hevc");

    companion object {
        fun of(raw: Int) = entries.firstOrNull { it.raw == raw }
    }
}

enum class StreamQuality(val raw: Int, val maxWidth: Int, val maxBitrate: Int, val label: String) {
    SAVER(0, 1280, 3_000_000, "Battery saver"),
    BALANCED(1, 1920, 8_000_000, "Balanced"),
    SHARP(2, 2940, 16_000_000, "Sharp");

    companion object {
        fun of(raw: Int) = entries.firstOrNull { it.raw == raw } ?: BALANCED
    }
}

/** Shape of the virtual screen the Mac creates when its lid is closed. */
enum class LidDisplayFit(val raw: Int, val label: String) {
    PHONE(0, "Fit phone (big text)"),
    PHONE_ROOMY(1, "Fit phone (more space)"),
    LAPTOP(2, "Laptop size");

    companion object {
        fun of(raw: Int) = entries.firstOrNull { it.raw == raw } ?: PHONE
    }
}

data class StreamSettings(
    val quality: StreamQuality = StreamQuality.BALANCED,
    val maxFPS: Int = 30,
    val codec: VideoCodec = VideoCodec.HEVC,
    val clientPixelWidth: Int = 2532,
    val clientPixelHeight: Int = 1170,
    val lidFit: LidDisplayFit = LidDisplayFit.PHONE,
) {
    fun encode(w: WireWriter) {
        w.u8(quality.raw); w.u8(maxFPS); w.u8(codec.raw)
        w.u16(clientPixelWidth.coerceIn(0, 0xFFFF)); w.u16(clientPixelHeight.coerceIn(0, 0xFFFF)); w.u8(lidFit.raw)
    }
}

enum class QuickAction(val raw: Int) {
    LOCK_SCREEN(1), SLEEP_DISPLAY(2), MISSION_CONTROL(3), SPOTLIGHT(4), APP_SWITCHER(5), SHOW_DESKTOP(6),
    VOLUME_UP(7), VOLUME_DOWN(8), MUTE(9), PLAY_PAUSE(10), NEXT_TRACK(11), PREVIOUS_TRACK(12),
    SCREENSHOT(13), FORCE_QUIT(14), LID_MODE_ON(15), LID_MODE_OFF(16), SLEEP_MAC(17), WAKE_DISPLAY(18),
}

class VideoFormat(val codec: VideoCodec, val width: Int, val height: Int, val parameterSets: List<ByteArray>) {
    override fun equals(other: Any?): Boolean =
        other is VideoFormat && codec == other.codec && width == other.width && height == other.height &&
            parameterSets.size == other.parameterSets.size &&
            parameterSets.indices.all { parameterSets[it].contentEquals(other.parameterSets[it]) }

    override fun hashCode(): Int = (codec.hashCode() * 31 + width) * 31 + height
}

/** [data] holds [length] bytes of AVCC/HVCC (4-byte length-prefixed NAL units); it may be a pooled buffer. */
class VideoFrame(val frameID: Long, val keyframe: Boolean, val captureMicros: Long, val data: ByteArray, val length: Int)

data class HostStatus(
    val hostName: String = "",
    val battery: Int = -1,
    val charging: Boolean = false,
    val onAC: Boolean = false,
    val lidClosed: Boolean = false,
    val lidMode: Boolean = false,
    val lidHelperInstalled: Boolean = false,
    val screenPermission: Boolean = false,
    val accessibilityPermission: Boolean = false,
    val virtualDisplay: Boolean = false,
)

// MARK: - phone → Mac

sealed class ClientMessage {
    data class StartStream(val settings: StreamSettings) : ClientMessage()
    data class UpdateSettings(val settings: StreamSettings) : ClientMessage()
    data class FrameAck(val frameID: Long) : ClientMessage()
    data object RequestKeyframe : ClientMessage()
    data class SetPaused(val paused: Boolean) : ClientMessage()
    data class MouseMove(val x: Float, val y: Float) : ClientMessage()
    data class MouseButton(val button: Int, val down: Boolean, val x: Float, val y: Float, val clicks: Int, val flags: Int) : ClientMessage()
    data class Scroll(val dx: Float, val dy: Float) : ClientMessage()
    data class Key(val code: Int, val down: Boolean, val flags: Int) : ClientMessage()
    data class Text(val text: String) : ClientMessage()
    data class Action(val action: QuickAction) : ClientMessage()
    data class Clipboard(val text: String) : ClientMessage()
    data class Ping(val micros: Long) : ClientMessage()

    fun encode(): ByteArray {
        val w = WireWriter(32)
        when (this) {
            is StartStream -> { w.u8(0x20); settings.encode(w) }
            is UpdateSettings -> { w.u8(0x21); settings.encode(w) }
            is FrameAck -> { w.u8(0x22); w.u32(frameID) }
            RequestKeyframe -> w.u8(0x23)
            is SetPaused -> { w.u8(0x24); w.bool(paused) }
            is MouseMove -> { w.u8(0x30); w.f32(x); w.f32(y) }
            is MouseButton -> {
                w.u8(0x31); w.u8(button); w.bool(down); w.f32(x); w.f32(y); w.u8(clicks); w.u32(flags.toLong() and 0xFFFFFFFFL)
            }
            is Scroll -> { w.u8(0x32); w.f32(dx); w.f32(dy) }
            is Key -> { w.u8(0x33); w.u16(code); w.bool(down); w.u32(flags.toLong() and 0xFFFFFFFFL) }
            is Text -> { w.u8(0x34); w.longString(text) }
            is Action -> { w.u8(0x35); w.u8(action.raw) }
            is Clipboard -> { w.u8(0x36); w.longString(text) }
            is Ping -> { w.u8(0x37); w.u64(micros) }
        }
        return w.bytes()
    }
}

// MARK: - Mac → phone

sealed class ServerMessage {
    class Format(val format: VideoFormat) : ServerMessage()
    class Frame(val frame: VideoFrame) : ServerMessage()
    data class Status(val status: HostStatus) : ServerMessage()
    data class Clipboard(val text: String) : ServerMessage()
    data class Pong(val micros: Long) : ServerMessage()
    data class Cursor(val x: Float, val y: Float) : ServerMessage()
    data class Notice(val text: String) : ServerMessage()

    companion object {
        /** Video frame payloads go into buffers from [pool] when given (fewer big allocations). */
        fun decode(buf: ByteArray, off: Int = 0, len: Int = buf.size - off, pool: ByteArrayPool? = null): ServerMessage {
            val r = WireReader(buf, off, off + len)
            return when (val t = r.u8()) {
                0x10 -> {
                    val codec = VideoCodec.of(r.u8()) ?: throw WireException("bad codec")
                    val w = r.u16()
                    val h = r.u16()
                    val n = r.u8()
                    Format(VideoFormat(codec, w, h, List(n) { r.blob16() }))
                }
                0x11 -> {
                    val id = r.u32()
                    val key = r.bool()
                    val time = r.u64()
                    val n = r.remaining
                    val data = pool?.obtain(n) ?: ByteArray(n)
                    System.arraycopy(buf, r.position, data, 0, n)
                    Frame(VideoFrame(id, key, time, data, n))
                }
                0x12 -> {
                    val name = r.string()
                    val battery = r.i8()
                    val f = r.u16()
                    fun bit(i: Int) = f and (1 shl i) != 0
                    Status(HostStatus(name, battery, bit(0), bit(1), bit(2), bit(3), bit(4), bit(5), bit(6), bit(7)))
                }
                0x13 -> Clipboard(r.longString())
                0x14 -> Pong(r.u64())
                0x15 -> Cursor(r.f32(), r.f32())
                0x16 -> Notice(r.string())
                else -> throw WireException("unknown server message $t")
            }
        }
    }
}

/** Reuses the large byte arrays that carry video frames, so streaming doesn't churn the GC. */
class ByteArrayPool(private val maxItems: Int = 16) {
    private val items = ArrayDeque<ByteArray>()

    @Synchronized
    fun obtain(min: Int): ByteArray {
        val it = items.iterator()
        while (it.hasNext()) {
            val a = it.next()
            if (a.size >= min) {
                it.remove()
                return a
            }
        }
        // Round up so a slightly bigger frame next time still fits.
        return ByteArray(((maxOf(min, 32 * 1024) + 16383) / 16384) * 16384)
    }

    @Synchronized
    fun recycle(a: ByteArray) {
        if (items.size < maxItems) items.addLast(a)
    }
}

/** Monotonic microseconds (only used for round-trip times on this side). */
fun monotonicMicros(): Long = System.nanoTime() / 1000
