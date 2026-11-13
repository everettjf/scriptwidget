package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.pkg.PackageLimits
import com.everettjf.scriptwidget.core.pkg.PackageNames
import com.everettjf.scriptwidget.core.pkg.SafeFiles
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.net.URISyntaxException
import java.time.OffsetDateTime
import java.time.format.DateTimeParseException
import java.util.Locale

/**
 * Strict decoder and validator of the Gallery 1.0 index, ported from `GalleryIndexValidator` in
 * Swift and tightened to the bounds of `Gallery/gallery.schema.json`.
 *
 * The index is untrusted input. It is refused as a whole when any rule fails; there is no
 * partial acceptance and no best-effort repair.
 */
object GalleryIndexValidator {
    /** `maximumIndexBytes`: a larger index is refused before it is parsed. */
    const val MAX_INDEX_BYTES = 1024 * 1024
    /** `maximumItems`. */
    const val MAX_ITEMS = 500
    /** `maximumWidgetBytes`: declared total of one widget item. */
    const val MAX_WIDGET_BYTES = 32L * 1024 * 1024
    /** `maximumSkillBytes`: declared total of one Skill item. */
    const val MAX_SKILL_BYTES = 256L * 1024
    /** `maximumFiles`: files of one item. */
    const val MAX_FILES = 500
    /** `ScriptPackageArchivePolicy.maximumFileBytes`: declared size of one file. */
    const val MAX_FILE_BYTES = PackageLimits.MAX_FILE_BYTES
    /** Longest file path, in code points. */
    const val MAX_PATH_LENGTH = 512
    /** Deepest file path (`components.count <= 16`). */
    const val MAX_PATH_DEPTH = 16
    const val MAX_NAME_LENGTH = 80
    const val MAX_SUMMARY_LENGTH = 240
    const val MAX_TAGS = 20
    /** Schema bounds that the Swift validator leaves to the JSON Schema. */
    const val MAX_SYMBOL_LENGTH = 80
    const val MAX_AUTHOR_LENGTH = 120
    const val MAX_LICENSE_LENGTH = 40

    private const val RAW_HOST = "raw.githubusercontent.com"
    private const val GITHUB_HOST = "github.com"
    private val identifier = Regex("^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$")
    private val semanticVersion = Regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
    private val digest = Regex("^[a-f0-9]{64}$")
    private val rootKeys = setOf("schemaVersion", "generatedAt", "repository", "items")
    private val itemKeys = setOf(
        "id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags",
        "minimumRuntimeVersion", "sourceURL", "featured", "files",
    )
    private val fileKeys = setOf("path", "url", "sha256", "bytes")

    /**
     * Decodes and fully validates an index.
     *
     * Refused: more than 1 MiB; bytes that are not strict UTF-8; anything but one JSON object;
     * an unknown key at any level (a future field must not be silently ignored); a missing or
     * wrongly typed field; an unknown `kind`; an unparseable `generatedAt`; and every rule of
     * [validate].
     *
     * @throws GalleryException [GalleryException.Kind.INVALID_INDEX] with all reasons, one per line.
     */
    fun decode(data: ByteArray): GalleryIndex {
        if (data.size > MAX_INDEX_BYTES) invalid("Gallery index exceeds 1 MiB.")
        val text = SafeFiles.decodeUtf8(data) ?: invalid("Gallery index is not valid UTF-8.")
        val root = GalleryFiles.parseObject(text) ?: invalid("Gallery index must be a JSON object.")
        val items = root.opt("items") as? JSONArray
        if (!rootKeys.containsAll(keys(root)) || items == null) invalid("Gallery index contains unknown fields or invalid items.")
        val schemaVersion = integer(root, "schemaVersion") ?: invalid("Gallery index field schemaVersion is missing or invalid.")
        val generatedAt = (root.opt("generatedAt") as? String)?.let(::instant) ?: invalid("Gallery index field generatedAt must be an ISO 8601 date-time.")
        val repository = root.opt("repository") as? String ?: invalid("Gallery index field repository is missing or invalid.")
        val index = GalleryIndex(
            schemaVersion = if (schemaVersion in Int.MIN_VALUE..Int.MAX_VALUE) schemaVersion.toInt() else -1,
            generatedAt = generatedAt,
            repository = repository,
            items = List(items.length()) { item(items.opt(it)) },
        )
        val issues = validate(index)
        if (issues.isNotEmpty()) invalid(issues.joinToString("\n") { it.message })
        return index
    }

    /**
     * Semantic rules of a decoded index. An empty result means the index is acceptable.
     *
     * Index: schema version 1; 1–500 items; an HTTPS `github.com` repository URL; item ids unique
     * ignoring case. Every item additionally passes [validateItem].
     */
    fun validate(index: GalleryIndex): List<GalleryValidationIssue> {
        val issues = ArrayList<GalleryValidationIssue>()
        fun reject(id: String, message: String) { issues.add(GalleryValidationIssue(id, message)) }
        if (index.schemaVersion != GalleryIndex.CURRENT_SCHEMA_VERSION) reject("schema", "Gallery schema ${index.schemaVersion} is unsupported.")
        if (index.items.isEmpty() || index.items.size > MAX_ITEMS) reject("items", "Gallery must contain 1–$MAX_ITEMS items.")
        if (!isGitHubUrl(index.repository)) reject("repository", "Gallery repository must be an HTTPS github.com URL.")
        if (index.items.map { it.id.lowercase(Locale.ROOT) }.toSet().size != index.items.size) {
            reject("duplicate_item", "Gallery item identifiers must be unique.")
        }
        for (item in index.items) issues.addAll(validateItem(item))
        return issues
    }

    /**
     * Rules of one item; the installer re-runs them so an item is never installed on the
     * strength of an earlier check.
     *
     * Refused: an id outside `[A-Za-z0-9][A-Za-z0-9.-]{2,127}`; a blank or over-long name,
     * summary, symbol, author or license; a version that is not `major.minor.patch[-pre]`; a
     * runtime contract other than `1.0`; more than 20 tags or tags equal ignoring case; a source
     * URL that is not HTTPS `github.com`; fewer than 2 or more than 500 files; paths that are
     * equal after NFC normalization and case folding (they would overwrite each other); a path
     * that fails [isSafeRelativePath]; a file URL that fails [isRawGitHubUrl]; a hash that is not
     * 64 lowercase hex digits; a file size outside 1 byte…25 MiB; a widget without `widget.json`
     * and `main.jsx` or above 32 MiB; a Skill that is not exactly `skill.json` and `SKILL.md` or
     * above 256 KiB.
     */
    fun validateItem(item: GalleryItem): List<GalleryValidationIssue> {
        val issues = ArrayList<GalleryValidationIssue>()
        val prefix = item.id.ifEmpty { "item" }
        fun reject(rule: String, message: String) { issues.add(GalleryValidationIssue("$prefix.$rule", message)) }

        if (!identifier.matches(item.id)) reject("id", "Gallery item id is invalid: ${item.id}")
        if (!bounded(item.name, MAX_NAME_LENGTH)) reject("name", "${item.id} has an invalid name.")
        if (!semanticVersion.matches(item.version)) reject("version", "${item.id} must use semantic versioning.")
        if (!bounded(item.summary, MAX_SUMMARY_LENGTH)) reject("summary", "${item.id} has an invalid summary.")
        if (!bounded(item.symbol, MAX_SYMBOL_LENGTH)) reject("symbol", "${item.id} has an invalid symbol.")
        if (!bounded(item.author, MAX_AUTHOR_LENGTH)) reject("author", "${item.id} has an invalid author.")
        if (!bounded(item.license, MAX_LICENSE_LENGTH)) reject("license", "${item.id} has an invalid license.")
        if (item.minimumRuntimeVersion != GalleryIndex.RUNTIME_CONTRACT_VERSION) {
            reject("runtime", "${item.id} requires unsupported runtime ${item.minimumRuntimeVersion}.")
        }
        if (item.tags.size > MAX_TAGS || item.tags.map { it.lowercase(Locale.ROOT) }.toSet().size != item.tags.size) {
            reject("tags", "${item.id} has invalid tags.")
        }
        if (!isGitHubUrl(item.sourceUrl)) reject("source", "${item.id} sourceURL must use HTTPS github.com.")
        if (item.files.size < 2 || item.files.size > MAX_FILES) reject("files", "${item.id} has an invalid file count.")

        if (item.files.map { PackageNames.identity(it.path) }.toSet().size != item.files.size) {
            reject("paths", "${item.id} contains duplicate or case-colliding paths.")
        }
        var total = 0L
        for (file in item.files) {
            if (!isSafeRelativePath(file.path)) reject("path", "${item.id} contains unsafe path ${file.path}.")
            if (!isRawGitHubUrl(file.url)) reject("url", "${item.id} files must use raw.githubusercontent.com over HTTPS.")
            if (!digest.matches(file.sha256)) reject("hash", "${item.id} contains an invalid SHA-256.")
            if (file.bytes <= 0 || file.bytes > MAX_FILE_BYTES) reject("bytes", "${item.id} contains an invalid file size.")
            val size = maxOf(0L, file.bytes)
            if (total <= Long.MAX_VALUE - size) total += size else reject("total", "${item.id} size overflows.")
        }
        val paths = item.files.map { it.path }.toSet()
        when (item.kind) {
            GalleryItemKind.WIDGET -> {
                if (!paths.containsAll(setOf("widget.json", "main.jsx"))) reject("required", "Widget ${item.id} must contain widget.json and main.jsx.")
                if (total > MAX_WIDGET_BYTES) reject("total", "Widget ${item.id} exceeds 32 MiB.")
            }
            GalleryItemKind.SKILL -> {
                if (paths != setOf("skill.json", "SKILL.md")) reject("required", "Skill ${item.id} must contain exactly skill.json and SKILL.md.")
                if (total > MAX_SKILL_BYTES) reject("total", "Skill ${item.id} exceeds 256 KiB.")
            }
        }
        return issues
    }

    /**
     * True when [path] can only name a location inside the item's own directory: not empty, at
     * most 512 code points, no leading slash, no backslash, colon (drive or stream syntax), NUL
     * or other control character, and 1–16 components none of which is empty, `.` or `..`.
     */
    fun isSafeRelativePath(path: String): Boolean {
        if (path.isEmpty() || path.codePointCount(0, path.length) > MAX_PATH_LENGTH) return false
        if (path.startsWith("/") || path.contains('\\') || path.contains(':') || path.any { it.isISOControl() }) return false
        val components = path.split('/')
        return components.size <= MAX_PATH_DEPTH && components.all { it.isNotEmpty() && it != "." && it != ".." }
    }

    /**
     * The Gallery trust rule for the index, every file and every redirect hop: HTTPS, host
     * exactly `raw.githubusercontent.com`, and no user info, port, query or fragment. A URL that
     * does not parse, or whose authority is anything but the bare host, is untrusted.
     */
    fun isRawGitHubUrl(url: String): Boolean {
        val uri = parse(url) ?: return false
        return hostIs(uri, RAW_HOST) && uri.rawQuery == null && uri.rawFragment == null
    }

    /** [isRawGitHubUrl] for a redirect target; the transport calls this for every hop. */
    fun isTrustedRedirect(target: URI): Boolean = isRawGitHubUrl(target.toString())

    /** Source and repository links: HTTPS, host exactly `github.com`, no user info and no port. */
    fun isGitHubUrl(url: String): Boolean = parse(url)?.let { hostIs(it, GITHUB_HOST) } == true

    private fun parse(url: String): URI? = try {
        URI(url).takeIf { it.isAbsolute && !it.isOpaque && it.scheme.equals("https", ignoreCase = true) }
    } catch (_: URISyntaxException) {
        null
    }

    /** Host match that also excludes user info and any port, including an empty one (`host:`). */
    private fun hostIs(uri: URI, host: String): Boolean =
        uri.host?.lowercase(Locale.ROOT) == host && uri.rawUserInfo == null && uri.port == -1 &&
            uri.rawAuthority?.lowercase(Locale.ROOT) == host

    private fun item(value: Any?): GalleryItem {
        val json = value as? JSONObject ?: invalid("Gallery index contains unknown fields or invalid items.")
        val files = json.opt("files") as? JSONArray
        if (!itemKeys.containsAll(keys(json)) || files == null) invalid("Gallery item contains unknown fields.")
        val id = json.opt("id") as? String ?: invalid("Gallery item field id is missing or invalid.")
        fun text(key: String): String = json.opt(key) as? String ?: invalid("Gallery item $id field $key is missing or invalid.")
        val tags = json.opt("tags") as? JSONArray ?: invalid("Gallery item $id field tags is missing or invalid.")
        return GalleryItem(
            id = id,
            kind = GalleryItemKind.fromWire(json.opt("kind") as? String) ?: invalid("Gallery item $id has an unknown kind."),
            name = text("name"),
            version = text("version"),
            summary = text("summary"),
            symbol = text("symbol"),
            author = text("author"),
            license = text("license"),
            tags = List(tags.length()) { tags.opt(it) as? String ?: invalid("Gallery item $id field tags is missing or invalid.") },
            minimumRuntimeVersion = text("minimumRuntimeVersion"),
            sourceUrl = text("sourceURL"),
            featured = json.opt("featured") as? Boolean ?: invalid("Gallery item $id field featured is missing or invalid."),
            files = List(files.length()) { file(id, files.opt(it)) },
        )
    }

    private fun file(id: String, value: Any?): GalleryFile {
        val json = value as? JSONObject
        if (json == null || !fileKeys.containsAll(keys(json))) invalid("Gallery item contains unknown fields.")
        fun text(key: String): String = json.opt(key) as? String ?: invalid("Gallery item $id has a file with a missing or invalid $key.")
        return GalleryFile(
            path = text("path"),
            url = text("url"),
            sha256 = text("sha256"),
            bytes = integer(json, "bytes") ?: invalid("Gallery item $id has a file with a missing or invalid bytes."),
        )
    }

    private fun keys(json: JSONObject): Set<String> = json.keys().asSequence().toSet()

    /** A JSON integer; fractions, strings and booleans are not coerced. */
    private fun integer(json: JSONObject, key: String): Long? = when (val value = json.opt(key)) {
        is Int -> value.toLong()
        is Long -> value
        else -> null
    }

    private fun instant(text: String): Long? = try {
        OffsetDateTime.parse(text).toInstant().toEpochMilli()
    } catch (_: DateTimeParseException) {
        null
    } catch (_: ArithmeticException) {
        null
    }

    private fun bounded(text: String, maximum: Int): Boolean = text.isNotBlank() && text.codePointCount(0, text.length) <= maximum

    private fun invalid(message: String): Nothing = throw GalleryException(GalleryException.Kind.INVALID_INDEX, message)
}
