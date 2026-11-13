package com.everettjf.scriptwidget.ui

import android.Manifest
import android.content.Intent
import android.provider.Settings
import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
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
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.core.surfaces.LiveActivityStateException
import com.everettjf.scriptwidget.core.surfaces.LiveActivityStates
import com.everettjf.scriptwidget.core.system.IsoDates
import com.everettjf.scriptwidget.live.LiveUpdate
import com.everettjf.scriptwidget.live.LiveUpdates
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private class LiveActivitiesState(val packages: List<InstalledPackage>, val active: List<LiveUpdate>, val notifications: Boolean, val promotion: Boolean)

private fun loadLiveActivities(context: android.content.Context): LiveActivitiesState =
    LiveActivitiesState(AppServices.library.list(), LiveUpdates.active(context), LiveUpdates.notificationsAllowed(context), LiveUpdates.promotionAllowed(context))

/**
 * Starts, updates and ends Live Updates, Android's counterpart of the iOS
 * Live Activities management screen. Route it from the app's navigation graph.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalLayoutApi::class)
@Composable
fun LiveActivitiesScreen(navigation: NavController) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<LiveActivitiesState?>(null) }
    var selected by remember { mutableStateOf<String?>(null) }
    var text by remember { mutableStateOf("") }
    var chooser by remember { mutableStateOf(false) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { revision += 1 }
    LaunchedEffect(revision) { state = withContext(Dispatchers.IO) { runCatching { loadLiveActivities(context.applicationContext) }.getOrNull() } }
    val permission = rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { revision += 1 }

    // Validated on every edit so the buttons only offer what will be accepted.
    val problem = remember(text) {
        try { LiveActivityStates.parse(text); null } catch (error: LiveActivityStateException) { error.message ?: "The state is invalid." }
    }
    val bytes = remember(text) { text.toByteArray(Charsets.UTF_8).size }

    fun report(result: com.everettjf.scriptwidget.live.LiveUpdateResult, done: String) {
        Toast.makeText(context, if (result.ok) done else result.message ?: "Android refused the Live Update.", Toast.LENGTH_LONG).show()
        revision += 1
    }

    Scaffold(topBar = {
        TopAppBar(title = { Text("Live Activities") }, navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            Card(Modifier.padding(16.dp).fillMaxWidth()) {
                Text(
                    "On Android a Live Activity is a Live Update: an ongoing notification drawn by the system. " +
                        "It shows the state's title, detail, progress and countdown in Android's own template. " +
                        "It does not draw the widget's JSX layout, and there is no Dynamic Island.",
                    style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(16.dp),
                )
            }
            val current = state
            if (current == null) { Text("Loading…", Modifier.padding(16.dp)); return@Column }

            if (!current.notifications) ListItem(
                headlineContent = { Text("Allow notifications") },
                supportingContent = { Text("Live Updates are notifications. Tap to allow them for ScriptWidget.", color = MaterialTheme.colorScheme.error) },
                modifier = Modifier.clickable { permission.launch(Manifest.permission.POST_NOTIFICATIONS) },
            )
            if (!LiveUpdates.promotionSupported) ListItem(
                headlineContent = { Text("Shown as an ongoing notification") },
                supportingContent = { Text("This Android version has no Live Updates. The activity appears as a normal ongoing notification with a progress bar.") },
            ) else if (current.notifications && !current.promotion) ListItem(
                headlineContent = { Text("Live Updates are off for ScriptWidget") },
                supportingContent = { Text("The activity still appears as an ongoing notification. Tap to allow Live Updates so it also shows on the lock screen and in the status bar.") },
                modifier = Modifier.clickable {
                    runCatching {
                        context.startActivity(Intent(Settings.ACTION_APP_NOTIFICATION_PROMOTION_SETTINGS).putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }
                },
            )

            LiveSection("Widget")
            val chosen = current.packages.firstOrNull { it.installation == selected }
            val running = current.active.firstOrNull { it.installation == selected }
            Box(Modifier.padding(horizontal = 16.dp, vertical = 8.dp)) {
                OutlinedButton(onClick = { chooser = true }, enabled = current.packages.isNotEmpty()) {
                    Text(chosen?.displayName ?: if (current.packages.isEmpty()) "No widgets installed" else "Choose an installed widget")
                }
                DropdownMenu(chooser, onDismissRequest = { chooser = false }) {
                    for (installed in current.packages) DropdownMenuItem(text = { Text(installed.displayName) }, onClick = {
                        chooser = false
                        selected = installed.installation
                        current.active.firstOrNull { it.installation == installed.installation }?.let { text = it.stateJson }
                    })
                }
            }

            LiveSection("State")
            OutlinedTextField(
                value = text, onValueChange = { text = it }, label = { Text("State JSON") }, minLines = 4, maxLines = 10,
                textStyle = TextStyle(fontFamily = FontFamily.Monospace), isError = problem != null,
                supportingText = { Text(problem ?: "Valid · $bytes of ${LiveActivityStates.MAXIMUM_BYTES} bytes") },
                modifier = Modifier.padding(horizontal = 16.dp).fillMaxWidth(),
            )
            FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AssistChip(onClick = { text = """{"title":"Reading","detail":"Chapter finished","progress":3,"total":8}""" }, label = { Text("Reading progress") })
                AssistChip(onClick = {
                    // A real deadline counted from now, as the iOS preset does.
                    text = """{"title":"Focus","detail":"One focused session","endsAt":"${IsoDates.format(System.currentTimeMillis() + 25 * 60_000L)}"}"""
                }, label = { Text("25-minute focus") })
                AssistChip(onClick = { text = "" }, label = { Text("Clear") })
            }
            Text(
                "Supported fields: title (1–40 characters), detail (up to 80), whole-number progress and total (0 ≤ progress ≤ total, total 1–10000) and endsAt, " +
                    "an ISO date and time with a time zone. With endsAt the notification counts down and ends at the deadline; Android may deliver that a little late.",
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp),
            )
            FlowRow(Modifier.padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Button(enabled = chosen != null && running == null && problem == null, onClick = {
                    report(LiveUpdates.start(context, chosen!!.installation, text), "Live Update started.")
                }) { Text("Start") }
                OutlinedButton(enabled = chosen != null && running != null && problem == null, onClick = {
                    report(LiveUpdates.update(context, chosen!!.installation, text), "Live Update updated.")
                }) { Text("Update") }
                OutlinedButton(enabled = running != null, onClick = {
                    LiveUpdates.end(context, running!!.installation)
                    Toast.makeText(context, "Live Update ended.", Toast.LENGTH_SHORT).show()
                    revision += 1
                }) { Text("End") }
            }

            LiveSection("Running")
            if (current.active.isEmpty()) ListItem(headlineContent = { Text("No Live Updates are running") },
                supportingContent = { Text("Up to ${LiveUpdates.MAXIMUM_ACTIVE} can run at once, one per widget. Deleting a widget ends its Live Update.") })
            for (update in current.active) {
                val installed = current.packages.firstOrNull { it.installation == update.installation }
                val content = runCatching { LiveActivityStates.content(LiveActivityStates.parse(update.stateJson), installed?.displayName.orEmpty(), System.currentTimeMillis()) }.getOrNull()
                ListItem(
                    headlineContent = { Text(content?.title?.takeIf { it.isNotEmpty() } ?: installed?.displayName ?: "Live Update") },
                    supportingContent = {
                        Text(listOfNotNull(installed?.displayName, content?.text?.takeIf { it.isNotEmpty() },
                            if (content?.progress != null) "${content.progress} / ${content.total}" else null,
                            if (content?.countdownTo != null) "counting down" else null).joinToString(" · "))
                    },
                    trailingContent = { if (update.installation == selected) Text("✓", color = MaterialTheme.colorScheme.primary) },
                    modifier = Modifier.clickable { selected = update.installation; text = update.stateJson },
                )
            }
        }
    }
}

@Composable
private fun LiveSection(title: String) {
    HorizontalDivider()
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
}
