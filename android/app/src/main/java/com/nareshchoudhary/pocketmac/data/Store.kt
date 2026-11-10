package com.nareshchoudhary.pocketmac.data

import android.content.Context
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nareshchoudhary.pocketmac.proto.DeviceID
import com.nareshchoudhary.pocketmac.proto.POCKETMAC_PORT
import com.nareshchoudhary.pocketmac.proto.X25519
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class SavedMac(
    val id: String,               // normalised Mac ID (12 chars)
    val name: String,
    val internetAddress: String = "",   // Tailscale name / IP — optional
    val port: Int = POCKETMAC_PORT,
    val lastConnected: Long = 0,
) {
    val prettyID: String get() = DeviceID.pretty(id)
}

enum class InputMode(val label: String) { TRACKPAD("Trackpad"), TOUCH("Touch") }

data class ClientSettings(
    val quality: Int = 1,
    val fps: Int = 30,
    val useHEVC: Boolean = true,
    val inputMode: InputMode = InputMode.TRACKPAD,
    val lidFit: Int = 0,
    val clipboardSync: Boolean = true,
    val keepScreenOn: Boolean = true,
    val reverseScroll: Boolean = false,
    val haptics: Boolean = true,
    val trackpadSpeed: Float = 1f,
    val autoSaverOnBatterySaver: Boolean = true,
    val unlockToConnect: Boolean = true,
)

/** Cached login for one Mac: the PBKDF2 output, never the password itself. */
class MacCredential(val salt: ByteArray, val iterations: Int, val key: ByteArray)

/** Saved Macs, settings, this phone's key and cached logins. UI reads the Compose state directly. */
class AppStore(private val context: Context) {
    private val prefs = context.getSharedPreferences("pocketmac", Context.MODE_PRIVATE)

    var macs by mutableStateOf(loadMacs())
        private set
    var settings by mutableStateOf(loadSettings())
        private set

    fun update(transform: (ClientSettings) -> ClientSettings) {
        settings = transform(settings)
        val s = settings
        prefs.edit().putString("settings", JSONObject().apply {
            put("quality", s.quality); put("fps", s.fps); put("useHEVC", s.useHEVC); put("inputMode", s.inputMode.name)
            put("lidFit", s.lidFit); put("clipboardSync", s.clipboardSync); put("keepScreenOn", s.keepScreenOn)
            put("reverseScroll", s.reverseScroll); put("haptics", s.haptics); put("trackpadSpeed", s.trackpadSpeed.toDouble())
            put("autoSaver", s.autoSaverOnBatterySaver); put("unlockToConnect", s.unlockToConnect)
        }.toString()).apply()
    }

    fun upsert(m: SavedMac) {
        val i = macs.indexOfFirst { it.id == m.id }
        macs = if (i >= 0) macs.toMutableList().also { it[i] = m } else macs + m
        saveMacs()
    }

    fun remove(m: SavedMac) {
        macs = macs.filter { it.id != m.id }
        saveMacs()
        deleteCredential(m.id)
    }

    // MARK: Identity — this phone's long-term key, created once. The Mac pairs with it.

    val identity: ByteArray by lazy {
        prefs.getString("identity", null)?.let { Vault.open(it) }?.takeIf { it.size == 32 }
            ?: X25519.generatePrivateKey().also { prefs.edit().putString("identity", Vault.seal(it)).apply() }
    }

    val deviceName: String by lazy {
        val custom = runCatching { Settings.Global.getString(context.contentResolver, Settings.Global.DEVICE_NAME) }.getOrNull()
        custom?.takeIf { it.isNotBlank() } ?: run {
            val maker = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
            if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL else "$maker ${Build.MODEL}"
        }
    }

    // MARK: Cached logins (encrypted with a key that never leaves the phone's secure hardware)

    fun hasCredential(id: String) = prefs.contains("cred-$id")

    fun loadCredential(id: String): MacCredential? {
        val raw = prefs.getString("cred-$id", null)?.let { Vault.open(it) } ?: return null
        return runCatching {
            val o = JSONObject(String(raw, Charsets.UTF_8))
            MacCredential(b64(o.getString("salt")), o.getInt("iterations"), b64(o.getString("key")))
        }.getOrNull()
    }

    fun saveCredential(c: MacCredential, id: String) {
        val json = JSONObject().put("salt", b64(c.salt)).put("iterations", c.iterations).put("key", b64(c.key)).toString()
        prefs.edit().putString("cred-$id", Vault.seal(json.toByteArray())).apply()
    }

    fun deleteCredential(id: String) = prefs.edit().remove("cred-$id").apply()

    // MARK: Persistence

    private fun saveMacs() {
        val arr = JSONArray()
        macs.forEach { m ->
            arr.put(JSONObject().put("id", m.id).put("name", m.name).put("address", m.internetAddress)
                .put("port", m.port).put("last", m.lastConnected))
        }
        prefs.edit().putString("macs", arr.toString()).apply()
    }

    private fun loadMacs(): List<SavedMac> = runCatching {
        val arr = JSONArray(prefs.getString("macs", "[]"))
        List(arr.length()) { i ->
            val o = arr.getJSONObject(i)
            SavedMac(o.getString("id"), o.optString("name", "My Mac"), o.optString("address", ""),
                o.optInt("port", POCKETMAC_PORT), o.optLong("last", 0))
        }
    }.getOrDefault(emptyList())

    private fun loadSettings(): ClientSettings {
        val d = ClientSettings()
        val o = prefs.getString("settings", null)?.let { runCatching { JSONObject(it) }.getOrNull() } ?: return d
        return ClientSettings(
            quality = o.optInt("quality", d.quality),
            fps = o.optInt("fps", d.fps),
            useHEVC = o.optBoolean("useHEVC", d.useHEVC),
            inputMode = runCatching { InputMode.valueOf(o.getString("inputMode")) }.getOrDefault(d.inputMode),
            lidFit = o.optInt("lidFit", d.lidFit),
            clipboardSync = o.optBoolean("clipboardSync", d.clipboardSync),
            keepScreenOn = o.optBoolean("keepScreenOn", d.keepScreenOn),
            reverseScroll = o.optBoolean("reverseScroll", d.reverseScroll),
            haptics = o.optBoolean("haptics", d.haptics),
            trackpadSpeed = o.optDouble("trackpadSpeed", d.trackpadSpeed.toDouble()).toFloat(),
            autoSaverOnBatterySaver = o.optBoolean("autoSaver", d.autoSaverOnBatterySaver),
            unlockToConnect = o.optBoolean("unlockToConnect", d.unlockToConnect),
        )
    }

    private fun b64(b: ByteArray): String = Base64.encodeToString(b, Base64.NO_WRAP)
    private fun b64(s: String): ByteArray = Base64.decode(s, Base64.NO_WRAP)
}

/**
 * AES-256-GCM with a key generated inside Android Keystore (secure hardware on
 * most phones): the key can't be copied off the device, so saved data is useless
 * anywhere else. The app also excludes its data from backups.
 */
object Vault {
    private const val ALIAS = "pocketmac.vault"

    private fun key(): SecretKey {
        val ks = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (ks.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return gen.generateKey()
    }

    fun seal(plain: ByteArray): String {
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.ENCRYPT_MODE, key())
        return Base64.encodeToString(c.iv + c.doFinal(plain), Base64.NO_WRAP)
    }

    fun open(sealed: String): ByteArray? = runCatching {
        val d = Base64.decode(sealed, Base64.NO_WRAP)
        val c = Cipher.getInstance("AES/GCM/NoPadding")
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, d, 0, 12))
        c.doFinal(d, 12, d.size - 12)
    }.getOrNull()
}
