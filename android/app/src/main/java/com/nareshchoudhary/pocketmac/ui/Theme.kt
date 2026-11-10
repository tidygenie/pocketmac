package com.nareshchoudhary.pocketmac.ui

import android.os.Build
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.dynamicDarkColorScheme
import androidx.compose.material3.dynamicLightColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext

private val Light = lightColorScheme(
    primary = Color(0xFF3354D9),
    onPrimary = Color.White,
    primaryContainer = Color(0xFFDDE3FF),
    onPrimaryContainer = Color(0xFF0B1A5E),
    secondary = Color(0xFF1C9DBB),
    background = Color(0xFFF7F8FC),
    surface = Color(0xFFF7F8FC),
)

private val Dark = darkColorScheme(
    primary = Color(0xFF9DB2FF),
    onPrimary = Color(0xFF0B1A5E),
    primaryContainer = Color(0xFF233A9E),
    onPrimaryContainer = Color(0xFFDDE3FF),
    secondary = Color(0xFF6FD3EC),
    background = Color(0xFF0F1117),
    surface = Color(0xFF0F1117),
)

/** Material You colours from the wallpaper on Android 12+, PocketMac blue otherwise. */
@Composable
fun PocketMacTheme(dark: Boolean = isSystemInDarkTheme(), content: @Composable () -> Unit) {
    val ctx = LocalContext.current
    val scheme = when {
        Build.VERSION.SDK_INT >= 31 -> if (dark) dynamicDarkColorScheme(ctx) else dynamicLightColorScheme(ctx)
        dark -> Dark
        else -> Light
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

/** The remote screen is always dark, whatever the system theme. */
@Composable
fun RemoteTheme(content: @Composable () -> Unit) = PocketMacTheme(dark = true, content = content)
