package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.pkg.SafeFiles
import org.json.JSONException
import org.json.JSONObject
import org.json.JSONTokener
import java.io.IOException
import java.nio.file.Files
import java.nio.file.Path
import java.nio.file.StandardCopyOption
import java.util.UUID

/** What a Gallery item installs. [wire] is the value of `kind` in the index. */
enum class GalleryItemKind(val wire: String, val displayName: String) {
    WIDGET("widget", "Widgets"),
    SKILL("skill", "Skills");

    companion object {
        /** The kind for an index value, or null for anything else (unknown kinds fail closed). */
        fun fromWire(value: String?): GalleryItemKind? = entries.firstOrNull { it.wire == value }
    }
}

/**
 * One downloadable file of a Gallery item. The index, not the server, is the authority for
 * [path], [bytes] and [sha256]: a download is accepted only when all three match exactly.
 */
data class GalleryFile(val path: String, val url: String, val sha256: String, val bytes: Long)

/** One catalog entry of Gallery 1.0 (`GalleryItem` in Swift). */
data class GalleryItem(
    val id: String,
    val kind: GalleryItemKind,
    val name: String,
    val version: String,
    val summary: String,
    val symbol: String,
    val author: String,
    val license: String,
    val tags: List<String>,
    /** Runtime contract version (`1.0`), not the package's minimum API version. */
    val minimumRuntimeVersion: String,
    val sourceUrl: String,
    val featured: Boolean,
    val files: List<GalleryFile>,
) {
    /**
     * Identity of the item's content: every path with its hash, sorted by path. A changed
     * fingerprint at an unchanged version is still offered as an update, so a corrected artifact
     * is never hidden.
     */
    val contentFingerprint: String
        get() = files.sortedBy { it.path }.joinToString("|") { "${it.path}:${it.sha256}" }

    /** Declared download size. Only meaningful for an item that passed validation. */
    val totalBytes: Long get() = files.sumOf { maxOf(0L, it.bytes) }
}

/** A decoded Gallery 1.0 index. [generatedAt] is milliseconds since the epoch. */
data class GalleryIndex(val schemaVersion: Int, val generatedAt: Long, val repository: String, val items: List<GalleryItem>) {
    companion object {
        /** `GalleryIndex.currentSchemaVersion`; any other schema is refused. */
        const val CURRENT_SCHEMA_VERSION = 1

        /** `ScriptWidgetBuildContract.runtimeAPIVersion`: the only runtime contract Gallery 1.0 items may declare. */
        const val RUNTIME_CONTRACT_VERSION = "1.0"
    }
}

/** One reason an index or item was refused. [id] is stable (`<item>.<rule>`), [message] is for people. */
data class GalleryValidationIssue(val id: String, val message: String)

/**
 * The single failure type of the Gallery layer (`GalleryError` in Swift). Every failure is a
 * refusal: nothing unverified is cached, shown as verified, or installed.
 */
class GalleryException(val kind: Kind, message: String, cause: Throwable? = null) : Exception(message, cause) {
    enum class Kind {
        /** The index is oversized, malformed, has unknown fields, or breaks a validation rule. */
        INVALID_INDEX,
        /** The request failed, was redirected off the trusted host, or returned an error status. */
        NETWORK,
        /** The network is unavailable and no previously validated index is cached. */
        MISSING_CACHE,
        /** A downloaded file did not match its declared status, host, byte count or SHA-256. */
        INVALID_DOWNLOAD,
        /** The verified files were refused by the widget or Skill installer. */
        INSTALL,
    }
}

/** JSON and file helpers shared by the Gallery and Skills layers. */
internal object GalleryFiles {
    /**
     * Parses [text] as exactly one JSON object. Anything else, including trailing content after
     * the object, yields null so a manifest cannot smuggle a second document.
     */
    fun parseObject(text: String): JSONObject? = try {
        val tokener = JSONTokener(text)
        val value = tokener.nextValue()
        if (value is JSONObject && tokener.nextClean() == 0.toChar()) value else null
    } catch (_: JSONException) {
        null
    }

    /** Replaces [target] with [bytes] through a flushed temporary file and one atomic rename. */
    @Throws(IOException::class)
    fun writeAtomically(target: Path, bytes: ByteArray) {
        Files.createDirectories(target.parent)
        val temporary = target.resolveSibling(".${target.fileName}.${UUID.randomUUID()}.tmp")
        try {
            SafeFiles.writeNew(temporary, bytes)
            Files.move(temporary, target, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } finally {
            Files.deleteIfExists(temporary)
        }
    }
}
