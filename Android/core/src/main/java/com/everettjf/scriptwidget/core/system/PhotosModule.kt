package com.everettjf.scriptwidget.core.system

import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.time.LocalDateTime
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Base64
import java.util.UUID

/** Bounds of the Photos API. */
object PhotoLimits {
    /** Photos the user can select in the app. */
    const val MAXIMUM_SELECTED = 24
    /** Thumbnails in one result. */
    const val MAXIMUM_RETURNED = 4
    /** Candidates one query considers, newest first. */
    const val MAXIMUM_CANDIDATES = 64
    const val MAXIMUM_SIDE = 768
    const val MAXIMUM_THUMBNAIL_BYTES = 128 * 1024
    const val SNAPSHOT_LIFETIME_SECONDS = 86_400.0
    /** A partially available result is retried after at most this long. */
    const val PARTIAL_RETRY_SECONDS = 60.0
}

/** Script-visible Photos errors, with the Apple runtime's wording. */
enum class PhotosError(val message: String) {
    INVALID("[invalid_options] Invalid photo options or selection"),
    DENIED("[permission_denied] Allow Photos access and choose photos or albums in ScriptWidget Settings"),
    UNAVAILABLE("[unavailable] Photos could not be loaded"),
    CHANGED("[scope_changed] Photo access changed. Reload and try again."),
    CACHE_MISS("[cache_miss] Open this widget in ScriptWidget to prepare its photo snapshot");

    fun reject(): SystemReject = SystemReject(message)
}

/** `items(options)` input: `limit` integer 1–4, `offset` integer 0–63, `maxAgeSeconds` 0–86400. Unknown keys, Booleans and nonfinite numbers reject. */
class PhotoQuery(val limit: Int, val offset: Int, val maxAgeSeconds: Double) {
    /** A snapshot is reused only for the same page. */
    val identity: String get() = "$limit:$offset"

    companion object {
        fun parse(options: JSONObject?): PhotoQuery {
            val values = options ?: JSONObject()
            if (values.keys().asSequence().any { it !in setOf("limit", "offset", "maxAgeSeconds") }) throw PhotosError.INVALID.reject()
            fun number(key: String, fallback: Double, range: ClosedFloatingPointRange<Double>, integer: Boolean): Double {
                if (!values.has(key)) return fallback
                val value = (values.opt(key) as? Number)?.toDouble()
                if (value == null || !value.isFinite() || value !in range || (integer && Math.rint(value) != value)) throw PhotosError.INVALID.reject()
                return value
            }
            return PhotoQuery(number("limit", 4.0, 1.0..4.0, true).toInt(), number("offset", 0.0, 0.0..63.0, true).toInt(), number("maxAgeSeconds", 3600.0, 0.0..86_400.0, false))
        }
    }
}

/** Produces a JPEG of the requested size and quality, or null. The Android implementation scales and compresses a bitmap. */
fun interface JpegEncoder { fun encode(width: Int, height: Int, quality: Int): ByteArray? }

/** A stored thumbnail: JPEG bytes and its pixel size. */
class Thumbnail(val bytes: ByteArray, val width: Int, val height: Int)

/** Thumbnail size and quality search: at most 768 px on the long side and at most 128 KiB. */
object ThumbnailPlan {
    private val qualities = listOf(85, 75, 65, 55, 45)
    private const val MINIMUM_SIDE = 96

    /** [width] × [height] scaled down (never up) so the longer side is at most [maximumSide]; each side stays at least 1. */
    fun fit(width: Int, height: Int, maximumSide: Int = PhotoLimits.MAXIMUM_SIDE): Pair<Int, Int> {
        if (width <= 0 || height <= 0) return 0 to 0
        val longest = maxOf(width, height)
        if (longest <= maximumSide) return width to height
        val scale = maximumSide.toDouble() / longest
        return maxOf(1, Math.round(width * scale).toInt()) to maxOf(1, Math.round(height * scale).toInt())
    }

    /**
     * Tries decreasing quality, then smaller sizes, until the JPEG fits the byte limit.
     * Null when even the smallest attempt is too large or the encoder fails.
     */
    fun encode(width: Int, height: Int, maximumBytes: Int = PhotoLimits.MAXIMUM_THUMBNAIL_BYTES, encoder: JpegEncoder): Thumbnail? {
        var (targetWidth, targetHeight) = fit(width, height)
        if (targetWidth <= 0 || targetHeight <= 0) return null
        while (true) {
            for (quality in qualities) {
                val bytes = encoder.encode(targetWidth, targetHeight, quality) ?: return null
                if (bytes.size <= maximumBytes && isJpeg(bytes)) return Thumbnail(bytes, targetWidth, targetHeight)
            }
            if (maxOf(targetWidth, targetHeight) <= MINIMUM_SIDE) return null
            val next = fit(targetWidth, targetHeight, maxOf(MINIMUM_SIDE, maxOf(targetWidth, targetHeight) * 3 / 4))
            targetWidth = next.first; targetHeight = next.second
        }
    }

    fun isJpeg(bytes: ByteArray): Boolean = bytes.size >= 4 && bytes[0] == 0xFF.toByte() && bytes[1] == 0xD8.toByte() && bytes[2] == 0xFF.toByte()
}

/** A selected photo. [id] is an opaque UUID, never a path; [width]/[height] are the original pixel size. */
class PhotoEntry(val id: String, val width: Int, val height: Int, val takenAt: Long, val revision: Long)

/**
 * The photos the user picked with the system Photo Picker, kept as bounded,
 * metadata-free JPEG thumbnails in app-private storage. Scripts never see
 * the library, a URI, a file name, a location or EXIF data.
 */
class PhotoLibrary(private val directory: File) {
    class Corrupt : Exception("photo index is invalid")
    private val index = PrivateFile(File(directory, "index.json"), 64 * 1024)

    /** Selected photos, newest first by capture time, ties by identifier. @throws Corrupt for an invalid index. */
    fun list(): List<PhotoEntry> = synchronized(index.lock) { load() }.sortedWith(compareByDescending<PhotoEntry> { it.takenAt }.thenBy { it.id })

    /** Digest of the selection; a snapshot made under another selection is never reused. */
    fun identity(entries: List<PhotoEntry>): String = Canonical.sha256(entries.sortedBy { it.id }.joinToString("\n") { "${it.id}:${it.revision}" })

    /**
     * Adds one thumbnail. Refused when 24 photos are already selected, the bytes
     * are not a JPEG, or they exceed 128 KiB.
     */
    fun add(thumbnail: Thumbnail, originalWidth: Int, originalHeight: Int, takenAt: Long, now: Long): PhotoEntry? = synchronized(index.lock) {
        val entries = runCatching { load() }.getOrDefault(emptyList())
        if (entries.size >= PhotoLimits.MAXIMUM_SELECTED || originalWidth < 1 || originalHeight < 1) return@synchronized null
        if (thumbnail.bytes.size > PhotoLimits.MAXIMUM_THUMBNAIL_BYTES || !ThumbnailPlan.isJpeg(thumbnail.bytes)) return@synchronized null
        val entry = PhotoEntry(UUID.randomUUID().toString(), originalWidth, originalHeight, takenAt, now)
        directory.mkdirs()
        val stored = runCatching { File(directory, entry.id + ".jpg").writeBytes(thumbnail.bytes); true }.getOrDefault(false)
        if (stored && save(entries + entry)) entry else { File(directory, entry.id + ".jpg").delete(); null }
    }

    fun remove(id: String): Boolean = synchronized(index.lock) {
        val entries = runCatching { load() }.getOrDefault(emptyList())
        if (CallContext.isOwner(id)) File(directory, "$id.jpg").delete()
        save(entries.filter { it.id != id })
    }

    /** Removes every photo; also the way to recover from a corrupt index. */
    fun clear() = synchronized(index.lock) {
        directory.listFiles()?.forEach { if (it.name.endsWith(".jpg")) it.delete() }
        index.delete()
    }

    /** Thumbnail bytes, or null when the file is missing, not a regular file, too large or not a JPEG. */
    fun read(entry: PhotoEntry): ByteArray? {
        val path = File(directory, entry.id + ".jpg").toPath()
        if (!CallContext.isOwner(entry.id) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS)) return null
        val bytes = runCatching { Files.readAllBytes(path) }.getOrNull() ?: return null
        return bytes.takeIf { it.size <= PhotoLimits.MAXIMUM_THUMBNAIL_BYTES && ThumbnailPlan.isJpeg(it) }
    }

    private fun load(): List<PhotoEntry> {
        val text = try { index.read() } catch (error: PrivateFile.Unreadable) { throw Corrupt() } ?: return emptyList()
        try {
            val root = JSONObject(text)
            val array = root.getJSONArray("photos")
            if (root.opt("formatVersion") != 1 || array.length() > PhotoLimits.MAXIMUM_SELECTED) throw Corrupt()
            val entries = List(array.length()) { position ->
                val item = array.getJSONObject(position)
                PhotoEntry(item.getString("id"), item.getInt("width"), item.getInt("height"), item.getLong("takenAt"), item.getLong("revision"))
            }
            if (entries.any { !CallContext.isOwner(it.id) || it.width < 1 || it.height < 1 } || entries.map { it.id }.toSet().size != entries.size) throw Corrupt()
            return entries
        } catch (error: org.json.JSONException) { throw Corrupt() }
    }

    private fun save(entries: List<PhotoEntry>): Boolean = index.write(JSONObject().put("formatVersion", 1).put("photos", JSONArray(entries.map {
        JSONObject().put("id", it.id).put("width", it.width).put("height", it.height).put("takenAt", it.takenAt).put("revision", it.revision)
    })).toString())
}

/**
 * The private snapshot record of one installation: which photos one query
 * delivered and when. Image bytes are always read from the current
 * selection, so a removed photo can never be served from a snapshot.
 */
object PhotoSnapshot {
    fun encode(scope: String, query: PhotoQuery, references: List<PhotoEntry>, available: Int, fetchedAtMilliseconds: Long): String = JSONObject()
        .put("formatVersion", 1).put("scope", scope).put("query", query.identity).put("available", available)
        .put("references", JSONArray(references.map { "${it.id}:${it.revision}" })).put("fetchedAt", fetchedAtMilliseconds).toString()

    /**
     * The snapshot's fetch time and available count when it matches the current selection, page and
     * photo revisions and is neither from the future nor older than 24 hours; null otherwise.
     */
    fun match(text: String, scope: String, query: PhotoQuery, references: List<PhotoEntry>, nowMilliseconds: Long): Pair<Long, Int>? {
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (root.opt("formatVersion") != 1 || root.opt("scope") != scope || root.opt("query") != query.identity) return null
        val stored = (root.opt("references") as? JSONArray)?.let { array -> List(array.length()) { array.opt(it) as? String } } ?: return null
        if (stored != references.map { "${it.id}:${it.revision}" }) return null
        val fetchedAt = (root.opt("fetchedAt") as? Number)?.toLong() ?: return null
        val available = (root.opt("available") as? Number)?.toInt() ?: return null
        val age = (nowMilliseconds - fetchedAt) / 1000.0
        if (age < 0 || age > PhotoLimits.SNAPSHOT_LIFETIME_SECONDS || available < 0 || available > references.size) return null
        return fetchedAt to available
    }

    /**
     * Whether a matching snapshot may answer a query. Future timeline entries and Live Activity
     * presentations always use it; otherwise it must be within `maxAgeSeconds`, and within 60 seconds
     * when some thumbnails were unavailable so they are retried.
     */
    fun usable(fetchedAtMilliseconds: Long, available: Int, references: Int, query: PhotoQuery, readOnly: Boolean, nowMilliseconds: Long): Boolean {
        if (readOnly) return true
        val limit = if (available < references) minOf(query.maxAgeSeconds, PhotoLimits.PARTIAL_RETRY_SECONDS) else query.maxAgeSeconds
        return (nowMilliseconds - fetchedAtMilliseconds) / 1000.0 <= limit
    }
}

/**
 * `$photos`. No storage permission exists or is needed: the only photos
 * reachable are the thumbnails the user chose in the app.
 */
class PhotosModule(
    private val library: PhotoLibrary,
    private val snapshotDirectory: File,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$photos")

    override fun handles(operation: String): Boolean = operation.startsWith("photos.")

    override fun call(request: ExecutionRequest, operation: String, payload: String?): String? {
        val context = CallContext.from(request)
        val value = when (operation) {
            "photos.isAvailable" -> permitted(context).toString()
            "photos.authorizationStatus" -> JSONObject.quote(authorizationStatus(context))
            else -> throw IllegalArgumentException("Unsupported operation $operation")
        }
        SystemLog.call(operation, "ok")
        return value
    }

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "photos.requestAuthorization" -> runSystemCall(operation, done) { requestAuthorization(context).toString() }
            "photos.items" -> runSystemCall(operation, done) { items(context, payload?.optJSONObject("options"), payload?.optBoolean("invalid") == true).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** An installed Package 2.0 widget that declares `photos`. */
    fun permitted(context: CallContext): Boolean = context.isInstalled && context.declares("photos")

    /**
     * `undeclared` without the package permission, otherwise `limited`: with the Photo Picker
     * the app can only ever reach the photos the user handed over, which is Apple's limited access.
     */
    fun authorizationStatus(context: CallContext): String = if (permitted(context)) "limited" else "undeclared"

    /** Nothing to prompt for on Android; resolves true. Consumes a data query except in read-only presentations. */
    fun requestAuthorization(context: CallContext): Boolean {
        if (!permitted(context)) throw PhotosError.DENIED.reject()
        if (context.isTimelineProjection || context.isLiveActivity) return true
        if (!context.consumeDataQuery()) throw SystemReject("[query_limit] Too many system data queries")
        return true
    }

    /**
     * `items(options)`, in the Apple runtime's order: package permission, options, query budget,
     * a nonempty selection, then the snapshot rules. The selection is compared again before delivery.
     */
    fun items(context: CallContext, options: JSONObject?, invalidOptions: Boolean = false): JSONObject {
        if (!permitted(context)) throw PhotosError.DENIED.reject()
        if (invalidOptions) throw PhotosError.INVALID.reject()
        val query = PhotoQuery.parse(options)
        if (!context.consumeDataQuery()) throw SystemReject("[query_limit] Too many system data queries")
        val record = PrivateFile(File(snapshotDirectory, ownerFileName(context.installation, ".photos.json")), 64 * 1024)
        try {
            val entries = try { library.list() } catch (error: PhotoLibrary.Corrupt) { throw PhotosError.UNAVAILABLE.reject() }
            if (entries.isEmpty()) throw PhotosError.DENIED.reject()
            val scope = library.identity(entries)
            val references = entries.take(PhotoLimits.MAXIMUM_CANDIDATES).drop(query.offset).take(query.limit)
            val now = clock.now()
            val readOnly = context.isTimelineProjection || context.isLiveActivity
            val items = JSONArray()
            for (entry in references) {
                val bytes = library.read(entry) ?: continue
                items.put(JSONObject().put("id", entry.id).put("image", "data:image/jpeg;base64," + Base64.getEncoder().encodeToString(bytes)).put("width", entry.width).put("height", entry.height))
            }
            val cached = synchronized(record.lock) { runCatching { record.read() }.getOrNull() }?.let { PhotoSnapshot.match(it, scope, query, references, now) }
                ?.takeIf { PhotoSnapshot.usable(it.first, it.second, references.size, query, readOnly, now) && it.second == items.length() }
            val fetchedAt = cached?.first ?: now
            if (cached == null) {
                if (readOnly) throw PhotosError.CACHE_MISS.reject()
                synchronized(record.lock) { record.write(PhotoSnapshot.encode(scope, query, references, items.length(), now)) }
            }
            val current = try { library.list() } catch (error: PhotoLibrary.Corrupt) { throw PhotosError.CHANGED.reject() }
            if (!permitted(context) || library.identity(current) != scope) throw PhotosError.CHANGED.reject()
            return JSONObject().put("status", if (items.length() == 0 && references.isNotEmpty()) "unavailable" else "ready").put("items", items)
                .put("unavailableCount", references.size - items.length()).put("fetchedAt", IsoDates.format(fetchedAt))
                .put("source", if (cached != null) "cache" else "system").put("stale", (now - fetchedAt) / 1000.0 > query.maxAgeSeconds)
        } catch (error: SystemReject) {
            synchronized(record.lock) { record.delete() }
            throw error
        }
    }
}

/** Copies Photo Picker results into the [PhotoLibrary] as re-encoded thumbnails; the originals are never kept. */
class PhotoImporter(context: Context, private val library: PhotoLibrary) {
    private val resolver = context.applicationContext.contentResolver

    /** Imports up to the remaining capacity and returns how many photos were added. */
    fun import(uris: List<Uri>): Int {
        var added = 0
        for (uri in uris) if (importOne(uri)) added += 1
        SystemLog.call("photos.import", "ok added=$added of=${uris.size}")
        return added
    }

    private fun importOne(uri: Uri): Boolean = runCatching {
        var originalWidth = 0
        var originalHeight = 0
        // ImageDecoder applies the EXIF orientation; re-encoding below drops every other tag.
        val bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(resolver, uri)) { decoder, info, _ ->
            originalWidth = info.size.width; originalHeight = info.size.height
            val (width, height) = ThumbnailPlan.fit(originalWidth, originalHeight)
            decoder.setTargetSize(maxOf(1, width), maxOf(1, height))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val thumbnail = ThumbnailPlan.encode(bitmap.width, bitmap.height) { width, height, quality ->
            val scaled = if (width == bitmap.width && height == bitmap.height) bitmap else Bitmap.createScaledBitmap(bitmap, width, height, true)
            val stream = ByteArrayOutputStream()
            val ok = scaled.compress(Bitmap.CompressFormat.JPEG, quality, stream)
            if (scaled !== bitmap) scaled.recycle()
            if (ok) stream.toByteArray() else null
        }
        bitmap.recycle()
        val now = System.currentTimeMillis()
        thumbnail != null && library.add(thumbnail, originalWidth, originalHeight, captureTime(uri) ?: now, now) != null
    }.getOrDefault(false)

    /** Capture time from EXIF, used only for ordering; it is not stored with the image or exposed to scripts. */
    private fun captureTime(uri: Uri): Long? = runCatching {
        resolver.openInputStream(uri)?.use { stream ->
            val text = android.media.ExifInterface(stream).getAttribute(android.media.ExifInterface.TAG_DATETIME_ORIGINAL) ?: return@use null
            LocalDateTime.parse(text, DateTimeFormatter.ofPattern("yyyy:MM:dd HH:mm:ss")).atZone(ZoneId.systemDefault()).toInstant().toEpochMilli()
        }
    }.getOrNull()
}
