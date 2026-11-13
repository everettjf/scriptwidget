package com.everettjf.scriptwidget.core.system

import com.everettjf.scriptwidget.core.plugin.StrictJson
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest
import java.util.UUID

/**
 * The `$icloud` error codes. The names and the sentence are the Apple runtime's, so a script that
 * matches on `[icloud:staleRevision]` behaves the same on Android.
 */
enum class CloudJsonError(val code: String) {
    UNAVAILABLE("unavailable"), NOT_CONNECTED("notConnected"), ACCOUNT_CHANGED("accountChanged"), INVALID_NAME("invalidName"),
    INVALID_DATA("invalidData"), LIMIT_EXCEEDED("limitExceeded"), CONFLICT("conflict"), STALE_REVISION("staleRevision"),
    IDENTITY_CHANGED("identityChanged");

    val message: String get() = "[icloud:$code] iCloud JSON operation could not complete. Existing records are preserved."
    fun reject(): SystemReject = SystemReject(message)
}

/** One entry of a [SyncFolder]. [handle] belongs to the folder that produced the node. */
class SyncNode(val name: String, val kind: Kind, val size: Long, val handle: Any) {
    /** [OTHER] is anything that is neither a plain directory nor a plain file: links, virtual documents, devices. */
    enum class Kind { DIRECTORY, FILE, OTHER }
}

/** A folder operation failed. [tooMany] means a listing was longer than the caller's bound. */
class SyncFolderException(val tooMany: Boolean = false) : Exception(if (tooMany) "too many entries" else "folder operation failed")

/**
 * The folder revision files are exchanged with: a Storage Access Framework tree the user picked, or
 * a plain directory. Everything it returns is untrusted; callers validate names, kinds, sizes and
 * content. It never deletes or overwrites.
 */
interface SyncFolder {
    val root: SyncNode

    /** True when the folder can be used without asking the user again. Must not block on a remote provider. */
    val isAvailable: Boolean

    /** The entries of [directory]. Throws [SyncFolderException] (`tooMany`) when there are more than [maximum]. */
    fun children(directory: SyncNode, maximum: Int): List<SyncNode>

    /** The bytes of [file]; throws when it is larger than [maximumBytes] or cannot be read. */
    fun read(file: SyncNode, maximumBytes: Int): ByteArray

    /** Creates the directory [name] in [parent], or returns the existing one. */
    fun createDirectory(parent: SyncNode, name: String): SyncNode

    /** Creates the new file [name] in [parent] holding exactly [bytes]. Throws when the name is taken. */
    fun createFile(parent: SyncNode, name: String, bytes: ByteArray): SyncNode
}

/**
 * A [SyncFolder] over a plain directory: the private cache, the "this device only" option and the
 * stand-in for a document tree in tests. Symbolic links are reported as [SyncNode.Kind.OTHER] and
 * never followed; a new file appears under its final name only once it is complete.
 */
class FileSyncFolder(private val directory: File) : SyncFolder {
    override val root: SyncNode get() = SyncNode("", SyncNode.Kind.DIRECTORY, 0, directory)

    override val isAvailable: Boolean get() = Files.isDirectory(directory.toPath(), LinkOption.NOFOLLOW_LINKS)

    override fun children(directory: SyncNode, maximum: Int): List<SyncNode> {
        val result = ArrayList<SyncNode>()
        try {
            Files.newDirectoryStream((directory.handle as File).toPath()).use { stream ->
                for (path in stream) {
                    if (result.size >= maximum) throw SyncFolderException(tooMany = true)
                    val attributes = Files.readAttributes(path, BasicFileAttributes::class.java, LinkOption.NOFOLLOW_LINKS)
                    val kind = when { attributes.isSymbolicLink -> SyncNode.Kind.OTHER; attributes.isDirectory -> SyncNode.Kind.DIRECTORY; attributes.isRegularFile -> SyncNode.Kind.FILE; else -> SyncNode.Kind.OTHER }
                    result += SyncNode(path.fileName.toString(), kind, attributes.size(), path.toFile())
                }
            }
        } catch (error: IOException) { throw SyncFolderException() } catch (error: java.nio.file.DirectoryIteratorException) { throw SyncFolderException() }
        return result
    }

    override fun read(file: SyncNode, maximumBytes: Int): ByteArray {
        val path = (file.handle as File).toPath()
        try {
            if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || Files.size(path) > maximumBytes) throw SyncFolderException()
            return Files.readAllBytes(path).also { if (it.size > maximumBytes) throw SyncFolderException() }
        } catch (error: IOException) { throw SyncFolderException() }
    }

    override fun createDirectory(parent: SyncNode, name: String): SyncNode {
        val target = child(parent, name)
        try {
            if (!Files.isDirectory(target.toPath(), LinkOption.NOFOLLOW_LINKS)) Files.createDirectory(target.toPath())
        } catch (error: IOException) { throw SyncFolderException() }
        return SyncNode(name, SyncNode.Kind.DIRECTORY, 0, target)
    }

    override fun createFile(parent: SyncNode, name: String, bytes: ByteArray): SyncNode {
        val target = child(parent, name)
        val temporary = File(parent.handle as File, ".revision-" + UUID.randomUUID())
        try {
            if (Files.exists(target.toPath(), LinkOption.NOFOLLOW_LINKS)) throw SyncFolderException()
            java.io.FileOutputStream(temporary).use { it.write(bytes); it.fd.sync() }
            Files.move(temporary.toPath(), target.toPath(), StandardCopyOption.ATOMIC_MOVE)
        } catch (error: IOException) { throw SyncFolderException() } finally { runCatching { Files.deleteIfExists(temporary.toPath()) } }
        return SyncNode(name, SyncNode.Kind.FILE, bytes.size.toLong(), target)
    }

    /** A direct child only: a name with a separator or a dot segment never becomes a path. */
    private fun child(parent: SyncNode, name: String): File {
        if (name.isEmpty() || name == "." || name == ".." || name.any { it == '/' || it == '\\' || it == '\u0000' }) throw SyncFolderException()
        return File(parent.handle as File, name)
    }
}

/** One immutable revision of a document. [id] is the SHA-256 of [bytes], which is also the file name. */
class CloudRevision(val id: String, val name: String, val parents: List<String>, val value: Map<String, Any?>, val bytes: ByteArray)

/**
 * Names, limits and the revision file format of `$icloud`.
 *
 * A store is `WidgetData/<store UUID>/<document name>/<SHA-256>.json`, the layout the Apple runtime
 * uses in its iCloud container. A revision file is one JSON object with exactly `formatVersion` (1),
 * `name`, `parents` (sorted, unique revision ids) and `value` (an object).
 */
object CloudJsonRules {
    /** Bytes of one encoded `value`. */
    const val MAXIMUM_VALUE_BYTES = 64 * 1024
    /** Revisions per store, over all documents. */
    const val MAXIMUM_REVISIONS = 256
    /** Bytes of all revision files of a store. */
    const val MAXIMUM_BYTES = 2 * 1024 * 1024
    /** Document names per store. */
    const val MAXIMUM_DOCUMENTS = 128
    /** Stores listed in a folder. */
    const val MAXIMUM_STORES = 128
    /** Bytes of one revision file: the value plus room for the parents. */
    const val MAXIMUM_FILE_BYTES = MAXIMUM_VALUE_BYTES + 64 * 1024
    /** Deepest nesting inside `value`, as in the preview engine. */
    const val MAXIMUM_DEPTH = 32
    const val STORES_DIRECTORY = "WidgetData"

    private val name = Regex("^[a-z][a-z0-9_-]{0,58}\\.json$")
    private val revision = Regex("^[a-f0-9]{64}$")
    private val temporary = Regex("^\\.revision-[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")

    /** Document names are flat lowercase ASCII file names: `/^[a-z][a-z0-9_-]{0,58}\.json$/`. */
    fun validName(value: String): Boolean = name.matches(value)

    /** Store identifiers are canonical lowercase UUIDs made by the app; a script never supplies one. */
    fun validStore(value: String): Boolean = CallContext.isOwner(value)

    /** Revision identifiers are 64 lowercase hexadecimal digits. */
    fun validRevision(value: String): Boolean = revision.matches(value)

    /** A file another writer has not finished publishing; it is skipped, never read. */
    fun isTemporary(fileName: String): Boolean = temporary.matches(fileName)

    fun hash(bytes: ByteArray): String = MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) }

    /**
     * Plain Kotlin data (`Map`, `List`, `String`, `Long`, `Double`, `Boolean`, null) for a JSON value
     * that arrived from a script, or `invalidData` when it is nested deeper than 32 levels or holds
     * a value JSON cannot express.
     */
    fun plain(value: Any?, depth: Int = 0): Any? {
        if (depth > MAXIMUM_DEPTH) throw CloudJsonError.INVALID_DATA.reject()
        return when (value) {
            null, JSONObject.NULL -> null
            is JSONObject -> value.keys().asSequence().associateWithTo(LinkedHashMap()) { plain(value.opt(it), depth + 1) }
            is JSONArray -> List(value.length()) { plain(value.opt(it), depth + 1) }
            is Map<*, *> -> value.entries.associateTo(LinkedHashMap()) { (key, member) -> (key as? String ?: throw CloudJsonError.INVALID_DATA.reject()) to plain(member, depth + 1) }
            is List<*> -> value.map { plain(it, depth + 1) }
            is String, is Boolean -> value
            is Int, is Long, is Short, is Byte -> (value as Number).toLong()
            is Number -> value.toDouble().also { if (!it.isFinite()) throw CloudJsonError.INVALID_DATA.reject() }
            else -> throw CloudJsonError.INVALID_DATA.reject()
        }
    }

    /**
     * Deterministic JSON text of plain data: object keys in UTF-16 code unit order, no insignificant
     * white space, slashes not escaped, whole numbers below 2^53 without a fraction. Equal values
     * always give equal bytes, so the same write on two devices is the same revision.
     */
    fun canonical(value: Any?): String = StringBuilder().also { encode(value, it) }.toString()

    private fun encode(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Map<*, *> -> {
                out.append('{')
                value.keys.map { it as String }.sorted().forEachIndexed { index, key -> if (index > 0) out.append(','); out.append(StrictJson.quote(key)).append(':'); encode(value[key], out) }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { index, member -> if (index > 0) out.append(','); encode(member, out) }
                out.append(']')
            }
            is String -> out.append(StrictJson.quote(value))
            is Boolean -> out.append(value.toString())
            is Long -> out.append(value.toString())
            is Double -> when {
                !value.isFinite() -> throw CloudJsonError.INVALID_DATA.reject()
                value == Math.rint(value) && Math.abs(value) < 9.007199254740992E15 -> out.append(value.toLong().toString())
                else -> out.append(value.toString())
            }
            else -> throw CloudJsonError.INVALID_DATA.reject()
        }
    }

    /** The file bytes of a new revision of [name] whose parents are [parents]. */
    fun encodeRevision(name: String, parents: List<String>, value: Map<String, Any?>): ByteArray =
        canonical(linkedMapOf("formatVersion" to 1L, "name" to name, "parents" to parents.sorted(), "value" to value)).toByteArray()

    /**
     * Validates one revision file. Every rule failing is `invalidData`:
     * - [id] is 64 lowercase hexadecimal digits and equals the SHA-256 of [bytes];
     * - at most 128 KiB of well-formed UTF-8 JSON without repeated keys;
     * - an object with exactly `formatVersion`, `name`, `parents`, `value`; `formatVersion` is the integer 1;
     * - `name` equals the directory the file was found in ([name]);
     * - `parents` is a sorted list of at most 256 distinct revision ids, none of them [id] itself;
     * - `value` is an object nested at most 32 levels whose encoding is at most 64 KiB.
     *
     * The byte order of keys is not required to be this implementation's: the identity of a revision
     * is the hash of its bytes, whoever wrote them.
     */
    fun decode(bytes: ByteArray, id: String, name: String): CloudRevision {
        val invalid = { CloudJsonError.INVALID_DATA.reject() }
        if (!validRevision(id) || !validName(name) || bytes.size > MAXIMUM_FILE_BYTES || hash(bytes) != id) throw invalid()
        val root = try {
            StrictJson.parse(DocumentRules.decodeUtf8(bytes) ?: throw invalid()) as? Map<*, *>
        } catch (error: StrictJson.JsonException) { null } catch (error: StackOverflowError) { null } ?: throw invalid()
        if (root.keys != setOf("formatVersion", "name", "parents", "value") || root["formatVersion"] != 1L || root["name"] != name) throw invalid()
        val parents = (root["parents"] as? List<*> ?: throw invalid()).map { it as? String ?: throw invalid() }
        if (parents.size > MAXIMUM_REVISIONS || parents != parents.sorted() || parents.toSet().size != parents.size || parents.any { it == id || !validRevision(it) }) throw invalid()
        @Suppress("UNCHECKED_CAST")
        val value = plain(root["value"] as? Map<*, *> ?: throw invalid()) as Map<String, Any?>
        if (canonical(value).toByteArray().size > MAXIMUM_VALUE_BYTES) throw invalid()
        return CloudRevision(id, name, parents, value, bytes)
    }
}

/** The revision graph of one document: which revisions are current and what a script is told. */
object CloudJsonGraph {
    /**
     * The heads of [name]: its revisions that no other revision of the document names as a parent,
     * ordered by id. One head is the current value; several are a conflict; none means no data.
     *
     * - A parent that is not present makes the history unreliable: `unavailable` until it arrives.
     * - Parent links that form a cycle are `invalidData`. Real files cannot form one, because an id
     *   is the hash of the bytes that contain the parent ids.
     */
    fun heads(revisions: Collection<CloudRevision>, name: String): List<CloudRevision> {
        val selected = revisions.filter { it.name == name }
        val byID = selected.associateBy { it.id }
        if (selected.any { revision -> revision.parents.any { it !in byID } }) throw CloudJsonError.UNAVAILABLE.reject()
        // Remove revisions whose parents are all removed; anything left sits on a cycle.
        val remaining = selected.associateTo(HashMap()) { it.id to it.parents.size }
        val children = HashMap<String, MutableList<String>>()
        for (revision in selected) for (parent in revision.parents) children.getOrPut(parent) { ArrayList() } += revision.id
        val ready = ArrayDeque(selected.filter { it.parents.isEmpty() }.map { it.id })
        var ordered = 0
        while (ready.isNotEmpty()) {
            val id = ready.removeFirst()
            ordered += 1
            for (child in children[id].orEmpty()) if (remaining.merge(child, -1, Int::plus) == 0) ready += child
        }
        if (ordered != selected.size) throw CloudJsonError.INVALID_DATA.reject()
        val parents = selected.flatMapTo(HashSet()) { it.parents }
        return selected.filter { it.id !in parents }.sortedBy { it.id }
    }

    /** The opaque revision token of a set of heads: empty without data, else a digest of the sorted head ids. */
    fun token(heads: List<CloudRevision>): String = if (heads.isEmpty()) "" else CloudJsonRules.hash(heads.joinToString("\n") { it.id }.toByteArray())

    /**
     * `{value, revision, state, conflicts}` for [name]. One head: its value. Several heads:
     * `state:"conflict"`, `value:null` and every head as `{id, value}`. [pending] marks the result
     * of a local write; neither `cached` nor `pending` says anything about upload.
     */
    fun response(revisions: Collection<CloudRevision>, name: String, pending: Boolean): String {
        val heads = heads(revisions, name)
        val result = LinkedHashMap<String, Any?>()
        result["value"] = if (heads.size == 1) heads[0].value else null
        result["revision"] = token(heads)
        result["state"] = if (heads.size > 1) "conflict" else if (pending) "pending" else "cached"
        result["conflicts"] = if (heads.size > 1) heads.map { linkedMapOf("id" to it.id, "value" to it.value) } else emptyList<Any>()
        return CloudJsonRules.canonical(result)
    }
}

/** The sync folder the user chose and its identity. A different folder is a different [account]. */
class CloudFolder(val account: String, val folder: SyncFolder)

/** What the app shows for one document of a store. More than one head is a conflict. */
class CloudDocumentState(val name: String, val revisions: Int, val heads: Int)

/**
 * JSON documents as immutable, content-addressed revisions, shared between devices through a
 * folder. The Android counterpart of `ScriptWidgetCloudJSONStore`.
 *
 * - Authority is a native grant per installation (`grants/<installation>.json`), written only by
 *   the app. It names one store and the folder identity it was made for. A script supplies a
 *   document name, never a store.
 * - Reads and writes use the private cache (`cache/<folder identity>/<store>`) and never touch the
 *   folder, so a widget is never blocked by a remote provider.
 * - A write adds one revision whose parents are the heads the caller observed. Nothing is ever
 *   overwritten or deleted, so two devices that write at the same time leave two heads.
 * - [synchronize] copies revisions in both directions. Folder content is validated like any other
 *   untrusted input; a bad file stops the exchange and leaves the cache as it was.
 */
class CloudJsonStore(private val directory: File, private val environment: () -> CloudFolder?) {
    private val lock = Any()
    private val exchangeLock = Any()

    private class Grant(val store: String, val account: String)

    private fun grantFile(installation: String) = PrivateFile(File(directory, "grants/$installation.json"), 2048)
    private fun cache(grant: Grant) = FileSyncFolder(File(directory, "cache/${grant.account}/${grant.store}"))

    /**
     * The grant of [installation]: `notConnected` without one, `invalidData` when the file is
     * malformed, `accountChanged` when it was made for another folder than the current one.
     */
    private fun grant(installation: String): Grant {
        if (!CallContext.isOwner(installation)) throw CloudJsonError.NOT_CONNECTED.reject()
        val text = try { grantFile(installation).read() } catch (error: PrivateFile.Unreadable) { throw CloudJsonError.INVALID_DATA.reject() } ?: throw CloudJsonError.NOT_CONNECTED.reject()
        val root = try { StrictJson.parse(text) as? Map<*, *> } catch (error: StrictJson.JsonException) { null } ?: throw CloudJsonError.INVALID_DATA.reject()
        val store = root["store"] as? String
        val account = root["account"] as? String
        if (root.keys != setOf("version", "store", "account") || root["version"] != 1L || store == null || account == null ||
            !CloudJsonRules.validStore(store) || !CloudJsonRules.validRevision(account)) throw CloudJsonError.INVALID_DATA.reject()
        if (environment()?.account != account) throw CloudJsonError.ACCOUNT_CHANGED.reject()
        return Grant(store, account)
    }

    /** Directories called [name] in each of [parents]. A provider may hold two entries with one name; they are read as one directory. */
    private fun directories(folder: SyncFolder, parents: List<SyncNode>, name: String, maximum: Int): List<SyncNode> =
        parents.flatMap { parent -> list(folder, parent, maximum).filter { it.name == name && it.kind == SyncNode.Kind.DIRECTORY } }

    private fun list(folder: SyncFolder, directory: SyncNode, maximum: Int): List<SyncNode> =
        try { folder.children(directory, maximum) } catch (error: SyncFolderException) { throw (if (error.tooMany) CloudJsonError.LIMIT_EXCEEDED else CloudJsonError.UNAVAILABLE).reject() }

    private fun storeDirectories(folder: SyncFolder, store: String): List<SyncNode> =
        directories(folder, directories(folder, listOf(folder.root), CloudJsonRules.STORES_DIRECTORY, 4096), store, CloudJsonRules.MAXIMUM_STORES + 1)

    /**
     * Every revision under [stores], validated. Fails closed, and the failure decides the code:
     * - more than 128 documents, 256 revisions or 2 MiB: `limitExceeded`;
     * - an entry that is not a document directory with a valid name, a link, a revision that fails
     *   [CloudJsonRules.decode], two files with one id and different bytes: `invalidData`;
     * - a file that is not `<id>.json`, is larger than 128 KiB or cannot be read: `unavailable`.
     *
     * `.DS_Store` files and unfinished `.revision-<UUID>` files are skipped without being read.
     */
    private fun inventory(folder: SyncFolder, stores: List<SyncNode>): Map<String, CloudRevision> {
        val result = LinkedHashMap<String, CloudRevision>()
        val names = HashSet<String>()
        var total = 0
        for (store in stores) for (document in list(folder, store, CloudJsonRules.MAXIMUM_DOCUMENTS + 1)) {
            if (document.name == ".DS_Store" && document.kind == SyncNode.Kind.FILE) continue
            if (!CloudJsonRules.validName(document.name) || document.kind != SyncNode.Kind.DIRECTORY) throw CloudJsonError.INVALID_DATA.reject()
            names += document.name
            if (names.size > CloudJsonRules.MAXIMUM_DOCUMENTS) throw CloudJsonError.LIMIT_EXCEEDED.reject()
            for (file in list(folder, document, CloudJsonRules.MAXIMUM_REVISIONS + 2)) {
                if (file.kind == SyncNode.Kind.FILE && (file.name == ".DS_Store" || CloudJsonRules.isTemporary(file.name))) continue
                if (file.kind != SyncNode.Kind.FILE) throw CloudJsonError.INVALID_DATA.reject()
                if (!file.name.endsWith(".json") || file.size > CloudJsonRules.MAXIMUM_FILE_BYTES) throw CloudJsonError.UNAVAILABLE.reject()
                val bytes = try { folder.read(file, CloudJsonRules.MAXIMUM_FILE_BYTES) } catch (error: SyncFolderException) { throw CloudJsonError.UNAVAILABLE.reject() }
                val id = file.name.dropLast(5)
                val known = result[id]
                if (known != null) { if (!known.bytes.contentEquals(bytes) || known.name != document.name) throw CloudJsonError.INVALID_DATA.reject(); continue }
                if (result.size >= CloudJsonRules.MAXIMUM_REVISIONS) throw CloudJsonError.LIMIT_EXCEEDED.reject()
                total += bytes.size
                if (total > CloudJsonRules.MAXIMUM_BYTES) throw CloudJsonError.LIMIT_EXCEEDED.reject()
                result[id] = CloudJsonRules.decode(bytes, id, document.name)
            }
        }
        return result
    }

    private fun cached(grant: Grant): Map<String, CloudRevision> = cache(grant).let { if (it.isAvailable) inventory(it, listOf(it.root)) else emptyMap() }

    /** Adds [revision] to [store] unless a file with its id is there. An existing file with other bytes is `invalidData`; nothing is overwritten. */
    private fun publish(folder: SyncFolder, store: SyncNode, revision: CloudRevision) {
        try {
            val document = list(folder, store, CloudJsonRules.MAXIMUM_DOCUMENTS + 1).firstOrNull { it.name == revision.name && it.kind == SyncNode.Kind.DIRECTORY }
                ?: folder.createDirectory(store, revision.name)
            val existing = list(folder, document, CloudJsonRules.MAXIMUM_REVISIONS + 2).firstOrNull { it.name == revision.id + ".json" }
            if (existing != null) {
                if (existing.kind != SyncNode.Kind.FILE || !folder.read(existing, CloudJsonRules.MAXIMUM_FILE_BYTES).contentEquals(revision.bytes)) throw CloudJsonError.INVALID_DATA.reject()
                return
            }
            folder.createFile(document, revision.id + ".json", revision.bytes)
        } catch (error: SyncFolderException) { throw CloudJsonError.UNAVAILABLE.reject() }
    }

    // MARK: App UI only

    /**
     * Connects [installation] to a store of the current folder and returns its id. Without
     * [existingStore] a new store is created; with it the store must already exist in the folder
     * (`unavailable` otherwise). `unavailable` without a folder. The previous store and its cache
     * are kept. This reads and writes the folder: call it off the main thread.
     */
    fun connect(installation: String, existingStore: String? = null): String {
        if (!CallContext.isOwner(installation)) throw CloudJsonError.NOT_CONNECTED.reject()
        val current = environment() ?: throw CloudJsonError.UNAVAILABLE.reject()
        if (!CloudJsonRules.validRevision(current.account) || !current.folder.isAvailable) throw CloudJsonError.UNAVAILABLE.reject()
        val id = existingStore ?: UUID.randomUUID().toString()
        if (!CloudJsonRules.validStore(id)) throw CloudJsonError.INVALID_NAME.reject()
        val folder = current.folder
        try {
            if (existingStore != null) {
                if (storeDirectories(folder, id).isEmpty()) throw CloudJsonError.UNAVAILABLE.reject()
            } else {
                val stores = directories(folder, listOf(folder.root), CloudJsonRules.STORES_DIRECTORY, 4096).firstOrNull() ?: folder.createDirectory(folder.root, CloudJsonRules.STORES_DIRECTORY)
                folder.createDirectory(stores, id)
            }
        } catch (error: SyncFolderException) { throw CloudJsonError.UNAVAILABLE.reject() }
        synchronized(lock) {
            if (environment()?.account != current.account) throw CloudJsonError.ACCOUNT_CHANGED.reject()
            val file = grantFile(installation)
            if (!file.write(CloudJsonRules.canonical(linkedMapOf("version" to 1L, "store" to id, "account" to current.account)))) throw CloudJsonError.UNAVAILABLE.reject()
        }
        return id
    }

    /** Revokes the grant of [installation]. Revision files and the cache are kept. */
    fun disconnect(installation: String) {
        if (CallContext.isOwner(installation)) synchronized(lock) { grantFile(installation).delete() }
    }

    /** The store [installation] is connected to; rejects like any read when it is not usable. */
    fun connection(installation: String): String = synchronized(lock) { grant(installation).store }

    /** The store ids found in the current folder, at most 128, sorted. Reads the folder: call it off the main thread. */
    fun availableStores(): List<String> {
        val folder = environment()?.folder ?: throw CloudJsonError.UNAVAILABLE.reject()
        val parents = directories(folder, listOf(folder.root), CloudJsonRules.STORES_DIRECTORY, 4096)
        return parents.flatMap { list(folder, it, CloudJsonRules.MAXIMUM_STORES + 1) }
            .filter { it.kind == SyncNode.Kind.DIRECTORY && CloudJsonRules.validStore(it.name) }.map { it.name }.distinct().sorted()
            .also { if (it.size > CloudJsonRules.MAXIMUM_STORES) throw CloudJsonError.LIMIT_EXCEEDED.reject() }
    }

    /** The cached documents of the store [installation] is connected to, for the app's status list. */
    fun documents(installation: String): List<CloudDocumentState> = synchronized(lock) {
        val revisions = cached(grant(installation)).values
        revisions.map { it.name }.distinct().sorted().map { name -> CloudDocumentState(name, revisions.count { it.name == name }, runCatching { CloudJsonGraph.heads(revisions, name).size }.getOrDefault(0)) }
    }

    // MARK: Script operations

    /** `{state, store, uploaded:null, uploadState:"unknown", conflictPolicy:"preserveAllVersions"}`; `state` is `connected` or `unavailable`. */
    fun status(installation: String): String = synchronized(lock) {
        val grant = grant(installation)
        CloudJsonRules.canonical(linkedMapOf("state" to if (environment()?.folder?.isAvailable == true) "connected" else "unavailable", "store" to grant.store,
            "uploaded" to null, "uploadState" to "unknown", "conflictPolicy" to "preserveAllVersions"))
    }

    /** The cached state of [name]. No cached revision is `value:null, revision:""`, which does not prove the folder has none. */
    fun read(installation: String, name: Any?): String {
        if (name !is String || !CloudJsonRules.validName(name)) throw CloudJsonError.INVALID_NAME.reject()
        return synchronized(lock) { CloudJsonGraph.response(cached(grant(installation)).values, name, pending = false) }
    }

    /**
     * Adds a revision of [name] to the cache. The order of checks:
     * 1. `invalidName`; 2. the grant; 3. `staleRevision` unless [expected] is the token of the
     * current heads; 4. `conflict` when there are several heads and this is not a resolution;
     * 5. `invalidData` unless [value] is a JSON object nested at most 32 levels;
     * 6. `limitExceeded` above 64 KiB, 256 revisions, 128 documents or 2 MiB.
     *
     * The new revision names every current head as a parent, so [resolving] supersedes all observed
     * conflicting heads while their files stay. Nothing is pruned to make room.
     */
    fun write(installation: String, name: Any?, value: Any?, expected: Any?, resolving: Boolean): String {
        if (name !is String || !CloudJsonRules.validName(name)) throw CloudJsonError.INVALID_NAME.reject()
        return synchronized(lock) {
            val grant = grant(installation)
            val items = cached(grant)
            val current = CloudJsonGraph.heads(items.values, name)
            if (expected !is String || CloudJsonGraph.token(current) != expected) throw CloudJsonError.STALE_REVISION.reject()
            if (!resolving && current.size > 1) throw CloudJsonError.CONFLICT.reject()
            if (value !is JSONObject && value !is Map<*, *>) throw CloudJsonError.INVALID_DATA.reject()
            @Suppress("UNCHECKED_CAST")
            val plain = CloudJsonRules.plain(value) as Map<String, Any?>
            if (CloudJsonRules.canonical(plain).toByteArray().size > CloudJsonRules.MAXIMUM_VALUE_BYTES || items.size >= CloudJsonRules.MAXIMUM_REVISIONS ||
                (items.values.none { it.name == name } && items.values.map { it.name }.toSet().size >= CloudJsonRules.MAXIMUM_DOCUMENTS) ||
                items.values.sumOf { it.bytes.size } + CloudJsonRules.MAXIMUM_FILE_BYTES > CloudJsonRules.MAXIMUM_BYTES) throw CloudJsonError.LIMIT_EXCEEDED.reject()
            val bytes = CloudJsonRules.encodeRevision(name, current.map { it.id }, plain)
            val id = CloudJsonRules.hash(bytes)
            val revision = items[id] ?: CloudJsonRules.decode(bytes, id, name)
            val cache = cache(grant)
            if (!cache.isAvailable && !(cache.root.handle as File).mkdirs() && !cache.isAvailable) throw CloudJsonError.UNAVAILABLE.reject()
            publish(cache, cache.root, revision)
            CloudJsonGraph.response(items.values + revision, name, pending = true)
        }
    }

    /**
     * Exchanges revision files between the cache and the folder and returns
     * `{state:"pending", materializedRevisions, downloadedRevisions, uploaded:null}`.
     *
     * - The store must still exist in the folder (`unavailable`); a removed store is never recreated.
     * - The whole folder inventory is validated before anything is copied, and incoming revisions
     *   reach the cache before any outgoing file is written.
     * - The union must fit the limits (`limitExceeded`); nothing is dropped to make it fit.
     * - `uploaded` is always null: a documents provider does not say whether a file has left the device.
     *
     * The folder is read and written outside the lock reads use, so a slow provider delays only this call.
     */
    fun synchronize(installation: String): String = synchronized(exchangeLock) {
        val grant = synchronized(lock) { grant(installation) }
        val current = environment()
        if (current == null || current.account != grant.account) throw CloudJsonError.ACCOUNT_CHANGED.reject()
        val folder = current.folder
        if (!folder.isAvailable) throw CloudJsonError.UNAVAILABLE.reject()
        val stores = storeDirectories(folder, grant.store)
        if (stores.isEmpty()) throw CloudJsonError.UNAVAILABLE.reject()
        val incoming = inventory(folder, stores)
        val (merged, downloaded) = synchronized(lock) {
            val again = try { grant(installation) } catch (error: SystemReject) { throw CloudJsonError.IDENTITY_CHANGED.reject() }
            if (again.store != grant.store || again.account != grant.account) throw CloudJsonError.IDENTITY_CHANGED.reject()
            val local = cached(grant)
            val union = (local + incoming.filterKeys { it !in local }).toSortedMap()
            if (union.size > CloudJsonRules.MAXIMUM_REVISIONS || union.values.map { it.name }.toSet().size > CloudJsonRules.MAXIMUM_DOCUMENTS ||
                union.values.sumOf { it.bytes.size } > CloudJsonRules.MAXIMUM_BYTES) throw CloudJsonError.LIMIT_EXCEEDED.reject()
            if (incoming.any { (id, revision) -> local[id]?.let { !it.bytes.contentEquals(revision.bytes) } == true }) throw CloudJsonError.INVALID_DATA.reject()
            val cache = cache(grant)
            if (!cache.isAvailable && !(cache.root.handle as File).mkdirs() && !cache.isAvailable) throw CloudJsonError.UNAVAILABLE.reject()
            val fresh = incoming.values.filter { it.id !in local }
            for (revision in fresh) publish(cache, cache.root, revision)
            union to fresh.size
        }
        for (revision in merged.values) {
            if (revision.id in incoming) continue
            if (environment()?.account != grant.account) throw CloudJsonError.ACCOUNT_CHANGED.reject()
            publish(folder, stores[0], revision)
        }
        CloudJsonRules.canonical(linkedMapOf("state" to "pending", "materializedRevisions" to merged.size.toLong(), "downloadedRevisions" to downloaded.toLong(), "uploaded" to null))
    }
}
