package com.nareshchoudhary.pocketmac.video

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Process
import android.os.SystemClock
import android.view.Surface
import com.nareshchoudhary.pocketmac.proto.ByteArrayPool
import com.nareshchoudhary.pocketmac.proto.VideoCodec
import com.nareshchoudhary.pocketmac.proto.VideoFormat
import com.nareshchoudhary.pocketmac.proto.VideoFrame
import java.nio.ByteBuffer
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/** What this phone's decoders can do, checked once. */
object Codecs {
    private val infos: List<MediaCodecInfo> by lazy {
        runCatching { MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder } }.getOrDefault(emptyList())
    }

    fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) info.isHardwareAccelerated
        else !info.name.startsWith("OMX.google.", true) && !info.name.startsWith("c2.android.", true)

    fun decoders(mime: String): List<MediaCodecInfo> =
        infos.filter { info -> info.supportedTypes.any { it.equals(mime, ignoreCase = true) } }
            .sortedBy { if (isHardware(it)) 0 else 1 }

    /** Hardware HEVC gives sharper text for the same data; fall back to H.264 without it. */
    val hasHardwareHevc: Boolean by lazy { decoders(VideoCodec.HEVC.mime).any(::isHardware) }

    fun supports(codec: VideoCodec, width: Int, height: Int): Boolean = decoders(codec.mime).any { info ->
        runCatching { info.getCapabilitiesForType(codec.mime).videoCapabilities.isSizeSupported(width, height) }.getOrDefault(false)
    }
}

/**
 * Hardware decode straight onto the screen's Surface: the picture never touches
 * the CPU, which keeps the phone cool and the battery happy. All state lives on
 * one thread; MediaCodec's callbacks arrive on that same thread.
 */
class VideoDecoder(private val pool: ByteArrayPool, private val listener: Listener) {
    interface Listener {
        fun onNeedKeyframe()
        fun onVideoSize(width: Int, height: Int)
        fun onFrameRendered()
        /** The decoder keeps failing with this codec (e.g. a weak HEVC decoder): try the other one. */
        fun onCodecTrouble(codec: VideoCodec)
    }

    private class Pending(val frame: VideoFrame, val ack: (Long) -> Unit)

    private val thread = HandlerThread("pocketmac.decode", Process.THREAD_PRIORITY_DISPLAY).apply { start() }
    private val handler = Handler(thread.looper)

    private var codec: MediaCodec? = null
    private var format: VideoFormat? = null
    private var surface: Surface? = null
    private val pending = ArrayDeque<Pending>()
    private val freeInputs = ArrayDeque<Int>()
    private var waitingForKeyframe = true
    private var lastKeyRequest = 0L
    private var pendingSince = 0L
    private var minInputSize = 0
    private var failures = 0
    private var firstFailure = 0L
    private var tuned = true

    fun setSurface(s: Surface?) {
        // Release synchronously when the surface goes away, so the codec never draws into a dead one.
        val done = CountDownLatch(1)
        val posted = handler.post {
            if (s !== surface) {
                surface = s
                releaseCodec()
                if (s != null) start()
            }
            done.countDown()
        }
        if (posted && s == null) done.await(1, TimeUnit.SECONDS)
    }

    fun handle(f: VideoFormat) = handler.post {
        if (f == format && codec != null) return@post
        val sizeChanged = format?.let { it.width != f.width || it.height != f.height } ?: true
        format = f
        if (sizeChanged) listener.onVideoSize(f.width, f.height)
        releaseCodec()
        start()
    }

    /** [ack] is called once the frame is in the decoder (or dropped) — the Mac's flow control. */
    fun handle(frame: VideoFrame, ack: (Long) -> Unit) = handler.post { enqueue(Pending(frame, ack)) }

    fun reset() = handler.post {
        format = null
        releaseCodec()
    }

    fun release() = handler.post {
        releaseCodec()
        thread.quitSafely()
    }

    // MARK: - decoder thread

    private fun enqueue(p: Pending) {
        if (codec == null) {
            drop(p)
            if (format != null && surface != null) askKeyframe()
            return
        }
        if (waitingForKeyframe && !p.frame.keyframe) {
            drop(p)
            askKeyframe()
            return
        }
        waitingForKeyframe = false
        if (pending.isEmpty()) pendingSince = SystemClock.uptimeMillis()
        pending.addLast(p)
        feed()
        // No input buffer for a long time: the decoder is stuck. Start over from a keyframe.
        if (pending.isNotEmpty() && SystemClock.uptimeMillis() - pendingSince > 1500) restart()
    }

    private fun feed() {
        val c = codec ?: return
        while (pending.isNotEmpty() && freeInputs.isNotEmpty()) {
            val index = freeInputs.removeFirst()
            val p = pending.removeFirst()
            val f = p.frame
            try {
                val buf: ByteBuffer = c.getInputBuffer(index) ?: throw IllegalStateException("no input buffer")
                if (f.length > buf.capacity()) {
                    // A keyframe bigger than the decoder's buffers: recreate with room for it.
                    minInputSize = f.length * 2
                    drop(p)
                    restart()
                    return
                }
                toAnnexB(f.data, f.length)
                buf.clear()
                buf.put(f.data, 0, f.length)
                c.queueInputBuffer(index, 0, f.length, f.captureMicros, if (f.keyframe) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0)
                drop(p)
                pendingSince = SystemClock.uptimeMillis()
            } catch (e: Exception) {
                drop(p)
                trouble()
                return
            }
        }
    }

    private fun drop(p: Pending) {
        p.ack(p.frame.frameID)
        pool.recycle(p.frame.data)
    }

    private fun askKeyframe() {
        val now = SystemClock.uptimeMillis()
        if (now - lastKeyRequest < 500) return
        lastKeyRequest = now
        listener.onNeedKeyframe()
    }

    private fun restart() {
        releaseCodec()
        start()
    }

    private fun trouble() {
        val now = SystemClock.uptimeMillis()
        if (now - firstFailure > 10_000) {
            firstFailure = now
            failures = 0
        }
        failures++
        if (failures == 2) tuned = false   // maybe a vendor low-latency option the decoder dislikes
        if (failures >= 4) format?.let { listener.onCodecTrouble(it.codec) }
        restart()
    }

    private fun start() {
        waitingForKeyframe = true
        val f = format ?: return
        val s = surface ?: return
        if (!s.isValid) return
        val c = try {
            create(f, s, tuned)
        } catch (e: Exception) {
            runCatching { create(f, s, tune = false) }.getOrNull()
        }
        if (c == null) {
            listener.onCodecTrouble(f.codec)
            return
        }
        codec = c
        askKeyframe()
    }

    private fun create(f: VideoFormat, s: Surface, tune: Boolean): MediaCodec {
        val mime = f.codec.mime
        val mf = MediaFormat.createVideoFormat(mime, f.width, f.height)
        val start = byteArrayOf(0, 0, 0, 1)
        if (f.codec == VideoCodec.HEVC) {
            mf.setByteBuffer("csd-0", ByteBuffer.wrap(f.parameterSets.fold(ByteArray(0)) { acc, ps -> acc + start + ps }))
        } else {
            f.parameterSets.firstOrNull()?.let { mf.setByteBuffer("csd-0", ByteBuffer.wrap(start + it)) }
            if (f.parameterSets.size > 1) {
                mf.setByteBuffer("csd-1", ByteBuffer.wrap(f.parameterSets.drop(1).fold(ByteArray(0)) { acc, ps -> acc + start + ps }))
            }
        }
        mf.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, maxOf(minInputSize, f.width * f.height / 2, 1 shl 20))
        val info = Codecs.decoders(mime).firstOrNull { info ->
            runCatching { info.getCapabilitiesForType(mime).videoCapabilities.isSizeSupported(f.width, f.height) }.getOrDefault(false)
        }
        val c = if (info != null) MediaCodec.createByCodecName(info.name) else MediaCodec.createDecoderByType(mime)
        try {
            if (tune) lowLatency(mf, c.name, runCatching { c.codecInfo.getCapabilitiesForType(mime) }.getOrNull())
            c.setCallback(Callback(), handler)
            c.configure(mf, s, null, 0)
            c.start()
        } catch (e: Exception) {
            runCatching { c.release() }
            throw e
        }
        freeInputs.clear()
        return c
    }

    /** Ask the decoder to hand out each frame as soon as it's decoded instead of buffering a few. */
    private fun lowLatency(mf: MediaFormat, name: String, caps: MediaCodecInfo.CodecCapabilities?) {
        mf.setInteger(MediaFormat.KEY_PRIORITY, 0)   // real-time
        if (Build.VERSION.SDK_INT >= 30 && caps?.isFeatureSupported(MediaCodecInfo.CodecCapabilities.FEATURE_LowLatency) == true) {
            mf.setInteger(MediaFormat.KEY_LOW_LATENCY, 1)
        }
        val n = name.lowercase()
        when {
            n.startsWith("c2.qti") || n.startsWith("omx.qcom") -> {
                mf.setInteger("vendor.qti-ext-dec-low-latency.enable", 1)
                mf.setInteger("vendor.qti-ext-dec-picture-order.enable", 1)
            }
            n.startsWith("c2.exynos") || n.startsWith("omx.exynos") -> mf.setInteger("vendor.rtc-ext-dec-low-latency.enable", 1)
        }
    }

    private fun releaseCodec() {
        codec?.let { c ->
            runCatching { c.stop() }
            runCatching { c.release() }
        }
        codec = null
        freeInputs.clear()
        while (pending.isNotEmpty()) drop(pending.removeFirst())
    }

    private inner class Callback : MediaCodec.Callback() {
        override fun onInputBufferAvailable(c: MediaCodec, index: Int) {
            if (c !== codec) return
            freeInputs.addLast(index)
            feed()
        }

        override fun onOutputBufferAvailable(c: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
            if (c !== codec) return
            try {
                // "Now": shown at the next screen refresh, never held back.
                c.releaseOutputBuffer(index, System.nanoTime())
                if (info.size > 0) listener.onFrameRendered()
            } catch (_: IllegalStateException) {
            }
        }

        override fun onError(c: MediaCodec, e: MediaCodec.CodecException) {
            if (c === codec) trouble()
        }

        override fun onOutputFormatChanged(c: MediaCodec, format: MediaFormat) {}
    }

    companion object {
        /** AVCC/HVCC (4-byte length prefixes) → Annex-B start codes, in place: same size, no copy. */
        fun toAnnexB(data: ByteArray, length: Int) {
            var i = 0
            while (i + 4 <= length) {
                val n = ((data[i].toInt() and 0xFF) shl 24) or ((data[i + 1].toInt() and 0xFF) shl 16) or
                    ((data[i + 2].toInt() and 0xFF) shl 8) or (data[i + 3].toInt() and 0xFF)
                data[i] = 0; data[i + 1] = 0; data[i + 2] = 0; data[i + 3] = 1
                if (n <= 0) break
                i += 4 + n
            }
        }
    }
}
