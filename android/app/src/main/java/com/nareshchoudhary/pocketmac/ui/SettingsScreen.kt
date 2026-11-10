@file:OptIn(ExperimentalMaterial3Api::class)

package com.nareshchoudhary.pocketmac.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.ArrowBack
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.nareshchoudhary.pocketmac.AppState
import com.nareshchoudhary.pocketmac.BuildConfig
import com.nareshchoudhary.pocketmac.data.InputMode
import com.nareshchoudhary.pocketmac.proto.StreamQuality
import com.nareshchoudhary.pocketmac.video.Codecs

@Composable
fun SettingsScreen(app: AppState) {
    val store = app.store
    val s = store.settings
    BackHandler { app.showSettings = false }
    val bar = TopAppBarDefaults.pinnedScrollBehavior()

    Scaffold(
        modifier = Modifier.nestedScroll(bar.nestedScrollConnection),
        topBar = {
            TopAppBar(
                title = { Text("Settings") },
                navigationIcon = { IconButton(onClick = { app.showSettings = false }) { Icon(Icons.AutoMirrored.Rounded.ArrowBack, "Back") } },
                scrollBehavior = bar,
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).navigationBarsPadding(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Section("Picture") {
                Segmented("Quality", StreamQuality.entries.map { it.label }, s.quality) { v -> store.update { it.copy(quality = v) } }
                Segmented("Frame rate (30 saves battery, 60 is smoother)", listOf("30 fps", "60 fps"), if (s.fps >= 60) 1 else 0) { v ->
                    store.update { it.copy(fps = if (v == 1) 60 else 30) }
                }
                val hevc = Codecs.hasHardwareHevc
                SwitchRow("HEVC (sharper text)",
                    if (hevc) "Recommended. Turn off only if the picture glitches." else "This phone has no HEVC hardware decoder, so H.264 is used.",
                    s.useHEVC && hevc, enabled = hevc) { v -> store.update { it.copy(useHEVC = v) } }
                SwitchRow("Battery saver when Battery Saver is on", "Lower quality and 30 fps while the phone saves power",
                    s.autoSaverOnBatterySaver) { v -> store.update { it.copy(autoSaverOnBatterySaver = v) } }
                Segmented("Mac screen when its lid is closed", listOf("Big text", "More space", "Laptop size"), s.lidFit) { v ->
                    store.update { it.copy(lidFit = v) }
                }
            }

            Section("Control") {
                Segmented("Touch mode", InputMode.entries.map { it.label }, s.inputMode.ordinal) { v ->
                    store.update { it.copy(inputMode = InputMode.entries[v]) }
                }
                Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                    Text("Trackpad speed", style = MaterialTheme.typography.bodyLarge)
                    Slider(value = s.trackpadSpeed, onValueChange = { v -> store.update { it.copy(trackpadSpeed = v) } }, valueRange = 0.4f..2.5f)
                }
                SwitchRow("Reverse scrolling", null, s.reverseScroll) { v -> store.update { it.copy(reverseScroll = v) } }
                SwitchRow("Haptic feedback", null, s.haptics) { v -> store.update { it.copy(haptics = v) } }
                Hint(
                    "Trackpad: slide to move the pointer, tap to click, tap-then-slide to drag, two fingers to scroll or right-click (tap), pinch to zoom.\n" +
                        "Touch: tap where you want to click, long-press for right-click.\n" +
                        "Both: three-finger swipe changes Spaces / Mission Control; three-finger tap shows the keyboard. " +
                        "Press back twice to disconnect.",
                )
            }

            Section("While connected") {
                SwitchRow("Keep phone screen on", null, s.keepScreenOn) { v -> store.update { it.copy(keepScreenOn = v) } }
                SwitchRow("Copy Mac clipboard to phone automatically", null, s.clipboardSync) { v -> store.update { it.copy(clipboardSync = v) } }
            }

            Section("Security") {
                SwitchRow("Fingerprint or screen lock to connect", "Before a saved login is used (Android 11 and later)",
                    s.unlockToConnect) { v -> store.update { it.copy(unlockToConnect = v) } }
                Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Text("This phone's key", Modifier.weight(1f), style = MaterialTheme.typography.bodyLarge)
                    Text(store.identityFingerprint, fontFamily = FontFamily.Monospace, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Hint(
                    "Every session is end-to-end encrypted (X25519 + AES-256-GCM) directly between this phone and your Mac, with no server " +
                        "in between. The Mac only accepts phones it paired with. The saved login is encrypted with a key kept in this " +
                        "phone's secure hardware, and the app's data is excluded from backups.",
                )
            }

            Section("Connecting from anywhere") {
                Hint(
                    "Same Wi-Fi: found automatically.\n\n" +
                        "Different networks (mobile data, other Wi-Fi): install Tailscale on the Mac and this phone, sign in with the same " +
                        "account, and put the Mac's Tailscale name or 100.x address in the Mac's “Internet address”. Tailscale only helps " +
                        "the two devices find each other; the picture and your input still go straight between them, encrypted twice.",
                )
            }

            Text("PocketMac ${BuildConfig.VERSION_NAME}", style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 4.dp, bottom = 24.dp))
        }
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    SectionTitle(title)
    ElevatedCard(Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp)) {
        Column(Modifier.padding(vertical = 8.dp), content = content)
    }
}

@Composable
private fun SwitchRow(title: String, subtitle: String?, checked: Boolean, enabled: Boolean = true, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            if (subtitle != null) {
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Spacer(Modifier.width(12.dp))
        Switch(checked = checked, onCheckedChange = onChange, enabled = enabled)
    }
}

@Composable
private fun Segmented(title: String, options: List<String>, selected: Int, onSelect: (Int) -> Unit) {
    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.bodyLarge)
        SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
            options.forEachIndexed { i, label ->
                SegmentedButton(
                    selected = i == selected,
                    onClick = { onSelect(i) },
                    shape = SegmentedButtonDefaults.itemShape(index = i, count = options.size),
                    label = { Text(label, maxLines = 1, overflow = TextOverflow.Ellipsis, style = MaterialTheme.typography.labelMedium) },
                )
            }
        }
    }
}

@Composable
private fun Hint(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
}
