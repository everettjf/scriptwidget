package com.everettjf.scriptwidget.ui

import android.graphics.Bitmap
import android.net.Uri
import android.util.LruCache
import android.widget.Toast
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.Public
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.BundledPackage
import com.everettjf.scriptwidget.core.runtime.PackageCompiler
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import com.everettjf.scriptwidget.core.runtime.PackageFiles

/** The app's top-level destinations, shown in the bottom bar. */
enum class MainTab(val route: String, val label: String, val icon: ImageVector) {
    WIDGETS("home", "My Widgets", Icons.Default.Widgets),
    TEMPLATES("templates", "Templates", Icons.Default.GridView),
    GALLERY("gallery", "Gallery", Icons.Default.Public),
    SETTINGS("settings", "Settings", Icons.Default.Settings),
}

/** Switches to a top-level destination without stacking a second copy of it. */
fun NavController.openTab(tab: MainTab) {
    navigate(tab.route) {
        popUpTo("home") { saveState = true }
        launchSingleTop = true
        restoreState = true
    }
}

@Composable
fun MainBar(navigation: NavController, current: MainTab) {
    NavigationBar {
        for (tab in MainTab.entries) NavigationBarItem(
            selected = tab == current,
            onClick = { if (tab != current) navigation.openTab(tab) },
            icon = { Icon(tab.icon, null) },
            label = { Text(tab.label, maxLines = 1) },
        )
    }
}

/** Files of a bundled package, readable without installing it. */
private fun BundledPackage.packageFiles(): PackageFiles {
    val text = LinkedHashMap<String, String>()
    val binary = LinkedHashMap<String, ByteArray>()
    for ((path, bytes) in AppServices.library.bundledFiles(this)) {
        if (PackageCompiler.isTextFile(path)) text[path] = bytes.toString(Charsets.UTF_8) else binary[path] = bytes
    }
    return MemoryPackageFiles(text, binary)
}

/**
 * Browsing must not make network requests on the user's behalf: a bundled
 * package that reaches the network is drawn only after the user adds it.
 */
private fun PackageFiles.usesNetwork(): Boolean {
    if (readText("widget.json")?.contains("\"network\"") == true) return true
    return paths().filter { PackageCompiler.isTextFile(it) && it != "widget.json" }
        .any { path -> readText(path)?.let { it.contains("fetch(") || it.contains("\$http") || it.contains("\$dataSource") } == true }
}

private class TemplateThumbnail(val bitmap: Bitmap?, val online: Boolean)

/** Thumbnails of bundled packages, kept while the app is open. */
private val thumbnails = object : LruCache<String, Bitmap>(24 * 1024 * 1024) {
    override fun sizeOf(key: String, value: Bitmap): Int = value.allocationByteCount
}

@Composable
private fun TemplatePreview(item: BundledPackage, family: String, dark: Boolean, modifier: Modifier = Modifier) {
    val density = LocalDensity.current.density
    val key = "${item.assetPath}|$family|$dark"
    val state by produceState<TemplateThumbnail?>(initialValue = thumbnails.get(key)?.let { TemplateThumbnail(it, false) }, key) {
        if (value != null) return@produceState
        val files = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { item.packageFiles() }
        value = if (files.usesNetwork()) TemplateThumbnail(null, true) else {
            val bitmap = renderPreview(files, "template-preview:${item.assetPath}", family, dark, "", null, minOf(density, 2f)).bitmap
            if (bitmap != null) thumbnails.put(key, bitmap)
            TemplateThumbnail(bitmap, false)
        }
    }
    val (width, height) = previewSizes[family] ?: previewSizes.getValue("small")
    Box(
        modifier.widthIn(max = width.dp).fillMaxWidth().aspectRatio(width / height).clip(RoundedCornerShape(22.dp)).background(MaterialTheme.colorScheme.surfaceVariant),
        contentAlignment = Alignment.Center,
    ) {
        val current = state
        when {
            current == null -> CircularProgressIndicator(Modifier.size(24.dp), strokeWidth = 2.dp)
            current.bitmap != null -> Image(current.bitmap.asImageBitmap(), contentDescription = "${item.name} preview", contentScale = ContentScale.FillBounds, modifier = Modifier.fillMaxSize())
            else -> Column(Modifier.padding(12.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Icon(if (current.online) Icons.Default.Public else Icons.Default.Widgets, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text(if (current.online) "Loads live data.\nAdd it to see it." else "No preview", style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TemplatesScreen(navigation: NavController) {
    val context = LocalContext.current
    val bundled = remember { AppServices.library.bundled() }
    var group by remember { mutableStateOf("template") }
    var query by remember { mutableStateOf("") }
    var selected by remember { mutableStateOf<BundledPackage?>(null) }
    val dark = isSystemInDarkTheme()

    fun add(item: BundledPackage) {
        runCatching { AppServices.library.installBundled(item) }
            .onSuccess { navigation.navigate("package/${Uri.encode(it.name)}") }
            .onFailure { Toast.makeText(context, it.message ?: "Could not add the template", Toast.LENGTH_LONG).show() }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Templates") }) }, bottomBar = { MainBar(navigation, MainTab.TEMPLATES) }) { padding ->
        val needle = query.trim()
        val shown = bundled.filter { it.group == group && (needle.isEmpty() || it.name.contains(needle, ignoreCase = true)) }
        LazyVerticalGrid(
            columns = GridCells.Adaptive(156.dp), modifier = Modifier.padding(padding).fillMaxSize(),
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item(key = "header", span = { GridItemSpan(maxLineSpan) }) {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(
                        query, { query = it.take(60) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                        leadingIcon = { Icon(Icons.Default.Search, null) }, placeholder = { Text("Search templates") },
                    )
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for ((key, label) in listOf("template" to "Widgets", "component" to "Components", "api" to "API examples")) {
                            FilterChip(selected = group == key, onClick = { group = key }, label = { Text(label) })
                        }
                    }
                }
            }
            if (shown.isEmpty()) item(key = "empty", span = { GridItemSpan(maxLineSpan) }) {
                Text("No template matches.", Modifier.padding(24.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            items(shown, key = { it.assetPath }) { item ->
                Column(
                    Modifier.clip(RoundedCornerShape(26.dp)).background(MaterialTheme.colorScheme.surfaceContainerLow).clickable { selected = item }.padding(10.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    TemplatePreview(item, "small", dark)
                    Text(item.name, style = MaterialTheme.typography.titleSmall, maxLines = 1, overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp, start = 4.dp, end = 4.dp, bottom = 2.dp))
                }
            }
        }
    }

    selected?.let { item ->
        ModalBottomSheet(onDismissRequest = { selected = null }) {
            Column(Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(14.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text(item.name, style = MaterialTheme.typography.titleLarge, modifier = Modifier.fillMaxWidth())
                TemplatePreview(item, "medium", dark)
                Text("Adding it puts a copy in My Widgets. You can change the code and place it on the home screen from there.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.fillMaxWidth())
                Button(onClick = { selected = null; add(item) }, modifier = Modifier.fillMaxWidth()) { Text("Add to My Widgets") }
            }
        }
    }
}
