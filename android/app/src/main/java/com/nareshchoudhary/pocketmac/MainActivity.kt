package com.nareshchoudhary.pocketmac

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.CancellationSignal
import android.os.PowerManager
import android.provider.Settings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.annotation.RequiresApi
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.runtime.Composable
import androidx.core.content.ContextCompat
import com.nareshchoudhary.pocketmac.ui.AddMacScreen
import com.nareshchoudhary.pocketmac.ui.HomeScreen
import com.nareshchoudhary.pocketmac.ui.PocketMacTheme
import com.nareshchoudhary.pocketmac.ui.RemoteScreen
import com.nareshchoudhary.pocketmac.ui.SettingsScreen

class MainActivity : ComponentActivity() {
    private val app: AppState get() = (application as PocketMacApplication).state
    private val unlockFn: (String, String, (Boolean) -> Unit) -> Unit = { title, subtitle, done -> unlock(title, subtitle, done) }
    private val prefs by lazy { getSharedPreferences("pocketmac", MODE_PRIVATE) }

    private val localNetworkRequest = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        app.localNetworkDenied = !granted
        if (granted) app.discovery.start()
    }

    private val powerSaveChanged = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            app.session?.updateStream()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        app.unlocker = unlockFn
        setContent { PocketMacTheme { AppRoot(app, ::requestLocalNetwork) } }
        ContextCompat.registerReceiver(this, powerSaveChanged, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED)
        if (!app.canUseLocalNetwork()) {
            if (prefs.getBoolean("askedLocalNetwork", false)) app.localNetworkDenied = true else requestLocalNetwork()
        }
    }

    override fun onDestroy() {
        unregisterReceiver(powerSaveChanged)
        if (app.unlocker === unlockFn) app.unlocker = null
        super.onDestroy()
    }

    override fun onStart() {
        super.onStart()
        app.onForeground()
    }

    override fun onStop() {
        super.onStop()
        if (!isChangingConfigurations) app.onBackground()
    }

    /** Android 17+: finding and reaching the Mac on Wi-Fi needs "local network" access. */
    private fun requestLocalNetwork() {
        if (Build.VERSION.SDK_INT < 37) return
        val asked = prefs.getBoolean("askedLocalNetwork", false)
        if (!asked || shouldShowRequestPermissionRationale(AppState.LOCAL_NETWORK_PERMISSION)) {
            prefs.edit().putBoolean("askedLocalNetwork", true).apply()
            localNetworkRequest.launch(AppState.LOCAL_NETWORK_PERMISSION)
        } else {
            // Denied twice: Android won't ask again, so open the app's settings page.
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
        }
    }

    override fun onResume() {
        super.onResume()
        if (app.localNetworkDenied && app.canUseLocalNetwork()) {
            app.localNetworkDenied = false
            app.discovery.start()
        }
    }

    /** Fingerprint, face or screen lock before a saved login is used. */
    private fun unlock(title: String, subtitle: String, done: (Boolean) -> Unit) {
        val secure = getSystemService(KeyguardManager::class.java)?.isDeviceSecure == true
        if (Build.VERSION.SDK_INT < 30 || !secure) {
            done(true)
            return
        }
        showPrompt(title, subtitle, done)
    }

    @RequiresApi(30)
    private fun showPrompt(title: String, subtitle: String, done: (Boolean) -> Unit) {
        val prompt = BiometricPrompt.Builder(this)
            .setTitle(title)
            .setSubtitle(subtitle)
            .setAllowedAuthenticators(BiometricManager.Authenticators.BIOMETRIC_STRONG or BiometricManager.Authenticators.DEVICE_CREDENTIAL)
            .build()
        prompt.authenticate(CancellationSignal(), mainExecutor, object : BiometricPrompt.AuthenticationCallback() {
            override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) = done(true)
            override fun onAuthenticationError(errorCode: Int, errString: CharSequence) = done(false)
        })
    }
}

private sealed interface Route {
    data object Home : Route
    data object Settings : Route
    data class Add(val form: AddMacForm) : Route
    data class Remote(val session: RemoteSession) : Route
}

@Composable
fun AppRoot(app: AppState, requestLocalNetwork: () -> Unit) {
    val session = app.session
    val form = app.addForm
    val route = when {
        session != null -> Route.Remote(session)
        form != null -> Route.Add(form)
        app.showSettings -> Route.Settings
        else -> Route.Home
    }
    AnimatedContent(
        targetState = route,
        transitionSpec = { fadeIn(tween(220)) togetherWith fadeOut(tween(150)) },
        contentKey = { r -> if (r is Route.Remote) r.session else r },
        label = "route",
    ) { r ->
        when (r) {
            Route.Home -> HomeScreen(app, requestLocalNetwork)
            Route.Settings -> SettingsScreen(app)
            is Route.Add -> AddMacScreen(app, r.form)
            is Route.Remote -> RemoteScreen(app, r.session)
        }
    }
}
