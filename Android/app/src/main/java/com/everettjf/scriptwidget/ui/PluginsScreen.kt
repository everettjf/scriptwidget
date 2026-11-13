package com.everettjf.scriptwidget.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.everettjf.scriptwidget.core.plugin.InstalledPlugin
import com.everettjf.scriptwidget.core.plugin.PluginStore

/**
 * Lists Data Source Plugins and lets the user import, export and delete them. A plugin is a
 * reviewable manifest: the screen shows the hosts and operations it can reach before and after
 * import, and importing one never gives any widget access by itself.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PluginsScreen(navigation: NavController, store: PluginStore) {
    val context = LocalContext.current
    var plugins by remember { mutableStateOf(store.list()) }
    var expanded by remember { mutableStateOf<String?>(null) }
    var exporting by remember { mutableStateOf<String?>(null) }
    var confirmDelete by remember { mutableStateOf<InstalledPlugin?>(null) }
    val toast = { message: String -> Toast.makeText(context, message, Toast.LENGTH_LONG).show() }

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) runCatching {
            (context.contentResolver.openInputStream(uri) ?: error("The file could not be opened.")).use { store.install(it) }
        }.onSuccess { plugins = store.list(); expanded = it.id; toast("Installed ${it.name}") }
            .onFailure { toast(it.message ?: "Import failed") }
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        val id = exporting
        exporting = null
        if (uri != null && id != null) runCatching {
            (context.contentResolver.openOutputStream(uri) ?: error("The file could not be created.")).use { store.export(id, it) }
        }.onFailure { toast(it.message ?: "Export failed") }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Data Source Plugins") },
            navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = { IconButton(onClick = { importer.launch(arrayOf("*/*")) }) { Icon(Icons.Default.Add, "Import plugin") } },
        )
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            ListItem(
                headlineContent = { Text("Plugins map parameters to HTTPS requests") },
                supportingContent = { Text("A plugin is data, not code. A widget can use one only when its widget.json lists the plugin, has the network permission, and declares the plugin's host in networkDomains. Import a .swplugin archive or a plugin.json file with +.") },
            )
            for (plugin in plugins) {
                val manifest = plugin.manifest
                val open = expanded == manifest.id
                HorizontalDivider()
                ListItem(
                    headlineContent = { Text(if (plugin.builtIn) "${manifest.name} · Built-in" else manifest.name) },
                    supportingContent = {
                        Column {
                            Text("${manifest.id} · ${manifest.version}")
                            Text("Hosts: ${manifest.hosts.joinToString(", ")}")
                            Text("${manifest.operations.size} operation${if (manifest.operations.size == 1) "" else "s"}: ${manifest.operations.joinToString(", ") { it.id }}")
                        }
                    },
                    modifier = Modifier.clickable { expanded = if (open) null else manifest.id },
                )
                if (open) {
                    Column(Modifier.padding(horizontal = 16.dp)) {
                        if (manifest.summary.isNotBlank()) Text(manifest.summary, style = MaterialTheme.typography.bodyMedium)
                        Text("By ${manifest.author} · ${manifest.license}", style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(top = 4.dp))
                        for (operation in manifest.operations) {
                            Text("${operation.title} (${operation.id})", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 12.dp))
                            Text("${operation.method} ${manifest.baseURL.trimEnd('/')}${operation.path} → ${operation.responseType.wireName}", style = MaterialTheme.typography.bodySmall, fontFamily = FontFamily.Monospace)
                            for (parameter in operation.parameters) {
                                val details = listOfNotNull(parameter.location.wireName, if (parameter.required) "required" else "optional", parameter.defaultValue?.let { "default $it" })
                                Text("${parameter.id} — ${parameter.label} (${details.joinToString(", ")})", style = MaterialTheme.typography.bodySmall)
                            }
                        }
                        if (!plugin.readme.isNullOrBlank()) {
                            Text("README", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 12.dp))
                            Text(plugin.readme.orEmpty(), style = MaterialTheme.typography.bodySmall)
                        }
                        Row(Modifier.padding(vertical = 4.dp)) {
                            TextButton(onClick = { exporting = manifest.id; exporter.launch("${fileName(manifest.name)}.swplugin") }) { Text("Export") }
                            if (!plugin.builtIn) TextButton(onClick = { confirmDelete = plugin }) { Text("Delete", color = MaterialTheme.colorScheme.error) }
                        }
                    }
                }
            }
        }
    }

    confirmDelete?.let { plugin ->
        AlertDialog(
            onDismissRequest = { confirmDelete = null }, title = { Text("Delete ${plugin.manifest.name}?") },
            text = { Text("Widgets that declare ${plugin.manifest.id} will fail their data source requests until it is installed again.") },
            confirmButton = { TextButton(onClick = {
                confirmDelete = null
                runCatching { store.delete(plugin.manifest.id) }.onFailure { toast(it.message ?: "Could not delete") }
                plugins = store.list()
            }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { confirmDelete = null }) { Text("Cancel") } },
        )
    }
}

/** File name suggestion for an export; the system picker has the final say. */
private fun fileName(name: String): String =
    name.lowercase().replace(Regex("[^a-z0-9]+"), "-").trim('-').ifEmpty { "plugin" }
