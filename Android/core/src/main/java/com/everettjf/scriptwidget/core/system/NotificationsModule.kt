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
import java.time.Instant
import java.time.ZoneId

/** One scheduled local notification of one installation. Exactly one of [date] or [hour]/[minute] is set. */
class ScheduledNotification(val owner: String, val key: String, val title: String, val body: String, val date: Long?, val hour: Int?, val minute: Int?) {
    val repeats: Boolean get() = hour != null && minute != null

    fun toJson(): JSONObject = JSONObject().put("owner", owner).put("key", key).put("title", title).put("body", body)
        .put("date", date ?: JSONObject.NULL).put("hour", hour ?: JSONObject.NULL).put("minute", minute ?: JSONObject.NULL)
}

/** Limits and pure rules of `$notifications`. */
object NotificationRules {
    /** Slots per installation. */
    const val MAXIMUM_PER_OWNER = 32
    /** Conservative app-wide capacity, the same check the Apple runtime makes. */
    const val MAXIMUM_TOTAL = 60
    const val MAXIMUM_DATE_WINDOW_MILLISECONDS = 366L * 86_400_000L
    private val fields = setOf("key", "title", "body", "date", "daily")

    /**
     * `schedule(options)` input: closed fields; key `[a-zA-Z0-9_-]{1,64}`; title/body nonempty,
     * without control characters, at most 256/1024 UTF-8 bytes; exactly one of `date` (future,
     * at most 366 days away) or `daily` (`{hour: 0–23, minute: 0–59}`, integers).
     */
    fun parse(owner: String, options: JSONObject, nowMilliseconds: Long): ScheduledNotification {
        val invalid = { SystemServiceError.INVALID_OPTIONS.reject() }
        SystemOptions.fields(options, fields)
        val key = SystemOptions.text(SystemOptions.member(options, "key"), 64)
        if (!SystemOptions.validKey(key)) throw invalid()
        val title = SystemOptions.text(SystemOptions.member(options, "title"), 256)
        val body = SystemOptions.text(SystemOptions.member(options, "body"), 1024)
        if (options.has("date") == options.has("daily")) throw invalid()
        if (options.has("date")) {
            val date = SystemOptions.date(options.opt("date"))
            if (date <= nowMilliseconds || date - nowMilliseconds > MAXIMUM_DATE_WINDOW_MILLISECONDS) throw invalid()
            return ScheduledNotification(owner, key, title, body, date, null, null)
        }
        val daily = options.opt("daily") as? JSONObject ?: throw invalid()
        SystemOptions.fields(daily, setOf("hour", "minute"))
        return ScheduledNotification(owner, key, title, body, null, SystemOptions.integer(SystemOptions.member(daily, "hour"), 0..23), SystemOptions.integer(SystemOptions.member(daily, "minute"), 0..59))
    }

    /** When [entry] fires next: its date, or the next local `hour:minute` strictly after [nowMilliseconds] (DST aware). */
    fun nextTrigger(entry: ScheduledNotification, nowMilliseconds: Long, zone: ZoneId): Long {
        val hour = entry.hour
        val minute = entry.minute
        if (hour == null || minute == null) return entry.date ?: nowMilliseconds
        val now = Instant.ofEpochMilli(nowMilliseconds).atZone(zone)
        var next = now.toLocalDate().atTime(hour, minute).atZone(zone)
        if (!next.toInstant().isAfter(now.toInstant())) next = now.toLocalDate().plusDays(1).atTime(hour, minute).atZone(zone)
        return next.toInstant().toEpochMilli()
    }

    /** A new slot needs room app-wide (60) and for the installation (32); replacing an existing key always fits. */
    fun hasCapacity(all: List<ScheduledNotification>, owner: String, key: String): Boolean {
        if (all.any { it.owner == owner && it.key == key }) return true
        return all.size < MAXIMUM_TOTAL && all.count { it.owner == owner } < MAXIMUM_PER_OWNER
    }
}

/** Durable list of pending notifications; the source of truth for `pending()` and for re-scheduling after a reboot. */
class NotificationStore(private val file: PrivateFile) {
    val lock: Any get() = file.lock

    /** Every pending entry. An unreadable or malformed file is `unavailable`, never an empty list. */
    fun all(): List<ScheduledNotification> = synchronized(file.lock) {
        val text = try { file.read() } catch (error: PrivateFile.Unreadable) { throw SystemServiceError.UNAVAILABLE.reject() } ?: return@synchronized emptyList()
        try {
            val array = JSONObject(text).getJSONArray("pending")
            List(array.length()) { index ->
                val item = array.getJSONObject(index)
                val entry = ScheduledNotification(item.getString("owner"), item.getString("key"), item.getString("title"), item.getString("body"),
                    if (item.isNull("date")) null else item.getLong("date"), if (item.isNull("hour")) null else item.getInt("hour"), if (item.isNull("minute")) null else item.getInt("minute"))
                if (!CallContext.isOwner(entry.owner) || !SystemOptions.validKey(entry.key) || (entry.date == null) == !entry.repeats) throw SystemServiceError.UNAVAILABLE.reject()
                entry
            }
        } catch (error: org.json.JSONException) { throw SystemServiceError.UNAVAILABLE.reject() }
    }

    fun save(entries: List<ScheduledNotification>): Boolean = synchronized(file.lock) {
        file.write(JSONObject().put("formatVersion", 1).put("pending", JSONArray(entries.map { it.toJson() })).toString())
    }

    /** Removes one slot and reports whether it existed. */
    fun remove(owner: String, key: String): Boolean = synchronized(file.lock) {
        val entries = all()
        val remaining = entries.filterNot { it.owner == owner && it.key == key }
        remaining.size != entries.size && save(remaining)
    }
}

/** The system side of local notifications. */
interface NotificationPlatform {
    /** The user allowed this app to post notifications. */
    fun enabled(): Boolean
    /** Arms an inexact alarm that posts [entry] around [triggerAtMilliseconds]; replaces an alarm of the same owner and key. */
    fun schedule(entry: ScheduledNotification, triggerAtMilliseconds: Long)
    fun cancel(owner: String, key: String)
}

/**
 * `$notifications`: `status`, `pending`, `schedule`, `cancel`. Entries are keyed
 * per installation; a widget can only see and cancel its own. Scheduling
 * acknowledges that the alarm was accepted, not that the notification was delivered.
 */
class NotificationsModule(
    private val platform: NotificationPlatform,
    private val store: NotificationStore,
    private val grants: SystemAccessGrants,
    private val prompts: PermissionPrompts,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
    private val zone: () -> ZoneId = { ZoneId.systemDefault() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$notifications")

    override fun handles(operation: String): Boolean = operation.startsWith("notifications.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "notifications.status" -> runSystemCall(operation, done) { status(context).toString() }
            "notifications.pending" -> runSystemCall(operation, done) { pending(context).toString() }
            "notifications.schedule" -> runSystemCall(operation, done) { schedule(context, payload?.optJSONObject("options")).toString() }
            "notifications.cancel" -> runSystemCall(operation, done) { cancel(context, payload?.opt("key")).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** `authorized`, `denied`, or `notDetermined` when the app has not asked yet. */
    fun authorization(): String = if (platform.enabled()) "authorized" else if (prompts.asked(PROMPT)) "denied" else "notDetermined"

    fun status(context: CallContext): JSONObject {
        SystemGate.check(context, PERMISSION, writing = false, grants = grants)
        return JSONObject().put("authorization", authorization())
    }

    /** This installation's slots: `{key, title, body, repeats, date}` with the next fire date. */
    fun pending(context: CallContext): JSONArray {
        SystemGate.check(context, PERMISSION, writing = false, grants = grants)
        val now = clock.now()
        val rows = store.all().filter { it.owner == context.installation }.take(NotificationRules.MAXIMUM_PER_OWNER)
        SystemGate.validate(context, PERMISSION, writing = false, grants = grants)
        return JSONArray(rows.map { JSONObject().put("key", it.key).put("title", it.title).put("body", it.body).put("repeats", it.repeats).put("date", IsoDates.format(NotificationRules.nextTrigger(it, now, zone()))) })
    }

    /**
     * After the system gate (an action, the native grant, the query budget): strict options,
     * notification authorization (`permission_denied`), capacity (`limit_exceeded`). The same
     * key replaces the installation's slot.
     */
    fun schedule(context: CallContext, options: JSONObject?): JSONObject {
        SystemGate.check(context, PERMISSION, writing = true, grants = grants)
        val entry = NotificationRules.parse(context.installation, options ?: throw SystemServiceError.INVALID_OPTIONS.reject(), clock.now())
        if (!platform.enabled()) throw SystemServiceError.PERMISSION_DENIED.reject()
        synchronized(store.lock) {
            val all = store.all()
            SystemGate.validate(context, PERMISSION, writing = true, grants = grants)
            if (!NotificationRules.hasCapacity(all, entry.owner, entry.key)) throw SystemServiceError.LIMIT_EXCEEDED.reject()
            if (!store.save(all.filterNot { it.owner == entry.owner && it.key == entry.key } + entry)) throw SystemServiceError.UNAVAILABLE.reject()
            try { platform.schedule(entry, NotificationRules.nextTrigger(entry, clock.now(), zone())) } catch (error: Exception) {
                store.save(all.filterNot { it.owner == entry.owner && it.key == entry.key })
                throw SystemServiceError.UNAVAILABLE.reject()
            }
        }
        return JSONObject().put("key", entry.key).put("status", "scheduled")
    }

    /** Cancels this installation's pending slot. Notifications that were already delivered are not touched. */
    fun cancel(context: CallContext, rawKey: Any?): JSONObject {
        SystemGate.check(context, PERMISSION, writing = true, grants = grants)
        val key = rawKey as? String
        if (key == null || !SystemOptions.validKey(key)) throw SystemServiceError.INVALID_OPTIONS.reject()
        SystemGate.validate(context, PERMISSION, writing = true, grants = grants)
        store.remove(context.installation, key)
        runCatching { platform.cancel(context.installation, key) }
        return JSONObject().put("key", key).put("status", "cancellationRequested")
    }

    /** Cancels every slot of a deleted installation. Called by the app when a package is removed. */
    fun retire(installation: String) {
        val mine = runCatching { store.all() }.getOrDefault(emptyList()).filter { it.owner == installation }
        for (entry in mine) { store.remove(entry.owner, entry.key); runCatching { platform.cancel(entry.owner, entry.key) } }
        SystemLog.call("notifications.retire", "ok count=${mine.size}")
    }

    companion object {
        const val PERMISSION = "notifications"
        const val PROMPT = "notifications"
    }
}

/**
 * Inexact alarms (`setWindow`, no exact-alarm permission) that broadcast to
 * the app's receiver, which calls [NotificationDelivery]. Posting uses one
 * notification channel and needs `POST_NOTIFICATIONS`.
 */
class AndroidNotificationPlatform(context: Context, private val receiver: Class<*>) : NotificationPlatform {
    private val appContext = context.applicationContext

    override fun enabled(): Boolean = appContext.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED &&
        appContext.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() == true

    override fun schedule(entry: ScheduledNotification, triggerAtMilliseconds: Long) {
        val alarms = appContext.getSystemService(AlarmManager::class.java) ?: throw IllegalStateException("alarms unavailable")
        alarms.setWindow(AlarmManager.RTC_WAKEUP, triggerAtMilliseconds, WINDOW_MILLISECONDS, intent(entry.owner, entry.key))
    }

    override fun cancel(owner: String, key: String) {
        appContext.getSystemService(AlarmManager::class.java)?.cancel(intent(owner, key))
    }

    private fun intent(owner: String, key: String): PendingIntent = PendingIntent.getBroadcast(appContext, 0,
        Intent(appContext, receiver).setAction(NotificationDelivery.ACTION_FIRE).setData(Uri.parse("scriptwidget-notification://fire/$owner/$key")),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    /** Posts [entry] now. Returns false when notifications are not allowed. */
    fun post(entry: ScheduledNotification): Boolean {
        val manager = appContext.getSystemService(NotificationManager::class.java) ?: return false
        if (!enabled()) return false
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Widget reminders", NotificationManager.IMPORTANCE_DEFAULT).apply { description = "Reminders scheduled by your widgets" })
        val launch = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName)
        val builder = Notification.Builder(appContext, CHANNEL).setSmallIcon(R.drawable.sw_notification).setContentTitle(entry.title).setContentText(entry.body)
            .setStyle(Notification.BigTextStyle().bigText(entry.body)).setAutoCancel(true).setShowWhen(true)
        if (launch != null) builder.setContentIntent(PendingIntent.getActivity(appContext, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
        manager.notify(entry.owner, entry.key.hashCode(), builder.build())
        return true
    }

    companion object {
        const val CHANNEL = "scriptwidget.reminders"
        /** Android stretches shorter windows to ten minutes; ask for what it will honor. */
        const val WINDOW_MILLISECONDS = 10 * 60_000L
    }
}

/** What the app's broadcast receiver does for alarm, boot and clock-change broadcasts. */
object NotificationDelivery {
    const val ACTION_FIRE = "com.everettjf.scriptwidget.notification.FIRE"

    /**
     * Handles one broadcast. [installationExists] lets the app drop slots of deleted packages.
     * - `ACTION_FIRE`: posts the entry if it is still pending; a daily entry is re-armed, a one-time entry is removed.
     * - Anything else (boot, app update, clock or time-zone change): re-arms every pending entry.
     */
    fun handle(context: Context, intent: Intent, receiver: Class<*>, installationExists: (String) -> Boolean) {
        val stores = SystemStores.get(context, receiver)
        val platform = AndroidNotificationPlatform(context, receiver)
        val now = System.currentTimeMillis()
        val zone = ZoneId.systemDefault()
        if (intent.action == ACTION_FIRE) {
            val segments = intent.data?.pathSegments.orEmpty()
            val entry = runCatching { stores.notificationStore.all() }.getOrDefault(emptyList()).firstOrNull { segments.size == 2 && it.owner == segments[0] && it.key == segments[1] }
            if (entry == null) { SystemLog.call("notifications.fire", "not_pending"); return }
            if (!installationExists(entry.owner)) { stores.notificationStore.remove(entry.owner, entry.key); SystemLog.call("notifications.fire", "owner_removed"); return }
            val posted = runCatching { platform.post(entry) }.getOrDefault(false)
            if (entry.repeats) runCatching { platform.schedule(entry, NotificationRules.nextTrigger(entry, now, zone)) } else stores.notificationStore.remove(entry.owner, entry.key)
            SystemLog.call("notifications.fire", if (posted) "ok repeats=${entry.repeats}" else "permission_denied")
            return
        }
        val entries = runCatching { stores.notificationStore.all() }.getOrDefault(emptyList())
        var armed = 0
        for (entry in entries) {
            if (!installationExists(entry.owner)) { stores.notificationStore.remove(entry.owner, entry.key); continue }
            // A one-time entry whose date passed while the device was off fires shortly after.
            val trigger = maxOf(NotificationRules.nextTrigger(entry, now, zone), now + 5_000)
            if (runCatching { platform.schedule(entry, trigger) }.isSuccess) armed += 1
        }
        SystemLog.call("notifications.rearm", "ok count=$armed")
    }
}
