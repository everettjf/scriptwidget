package com.everettjf.scriptwidget.core.system

import com.everettjf.scriptwidget.core.api.RuntimePolicy
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.time.Instant
import java.time.OffsetDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService

/** A rejection whose [message] is delivered to the script verbatim. It never contains user data. */
class SystemReject(message: String) : Exception(message)

/**
 * Error codes shared by the Runtime 1.6 system services (`$notifications`,
 * calendar writes). The message is the same sentence the Apple runtime uses,
 * so scripts that match on the bracketed code behave the same on Android.
 */
enum class SystemServiceError(val code: String) {
    INVALID_OPTIONS("invalid_options"), PERMISSION_DENIED("permission_denied"), UNAVAILABLE("unavailable"),
    QUERY_LIMIT("query_limit"), READ_ONLY("read_only"), SCOPE_CHANGED("scope_changed"),
    LIMIT_EXCEEDED("limit_exceeded"), OUTCOME_UNKNOWN("outcome_unknown"), REQUEST_CONFLICT("request_conflict");

    val message: String get() = "[$code] System operation could not complete. Existing user data is preserved."
    fun reject(): SystemReject = SystemReject(message)

    companion object {
        /** Message for a failure that is not one of the known codes. */
        const val FAILED = "[system_failed] System operation failed; review the result before retrying a write."
    }
}

/** One INFO line per native call under the `ScriptWidget` tag. Callers pass operation names and error codes only, never user data. */
object SystemLog {
    const val TAG = "ScriptWidget"

    /** Replaceable so JVM tests can capture lines; the default writes to logcat. */
    @Volatile var sink: (String) -> Unit = { line -> runCatching { android.util.Log.i(TAG, line) } }

    fun call(operation: String, outcome: String) = sink("$operation -> $outcome")

    /** The bracketed code of a rejection message, or `error` when it has none. The free text is never logged. */
    fun code(message: String): String = Regex("^\\[([a-z_:A-Z]{1,40})]").find(message)?.groupValues?.get(1) ?: "error"
}

/** Wall clock, replaceable in tests. */
fun interface SystemClock { fun now(): Long }

/** Background threads for system queries, so the JavaScript thread never blocks on a provider or disk. */
object SystemExecutor {
    val pool: ScheduledExecutorService = Executors.newScheduledThreadPool(4) { runnable -> Thread(runnable, "scriptwidget-system").apply { isDaemon = true } }
}

/**
 * The facts about one execution that policy decisions need. Built from the
 * [ExecutionRequest] in production and directly in tests, so every rule can
 * be exercised on the JVM.
 */
class CallContext(
    /** Installation identity; namespaces grants, receipts and caches. */
    val installation: String,
    val hasManifest: Boolean,
    val permissions: Set<String>,
    val networkDomains: List<String>,
    val minimumRuntimeVersion: String?,
    val isAction: Boolean,
    val isTimelineProjection: Boolean,
    val isLiveActivity: Boolean,
    private val dataQuery: () -> Boolean = { true },
    private val networkRequest: () -> Boolean = { true },
    private val active: () -> Boolean = { true },
) {
    /** An installed owner is a canonical lowercase UUID; previews and unmanaged packages are not owners. */
    val isInstalled: Boolean get() = isOwner(installation)

    /** True while the execution is still running; results for a finished execution are dropped. */
    val isActive: Boolean get() = active()

    /** Takes one of the eight system-data queries of this execution. False when the budget is spent. */
    fun consumeDataQuery(): Boolean = dataQuery()

    /** Takes one of the 32 network requests of this execution. */
    fun consumeNetworkRequest(): Boolean = networkRequest()

    /** Package 2.0 permission check: a missing manifest never declares anything. */
    fun declares(permission: String): Boolean = hasManifest && permission in permissions

    /** `network` plus a matching `networkDomains` entry, the rule `fetch` applies. */
    fun allowsHost(host: String): Boolean = declares("network") && RuntimePolicy.hostMatches(host, networkDomains)

    companion object {
        const val MAXIMUM_DATA_QUERIES = 8
        const val MAXIMUM_NETWORK_REQUESTS = 32
        private val owner = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")

        fun isOwner(value: String): Boolean = owner.matches(value)

        fun from(request: ExecutionRequest): CallContext {
            val manifest = request.prepared.manifest
            fun strings(key: String): List<String> = manifest?.optJSONArray(key)?.let { array -> List(array.length()) { array.optString(it) } } ?: emptyList()
            return CallContext(
                installation = request.packageID,
                // A present manifest that could not be read still counts as present: it declares nothing and is never treated as legacy.
                hasManifest = request.prepared.hasManifest,
                permissions = strings("permissions").toSet(),
                networkDomains = strings("networkDomains"),
                minimumRuntimeVersion = manifest?.optString("minimumRuntimeVersion")?.takeIf { it.isNotEmpty() },
                isAction = RuntimePolicy.isAction(request),
                isTimelineProjection = RuntimePolicy.isTimelineProjection(request),
                isLiveActivity = RuntimePolicy.isLiveActivity(request),
                dataQuery = { request.session.dataQueries.incrementAndGet() <= MAXIMUM_DATA_QUERIES },
                networkRequest = { request.session.networkRequests.incrementAndGet() <= MAXIMUM_NETWORK_REQUESTS },
                active = { !request.session.finished },
            )
        }
    }
}

/** ISO-8601 instants in the forms the Apple runtime accepts and produces. */
object IsoDates {
    private val pattern = Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:\\.\\d{1,9})?(?:Z|[+-]\\d{2}:\\d{2})$")
    private val fractional = DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'").withZone(ZoneOffset.UTC)

    /** Epoch milliseconds of a full date-time with a time zone, or null. Dates without a zone or with impossible fields are rejected. */
    fun parse(text: String): Long? {
        if (text.toByteArray().size > 64 || !pattern.matches(text)) return null
        return runCatching { OffsetDateTime.parse(text).toInstant().toEpochMilli() }.getOrNull()
    }

    /** `2026-11-01T12:00:00Z`: whole seconds, UTC. */
    fun format(milliseconds: Long): String = Instant.ofEpochSecond(Math.floorDiv(milliseconds, 1000L)).toString()

    /** `2026-11-01T12:00:00.000Z`: the form `$location` uses for `timestamp`. */
    fun formatFractional(milliseconds: Long): String = fractional.format(Instant.ofEpochMilli(milliseconds))
}

/** Strict, bounded option parsing shared by the system services. Every failure is `invalid_options`. */
object SystemOptions {
    private val key = Regex("^[a-zA-Z0-9_-]{1,64}$")
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    const val MAXIMUM_OPTION_BYTES = 16384

    private fun invalid(): SystemReject = SystemServiceError.INVALID_OPTIONS.reject()

    /** Keys match `[a-zA-Z0-9_-]{1,64}`. */
    fun validKey(value: String): Boolean = key.matches(value)

    /** Request identifiers are canonical lowercase UUIDs. */
    fun validRequestID(value: String): Boolean = uuid.matches(value)

    /** Rejects unknown fields and option objects above 16 KiB. */
    fun fields(options: JSONObject, allowed: Set<String>) {
        if (options.keys().asSequence().any { it !in allowed } || options.toString().toByteArray().size > MAXIMUM_OPTION_BYTES) throw invalid()
    }

    /** A string that is not blank, has no control or format characters and fits [maximum] UTF-8 bytes. */
    fun text(value: Any?, maximum: Int = 256): String {
        val text = value as? String ?: throw invalid()
        if (text.isBlank() || text.toByteArray().size > maximum || hasControlCharacters(text)) throw invalid()
        return text
    }

    fun hasControlCharacters(text: String): Boolean = text.codePoints().anyMatch {
        val type = Character.getType(it)
        type == Character.CONTROL.toInt() || type == Character.FORMAT.toInt()
    }

    /** A finite JSON number inside [range]; Booleans are not numbers. */
    fun number(value: Any?, range: ClosedFloatingPointRange<Double>): Double {
        if (value !is Number) throw invalid()
        val number = value.toDouble()
        if (!number.isFinite() || number !in range) throw invalid()
        return number
    }

    fun integer(value: Any?, range: IntRange): Int {
        val number = number(value, range.first.toDouble()..range.last.toDouble())
        if (Math.rint(number) != number) throw invalid()
        return number.toInt()
    }

    /** A full ISO-8601 date-time with a zone, as epoch milliseconds. */
    fun date(value: Any?): Long = IsoDates.parse(text(value, 64)) ?: throw invalid()

    fun boolean(value: Any?): Boolean = value as? Boolean ?: throw invalid()

    /** A present, non-null member of [options], or null. */
    fun member(options: JSONObject, name: String): Any? = if (options.has(name) && !options.isNull(name)) options.get(name) else null
}

/** Deterministic JSON and digests for fingerprints and cache identities. */
object Canonical {
    /** JSON with object keys sorted, so equal values always encode to equal bytes. */
    fun encode(value: Any?): String = when (value) {
        null, JSONObject.NULL -> "null"
        is JSONObject -> value.keys().asSequence().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + encode(value.opt(it)) }
        is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { encode(value.opt(it)) }
        is Map<*, *> -> value.keys.map { it.toString() }.sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + encode(value[it]) }
        is Collection<*> -> value.joinToString(",", "[", "]") { encode(it) }
        is String -> JSONObject.quote(value)
        is Boolean -> value.toString()
        is Number -> if (value.toDouble() == Math.rint(value.toDouble()) && Math.abs(value.toDouble()) < 9.007199254740992E15) value.toLong().toString() else value.toDouble().toString()
        else -> JSONObject.quote(value.toString())
    }

    fun sha256(text: String): String = MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }

    /** Fingerprint of a mutation: the operation name and every option, so a reused requestID with other arguments is detected. */
    fun fingerprint(operation: String, options: JSONObject): String = sha256(encode(mapOf("operation" to operation, "options" to options)))
}

/**
 * A small private JSON file. Reads are bounded and refuse links and
 * non-regular files; writes replace the file atomically. A present file that
 * cannot be read is reported as [Unreadable] so callers fail closed instead
 * of treating it as missing.
 */
class PrivateFile(val file: File, private val maximumBytes: Int) {
    class Unreadable : Exception("private file is unreadable")

    /** Lock shared by every reader and writer of this path in the process. */
    val lock: Any get() = locks.getOrPut(file.absolutePath) { Any() }

    fun exists(): Boolean = Files.exists(file.toPath(), LinkOption.NOFOLLOW_LINKS)

    /** File text, or null when the file does not exist. */
    fun read(): String? {
        val path = file.toPath()
        if (!Files.exists(path, LinkOption.NOFOLLOW_LINKS)) return null
        if (!Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) || file.length() > maximumBytes) throw Unreadable()
        return try { file.readBytes().takeIf { it.size <= maximumBytes }?.toString(Charsets.UTF_8) ?: throw Unreadable() } catch (error: java.io.IOException) { throw Unreadable() }
    }

    /** Writes [text] through a temporary file and an atomic rename. False when it exceeds the bound or the disk refuses it. */
    fun write(text: String): Boolean {
        val bytes = text.toByteArray()
        if (bytes.size > maximumBytes) return false
        return runCatching {
            file.parentFile?.mkdirs()
            val temporary = File(file.parentFile, file.name + ".tmp")
            temporary.writeBytes(bytes)
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
            true
        }.getOrDefault(false)
    }

    fun delete() { runCatching { Files.deleteIfExists(file.toPath()) } }

    companion object { private val locks = ConcurrentHashMap<String, Any>() }
}

/** File names for per-installation records: a digest, so an identity can never become a path. */
fun ownerFileName(installation: String, suffix: String): String = Canonical.sha256(installation).take(40) + suffix

/**
 * Per-installation native grants for the system services, the Android
 * counterpart of the System Access sheet. A grant is local to the device,
 * bound to the installation identity and never part of an exported package.
 * A malformed grant file denies everything.
 */
class SystemAccessGrants(private val file: PrivateFile) {
    /** Capabilities that need an explicit per-widget grant on Android. */
    companion object { val CAPABILITIES = setOf("notifications", "calendarWrite") }

    /** @throws SystemReject `unavailable` when the grant file is present but invalid. */
    fun granted(installation: String, capability: String): Boolean = synchronized(file.lock) { capability in load()[installation].orEmpty() }

    fun capabilities(installation: String): Set<String> = synchronized(file.lock) { runCatching { load()[installation].orEmpty() }.getOrDefault(emptySet()) }

    /** Grants or revokes one capability. A corrupt file is replaced: this is an explicit user action in the app. */
    fun set(installation: String, capability: String, granted: Boolean): Boolean {
        if (!CallContext.isOwner(installation) || capability !in CAPABILITIES) return false
        return synchronized(file.lock) { store(installation, capability, granted) }
    }

    private fun store(installation: String, capability: String, granted: Boolean): Boolean {
        val all = runCatching { load() }.getOrDefault(emptyMap()).toMutableMap()
        val next = all[installation].orEmpty().toMutableSet().apply { if (granted) add(capability) else remove(capability) }
        if (next.isEmpty()) all.remove(installation) else all[installation] = next
        val grants = JSONObject()
        for ((owner, capabilities) in all.toSortedMap()) grants.put(owner, JSONArray(capabilities.sorted()))
        return file.write(JSONObject().put("formatVersion", 1).put("grants", grants).toString())
    }

    private fun load(): Map<String, Set<String>> {
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw SystemServiceError.UNAVAILABLE.reject() } ?: return emptyMap()
        return try {
            val root = JSONObject(text)
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "grants") || root.get("formatVersion") != 1) throw SystemServiceError.UNAVAILABLE.reject()
            val grants = root.getJSONObject("grants")
            if (grants.length() > 512) throw SystemServiceError.UNAVAILABLE.reject()
            grants.keys().asSequence().associateWith { owner ->
                val array = grants.getJSONArray(owner)
                val values = List(array.length()) { array.get(it) as? String ?: throw SystemServiceError.UNAVAILABLE.reject() }
                if (!CallContext.isOwner(owner) || values.toSet().size != values.size || !CAPABILITIES.containsAll(values)) throw SystemServiceError.UNAVAILABLE.reject()
                values.toSet()
            }
        } catch (error: org.json.JSONException) { throw SystemServiceError.UNAVAILABLE.reject() }
    }
}

/**
 * The shared gate of the Runtime 1.6 system services. The order is the Apple
 * runtime's and decides which code a script sees:
 * 1. `permission_denied`: not an installed owner, no manifest, the permission
 *    is not declared, or `minimumRuntimeVersion` is below 1.6;
 * 2. `read_only`: a future timeline entry, a Live Activity presentation, or
 *    a write outside a user-initiated action;
 * 3. `permission_denied`: the installation has no native grant;
 * 4. `query_limit`: the eight-query budget of the execution is spent.
 */
object SystemGate {
    fun check(context: CallContext, permission: String, writing: Boolean, grants: SystemAccessGrants?) {
        validate(context, permission, writing, grants)
        if (!context.consumeDataQuery()) throw SystemServiceError.QUERY_LIMIT.reject()
    }

    /** Steps 1 to 3 only; repeated before a result is delivered so a revoked grant stops an in-flight call. */
    fun validate(context: CallContext, permission: String, writing: Boolean, grants: SystemAccessGrants?) {
        if (!context.isInstalled || !context.declares(permission) || !supportsRuntime("1.6", context.minimumRuntimeVersion)) throw SystemServiceError.PERMISSION_DENIED.reject()
        if (context.isTimelineProjection || context.isLiveActivity || (writing && !context.isAction)) throw SystemServiceError.READ_ONLY.reject()
        if (grants != null && !grants.granted(context.installation, permission)) throw SystemServiceError.PERMISSION_DENIED.reject()
    }

    /** True when [declared] (`major.minor`) is at least [required]. A missing or malformed version is 0.0. */
    fun supportsRuntime(required: String, declared: String?): Boolean {
        fun parts(text: String?): Pair<Int, Int>? = Regex("^(\\d{1,4})\\.(\\d{1,4})$").find(text.orEmpty())?.let { it.groupValues[1].toInt() to it.groupValues[2].toInt() }
        val need = parts(required) ?: return false
        val have = parts(declared) ?: (0 to 0)
        return have.first > need.first || (have.first == need.first && have.second >= need.second)
    }
}

/**
 * Durable replay receipts for writes to system data. A request identifier is
 * recorded as `prepared` before the system write and `completed` after it:
 * - the same identifier and fingerprint replays the confirmed result;
 * - the same identifier with other arguments is a conflict;
 * - a `prepared` receipt means the outcome is unknown and is never retried;
 * - at most 128 receipts and 64 KiB; completed receipts expire after seven days.
 */
class MutationLedger(private val file: PrivateFile, private val clock: SystemClock) {
    enum class Failure { CORRUPT, CONFLICT, UNCERTAIN, FULL }
    class LedgerException(val failure: Failure) : Exception(failure.name)
    class Receipt(val id: String, val listID: String, val replayed: Boolean)
    private class Entry(val requestID: String, val fingerprint: String, val listID: String, val createdAt: Double, var state: String, var id: String?)

    /**
     * Runs [write] at most once for [requestID]. [write] must call the
     * function it receives immediately before committing to the system; that
     * call stores the `prepared` receipt and re-runs [validate].
     */
    fun perform(requestID: String, fingerprint: String, listID: String, validate: () -> Unit, write: (beforeCommit: () -> Unit) -> String): Receipt =
        synchronized(file.lock) { locked(requestID, fingerprint, listID, validate, write) }

    private fun locked(requestID: String, fingerprint: String, listID: String, validate: () -> Unit, write: (beforeCommit: () -> Unit) -> String): Receipt {
        validate()
        val entries = load()
        val now = clock.now() / 1000.0
        entries.removeAll { it.state == "completed" && now - it.createdAt > RETENTION_SECONDS }
        entries.firstOrNull { it.requestID == requestID }?.let { prior ->
            if (prior.fingerprint != fingerprint || prior.listID != listID) throw LedgerException(Failure.CONFLICT)
            val id = prior.id
            if (prior.state != "completed" || id == null) throw LedgerException(Failure.UNCERTAIN)
            return Receipt(id, prior.listID, true)
        }
        if (entries.size >= MAXIMUM_ENTRIES) throw LedgerException(Failure.FULL)
        var began = false
        val id: String
        try {
            id = write {
                if (began) throw LedgerException(Failure.UNCERTAIN)
                validate()
                entries += Entry(requestID, fingerprint, listID, now, "prepared", null)
                // Reserve room for the largest identifier so a successful write can always record its receipt.
                val reserved = encode(entries, reserveLast = true)
                if (reserved.toByteArray().size > MAXIMUM_BYTES) throw LedgerException(Failure.FULL)
                if (!file.write(encode(entries, reserveLast = false))) throw LedgerException(Failure.UNCERTAIN)
                began = true
            }
        } catch (error: Exception) {
            if (began) throw LedgerException(Failure.UNCERTAIN)
            throw error
        }
        if (!began || !validID(id)) throw LedgerException(Failure.UNCERTAIN)
        entries.last().apply { state = "completed"; this.id = id }
        if (!file.write(encode(entries, reserveLast = false))) throw LedgerException(Failure.UNCERTAIN)
        return Receipt(id, listID, false)
    }

    private fun load(): MutableList<Entry> {
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw LedgerException(Failure.CORRUPT) } ?: return ArrayList()
        try {
            val root = JSONObject(text)
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "entries") || root.get("formatVersion") != 1) throw LedgerException(Failure.CORRUPT)
            val array = root.getJSONArray("entries")
            if (array.length() > MAXIMUM_ENTRIES) throw LedgerException(Failure.CORRUPT)
            val entries = ArrayList<Entry>()
            for (index in 0 until array.length()) {
                val item = array.getJSONObject(index)
                val state = item.getString("state")
                val id = if (item.has("id")) item.get("id") as? String ?: throw LedgerException(Failure.CORRUPT) else null
                val entry = Entry(item.getString("requestID"), item.getString("fingerprint"), item.getString("listID"), item.getDouble("createdAt"), state, id)
                val known = setOf("requestID", "fingerprint", "listID", "createdAt", "state", "id")
                if (item.keys().asSequence().any { it !in known } || !SystemOptions.validRequestID(entry.requestID) || !Regex("^[0-9a-f]{64}$").matches(entry.fingerprint) ||
                    entry.listID.isEmpty() || entry.listID.toByteArray().size > 256 || !entry.createdAt.isFinite() || entry.createdAt < 0 ||
                    state !in setOf("prepared", "completed") || (if (state == "prepared") id != null else !validID(id))) throw LedgerException(Failure.CORRUPT)
                entries += entry
            }
            if (entries.map { it.requestID }.toSet().size != entries.size) throw LedgerException(Failure.CORRUPT)
            return entries
        } catch (error: org.json.JSONException) { throw LedgerException(Failure.CORRUPT) }
    }

    private fun encode(entries: List<Entry>, reserveLast: Boolean): String {
        val array = JSONArray()
        entries.forEachIndexed { index, entry ->
            val reserve = reserveLast && index == entries.lastIndex
            val item = JSONObject().put("requestID", entry.requestID).put("fingerprint", entry.fingerprint).put("listID", entry.listID)
                .put("createdAt", entry.createdAt).put("state", if (reserve) "completed" else entry.state)
            (if (reserve) "x".repeat(MAXIMUM_ID_BYTES) else entry.id)?.let { item.put("id", it) }
            array.put(item)
        }
        return JSONObject().put("formatVersion", 1).put("entries", array).toString()
    }

    companion object {
        const val MAXIMUM_ENTRIES = 128
        const val MAXIMUM_BYTES = 64 * 1024
        const val MAXIMUM_ID_BYTES = 2048
        const val RETENTION_SECONDS = 7 * 86_400.0

        fun validID(id: String?): Boolean = id != null && id.isNotEmpty() && id.toByteArray().size <= MAXIMUM_ID_BYTES

        /** The script-visible error for a ledger failure, as the Apple runtime maps it. */
        fun error(failure: Failure): SystemServiceError = when (failure) {
            Failure.UNCERTAIN -> SystemServiceError.OUTCOME_UNKNOWN
            Failure.CONFLICT -> SystemServiceError.REQUEST_CONFLICT
            Failure.FULL -> SystemServiceError.LIMIT_EXCEEDED
            Failure.CORRUPT -> SystemServiceError.UNAVAILABLE
        }
    }
}

/** Remembers that the app asked for a runtime permission, which separates `notDetermined` from `denied` on Android. */
class PermissionPrompts(private val file: PrivateFile) {
    fun asked(name: String): Boolean = synchronized(file.lock) { load().optBoolean(name, false) }

    fun markAsked(name: String) { synchronized(file.lock) { file.write(load().put(name, true).toString()) } }

    private fun load(): JSONObject = runCatching { file.read()?.let { JSONObject(it) } }.getOrNull() ?: JSONObject()
}

/** Runs [block] off the JavaScript thread, logs one line, and completes [done] exactly once with JSON or a rejection message. */
internal fun runSystemCall(operation: String, done: (ok: Boolean, json: String?) -> Unit, block: () -> String) {
    fun finish(ok: Boolean, value: String) {
        SystemLog.call(operation, if (ok) "ok" else SystemLog.code(value))
        done(ok, if (ok) value else JSONObject.quote(value))
    }
    try {
        SystemExecutor.pool.execute {
            try { finish(true, block()) }
            catch (error: SystemReject) { finish(false, error.message ?: SystemServiceError.FAILED) }
            catch (error: Exception) { finish(false, SystemServiceError.FAILED) }
        }
    } catch (error: java.util.concurrent.RejectedExecutionException) { finish(false, SystemServiceError.UNAVAILABLE.message) }
}
