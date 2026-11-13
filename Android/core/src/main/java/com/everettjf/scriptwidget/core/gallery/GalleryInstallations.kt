package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.pkg.SafeFiles
import org.json.JSONObject
import java.io.File
import java.io.IOException

/**
 * What was installed for one Gallery item (`GalleryInstalledRecord` in Swift). [localIdentifier]
 * is the package name for a widget and the Skill id for a Skill.
 */
data class GalleryInstalledRecord(
    val itemId: String,
    val kind: GalleryItemKind,
    val version: String,
    val localIdentifier: String,
    val contentFingerprint: String,
    val installedAt: Long,
)

/** Install state of an item as shown in the Gallery. */
sealed interface GalleryInstallState {
    data object NotInstalled : GalleryInstallState
    data object Installed : GalleryInstallState
    /** The catalog holds a newer version, or different content at the same version. */
    data class UpdateAvailable(val current: String) : GalleryInstallState
}

/**
 * Persistent map from Gallery item id to its [GalleryInstalledRecord]
 * (`GalleryInstallationRegistry` in Swift). The registry is bookkeeping, not authority: an
 * unreadable or malformed file reads as "nothing installed", and the installer confirms every
 * record against the package or Skill that is really on disk.
 */
class GalleryInstallationRegistry(private val file: File) {
    private val lock = Any()

    /** All readable records. Malformed entries are dropped. */
    fun records(): Map<String, GalleryInstalledRecord> = synchronized(lock) {
        val root = SafeFiles.readBounded(file.toPath(), MAX_REGISTRY_BYTES)?.let(SafeFiles::decodeUtf8)?.let(GalleryFiles::parseObject)
            ?: return emptyMap()
        val result = LinkedHashMap<String, GalleryInstalledRecord>()
        for (key in root.keys()) {
            val record = (root.opt(key) as? JSONObject)?.let(::decode)
            if (record != null && record.itemId == key) result[key] = record
        }
        result
    }

    fun record(itemId: String): GalleryInstalledRecord? = records()[itemId]

    /**
     * Compares the record with the catalog entry: same version and fingerprint is installed; a
     * locally newer version is installed (never offered as a downgrade); anything else,
     * including changed content at the same version, is an update.
     */
    fun state(item: GalleryItem): GalleryInstallState {
        val value = record(item.id) ?: return GalleryInstallState.NotInstalled
        if (value.version == item.version && value.contentFingerprint == item.contentFingerprint) return GalleryInstallState.Installed
        if (GallerySemanticVersion.compare(value.version, item.version) > 0) return GalleryInstallState.Installed
        return GalleryInstallState.UpdateAvailable(value.version)
    }

    /** Adds or replaces one record; the file is replaced atomically. */
    @Throws(IOException::class)
    fun save(record: GalleryInstalledRecord) = synchronized(lock) { write(records() + (record.itemId to record)) }

    /** Forgets one record; the installed package or Skill is not touched. */
    @Throws(IOException::class)
    fun remove(itemId: String) = synchronized(lock) { write(records() - itemId) }

    private fun write(values: Map<String, GalleryInstalledRecord>) = synchronized(lock) {
        val root = JSONObject()
        for ((key, value) in values.toSortedMap()) {
            root.put(
                key,
                JSONObject()
                    .put("itemID", value.itemId).put("kind", value.kind.wire).put("version", value.version)
                    .put("localIdentifier", value.localIdentifier).put("contentFingerprint", value.contentFingerprint)
                    .put("installedAt", value.installedAt),
            )
        }
        GalleryFiles.writeAtomically(file.absoluteFile.toPath(), (root.toString(2) + "\n").toByteArray(Charsets.UTF_8))
    }

    private fun decode(json: JSONObject): GalleryInstalledRecord? {
        return GalleryInstalledRecord(
            itemId = json.opt("itemID") as? String ?: return null,
            kind = GalleryItemKind.fromWire(json.opt("kind") as? String) ?: return null,
            version = json.opt("version") as? String ?: return null,
            localIdentifier = json.opt("localIdentifier") as? String ?: return null,
            contentFingerprint = json.opt("contentFingerprint") as? String ?: return null,
            installedAt = (json.opt("installedAt") as? Number)?.toLong() ?: return null,
        )
    }

    private companion object {
        const val MAX_REGISTRY_BYTES = 4L * 1024 * 1024
    }
}

/** Version ordering used for update detection (`GallerySemanticVersion` in Swift). */
object GallerySemanticVersion {
    /**
     * Negative, zero or positive as [lhs] is older than, equal to or newer than [rhs].
     *
     * The numeric components before any `-` suffix are compared first; missing components count
     * as 0 and non-numeric ones as 0. Versions with equal numbers but different text (a
     * pre-release suffix) are ordered by a case-insensitive, digit-aware text comparison, which
     * stands in for Swift's `localizedStandardCompare` and, like it, is not SemVer precedence.
     */
    fun compare(lhs: String, rhs: String): Int {
        val left = components(lhs)
        val right = components(rhs)
        for (index in 0 until maxOf(left.size, right.size)) {
            val a = left.getOrElse(index) { 0L }
            val b = right.getOrElse(index) { 0L }
            if (a != b) return if (a < b) -1 else 1
        }
        return if (lhs == rhs) 0 else natural(lhs, rhs)
    }

    private fun components(value: String): List<Long> =
        value.substringBefore('-').split('.').filter { it.isNotEmpty() }.map { it.toLongOrNull() ?: 0L }

    private val chunk = Regex("[0-9]+|[^0-9]+")

    private fun natural(lhs: String, rhs: String): Int {
        val left = chunk.findAll(lhs).map { it.value }.toList()
        val right = chunk.findAll(rhs).map { it.value }.toList()
        for (index in 0 until minOf(left.size, right.size)) {
            val a = left[index]
            val b = right[index]
            val numeric = a[0].isDigit() && b[0].isDigit()
            val order = if (numeric) {
                val x = a.trimStart('0')
                val y = b.trimStart('0')
                if (x.length != y.length) x.length.compareTo(y.length) else x.compareTo(y)
            } else {
                a.compareTo(b, ignoreCase = true)
            }
            if (order != 0) return order
        }
        return if (left.size != right.size) left.size.compareTo(right.size) else lhs.compareTo(rhs)
    }
}
