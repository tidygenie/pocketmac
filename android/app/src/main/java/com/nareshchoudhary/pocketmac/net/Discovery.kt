package com.nareshchoudhary.pocketmac.net

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import androidx.compose.runtime.mutableStateMapOf
import androidx.core.content.ContextCompat
import com.nareshchoudhary.pocketmac.proto.DeviceID
import com.nareshchoudhary.pocketmac.proto.POCKETMAC_SERVICE_TYPE
import java.net.Inet4Address
import java.net.InetAddress

/** Finds PocketMac hosts on the same Wi-Fi (mDNS / DNS-SD, like Bonjour on the iPhone). */
class Discovery(context: Context) {
    data class Found(val id: String, val name: String, val address: InetAddress, val port: Int)

    /** Keyed by normalised Mac ID. Main thread only. */
    val found = mutableStateMapOf<String, Found>()

    private val nsd = context.getSystemService(NsdManager::class.java)
    private val main = Handler(Looper.getMainLooper())
    private val mainExecutor = ContextCompat.getMainExecutor(context)
    private var listener: NsdManager.DiscoveryListener? = null
    private val idByService = HashMap<String, String>()
    private val infoCallbacks = HashMap<String, Any>()   // NsdManager.ServiceInfoCallback (Android 14+)
    private val resolveQueue = ArrayDeque<NsdServiceInfo>()
    private var resolving = false
    private var wanted = false

    fun start() {
        wanted = true
        if (listener != null || nsd == null) return
        val l = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {
                main.post {
                    if (listener === this) listener = null
                    main.postDelayed({ if (wanted) start() }, 5000)
                }
            }
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onServiceFound(info: NsdServiceInfo) {
                main.post { if (listener === this) resolve(info) }
            }
            override fun onServiceLost(info: NsdServiceInfo) {
                main.post { lost(info.serviceName) }
            }
        }
        try {
            nsd.discoverServices(POCKETMAC_SERVICE_TYPE, NsdManager.PROTOCOL_DNS_SD, l)
            listener = l
        } catch (_: Throwable) {
            main.postDelayed({ if (wanted) start() }, 5000)
        }
    }

    fun stop() {
        wanted = false
        listener?.let { runCatching { nsd?.stopServiceDiscovery(it) } }
        listener = null
        if (Build.VERSION.SDK_INT >= 34) {
            infoCallbacks.values.forEach { runCatching { nsd?.unregisterServiceInfoCallback(it as NsdManager.ServiceInfoCallback) } }
        }
        infoCallbacks.clear()
        resolveQueue.clear()
    }

    private fun resolve(info: NsdServiceInfo) {
        if (Build.VERSION.SDK_INT >= 34) watch(info)
        else {
            resolveQueue.addLast(info)
            resolveNext()
        }
    }

    private fun publish(serviceName: String, idRaw: ByteArray?, addresses: List<InetAddress>, port: Int) {
        val id = idRaw?.let { DeviceID.normalize(String(it, Charsets.UTF_8)) }.orEmpty()
        val address = addresses.firstOrNull { it is Inet4Address } ?: addresses.firstOrNull()
        if (id.length != 12 || address == null || port <= 0) return
        idByService[serviceName] = id
        found[id] = Found(id, serviceName, address, port)
    }

    private fun lost(serviceName: String) {
        idByService.remove(serviceName)?.let { found.remove(it) }
        if (Build.VERSION.SDK_INT >= 34) {
            infoCallbacks.remove(serviceName)?.let { runCatching { nsd?.unregisterServiceInfoCallback(it as NsdManager.ServiceInfoCallback) } }
        }
    }

    /** Android 14+: one callback per service keeps its address up to date. */
    @RequiresApi(34)
    private fun watch(info: NsdServiceInfo) {
        if (infoCallbacks.containsKey(info.serviceName)) return
        val cb = object : NsdManager.ServiceInfoCallback {
            override fun onServiceInfoCallbackRegistrationFailed(errorCode: Int) {
                infoCallbacks.remove(info.serviceName)
            }
            override fun onServiceUpdated(updated: NsdServiceInfo) {
                publish(updated.serviceName, updated.attributes["id"], updated.hostAddresses, updated.port)
            }
            override fun onServiceLost() = lost(info.serviceName)
            override fun onServiceInfoCallbackUnregistered() {}
        }
        infoCallbacks[info.serviceName] = cb
        try {
            nsd?.registerServiceInfoCallback(info, mainExecutor, cb)
        } catch (_: Throwable) {
            infoCallbacks.remove(info.serviceName)
        }
    }

    /** Older Android: resolve one service at a time (the system allows only one). */
    @Suppress("DEPRECATION")
    private fun resolveNext() {
        if (resolving || nsd == null) return
        val info = resolveQueue.removeFirstOrNull() ?: return
        resolving = true
        try {
            nsd.resolveService(info, object : NsdManager.ResolveListener {
                override fun onResolveFailed(serviceInfo: NsdServiceInfo, errorCode: Int) {
                    main.post { resolving = false; resolveNext() }
                }
                override fun onServiceResolved(r: NsdServiceInfo) {
                    main.post {
                        resolving = false
                        if (listener != null) publish(r.serviceName, r.attributes["id"], listOfNotNull(r.host), r.port)
                        resolveNext()
                    }
                }
            })
        } catch (_: Throwable) {
            resolving = false
        }
    }
}
