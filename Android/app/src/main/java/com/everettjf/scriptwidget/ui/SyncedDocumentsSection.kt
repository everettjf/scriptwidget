package com.everettjf.scriptwidget.ui

import android.net.Uri
import android.provider.DocumentsContract
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ListItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.core.system.CloudFolderSettings
import com.everettjf.scriptwidget.core.system.CloudJsonRules
import com.everettjf.scriptwidget.core.system.SystemLog
import com.everettjf.scriptwidget.core.system.SystemReject
import com.everettjf.scriptwidget.core.system.SystemStores
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The "Synced documents" part of System Access: the folder `$icloud` exchanges files with, the
 * stores in it, and which store each widget is connected to. A widget can never choose a folder or
 * a store itself. Folder access happens off the main thread; names of documents are shown here but
 * never logged.
 *
 * [revision] changes whenever state must be read again; [changed] asks the screen to do so.
 */
@Composable
internal fun SyncedDocumentsSection(stores: SystemStores, revision: Int, changed: () -> Unit, report: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var busy by remember { mutableStateOf(false) }
    val choice = remember(revision) { stores.cloudFolder.choice() }
    val available = remember(revision) { runCatching { stores.cloudFolder.current()?.folder?.isAvailable == true }.getOrDefault(false) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        if (uri != null) {
            report(if (stores.cloudFolder.chooseTree(uri)) "Sync folder chosen. Connect widgets to a store below." else "That folder cannot be kept across restarts. Choose a folder from another location.")
            changed()
        }
    }
    /** Runs folder work off the main thread and reports one sentence. */
    fun folderWork(work: () -> String) {
        if (busy) return
        busy = true
        scope.launch {
            val text = withContext(Dispatchers.IO) { runCatching(work).getOrElse { cloudMessage((it as? SystemReject)?.message) } }
            busy = false
            report(text)
            changed()
        }
    }

    AccessSection("Synced documents")
    ListItem(
        headlineContent = { Text(when {
            choice == null -> "No sync folder chosen"
            choice.kind == "local" -> "Kept on this device only"
            available -> "Sync folder: ${folderLabel(choice)}"
            else -> "Sync folder access was lost: ${folderLabel(choice)}"
        }) },
        supportingContent = { Text("Widgets that declare iCloud data (\$icloud) keep JSON documents here instead of iCloud, which Android does not have. " +
            "Choose a folder of a cloud storage app (or on this device) and the files in it are exchanged when a widget saves, when you open ScriptWidget and when you tap Sync now. " +
            "Your cloud app uploads them on its own schedule; ScriptWidget cannot tell whether a file has left this device. " +
            "Every version is kept as its own file. Do not edit, rename or delete those files: a changed file stops the exchange until it is restored.") },
    )
    Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(enabled = !busy, onClick = { runCatching { picker.launch(null) }.onFailure { report("No files app is available on this device.") } }) { Text(if (choice?.kind == "tree") "Replace folder" else "Choose folder") }
        if (choice?.kind != "local") OutlinedButton(enabled = !busy, onClick = {
            report(if (stores.cloudFolder.chooseLocal()) "Documents stay on this device. Widgets connected to the same store still share them." else "The setting could not be saved.")
            changed()
        }) { Text("This device only") }
        if (choice != null) OutlinedButton(enabled = !busy, onClick = {
            stores.cloudFolder.clear()
            report("Sync folder disconnected. Its files and the copies on this device were kept; choose the same folder again to continue.")
            changed()
        }) { Text("Disconnect folder") }
    }
    if (choice != null && choice.kind == "tree") ListItem(headlineContent = { Text("Changing the folder", style = MaterialTheme.typography.bodyMedium) },
        supportingContent = { Text("Widgets stay connected to stores of the folder they were connected in. After choosing another folder, connect them again there.") })

    val packages = remember(revision) { AppServices.library.list().filter { "icloud" in it.permissions } }
    // Reading the folder can be slow for a cloud provider: listed off the main thread, empty until it answers.
    val folderStores by produceState<List<String>?>(null, revision, choice?.uri, choice?.kind) {
        value = if (choice == null) emptyList() else withContext(Dispatchers.IO) { runCatching { stores.cloudStore.availableStores() }.getOrNull() }
    }
    val connections = remember(revision) { packages.associate { it.installation to runCatching { stores.cloudStore.connection(it.installation) } } }
    if (choice != null) {
        val found = folderStores
        ListItem(headlineContent = { Text(when { found == null -> "Stores in this folder could not be listed"; found.isEmpty() -> "No stores in this folder yet"; else -> "${found.size} store${if (found.size == 1) "" else "s"} in this folder" }) },
            supportingContent = { Text("A store is one shared space of documents. Give each widget its own store to keep its data separate, or connect several widgets (on this or another device) to the same store to share it. " +
                "Only connect widgets you trust with that data.") })
        OutlinedButton(modifier = Modifier.padding(horizontal = 16.dp), enabled = !busy && connections.values.any { it.isSuccess }, onClick = {
            folderWork {
                val outcomes = packages.filter { connections[it.installation]?.isSuccess == true }.map { stores.cloud.exchange(it.installation) }
                val failed = outcomes.filterNotNull()
                if (failed.isEmpty()) "Exchanged files with the sync folder for ${outcomes.size} widget${if (outcomes.size == 1) "" else "s"}. Uploading is up to your cloud app."
                else "${failed.size} of ${outcomes.size} exchanges did not finish. ${cloudMessage("[${failed.first()}]")}"
            }
        }) { Text(if (busy) "Working…" else "Sync now") }
    }

    if (packages.isEmpty()) ListItem(headlineContent = { Text("No installed widget asks for synced documents") })
    for (item in packages) {
        val connection = connections[item.installation]
        val store = connection?.getOrNull()
        val problem = SystemLog.code((connection?.exceptionOrNull() as? SystemReject)?.message.orEmpty())
        val documents = remember(revision, item.installation) { if (store == null) null else runCatching { stores.cloudStore.documents(item.installation) }.getOrNull() }
        val conflicts = documents.orEmpty().count { it.heads > 1 }
        ListItem(headlineContent = { Text(item.displayName) },
            supportingContent = { Text(when {
                store != null -> "Connected to store ${shortStore(store)}" + (packages.filter { it !== item && connections[it.installation]?.getOrNull() == store }.takeIf { it.isNotEmpty() }?.let { shared -> ", shared with ${shared.joinToString { it.displayName }}" } ?: "") + "." +
                    when { documents == null -> " Its saved documents could not be read."; documents.isEmpty() -> " No documents saved on this device yet."; else -> "" } +
                    (if (conflicts > 0) " $conflicts document${if (conflicts == 1) " has" else "s have"} versions written on different devices at the same time. Both are kept; open the widget to choose or merge them." else "")
                problem == "icloud:accountChanged" -> "Connected in another sync folder. Choose that folder again, or connect this widget to a store here."
                problem == "icloud:notConnected" -> "Not connected. The widget shows its setup state until you connect it to a store."
                else -> "Its connection could not be read. Connect it again."
            }) })
        for (document in documents.orEmpty()) ListItem(modifier = Modifier.padding(start = 16.dp),
            headlineContent = { Text(document.name, style = MaterialTheme.typography.bodyMedium) },
            supportingContent = { Text("${document.revisions} version${if (document.revisions == 1) "" else "s"} kept" + when { document.heads > 1 -> " · ${document.heads} conflicting versions"; document.heads == 0 -> " · waiting for an earlier version from the folder"; else -> "" }) })
        if (choice != null) Row(Modifier.horizontalScroll(rememberScrollState()).padding(start = 32.dp, end = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(enabled = !busy, onClick = {
                folderWork { "Connected to the new store ${shortStore(stores.cloudStore.connect(item.installation))}.".also { SystemLog.call("access.icloud.connect", "new") } }
            }) { Text("New store") }
            var choosing by remember(item.installation) { mutableStateOf(false) }
            val others = folderStores.orEmpty().filter { it != store }
            Box {
                OutlinedButton(enabled = !busy && others.isNotEmpty(), onClick = { choosing = true }) { Text("Existing store") }
                DropdownMenu(expanded = choosing, onDismissRequest = { choosing = false }) {
                    for (candidate in others.take(CloudJsonRules.MAXIMUM_STORES)) {
                        val users = packages.filter { connections[it.installation]?.getOrNull() == candidate }
                        DropdownMenuItem(text = { Text(shortStore(candidate) + if (users.isEmpty()) "" else " · ${users.joinToString { it.displayName }}") }, onClick = {
                            choosing = false
                            folderWork {
                                stores.cloudStore.connect(item.installation, existingStore = candidate)
                                stores.cloud.exchange(item.installation)
                                SystemLog.call("access.icloud.connect", "existing")
                                "Connected to store ${shortStore(candidate)}. This widget can now read and change its documents."
                            }
                        })
                    }
                }
            }
            if (connection?.isSuccess == true || problem != "icloud:notConnected") TextButton(enabled = !busy, onClick = {
                stores.cloudStore.disconnect(item.installation)
                SystemLog.call("access.icloud.disconnect", "ok")
                report("Disconnected. The documents were kept in the folder and on this device.")
                changed()
            }) { Text("Disconnect") }
        }
    }
}

/** The first eight characters of a store id: enough to tell stores apart on two devices. */
private fun shortStore(store: String): String = store.take(8)

/** The folder's own name from the tree identifier, for display only. */
private fun folderLabel(choice: CloudFolderSettings.Choice): String = runCatching {
    val id = DocumentsContract.getTreeDocumentId(Uri.parse(choice.uri))
    id.substringAfterLast('/').substringAfterLast(':').ifEmpty { id }.take(64)
}.getOrDefault("chosen folder").ifEmpty { "chosen folder" }

/** A sentence for an `[icloud:…]` rejection. */
private fun cloudMessage(rejection: String?): String = when (SystemLog.code(rejection.orEmpty())) {
    "icloud:unavailable" -> "The sync folder or the store in it could not be reached. If the store was deleted there, connect the widget to a new store."
    "icloud:invalidData" -> "A file in the sync folder is not a valid version file (it may have been edited or is still being copied). Nothing was changed on this device."
    "icloud:limitExceeded" -> "The store is full (256 versions or 2 MiB). Connect the widget to a new store; nothing is removed automatically."
    "icloud:accountChanged" -> "This widget is connected in another sync folder."
    "icloud:notConnected" -> "This widget is not connected to a store."
    "icloud:identityChanged" -> "The connection changed while files were being exchanged. Try again."
    else -> "The sync folder could not be used. Check that the folder still exists and try again."
}
