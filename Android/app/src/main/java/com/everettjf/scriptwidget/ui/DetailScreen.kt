package com.everettjf.scriptwidget.ui

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.core.PlatformSupport
import com.everettjf.scriptwidget.core.runtime.ExecutionResult
import com.everettjf.scriptwidget.widget.LargeWidgetProvider
import com.everettjf.scriptwidget.widget.MediumWidgetProvider
import com.everettjf.scriptwidget.widget.SmallWidgetProvider
import com.everettjf.scriptwidget.widget.WidgetBinding
import com.everettjf.scriptwidget.widget.WidgetScheduler

/** Binds a widget the launcher just pinned from the detail screen. */
class WidgetPinnedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        AppServices.attach(context.applicationContext)
        val appWidgetId = intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, AppWidgetManager.INVALID_APPWIDGET_ID)
        val installation = intent.getStringExtra(EXTRA_INSTALLATION) ?: return
        if (appWidgetId == AppWidgetManager.INVALID_APPWIDGET_ID) return
        AppServices.widgets.set(appWidgetId, WidgetBinding(installation, intent.getStringExtra(EXTRA_PARAMETER).orEmpty()))
        WidgetScheduler.refresh(context, intArrayOf(appWidgetId))
    }

    companion object {
        const val EXTRA_INSTALLATION = "installation"
        const val EXTRA_PARAMETER = "parameter"
    }
}

/** Asks the launcher to place a widget of [family] that shows [installed]. */
fun pinWidget(context: Context, installed: InstalledPackage, family: String, parameter: String): Boolean {
    val manager = AppWidgetManager.getInstance(context)
    if (!manager.isRequestPinAppWidgetSupported) return false
    val provider = when (family) { "small" -> SmallWidgetProvider::class.java; "large" -> LargeWidgetProvider::class.java; else -> MediumWidgetProvider::class.java }
    // The configuration screen may also open; it binds the same package without asking.
    AppServices.widgets.rememberPendingPin(installed.installation, parameter)
    val callback = Intent(context, WidgetPinnedReceiver::class.java)
        .setData(Uri.parse("scriptwidget-pin://${installed.installation}/${System.currentTimeMillis()}"))
        .putExtra(WidgetPinnedReceiver.EXTRA_INSTALLATION, installed.installation)
        .putExtra(WidgetPinnedReceiver.EXTRA_PARAMETER, parameter)
    val pending = PendingIntent.getBroadcast(context, 0, callback, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE)
    return manager.requestPinAppWidget(ComponentName(context, provider), null, pending)
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun DetailScreen(navigation: NavController, name: String) {
    val context = LocalContext.current
    var installed by remember { mutableStateOf(AppServices.library.find(name)) }
    val item = installed
    if (item == null) { Text("This widget is no longer installed.", Modifier.padding(32.dp)); return }

    var family by remember { mutableStateOf("medium") }
    var dark by remember { mutableStateOf<Boolean?>(null) }
    var parameter by remember { mutableStateOf("") }
    var revision by remember { mutableIntStateOf(0) }
    var result by remember { mutableStateOf<ExecutionResult?>(null) }
    var menu by remember { mutableStateOf(false) }
    var rename by remember { mutableStateOf(false) }
    var confirmDelete by remember { mutableStateOf(false) }
    val useDark = dark ?: isSystemInDarkTheme()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { installed = AppServices.library.find(name); revision += 1 }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        if (uri != null) runCatching { context.contentResolver.openOutputStream(uri)?.use { AppServices.library.exportArchive(item.name, it) } }
            .onFailure { Toast.makeText(context, it.message ?: "Export failed", Toast.LENGTH_LONG).show() }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text(item.displayName, maxLines = 1) },
            navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = {
                IconButton(onClick = { menu = true }) { Icon(Icons.Default.MoreVert, "More") }
                DropdownMenu(menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("Rename") }, onClick = { menu = false; rename = true })
                    DropdownMenuItem(text = { Text("Duplicate") }, onClick = {
                        menu = false
                        runCatching { AppServices.library.duplicate(item.name) }.onSuccess { navigation.navigate("package/${Uri.encode(it.name)}") { popUpTo("home") } }
                            .onFailure { Toast.makeText(context, it.message ?: "Could not duplicate", Toast.LENGTH_LONG).show() }
                    })
                    DropdownMenuItem(text = { Text("Export .swt") }, onClick = { menu = false; exporter.launch("${item.name}.swt") })
                    DropdownMenuItem(text = { Text("Improve with AI") }, onClick = { menu = false; navigation.navigate("ai/${Uri.encode(item.name)}") })
                    DropdownMenuItem(text = { Text("Delete") }, onClick = { menu = false; confirmDelete = true })
                }
            },
        )
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            WidgetPreview(item.files, item.installation, family, useDark, parameter = parameter, buildDirectory = item.buildDirectory, revision = revision) { result = it }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for (size in listOf("small", "medium", "large")) FilterChip(selected = family == size, onClick = { family = size }, label = { Text(size.replaceFirstChar { it.uppercase() }) })
                FilterChip(selected = useDark, onClick = { dark = !useDark }, label = { Text("Dark") })
            }
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Button(onClick = { navigation.navigate("editor/${Uri.encode(item.name)}") }, modifier = Modifier.weight(1f)) { Text("Edit code") }
                OutlinedButton(onClick = {
                    if (!pinWidget(context, item, family, parameter)) Toast.makeText(context, "Long-press the home screen, choose Widgets, then ScriptWidget.", Toast.LENGTH_LONG).show()
                }, modifier = Modifier.weight(1f)) { Text("Add to home screen") }
            }
            OutlinedTextField(parameter, { parameter = it.take(4096) }, singleLine = true, label = { Text("Widget parameter") }, modifier = Modifier.fillMaxWidth())

            val unsupported = remember(item.installation, revision) { PlatformSupport.unsupported(item.manifest, item.files) }
            if (unsupported.isNotEmpty()) Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Not supported on Android", style = MaterialTheme.typography.titleSmall)
                    for (line in unsupported) Text("• $line", style = MaterialTheme.typography.bodySmall)
                }
            }
            if (item.permissions.isNotEmpty()) FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (permission in item.permissions) AssistChip(onClick = {}, label = { Text(permission) })
            }
            result?.let { execution ->
                val error = execution.error
                if (error != null || execution.logs.isNotEmpty()) Card(Modifier.fillMaxWidth()) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        if (error != null) Text("[${error.kind}] ${error.message}", color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                        for (log in execution.logs.takeLast(40)) Text(log.message, style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace,
                            color = if (log.level == "error") MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurface)
                    }
                }
                Text("Ran in ${execution.elapsedMilliseconds} ms", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }

    if (rename) NameDialog("Rename", item.name, onDismiss = { rename = false }) { newName ->
        rename = false
        runCatching { AppServices.library.rename(item.name, newName) }
            .onSuccess { navigation.navigate("package/${Uri.encode(it.name)}") { popUpTo("home") } }
            .onFailure { Toast.makeText(context, it.message ?: "Could not rename", Toast.LENGTH_LONG).show() }
    }
    if (confirmDelete) AlertDialog(
        onDismissRequest = { confirmDelete = false }, title = { Text("Delete ${item.displayName}?") },
        text = { Text("The package and its saved data are removed from this device. Widgets showing it will ask you to choose another.") },
        confirmButton = { TextButton(onClick = {
            confirmDelete = false
            runCatching { AppServices.library.delete(item.name); AppServices.runtime.storage.clear(item.installation) }
            WidgetScheduler.refreshPackage(context, item.installation)
            navigation.popBackStack("home", false)
        }) { Text("Delete") } },
        dismissButton = { TextButton(onClick = { confirmDelete = false }) { Text("Cancel") } },
    )
}
