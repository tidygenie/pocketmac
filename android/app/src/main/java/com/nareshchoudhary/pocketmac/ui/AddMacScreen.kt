@file:OptIn(ExperimentalMaterial3Api::class)

package com.nareshchoudhary.pocketmac.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material.icons.rounded.Visibility
import androidx.compose.material.icons.rounded.VisibilityOff
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import com.nareshchoudhary.pocketmac.AddMacForm
import com.nareshchoudhary.pocketmac.AppState

@Composable
fun AddMacScreen(app: AppState, form: AddMacForm) {
    val editing = form.editing != null
    val canSave = form.idValid && (editing || form.password.isNotEmpty())
    BackHandler { app.addForm = null }

    fun save() {
        if (!canSave) return
        val mac = form.makeMac()
        app.store.upsert(mac)
        val pw = form.password
        app.addForm = null
        if (!editing || pw.isNotEmpty()) {
            if (pw.isNotEmpty()) app.store.deleteCredential(mac.id)
            app.connect(mac, pw.ifEmpty { null }, form.remember)
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(if (editing) "Edit Mac" else "Add Mac") },
                navigationIcon = { IconButton(onClick = { app.addForm = null }) { Icon(Icons.Rounded.Close, "Cancel") } },
                actions = { TextButton(onClick = ::save, enabled = canSave) { Text(if (editing) "Save" else "Connect") } },
            )
        },
    ) { padding ->
        Column(
            Modifier.fillMaxSize().padding(padding).imePadding().verticalScroll(rememberScrollState()).padding(horizontal = 20.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            OutlinedTextField(
                value = form.macID,
                onValueChange = { form.macID = it.uppercase() },
                label = { Text("Mac ID") },
                placeholder = { Text("XXXX-XXXX-XXXX") },
                singleLine = true,
                textStyle = TextStyle(fontFamily = FontFamily.Monospace),
                isError = form.macID.isNotEmpty() && !form.idValid,
                supportingText = {
                    Text(
                        if (form.macID.isNotEmpty() && !form.idValid) "The ID has 12 letters and numbers. It's shown in PocketMac Host on the Mac."
                        else "The ID is the fingerprint of the Mac's key: the app refuses any Mac that doesn't match it.",
                    )
                },
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Characters, autoCorrectEnabled = false,
                    keyboardType = KeyboardType.Ascii, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )

            var showPassword by remember { mutableStateOf(false) }
            OutlinedTextField(
                value = form.password,
                onValueChange = { form.password = it },
                label = { Text("Password") },
                placeholder = { Text(if (editing) "Leave empty to keep the saved login" else "Mac host password") },
                singleLine = true,
                visualTransformation = if (showPassword) VisualTransformation.None else PasswordVisualTransformation(),
                trailingIcon = {
                    IconButton(onClick = { showPassword = !showPassword }) {
                        Icon(if (showPassword) Icons.Rounded.VisibilityOff else Icons.Rounded.Visibility,
                            if (showPassword) "Hide password" else "Show password")
                    }
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Remember login", style = MaterialTheme.typography.bodyLarge)
                    Text("Saved encrypted on this phone; unlocked with your fingerprint or screen lock",
                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                Spacer(Modifier.width(12.dp))
                Switch(checked = form.remember, onCheckedChange = { form.remember = it })
            }

            OutlinedTextField(
                value = form.name,
                onValueChange = { form.name = it },
                label = { Text("Name (optional)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.Words, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )

            Text("For other networks", style = MaterialTheme.typography.titleSmall, color = MaterialTheme.colorScheme.primary)
            OutlinedTextField(
                value = form.address,
                onValueChange = { form.address = it.trim() },
                label = { Text("Internet address (optional)") },
                placeholder = { Text("e.g. macbook-air or 100.101.102.103") },
                singleLine = true,
                supportingText = {
                    Text("Leave empty if you only use it on the same Wi-Fi. For anywhere access, install Tailscale on the Mac and this phone " +
                        "(same account) and enter the Mac's Tailscale name or 100.x address shown in PocketMac Host.")
                },
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri, autoCorrectEnabled = false, imeAction = ImeAction.Next),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = form.port,
                onValueChange = { v -> form.port = v.filter(Char::isDigit).take(5) },
                label = { Text("Port") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, imeAction = ImeAction.Done),
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}
