package com.everettjf.scriptwidget.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FloatingActionButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
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
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage

const val BLANK_SOURCE = """${'$'}render(
  <vstack frame="max" background="#0f172a">
    <text font="title3" fontWeight="semibold" color="white">Hello, ScriptWidget</text>
    <text font="caption" color="#94a3b8">{new Date().toLocaleTimeString()}</text>
  </vstack>
);
"""

/** Installs a `.swt` archive from a content URI. Shows the reason when it is rejected. */
fun importPackage(context: Context, uri: Uri): InstalledPackage? {
    val displayName = runCatching {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null }
    }.getOrNull() ?: uri.lastPathSegment ?: "Imported Widget"
    val name = displayName.substringAfterLast('/').removeSuffix(".swt").removeSuffix(".zip").ifBlank { "Imported Widget" }
    return try {
        context.contentResolver.openInputStream(uri)?.use { AppServices.library.importArchive(it, name) }
    } catch (error: Exception) {
        Toast.makeText(context, "Could not install: ${error.message}", Toast.LENGTH_LONG).show()
        null
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(navigation: NavController) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var packages by remember { mutableStateOf(AppServices.library.list()) }
    var showAdd by remember { mutableStateOf(false) }
    var showName by remember { mutableStateOf(false) }
    val dark = isSystemInDarkTheme()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { packages = AppServices.library.list(); revision += 1 }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importPackage(context, uri)?.let { navigation.navigate("package/${Uri.encode(it.name)}") }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("ScriptWidget") }, actions = { IconButton(onClick = { navigation.navigate("settings") }) { Icon(Icons.Default.Settings, "Settings") } }) },
        floatingActionButton = { FloatingActionButton(onClick = { showAdd = true }) { Icon(Icons.Default.Add, "New widget") } },
    ) { padding ->
        if (packages.isEmpty()) {
            Column(Modifier.padding(padding).fillMaxSize().padding(32.dp), verticalArrangement = Arrangement.Center) {
                Text("No widgets yet", style = MaterialTheme.typography.titleLarge)
                Text("Tap + to start from a template, write one, or ask AI to draft it.", style = MaterialTheme.typography.bodyMedium)
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(170.dp), modifier = Modifier.padding(padding).fillMaxSize(),
                contentPadding = PaddingValues(12.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                items(packages, key = { it.installation }) { item ->
                    Column(Modifier.clickable { navigation.navigate("package/${Uri.encode(item.name)}") }) {
                        WidgetPreview(item.files, item.installation, "small", dark, buildDirectory = item.buildDirectory, revision = revision)
                        Text(item.displayName, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 6.dp, start = 4.dp))
                    }
                }
            }
        }
    }

    if (showAdd) {
        ModalBottomSheet(onDismissRequest = { showAdd = false }) {
            @Composable fun row(icon: ImageVector, title: String, subtitle: String, action: () -> Unit) = ListItem(
                headlineContent = { Text(title) }, supportingContent = { Text(subtitle) }, leadingContent = { Icon(icon, null) },
                modifier = Modifier.clickable { showAdd = false; action() },
            )
            Column(Modifier.padding(bottom = 24.dp)) {
                row(Icons.Default.Code, "Blank widget", "Start from a few lines of JSX") { showName = true }
                row(Icons.Default.GridView, "Templates", "Ready-made widgets and API examples") { navigation.navigate("templates") }
                row(Icons.Default.Public, "Gallery", "Verified widgets from the ScriptWidget catalog") { navigation.navigate("gallery") }
                row(Icons.Default.AutoAwesome, "Generate with AI", "Describe a widget and let a model draft it") { navigation.navigate("ai") }
                row(Icons.Default.FileOpen, "Import .swt", "Install a package exported from iPhone, Mac or the web") { picker.launch(arrayOf("*/*")) }
            }
        }
    }
    if (showName) NameDialog("New widget", "My Widget", onDismiss = { showName = false }) { name ->
        showName = false
        runCatching { AppServices.library.create(name, BLANK_SOURCE) }
            .onSuccess { navigation.navigate("editor/${Uri.encode(it.name)}") }
            .onFailure { Toast.makeText(context, it.message ?: "Could not create the widget", Toast.LENGTH_LONG).show() }
    }
}

@Composable
fun NameDialog(title: String, initial: String, onDismiss: () -> Unit, onConfirm: (String) -> Unit) {
    var name by remember { mutableStateOf(initial) }
    AlertDialog(
        onDismissRequest = onDismiss, title = { Text(title) },
        text = { OutlinedTextField(name, { name = it.take(80) }, singleLine = true, label = { Text("Name") }) },
        confirmButton = { TextButton(enabled = name.isNotBlank(), onClick = { onConfirm(name.trim()) }) { Text("OK") } },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplatesScreen(navigation: NavController) {
    val context = LocalContext.current
    val bundled = remember { AppServices.library.bundled() }
    var group by remember { mutableStateOf("template") }
    Scaffold(topBar = {
        TopAppBar(title = { Text("Templates") }, navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                for ((key, label) in listOf("template" to "Templates", "component" to "Components", "api" to "APIs")) {
                    TextButton(onClick = { group = key }) { Text(label, color = if (group == key) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant) }
                }
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(bundled.filter { it.group == group }, key = { it.assetPath }) { item ->
                    ListItem(
                        headlineContent = { Text(item.name) },
                        trailingContent = { Text("Add", color = MaterialTheme.colorScheme.primary) },
                        modifier = Modifier.clickable {
                            runCatching { AppServices.library.installBundled(item) }
                                .onSuccess { navigation.navigate("package/${Uri.encode(it.name)}") { popUpTo("home") } }
                                .onFailure { Toast.makeText(context, it.message ?: "Could not add the template", Toast.LENGTH_LONG).show() }
                        },
                    )
                }
            }
        }
    }
}
