package com.everettjf.scriptwidget.core.system

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import com.everettjf.scriptwidget.core.R
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * One alarm or timer of one installation.
 *
 * [state] is `scheduled` (a fixed date), `countdown` (a running timer), `paused` (a timer with
 * [remaining] milliseconds left) or `stopped`. [fireAt] is set while the alarm is armed.
 */
class AlarmRecord(val owner: String, val key: String, val title: String, val state: String, val timer: Boolean, val fireAt: Long?, val remaining: Long?) {
    /** Armed with the system: it will fire at [fireAt]. */
    val armed: Boolean get() = state == AlarmRules.SCHEDULED || state == AlarmRules.COUNTDOWN

    fun with(state: String, fireAt: Long?, remaining: Long?): AlarmRecord = AlarmRecord(owner, key, title, state, timer, fireAt, remaining)

    fun toJson(): JSONObject = JSONObject().put("owner", owner).put("key", key).put("title", title).put("state", state).put("timer", timer)
        .put("fireAt", fireAt ?: JSONObject.NULL).put("remaining", remaining ?: JSONObject.NULL)
}

/** A validated `schedule` request: exactly one of [date] (epoch milliseconds) or [seconds]. */
class AlarmRequest(val requestID: String, val key: String, val title: String, val date: Long?, val seconds: Double?, val fingerprint: String)

/** Limits and pure rules of `$alarms`. */
object AlarmRules {
    const val SCHEDULED = "scheduled"
    const val COUNTDOWN = "countdown"
    const val PAUSED = "paused"
    const val STOPPED = "stopped"
    val STATES = setOf(SCHEDULED, COUNTDOWN, PAUSED, STOPPED)

    /** Named keys tracked per installation. */
    const val MAXIMUM_PER_OWNER = 32
    const val MAXIMUM_DATE_WINDOW_MILLISECONDS = 366L * 86_400_000L
    /** Ledger scope of every alarm receipt. */
    const val SCOPE = "alarms"
    private val fields = setOf("requestID", "key", "title", "date", "seconds")

    /**
     * `schedule(options)` input, in the Apple runtime's order: closed fields; key
     * `[a-zA-Z0-9_-]{1,64}`; exactly one of `date` and `seconds`; title nonempty, without control
     * characters, at most 128 UTF-8 bytes; `date` a future ISO date-time at most 366 days away;
     * `seconds` 60…86400; `requestID` a canonical lowercase UUID. Every violation is `invalid_options`.
     */
    fun parse(options: JSONObject, nowMilliseconds: Long): AlarmRequest {
        val invalid = { SystemServiceError.INVALID_OPTIONS.reject() }
        val key = SystemOptions.text(SystemOptions.member(options, "key"), 64)
        if (!SystemOptions.validKey(key)) throw invalid()
        SystemOptions.fields(options, fields)
        if (options.has("date") == options.has("seconds")) throw invalid()
        val title = SystemOptions.text(SystemOptions.member(options, "title"), 128)
        val date = if (options.has("date")) SystemOptions.date(options.opt("date")) else null
        val seconds = if (options.has("seconds")) SystemOptions.number(options.opt("seconds"), 60.0..86_400.0) else null
        if (date != null && (date <= nowMilliseconds || date - nowMilliseconds > MAXIMUM_DATE_WINDOW_MILLISECONDS)) throw invalid()
        val requestID = SystemOptions.text(SystemOptions.member(options, "requestID"), 36)
        if (!SystemOptions.validRequestID(requestID)) throw invalid()
        return AlarmRequest(requestID, key, title, date, seconds, Canonical.fingerprint("schedule", options))
    }

    /**
     * The native identifier of an alarm: a UUID derived from the installation and the key, so a
     * script can never name another installation's alarm.
     */
    fun id(owner: String, key: String): String {
        if (!SystemOptions.validKey(key) || !CallContext.isOwner(owner)) throw SystemServiceError.INVALID_OPTIONS.reject()
        val hex = Canonical.sha256("$owner:alarm:$key")
        return "${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20, 32)}"
    }

    /** The record a new request starts as: `countdown` for `seconds`, `scheduled` for `date`. */
    fun start(owner: String, request: AlarmRequest, nowMilliseconds: Long): AlarmRecord {
        val seconds = request.seconds
        return if (seconds != null) AlarmRecord(owner, request.key, request.title, COUNTDOWN, true, nowMilliseconds + Math.round(seconds * 1000), null)
        else AlarmRecord(owner, request.key, request.title, SCHEDULED, false, request.date, null)
    }

    /**
     * The state machine of `pause`, `resume` and `stop`. Returns the next record, or null when
     * the system state does not allow the transition (`unavailable`):
     * - `pause`: only a running countdown; the time left is kept.
     * - `resume`: only a paused countdown; it fires after the time that was left.
     * - `stop`: any alarm that is not already stopped; it will not fire.
     */
    fun transition(record: AlarmRecord, method: String, nowMilliseconds: Long): AlarmRecord? = when (method) {
        "pause" -> if (record.state == COUNTDOWN && record.timer && record.fireAt != null) record.with(PAUSED, null, maxOf(1_000L, record.fireAt - nowMilliseconds)) else null
        "resume" -> if (record.state == PAUSED && record.remaining != null) record.with(COUNTDOWN, nowMilliseconds + record.remaining, null) else null
        "stop" -> if (record.state != STOPPED) record.with(STOPPED, null, null) else null
        else -> null
    }
}

/** Durable alarm records; the source of truth for `pending()` and for re-arming after a reboot. */
class AlarmStore(private val file: PrivateFile) {
    val lock: Any get() = file.lock

    /** Every record. An unreadable or malformed file is `unavailable`, never an empty list. */
    fun all(): List<AlarmRecord> = synchronized(file.lock) {
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw SystemServiceError.UNAVAILABLE.reject() } ?: return@synchronized emptyList()
        try {
            val root = JSONObject(text)
            if (root.keys().asSequence().toSet() != setOf("formatVersion", "alarms") || root.get("formatVersion") != 1) throw SystemServiceError.UNAVAILABLE.reject()
            val array = root.getJSONArray("alarms")
            val records = List(array.length()) { index ->
                val item = array.getJSONObject(index)
                val record = AlarmRecord(item.getString("owner"), item.getString("key"), item.getString("title"), item.getString("state"), item.getBoolean("timer"),
                    if (item.isNull("fireAt")) null else item.getLong("fireAt"), if (item.isNull("remaining")) null else item.getLong("remaining"))
                val consistent = when (record.state) {
                    AlarmRules.SCHEDULED -> !record.timer && record.fireAt != null && record.remaining == null
                    AlarmRules.COUNTDOWN -> record.timer && record.fireAt != null && record.remaining == null
                    AlarmRules.PAUSED -> record.timer && record.fireAt == null && record.remaining != null && record.remaining > 0
                    AlarmRules.STOPPED -> record.fireAt == null && record.remaining == null
                    else -> false
                }
                if (!CallContext.isOwner(record.owner) || !SystemOptions.validKey(record.key) || !consistent) throw SystemServiceError.UNAVAILABLE.reject()
                record
            }
            val perOwner = records.groupingBy { it.owner }.eachCount()
            if (records.map { it.owner to it.key }.toSet().size != records.size || perOwner.values.any { it > AlarmRules.MAXIMUM_PER_OWNER }) throw SystemServiceError.UNAVAILABLE.reject()
            records
        } catch (error: org.json.JSONException) { throw SystemServiceError.UNAVAILABLE.reject() }
    }

    fun save(records: List<AlarmRecord>): Boolean = synchronized(file.lock) {
        file.write(JSONObject().put("formatVersion", 1).put("alarms", JSONArray(records.map { it.toJson() })).toString())
    }
}

/** The system side of alarms and timers. */
interface AlarmPlatform {
    /** The user allowed this app to post notifications, which is how an alarm is presented on Android. */
    fun enabled(): Boolean
    /** Arms an inexact alarm for [record] around [triggerAtMilliseconds]; replaces an alarm of the same owner and key. */
    fun arm(record: AlarmRecord, triggerAtMilliseconds: Long)
    /** Disarms the alarm and removes its posted notification, if any. */
    fun disarm(owner: String, key: String)
}

/**
 * `$alarms`: `status`, `pending`, `schedule`, `cancel`, `stop`, `pause`, `resume`.
 *
 * Android has no AlarmKit. An alarm is this app's own record, armed with an inexact
 * `AlarmManager` window and presented as a notification when it fires; there is no system alarm
 * screen, snooze or countdown Live Activity. Records are keyed per installation, so a widget can
 * only see and control its own alarms.
 */
class AlarmsModule(
    private val platform: AlarmPlatform,
    private val store: AlarmStore,
    private val grants: SystemAccessGrants,
    private val prompts: PermissionPrompts,
    private val directory: File,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$alarms")

    override fun handles(operation: String): Boolean = operation.startsWith("alarms.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "alarms.status" -> runSystemCall(operation, done) { status(context).toString() }
            "alarms.pending" -> runSystemCall(operation, done) { pending(context).toString() }
            "alarms.schedule" -> runSystemCall(operation, done) { schedule(context, payload?.optJSONObject("options")).toString() }
            "alarms.cancel", "alarms.stop", "alarms.pause", "alarms.resume" -> runSystemCall(operation, done) { control(context, operation.removePrefix("alarms."), payload?.opt("key")).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** `authorized`, `denied`, or `notDetermined` when the app has not asked for notifications yet. */
    fun authorization(): String = if (platform.enabled()) "authorized" else if (prompts.asked(NotificationsModule.PROMPT)) "denied" else "notDetermined"

    fun status(context: CallContext): JSONObject {
        SystemGate.check(context, PERMISSION, writing = false, grants = grants)
        return JSONObject().put("authorization", authorization())
    }

    /** This installation's alarms as `{key, state}`. Requires notification authorization (`permission_denied`). */
    fun pending(context: CallContext): JSONArray {
        SystemGate.check(context, PERMISSION, writing = false, grants = grants)
        if (!platform.enabled()) throw SystemServiceError.PERMISSION_DENIED.reject()
        val rows = store.all().filter { it.owner == context.installation }.sortedBy { it.key }
        SystemGate.validate(context, PERMISSION, writing = false, grants = grants)
        return JSONArray(rows.map { JSONObject().put("key", it.key).put("state", it.state) })
    }

    /**
     * After the system gate (an action, the native grant, the query budget): notification
     * authorization (`permission_denied`), strict options, then the replay ledger. Inside the
     * ledger: at most 32 keys (`limit_exceeded`), and an alarm that is scheduled, counting down or
     * paused is never replaced (`request_conflict`); a stopped one is. A repeated `requestID` with
     * the same options returns the confirmed result with `replayed: true`.
     */
    fun schedule(context: CallContext, options: JSONObject?): JSONObject {
        SystemGate.check(context, PERMISSION, writing = true, grants = grants)
        if (!platform.enabled()) throw SystemServiceError.PERMISSION_DENIED.reject()
        val request = AlarmRules.parse(options ?: JSONObject(), clock.now())
        val id = AlarmRules.id(context.installation, request.key)
        val ledger = MutationLedger(PrivateFile(File(directory, ownerFileName(context.installation, ".receipts.json")), MutationLedger.MAXIMUM_BYTES), clock)
        val receipt = try {
            ledger.perform(request.requestID, request.fingerprint, AlarmRules.SCOPE, validate = {
                SystemGate.validate(context, PERMISSION, writing = true, grants = grants)
                if (!platform.enabled()) throw SystemServiceError.PERMISSION_DENIED.reject()
            }) { beforeCommit ->
                synchronized(store.lock) {
                    val all = store.all()
                    val mine = all.filter { it.owner == context.installation }
                    val existing = mine.firstOrNull { it.key == request.key }
                    if (existing == null && mine.size >= AlarmRules.MAXIMUM_PER_OWNER) throw SystemServiceError.LIMIT_EXCEEDED.reject()
                    if (existing != null && existing.state != AlarmRules.STOPPED) throw SystemServiceError.REQUEST_CONFLICT.reject()
                    beforeCommit()
                    val now = clock.now()
                    val record = AlarmRules.start(context.installation, request, now)
                    // Arm first: an armed alarm without a record does nothing when it fires, while a record without an alarm would never fire.
                    try { platform.arm(record, record.fireAt ?: now) } catch (error: Exception) { throw SystemServiceError.OUTCOME_UNKNOWN.reject() }
                    if (!store.save(all.filterNot { it.owner == record.owner && it.key == record.key } + record)) {
                        runCatching { platform.disarm(record.owner, record.key) }
                        throw SystemServiceError.OUTCOME_UNKNOWN.reject()
                    }
                    id
                }
            }
        } catch (error: MutationLedger.LedgerException) { throw MutationLedger.error(error.failure).reject() }
        return JSONObject().put("key", request.key).put("status", "scheduled").put("replayed", receipt.replayed)
    }

    /**
     * `cancel`, `stop`, `pause`, `resume`. After the system gate and notification authorization:
     * the key must be valid (`invalid_options`) and name one of this installation's alarms
     * (`unavailable`); `cancel` removes it; the others follow [AlarmRules.transition] and are
     * `unavailable` when the current state does not allow them.
     */
    fun control(context: CallContext, method: String, rawKey: Any?): JSONObject {
        SystemGate.check(context, PERMISSION, writing = true, grants = grants)
        if (!platform.enabled()) throw SystemServiceError.PERMISSION_DENIED.reject()
        val key = SystemOptions.text(rawKey, 64)
        if (!SystemOptions.validKey(key)) throw SystemServiceError.INVALID_OPTIONS.reject()
        synchronized(store.lock) {
            val all = store.all()
            val record = all.firstOrNull { it.owner == context.installation && it.key == key } ?: throw SystemServiceError.UNAVAILABLE.reject()
            val others = all.filterNot { it.owner == record.owner && it.key == record.key }
            val now = clock.now()
            val next = if (method == "cancel") null else AlarmRules.transition(record, method, now) ?: throw SystemServiceError.UNAVAILABLE.reject()
            SystemGate.validate(context, PERMISSION, writing = true, grants = grants)
            if (!store.save(if (next == null) others else others + next)) throw SystemServiceError.UNAVAILABLE.reject()
            runCatching { if (next != null && next.armed) platform.arm(next, next.fireAt ?: now) else platform.disarm(record.owner, record.key) }
        }
        return JSONObject().put("key", key).put("status", "requested")
    }

    /** Cancels every alarm of a deleted installation and drops its receipts. Called by the app when a package is removed. */
    fun retire(installation: String) {
        var count = 0
        runCatching {
            synchronized(store.lock) {
                val all = store.all()
                val mine = all.filter { it.owner == installation }
                count = mine.size
                if (mine.isNotEmpty()) store.save(all - mine.toSet())
                for (record in mine) runCatching { platform.disarm(record.owner, record.key) }
            }
        }
        if (CallContext.isOwner(installation)) PrivateFile(File(directory, ownerFileName(installation, ".receipts.json")), MutationLedger.MAXIMUM_BYTES).delete()
        SystemLog.call("alarms.retire", "ok count=$count")
    }

    companion object {
        const val PERMISSION = "alarms"
    }
}

/**
 * Inexact alarms (`setWindow`, no exact-alarm permission) that broadcast to the app's receiver,
 * which calls [AlarmDelivery]. A fired alarm is one notification on its own high-importance channel.
 */
class AndroidAlarmPlatform(context: Context, private val receiver: Class<*>) : AlarmPlatform {
    private val appContext = context.applicationContext

    override fun enabled(): Boolean = appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED &&
        appContext.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() == true

    override fun arm(record: AlarmRecord, triggerAtMilliseconds: Long) {
        val alarms = appContext.getSystemService(AlarmManager::class.java) ?: throw IllegalStateException("alarms unavailable")
        alarms.setWindow(AlarmManager.RTC_WAKEUP, triggerAtMilliseconds, WINDOW_MILLISECONDS, intent(record.owner, record.key))
    }

    override fun disarm(owner: String, key: String) {
        appContext.getSystemService(AlarmManager::class.java)?.cancel(intent(owner, key))
        appContext.getSystemService(NotificationManager::class.java)?.cancel(tag(owner), key.hashCode())
    }

    private fun tag(owner: String) = "alarm:$owner"

    private fun intent(owner: String, key: String): PendingIntent = PendingIntent.getBroadcast(appContext, 0,
        Intent(appContext, receiver).setAction(AlarmDelivery.ACTION_FIRE).setData(Uri.parse("scriptwidget-alarm://fire/$owner/$key")),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** Posts the alert for [record] now. Returns false when notifications are not allowed. */
    fun post(record: AlarmRecord): Boolean {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return false
        if (!enabled()) return false
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Widget alarms and timers", NotificationManager.IMPORTANCE_HIGH).apply { description = "Alarms and timers started from your widgets" })
        val launch = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
        val builder = Notification.Builder(appContext, CHANNEL).setSmallIcon(R.drawable.sw_notification).setContentTitle(record.title)
            .setCategory(Notification.CATEGORY_ALARM).setAutoCancel(true).setShowWhen(true)
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(appContext, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        manager.notify(tag(record.owner), record.key.hashCode(), builder.build())
        return true
    }

    companion object {
        const val CHANNEL = "scriptwidget.alarms"
        /** Android stretches shorter windows to ten minutes; ask for what it will honor. */
        const val WINDOW_MILLISECONDS = 10 * 60_000L
    }
}

/** What the app's broadcast receiver does for alarm, boot and clock-change broadcasts. */
object AlarmDelivery {
    const val ACTION_FIRE = "com.everettjf.scriptwidget.alarm.FIRE"

    /**
     * Handles one broadcast. [installationExists] lets the app drop alarms of deleted packages.
     * - `ACTION_FIRE`: posts the alert if the alarm is still armed and removes its record: a fired
     *   alarm is finished, and its key can be scheduled again.
     * - Anything else (boot, app update, clock or time-zone change): re-arms every armed record.
     */
    fun handle(context: Context, intent: Intent, receiver: Class<*>, installationExists: (String) -> Boolean) {
        val stores = SystemStores.get(context, receiver)
        val platform = AndroidAlarmPlatform(context, receiver)
        val store = stores.alarmStore
        val now = System.currentTimeMillis()
        synchronized(store.lock) {
            val all = runCatching { store.all() }.getOrNull() ?: run { SystemLog.call("alarms.deliver", "unavailable"); return }
            if (intent.action == ACTION_FIRE) {
                val segments = intent.data?.pathSegments.orEmpty()
                val record = all.firstOrNull { segments.size == 2 && it.owner == segments[0] && it.key == segments[1] && it.armed }
                if (record == null) { SystemLog.call("alarms.fire", "not_pending"); return }
                store.save(all - record)
                if (!installationExists(record.owner)) { SystemLog.call("alarms.fire", "owner_removed"); return }
                val posted = runCatching { platform.post(record) }.getOrDefault(false)
                SystemLog.call("alarms.fire", if (posted) "ok" else "permission_denied")
                return
            }
            val kept = all.filter { installationExists(it.owner) }
            if (kept.size != all.size) store.save(kept)
            var armed = 0
            // An alarm whose time passed while the device was off fires shortly after.
            for (record in kept) if (record.armed && runCatching { platform.arm(record, maxOf(record.fireAt ?: now, now + 5_000)) }.isSuccess) armed += 1
            SystemLog.call("alarms.rearm", "ok count=$armed")
        }
    }
}
