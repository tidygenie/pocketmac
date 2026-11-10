package com.nareshchoudhary.pocketmac

import android.content.pm.ActivityInfo
import android.graphics.Bitmap
import android.graphics.ImageFormat
import android.media.ImageReader
import android.os.Handler
import android.os.HandlerThread
import android.os.SystemClock
import android.util.Log
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.nareshchoudhary.pocketmac.data.SavedMac
import com.nareshchoudhary.pocketmac.proto.ByteArrayPool
import com.nareshchoudhary.pocketmac.proto.ServerMessage
import com.nareshchoudhary.pocketmac.proto.VideoCodec
import com.nareshchoudhary.pocketmac.video.VideoDecoder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Recorded Mac streams (tools/make-vectors.sh): length-prefixed, decrypted server messages. */
fun recordedStream(name: String): List<ByteArray> {
    val bytes = InstrumentationRegistry.getInstrumentation().context.assets.open(name).use { it.readBytes() }
    val out = mutableListOf<ByteArray>()
    var i = 0
    while (i + 4 <= bytes.size) {
        val n = ((bytes[i].toInt() and 0xFF) shl 24) or ((bytes[i + 1].toInt() and 0xFF) shl 16) or
            ((bytes[i + 2].toInt() and 0xFF) shl 8) or (bytes[i + 3].toInt() and 0xFF)
        out += bytes.copyOfRange(i + 4, i + 4 + n)
        i += 4 + n
    }
    return out
}

/** Real video from the Mac host goes through the app's decoder onto a surface. */
@RunWith(AndroidJUnit4::class)
class DecoderTest {
    private fun decode(name: String) {
        val messages = recordedStream(name).map { ServerMessage.decode(it) }
        val format = messages.filterIsInstance<ServerMessage.Format>().first().format
        val frames = messages.filterIsInstance<ServerMessage.Frame>()
        val readerThread = HandlerThread("reader").apply { start() }
        val reader = ImageReader.newInstance(format.width, format.height, ImageFormat.YUV_420_888, 4)
        val images = AtomicInteger()
        reader.setOnImageAvailableListener({ r ->
            r.acquireLatestImage()?.close()
            images.incrementAndGet()
        }, Handler(readerThread.looper))

        val rendered = AtomicInteger()
        val trouble = AtomicBoolean()
        val decoder = VideoDecoder(ByteArrayPool(), object : VideoDecoder.Listener {
            override fun onNeedKeyframe() {}
            override fun onVideoSize(width: Int, height: Int) {}
            override fun onFrameRendered() {
                rendered.incrementAndGet()
            }
            override fun onCodecTrouble(codec: VideoCodec) = trouble.set(true)
        })
        decoder.setSurface(reader.surface)
        val acks = AtomicInteger()
        for (m in messages) {
            when (m) {
                is ServerMessage.Format -> decoder.handle(m.format)
                is ServerMessage.Frame -> {
                    decoder.handle(m.frame) { acks.incrementAndGet() }
                    Thread.sleep(20)
                }
                else -> {}
            }
        }
        val deadline = SystemClock.uptimeMillis() + 5000
        while (SystemClock.uptimeMillis() < deadline && (acks.get() < frames.size || rendered.get() < frames.size)) Thread.sleep(50)
        Log.i("PocketMacTest", "$name: ${format.codec} ${format.width}x${format.height} frames=${frames.size} acked=${acks.get()} rendered=${rendered.get()} images=${images.get()}")
        decoder.setSurface(null)
        decoder.release()
        reader.close()
        readerThread.quitSafely()

        assertEquals("every frame acknowledged (Mac flow control)", frames.size, acks.get())
        assertFalse("decoder reported trouble", trouble.get())
        assertTrue("decoded frames reached the screen: ${rendered.get()} of ${frames.size}", rendered.get() >= frames.size - 2)
    }

    @Test fun hevcStreamFromMacDecodes() = decode("stream-hevc.bin")
    @Test fun h264StreamFromMacDecodes() = decode("stream-h264.bin")
}

/** Screenshots of every screen (uploaded by CI) so the layout can be checked without a phone. */
@RunWith(AndroidJUnit4::class)
class ScreenshotTest {
    private val inst = InstrumentationRegistry.getInstrumentation()
    private val app get() = (inst.targetContext.applicationContext as PocketMacApplication).state

    private fun shot(name: String) {
        SystemClock.sleep(2000)   // CI emulators render slowly
        inst.waitForIdleSync()
        val bmp = inst.uiAutomation.takeScreenshot() ?: return
        val dir = File(inst.targetContext.filesDir, "screens").apply { mkdirs() }
        File(dir, "$name.png").outputStream().use { bmp.compress(Bitmap.CompressFormat.PNG, 100, it) }
    }

    @Test fun everyScreen() {
        val mac = SavedMac("K7QM4XPA9TZC", "Naresh's MacBook Air", "naresh-macbook-air",
            lastConnected = System.currentTimeMillis() - 3_600_000)
        inst.runOnMainSync { app.store.upsert(mac) }
        ActivityScenario.launch(MainActivity::class.java).use { scenario ->
            shot("1-home")
            inst.runOnMainSync { app.addForm = AddMacForm() }
            shot("2-add-mac")
            inst.runOnMainSync { app.addForm = null; app.showSettings = true }
            shot("3-settings")
            inst.runOnMainSync { app.showSettings = false }

            scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_LANDSCAPE }
            SystemClock.sleep(1500)
            val stream = recordedStream("stream-hevc.bin")
            inst.runOnMainSync { app.startDemo(mac, stream) }
            SystemClock.sleep(3000)
            shot("4-remote")
            val fps = app.session?.fps ?: 0
            Log.i("PocketMacTest", "remote screen fps=$fps")

            inst.runOnMainSync { app.session?.view?.setKeyboard(true) }
            SystemClock.sleep(5000)   // the emulator's keyboard takes a few seconds to appear the first time
            shot("5-keyboard")
            inst.runOnMainSync { app.session?.view?.setKeyboard(false); app.session?.toolbarOpen = false }
            shot("6-toolbar-hidden")

            scenario.onActivity { it.requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_PORTRAIT }
            inst.runOnMainSync { app.session?.toolbarOpen = true }
            SystemClock.sleep(1500)
            shot("7-remote-portrait")
            inst.runOnMainSync { app.closeSession() }
            assertTrue("video plays on the remote screen (fps=$fps)", fps > 0)
        }
    }
}
