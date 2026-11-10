package com.nareshchoudhary.pocketmac.proto

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ThreadFactory
import java.util.concurrent.TimeUnit

/** Shared background threads for networking (daemon: never keep the process alive). */
object NetThreads {
    private fun factory(name: String) = ThreadFactory { r -> Thread(r, name).apply { isDaemon = true } }
    val io = Executors.newCachedThreadPool(factory("pocketmac.net"))
    val scheduler = ScheduledThreadPoolExecutor(1, factory("pocketmac.timer")).apply { removeOnCancelPolicy = true }

    fun closeQuietly(s: Socket?) {
        if (s == null) return
        io.execute { try { s.close() } catch (_: Throwable) {} }
    }
}

/** A way to reach the Mac: a name to look up (Tailscale, IP typed by the user) or an address found nearby. */
class Endpoint private constructor(val host: String?, val address: InetAddress?, val port: Int) {
    val key: String get() = "${address?.hostAddress ?: host}:$port"

    companion object {
        fun host(host: String, port: Int) = Endpoint(host, null, port)
        fun address(address: InetAddress, port: Int) = Endpoint(null, address, port)
    }
}

/**
 * "Happy eyeballs": tries every known path to the Mac at once (nearby address,
 * Tailscale name, typed IP) and keeps whichever connects first.
 */
class ConnectionRacer(timeoutMs: Long, private val completion: (Socket?, Throwable?) -> Unit) {
    private val lock = Any()
    private var done = false
    private var expectingMore = true
    private var pending = 0
    private var lastError: Throwable? = null
    private val sockets = mutableListOf<Socket>()
    private val tried = HashSet<String>()
    private val timeout: ScheduledFuture<*> = NetThreads.scheduler.schedule(Runnable {
        fail(WireException("Couldn't reach the Mac. Is PocketMac Host running, and are both devices online (same Wi-Fi, or Tailscale on both)?"))
    }, timeoutMs, TimeUnit.MILLISECONDS)

    fun add(e: Endpoint) {
        synchronized(lock) {
            if (done || !tried.add(e.key)) return
            pending++
        }
        NetThreads.io.execute {
            val addresses = try {
                e.address?.let { listOf(it) } ?: InetAddress.getAllByName(e.host).toList()
            } catch (t: Throwable) {
                synchronized(lock) { lastError = t }
                emptyList()
            }
            synchronized(lock) { pending += addresses.size }
            addresses.forEach { a -> NetThreads.io.execute { attempt(a, e.port) } }
            finishedOne()
        }
    }

    /** Call when no further endpoints will be added (nearby search gave up). */
    fun noMoreEndpoints() {
        synchronized(lock) { expectingMore = false }
        checkExhausted()
    }

    fun cancel() {
        val open: List<Socket>
        synchronized(lock) {
            done = true
            open = sockets.toList()
            sockets.clear()
        }
        timeout.cancel(false)
        open.forEach(NetThreads::closeQuietly)
    }

    private fun attempt(address: InetAddress, port: Int) {
        val s = Socket()
        synchronized(lock) {
            if (done) {
                pending--
                return
            }
            sockets += s
        }
        try {
            s.tcpNoDelay = true
            s.keepAlive = true
            try { s.trafficClass = 0x88 } catch (_: Throwable) {}   // DSCP AF41: interactive video
            s.connect(InetSocketAddress(address, port), 8000)
            val losers: List<Socket>
            synchronized(lock) {
                sockets.remove(s)
                if (done) {
                    NetThreads.closeQuietly(s)
                    return
                }
                done = true
                losers = sockets.toList()
                sockets.clear()
            }
            timeout.cancel(false)
            losers.forEach(NetThreads::closeQuietly)
            completion(s, null)
        } catch (t: Throwable) {
            NetThreads.closeQuietly(s)
            synchronized(lock) {
                sockets.remove(s)
                lastError = t
            }
            finishedOne()
        }
    }

    private fun finishedOne() {
        synchronized(lock) { pending-- }
        checkExhausted()
    }

    private fun checkExhausted() {
        val err = synchronized(lock) {
            if (done || pending > 0 || expectingMore) return
            lastError ?: WireException("Couldn't find the Mac on this Wi-Fi. Check that PocketMac Host is running, or add the Mac's Tailscale address to connect from another network.")
        }
        fail(err)
    }

    private fun fail(e: Throwable) {
        synchronized(lock) {
            if (done) return
            done = true
            sockets.forEach(NetThreads::closeQuietly)
            sockets.clear()
        }
        timeout.cancel(false)
        completion(null, e)
    }
}

/**
 * Everything the phone needs to log in and talk to the Mac. Callbacks arrive on
 * background threads; [onMessage] on the single reader thread, in order.
 */
class ClientCore(
    private val identity: ByteArray,
    private val macID: String,
    private val deviceName: String,
    /** Video frame buffers come from here; the decoder hands them back. */
    val framePool: ByteArrayPool = ByteArrayPool(),
    private val passwordKey: (salt: ByteArray, iterations: Int) -> ByteArray?,
) {
    sealed interface State {
        data object Connecting : State
        data object Authenticating : State
        data class Connected(val hostName: String) : State
        data class Closed(val error: Throwable?) : State
    }

    @Volatile var onState: ((State) -> Unit)? = null
    @Volatile var onMessage: ((ServerMessage) -> Unit)? = null
    /** After a successful login, with the salt/iterations/key actually used, so the app can cache the key. */
    @Volatile var onAuthenticated: ((ClientHandshake.ServerHelloInfo, ByteArray) -> Unit)? = null

    private val lock = Any()
    private var finished = false
    private var racer: ConnectionRacer? = null
    private var socket: Socket? = null
    private var writer: Writer? = null
    @Volatile private var sendCipher: CipherState? = null

    fun connect(endpoints: List<Endpoint>, moreComing: Boolean = false) {
        onState?.invoke(State.Connecting)
        val r = ConnectionRacer(10_000) { s, e -> if (s != null) connected(s) else finish(e) }
        synchronized(lock) {
            if (finished) return
            racer = r
        }
        endpoints.forEach(r::add)
        if (!moreComing) r.noMoreEndpoints()
    }

    fun addEndpoint(e: Endpoint) = racer?.add(e)
    fun noMoreEndpoints() = racer?.noMoreEndpoints()

    /** Thread-safe; dropped unless logged in. */
    fun send(m: ClientMessage) {
        if (sendCipher == null) return
        writer?.enqueue(m.encode(), encrypt = true)
    }

    fun close() = finish(null)

    private fun connected(s: Socket) {
        val w: Writer
        synchronized(lock) {
            racer = null
            if (finished) {
                NetThreads.closeQuietly(s)
                return
            }
            socket = s
            w = Writer(s)
            writer = w
        }
        w.start()
        Thread({ readLoop(s, w) }, "pocketmac.recv").apply {
            isDaemon = true
            priority = Thread.MAX_PRIORITY - 1
        }.start()
    }

    private fun readLoop(s: Socket, w: Writer) {
        val loginTimeout = NetThreads.scheduler.schedule(Runnable {
            if (sendCipher == null) finish(WireException("Login timed out."))
        }, 15, TimeUnit.SECONDS)
        try {
            s.soTimeout = 15_000
            val input = DataInputStream(BufferedInputStream(s.getInputStream(), 1 shl 16))
            onState?.invoke(State.Authenticating)
            val hs = ClientHandshake(identity, macID, deviceName)
            w.enqueue(hs.hello(), encrypt = false)
            val info = hs.parseServerHello(readPlain(input))
            val pk = passwordKey(info.salt, info.iterations)
                ?: throw HandshakeFailure(HandshakeErrorCode.BAD_CREDENTIALS, 0, "Password needed.")
            val (fin, keys) = hs.finish(pk)
            w.enqueue(fin, encrypt = false)
            hs.verifyServerFinish(readPlain(input), keys)
            val recv = CipherState(keys.serverToClient)
            sendCipher = CipherState(keys.clientToServer)
            loginTimeout.cancel(false)
            onAuthenticated?.invoke(info, pk)
            onState?.invoke(State.Connected(info.hostName))
            // The Mac sends a status every few seconds and answers pings, so silence means the link is gone.
            s.soTimeout = 12_000
            var record = ByteArray(64 * 1024)
            var plain = ByteArray(64 * 1024)
            while (true) {
                val len = input.readInt()
                if (len < 0 || len > MAX_FRAME) throw WireException("frame too large")
                if (record.size < len) record = ByteArray(len + len / 4)
                input.readFully(record, 0, len)
                if (plain.size < len) plain = ByteArray(len + len / 4)
                val n = recv.open(record, 0, len, plain)
                val m = try {
                    ServerMessage.decode(plain, 0, n, framePool)
                } catch (_: WireException) {
                    continue   // unknown message from a newer host
                }
                onMessage?.invoke(m)
            }
        } catch (e: Throwable) {
            loginTimeout.cancel(false)
            finish(if (e is EOFException) WireException("The Mac closed the connection.") else e)
        }
    }

    private fun readPlain(input: DataInputStream): ByteArray {
        val len = input.readInt()
        if (len < 0 || len > 64 * 1024) throw WireException("bad handshake message")
        return ByteArray(len).also { input.readFully(it) }
    }

    private fun finish(e: Throwable?) {
        val cb: ((State) -> Unit)?
        val s: Socket?
        synchronized(lock) {
            if (finished) return
            finished = true
            cb = onState
            s = socket
        }
        onMessage = null   // nothing from this connection after it's closed
        racer?.cancel()
        writer?.shutdown()
        NetThreads.closeQuietly(s)
        cb?.invoke(State.Closed(e))
    }

    /** One thread owns the socket's output and the send cipher, so nonces stay in order. */
    private inner class Writer(s: Socket) : Thread("pocketmac.send") {
        private val queue = LinkedBlockingQueue<Out>()
        private val socketRef = s

        init {
            isDaemon = true
        }

        fun enqueue(data: ByteArray, encrypt: Boolean) {
            queue.offer(Out(data, encrypt))
        }

        fun shutdown() {
            queue.offer(STOP)
        }

        override fun run() {
            try {
                val out = DataOutputStream(BufferedOutputStream(socketRef.getOutputStream(), 1 shl 16))
                while (true) {
                    var item = queue.take()
                    while (true) {
                        if (item === STOP) return
                        val payload = if (item.encrypt) sendCipher!!.seal(item.data) else item.data
                        out.writeInt(payload.size)
                        out.write(payload)
                        item = queue.poll() ?: break
                    }
                    out.flush()   // one write for everything that queued up meanwhile
                }
            } catch (e: Throwable) {
                finish(e)
            }
        }
    }

    private class Out(val data: ByteArray, val encrypt: Boolean)

    companion object {
        const val MAX_FRAME = 16 shl 20
        private val STOP = Out(ByteArray(0), false)
    }
}
