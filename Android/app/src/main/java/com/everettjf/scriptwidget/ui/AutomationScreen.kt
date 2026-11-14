package com.everettjf.scriptwidget.ui

import android.content.ClipData
import android.content.ClipDescription
import android.content.ClipboardManager
import android.os.PersistableBundle
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.actions.ActionRunner
import com.everettjf.scriptwidget.automation.AutomationReceiver
import com.everettjf.scriptwidget.automation.AutomationStore
import com.everettjf.scriptwidget.core.surfaces.Automation
import com.everettjf.scriptwidget.core.surfaces.PackageSurfaces
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Copies text that must not show up in clipboard previews or sync to other devices. */
private fun copySecret(context: android.content.Context, text: String) {
    val clip = ClipData.newPlainText("ScriptWidget automation token", text)
    clip.description.extras = PersistableBundle().apply { putBoolean(ClipDescription.EXTRA_IS_SENSITIVE, true) }
    context.getSystemService(ClipboardManager::class.java)?.setPrimaryClip(clip)
}

/**
 * Lets the user open the automation entry point: turn it on, copy the token
 * a sender needs, and choose which packages other apps may run.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AutomationScreen(navigation: NavController) {
    val context = LocalContext.current
    val store = remember { AutomationStore(context.applicationContext) }
    var revision by remember { mutableIntStateOf(0) }
    var enabled by remember { mutableStateOf(store.enabled) }
    var token by remember { mutableStateOf(store.token) }
    var allowed by remember { mutableStateOf(store.allowedPackages()) }
    var packages by remember { mutableStateOf<List<Pair<InstalledPackage, PackageSurfaces?>>?>(null) }
    var confirmRenew by remember { mutableStateOf(false) }
    LaunchedEffect(revision) {
        packages = withContext(Dispatchers.IO) { runCatching { AppServices.library.list().map { it to ActionRunner.declared(it) } }.getOrDefault(emptyList()) }
        allowed = store.allowedPackages()
    }
    val applicationId = context.packageName

    Scaffold(topBar = {
        TopAppBar(title = { Text("Automation") }, navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            Text(
                "Let Tasker, MacroDroid and similar apps run a widget's declared actions or redraw its widgets, for example when you arrive home or connect a charger. " +
                    "Off by default. Other apps can only pick an action a widget declares in widget.json.",
                style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(16.dp),
            )
            ListItem(
                headlineContent = { Text("Allow other apps to run actions") },
                supportingContent = { Text(if (enabled) "On. A request also needs the token and an allowed package." else "Off. Every request is ignored.") },
                trailingContent = { Switch(enabled, onCheckedChange = { store.enabled = it; enabled = it; token = store.token }) },
            )
            if (enabled) {
                AutomationSection("Token")
                ListItem(
                    headlineContent = { Text(token?.let { "••••••••" + it.takeLast(4) } ?: "No token", fontFamily = FontFamily.Monospace) },
                    supportingContent = { Text("Every request must include it. Give it only to automation apps you trust; any app that knows it can run the allowed packages.") },
                    trailingContent = {
                        Row {
                            TextButton(onClick = { token?.let { copySecret(context, it); Toast.makeText(context, "Token copied", Toast.LENGTH_SHORT).show() } }) { Text("Copy") }
                            TextButton(onClick = { confirmRenew = true }) { Text("New") }
                        }
                    },
                )

                AutomationSection("Packages other apps may run")
                val current = packages
                val withActions = current?.filter { (_, surfaces) -> surfaces != null && surfaces.actions.isNotEmpty() }.orEmpty()
                if (current == null) Text("Loading…", Modifier.padding(16.dp))
                else if (withActions.isEmpty()) ListItem(
                    headlineContent = { Text("No installed widget declares actions") },
                    supportingContent = { Text("Add an actions list to a widget's widget.json, or add the Automation Counter template.") },
                )
                for ((installed, surfaces) in withActions) ListItem(
                    headlineContent = { Text(installed.name) },
                    supportingContent = { Text("Actions: " + surfaces!!.actions.joinToString(", ") { it.id }) },
                    trailingContent = {
                        Switch(installed.installation in allowed, onCheckedChange = { store.setAllowed(installed.installation, it); revision += 1 })
                    },
                )

                AutomationSection("How to send a request")
                Text(
                    "Send a broadcast to this app. In Tasker: Send Intent, target Broadcast Receiver.",
                    style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp),
                )
                for ((label, value) in listOf(
                    "Package" to applicationId,
                    "Class" to AutomationReceiver::class.java.name,
                    "Action, to run an action" to applicationId + Automation.ACTION_RUN,
                    "Action, to redraw widgets" to applicationId + Automation.ACTION_REFRESH,
                    "Extras (text)" to "package: the name under Packages above\naction: one of its actions\ntoken: the token\nvalue: true or false (optional)",
                )) ListItem(overlineContent = { Text(label) }, headlineContent = { Text(value, fontFamily = FontFamily.Monospace, style = MaterialTheme.typography.bodySmall) })
                Text(
                    "At most 30 requests a minute are accepted. A redraw without a package redraws every allowed package.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp),
                )
            }
        }
    }

    if (confirmRenew) AlertDialog(
        onDismissRequest = { confirmRenew = false },
        title = { Text("Create a new token?") },
        text = { Text("Tasks that use the current token stop working until you give them the new one.") },
        confirmButton = { TextButton(onClick = { token = store.renewToken(); confirmRenew = false }) { Text("Create") } },
        dismissButton = { TextButton(onClick = { confirmRenew = false }) { Text("Cancel") } },
    )
}

@Composable
private fun AutomationSection(title: String) {
    HorizontalDivider()
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
}
