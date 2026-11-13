package com.everettjf.scriptwidget.core.system

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset

/** Identifier helpers: calendar IDs are opaque and compared by exact UTF-8 bytes. */
internal object CalendarIDs {
    const val MAXIMUM = 64
    val order: Comparator<String> = Comparator { a, b -> java.util.Arrays.compareUnsigned(a.toByteArray(), b.toByteArray()) }

    /** At most 64 unique, nonempty identifiers of at most 256 UTF-8 bytes each. */
    fun valid(ids: List<String>): Boolean = ids.size <= MAXIMUM && ids.toSet().size == ids.size && ids.all { it.isNotEmpty() && it.toByteArray().size <= 256 }
}

/** Script-visible calendar scope errors, with the Apple runtime's wording. */
enum class CalendarAccessError(val message: String) {
    UNAVAILABLE("[permission_denied] Calendar source settings are unavailable. Open ScriptWidget to review access."),
    NONE_SELECTED("[permission_denied] No Calendar sources are selected in ScriptWidget Settings."),
    OUTSIDE_SELECTION("[invalid_options] A requested Calendar source is unavailable or outside your selection."),
    CHANGED("[permission_denied] Calendar source selection changed. Run the widget again.");

    fun reject(): SystemReject = SystemReject(message)
}

/**
 * The calendars the user allows widgets to read, chosen in the app. Null
 * [calendarIDs] means all calendars including new ones; an empty list means
 * none. Scripts can narrow this scope with `calendarIDs` but never widen it.
 */
class CalendarSelection(calendarIDs: List<String>?) {
    val calendarIDs: List<String>? = calendarIDs?.sortedWith(CalendarIDs.order)

    val encoded: String get() = Canonical.encode(mapOf("formatVersion" to 1, "mode" to if (calendarIDs == null) "all" else "selected", "calendarIDs" to (calendarIDs ?: emptyList())))

    /** Digest stored with snapshots, so narrowing the selection invalidates older, broader snapshots. */
    val identity: String get() = Canonical.sha256(encoded)

    fun allows(id: String): Boolean = calendarIDs?.contains(id) ?: true

    /**
     * The calendars one query may read: every [requested] ID must exist and be
     * inside the selection (`outsideSelection` otherwise); with no request, all
     * available selected calendars. An empty selection is `noneSelected`.
     */
    fun permittedIDs(available: List<String>, requested: List<String>): List<String> {
        if (calendarIDs != null && calendarIDs.isEmpty()) throw CalendarAccessError.NONE_SELECTED.reject()
        val known = available.toSet()
        if (!requested.all { it in known && allows(it) }) throw CalendarAccessError.OUTSIDE_SELECTION.reject()
        val permitted = (if (requested.isEmpty()) known.filter { allows(it) } else requested).sortedWith(CalendarIDs.order)
        if (calendarIDs != null && permitted.isEmpty()) throw CalendarAccessError.OUTSIDE_SELECTION.reject()
        return permitted
    }

    override fun equals(other: Any?): Boolean = other is CalendarSelection && other.encoded == encoded
    override fun hashCode(): Int = encoded.hashCode()

    companion object {
        val ALL = CalendarSelection(null)
        val NONE = CalendarSelection(emptyList())

        /** Parses stored settings. Anything but the exact expected shape fails closed with `unavailable`. */
        fun decode(text: String): CalendarSelection {
            val root = runCatching { JSONObject(text) }.getOrNull() ?: throw CalendarAccessError.UNAVAILABLE.reject()
            val mode = root.opt("mode") as? String
            val array = root.opt("calendarIDs") as? JSONArray
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "mode", "calendarIDs") || root.opt("formatVersion") != 1 || mode !in setOf("all", "selected") || array == null) throw CalendarAccessError.UNAVAILABLE.reject()
            val ids = List(array.length()) { array.opt(it) as? String ?: throw CalendarAccessError.UNAVAILABLE.reject() }
            if (!CalendarIDs.valid(ids) || (mode == "all" && ids.isNotEmpty())) throw CalendarAccessError.UNAVAILABLE.reject()
            return CalendarSelection(if (mode == "all") null else ids)
        }
    }
}

/**
 * Where the app stores the calendar selection. On Android nothing is
 * selected until the user chooses calendars in the app, so a missing file
 * means [CalendarSelection.NONE]. A present malformed file blocks reads.
 */
class CalendarSelectionStore(private val file: PrivateFile) {
    /** @throws SystemReject [CalendarAccessError.UNAVAILABLE] when the settings are present but invalid. */
    fun load(): CalendarSelection = synchronized(file.lock) {
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw CalendarAccessError.UNAVAILABLE.reject() }
        if (text == null) CalendarSelection.NONE else CalendarSelection.decode(text)
    }

    /** Saves an explicit user choice from the app; replaces unreadable settings. */
    fun save(selection: CalendarSelection): Boolean = synchronized(file.lock) {
        CalendarIDs.valid(selection.calendarIDs ?: emptyList()) && file.write(selection.encoded)
    }
}

/** Strict `events(options)` input. Every failure is `[invalid_options]` with the Apple runtime's message. */
class CalendarQuery(val start: Long, val end: Long, val limit: Int, val calendarIDs: List<String>, val maxAgeSeconds: Double) {
    /** Identity of the query window, selected IDs and limit; a snapshot is reused only for an identical query. */
    val cacheIdentity: String get() = Canonical.sha256(Canonical.encode(mapOf("start" to start, "end" to end, "limit" to limit, "calendarIDs" to calendarIDs)))

    companion object {
        const val MAXIMUM_ITEMS = 50
        const val MAXIMUM_RANGE_MILLISECONDS = 31L * 86_400_000L
        private val keys = setOf("start", "end", "limit", "calendarIDs", "maxAgeSeconds")

        private fun invalid(message: String): SystemReject = SystemReject("[invalid_options] $message")

        /**
         * - `start` defaults to the start of the current local day, `end` to one local calendar day later (DST aware);
         * - the range is positive and at most 31 × 24 hours;
         * - `limit` is an integer 1–50 (default 10); `maxAgeSeconds` is 0–86400 (default 60);
         * - `calendarIDs` is 1–16 unique, nonempty IDs of at most 256 UTF-8 bytes.
         */
        fun parse(options: JSONObject?, nowMilliseconds: Long, zone: ZoneId): CalendarQuery {
            val values = options ?: JSONObject()
            if (values.keys().asSequence().any { it !in keys }) throw invalid("Unknown calendar query option")
            fun date(key: String, fallback: () -> Long): Long {
                if (!values.has(key)) return fallback()
                val text = values.opt(key) as? String ?: throw invalid("$key must be an ISO-8601 string")
                if (text.toByteArray().size > 64 || !Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,9})?(?:Z|[+-]\\d{2}:\\d{2})$").matches(text)) throw invalid("$key must be an ISO-8601 string")
                return IsoDates.parse(text) ?: throw invalid("Invalid $key date")
            }
            val start = date("start") { Instant.ofEpochMilli(nowMilliseconds).atZone(zone).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli() }
            val end = date("end") { Instant.ofEpochMilli(start).atZone(zone).plusDays(1).toInstant().toEpochMilli() }
            if (end <= start || end - start > MAXIMUM_RANGE_MILLISECONDS) throw invalid("Calendar range must be positive and at most 31 days")
            fun number(key: String, fallback: Double, minimum: Double, maximum: Double): Double {
                if (!values.has(key)) return fallback
                val value = (values.opt(key) as? Number)?.toDouble()
                if (value == null || !value.isFinite() || value < minimum || value > maximum) throw invalid("Invalid $key")
                return value
            }
            val count = number("limit", 10.0, 1.0, MAXIMUM_ITEMS.toDouble())
            if (Math.rint(count) != count) throw invalid("limit must be an integer")
            val maxAge = number("maxAgeSeconds", 60.0, 0.0, 86_400.0)
            val ids = if (!values.has("calendarIDs")) emptyList() else {
                val array = values.opt("calendarIDs") as? JSONArray
                val list = array?.let { items -> List(items.length()) { items.opt(it) as? String } }
                if (list == null || list.isEmpty() || list.size > 16 || list.any { it == null || it.isEmpty() || it.toByteArray().size > 256 } || list.toSet().size != list.size) {
                    throw invalid("calendarIDs must contain 1–16 unique identifiers")
                }
                list.filterNotNull().sortedWith(CalendarIDs.order)
            }
            return CalendarQuery(start, end, count.toInt(), ids, maxAge)
        }
    }
}

/** One calendar the system knows. */
class CalendarSource(val id: String, val title: String, val writable: Boolean)

/** One event occurrence. Times are epoch milliseconds; all-day events use local midnights. */
class CalendarEvent(val id: String, val calendarID: String, val title: String, val start: Long, val end: Long, val allDay: Boolean) {
    fun toJson(): JSONObject = JSONObject().put("id", id).put("calendarID", calendarID).put("title", CalendarResults.bounded(title, 1024))
        .put("start", IsoDates.format(start)).put("end", IsoDates.format(end)).put("allDay", allDay)
}

/** An existing event as far as ownership checks need it. */
class CalendarEventInfo(val calendarID: String, val recurring: Boolean)

/** The Calendar Provider behind an interface, so query, scope and write rules are testable on the JVM. */
interface CalendarPlatform {
    fun canRead(): Boolean
    fun canWrite(): Boolean
    fun sources(): List<CalendarSource>
    /** Occurrences overlapping the window in [calendarIDs], and whether more exist than were scanned. */
    fun events(start: Long, end: Long, calendarIDs: List<String>): Pair<List<CalendarEvent>, Boolean>
    /** Creates a single, nonrecurring event and returns its identifier, or null when the provider refused. */
    fun insert(calendarID: String, title: String, start: Long, end: Long, allDay: Boolean): String?
    fun update(eventID: String, title: String, start: Long, end: Long, allDay: Boolean): Boolean
    fun event(eventID: String): CalendarEventInfo?
}

/** Result building and snapshot validation for `events()`. */
object CalendarResults {
    const val MAXIMUM_CACHE_BYTES = 64 * 1024
    const val STALE_SECONDS = 60.0

    /** [text] cut to at most [maximumBytes] UTF-8 bytes on a code point boundary. */
    fun bounded(text: String, maximumBytes: Int): String {
        if (text.toByteArray().size <= maximumBytes) return text
        val builder = StringBuilder()
        var used = 0
        var index = 0
        while (index < text.length) {
            val point = text.codePointAt(index)
            val size = String(Character.toChars(point)).toByteArray().size
            if (used + size > maximumBytes) break
            builder.appendCodePoint(point); used += size; index += Character.charCount(point)
        }
        return builder.toString()
    }

    /**
     * `{status, items, fetchedAt, source, stale, truncated}` for a system read:
     * only permitted calendars, only events overlapping the window, sorted by
     * start then identifier, cut to the limit; `truncated` reports any excess.
     */
    fun build(query: CalendarQuery, permitted: List<String>, events: List<CalendarEvent>, scanTruncated: Boolean, nowMilliseconds: Long): JSONObject {
        val allowed = permitted.toSet()
        val matching = events.filter { it.calendarID in allowed && it.end >= it.start && (if (it.allDay) it.end > query.start else it.end >= query.start) && it.start < query.end }
            .sortedWith(compareBy<CalendarEvent> { it.start }.thenBy(CalendarIDs.order) { it.id })
        val items = matching.take(query.limit)
        return JSONObject().put("status", if (items.isEmpty()) "empty" else "ready").put("items", JSONArray(items.map { it.toJson() }))
            .put("fetchedAt", IsoDates.format(nowMilliseconds)).put("source", "system").put("stale", false)
            .put("truncated", scanTruncated || matching.size > query.limit)
    }

    fun encodeCache(query: CalendarQuery, selection: CalendarSelection, value: JSONObject, nowMilliseconds: Long): String =
        JSONObject().put("query", query.cacheIdentity).put("selection", selection.identity).put("timestamp", nowMilliseconds / 1000.0).put("value", value).toString()

    /**
     * A stored snapshot as a script result, or null. It is used only when the
     * query and selection identities match, it is not from the future, it is
     * no older than `maxAgeSeconds` (0 disables the cache) and every record is
     * inside the current selection and window. Results older than 60 seconds are `stale`.
     */
    fun decodeCache(text: String, query: CalendarQuery, selection: CalendarSelection, nowMilliseconds: Long): JSONObject? {
        if (query.maxAgeSeconds <= 0 || selection.calendarIDs?.isEmpty() == true || text.toByteArray().size > MAXIMUM_CACHE_BYTES) return null
        val root = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (root.keys().asSequence().toSet() != setOf("query", "selection", "timestamp", "value")) return null
        if (root.opt("selection") != selection.identity || root.opt("query") != query.cacheIdentity) return null
        val timestamp = (root.opt("timestamp") as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: return null
        val age = nowMilliseconds / 1000.0 - timestamp
        if (age < 0 || age > query.maxAgeSeconds) return null
        val value = root.opt("value") as? JSONObject ?: return null
        if (value.keys().asSequence().toSet() != setOf("status", "items", "fetchedAt", "source", "stale", "truncated")) return null
        val items = value.opt("items") as? JSONArray ?: return null
        if (items.length() > query.limit || value.opt("status") != (if (items.length() == 0) "empty" else "ready") || value.opt("source") != "system") return null
        if (IsoDates.parse(value.opt("fetchedAt") as? String ?: return null) == null || value.opt("stale") !is Boolean || value.opt("truncated") !is Boolean) return null
        for (index in 0 until items.length()) {
            val item = items.opt(index) as? JSONObject ?: return null
            if (item.keys().asSequence().toSet() != setOf("id", "calendarID", "title", "start", "end", "allDay")) return null
            val id = item.opt("id") as? String ?: return null
            val calendarID = item.opt("calendarID") as? String ?: return null
            val title = item.opt("title") as? String ?: return null
            val start = IsoDates.parse(item.opt("start") as? String ?: return null) ?: return null
            val end = IsoDates.parse(item.opt("end") as? String ?: return null) ?: return null
            if (id.toByteArray().size > 2048 || calendarID.isEmpty() || calendarID.toByteArray().size > 256 || !selection.allows(calendarID) ||
                (query.calendarIDs.isNotEmpty() && calendarID !in query.calendarIDs) || title.toByteArray().size > 1024 ||
                end < start || end < query.start || start >= query.end || item.opt("allDay") !is Boolean) return null
        }
        return value.put("source", "cache").put("stale", age > STALE_SECONDS)
    }
}

/** Android stores all-day events as UTC midnights; scripts see local midnights, as on Apple platforms. */
object AllDayDates {
    fun utcToLocal(milliseconds: Long, zone: ZoneId): Long =
        Instant.ofEpochMilli(milliseconds).atZone(ZoneOffset.UTC).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli()

    /** The UTC midnight of the local date of [milliseconds]; [roundUp] moves a time inside a day to the next midnight (for end dates). */
    fun localToUtc(milliseconds: Long, zone: ZoneId, roundUp: Boolean = false): Long {
        val local = Instant.ofEpochMilli(milliseconds).atZone(zone)
        var date: LocalDate = local.toLocalDate()
        if (roundUp && local.toLocalTime().toNanoOfDay() > 0) date = date.plusDays(1)
        return date.atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
    }
}

/** Strict `create`/`update` input: closed fields, canonical request UUID, positive duration of at most 366 days. */
class CalendarMutation(val requestID: String, val calendarID: String, val title: String, val start: Long, val end: Long, val allDay: Boolean, val eventID: String?, val fingerprint: String) {
    companion object {
        fun parse(options: JSONObject, updating: Boolean): CalendarMutation {
            SystemOptions.fields(options, setOf("requestID", "calendarID", "title", "start", "end", "allDay") + (if (updating) setOf("id") else emptySet()))
            val requestID = SystemOptions.text(SystemOptions.member(options, "requestID"), 36)
            if (!SystemOptions.validRequestID(requestID)) throw SystemServiceError.INVALID_OPTIONS.reject()
            val calendarID = SystemOptions.text(SystemOptions.member(options, "calendarID"), 256)
            val title = SystemOptions.text(SystemOptions.member(options, "title"), 512)
            val start = SystemOptions.date(SystemOptions.member(options, "start"))
            val end = SystemOptions.date(SystemOptions.member(options, "end"))
            if (end <= start || end - start > 366L * 86_400_000L) throw SystemServiceError.INVALID_OPTIONS.reject()
            val allDay = if (options.has("allDay")) SystemOptions.boolean(options.opt("allDay")) else false
            val eventID = if (updating) SystemOptions.text(SystemOptions.member(options, "id"), 2048) else null
            return CalendarMutation(requestID, calendarID, title, start, end, allDay, eventID, Canonical.fingerprint(if (updating) "update" else "create", options))
        }
    }
}

/** Events an installation created, the only ones it may update. Bounded to 128 and kept outside `$storage`. */
class OwnedEvents(private val file: PrivateFile) {
    val lock: Any get() = file.lock

    /** @throws SystemReject `unavailable` for an unreadable registry, `limit_exceeded` for one beyond its bounds. */
    fun load(): MutableMap<String, String> {
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw SystemServiceError.UNAVAILABLE.reject() } ?: return LinkedHashMap()
        val root = runCatching { JSONObject(text) }.getOrNull() ?: throw SystemServiceError.UNAVAILABLE.reject()
        val owned = LinkedHashMap<String, String>()
        for (key in root.keys()) owned[key] = root.opt(key) as? String ?: throw SystemServiceError.UNAVAILABLE.reject()
        if (owned.size > MAXIMUM || owned.any { it.key.isEmpty() || it.key.toByteArray().size > 2048 || it.value.toByteArray().size > 256 }) throw SystemServiceError.LIMIT_EXCEEDED.reject()
        return owned
    }

    fun save(owned: Map<String, String>): Boolean = file.write(JSONObject(owned).toString())

    companion object { const val MAXIMUM = 128 }
}

/**
 * `$calendar`: reads through the Calendar Provider inside the user's
 * selection, and `create`/`update` for events this installation created.
 * Permission prompts and source selection live in the app; nothing here shows UI.
 */
class CalendarModule(
    private val platform: CalendarPlatform,
    private val selections: CalendarSelectionStore,
    private val grants: SystemAccessGrants,
    private val prompts: PermissionPrompts,
    private val directory: java.io.File,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
    private val zone: () -> ZoneId = { ZoneId.systemDefault() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$calendar")

    override fun handles(operation: String): Boolean = operation.startsWith("calendar.")

    override fun call(request: ExecutionRequest, operation: String, payload: String?): String? {
        val context = CallContext.from(request)
        val value = when (operation) {
            "calendar.isAvailable" -> context.isInstalled.toString()
            "calendar.authorizationStatus" -> JSONObject.quote(authorizationStatus(context))
            else -> throw IllegalArgumentException("Unsupported operation $operation")
        }
        SystemLog.call(operation, "ok")
        return value
    }

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        val options = payload?.optJSONObject("options")
        val invalid = payload?.optString("invalid")?.takeIf { it.isNotEmpty() }
        when (operation) {
            "calendar.requestAuthorization" -> runSystemCall(operation, done) { requestAuthorization(context).toString() }
            "calendar.calendars" -> runSystemCall(operation, done) { calendars(context).toString() }
            "calendar.events" -> runSystemCall(operation, done) { events(context, options, invalid).toString() }
            "calendar.create" -> runSystemCall(operation, done) { mutate(context, options, updating = false).toString() }
            "calendar.update" -> runSystemCall(operation, done) { mutate(context, options, updating = true).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    private fun permitted(context: CallContext): Boolean = context.isInstalled && context.declares("calendar")

    /** `undeclared` without the package permission; otherwise `authorized`, `writeOnly`, `denied` or `notDetermined`. */
    fun authorizationStatus(context: CallContext): String = if (!permitted(context)) "undeclared" else systemStatus()

    /** Reading events needs `READ_CALENDAR`; holding only `WRITE_CALENDAR` is `writeOnly`. */
    fun systemStatus(): String = when {
        platform.canRead() -> "authorized"
        platform.canWrite() -> "writeOnly"
        prompts.asked(PROMPT) -> "denied"
        else -> "notDetermined"
    }

    /** Resolves to whether read access exists now. A widget never prompts; access is requested in the app. */
    fun requestAuthorization(context: CallContext): Boolean {
        if (!permitted(context)) { cache(context).delete(); throw SystemReject(INSTALL) }
        val authorized = systemStatus() == "authorized"
        if (!authorized) cache(context).delete()
        return authorized
    }

    /**
     * Gate shared by `calendars()` and `events()`, in the Apple runtime's order: package permission,
     * option errors, query budget, system authorization, then the native selection.
     */
    private fun admit(context: CallContext, invalid: String?, forEvents: Boolean): CalendarSelection {
        if (!permitted(context)) { cache(context).delete(); throw SystemReject(INSTALL) }
        if (invalid != null) throw SystemReject(invalid)
        if (!context.consumeDataQuery()) throw SystemReject("[query_limit] Too many system data queries")
        if (systemStatus() != "authorized") { cache(context).delete(); throw SystemReject("[permission_denied] Allow calendar access in ScriptWidget") }
        try {
            val selection = selections.load()
            if (forEvents && selection.calendarIDs?.isEmpty() == true) throw CalendarAccessError.NONE_SELECTED.reject()
            return selection
        } catch (error: SystemReject) { cache(context).delete(); throw error }
    }

    /** Authorization and selection are checked again immediately before a result is delivered. */
    private fun confirm(context: CallContext, selection: CalendarSelection) {
        if (!permitted(context) || systemStatus() != "authorized") { cache(context).delete(); throw SystemReject("[permission_denied] Calendar access was revoked") }
        if (runCatching { selections.load() }.getOrNull() != selection) { cache(context).delete(); throw CalendarAccessError.CHANGED.reject() }
    }

    /** Up to 64 `{id, title}` entries inside the native selection; empty when nothing is selected. */
    fun calendars(context: CallContext): JSONArray {
        val selection = admit(context, null, forEvents = false)
        if (context.isTimelineProjection) throw SystemReject("[timeline_read_only] No matching Calendar snapshot is available")
        val seen = HashSet<String>()
        val rows = try {
            platform.sources().filter { selection.allows(it.id) && CalendarIDs.valid(listOf(it.id)) && seen.add(it.id) }.take(CalendarIDs.MAXIMUM)
        } catch (error: Exception) { throw SystemReject(QUERY_FAILED) }
        confirm(context, selection)
        return JSONArray(rows.map { JSONObject().put("id", it.id).put("title", it.title.take(256)) })
    }

    /** `events(options)`; [invalidOptions] is a rejection the JavaScript bridge already produced for unbridgeable input. */
    fun events(context: CallContext, options: JSONObject?, invalidOptions: String? = null): JSONObject {
        var query: CalendarQuery? = null
        var invalid = invalidOptions
        if (invalid == null && permitted(context)) try { query = CalendarQuery.parse(options, clock.now(), zone()) } catch (error: SystemReject) { invalid = error.message }
        val selection = admit(context, invalid, forEvents = true)
        val parsed = query ?: throw SystemReject(QUERY_FAILED)
        val file = cache(context)
        val cached = synchronized(file.lock) { runCatching { file.read() }.getOrNull()?.let { CalendarResults.decodeCache(it, parsed, selection, clock.now()) } }
        if (context.isTimelineProjection) {
            if (cached == null || systemStatus() != "authorized" || runCatching { selections.load() }.getOrNull() != selection) throw SystemReject("[timeline_read_only] No matching Calendar snapshot is available")
            return cached
        }
        val payload = cached ?: run {
            val value = try {
                val sources = platform.sources().filter { CalendarIDs.valid(listOf(it.id)) }
                val ids = selection.permittedIDs(sources.map { it.id }, parsed.calendarIDs)
                val (events, truncated) = platform.events(parsed.start, parsed.end, ids)
                CalendarResults.build(parsed, ids, events, truncated, clock.now())
            } catch (error: SystemReject) { throw error } catch (error: Exception) { throw SystemReject(QUERY_FAILED) }
            if (context.isActive && systemStatus() == "authorized" && runCatching { selections.load() }.getOrNull() == selection) {
                val encoded = CalendarResults.encodeCache(parsed, selection, value, clock.now())
                if (encoded.toByteArray().size <= CalendarResults.MAXIMUM_CACHE_BYTES) synchronized(file.lock) { file.write(encoded) }
            }
            value
        }
        confirm(context, selection)
        return payload
    }

    /**
     * `create`/`update`. After the shared system gate (`calendarWrite`, an action, the native grant, the
     * query budget): strict options, the `calendar` permission with read and write access, a calendar
     * inside the selection that is writable, and for updates an event this installation created that
     * is not recurring. The system write runs at most once per `requestID` through the replay ledger.
     */
    fun mutate(context: CallContext, options: JSONObject?, updating: Boolean): JSONObject {
        SystemGate.check(context, "calendarWrite", writing = true, grants = grants)
        val request = CalendarMutation.parse(options ?: JSONObject(), updating)
        val access = {
            if (!context.declares("calendar") || !platform.canRead() || !platform.canWrite()) throw SystemServiceError.PERMISSION_DENIED.reject()
        }
        access()
        val selection = try { selections.load() } catch (error: SystemReject) { throw SystemReject(SystemServiceError.FAILED) }
        if (!selection.allows(request.calendarID)) throw SystemServiceError.PERMISSION_DENIED.reject()
        val calendar = runCatching { platform.sources() }.getOrNull()?.firstOrNull { it.id == request.calendarID }
        if (calendar == null || !calendar.writable) throw SystemServiceError.PERMISSION_DENIED.reject()
        val registry = OwnedEvents(PrivateFile(java.io.File(directory, ownerFileName(context.installation, ".owned.json")), 128 * 1024))
        val ledger = MutationLedger(PrivateFile(java.io.File(directory, ownerFileName(context.installation, ".receipts.json")), MutationLedger.MAXIMUM_BYTES), clock)
        return synchronized(registry.lock) {
            val owned = registry.load()
            val eventID = request.eventID
            if (eventID != null) {
                val existing = runCatching { platform.event(eventID) }.getOrNull()
                if (owned[eventID] != request.calendarID || existing == null || existing.calendarID != request.calendarID || existing.recurring) throw SystemServiceError.PERMISSION_DENIED.reject()
            } else if (owned.size >= OwnedEvents.MAXIMUM) throw SystemServiceError.LIMIT_EXCEEDED.reject()
            val receipt = try {
                ledger.perform(request.requestID, request.fingerprint, request.calendarID, validate = {
                    SystemGate.validate(context, "calendarWrite", writing = true, grants = grants)
                    access()
                    if (runCatching { selections.load() }.getOrNull() != selection) throw SystemServiceError.SCOPE_CHANGED.reject()
                }) { beforeCommit ->
                    beforeCommit()
                    if (eventID != null) {
                        if (!platform.update(eventID, request.title, request.start, request.end, request.allDay)) throw SystemServiceError.OUTCOME_UNKNOWN.reject()
                        eventID
                    } else platform.insert(request.calendarID, request.title, request.start, request.end, request.allDay) ?: throw SystemServiceError.OUTCOME_UNKNOWN.reject()
                }
            } catch (error: MutationLedger.LedgerException) { throw MutationLedger.error(error.failure).reject() }
            owned[receipt.id] = request.calendarID
            if (!registry.save(owned)) throw SystemServiceError.OUTCOME_UNKNOWN.reject()
            cache(context).delete()
            JSONObject().put("id", receipt.id).put("calendarID", request.calendarID).put("status", "applied").put("replayed", receipt.replayed)
        }
    }

    /** At most one 64 KiB event snapshot per installation. */
    private fun cache(context: CallContext): PrivateFile = PrivateFile(java.io.File(directory, ownerFileName(context.installation, ".events.json")), CalendarResults.MAXIMUM_CACHE_BYTES)

    companion object {
        const val PROMPT = "calendar"
        private const val INSTALL = "[permission_denied] Install this widget and declare calendar in widget.json"
        private const val QUERY_FAILED = "[query_failed] Calendar data could not be loaded"
    }
}

/** [CalendarPlatform] on the Calendar Provider with `READ_CALENDAR` / `WRITE_CALENDAR`. */
class AndroidCalendarPlatform(context: Context) : CalendarPlatform {
    private val appContext = context.applicationContext
    private val resolver get() = appContext.contentResolver

    override fun canRead(): Boolean = appContext.checkSelfPermission(Manifest.permission.READ_CALENDAR) == PackageManager.PERMISSION_GRANTED
    override fun canWrite(): Boolean = appContext.checkSelfPermission(Manifest.permission.WRITE_CALENDAR) == PackageManager.PERMISSION_GRANTED

    override fun sources(): List<CalendarSource> {
        val rows = ArrayList<CalendarSource>()
        val columns = arrayOf(CalendarContract.Calendars._ID, CalendarContract.Calendars.CALENDAR_DISPLAY_NAME, CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
        resolver.query(CalendarContract.Calendars.CONTENT_URI, columns, null, null, CalendarContract.Calendars._ID)?.use { cursor ->
            while (cursor.moveToNext() && rows.size < 256) {
                rows += CalendarSource(cursor.getLong(0).toString(), cursor.getString(1).orEmpty(), cursor.getInt(2) >= CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR)
            }
        }
        return rows
    }

    override fun events(start: Long, end: Long, calendarIDs: List<String>): Pair<List<CalendarEvent>, Boolean> {
        val ids = calendarIDs.mapNotNull { it.toLongOrNull() }
        if (ids.isEmpty()) return emptyList<CalendarEvent>() to false
        val zone = ZoneId.systemDefault()
        // All-day rows are UTC midnights: widen the provider window by a day and filter after conversion.
        val uri = CalendarContract.Instances.CONTENT_URI.buildUpon().also { ContentUris.appendId(it, start - DAY); ContentUris.appendId(it, end + DAY) }.build()
        val columns = arrayOf(CalendarContract.Instances.EVENT_ID, CalendarContract.Instances.CALENDAR_ID, CalendarContract.Instances.TITLE,
            CalendarContract.Instances.BEGIN, CalendarContract.Instances.END, CalendarContract.Instances.ALL_DAY)
        val selection = "${CalendarContract.Instances.CALENDAR_ID} IN (${ids.joinToString(",")})"
        val rows = ArrayList<CalendarEvent>()
        var truncated = false
        resolver.query(uri, columns, selection, null, "${CalendarContract.Instances.BEGIN} ASC, ${CalendarContract.Instances.EVENT_ID} ASC")?.use { cursor ->
            while (cursor.moveToNext()) {
                if (rows.size >= MAXIMUM_SCAN) { truncated = true; break }
                val allDay = cursor.getInt(5) != 0
                val begin = cursor.getLong(3).let { if (allDay) AllDayDates.utcToLocal(it, zone) else it }
                val finish = cursor.getLong(4).let { if (allDay) AllDayDates.utcToLocal(it, zone) else it }
                if (finish < start || begin >= end) continue
                rows += CalendarEvent(cursor.getLong(0).toString(), cursor.getLong(1).toString(), cursor.getString(2).orEmpty(), begin, finish, allDay)
            }
        }
        return rows to truncated
    }

    private fun values(title: String, start: Long, end: Long, allDay: Boolean): ContentValues {
        val zone = ZoneId.systemDefault()
        return ContentValues().apply {
            put(CalendarContract.Events.TITLE, title)
            put(CalendarContract.Events.DTSTART, if (allDay) AllDayDates.localToUtc(start, zone) else start)
            put(CalendarContract.Events.DTEND, if (allDay) AllDayDates.localToUtc(end, zone, roundUp = true) else end)
            put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
            put(CalendarContract.Events.EVENT_TIMEZONE, if (allDay) "UTC" else zone.id)
        }
    }

    override fun insert(calendarID: String, title: String, start: Long, end: Long, allDay: Boolean): String? {
        val calendar = calendarID.toLongOrNull() ?: return null
        val created = resolver.insert(CalendarContract.Events.CONTENT_URI, values(title, start, end, allDay).apply { put(CalendarContract.Events.CALENDAR_ID, calendar) })
        return created?.lastPathSegment?.toLongOrNull()?.toString()
    }

    override fun update(eventID: String, title: String, start: Long, end: Long, allDay: Boolean): Boolean {
        val id = eventID.toLongOrNull() ?: return false
        return resolver.update(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id), values(title, start, end, allDay), null, null) == 1
    }

    override fun event(eventID: String): CalendarEventInfo? {
        val id = eventID.toLongOrNull() ?: return null
        val columns = arrayOf(CalendarContract.Events.CALENDAR_ID, CalendarContract.Events.RRULE, CalendarContract.Events.RDATE, CalendarContract.Events.ORIGINAL_ID, CalendarContract.Events.DELETED)
        resolver.query(ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, id), columns, null, null, null)?.use { cursor ->
            if (!cursor.moveToFirst() || cursor.getInt(4) != 0) return null
            val recurring = !cursor.getString(1).isNullOrEmpty() || !cursor.getString(2).isNullOrEmpty() || !cursor.getString(3).isNullOrEmpty()
            return CalendarEventInfo(cursor.getLong(0).toString(), recurring)
        }
        return null
    }

    private companion object {
        const val DAY = 86_400_000L
        const val MAXIMUM_SCAN = 500
    }
}
