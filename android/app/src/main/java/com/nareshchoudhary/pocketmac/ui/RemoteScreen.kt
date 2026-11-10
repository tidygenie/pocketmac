@file:OptIn(ExperimentalLayoutApi::class)

package com.nareshchoudhary.pocketmac.ui

import android.app.Activity
import android.content.Context
import android.content.ContextWrapper
import android.os.SystemClock
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.WindowInsetsSides
import androidx.compose.foundation.layout.displayCutout
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.only
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.rounded.VolumeDown
import androidx.compose.material.icons.automirrored.rounded.VolumeOff
import androidx.compose.material.icons.automirrored.rounded.VolumeUp
import androidx.compose.material.icons.rounded.Bedtime
import androidx.compose.material.icons.rounded.Bolt
import androidx.compose.material.icons.rounded.Cancel
import androidx.compose.material.icons.rounded.Check
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.ContentPaste
import androidx.compose.material.icons.rounded.Dashboard
import androidx.compose.material.icons.rounded.DesktopWindows
import androidx.compose.material.icons.rounded.Download
import androidx.compose.material.icons.rounded.FitScreen
import androidx.compose.material.icons.rounded.Keyboard
import androidx.compose.material.icons.rounded.KeyboardArrowDown
import androidx.compose.material.icons.rounded.KeyboardArrowUp
import androidx.compose.material.icons.rounded.KeyboardHide
import androidx.compose.material.icons.rounded.Laptop
import androidx.compose.material.icons.rounded.Lock
import androidx.compose.material.icons.rounded.Mouse
import androidx.compose.material.icons.rounded.NightsStay
import androidx.compose.material.icons.rounded.PlayArrow
import androidx.compose.material.icons.rounded.PowerSettingsNew
import androidx.compose.material.icons.rounded.Screenshot
import androidx.compose.material.icons.rounded.Search
import androidx.compose.material.icons.rounded.SkipNext
import androidx.compose.material.icons.rounded.SkipPrevious
import androidx.compose.material.icons.rounded.Tab
import androidx.compose.material.icons.rounded.TouchApp
import androidx.compose.material.icons.rounded.Tune
import androidx.compose.material.icons.rounded.Upload
import androidx.compose.material.icons.rounded.Warning
import androidx.compose.material.icons.rounded.WbSunny
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.nareshchoudhary.pocketmac.AppState
import com.nareshchoudhary.pocketmac.RemoteSession
import com.nareshchoudhary.pocketmac.data.InputMode
import com.nareshchoudhary.pocketmac.proto.ClientMessage
import com.nareshchoudhary.pocketmac.proto.QuickAction
import com.nareshchoudhary.pocketmac.proto.StreamQuality
import com.nareshchoudhary.pocketmac.remote.KeyMap
import com.nareshchoudhary.pocketmac.remote.ModifierFlag
import com.nareshchoudhary.pocketmac.remote.RemoteView

private val Glass = Color(0xD91C1C1E)

fun Context.findActivity(): Activity? {
    var c: Context = this
    while (c is ContextWrapper) {
        if (c is Activity) return c
        c = c.baseContext
    }
    return null
}

@Composable
fun RemoteScreen(app: AppState, session: RemoteSession) = RemoteTheme {
    val density = LocalDensity.current
    val imeVisible = WindowInsets.isImeVisible
    val imeBottom = WindowInsets.ime.getBottom(density)
    val barPx = with(density) { 52.dp.roundToPx() }
    var remoteView by remember { mutableStateOf<RemoteView?>(null) }
    var lastBack by remember { mutableLongStateOf(0L) }

    // Full screen while the Mac is shown; a swipe from the edge brings the bars back briefly.
    val view = LocalView.current
    DisposableEffect(Unit) {
        val window = view.context.findActivity()?.window
        val ctl = window?.let { WindowCompat.getInsetsController(it, view) }
        ctl?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        ctl?.hide(WindowInsetsCompat.Type.systemBars())
        onDispose { ctl?.show(WindowInsetsCompat.Type.systemBars()) }
    }
    LaunchedEffect(imeVisible) { if (!imeVisible) session.keyboardVisible = false }

    // Back hides the keyboard; twice in a row disconnects (a stray edge swipe must not lock the Mac).
    BackHandler {
        val now = SystemClock.uptimeMillis()
        when {
            session.keyboardVisible -> remoteView?.setKeyboard(false)
            !session.isConnected || now - lastBack < 2000 -> app.closeSession()
            else -> {
                lastBack = now
                session.showToast("Press back again to disconnect")
            }
        }
    }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        AndroidView(
            factory = { ctx -> RemoteView(ctx, session).also { session.view = it; remoteView = it } },
            modifier = Modifier.fillMaxSize(),
            update = { v ->
                v.setKeyboardOverlap(if (imeVisible) imeBottom + barPx else 0)
                v.keepScreenOn = session.settings.keepScreenOn && session.isConnected
            },
            onRelease = { v -> if (session.view === v) session.view = null },
        )

        when (val p = session.phase) {
            is RemoteSession.Phase.Connecting -> OverlayCard {
                CircularProgressIndicator()
                Text(p.text, textAlign = TextAlign.Center)
                OutlinedButton(onClick = { app.closeSession() }) { Text("Cancel") }
            }
            is RemoteSession.Phase.NeedsPassword -> PasswordCard(app, session, p.message)
            is RemoteSession.Phase.Failed -> OverlayCard {
                Icon(Icons.Rounded.Warning, null, Modifier.size(40.dp), tint = Color(0xFFFFC233))
                Text(p.message, textAlign = TextAlign.Center)
                Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                    OutlinedButton(onClick = { app.closeSession() }) { Text("Close") }
                    Button(onClick = { session.retry() }) { Text("Try again") }
                }
            }
            RemoteSession.Phase.Connected -> Toolbar(app, session, remoteView)
        }

        Toast(session.toast, Modifier.align(Alignment.TopCenter).padding(top = 64.dp, start = 24.dp, end = 24.dp))

        if (session.keyboardVisible && imeVisible) {
            KeyboardBar(session, onHide = { remoteView?.setKeyboard(false) },
                modifier = Modifier.align(Alignment.BottomCenter).windowInsetsPadding(WindowInsets.ime))
        }
    }
}

@Composable
private fun OverlayCard(content: @Composable () -> Unit) {
    Box(Modifier.fillMaxSize().imePadding().padding(16.dp), contentAlignment = Alignment.Center) {
        Surface(shape = RoundedCornerShape(28.dp), color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.96f),
            modifier = Modifier.widthIn(max = 440.dp)) {
            Column(Modifier.padding(24.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                content()
            }
        }
    }
}

@Composable
private fun PasswordCard(app: AppState, session: RemoteSession, message: String?) {
    var password by remember { mutableStateOf("") }
    val focus = remember { FocusRequester() }
    fun submit() {
        if (password.isNotEmpty()) session.submitPassword(password.also { password = "" })
    }
    OverlayCard {
        Icon(Icons.Rounded.Lock, null, Modifier.size(36.dp), tint = MaterialTheme.colorScheme.primary)
        Text(session.mac.name, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
        if (message != null) Text(message, color = Color(0xFFFFA94D), textAlign = TextAlign.Center)
        OutlinedTextField(
            value = password,
            onValueChange = { password = it },
            label = { Text("Mac host password") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.Go),
            keyboardActions = KeyboardActions(onGo = { submit() }),
            modifier = Modifier.fillMaxWidth().focusRequester(focus),
        )
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            Text("Remember login", Modifier.weight(1f))
            Switch(checked = session.rememberPassword, onCheckedChange = { session.rememberPassword = it })
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(onClick = { app.closeSession() }) { Text("Cancel") }
            Button(onClick = ::submit, enabled = password.isNotEmpty()) { Text("Connect") }
        }
    }
    LaunchedEffect(Unit) { runCatching { focus.requestFocus() } }
}

@Composable
private fun Toast(text: String?, modifier: Modifier) {
    var last by remember { mutableStateOf("") }
    if (text != null) last = text
    AnimatedVisibility(text != null, modifier, enter = fadeIn(tween(150)), exit = fadeOut(tween(250))) {
        Surface(shape = RoundedCornerShape(50), color = Glass, contentColor = Color.White) {
            Text(last, Modifier.padding(horizontal = 16.dp, vertical = 9.dp), textAlign = TextAlign.Center,
                style = MaterialTheme.typography.bodyMedium)
        }
    }
}

// MARK: Toolbar

@Composable
private fun Toolbar(app: AppState, session: RemoteSession, remoteView: RemoteView?) {
    BoxWithConstraints(
        Modifier.fillMaxWidth().windowInsetsPadding(WindowInsets.displayCutout.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal))
            .padding(top = 6.dp),
        contentAlignment = Alignment.TopCenter,
    ) {
        val narrow = maxWidth < 520.dp
        AnimatedContent(session.toolbarOpen, transitionSpec = { fadeIn(tween(160)) togetherWith fadeOut(tween(120)) }, label = "toolbar") { open ->
            if (open) {
                Surface(shape = CircleShape, color = Glass, contentColor = Color.White, shadowElevation = 6.dp) {
                    Row(Modifier.padding(horizontal = 4.dp, vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
                        ToolButton(Icons.Rounded.KeyboardArrowUp, "Hide toolbar") { session.toolbarOpen = false }
                        ToolButton(if (session.keyboardVisible) Icons.Rounded.KeyboardHide else Icons.Rounded.Keyboard, "Keyboard") {
                            remoteView?.toggleKeyboard()
                        }
                        val trackpad = session.settings.inputMode == InputMode.TRACKPAD
                        ToolButton(if (trackpad) Icons.Rounded.Mouse else Icons.Rounded.TouchApp, "Touch mode") {
                            val next = if (trackpad) InputMode.TOUCH else InputMode.TRACKPAD
                            app.store.update { it.copy(inputMode = next) }
                            session.showToast("${next.label} mode")
                        }
                        ActionsMenu(session)
                        ClipboardMenu(session)
                        StreamMenu(app, session)
                        if (session.zoomed) ToolButton(Icons.Rounded.FitScreen, "Reset zoom") { remoteView?.resetZoom() }
                        if (!narrow) StatusText(session)
                        ToolButton(Icons.Rounded.Close, "Disconnect") { app.closeSession() }
                    }
                }
            } else {
                Surface(onClick = { session.toolbarOpen = true }, shape = CircleShape, color = Glass.copy(alpha = 0.6f), contentColor = Color.White) {
                    Icon(Icons.Rounded.KeyboardArrowDown, "Show toolbar", Modifier.padding(horizontal = 14.dp, vertical = 1.dp).size(20.dp))
                }
            }
        }
    }
}

@Composable
private fun ToolButton(icon: ImageVector, description: String, onClick: () -> Unit) {
    IconButton(onClick = onClick, modifier = Modifier.size(40.dp)) { Icon(icon, description, Modifier.size(20.dp)) }
}

private fun statusLine(session: RemoteSession): String {
    val parts = mutableListOf<String>()
    session.status?.let { if (it.battery >= 0) parts += (if (it.charging || it.onAC) "⚡" else "") + "${it.battery}%" }
    if (session.rttMs >= 0) parts += "${session.rttMs} ms"
    parts += "${session.fps} fps"
    return parts.joinToString(" · ")
}

@Composable
private fun StatusText(session: RemoteSession) {
    Text(statusLine(session), fontSize = 11.sp, fontFamily = FontFamily.Monospace, color = Color.White.copy(alpha = 0.75f),
        maxLines = 1, modifier = Modifier.padding(horizontal = 6.dp))
}

@Composable
private fun MenuButton(icon: ImageVector, description: String, content: @Composable (close: () -> Unit) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        ToolButton(icon, description) { open = true }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) { content { open = false } }
    }
}

@Composable
private fun MenuHeader(text: String) {
    Text(text, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 10.dp, bottom = 4.dp))
}

@Composable
private fun MenuItem(text: String, icon: ImageVector?, checked: Boolean = false, onClick: () -> Unit) {
    val iv = if (checked) Icons.Rounded.Check else icon
    DropdownMenuItem(
        text = { Text(text) },
        leadingIcon = { if (iv != null) Icon(iv, null) else Spacer(Modifier.size(24.dp)) },
        onClick = onClick,
    )
}

@Composable
private fun ActionsMenu(session: RemoteSession) = MenuButton(Icons.Rounded.Bolt, "Mac actions") { close ->
    fun act(a: QuickAction) {
        session.send(ClientMessage.Action(a))
        close()
    }
    MenuHeader("Mac")
    MenuItem("Spotlight", Icons.Rounded.Search) { act(QuickAction.SPOTLIGHT) }
    MenuItem("Mission Control", Icons.Rounded.Dashboard) { act(QuickAction.MISSION_CONTROL) }
    MenuItem("Switch app (⌘Tab)", Icons.Rounded.Tab) { act(QuickAction.APP_SWITCHER) }
    MenuItem("Show desktop", Icons.Rounded.DesktopWindows) { act(QuickAction.SHOW_DESKTOP) }
    MenuItem("Screenshot to Desktop", Icons.Rounded.Screenshot) { act(QuickAction.SCREENSHOT) }
    MenuItem("Force quit…", Icons.Rounded.Cancel) { act(QuickAction.FORCE_QUIT) }
    HorizontalDivider()
    MenuHeader("Media")
    MenuItem("Play / Pause", Icons.Rounded.PlayArrow) { act(QuickAction.PLAY_PAUSE) }
    MenuItem("Next", Icons.Rounded.SkipNext) { act(QuickAction.NEXT_TRACK) }
    MenuItem("Previous", Icons.Rounded.SkipPrevious) { act(QuickAction.PREVIOUS_TRACK) }
    MenuItem("Volume up", Icons.AutoMirrored.Rounded.VolumeUp) { act(QuickAction.VOLUME_UP) }
    MenuItem("Volume down", Icons.AutoMirrored.Rounded.VolumeDown) { act(QuickAction.VOLUME_DOWN) }
    MenuItem("Mute", Icons.AutoMirrored.Rounded.VolumeOff) { act(QuickAction.MUTE) }
    HorizontalDivider()
    MenuHeader("Power")
    MenuItem("Wake screen", Icons.Rounded.WbSunny) { act(QuickAction.WAKE_DISPLAY) }
    MenuItem("Turn off screen", Icons.Rounded.Bedtime) { act(QuickAction.SLEEP_DISPLAY) }
    MenuItem("Lock Mac", Icons.Rounded.Lock) { act(QuickAction.LOCK_SCREEN) }
    session.status?.let { s ->
        if (s.lidMode) MenuItem("Allow sleep with lid closed", Icons.Rounded.NightsStay) { act(QuickAction.LID_MODE_OFF) }
        else MenuItem("Keep awake with lid closed", Icons.Rounded.Laptop) { act(QuickAction.LID_MODE_ON) }
    }
    MenuItem("Sleep Mac", Icons.Rounded.PowerSettingsNew) { act(QuickAction.SLEEP_MAC) }
}

@Composable
private fun ClipboardMenu(session: RemoteSession) = MenuButton(Icons.Rounded.ContentPaste, "Clipboard") { close ->
    MenuItem("Send phone clipboard to Mac", Icons.Rounded.Upload) { close(); session.sendClipboardToMac(andPaste = false) }
    MenuItem("Paste phone clipboard on Mac", Icons.Rounded.ContentPaste) { close(); session.sendClipboardToMac(andPaste = true) }
    session.lastMacClipboard?.let { t ->
        MenuItem("Copy Mac clipboard: “${t.take(30)}”", Icons.Rounded.Download) { close(); session.copyMacClipboard() }
    }
}

@Composable
private fun StreamMenu(app: AppState, session: RemoteSession) = MenuButton(Icons.Rounded.Tune, "Picture") { _ ->
    val s = app.store.settings
    fun change(transform: (com.nareshchoudhary.pocketmac.data.ClientSettings) -> com.nareshchoudhary.pocketmac.data.ClientSettings) {
        app.store.update(transform)
        session.updateStream()
    }
    Text(statusLine(session) + " · ${session.kbps} kbps", fontSize = 11.sp, fontFamily = FontFamily.Monospace,
        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp, vertical = 6.dp))
    HorizontalDivider()
    MenuHeader("Quality")
    StreamQuality.entries.forEach { q -> MenuItem(q.label, null, checked = s.quality == q.raw) { change { it.copy(quality = q.raw) } } }
    MenuHeader("Frame rate")
    MenuItem("30 fps (saves battery)", null, checked = s.fps < 60) { change { it.copy(fps = 30) } }
    MenuItem("60 fps (smoother)", null, checked = s.fps >= 60) { change { it.copy(fps = 60) } }
    MenuHeader("Mac screen when its lid is closed")
    listOf("Fit phone (big text)", "Fit phone (more space)", "Laptop size").forEachIndexed { i, label ->
        MenuItem(label, null, checked = s.lidFit == i) { change { it.copy(lidFit = i) } }
    }
}

// MARK: Keyboard bar

@Composable
private fun KeyboardBar(session: RemoteSession, onHide: () -> Unit, modifier: Modifier) {
    Surface(modifier.fillMaxWidth(), color = Color(0xFF1C1C1E), contentColor = Color.White) {
        Row(
            Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 8.dp, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            KeyChip(onClick = onHide) { Icon(Icons.Rounded.KeyboardHide, "Hide keyboard", Modifier.size(20.dp)) }
            fun key(code: Int, flags: Int = 0) {
                session.sendCombo(code, flags or session.activeModifiers)
                session.clearOneShot()
            }
            KeyText("esc") { key(KeyMap.ESCAPE) }
            KeyText("tab") { key(KeyMap.TAB) }
            for ((title, flag) in listOf("⌘" to ModifierFlag.COMMAND, "⌥" to ModifierFlag.OPTION, "⌃" to ModifierFlag.CONTROL, "⇧" to ModifierFlag.SHIFT)) {
                val color = when {
                    session.locked and flag != 0 -> Color(0xFF0A84FF)
                    session.oneShot and flag != 0 -> Color(0xFFFF9F0A)
                    else -> Color(0xFF3A3A3C)
                }
                KeyText(title, color) { session.tapModifier(flag) }
            }
            KeyText("←") { key(KeyMap.LEFT) }
            KeyText("↑") { key(KeyMap.UP) }
            KeyText("↓") { key(KeyMap.DOWN) }
            KeyText("→") { key(KeyMap.RIGHT) }
            KeyText("⌦") { key(KeyMap.FORWARD_DELETE) }
            val cmd = ModifierFlag.COMMAND
            listOf("⌘C" to 8, "⌘V" to 9, "⌘X" to 7, "⌘Z" to 6, "⌘A" to 0, "⌘F" to 3, "⌘S" to 1, "⌘W" to 13, "⌘T" to 17).forEach { (t, c) ->
                KeyText(t) { key(c, cmd) }
            }
            KeyText("⌘Tab") { key(KeyMap.TAB, cmd) }
            KeyText("⌘Space") { key(KeyMap.SPACE, cmd) }
            KeyText("home") { key(KeyMap.HOME) }
            KeyText("end") { key(KeyMap.END) }
            KeyText("pg↑") { key(KeyMap.PAGE_UP) }
            KeyText("pg↓") { key(KeyMap.PAGE_DOWN) }
            KeyMap.FUNCTION_KEYS.forEachIndexed { i, c -> KeyText("F${i + 1}") { key(c) } }
            Spacer(Modifier.width(4.dp))
        }
    }
}

@Composable
private fun KeyChip(color: Color = Color(0xFF3A3A3C), onClick: () -> Unit, content: @Composable () -> Unit) {
    Surface(onClick = onClick, shape = RoundedCornerShape(9.dp), color = color, contentColor = Color.White) {
        Box(Modifier.padding(horizontal = 12.dp, vertical = 8.dp), contentAlignment = Alignment.Center) { content() }
    }
}

@Composable
private fun KeyText(title: String, color: Color = Color(0xFF3A3A3C), onClick: () -> Unit) =
    KeyChip(color, onClick) { Text(title, fontSize = 15.sp, fontWeight = FontWeight.Medium) }
