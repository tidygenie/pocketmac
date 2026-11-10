package com.nareshchoudhary.pocketmac.proto

/*
 PocketMac handshake (v1), identical to Shared/Handshake.swift:

   phone                                    Mac
   ClientHello  e_c, s_c, name   ───────▶
                                 ◀───────   ServerHello  e_s, s_s, salt, iterations
   (check ID == fingerprint(s_s))
   ClientFinish HMAC(kc, th)     ───────▶   (check password-bound MAC, pinned s_c)
                                 ◀───────   ServerFinish HMAC(ks, th)

   th   = SHA256(ClientHello ‖ ServerHello)
   keys = HKDF(DH(e_c,e_s) ‖ DH(e_c,s_s) ‖ DH(s_c,e_s) ‖ PBKDF2(password), salt: th)
*/

enum class HandshakeErrorCode(val raw: Int, val userMessage: String) {
    BAD_CREDENTIALS(1, "Wrong password."),
    NOT_AUTHORIZED(2, "This phone isn't paired yet. On the Mac, open PocketMac Host and click “Pair another phone”, then try again."),
    LOCKED_OUT(3, "Too many wrong attempts. Try again later."),
    BAD_VERSION(4, "App and Mac host versions don't match. Update both."),
    NOT_CONFIGURED(5, "The Mac host has no password yet. Set one in PocketMac Host on the Mac."),
    PROTOCOL_ERROR(6, "Connection error during login.");

    companion object {
        fun of(raw: Int) = entries.firstOrNull { it.raw == raw } ?: PROTOCOL_ERROR
    }
}

class HandshakeFailure(val code: HandshakeErrorCode, val retryAfter: Long = 0, val serverMessage: String = "") : Exception() {
    override val message: String
        get() = when {
            code == HandshakeErrorCode.LOCKED_OUT && retryAfter > 0 -> "Too many wrong attempts. Try again in $retryAfter s."
            serverMessage.isEmpty() -> code.userMessage
            else -> serverMessage
        }
}

class SessionKeys(
    val clientToServer: ByteArray,
    val serverToClient: ByteArray,
    val confirmClient: ByteArray,
    val confirmServer: ByteArray,
)

object Handshake {
    const val VERSION = 1
    const val MAX_NAME_LENGTH = 64
    private val MAGIC = "PKM".toByteArray()
    private val INFO = "PocketMac v1 session".toByteArray()

    const val CLIENT_HELLO = 0x01
    const val SERVER_HELLO = 0x02
    const val CLIENT_FINISH = 0x03
    const val SERVER_FINISH = 0x04
    const val ERROR = 0x05

    fun magic(): ByteArray = MAGIC.copyOf()

    fun transcript(clientHello: ByteArray, serverHello: ByteArray) = PMCrypto.sha256(clientHello, serverHello)

    fun deriveKeys(dh1: ByteArray, dh2: ByteArray, dh3: ByteArray, passwordKey: ByteArray, transcript: ByteArray): SessionKeys {
        val b = PMCrypto.hkdf(dh1 + dh2 + dh3 + passwordKey, transcript, INFO, 128)
        return SessionKeys(b.copyOfRange(0, 32), b.copyOfRange(32, 64), b.copyOfRange(64, 96), b.copyOfRange(96, 128))
    }

    /** Throws [HandshakeFailure] if [msg] is an error message, otherwise checks the type. */
    fun expect(type: Int, msg: ByteArray): WireReader {
        val r = WireReader(msg)
        val t = r.u8()
        if (t == ERROR) {
            val code = r.u8()
            val retry = r.u32()
            val text = try { r.string() } catch (_: WireException) { "" }
            throw HandshakeFailure(HandshakeErrorCode.of(code), retry, text)
        }
        if (t != type) throw HandshakeFailure(HandshakeErrorCode.PROTOCOL_ERROR, 0, "Unexpected handshake message.")
        return r
    }

    /** At most [MAX_NAME_LENGTH] characters, never cutting a character in half. */
    fun clampName(s: String): String {
        val count = s.codePointCount(0, s.length)
        return if (count <= MAX_NAME_LENGTH) s else s.substring(0, s.offsetByCodePoints(0, MAX_NAME_LENGTH))
    }
}

/** The phone's side of the handshake. */
class ClientHandshake(
    private val staticKey: ByteArray,
    expectedID: String,
    deviceName: String,
    private val ephemeral: ByteArray = X25519.generatePrivateKey(),
) {
    class ServerHelloInfo(
        val hostStaticKey: ByteArray,
        val salt: ByteArray,
        val iterations: Int,
        val hostName: String,
        val alreadyPaired: Boolean,
    )

    private val expectedID = DeviceID.normalize(expectedID)
    private val deviceName = Handshake.clampName(deviceName)
    private var helloBytes = ByteArray(0)
    private var serverHelloBytes = ByteArray(0)
    private var serverEphemeral = ByteArray(0)
    private var serverStatic = ByteArray(0)

    fun hello(): ByteArray {
        val w = WireWriter(128)
        w.u8(Handshake.CLIENT_HELLO)
        w.raw(Handshake.magic())
        w.u8(Handshake.VERSION)
        w.raw(X25519.publicKey(ephemeral))
        w.raw(X25519.publicKey(staticKey))
        w.string(deviceName)
        helloBytes = w.bytes()
        return helloBytes
    }

    fun parseServerHello(msg: ByteArray): ServerHelloInfo {
        val r = Handshake.expect(Handshake.SERVER_HELLO, msg)
        serverEphemeral = r.take(32)
        serverStatic = r.take(32)
        val salt = r.blob16()
        val iterations = r.u32()
        val hostName = r.string()
        val flags = r.u8()
        if (DeviceID.from(serverStatic) != expectedID) {
            throw HandshakeFailure(HandshakeErrorCode.PROTOCOL_ERROR, 0,
                "This Mac's ID doesn't match. Check the ID shown in PocketMac Host.")
        }
        if (iterations < 10_000 || iterations > 5_000_000 || salt.size < 16) {
            throw HandshakeFailure(HandshakeErrorCode.PROTOCOL_ERROR, 0, "Bad key parameters from Mac.")
        }
        serverHelloBytes = msg
        return ServerHelloInfo(serverStatic, salt, iterations.toInt(), hostName, flags and 1 != 0)
    }

    /** Returns the ClientFinish message and the session keys. */
    fun finish(passwordKey: ByteArray): Pair<ByteArray, SessionKeys> {
        val dh1 = PMCrypto.dh(ephemeral, serverEphemeral)
        val dh2 = PMCrypto.dh(ephemeral, serverStatic)
        val dh3 = PMCrypto.dh(staticKey, serverEphemeral)
        val th = Handshake.transcript(helloBytes, serverHelloBytes)
        val keys = Handshake.deriveKeys(dh1, dh2, dh3, passwordKey, th)
        val w = WireWriter(40)
        w.u8(Handshake.CLIENT_FINISH)
        w.raw(PMCrypto.hmac(keys.confirmClient, th, "client".toByteArray()))
        return w.bytes() to keys
    }

    fun verifyServerFinish(msg: ByteArray, keys: SessionKeys) {
        val r = Handshake.expect(Handshake.SERVER_FINISH, msg)
        val mac = r.take(32)
        val th = Handshake.transcript(helloBytes, serverHelloBytes)
        if (!PMCrypto.equal(mac, PMCrypto.hmac(keys.confirmServer, th, "server".toByteArray()))) {
            throw HandshakeFailure(HandshakeErrorCode.PROTOCOL_ERROR, 0, "Mac failed to prove its identity.")
        }
    }
}
