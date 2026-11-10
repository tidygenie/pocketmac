package com.nareshchoudhary.pocketmac.proto

import java.security.MessageDigest
import java.security.SecureRandom
import java.text.Normalizer
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

object PMCrypto {
    private val random = SecureRandom()

    /** PBKDF2-HMAC-SHA256 of the NFC-normalised password: 32 bytes, as on the Mac. */
    fun passwordKey(password: String, salt: ByteArray, iterations: Int): ByteArray {
        val pw = Normalizer.normalize(password, Normalizer.Form.NFC).toByteArray(Charsets.UTF_8)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(if (pw.isEmpty()) emptyKey() else SecretKeySpec(pw, "HmacSHA256"))
        val out = ByteArray(32)
        val u = ByteArray(32)
        mac.update(salt)
        mac.update(byteArrayOf(0, 0, 0, 1))
        mac.doFinal(u, 0)
        u.copyInto(out)
        for (round in 1 until iterations) {
            mac.update(u)
            mac.doFinal(u, 0)
            for (j in 0 until 32) out[j] = (out[j].toInt() xor u[j].toInt()).toByte()
        }
        return out
    }

    // HMAC with an empty key equals HMAC with one zero byte (both are zero-padded to the block size).
    private fun emptyKey() = SecretKeySpec(ByteArray(1), "HmacSHA256")

    fun randomBytes(n: Int): ByteArray = ByteArray(n).also { random.nextBytes(it) }

    fun sha256(vararg parts: ByteArray): ByteArray {
        val md = MessageDigest.getInstance("SHA-256")
        parts.forEach { md.update(it) }
        return md.digest()
    }

    fun hmac(key: ByteArray, vararg parts: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        parts.forEach { mac.update(it) }
        return mac.doFinal()
    }

    /** RFC 5869 HKDF-SHA256. */
    fun hkdf(ikm: ByteArray, salt: ByteArray, info: ByteArray, length: Int): ByteArray {
        val prk = hmac(if (salt.isEmpty()) ByteArray(32) else salt, ikm)
        val out = ByteArray(length)
        var t = ByteArray(0)
        var pos = 0
        var counter = 1
        while (pos < length) {
            t = hmac(prk, t, info, byteArrayOf(counter.toByte()))
            val n = minOf(t.size, length - pos)
            t.copyInto(out, pos, 0, n)
            pos += n
            counter++
        }
        return out
    }

    /** Constant-time comparison. */
    fun equal(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    fun dh(privateKey: ByteArray, publicKey: ByteArray): ByteArray {
        if (publicKey.size != 32) throw WireException("invalid public key")
        val shared = X25519.scalarMult(privateKey, publicKey)
        // Reject low-order points (all-zero output).
        if (shared.all { it.toInt() == 0 }) throw WireException("invalid public key")
        return shared
    }
}

/**
 * The Mac's ID is a fingerprint of its long-term public key: 60 bits shown as
 * 12 Crockford-base32 characters, e.g. "K7QM-4XPA-9TZC". Typing it on the phone
 * authenticates the Mac: nobody can impersonate it without its private key.
 */
object DeviceID {
    private const val ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"

    fun from(publicKey: ByteArray): String {
        val h = PMCrypto.sha256(publicKey)
        var bits = 0L
        for (i in 0 until 8) bits = (bits shl 8) or (h[i].toLong() and 0xFF)
        bits = bits ushr 4
        val sb = StringBuilder(12)
        for (i in 11 downTo 0) sb.append(ALPHABET[((bits ushr (i * 5)) and 0x1F).toInt()])
        return sb.toString()
    }

    /** Upper-case, drop separators, fix look-alikes (O→0, I/L→1, U→V). */
    fun normalize(input: String): String {
        val sb = StringBuilder()
        for (ch in input.uppercase()) {
            when (ch) {
                'O' -> sb.append('0')
                'I', 'L' -> sb.append('1')
                'U' -> sb.append('V')
                else -> if (ch in ALPHABET) sb.append(ch)
            }
        }
        return sb.toString()
    }

    fun pretty(id: String): String {
        val n = normalize(id)
        if (n.length != 12) return n
        return n.substring(0, 4) + "-" + n.substring(4, 8) + "-" + n.substring(8, 12)
    }

    fun isValid(id: String): Boolean = normalize(id).length == 12
}

/**
 * One direction of the encrypted stream: AES-256-GCM with an implicit 64-bit
 * counter nonce, so any replayed / reordered / dropped record fails to open.
 * Not thread-safe: each direction is used by exactly one thread.
 */
class CipherState(key: ByteArray) {
    private val key = SecretKeySpec(key, "AES")
    private val cipher = Cipher.getInstance("AES/GCM/NoPadding")
    private val nonce = ByteArray(12)
    private var counter = 0L

    private fun nextNonce(): GCMParameterSpec {
        for (i in 0 until 8) nonce[4 + i] = (counter ushr (56 - 8 * i)).toByte()
        counter++
        return GCMParameterSpec(128, nonce)
    }

    fun seal(plaintext: ByteArray): ByteArray {
        cipher.init(Cipher.ENCRYPT_MODE, key, nextNonce())
        return cipher.doFinal(plaintext)
    }

    /** Decrypts into [out] (needs at least len-16 bytes) and returns the plaintext length. */
    fun open(record: ByteArray, off: Int, len: Int, out: ByteArray): Int {
        if (len < 16) throw WireException("record too short")
        cipher.init(Cipher.DECRYPT_MODE, key, nextNonce())
        return cipher.doFinal(record, off, len, out, 0)
    }

    fun open(record: ByteArray): ByteArray {
        val out = ByteArray(maxOf(record.size, 16))
        val n = open(record, 0, record.size, out)
        return out.copyOf(n)
    }
}
