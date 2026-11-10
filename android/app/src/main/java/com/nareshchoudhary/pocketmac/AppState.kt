package com.nareshchoudhary.pocketmac

import android.app.Application
import android.content.ClipData
import android.content.ClipboardManager
import android.content.pm.PackageManager
import android.os.Build
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.nareshchoudhary.pocketmac.data.AppStore
import com.nareshchoudhary.pocketmac.data.SavedMac
import com.nareshchoudhary.pocketmac.net.Discovery
import com.nareshchoudhary.pocketmac.proto.DeviceID
import com.nareshchoudhary.pocketmac.proto.POCKETMAC_PORT

class PocketMacApplication : Application() {
    lateinit var state: AppState
        private set

    override fun onCreate() {
        super.onCreate()
        state = AppState(this)
    }
}

/** App-wide state: saved Macs, nearby Macs, which screen is showing. Lives as long as the process. */
class AppState(val context: Application) {
    val store = AppStore(context)
    val discovery = Discovery(context)

    var session by mutableStateOf<RemoteSession?>(null)
        private set
    var addForm by mutableStateOf<AddMacForm?>(null)
    var showSettings by mutableStateOf(false)
    /** Android 17+: the user hasn't allowed local network access yet (needed to find the Mac on Wi-Fi). */
    var localNetworkDenied by mutableStateOf(false)

    /** Set by the activity: shows the fingerprint / screen-lock prompt and reports success. */
    var unlocker: ((title: String, subtitle: String, done: (Boolean) -> Unit) -> Unit)? = null

    fun connect(mac: SavedMac, password: String? = null, remember: Boolean = true) {
        session?.close()
        val s = RemoteSession(this, mac)
        s.rememberPassword = remember
        session = s
        s.start(password)
    }

    /** UI tests: show the remote screen playing recorded video, no Mac needed. */
    fun startDemo(mac: SavedMac, messages: List<ByteArray>) {
        session?.close()
        val s = RemoteSession(this, mac)
        session = s
        s.startDemo(messages)
    }

    fun closeSession() {
        session?.close()
        session = null
    }

    fun onForeground() {
        if (canUseLocalNetwork()) discovery.start()
        session?.resume()
    }

    fun onBackground() {
        session?.suspend()
        discovery.stop()
    }

    fun unlock(title: String, subtitle: String, done: (Boolean) -> Unit) {
        val u = unlocker
        if (u == null || !store.settings.unlockToConnect) done(true) else u(title, subtitle, done)
    }

    fun canUseLocalNetwork(): Boolean =
        Build.VERSION.SDK_INT < 37 || context.checkSelfPermission(LOCAL_NETWORK_PERMISSION) == PackageManager.PERMISSION_GRANTED

    private val clipboard get() = context.getSystemService(ClipboardManager::class.java)

    fun clipboardText(): String? = runCatching {
        clipboard?.primaryClip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(context)?.toString()
    }.getOrNull()

    fun setClipboard(text: String) {
        runCatching { clipboard?.setPrimaryClip(ClipData.newPlainText("From Mac", text)) }
    }

    companion object {
        const val LOCAL_NETWORK_PERMISSION = "android.permission.ACCESS_LOCAL_NETWORK"
    }
}

/** Form state for adding / editing a Mac. */
class AddMacForm(val editing: SavedMac? = null, id: String = "", name: String = "") {
    var macID by mutableStateOf(editing?.prettyID ?: DeviceID.pretty(id))
    var name by mutableStateOf(editing?.name ?: name)
    var address by mutableStateOf(editing?.internetAddress ?: "")
    var port by mutableStateOf((editing?.port ?: POCKETMAC_PORT).toString())
    var password by mutableStateOf("")
    var remember by mutableStateOf(true)

    val idValid: Boolean get() = DeviceID.isValid(macID)

    fun makeMac(): SavedMac {
        val base = editing ?: SavedMac(id = DeviceID.normalize(macID), name = "")
        return base.copy(
            id = DeviceID.normalize(macID),
            name = name.trim().ifEmpty { "My Mac" },
            internetAddress = address.trim(),
            port = port.trim().toIntOrNull()?.takeIf { it in 1..65535 } ?: POCKETMAC_PORT,
        )
    }
}
