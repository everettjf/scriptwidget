package com.everettjf.scriptwidget.ui

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.filled.AddToHomeScreen
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExtendedFloatingActionButton
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.OutlinedButton
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import com.everettjf.scriptwidget.widget.ScriptWidgetProvider
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

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(navigation: NavController) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var packages by remember { mutableStateOf(AppServices.library.list()) }
    var placed by remember { mutableStateOf(ScriptWidgetProvider.allIds(context).isNotEmpty()) }
    var showAdd by remember { mutableStateOf(false) }
    var showName by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    val dark = isSystemInDarkTheme()
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) {
        packages = AppServices.library.list(); revision += 1
        placed = ScriptWidgetProvider.allIds(context).isNotEmpty()
    }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) importPackage(context, uri)?.let { navigation.navigate("package/${Uri.encode(it.name)}") }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text("My Widgets") }) },
        bottomBar = { MainBar(navigation, MainTab.WIDGETS) },
        floatingActionButton = {
            ExtendedFloatingActionButton(onClick = { showAdd = true }, icon = { Icon(Icons.Default.Add, null) }, text = { Text("New widget") })
        },
    ) { padding ->
        if (packages.isEmpty()) {
            Column(
                Modifier.padding(padding).fillMaxSize().padding(32.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically), horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(Icons.Default.Widgets, null, Modifier.size(48.dp), tint = MaterialTheme.colorScheme.primary)
                Text("No widgets yet", style = MaterialTheme.typography.titleLarge)
                Text("Start from a template, write one yourself, or describe it and let AI draft it.", style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                Button(onClick = { navigation.openTab(MainTab.TEMPLATES) }) { Text("Browse templates") }
                OutlinedButton(onClick = { showName = true }) { Text("Start with a blank widget") }
            }
        } else {
            LazyVerticalGrid(
                columns = GridCells.Adaptive(156.dp), modifier = Modifier.padding(padding).fillMaxSize(),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 96.dp),
                horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                if (!placed) item(key = "hint", span = { GridItemSpan(maxLineSpan) }) {
                    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)) {
                        Row(Modifier.padding(14.dp), horizontalArrangement = Arrangement.spacedBy(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.AddToHomeScreen, null, tint = MaterialTheme.colorScheme.onPrimaryContainer)
                            Text("Open a widget and tap Add to home screen. Or touch and hold the home screen, choose Widgets, then ScriptWidget.",
                                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onPrimaryContainer)
                        }
                    }
                }
                items(packages, key = { it.installation }) { item ->
                    Box {
                        Column(
                            Modifier.clip(RoundedCornerShape(26.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow)
                                .combinedClickable(
                                    onClick = { navigation.navigate("package/${Uri.encode(item.name)}") },
                                    onLongClick = { menuFor = item.installation }, onLongClickLabel = "More actions",
                                ).padding(10.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            WidgetPreview(item.files, item.installation, "small", dark, buildDirectory = item.buildDirectory, revision = revision)
                            Text(item.displayName, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.fillMaxWidth().padding(top = 8.dp, start = 4.dp, end = 4.dp, bottom = 2.dp))
                        }
                        DropdownMenu(menuFor == item.installation, onDismissRequest = { menuFor = null }) {
                            DropdownMenuItem(text = { Text("Add to home screen") }, leadingIcon = { Icon(Icons.Default.AddToHomeScreen, null) }, onClick = {
                                menuFor = null
                                if (!pinWidget(context, item, "small", "")) Toast.makeText(context, PIN_FALLBACK, Toast.LENGTH_LONG).show()
                            })
                            DropdownMenuItem(text = { Text("Edit code") }, leadingIcon = { Icon(Icons.Default.Code, null) }, onClick = {
                                menuFor = null; navigation.navigate("editor/${Uri.encode(item.name)}")
                            })
                            DropdownMenuItem(text = { Text("Improve with AI") }, leadingIcon = { Icon(Icons.Default.AutoAwesome, null) }, onClick = {
                                menuFor = null; navigation.navigate("ai/${Uri.encode(item.name)}")
                            })
                        }
                    }
                }
            }
        }
    }

    if (showAdd) {
        ModalBottomSheet(onDismissRequest = { showAdd = false }) {
            @Composable fun row(icon: ImageVector, title: String, subtitle: String, action: () -> Unit) = ListItem(
                headlineContent = { Text(title) }, supportingContent = { Text(subtitle) }, leadingContent = { Icon(icon, null) },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                modifier = Modifier.clickable { showAdd = false; action() },
            )
            Column(Modifier.padding(bottom = 24.dp)) {
                Text("New widget", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
                row(Icons.Default.GridView, "From a template", "Ready-made widgets you can change") { navigation.openTab(MainTab.TEMPLATES) }
                row(Icons.Default.AutoAwesome, "Generate with AI", "Describe a widget and let a model draft it") { navigation.navigate("ai") }
                row(Icons.Default.Code, "Blank widget", "Start from a few lines of JSX") { showName = true }
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

/** Shown when the launcher cannot pin a widget from inside the app. */
const val PIN_FALLBACK = "Touch and hold the home screen, choose Widgets, then ScriptWidget."

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
