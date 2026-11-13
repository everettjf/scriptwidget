package com.everettjf.scriptwidget.ui

import android.widget.Toast
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.FileOpen
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import com.everettjf.scriptwidget.core.skills.Skill
import com.everettjf.scriptwidget.core.skills.SkillStore
import com.everettjf.scriptwidget.core.skills.SkillValidator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Manage Skills 1.0: enable them for AI requests, inspect their instructions, import and export
 * `.swskill` archives, and delete installed ones. A Skill only ever contributes prompt text;
 * nothing on this screen runs Skill content. All store access runs on `Dispatchers.IO`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SkillsScreen(navigation: NavController) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var skills by remember { mutableStateOf<List<Skill>>(emptyList()) }
    var enabled by remember { mutableStateOf<Set<String>>(emptySet()) }
    var loaded by remember { mutableStateOf(false) }
    var menuFor by remember { mutableStateOf<String?>(null) }
    var viewing by remember { mutableStateOf<Skill?>(null) }
    var deleting by remember { mutableStateOf<Skill?>(null) }
    var exporting by remember { mutableStateOf<String?>(null) }

    fun toast(message: String) = Toast.makeText(context, message, Toast.LENGTH_LONG).show()

    /** Runs [work] on the IO dispatcher, reports a failure, then reloads the list. */
    fun store(failure: String, success: String? = null, work: (SkillStore) -> Unit) {
        scope.launch {
            val store = GalleryServices.get(context).skills
            val result = withContext(Dispatchers.IO) { runCatching { work(store) } }
            val (list, ids) = withContext(Dispatchers.IO) { store.list() to store.enabledIds() }
            skills = list
            enabled = ids
            loaded = true
            result.onSuccess { success?.let(::toast) }.onFailure { toast("$failure: ${it.message ?: "unknown error"}") }
        }
    }

    LaunchedEffect(Unit) { store("Skills could not be loaded") {} }

    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) store("Could not import the skill", "Skill imported. Turn it on to use it with AI.") { skillStore ->
            val input = context.contentResolver.openInputStream(uri) ?: error("The file could not be opened.")
            input.use { skillStore.importArchive(it) }
        }
    }
    val exporter = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/zip")) { uri ->
        val id = exporting
        exporting = null
        if (uri != null && id != null) store("Could not export the skill", "Skill exported.") { skillStore ->
            val output = context.contentResolver.openOutputStream(uri) ?: error("The file could not be created.")
            output.use { skillStore.exportArchive(id, it) }
        }
    }

    Scaffold(topBar = {
        TopAppBar(
            title = { Text("Skills") },
            navigationIcon = { IconButton(onClick = { navigation.popBackStack() }) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
            actions = { IconButton(onClick = { importer.launch(arrayOf("*/*")) }) { Icon(Icons.Default.FileOpen, "Import skill") } },
        )
    }) { padding ->
        LazyColumn(Modifier.padding(padding).fillMaxSize()) {
            item(key = "header") {
                Text(
                    "Skills add their instructions to AI requests while they are turned on. They cannot run code, use the network, or grant permissions.",
                    Modifier.padding(horizontal = 16.dp, vertical = 12.dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            if (loaded && skills.isEmpty()) item(key = "empty") { Text("No skills.", Modifier.padding(32.dp)) }
            items(skills, key = { it.id }) { skill ->
                ListItem(
                    overlineContent = { Text(if (skill.isBuiltIn) "Built-in · ${skill.version}" else listOfNotNull("Installed", skill.version, skill.author).joinToString(" · "), maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    headlineContent = { Text(skill.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                    supportingContent = { Text(skill.summary, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                    trailingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Switch(skill.id in enabled, onCheckedChange = { on -> store("Could not change the skill") { it.setEnabled(skill.id, on) } })
                            Box {
                                IconButton(onClick = { menuFor = skill.id }) { Icon(Icons.Default.MoreVert, "More for ${skill.title}") }
                                DropdownMenu(menuFor == skill.id, onDismissRequest = { menuFor = null }) {
                                    DropdownMenuItem(text = { Text("View instructions") }, onClick = { menuFor = null; viewing = skill })
                                    DropdownMenuItem(text = { Text("Export") }, onClick = {
                                        menuFor = null
                                        exporting = skill.id
                                        exporter.launch("${SkillValidator.slug(skill.title)}.swskill")
                                    })
                                    if (!skill.isBuiltIn) DropdownMenuItem(text = { Text("Delete") }, onClick = { menuFor = null; deleting = skill })
                                }
                            }
                        }
                    },
                    modifier = Modifier.clickable { viewing = skill },
                )
                HorizontalDivider()
            }
        }
    }

    viewing?.let { skill ->
        AlertDialog(
            onDismissRequest = { viewing = null },
            title = { Text(skill.title) },
            text = {
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    if (skill.tags.isNotEmpty()) Text(skill.tags.joinToString(" · "), style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(skill.instruction, style = MaterialTheme.typography.bodyMedium)
                }
            },
            confirmButton = { TextButton(onClick = { viewing = null }) { Text("Close") } },
        )
    }
    deleting?.let { skill ->
        AlertDialog(
            onDismissRequest = { deleting = null },
            title = { Text("Delete ${skill.title}?") },
            text = { Text("The skill is removed from this device. Export it first if you want to keep a copy.") },
            confirmButton = { TextButton(onClick = { deleting = null; store("Could not delete the skill") { it.delete(skill.id) } }) { Text("Delete") } },
            dismissButton = { TextButton(onClick = { deleting = null }) { Text("Cancel") } },
        )
    }
}
