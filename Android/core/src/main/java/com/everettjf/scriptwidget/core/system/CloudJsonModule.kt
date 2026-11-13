package com.everettjf.scriptwidget.core.system

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * `$icloud` on Android: `readJSON`, `writeJSON`, `resolveJSON`, `sync`, `status` over the store the
 * user connected this installation to in the app. Android has no iCloud; the store lives in a sync
 * folder the user chose, and the script-facing contract is the Apple runtime's.
 *
 * Order of checks, with the Apple runtime's messages:
 * 1. `[icloud:unavailable]` unless the execution belongs to an installed package (not a preview);
 * 2. `[permission_denied]` unless the manifest declares `icloud` with `minimumRuntimeVersion` 1.5 or later;
 * 3. `[icloud:read_only]` in a future timeline entry or a Live Activity presentation, for a write,
 *    resolution or sync outside a user-initiated action, and when the eight-query budget is spent;
 * 4. the store's own rules ([CloudJsonStore]).
 *
 * Reads and writes use the private cache only. After a write or resolution succeeds, one exchange
 * with the folder runs in the background for the same installation; its outcome never changes the
 * result the script already has. [onRevisionsReceived] is called when an exchange brought new revisions.
 */
class CloudJsonModule(
    private val store: CloudJsonStore,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
    private val background: (() -> Unit) -> Unit = { job -> runCatching { SystemExecutor.pool.execute(job) } },
) : NativeModule {
    /** Set by the app to redraw widgets after new revisions arrived. */
    @Volatile var onRevisionsReceived: () -> Unit = {}
    @Volatile private var lastRecovery = Long.MIN_VALUE

    override val apis: Set<String> = setOf("\$icloud")

    override fun handles(operation: String): Boolean = operation.startsWith("icloud.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        fun argument(name: String): Any? = payload?.opt(name)?.takeIf { it != JSONObject.NULL }
        when (operation) {
            "icloud.readJSON" -> runSystemCall(operation, done) { readJSON(context, argument("name")) }
            "icloud.writeJSON" -> runSystemCall(operation, done) { writeJSON(context, argument("name"), argument("value"), argument("expectedRevision")) }
            "icloud.resolveJSON" -> runSystemCall(operation, done) { resolveJSON(context, argument("name"), argument("value"), argument("expectedRevision")) }
            "icloud.sync" -> runSystemCall(operation, done) { sync(context) }
            "icloud.status" -> runSystemCall(operation, done) { status(context) }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** Steps 1 to 3 above. */
    fun gate(context: CallContext, writing: Boolean) {
        if (!context.isInstalled) throw SystemReject(NOT_INSTALLED)
        if (!context.declares(PERMISSION) || !SystemGate.supportsRuntime("1.5", context.minimumRuntimeVersion)) throw SystemReject(NOT_DECLARED)
        if (context.isTimelineProjection || context.isLiveActivity || (writing && !context.isAction) || !context.consumeDataQuery()) throw SystemReject(READ_ONLY)
    }

    /** Cached `{value, revision, state, conflicts}`; see [CloudJsonStore.read]. */
    fun readJSON(context: CallContext, name: Any?): String {
        gate(context, writing = false)
        return store.read(context.installation, name)
    }

    /** A new revision on top of the single observed head; see [CloudJsonStore.write]. User action only. */
    fun writeJSON(context: CallContext, name: Any?, value: Any?, expectedRevision: Any?): String = write(context, name, value, expectedRevision, resolving = false)

    /** A new revision that supersedes every observed conflicting head. User action only. */
    fun resolveJSON(context: CallContext, name: Any?, value: Any?, expectedRevision: Any?): String = write(context, name, value, expectedRevision, resolving = true)

    private fun write(context: CallContext, name: Any?, value: Any?, expected: Any?, resolving: Boolean): String {
        gate(context, writing = true)
        val result = store.write(context.installation, name, value, expected, resolving)
        val installation = context.installation
        background { exchange(installation) }
        return result
    }

    /** Exchanges revision files with the folder now; see [CloudJsonStore.synchronize]. User action only. */
    fun sync(context: CallContext): String {
        gate(context, writing = true)
        return store.synchronize(context.installation).also { notifyIfReceived(it) }
    }

    /** `{state, store, uploaded:null, uploadState:"unknown", conflictPolicy:"preserveAllVersions"}`. */
    fun status(context: CallContext): String {
        gate(context, writing = false)
        return store.status(context.installation)
    }

    /**
     * One exchange for [installation] outside any execution: after a write, from the app's "Sync
     * now" and on app foreground. Returns the rejection code, or null on success. The grant is read
     * again inside, so a removed or reconnected installation is not followed.
     */
    fun exchange(installation: String): String? {
        val failure = try { notifyIfReceived(store.synchronize(installation)); null } catch (error: SystemReject) { SystemLog.code(error.message.orEmpty()) } catch (error: Exception) { "error" }
        SystemLog.call("icloud.exchange", failure ?: "ok")
        return failure
    }

    /** App foreground recovery: exchanges every connected installation, at most once every 15 seconds. */
    fun recover(installations: List<String>) {
        val now = clock.now()
        synchronized(this) {
            if (lastRecovery != Long.MIN_VALUE && now - lastRecovery in 0 until RECOVERY_INTERVAL_MILLISECONDS) return
            lastRecovery = now
        }
        for (installation in installations) if (runCatching { store.connection(installation) }.isSuccess) background { exchange(installation) }
    }

    /** Revokes the connection of a deleted installation. Revision files and the cache stay. */
    fun retire(installation: String) {
        store.disconnect(installation)
        SystemLog.call("icloud.retire", "ok")
    }

    private fun notifyIfReceived(result: String) {
        if (runCatching { JSONObject(result).optInt("downloadedRevisions", 0) > 0 }.getOrDefault(false)) runCatching { onRevisionsReceived() }
    }

    companion object {
        const val PERMISSION = "icloud"
        const val RECOVERY_INTERVAL_MILLISECONDS = 15_000L
        const val NOT_INSTALLED = "[icloud:unavailable] Install the widget and connect iCloud JSON in the app. Native CLI and template previews cannot access iCloud."
        const val NOT_DECLARED = "[permission_denied] Declare icloud in widget.json and connect this installation in the app."
        const val READ_ONLY = "[icloud:read_only] Writes and sync require a user action; future/Live Activity presentations cannot access iCloud JSON."
    }
}

/**
 * Which folder holds the synced documents: a Storage Access Framework tree the user picked (a cloud
 * provider's folder or device storage) or a directory inside the app for this device only. The
 * choice is device-local and never part of a package. A malformed settings file means no folder.
 */
class CloudFolderSettings(context: Context, private val file: PrivateFile, private val localDirectory: File) {
    private val appContext = context.applicationContext

    /** Instrumented tests set this to make a plain directory stand in for the picked tree. Never set in production. */
    @Volatile var testFolder: CloudFolder? = null

    /** [kind] is `tree` (with the tree [uri]) or `local`. */
    class Choice(val kind: String, val uri: String)

    /** The stored choice, or null when none is stored or the file is not valid. */
    fun choice(): Choice? = synchronized(file.lock) {
        runCatching {
            val root = JSONObject(file.read() ?: return@runCatching null)
            val kind = root.get("kind") as? String
            val uri = root.get("uri") as? String
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "kind", "uri") || root.get("formatVersion") != 1 || kind == null || uri == null ||
                uri.toByteArray().size > 2048 || !((kind == "local" && uri.isEmpty()) || (kind == "tree" && uri.startsWith("content://")))) null else Choice(kind, uri)
        }.getOrNull()
    }

    /**
     * The folder and its identity for [CloudJsonStore]. The identity is a digest of the kind and the
     * tree URI, so connections made for one folder are refused (`accountChanged`) after another is chosen
     * and work again when the same folder is chosen again.
     */
    fun current(): CloudFolder? {
        testFolder?.let { return it }
        val choice = choice() ?: return null
        val account = Canonical.sha256("scriptwidget-sync-folder\n${choice.kind}\n${choice.uri}")
        return CloudFolder(account, if (choice.kind == "local") FileSyncFolder(localDirectory) else TreeSyncFolder(appContext, Uri.parse(choice.uri)))
    }

    /** Stores a picked tree and keeps read and write access to it across restarts. False when the provider does not offer persistable access. */
    fun chooseTree(uri: Uri): Boolean {
        val flags = Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        if (runCatching { appContext.contentResolver.takePersistableUriPermission(uri, flags) }.isFailure) return false
        val previous = choice()
        val stored = synchronized(file.lock) { file.write(JSONObject().put("formatVersion", 1).put("kind", "tree").put("uri", uri.toString()).toString()) }
        if (stored && previous?.kind == "tree" && previous.uri != uri.toString()) release(previous.uri)
        SystemLog.call("icloud.folder", if (stored) "tree" else "error")
        return stored
    }

    /** Keeps synced documents in a private directory of this device; nothing leaves it. */
    fun chooseLocal(): Boolean {
        val previous = choice()
        localDirectory.mkdirs()
        val stored = synchronized(file.lock) { file.write(JSONObject().put("formatVersion", 1).put("kind", "local").put("uri", "").toString()) }
        if (stored && previous?.kind == "tree") release(previous.uri)
        SystemLog.call("icloud.folder", if (stored) "local" else "error")
        return stored
    }

    /** Forgets the folder and gives up access to it. Files in the folder, the cache and the connections are kept. */
    fun clear() {
        val previous = choice()
        synchronized(file.lock) { file.delete() }
        if (previous?.kind == "tree") release(previous.uri)
        SystemLog.call("icloud.folder", "cleared")
    }

    private fun release(uri: String) {
        runCatching { appContext.contentResolver.releasePersistableUriPermission(Uri.parse(uri), Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
    }
}

/**
 * A [SyncFolder] over a document tree picked with `ACTION_OPEN_DOCUMENT_TREE`. Only
 * `DocumentsContract` is used. Display names, types and sizes come from the provider and are
 * treated as untrusted by the caller; virtual documents are [SyncNode.Kind.OTHER].
 *
 * A provider may rename what it creates (a duplicate name, a changed extension). A created entry
 * whose name is not exactly the requested one is deleted again and the operation fails. A new file
 * is read back and compared before it counts as written.
 */
class TreeSyncFolder(context: Context, private val tree: Uri) : SyncFolder {
    private val resolver = context.applicationContext.contentResolver

    override val root: SyncNode get() = SyncNode("", SyncNode.Kind.DIRECTORY, 0, DocumentsContract.getTreeDocumentId(tree))

    /** A local check of the persisted permission; the provider is not contacted. */
    override val isAvailable: Boolean get() = runCatching { resolver.persistedUriPermissions.any { it.uri == tree && it.isReadPermission && it.isWritePermission } }.getOrDefault(false)

    private fun document(node: SyncNode): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, node.handle as String)

    private fun <T> guarded(block: () -> T): T = try { block() } catch (error: SyncFolderException) { throw error } catch (error: Exception) { throw SyncFolderException() }

    override fun children(directory: SyncNode, maximum: Int): List<SyncNode> = guarded {
        val columns = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME, DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_FLAGS)
        val result = ArrayList<SyncNode>()
        (resolver.query(DocumentsContract.buildChildDocumentsUriUsingTree(tree, directory.handle as String), columns, null, null, null) ?: throw SyncFolderException()).use { cursor ->
            while (cursor.moveToNext()) {
                if (result.size >= maximum) throw SyncFolderException(tooMany = true)
                val id = cursor.getString(0) ?: throw SyncFolderException()
                val name = cursor.getString(1)
                val virtual = !cursor.isNull(4) && cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT != 0
                val kind = when { name == null || virtual -> SyncNode.Kind.OTHER; cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR -> SyncNode.Kind.DIRECTORY; else -> SyncNode.Kind.FILE }
                result += SyncNode(name.orEmpty(), kind, if (cursor.isNull(3)) 0 else cursor.getLong(3), id)
            }
        }
        result
    }

    override fun read(file: SyncNode, maximumBytes: Int): ByteArray = guarded {
        (resolver.openInputStream(document(file)) ?: throw SyncFolderException()).use { input ->
            val buffer = ByteArrayOutputStream()
            val chunk = ByteArray(8192)
            while (true) {
                val count = input.read(chunk)
                if (count < 0) break
                buffer.write(chunk, 0, count)
                if (buffer.size() > maximumBytes) throw SyncFolderException()
            }
            buffer.toByteArray()
        }
    }

    override fun createDirectory(parent: SyncNode, name: String): SyncNode = guarded {
        children(parent, 4096).firstOrNull { it.name == name && it.kind == SyncNode.Kind.DIRECTORY } ?: create(parent, DocumentsContract.Document.MIME_TYPE_DIR, name, SyncNode.Kind.DIRECTORY, 0)
    }

    override fun createFile(parent: SyncNode, name: String, bytes: ByteArray): SyncNode = guarded {
        if (children(parent, 4096).any { it.name == name }) throw SyncFolderException()
        val node = create(parent, "application/json", name, SyncNode.Kind.FILE, bytes.size.toLong())
        try {
            (resolver.openOutputStream(document(node), "wt") ?: throw SyncFolderException()).use { it.write(bytes) }
            if (!read(node, bytes.size).contentEquals(bytes)) throw SyncFolderException()
        } catch (error: Exception) {
            runCatching { DocumentsContract.deleteDocument(resolver, document(node)) }
            throw SyncFolderException()
        }
        node
    }

    private fun create(parent: SyncNode, mimeType: String, name: String, kind: SyncNode.Kind, size: Long): SyncNode {
        val created = DocumentsContract.createDocument(resolver, document(parent), mimeType, name) ?: throw SyncFolderException()
        val actual = resolver.query(created, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        if (actual != name) {
            runCatching { DocumentsContract.deleteDocument(resolver, created) }
            throw SyncFolderException()
        }
        return SyncNode(name, kind, size, DocumentsContract.getDocumentId(created))
    }
}
