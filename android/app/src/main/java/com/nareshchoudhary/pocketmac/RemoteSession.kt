package com.nareshchoudhary.pocketmac

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.view.WindowManager
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nareshchoudhary.pocketmac.data.ClientSettings
import com.nareshchoudhary.pocketmac.data.MacCredential
import com.nareshchoudhary.pocketmac.data.SavedMac
import com.nareshchoudhary.pocketmac.proto.ByteArrayPool
import com.nareshchoudhary.pocketmac.proto.ClientCore
import com.nareshchoudhary.pocketmac.proto.ClientHandshake
import com.nareshchoudhary.pocketmac.proto.ClientMessage
import com.nareshchoudhary.pocketmac.proto.Endpoint
import com.nareshchoudhary.pocketmac.proto.HandshakeErrorCode
import com.nareshchoudhary.pocketmac.proto.HandshakeFailure
import com.nareshchoudhary.pocketmac.proto.HostStatus
import com.nareshchoudhary.pocketmac.proto.LidDisplayFit
import com.nareshchoudhary.pocketmac.proto.NetThreads
import com.nareshchoudhary.pocketmac.proto.PMCrypto
import com.nareshchoudhary.pocketmac.proto.ServerMessage
import com.nareshchoudhary.pocketmac.proto.StreamQuality
import com.nareshchoudhary.pocketmac.proto.StreamSettings
import com.nareshchoudhary.pocketmac.proto.VideoCodec
import com.nareshchoudhary.pocketmac.proto.WireException
import com.nareshchoudhary.pocketmac.proto.monotonicMicros
import com.nareshchoudhary.pocketmac.remote.KeyMap
import com.nareshchoudhary.pocketmac.remote.ModifierFlag
import com.nareshchoudhary.pocketmac.remote.RemoteView
import com.nareshchoudhary.pocketmac.video.Codecs
import com.nareshchoudhary.pocketmac.video.VideoDecoder
import java.net.ConnectException
import java.net.NoRouteToHostException
import java.net.SocketException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import java.security.GeneralSecurityException
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import kotlin.math.max
import kotlin.math.min

/** One connection to one Mac: login, reconnects, video, input. UI state is Compose state (main thread). */
class RemoteSession(private val app: AppState, initialMac: SavedMac) : VideoDecoder.Listener {
    sealed interface Phase {
        data class Connecting(val text: String) : Phase
        data object Connected : Phase
        data class NeedsPassword(val message: String?) : Phase
        data class Failed(val message: String) : Phase
    }

    var phase by mutableStateOf<Phase>(Phase.Connecting("Connecting…"))
        private set
    var status by mutableStateOf<HostStatus?>(null)
        private set
    var toast by mutableStateOf<String?>(null)
        private set
    var fps by mutableIntStateOf(0)
        private set
    var kbps by mutableIntStateOf(0)
        private set
    var rttMs by mutableIntStateOf(-1)
        private set
    var lastMacClipboard by mutableStateOf<String?>(null)
        private set
    var mac by mutableStateOf(initialMac)
        private set
    var rememberPassword by mutableStateOf(true)
    var toolbarOpen by mutableStateOf(true)
    var zoomed by mutableStateOf(false)
    var keyboardVisible by mutableStateOf(false)

    /** Keyboard-bar modifiers: one-shot (next key only) and locked. */
    var oneShot by mutableIntStateOf(0)
        private set
    var locked by mutableIntStateOf(0)
        private set
    val activeModifiers: Int get() = oneShot or locked

    val settings: ClientSettings get() = app.store.settings
    val isConnected: Boolean get() = phase == Phase.Connected

    /** Main thread. Set while the remote screen is on screen. */
    var view: RemoteView? = null
    @Volatile var videoSize: Pair<Int, Int>? = null
        private set

    private val store = app.store
    private val main = Handler(Looper.getMainLooper())
    private val pool = ByteArrayPool()
    val decoder = VideoDecoder(pool, this)
    @Volatile private var core: ClientCore? = null
    private var credential: MacCredential? = null
    private var password: String? = null
    private var wantsConnection = false
    private var suspended = false
    private var reconnectAttempt = 0
    private var everConnected = false
    private var closed = false
    private val renderedFrames = AtomicInteger()
    private val receivedBytes = AtomicLong()
    private val lastModifierTap = HashMap<Int, Long>()
    private var demo: Thread? = null

    private val statsTick = object : Runnable {
        override fun run() {
            fps = renderedFrames.getAndSet(0)
            kbps = (receivedBytes.getAndSet(0) * 8 / 1000).toInt()
            main.postDelayed(this, 1000)
        }
    }
    private val pingTick = object : Runnable {
        override fun run() {
            send(ClientMessage.Ping(monotonicMicros()))
            main.postDelayed(this, 3000)
        }
    }
    private val hideToast = Runnable { toast = null }

    // MARK: Lifecycle

    /** [password] null → use the saved login (after fingerprint / screen lock) if there is one, else ask. */
    fun start(password: String?) {
        if (!password.isNullOrEmpty()) {
            this.password = password
            connect()
            return
        }
        if (credential != null) {
            connect()
            return
        }
        if (!store.hasCredential(mac.id)) {
            phase = Phase.NeedsPassword(null)
            return
        }
        phase = Phase.Connecting("Unlocking…")
        app.unlock("Unlock your Mac login", mac.name) { ok ->
            if (closed) return@unlock
            val c = if (ok) store.loadCredential(mac.id) else null
            if (c != null) {
                credential = c
                connect()
            } else {
                phase = Phase.NeedsPassword(null)
            }
        }
    }

    fun submitPassword(pw: String) {
        if (pw.isEmpty()) return
        credential = null
        start(pw)
    }

    fun retry() = connect()

    fun disconnect() {
        wantsConnection = false
        stopTimers()
        core?.close()
        core = null
        demo?.interrupt()
        demo = null
    }

    /** Leaving the screen for good: also frees the decoder. */
    fun close() {
        closed = true
        disconnect()
        decoder.release()
    }

    /** App went to the background: tell the Mac (it waits before locking), then close cleanly. */
    fun suspend() {
        if (!wantsConnection || !isConnected || demo != null) return
        suspended = true
        send(ClientMessage.SetPaused(true))
        stopTimers()
        val c = core
        core = null
        main.postDelayed({ c?.close() }, 200)
    }

    fun resume() {
        if (!suspended) return
        suspended = false
        connect(quiet = true)
    }

    private fun connect(quiet: Boolean = false) {
        core?.close()
        wantsConnection = true
        if (!quiet || !everConnected) phase = Phase.Connecting("Connecting to ${mac.name}…")
        decoder.reset()
        videoSize = null

        val cred = credential
        val pw = password
        val c = ClientCore(store.identity, mac.id, store.deviceName, pool) { salt, iterations ->
            if (cred != null && cred.salt.contentEquals(salt) && cred.iterations == iterations) cred.key
            else pw?.let { PMCrypto.passwordKey(it, salt, iterations) }
        }
        core = c
        c.onState = { st -> main.post { if (c === core) handle(st) } }
        c.onAuthenticated = { info, key -> main.post { authenticated(info, key) } }
        c.onMessage = { m -> received(m, c) }

        // Race every path we know: the Mac found on this Wi-Fi, and its internet address (Tailscale).
        val endpoints = mutableListOf<Endpoint>()
        val discovery = app.discovery
        discovery.found[mac.id]?.let { endpoints += Endpoint.address(it.address, it.port) }
        val addr = mac.internetAddress.trim()
        if (addr.isNotEmpty()) endpoints += Endpoint.host(addr, mac.port)
        val waitForNearby = discovery.found[mac.id] == null && app.canUseLocalNetwork()
        c.connect(endpoints, moreComing = waitForNearby)
        if (waitForNearby) {
            app.discovery.start()
            var tries = 0
            val poll = object : Runnable {
                override fun run() {
                    if (c !== core) return
                    tries++
                    val f = discovery.found[mac.id]
                    if (f != null) {
                        c.addEndpoint(Endpoint.address(f.address, f.port))
                        c.noMoreEndpoints()
                    } else if (tries >= 14) {
                        c.noMoreEndpoints()
                    } else {
                        main.postDelayed(this, 250)
                    }
                }
            }
            main.postDelayed(poll, 250)
        }
    }

    private fun handle(st: ClientCore.State) {
        when (st) {
            ClientCore.State.Connecting ->
                if (!everConnected || phase != Phase.Connected) phase = Phase.Connecting("Connecting to ${mac.name}…")
            ClientCore.State.Authenticating ->
                if (phase != Phase.Connected) phase = Phase.Connecting("Logging in…")
            is ClientCore.State.Connected -> {
                phase = Phase.Connected
                everConnected = true
                reconnectAttempt = 0
                send(ClientMessage.StartStream(streamSettings()))
                startTimers()
            }
            is ClientCore.State.Closed -> connectionClosed(st.error)
        }
    }

    private fun connectionClosed(e: Throwable?) {
        stopTimers()
        if (!wantsConnection || suspended) return
        if (e is HandshakeFailure) {
            wantsConnection = false
            if (e.code == HandshakeErrorCode.BAD_CREDENTIALS) {
                if (password == null && credential != null) {
                    credential = null
                    store.deleteCredential(mac.id)
                    phase = Phase.NeedsPassword("The saved login no longer works (password changed?). Enter the Mac password.")
                } else {
                    password = null
                    phase = Phase.NeedsPassword(if (e.serverMessage == "Password needed.") null else "Wrong password. Try again.")
                }
            } else {
                phase = Phase.Failed(e.message)
            }
            return
        }
        // Network drop (Wi-Fi ↔ mobile data, tunnel, Mac asleep…): retry with backoff.
        if (everConnected && reconnectAttempt < 6) {
            reconnectAttempt++
            val delay = min(8000L, 500L shl (reconnectAttempt - 1))
            phase = Phase.Connecting("Connection lost — reconnecting…")
            main.postDelayed({
                if (wantsConnection && !suspended && phase != Phase.Connected) connect(quiet = true)
            }, delay)
        } else {
            wantsConnection = false
            phase = Phase.Failed(friendly(e))
        }
    }

    private fun authenticated(info: ClientHandshake.ServerHelloInfo, key: ByteArray) {
        val c = MacCredential(info.salt, info.iterations, key)
        credential = c
        if (password != null && rememberPassword) {
            val id = mac.id
            NetThreads.io.execute { store.saveCredential(c, id) }
        }
        password = null
        mac = mac.copy(name = info.hostName, lastConnected = System.currentTimeMillis())
        store.upsert(mac)
    }

    // MARK: Messages (network thread)

    private fun received(m: ServerMessage, c: ClientCore) {
        when (m) {
            is ServerMessage.Format -> {
                videoSize = m.format.width to m.format.height
                decoder.handle(m.format)
            }
            is ServerMessage.Frame -> {
                receivedBytes.addAndGet(m.frame.length.toLong())
                decoder.handle(m.frame) { id -> c.send(ClientMessage.FrameAck(id)) }
            }
            is ServerMessage.Status -> main.post { status = m.status }
            is ServerMessage.Clipboard -> main.post {
                lastMacClipboard = m.text
                if (settings.clipboardSync) {
                    app.setClipboard(m.text)
                    if (Build.VERSION.SDK_INT < 33) showToast("Copied from Mac")   // Android 13+ shows its own
                }
            }
            is ServerMessage.Pong -> {
                val ms = ((monotonicMicros() - m.micros) / 1000).toInt()
                main.post { rttMs = ms }
            }
            is ServerMessage.Cursor -> main.post { view?.remoteCursor(m.x, m.y) }
            is ServerMessage.Notice -> main.post { showToast(m.text, 6000) }
        }
    }

    fun send(m: ClientMessage) {
        core?.send(m)
    }

    // MARK: VideoDecoder.Listener (decoder thread)

    override fun onNeedKeyframe() = send(ClientMessage.RequestKeyframe)
    override fun onVideoSize(width: Int, height: Int) {
        main.post { view?.setVideoSize(width, height) }
    }
    override fun onFrameRendered() {
        renderedFrames.incrementAndGet()
    }
    override fun onCodecTrouble(codec: VideoCodec) {
        main.post {
            if (codec == VideoCodec.HEVC && settings.useHEVC) {
                store.update { it.copy(useHEVC = false) }
                showToast("Switched to H.264 — this phone's HEVC decoder had trouble")
                updateStream()
            }
        }
    }

    // MARK: Stream settings

    fun streamSettings(): StreamSettings {
        val s = settings
        val power = app.context.getSystemService(PowerManager::class.java)
        val saver = s.autoSaverOnBatterySaver && power?.isPowerSaveMode == true
        val codec = if (s.useHEVC && Codecs.hasHardwareHevc) VideoCodec.HEVC else VideoCodec.H264
        var quality = if (saver) StreamQuality.SAVER else StreamQuality.of(s.quality)
        // Don't ask for more pixels than this phone's decoder can handle.
        if (quality == StreamQuality.SHARP && !Codecs.supports(codec, 2940, 1912)) quality = StreamQuality.BALANCED
        if (quality == StreamQuality.BALANCED && !Codecs.supports(codec, 1920, 1248)) quality = StreamQuality.SAVER
        val (w, h) = screenPixels()
        return StreamSettings(quality, if (saver) 30 else s.fps, codec, max(w, h), min(w, h), LidDisplayFit.of(s.lidFit))
    }

    private fun screenPixels(): Pair<Int, Int> {
        val wm = app.context.getSystemService(WindowManager::class.java)
        if (Build.VERSION.SDK_INT >= 30 && wm != null) {
            val b = wm.maximumWindowMetrics.bounds
            return b.width() to b.height()
        }
        val dm = app.context.resources.displayMetrics
        return dm.widthPixels to dm.heightPixels
    }

    fun updateStream() {
        if (isConnected) send(ClientMessage.UpdateSettings(streamSettings()))
    }

    // MARK: Keys

    /** Presses modifiers like a real keyboard: ⌘ down, C down, C up, ⌘ up. */
    fun sendCombo(code: Int, flags: Int) {
        val mods = listOf(ModifierFlag.CONTROL to 59, ModifierFlag.OPTION to 58, ModifierFlag.SHIFT to 56, ModifierFlag.COMMAND to 55)
        var held = 0
        for ((flag, key) in mods) if (flags and flag != 0) {
            held = held or flag
            send(ClientMessage.Key(key, true, held))
        }
        send(ClientMessage.Key(code, true, flags))
        send(ClientMessage.Key(code, false, flags))
        for ((flag, key) in mods.reversed()) if (flags and flag != 0) {
            held = held and flag.inv()
            send(ClientMessage.Key(key, false, held))
        }
    }

    fun typed(text: String) {
        val mods = activeModifiers
        val shortcut = mods and (ModifierFlag.COMMAND or ModifierFlag.CONTROL or ModifierFlag.OPTION) != 0
        val single = text.length == 1
        val mapped = if (shortcut && single) KeyMap.code(text[0]) else null
        when {
            text == "\n" || text == "\r" -> sendCombo(KeyMap.RETURN, takeModifiers())
            mapped != null -> sendCombo(mapped.first, takeModifiers() or (if (mapped.second) ModifierFlag.SHIFT else 0))
            else -> {
                if (mods and ModifierFlag.SHIFT != 0) clearOneShot()
                // Newlines inside pasted / multi-character text become Return presses.
                val parts = text.split('\n')
                parts.forEachIndexed { i, part ->
                    if (part.isNotEmpty()) send(ClientMessage.Text(part))
                    if (i < parts.size - 1) sendCombo(KeyMap.RETURN, 0)
                }
            }
        }
    }

    fun takeModifiers(): Int {
        val m = activeModifiers
        clearOneShot()
        return m
    }

    fun clearOneShot() {
        if (oneShot != 0) oneShot = 0
    }

    /** Tap = next key only. Double-tap = locked. Tap again = off. */
    fun tapModifier(flag: Int) {
        val now = System.currentTimeMillis()
        when {
            locked and flag != 0 -> locked = locked and flag.inv()
            oneShot and flag != 0 -> {
                oneShot = oneShot and flag.inv()
                if (now - (lastModifierTap[flag] ?: 0) < 400) locked = locked or flag
            }
            else -> oneShot = oneShot or flag
        }
        lastModifierTap[flag] = now
    }

    // MARK: Clipboard

    fun sendClipboardToMac(andPaste: Boolean) {
        val s = app.clipboardText()
        if (s.isNullOrEmpty()) {
            showToast("Phone clipboard is empty")
            return
        }
        send(ClientMessage.Clipboard(s))
        showToast(if (andPaste) "Pasted on Mac" else "Sent to Mac clipboard")
        if (andPaste) main.postDelayed({ sendCombo(9, ModifierFlag.COMMAND) }, 250)
    }

    fun copyMacClipboard() {
        val t = lastMacClipboard ?: return
        app.setClipboard(t)
        if (Build.VERSION.SDK_INT < 33) showToast("Copied to phone")
    }

    fun showToast(s: String, millis: Long = 2200) {
        toast = s
        main.removeCallbacks(hideToast)
        main.postDelayed(hideToast, millis)
    }

    // MARK: Timers

    private fun startTimers() {
        stopTimers()
        main.postDelayed(statsTick, 1000)
        pingTick.run()
    }

    private fun stopTimers() {
        main.removeCallbacks(statsTick)
        main.removeCallbacks(pingTick)
    }

    private fun friendly(e: Throwable?): String {
        val unreachable = "Couldn't reach the Mac. Check that it's awake, and that both devices are on the same Wi-Fi or both have Tailscale on." +
            if (!app.canUseLocalNetwork()) "\n\nAlso allow PocketMac to find devices on your local network (tap Allow on the home screen)." else ""
        return when (e) {
            null -> "Disconnected."
            is HandshakeFailure -> e.message
            is WireException -> e.message ?: "Connection error."
            is UnknownHostException -> "Couldn't find that internet address. Check the Tailscale name or IP."
            is ConnectException -> if (e.message.orEmpty().contains("ECONNREFUSED")) "The Mac refused the connection. Is PocketMac Host running on it?" else unreachable
            is SocketTimeoutException, is NoRouteToHostException -> unreachable
            is SocketException -> if (e.message.orEmpty().contains("reset", true)) "The connection was reset." else unreachable
            is GeneralSecurityException -> "The connection was corrupted or tampered with, so it was closed."
            else -> e.message ?: e.javaClass.simpleName
        }
    }

    // MARK: Demo (used by the UI tests to show recorded video without a Mac)

    fun startDemo(messages: List<ByteArray>) {
        disconnect()
        phase = Phase.Connected
        status = HostStatus(hostName = mac.name, battery = 82, charging = true, screenPermission = true, accessibilityPermission = true)
        rttMs = 4
        startTimers()
        demo = Thread({
            try {
                while (!Thread.currentThread().isInterrupted) {
                    for (raw in messages) {
                        when (val m = ServerMessage.decode(raw)) {
                            is ServerMessage.Format -> {
                                videoSize = m.format.width to m.format.height
                                decoder.handle(m.format)
                            }
                            is ServerMessage.Frame -> {
                                receivedBytes.addAndGet(m.frame.length.toLong())
                                decoder.handle(m.frame) {}
                                Thread.sleep(33)
                            }
                            else -> {}
                        }
                    }
                }
            } catch (_: InterruptedException) {
            }
        }, "pocketmac.demo").apply { isDaemon = true; start() }
    }
}
