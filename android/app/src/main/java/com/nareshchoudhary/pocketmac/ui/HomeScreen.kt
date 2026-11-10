@file:OptIn(ExperimentalMaterial3Api::class)

package com.nareshchoudhary.pocketmac.ui

import android.text.format.DateUtils
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Add
import androidx.compose.material.icons.rounded.ChevronRight
import androidx.compose.material.icons.rounded.Delete
import androidx.compose.material.icons.rounded.Devices
import androidx.compose.material.icons.rounded.Edit
import androidx.compose.material.icons.rounded.Key
import androidx.compose.material.icons.rounded.LaptopMac
import androidx.compose.material.icons.rounded.MoreVert
import androidx.compose.material.icons.rounded.Settings
import androidx.compose.material.icons.rounded.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ElevatedCard
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LargeTopAppBar
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedCard
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.nareshchoudhary.pocketmac.AddMacForm
import com.nareshchoudhary.pocketmac.AppState
import com.nareshchoudhary.pocketmac.data.SavedMac
import com.nareshchoudhary.pocketmac.net.Discovery
import com.nareshchoudhary.pocketmac.proto.DeviceID

@Composable
fun HomeScreen(app: AppState, requestLocalNetwork: () -> Unit) {
    val store = app.store
    val scroll = TopAppBarDefaults.exitUntilCollapsedScrollBehavior()
    val found = app.discovery.found
    val nearby = found.values.filter { f -> store.macs.none { it.id == f.id } }.sortedBy { it.name }

    Scaffold(
        modifier = Modifier.nestedScroll(scroll.nestedScrollConnection),
        topBar = {
            LargeTopAppBar(
                title = { Text("PocketMac", fontWeight = FontWeight.SemiBold) },
                actions = {
                    IconButton(onClick = { app.showSettings = true }) { Icon(Icons.Rounded.Settings, "Settings") }
                },
                scrollBehavior = scroll,
            )
        },
        floatingActionButton = {
            ExtendedFloatingActionButton(
                onClick = { app.addForm = AddMacForm() },
                icon = { Icon(Icons.Rounded.Add, null) },
                text = { Text("Add Mac") },
            )
        },
    ) { padding ->
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(
                start = 16.dp, end = 16.dp,
                top = padding.calculateTopPadding() + 4.dp,
                bottom = padding.calculateBottomPadding() + 96.dp,
            ),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (app.localNetworkDenied) item("lan") { LocalNetworkCard(requestLocalNetwork) }
            if (store.macs.isEmpty()) item("welcome") { WelcomeCard() }
            if (store.macs.isNotEmpty()) {
                item("mine") { SectionTitle("My Macs") }
                items(store.macs, key = { it.id }) { mac -> MacCard(app, mac, nearby = found.containsKey(mac.id)) }
            }
            if (nearby.isNotEmpty()) {
                item("nearby") { SectionTitle("Nearby") }
                items(nearby, key = { "n-" + it.id }) { f -> NearbyCard(f) { app.addForm = AddMacForm(id = f.id, name = f.name) } }
            }
        }
    }
}

@Composable
fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.titleSmall,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 4.dp, top = 8.dp),
    )
}

@Composable
private fun WelcomeCard() {
    ElevatedCard(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(20.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(
                Modifier.size(56.dp).background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(16.dp)),
                contentAlignment = Alignment.Center,
            ) { Icon(Icons.Rounded.Devices, null, Modifier.size(32.dp), tint = MaterialTheme.colorScheme.onPrimaryContainer) }
            Text("Control your Mac from here", style = MaterialTheme.typography.titleLarge)
            Text(
                "1. Run PocketMac Host on the Mac and set a password.\n" +
                    "2. Tap Add Mac and enter the Mac's ID and password.\n" +
                    "3. On another network? Turn on Tailscale on both and add the Mac's Tailscale address.\n\n" +
                    "Already using PocketMac on an iPhone? On the Mac, click “Pair another phone” first.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun LocalNetworkCard(onAllow: () -> Unit) {
    OutlinedCard(Modifier.fillMaxWidth()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.Wifi, null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(14.dp))
            Text(
                "Allow local network access so PocketMac can find and reach your Mac on Wi-Fi.",
                style = MaterialTheme.typography.bodyMedium,
                modifier = Modifier.weight(1f),
            )
            Spacer(Modifier.width(8.dp))
            FilledTonalButton(onClick = onAllow) { Text("Allow") }
        }
    }
}

@Composable
private fun MacCard(app: AppState, mac: SavedMac, nearby: Boolean) {
    var menu by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    ElevatedCard(
        onClick = { app.connect(mac) },
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(20.dp),
    ) {
        Row(Modifier.padding(start = 16.dp, top = 14.dp, bottom = 14.dp, end = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(contentAlignment = Alignment.BottomEnd) {
                Box(
                    Modifier.size(48.dp).background(MaterialTheme.colorScheme.primaryContainer, RoundedCornerShape(14.dp)),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Rounded.LaptopMac, null, tint = MaterialTheme.colorScheme.onPrimaryContainer) }
                Box(
                    Modifier.size(12.dp).background(MaterialTheme.colorScheme.surface, CircleShape).padding(2.dp)
                        .background(if (nearby) Color(0xFF34C759) else Color.Gray.copy(alpha = 0.5f), CircleShape),
                )
            }
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(mac.name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                Text(mac.prettyID, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(subtitle(mac, nearby), style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
            }
            Box {
                IconButton(onClick = { menu = true }) { Icon(Icons.Rounded.MoreVert, "More") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Edit") }, leadingIcon = { Icon(Icons.Rounded.Edit, null) },
                        onClick = { menu = false; app.addForm = AddMacForm(editing = mac) })
                    if (app.store.hasCredential(mac.id)) {
                        DropdownMenuItem(text = { Text("Forget saved password") }, leadingIcon = { Icon(Icons.Rounded.Key, null) },
                            onClick = { menu = false; app.store.deleteCredential(mac.id) })
                    }
                    DropdownMenuItem(text = { Text("Delete") }, leadingIcon = { Icon(Icons.Rounded.Delete, null) },
                        onClick = { menu = false; confirmDelete = true })
                }
            }
        }
    }
    if (confirmDelete) {
        AlertDialog(
            onDismissRequest = { confirmDelete = false },
            title = { Text("Delete ${mac.name}?") },
            text = { Text("This removes the Mac and its saved login from this phone. You can add it again with its ID and password.") },
            confirmButton = { TextButton(onClick = { confirmDelete = false; app.store.remove(mac) }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
        )
    }
}

private fun subtitle(mac: SavedMac, nearby: Boolean): String {
    val parts = mutableListOf(
        when {
            nearby -> "Nearby"
            mac.internetAddress.isNotEmpty() -> "Via ${mac.internetAddress}"
            else -> "Not nearby"
        },
    )
    if (mac.lastConnected > 0) {
        parts += "used " + DateUtils.getRelativeTimeSpanString(mac.lastConnected, System.currentTimeMillis(), DateUtils.MINUTE_IN_MILLIS)
    }
    return parts.joinToString(" · ")
}

@Composable
private fun NearbyCard(f: Discovery.Found, onAdd: () -> Unit) {
    OutlinedCard(onClick = onAdd, modifier = Modifier.fillMaxWidth(), shape = RoundedCornerShape(20.dp),
        colors = CardDefaults.outlinedCardColors()) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Rounded.LaptopMac, null, tint = MaterialTheme.colorScheme.primary)
            Spacer(Modifier.width(14.dp))
            Column(Modifier.weight(1f)) {
                Text(f.name, style = MaterialTheme.typography.titleMedium, maxLines = 1)
                Text(DeviceID.pretty(f.id), style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Text("Add", color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelLarge)
            Icon(Icons.Rounded.ChevronRight, null, tint = MaterialTheme.colorScheme.primary)
        }
    }
}
