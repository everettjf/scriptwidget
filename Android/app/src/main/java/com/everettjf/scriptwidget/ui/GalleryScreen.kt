package com.everettjf.scriptwidget.ui

import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Widgets
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import com.everettjf.scriptwidget.GalleryServices
import com.everettjf.scriptwidget.core.PlatformSupport
import com.everettjf.scriptwidget.core.gallery.GalleryInstallState
import com.everettjf.scriptwidget.core.gallery.GalleryItem
import com.everettjf.scriptwidget.core.gallery.GalleryItemKind
import com.everettjf.scriptwidget.core.gallery.GallerySnapshot
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date

/** What the detail page learned from the verified `widget.json` of an item. */
private sealed interface ManifestPreview {
    data object Loading : ManifestPreview
    data class Loaded(val apiVersion: String?, val permissions: List<String>, val unsupported: List<String>) : ManifestPreview
    data class Failed(val reason: String) : ManifestPreview
}

/**
 * The Gallery: the verified catalog of community widgets and Skills. All network and file work
 * runs on `Dispatchers.IO`; the screen only shows indexes that passed validation and only
 * installs items whose every file matched its declared size and SHA-256.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun GalleryScreen(navigation: NavController) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var snapshot by remember { mutableStateOf<GallerySnapshot?>(null) }
    var states by remember { mutableStateOf<Map<String, GalleryInstallState>>(emptyMap()) }
    var loading by remember { mutableStateOf(true) }
    var failure by remember { mutableStateOf<String?>(null) }
    var query by remember { mutableStateOf("") }
    var kind by remember { mutableStateOf<GalleryItemKind?>(null) }
    var selectedId by remember { mutableStateOf<String?>(null) }
    var installing by remember { mutableStateOf<Set<String>>(emptySet()) }
    var installFailures by remember { mutableStateOf<Map<String, String>>(emptyMap()) }

    suspend fun readStates(items: List<GalleryItem>) = withContext(Dispatchers.IO) {
        val installer = GalleryServices.get(context).installer
        items.associate { it.id to runCatching { installer.state(it) }.getOrDefault(GalleryInstallState.NotInstalled) }
    }

    fun refresh(force: Boolean) {
        scope.launch {
            loading = true
            val result = withContext(Dispatchers.IO) { runCatching { GalleryServices.get(context).repository.load(forceRefresh = force) } }
            result.onSuccess { loaded ->
                snapshot = loaded
                failure = null
                states = readStates(loaded.index.items)
            }.onFailure { failure = it.message ?: "The Gallery could not be loaded." }
            loading = false
        }
    }

    fun install(item: GalleryItem) {
        if (item.id in installing) return
        scope.launch {
            installing = installing + item.id
            installFailures = installFailures - item.id
            val result = withContext(Dispatchers.IO) { runCatching { GalleryServices.get(context).installer.install(item) } }
            installing = installing - item.id
            result.onSuccess { record ->
                snapshot?.let { states = readStates(it.index.items) }
                if (item.kind == GalleryItemKind.WIDGET) {
                    navigation.navigate("package/${Uri.encode(record.localIdentifier)}") { popUpTo("home") }
                } else {
                    Toast.makeText(context, "${item.name} installed. Turn it on under Skills to use it with AI.", Toast.LENGTH_LONG).show()
                }
            }.onFailure { installFailures = installFailures + (item.id to (it.message ?: "The item could not be installed.")) }
        }
    }

    LaunchedEffect(Unit) { refresh(force = false) }

    val selected = snapshot?.index?.items?.firstOrNull { it.id == selectedId }
    if (selected != null) {
        BackHandler { selectedId = null }
        GalleryDetail(
            item = selected,
            state = states[selected.id] ?: GalleryInstallState.NotInstalled,
            installing = selected.id in installing,
            failure = installFailures[selected.id],
            onBack = { selectedId = null },
            onInstall = { install(selected) },
        )
        return
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Gallery") },
            navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = { IconButton(enabled = !loading, onClick = { refresh(force = true) }) { Icon(Icons.Default.Refresh, "Refresh") } },
        )
    }) { padding ->
        PullToRefreshBox(isRefreshing = loading, onRefresh = { refresh(force = true) }, modifier = Modifier.padding(padding).fillMaxSize()) {
            val current = snapshot
            if (current == null) {
                // The box needs scrollable content for the pull gesture, also while empty.
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(32.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
                ) {
                    if (failure != null) {
                        Text("The Gallery is unavailable", style = MaterialTheme.typography.titleLarge)
                        Text(failure.orEmpty(), style = MaterialTheme.typography.bodyMedium)
                        Text("No verified copy of the catalog is saved on this device yet.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Button(enabled = !loading, onClick = { refresh(force = true) }) { Text("Try again") }
                    } else {
                        Text("Loading the Gallery…", style = MaterialTheme.typography.bodyMedium)
                    }
                }
                return@PullToRefreshBox
            }

            val needle = query.trim()
            val items = current.index.items.filter { item ->
                (kind == null || item.kind == kind) && (needle.isEmpty() || listOf(item.name, item.summary, item.author).plus(item.tags).any { it.contains(needle, ignoreCase = true) })
            }
            LazyColumn(Modifier.fillMaxSize()) {
                item(key = "header") {
                    Column(Modifier.padding(horizontal = 16.dp, vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (current.isOffline) OfflineNotice(current)
                        OutlinedTextField(
                            query, { query = it.take(80) }, singleLine = true, modifier = Modifier.fillMaxWidth(),
                            leadingIcon = { Icon(Icons.Default.Search, null) }, placeholder = { Text("Search widgets and skills") },
                        )
                        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            FilterChip(selected = kind == null, onClick = { kind = null }, label = { Text("All") })
                            for (option in GalleryItemKind.entries) FilterChip(selected = kind == option, onClick = { kind = option }, label = { Text(option.displayName) })
                        }
                    }
                }
                if (items.isEmpty()) item(key = "empty") {
                    Text("Nothing in the Gallery matches.", Modifier.padding(32.dp), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                items(items, key = { it.id }) { item ->
                    ListItem(
                        leadingContent = { Icon(if (item.kind == GalleryItemKind.WIDGET) Icons.Default.Widgets else Icons.Default.AutoAwesome, null) },
                        overlineContent = { Text("${if (item.kind == GalleryItemKind.WIDGET) "Widget" else "Skill"} · ${item.version} · ${item.author}", maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        headlineContent = { Text(item.name, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        supportingContent = { Text(item.summary, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        trailingContent = {
                            InstallControl(states[item.id] ?: GalleryInstallState.NotInstalled, item.id in installing, compact = true) { install(item) }
                        },
                        modifier = Modifier.clickable { selectedId = item.id },
                    )
                    installFailures[item.id]?.let { Text(it, Modifier.padding(horizontal = 16.dp), color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall) }
                    HorizontalDivider()
                }
            }
        }
    }
}

@Composable
private fun OfflineNotice(snapshot: GallerySnapshot) {
    val saved = remember(snapshot.fetchedAt) { DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(snapshot.fetchedAt)) }
    Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
            Text("Offline", style = MaterialTheme.typography.titleSmall)
            Text("Showing the verified catalog saved $saved. Installing still needs a connection.", style = MaterialTheme.typography.bodySmall)
            snapshot.offlineReason?.let { Text(it, style = MaterialTheme.typography.bodySmall) }
        }
    }
}

/** Install, Update or Installed, with a spinner while the item is being downloaded and verified. */
@Composable
private fun InstallControl(state: GalleryInstallState, installing: Boolean, compact: Boolean, onInstall: () -> Unit) {
    when {
        installing -> Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            CircularProgressIndicator(Modifier.size(20.dp), strokeWidth = 2.dp)
            if (!compact) Text("Downloading and verifying…", style = MaterialTheme.typography.bodyMedium)
        }
        state is GalleryInstallState.Installed ->
            if (compact) Text("Installed", color = MaterialTheme.colorScheme.onSurfaceVariant) else OutlinedButton(enabled = false, onClick = {}) { Text("Installed") }
        state is GalleryInstallState.UpdateAvailable ->
            if (compact) TextButton(onClick = onInstall) { Text("Update") } else Button(onClick = onInstall) { Text("Update from ${state.current}") }
        else -> if (compact) TextButton(onClick = onInstall) { Text("Install") } else Button(onClick = onInstall) { Text("Install") }
    }
}

@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
private fun GalleryDetail(item: GalleryItem, state: GalleryInstallState, installing: Boolean, failure: String?, onBack: () -> Unit, onInstall: () -> Unit) {
    val context = LocalContext.current
    var preview by remember(item.id, item.contentFingerprint) { mutableStateOf<ManifestPreview?>(if (item.kind == GalleryItemKind.WIDGET) ManifestPreview.Loading else null) }

    // The manifest shown here is the hash-verified widget.json of this exact catalog entry.
    LaunchedEffect(item.id, item.contentFingerprint) {
        if (item.kind != GalleryItemKind.WIDGET) return@LaunchedEffect
        preview = withContext(Dispatchers.IO) {
            runCatching {
                val manifest = JSONObject(String(GalleryServices.get(context).installer.downloadVerified(item, "widget.json"), Charsets.UTF_8))
                val permissions = manifest.optJSONArray("permissions")?.let { array -> List(array.length()) { array.optString(it) } }.orEmpty()
                val api = (manifest.opt("minimumRuntimeVersion") as? String) ?: (manifest.opt("runtimeVersion") as? String)
                ManifestPreview.Loaded(api, permissions, PlatformSupport.unsupported(manifest, null))
            }.getOrElse { ManifestPreview.Failed(it.message ?: "The manifest could not be loaded.") }
        }
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text(item.name, maxLines = 1, overflow = TextOverflow.Ellipsis) }, navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(item.summary, style = MaterialTheme.typography.bodyLarge)
            InstallControl(state, installing, compact = false, onInstall = onInstall)
            if (failure != null) Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer), modifier = Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text("Not installed", style = MaterialTheme.typography.titleSmall)
                    Text(failure, style = MaterialTheme.typography.bodySmall)
                }
            }

            val loaded = preview as? ManifestPreview.Loaded
            Card(Modifier.fillMaxWidth()) {
                Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    Fact("Type", if (item.kind == GalleryItemKind.WIDGET) "Widget" else "Skill (AI prompt guidance)")
                    Fact("Version", item.version)
                    Fact("Author", item.author)
                    Fact("License", item.license)
                    Fact("Files", "${item.files.size} · ${Formatter.formatShortFileSize(context, item.totalBytes)}")
                    Fact("Requires", "Runtime ${item.minimumRuntimeVersion}" + (loaded?.apiVersion?.let { " · API $it or later" } ?: ""))
                }
            }
            if (item.tags.isNotEmpty()) FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                for (tag in item.tags) AssistChip(onClick = {}, label = { Text(tag) })
            }

            when (val current = preview) {
                null -> Text("Skills only add instructions to AI prompts. They cannot run code or grant permissions.", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                is ManifestPreview.Loading -> Text("Checking Android compatibility…", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                is ManifestPreview.Failed -> Text("Android compatibility could not be checked: ${current.reason}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                is ManifestPreview.Loaded -> {
                    if (current.unsupported.isNotEmpty()) Card(colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.tertiaryContainer), modifier = Modifier.fillMaxWidth()) {
                        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                            Text("Not supported on Android", style = MaterialTheme.typography.titleSmall)
                            for (line in current.unsupported) Text("• $line", style = MaterialTheme.typography.bodySmall)
                        }
                    }
                    if (current.permissions.isNotEmpty()) {
                        Text("Permissions", style = MaterialTheme.typography.titleSmall)
                        FlowRow(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            for (permission in current.permissions) AssistChip(onClick = {}, label = { Text(permission) })
                        }
                    }
                }
            }

            OutlinedButton(onClick = {
                runCatching { context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(item.sourceUrl))) }
                    .onFailure { Toast.makeText(context, "No app can open the source link.", Toast.LENGTH_LONG).show() }
            }) { Text("View source on GitHub") }
            Text(
                "Every file is checked against the size and SHA-256 in the curated catalog before it is installed. That detects corrupted or substituted downloads; it does not review the code for you.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Fact(label: String, value: String) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(label, Modifier.weight(0.35f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(value, Modifier.weight(0.65f), style = MaterialTheme.typography.bodyMedium)
    }
}
