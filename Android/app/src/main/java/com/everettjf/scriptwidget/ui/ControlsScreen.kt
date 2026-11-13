package com.everettjf.scriptwidget.ui

import android.app.StatusBarManager
import android.widget.Toast
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LifecycleEventEffect
import androidx.navigation.NavController
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.InstalledPackage
import com.everettjf.scriptwidget.actions.ActionRunner
import com.everettjf.scriptwidget.actions.ControlIconResources
import com.everettjf.scriptwidget.actions.ControlTileStore
import com.everettjf.scriptwidget.actions.ControlTiles
import com.everettjf.scriptwidget.actions.ResolvedControl
import com.everettjf.scriptwidget.actions.ShortcutPublisher
import com.everettjf.scriptwidget.actions.SurfaceHooks
import com.everettjf.scriptwidget.core.surfaces.ControlSlotException
import com.everettjf.scriptwidget.core.surfaces.ControlSlots
import com.everettjf.scriptwidget.core.surfaces.DeclaredAction
import com.everettjf.scriptwidget.core.surfaces.PackageSurfaces
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Everything the Controls screen shows, read off the main thread. */
private class ControlsState(
    val slots: ControlSlots,
    val resolved: Map<Int, ResolvedControl>,
    /** Installed packages with what they declare; null surfaces mean an invalid manifest. */
    val packages: List<Pair<InstalledPackage, PackageSurfaces?>>,
    val shortcutIDs: List<String>,
)

private fun loadControls(context: android.content.Context): ControlsState {
    // Free tiles of deleted packages and republish shortcuts before reading.
    SurfaceHooks.reconcile(context)
    val slots = ControlTileStore.get(context).slots()
    val resolved = slots.assigned().mapNotNull { (slot, assignment) -> ControlTiles.resolve(assignment)?.let { slot to it } }.toMap()
    val packages = AppServices.library.list().map { it to ActionRunner.declared(it) }
    return ControlsState(slots, resolved, packages, ShortcutPublisher.sync(context))
}

/**
 * Assigns package `controls` to the eight Quick Settings tiles and lists the
 * `actions` published as launcher shortcuts. Route it from the app's navigation graph.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ControlsScreen(navigation: NavController) {
    val context = LocalContext.current
    var revision by remember { mutableIntStateOf(0) }
    var state by remember { mutableStateOf<ControlsState?>(null) }
    LifecycleEventEffect(Lifecycle.Event.ON_RESUME) { revision += 1 }
    LaunchedEffect(revision) { state = withContext(Dispatchers.IO) { runCatching { loadControls(context.applicationContext) }.getOrNull() } }

    fun toast(message: String) = Toast.makeText(context, message, Toast.LENGTH_LONG).show()

    Scaffold(topBar = {
        TopAppBar(title = { Text("Controls") }, navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } })
    }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().verticalScroll(rememberScrollState())) {
            Text(
                "Controls a widget declares can run from Quick Settings. Android has no Control Center gallery, so ScriptWidget offers ${ControlSlots.COUNT} tiles: " +
                    "give a control a tile here, then add that tile to Quick Settings. A tile shows the control's title and a built-in icon; SF Symbols are not available on Android.",
                style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(16.dp),
            )
            val current = state
            if (current == null) { Text("Loading…", Modifier.padding(16.dp)); return@Column }

            ControlsSection("Quick Settings tiles")
            for (slot in 1..ControlSlots.COUNT) {
                val assignment = current.slots.get(slot)
                val resolved = current.resolved[slot]
                ListItem(
                    leadingContent = { Icon(painterResource(ControlIconResources.drawable(resolved?.control?.systemImage)), null) },
                    overlineContent = { Text("Tile $slot") },
                    headlineContent = { Text(resolved?.control?.title ?: if (assignment == null) "Free" else "Control removed") },
                    supportingContent = {
                        Text(when {
                            resolved != null -> resolved.subtitle + if (resolved.control.isToggle) " · Toggle" else " · Button"
                            assignment == null -> "Shown as unavailable in Quick Settings."
                            else -> "Its widget was deleted or no longer declares this control."
                        })
                    },
                    trailingContent = {
                        if (assignment != null) Row {
                            if (resolved != null) TextButton(onClick = {
                                ControlTiles.requestAdd(context, slot) { result ->
                                    toast(when (result) {
                                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ADDED -> "Tile added to Quick Settings."
                                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_ALREADY_ADDED -> "This tile is already in Quick Settings."
                                        StatusBarManager.TILE_ADD_REQUEST_RESULT_TILE_NOT_ADDED -> "Tile not added."
                                        else -> "Android could not add the tile. Edit Quick Settings and drag “ScriptWidget Control $slot” in."
                                    })
                                }
                            }) { Text("Add tile") }
                            TextButton(onClick = { ControlTileStore.get(context).unassign(slot); revision += 1 }) { Text("Remove") }
                        }
                    },
                )
            }

            ControlsSection("Controls in your widgets")
            val withControls = current.packages.filter { (_, surfaces) -> surfaces == null || surfaces.controls.isNotEmpty() }
            if (withControls.isEmpty()) ListItem(
                headlineContent = { Text("No installed widget declares controls") },
                supportingContent = { Text("Add a controls list to a widget's widget.json. A toggle also needs a stateKey and the storage permission.") },
            )
            for ((installed, surfaces) in withControls) {
                if (surfaces == null) {
                    ListItem(headlineContent = { Text(installed.displayName) },
                        supportingContent = { Text("Its widget.json is invalid, so its controls and actions are not offered.", color = MaterialTheme.colorScheme.error) })
                    continue
                }
                for (control in surfaces.controls) {
                    val slot = current.slots.slotOf(installed.installation, control.id)
                    ListItem(
                        leadingContent = { Icon(painterResource(ControlIconResources.drawable(control.systemImage)), null) },
                        headlineContent = { Text(control.title) },
                        supportingContent = { Text(listOfNotNull(installed.displayName, control.subtitle?.takeIf { it.isNotBlank() }, if (control.isToggle) "Toggle" else "Button").joinToString(" · ")) },
                        trailingContent = {
                            if (slot != null) Text("Tile $slot", color = MaterialTheme.colorScheme.primary)
                            else TextButton(enabled = current.slots.firstFree() != null, onClick = {
                                try {
                                    ControlTileStore.get(context).assign(installed.installation, control.id)
                                } catch (error: ControlSlotException) {
                                    toast(error.message ?: "Could not assign this control.")
                                }
                                revision += 1
                            }) { Text("Assign") }
                        },
                    )
                }
            }

            ControlsSection("App shortcuts")
            val actions: List<Pair<InstalledPackage, DeclaredAction>> = current.packages.flatMap { (installed, surfaces) -> surfaces?.actions.orEmpty().map { installed to it } }
            ListItem(
                headlineContent = { Text(if (actions.isEmpty()) "No installed widget declares actions" else "${current.shortcutIDs.size} of ${actions.size} actions published") },
                supportingContent = {
                    Text("Touch and hold the ScriptWidget icon on the home screen to run a declared action, or drag one out as its own icon. " +
                        "The launcher limits how many it lists; the ones you use most recently come first. Siri and the Shortcuts app are not available on Android.")
                },
            )
            for ((installed, action) in actions) ListItem(
                leadingContent = { Icon(painterResource(ControlIconResources.drawable(action.systemImage)), null) },
                headlineContent = { Text(action.title) },
                supportingContent = { Text(listOfNotNull(installed.displayName, action.description?.takeIf { it.isNotBlank() }).joinToString(" · ")) },
                trailingContent = {
                    TextButton(onClick = {
                        ActionRunner.runAsync(context, installed.installation, action.id, "shortcut", null, null) { result ->
                            if (result.ok) ShortcutPublisher.recordUse(context, installed.installation, action.id)
                            toast(if (result.ok) "Action finished." else result.message ?: "The action failed.")
                            revision += 1
                        }
                    }) { Text("Run") }
                },
            )
        }
    }
}

@Composable
private fun ControlsSection(title: String) {
    HorizontalDivider()
    Text(title, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 16.dp, top = 16.dp, bottom = 4.dp))
}
