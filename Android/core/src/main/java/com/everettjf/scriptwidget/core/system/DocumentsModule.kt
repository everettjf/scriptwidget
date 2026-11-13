package com.everettjf.scriptwidget.core.system

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.system.Os
import android.system.OsConstants
import com.everettjf.scriptwidget.core.plugin.StrictJson
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.UUID

/** Limits and parsers of `$documents`. Imported content is data: it is parsed here and never executed. */
object DocumentRules {
    /** Files per installation. */
    const val MAXIMUM_FILES = 8
    /** Bytes per file. */
    const val MAXIMUM_BYTES = 262_144
    const val MAXIMUM_NAME_BYTES = 255
    const val MAXIMUM_DATA_ROWS = 500
    const val MAXIMUM_COLUMNS = 32
    const val MAXIMUM_CELL_BYTES = 8192
    val TYPES = setOf("json", "csv")
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

    /** Document identifiers are canonical lowercase UUIDs made by the app, never paths or URIs. */
    fun validID(value: String): Boolean = uuid.matches(value)

    /** Strict UTF-8: malformed input is null, never replaced. */
    fun decodeUtf8(bytes: ByteArray): String? = try {
        Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
    } catch (error: CharacterCodingException) { null }

    /**
     * Bounded RFC 4180 style CSV, the Apple runtime's parser.
     *
     * - At most 256 KiB of valid UTF-8, an optional byte-order mark (`invalid_options` otherwise).
     * - Fields are separated by commas; rows end with CR LF, LF or CR. A field may be quoted; inside
     *   quotes a doubled quote is one quote and delimiters and newlines are data.
     * - A quote inside an unquoted field, text after a closing quote and an unclosed quote are `invalid_options`.
     * - More than 32 fields in a row, a cell above 8 KiB or more than 500 data rows are
     *   `limit_exceeded`: nothing is silently truncated, so `truncated` is always false.
     * - The first row is the header: nonempty, unique names. Every data row has exactly as many
     *   fields (`invalid_options` otherwise).
     */
    fun csv(bytes: ByteArray): JSONObject {
        val invalid = { SystemServiceError.INVALID_OPTIONS.reject() }
        val limit = { SystemServiceError.LIMIT_EXCEEDED.reject() }
        if (bytes.size > MAXIMUM_BYTES) throw invalid()
        var text = decodeUtf8(bytes) ?: throw invalid()
        if (text.startsWith("﻿")) text = text.substring(1)
        val rows = ArrayList<List<String>>()
        var row = ArrayList<String>()
        val field = StringBuilder()
        var fieldBytes = 0
        var quoted = false
        var closed = false
        fun append(character: Char) {
            field.append(character)
            // UTF-16 units to UTF-8 bytes: a surrogate pair is four bytes, two per unit.
            fieldBytes += when { character.code < 0x80 -> 1; character.code < 0x800 -> 2; Character.isSurrogate(character) -> 2; else -> 3 }
            if (fieldBytes > MAXIMUM_CELL_BYTES) throw limit()
        }
        fun finishField() {
            if (row.size >= MAXIMUM_COLUMNS) throw limit()
            row.add(field.toString()); field.setLength(0); fieldBytes = 0; closed = false
        }
        fun finishRow() {
            finishField()
            if (rows.size >= MAXIMUM_DATA_ROWS + 1) throw limit()
            rows.add(row); row = ArrayList()
        }
        var cursor = 0
        while (cursor < text.length) {
            val character = text[cursor]
            cursor += 1
            if (quoted) {
                if (character == '"') {
                    if (cursor < text.length && text[cursor] == '"') { append('"'); cursor += 1 } else { quoted = false; closed = true }
                } else append(character)
            } else if (character == '"') {
                if (field.isNotEmpty() || closed) throw invalid()
                quoted = true
            } else if (character == ',') finishField()
            else if (character == '\n' || character == '\r') {
                if (character == '\r' && cursor < text.length && text[cursor] == '\n') cursor += 1
                finishRow()
            } else {
                if (closed) throw invalid()
                append(character)
            }
        }
        if (quoted) throw invalid()
        if (field.isNotEmpty() || row.isNotEmpty() || closed) finishRow()
        val headers = rows.firstOrNull() ?: throw invalid()
        if (headers.isEmpty() || headers.any { it.isEmpty() } || headers.toSet().size != headers.size || rows.drop(1).any { it.size != headers.size }) throw invalid()
        return JSONObject().put("headers", JSONArray(headers)).put("rows", JSONArray(rows.drop(1).map { JSONArray(it) })).put("truncated", false)
    }

    /**
     * Strict JSON whose root is an object or an array, returned as JSON text for the script.
     * Above 256 KiB is `limit_exceeded`; another root is `invalid_options`; text that is not
     * well-formed UTF-8 JSON is the generic system failure, as on the Apple runtime.
     */
    fun json(bytes: ByteArray): String {
        if (bytes.size > MAXIMUM_BYTES) throw SystemServiceError.LIMIT_EXCEEDED.reject()
        val value = try {
            val text = decodeUtf8(bytes) ?: throw SystemReject(SystemServiceError.FAILED)
            StrictJson.parse(text.removePrefix("﻿"), allowDuplicateKeys = true)
        } catch (error: StrictJson.JsonException) { throw SystemReject(SystemServiceError.FAILED) }
        if (value !is Map<*, *> && value !is List<*>) throw SystemServiceError.INVALID_OPTIONS.reject()
        return StringBuilder().also { encode(value, it) }.toString()
    }

    private fun encode(value: Any?, out: StringBuilder) {
        when (value) {
            null -> out.append("null")
            is Map<*, *> -> {
                out.append('{')
                var first = true
                for ((key, member) in value) { if (!first) out.append(','); first = false; out.append(JSONObject.quote(key.toString())).append(':'); encode(member, out) }
                out.append('}')
            }
            is List<*> -> {
                out.append('[')
                value.forEachIndexed { index, member -> if (index > 0) out.append(','); encode(member, out) }
                out.append(']')
            }
            is String -> out.append(JSONObject.quote(value))
            is Double -> if (value.isFinite()) out.append(value.toString()) else throw SystemReject(SystemServiceError.FAILED)
            else -> out.append(value.toString())
        }
    }

    /** `json` or `csv` from a file name or MIME type, or null for anything else. */
    fun type(name: String, mimeType: String?): String? = when {
        name.endsWith(".json", ignoreCase = true) -> "json"
        name.endsWith(".csv", ignoreCase = true) -> "csv"
        mimeType == "application/json" -> "json"
        mimeType == "text/csv" || mimeType == "text/comma-separated-values" -> "csv"
        else -> null
    }

    /** A display name without path separators or control characters, at most 255 UTF-8 bytes; `Untitled` when nothing is left. */
    fun name(raw: String?): String {
        var name = raw.orEmpty().substringAfterLast('/').substringAfterLast('\\').filterNot { Character.isISOControl(it) || Character.getType(it) == Character.FORMAT.toInt() }.trim()
        while (name.toByteArray().size > MAXIMUM_NAME_BYTES) name = name.dropLast(1)
        if (name.isNotEmpty() && Character.isHighSurrogate(name.last())) name = name.dropLast(1)
        return name.ifEmpty { "Untitled" }
    }
}

/** One imported document: the script sees [id], [name], [type] and [bytes]; [source] stays in the app. */
class DocumentEntry(val id: String, val name: String, val type: String, val bytes: Int, val source: String?)

/**
 * Private, bounded copies of the documents the user imported for each installation. The index and
 * the copies live in a directory named by a digest of the installation, so an identity is never a
 * path. A malformed index is `unavailable`, never an empty list.
 */
class DocumentStore(private val directory: File) {
    private fun home(installation: String) = File(directory, ownerFileName(installation, ""))
    private fun index(installation: String) = PrivateFile(File(home(installation), "index.json"), 32 * 1024)
    private fun copy(installation: String, id: String) = PrivateFile(File(home(installation), id), DocumentRules.MAXIMUM_BYTES)

    /** The installation's documents in import order. */
    fun list(installation: String): List<DocumentEntry> {
        if (!CallContext.isOwner(installation)) return emptyList()
        val file = index(installation)
        return synchronized(file.lock) { load(file) }
    }

    /**
     * Stores a copy of [content] for [installation] and returns its entry, or null when the
     * installation is unknown, the type is not `json`/`csv`, the content is above 256 KiB or the
     * installation already has eight documents.
     */
    fun add(installation: String, name: String, type: String, content: ByteArray, source: String?): DocumentEntry? {
        if (!CallContext.isOwner(installation) || type !in DocumentRules.TYPES || content.size > DocumentRules.MAXIMUM_BYTES) return null
        val file = index(installation)
        return synchronized(file.lock) {
            val entries = runCatching { load(file) }.getOrNull() ?: return@synchronized null
            if (entries.size >= DocumentRules.MAXIMUM_FILES) return@synchronized null
            val entry = DocumentEntry(UUID.randomUUID().toString(), DocumentRules.name(name), type, content.size, source?.takeIf { it.toByteArray().size <= 2048 })
            if (!copy(installation, entry.id).writeBytes(content) || !save(file, entries + entry)) { copy(installation, entry.id).delete(); return@synchronized null }
            entry
        }
    }

    /** Replaces the copy of an existing document with newer [content] from the same source. */
    fun replace(installation: String, id: String, content: ByteArray): Boolean {
        if (!CallContext.isOwner(installation) || content.size > DocumentRules.MAXIMUM_BYTES) return false
        val file = index(installation)
        return synchronized(file.lock) {
            val entries = runCatching { load(file) }.getOrNull() ?: return@synchronized false
            val entry = entries.firstOrNull { it.id == id } ?: return@synchronized false
            copy(installation, id).writeBytes(content) && save(file, entries.map { if (it.id == id) DocumentEntry(id, entry.name, entry.type, content.size, entry.source) else it })
        }
    }

    /**
     * The bytes of one document. `permission_denied` unless [id] names a document of this
     * installation with this [type] whose copy still has the recorded size.
     */
    fun read(installation: String, id: String, type: String): ByteArray {
        val denied = { SystemServiceError.PERMISSION_DENIED.reject() }
        if (!CallContext.isOwner(installation) || !DocumentRules.validID(id)) throw denied()
        val file = index(installation)
        return synchronized(file.lock) {
            val entry = load(file).firstOrNull { it.id == id && it.type == type } ?: throw denied()
            val bytes = runCatching { copy(installation, entry.id).readBytes() }.getOrNull()
            if (bytes == null || bytes.size != entry.bytes) throw denied()
            bytes
        }
    }

    /** Removes one document and returns its entry, or null when it did not exist. */
    fun remove(installation: String, id: String): DocumentEntry? {
        if (!CallContext.isOwner(installation)) return null
        val file = index(installation)
        return synchronized(file.lock) {
            val entries = runCatching { load(file) }.getOrNull() ?: return@synchronized null
            val entry = entries.firstOrNull { it.id == id } ?: return@synchronized null
            if (!save(file, entries - entry)) return@synchronized null
            copy(installation, id).delete()
            entry
        }
    }

    /** Deletes everything stored for [installation], including an unreadable index, and returns the sources that were recorded. */
    fun clear(installation: String): List<String> {
        if (!CallContext.isOwner(installation)) return emptyList()
        val file = index(installation)
        return synchronized(file.lock) {
            val sources = runCatching { load(file) }.getOrDefault(emptyList()).mapNotNull { it.source }
            home(installation).listFiles()?.forEach { it.delete() }
            home(installation).delete()
            sources
        }
    }

    private fun PrivateFile.writeBytes(content: ByteArray): Boolean = runCatching {
        if (content.size > DocumentRules.MAXIMUM_BYTES) return false
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, file.name + ".tmp")
        temporary.writeBytes(content)
        java.nio.file.Files.move(temporary.toPath(), file.toPath(), java.nio.file.StandardCopyOption.REPLACE_EXISTING, java.nio.file.StandardCopyOption.ATOMIC_MOVE)
        true
    }.getOrDefault(false)

    private fun PrivateFile.readBytes(): ByteArray? {
        val path = file.toPath()
        if (!java.nio.file.Files.isRegularFile(path, java.nio.file.LinkOption.NOFOLLOW_LINKS) || file.length() > DocumentRules.MAXIMUM_BYTES) return null
        return file.readBytes().takeIf { it.size <= DocumentRules.MAXIMUM_BYTES }
    }

    private fun load(file: PrivateFile): List<DocumentEntry> {
        val unavailable = { SystemServiceError.UNAVAILABLE.reject() }
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw unavailable() } ?: return emptyList()
        return try {
            val root = JSONObject(text)
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "documents") || root.get("formatVersion") != 1) throw unavailable()
            val array = root.getJSONArray("documents")
            if (array.length() > DocumentRules.MAXIMUM_FILES) throw unavailable()
            val entries = List(array.length()) { index ->
                val item = array.getJSONObject(index)
                val entry = DocumentEntry(item.getString("id"), item.getString("name"), item.getString("type"), item.getInt("bytes"), if (item.isNull("source")) null else item.getString("source"))
                if (!DocumentRules.validID(entry.id) || entry.name.isEmpty() || entry.name.toByteArray().size > DocumentRules.MAXIMUM_NAME_BYTES ||
                    entry.type !in DocumentRules.TYPES || entry.bytes !in 0..DocumentRules.MAXIMUM_BYTES) throw unavailable()
                entry
            }
            if (entries.map { it.id }.toSet().size != entries.size) throw unavailable()
            entries
        } catch (error: org.json.JSONException) { throw unavailable() }
    }

    private fun save(file: PrivateFile, entries: List<DocumentEntry>): Boolean = file.write(JSONObject().put("formatVersion", 1).put("documents", JSONArray(entries.map {
        JSONObject().put("id", it.id).put("name", it.name).put("type", it.type).put("bytes", it.bytes).put("source", it.source ?: JSONObject.NULL)
    })).toString())
}

/**
 * `$documents`: `list`, `readJSON`, `readCSV` over the files the user imported for this
 * installation in the app. Every call passes the system gate (`documents` declared by an
 * installed Runtime 1.6 package, not a future timeline entry or Live Activity, the query budget).
 * The per-installation import is the native grant: a widget without imported files gets an empty
 * list, and an identifier of another installation is `permission_denied`.
 */
class DocumentsModule(private val store: DocumentStore) : NativeModule {
    override val apis: Set<String> = setOf("\$documents")

    override fun handles(operation: String): Boolean = operation.startsWith("documents.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "documents.list" -> runSystemCall(operation, done) { list(context).toString() }
            "documents.readJSON" -> runSystemCall(operation, done) { readJSON(context, payload?.opt("id")) }
            "documents.readCSV" -> runSystemCall(operation, done) { readCSV(context, payload?.opt("id")).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** `[{id, name, type, bytes}]` for this installation. */
    fun list(context: CallContext): JSONArray {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        return JSONArray(store.list(context.installation).map { JSONObject().put("id", it.id).put("name", it.name).put("type", it.type).put("bytes", it.bytes) })
    }

    /** The JSON text of an imported `json` document; see [DocumentRules.json]. */
    fun readJSON(context: CallContext, id: Any?): String {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        return DocumentRules.json(store.read(context.installation, id as? String ?: throw SystemServiceError.PERMISSION_DENIED.reject(), "json"))
    }

    /** `{headers, rows, truncated}` of an imported `csv` document; see [DocumentRules.csv]. */
    fun readCSV(context: CallContext, id: Any?): JSONObject {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        return DocumentRules.csv(store.read(context.installation, id as? String ?: throw SystemServiceError.PERMISSION_DENIED.reject(), "csv"))
    }

    /** Deletes the imported copies of a deleted installation. */
    fun retire(installation: String): List<String> {
        val sources = store.clear(installation)
        SystemLog.call("documents.retire", "ok")
        return sources
    }

    companion object {
        const val PERMISSION = "documents"
    }
}

/**
 * Copies documents the user picked with the Storage Access Framework into the [DocumentStore].
 * The app keeps a persistable read permission for each source so the user can refresh a copy
 * later; widgets only ever read the copy.
 */
class DocumentImporter(context: Context, private val store: DocumentStore) {
    private val appContext = context.applicationContext

    /** Why a picked file was not imported; shown to the user, never logged with a name. */
    enum class Outcome { IMPORTED, UNSUPPORTED_TYPE, TOO_LARGE, UNREADABLE, INVALID_CONTENT, FULL }

    /** Imports each URI for [installation] and returns one outcome per URI, in order. */
    fun import(installation: String, uris: List<Uri>): List<Outcome> {
        val outcomes = uris.map { uri -> runCatching { importOne(installation, uri) }.getOrDefault(Outcome.UNREADABLE) }
        SystemLog.call("documents.import", "ok imported=${outcomes.count { it == Outcome.IMPORTED }} skipped=${outcomes.count { it != Outcome.IMPORTED }}")
        return outcomes
    }

    /** Reads the recorded source of a document again and replaces the private copy. */
    fun refresh(installation: String, id: String): Outcome {
        val outcome = runCatching {
            val entry = store.list(installation).firstOrNull { it.id == id }
            val source = entry?.source ?: return@runCatching Outcome.UNREADABLE
            val content = read(Uri.parse(source)) ?: return@runCatching Outcome.UNREADABLE
            if (content.size > DocumentRules.MAXIMUM_BYTES) return@runCatching Outcome.TOO_LARGE
            if (!valid(entry.type, content)) return@runCatching Outcome.INVALID_CONTENT
            if (store.replace(installation, id, content)) Outcome.IMPORTED else Outcome.UNREADABLE
        }.getOrDefault(Outcome.UNREADABLE)
        SystemLog.call("documents.refresh", outcome.name.lowercase())
        return outcome
    }

    /** Removes a document and gives up the read permission for its source when no other document uses it. */
    fun remove(installation: String, id: String) {
        val removed = store.remove(installation, id)
        removed?.source?.let { release(listOf(it)) }
        SystemLog.call("documents.remove", if (removed != null) "ok" else "not_found")
    }

    /** Gives up persisted read permissions for [sources] that no remaining document refers to. */
    fun release(sources: List<String>, stillUsed: Set<String> = emptySet()) {
        for (source in sources.distinct()) if (source !in stillUsed) runCatching {
            appContext.contentResolver.releasePersistableUriPermission(Uri.parse(source), Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
    }

    private fun importOne(installation: String, uri: Uri): Outcome {
        val resolver = appContext.contentResolver
        val name = resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor -> if (cursor.moveToFirst()) cursor.getString(0) else null } ?: uri.lastPathSegment.orEmpty()
        val type = DocumentRules.type(name, resolver.getType(uri)) ?: return Outcome.UNSUPPORTED_TYPE
        if (store.list(installation).size >= DocumentRules.MAXIMUM_FILES) return Outcome.FULL
        val content = read(uri) ?: return Outcome.UNREADABLE
        if (content.size > DocumentRules.MAXIMUM_BYTES) return Outcome.TOO_LARGE
        if (!valid(type, content)) return Outcome.INVALID_CONTENT
        val persisted = runCatching { resolver.takePersistableUriPermission(uri, Intent.FLAG_GRANT_READ_URI_PERMISSION) }.isSuccess
        return if (store.add(installation, name, type, content, if (persisted) uri.toString() else null) != null) Outcome.IMPORTED else Outcome.FULL
    }

    /** The document parses under the same rules a widget read applies, so a broken file is refused at import. */
    private fun valid(type: String, content: ByteArray): Boolean = try {
        if (type == "json") DocumentRules.json(content) else DocumentRules.csv(content)
        true
    } catch (error: SystemReject) { false }

    /**
     * A bounded read of the picked document: at most 256 KiB + 1 byte, so an oversized file is
     * detected without loading it. When the provider hands out a regular file, its size and
     * modification time must be unchanged after the read; a source that changed meanwhile is unreadable.
     */
    private fun read(uri: Uri): ByteArray? = appContext.contentResolver.openFileDescriptor(uri, "r")?.use { descriptor ->
        val before = Os.fstat(descriptor.fileDescriptor)
        val regular = OsConstants.S_ISREG(before.st_mode)
        if (OsConstants.S_ISDIR(before.st_mode) || OsConstants.S_ISLNK(before.st_mode)) return null
        if (regular && before.st_size > DocumentRules.MAXIMUM_BYTES) return ByteArray(DocumentRules.MAXIMUM_BYTES + 1)
        // The stream is not closed here: closing it would close the descriptor that is examined again below.
        val content = bounded(FileInputStream(descriptor.fileDescriptor))
        if (regular) {
            val after = Os.fstat(descriptor.fileDescriptor)
            if (after.st_size != before.st_size || after.st_mtim.tv_sec != before.st_mtim.tv_sec || after.st_mtim.tv_nsec != before.st_mtim.tv_nsec ||
                (content.size <= DocumentRules.MAXIMUM_BYTES && content.size.toLong() != before.st_size)) return null
        }
        content
    }

    private fun bounded(input: InputStream): ByteArray {
        val buffer = ByteArrayOutputStream()
        val chunk = ByteArray(8192)
        while (buffer.size() <= DocumentRules.MAXIMUM_BYTES) {
            val count = input.read(chunk, 0, minOf(chunk.size, DocumentRules.MAXIMUM_BYTES + 1 - buffer.size()))
            if (count < 0) break
            buffer.write(chunk, 0, count)
        }
        return buffer.toByteArray()
    }
}
