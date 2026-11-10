package com.nareshchoudhary.pocketmac

import com.nareshchoudhary.pocketmac.proto.ClientHandshake
import com.nareshchoudhary.pocketmac.proto.ClientMessage
import com.nareshchoudhary.pocketmac.proto.CipherState
import com.nareshchoudhary.pocketmac.proto.DeviceID
import com.nareshchoudhary.pocketmac.proto.Handshake
import com.nareshchoudhary.pocketmac.proto.HandshakeErrorCode
import com.nareshchoudhary.pocketmac.proto.HandshakeFailure
import com.nareshchoudhary.pocketmac.proto.LidDisplayFit
import com.nareshchoudhary.pocketmac.proto.PMCrypto
import com.nareshchoudhary.pocketmac.proto.QuickAction
import com.nareshchoudhary.pocketmac.proto.ServerMessage
import com.nareshchoudhary.pocketmac.proto.StreamQuality
import com.nareshchoudhary.pocketmac.proto.StreamSettings
import com.nareshchoudhary.pocketmac.proto.VideoCodec
import com.nareshchoudhary.pocketmac.proto.X25519
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

/**
 * Known-answer tests generated from the Swift code that runs on the Mac and
 * iPhone (tools/vectors). If these pass, the Android app speaks exactly the
 * same protocol, byte for byte.
 */
class ProtocolVectorsTest {
    private val v: Map<String, String> by lazy {
        val text = javaClass.classLoader!!.getResourceAsStream("vectors.txt")!!.bufferedReader().readText()
        text.lines().filter { it.isNotBlank() }.associate { line ->
            val i = line.indexOf(' ')
            line.substring(0, i) to line.substring(i + 1)
        }
    }

    private fun hex(name: String): ByteArray {
        val s = v[name] ?: error("missing vector $name")
        return ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
    }

    private fun str(name: String) = String(hex(name), Charsets.UTF_8)
    private fun hexOf(b: ByteArray) = b.joinToString("") { "%02x".format(it) }

    @Test fun x25519MatchesRfc7748() {
        val k = "a546e36bf0527c9d3b16154b82465edd62144c0ac1fc5a18506a2244ba449ac4"
        val u = "e6db6867583030db3594c1a424b15f7c726624ec26b3353b10a903a6d0ab1c4c"
        fun h(s: String) = ByteArray(s.length / 2) { s.substring(it * 2, it * 2 + 2).toInt(16).toByte() }
        assertEquals("c3da55379de9c6908e94ea4df28d084f32eccf03491c71f754b4075577a28552", hexOf(X25519.scalarMult(h(k), h(u))))
    }

    @Test fun x25519MatchesCryptoKit() {
        assertArrayEquals(hex("dh.shared"), PMCrypto.dh(hex("dh.a"), hex("dh.bpub")))
        for (i in 0 until 3) assertArrayEquals(hex("id.$i.pub"), X25519.publicKey(hex("id.$i.priv")))
    }

    @Test fun deviceIDs() {
        for (i in 0 until 3) assertEquals(str("id.$i.id"), DeviceID.from(hex("id.$i.pub")))
        for (i in 0 until 3) assertEquals(str("norm.$i.out"), DeviceID.normalize(str("norm.$i.in")))
    }

    @Test fun passwordKeys() {
        for (i in 0 until 3) {
            val key = PMCrypto.passwordKey(str("pbkdf2.$i.password"), hex("pbkdf2.$i.salt"), v["pbkdf2.$i.iterations"]!!.toInt())
            assertArrayEquals("pbkdf2 #$i", hex("pbkdf2.$i.key"), key)
        }
    }

    @Test fun fullHandshakeAndRecords() {
        val hs = ClientHandshake(hex("hs.clientStatic"), str("hs.macID"), str("hs.deviceName"), hex("hs.clientEphemeral"))
        assertEquals(hexOf(hex("hs.clientHello")), hexOf(hs.hello()))
        val info = hs.parseServerHello(hex("hs.serverHello"))
        assertEquals("Naresh’s MacBook Air", info.hostName)
        assertTrue(info.alreadyPaired)
        val pk = PMCrypto.passwordKey(str("hs.password"), info.salt, info.iterations)
        val (finish, keys) = hs.finish(pk)
        assertEquals(hexOf(hex("hs.clientFinish")), hexOf(finish))
        hs.verifyServerFinish(hex("hs.serverFinish"), keys)
        assertArrayEquals(hex("hs.c2s"), keys.clientToServer)
        assertArrayEquals(hex("hs.s2c"), keys.serverToClient)

        // phone → Mac: identical plaintext and ciphertext
        val settings = StreamSettings(StreamQuality.SHARP, 60, VideoCodec.H264, 2400, 1080, LidDisplayFit.PHONE_ROOMY)
        val messages = listOf(
            ClientMessage.StartStream(settings), ClientMessage.UpdateSettings(StreamSettings()),
            ClientMessage.FrameAck(0xDEADBEEFL), ClientMessage.RequestKeyframe, ClientMessage.SetPaused(true),
            ClientMessage.MouseMove(0.25f, 0.75f), ClientMessage.MouseButton(1, true, 0.5f, 0.125f, 2, 0x100000),
            ClientMessage.Scroll(-3.5f, 12.25f), ClientMessage.Key(36, false, 0x40000), ClientMessage.Text("héllo ✓\n"),
            ClientMessage.Action(QuickAction.MISSION_CONTROL), ClientMessage.Clipboard("clip 📋"), ClientMessage.Ping(1_234_567_890_123L),
        )
        val send = CipherState(keys.clientToServer)
        messages.forEachIndexed { i, m ->
            val plain = m.encode()
            assertEquals("c2s #$i plain", hexOf(hex("c2s.$i.plain")), hexOf(plain))
            assertEquals("c2s #$i sealed", hexOf(hex("c2s.$i.sealed")), hexOf(send.seal(plain)))
        }

        // Mac → phone: open and decode every message type
        val recv = CipherState(keys.serverToClient)
        val decoded = (0 until 7).map { i ->
            val plain = recv.open(hex("s2c.$i.sealed"))
            assertArrayEquals("s2c #$i", hex("s2c.$i.plain"), plain)
            ServerMessage.decode(plain)
        }
        val fmt = (decoded[0] as ServerMessage.Format).format
        assertEquals(VideoCodec.HEVC, fmt.codec)
        assertEquals(1920, fmt.width)
        assertEquals(1248, fmt.height)
        assertEquals(3, fmt.parameterSets.size)
        assertEquals("42030405", hexOf(fmt.parameterSets[1]))
        val frame = (decoded[1] as ServerMessage.Frame).frame
        assertEquals(42L, frame.frameID)
        assertTrue(frame.keyframe)
        assertEquals(987_654_321L, frame.captureMicros)
        assertEquals("000000032601af0000000202 01".replace(" ", ""), hexOf(frame.data.copyOf(frame.length)))
        val st = (decoded[2] as ServerMessage.Status).status
        assertEquals("MacBook Air", st.hostName)
        assertEquals(87, st.battery)
        assertTrue(st.charging && st.lidMode && st.screenPermission && st.accessibilityPermission)
        assertTrue(!st.onAC && !st.lidClosed && !st.lidHelperInstalled && !st.virtualDisplay)
        assertEquals(ServerMessage.Clipboard("from Mac ✓"), decoded[3])
        assertEquals(ServerMessage.Pong(55), decoded[4])
        assertEquals(ServerMessage.Cursor(0.5f, 0.0625f), decoded[5])
        assertEquals(ServerMessage.Notice("Mac locked"), decoded[6])
    }

    @Test fun tamperedRecordIsRejected() {
        val keys = hex("hs.s2c")
        val sealed = hex("s2c.0.sealed")
        sealed[3] = (sealed[3].toInt() xor 1).toByte()
        try {
            CipherState(keys).open(sealed)
            fail("tampered record opened")
        } catch (_: javax.crypto.AEADBadTagException) {
        }
    }

    @Test fun wrongMacIsDetected() {
        val hs = ClientHandshake(hex("hs.clientStatic"), "1N81-1EPB-JZXA", "x", hex("hs.clientEphemeral"))
        hs.hello()
        try {
            hs.parseServerHello(hex("hs.serverHello"))
            fail("accepted a Mac whose key doesn't match the ID")
        } catch (e: HandshakeFailure) {
            assertEquals(HandshakeErrorCode.PROTOCOL_ERROR, e.code)
        }
    }

    @Test fun handshakeErrorsAreReadable() {
        try {
            Handshake.expect(Handshake.SERVER_HELLO, hex("hs.error"))
            fail("error message not reported")
        } catch (e: HandshakeFailure) {
            assertEquals(HandshakeErrorCode.LOCKED_OUT, e.code)
            assertEquals(30L, e.retryAfter)
            assertEquals("Too many wrong attempts. Try again in 30 s.", e.message)
        }
    }
}
