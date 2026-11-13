package com.everettjf.scriptwidget.live

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.Uri
import android.os.Build
import android.util.Log
import com.everettjf.scriptwidget.AppServices
import com.everettjf.scriptwidget.MainActivity
import com.everettjf.scriptwidget.R
import com.everettjf.scriptwidget.core.surfaces.LiveActivityState
import com.everettjf.scriptwidget.core.surfaces.LiveActivityStateException
import com.everettjf.scriptwidget.core.surfaces.LiveActivityStates
import org.json.JSONObject

/** One running Live Update. It belongs to an installation, not to a package name. */
class LiveUpdate(val installation: String, val notificationID: Int, val stateJson: String, val startedAt: Long, val updatedAt: Long)

/** Outcome of a Live Update request. [message] is user-facing and set only on failure. */
class LiveUpdateResult private constructor(val ok: Boolean, val message: String?) {
    companion object {
        val OK = LiveUpdateResult(true, null)
        fun error(message: String) = LiveUpdateResult(false, message)
    }
}

/**
 * Android's counterpart of local Live Activities: an ongoing notification
 * that asks to be promoted to a Live Update. The system draws its own
 * template from the state's `title`, `detail`, `progress`/`total` and
 * `endsAt`; the package's JSX layout and Dynamic Island content are not drawn.
 */
object LiveUpdates {
    private const val TAG = "ScriptWidget"
    const val CHANNEL = "live-updates"
    /** Notification tag of every Live Update; the id is [LiveUpdate.notificationID]. */
    const val NOTIFICATION_TAG = "live-update"
    /** As on iOS, at most four activities run at once. */
    const val MAXIMUM_ACTIVE = 4
    private const val PREFERENCES = "live-updates"
    private const val KEY_ACTIVE = "active"
    private const val KEY_NEXT = "next"
    private const val FIRST_NOTIFICATION_ID = 7100
    /** A notification that was just posted may not be listed yet. */
    private const val RECONCILE_GRACE_MILLISECONDS = 3000L

    /**
     * Starts a Live Update for an installed package.
     * Fails when the state is invalid, the package already has one, four are running, or notifications are off.
     */
    @Synchronized
    fun start(context: Context, installation: String, stateText: String): LiveUpdateResult {
        val application = context.applicationContext
        // Records of Live Updates the system no longer shows must not block a new one.
        reconcile(application)
        if (load(application).containsKey(installation)) return LiveUpdateResult.error("This widget already has a Live Update. Update or end it.")
        if (load(application).size >= MAXIMUM_ACTIVE) return LiveUpdateResult.error("At most $MAXIMUM_ACTIVE Live Updates can run at once. End one first.")
        return post(application, installation, stateText, null)
    }

    /** Replaces the state of a running Live Update. Fails when none is running for the package. */
    @Synchronized
    fun update(context: Context, installation: String, stateText: String): LiveUpdateResult {
        val application = context.applicationContext
        val current = load(application)[installation] ?: return LiveUpdateResult.error("This widget has no running Live Update.")
        return post(application, installation, stateText, current)
    }

    /** Ends a package's Live Update and removes its notification. Returns false when none was running. */
    @Synchronized
    fun end(context: Context, installation: String): Boolean {
        val application = context.applicationContext
        val all = load(application)
        val current = all.remove(installation) ?: return false
        save(application, all)
        application.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION_TAG, current.notificationID)
        application.getSystemService(AlarmManager::class.java)?.cancel(expiry(application, installation, 0))
        return true
    }

    /** The Live Updates the system still shows, oldest first. Ends those whose package is gone. */
    @Synchronized
    fun active(context: Context): List<LiveUpdate> {
        reconcile(context)
        return load(context.applicationContext).values.sortedBy { it.startedAt }
    }

    /** The running Live Update of a package, or null. */
    @Synchronized
    fun find(context: Context, installation: String): LiveUpdate? = load(context.applicationContext)[installation]

    /**
     * Brings the records in line with reality: ends Live Updates of packages
     * that were deleted, and forgets ones the system no longer shows (after a
     * restart, a timeout or a user dismissal).
     */
    @Synchronized
    fun reconcile(context: Context) {
        val application = context.applicationContext
        AppServices.attach(application)
        val all = load(application)
        if (all.isEmpty()) return
        val manager = application.getSystemService(NotificationManager::class.java)
        val shown = runCatching { manager?.activeNotifications?.filter { it.tag == NOTIFICATION_TAG }?.map { it.id }?.toSet() }.getOrNull()
        val installations = AppServices.library.list().map { it.installation }.toSet()
        val now = System.currentTimeMillis()
        for (update in all.values.toList()) {
            val retired = update.installation !in installations
            val vanished = shown != null && update.notificationID !in shown && now - update.updatedAt > RECONCILE_GRACE_MILLISECONDS
            if (!retired && !vanished) continue
            all.remove(update.installation)
            manager?.cancel(NOTIFICATION_TAG, update.notificationID)
            application.getSystemService(AlarmManager::class.java)?.cancel(expiry(application, update.installation, 0))
        }
        save(application, all)
    }

    /** True when notifications are allowed for the app, which every Live Update needs. */
    fun notificationsAllowed(context: Context): Boolean = context.getSystemService(NotificationManager::class.java)?.areNotificationsEnabled() == true

    /** True when this Android version has Live Updates (Android 16 and later). */
    /** Promoted Live Updates exist from Android 16 QPR (API 36.1); Android 16.0 has the same API level without them. */
    val promotionSupported: Boolean by lazy {
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA &&
            runCatching { Notification.Builder::class.java.getMethod("setRequestPromotedOngoing", Boolean::class.javaPrimitiveType) }.isSuccess
    }

    /** True when the user lets this app's notifications be promoted to Live Updates. Always false before Android 16. */
    fun promotionAllowed(context: Context): Boolean =
        promotionSupported && runCatching { context.getSystemService(NotificationManager::class.java)?.canPostPromotedNotifications() == true }.getOrDefault(false)

    private fun post(context: Context, installation: String, stateText: String, current: LiveUpdate?): LiveUpdateResult {
        AppServices.attach(context)
        val installed = AppServices.library.findByInstallation(installation) ?: return LiveUpdateResult.error("This widget is no longer installed.")
        val state = try {
            LiveActivityStates.parse(stateText)
        } catch (error: LiveActivityStateException) {
            return LiveUpdateResult.error(error.message ?: "The state is invalid.")
        }
        val manager = context.getSystemService(NotificationManager::class.java) ?: return LiveUpdateResult.error("Notifications are unavailable on this device.")
        if (!manager.areNotificationsEnabled()) return LiveUpdateResult.error("Allow notifications for ScriptWidget to show Live Updates.")
        ensureChannel(context, manager)

        val now = System.currentTimeMillis()
        val all = load(context)
        val id = current?.notificationID ?: nextNotificationID(context)
        return try {
            manager.notify(NOTIFICATION_TAG, id, notification(context, installation, installed.displayName, state, now))
            all[installation] = LiveUpdate(installation, id, state.json, current?.startedAt ?: now, now)
            save(context, all)
            schedule(context, installation, state, now)
            LiveUpdateResult.OK
        } catch (error: Exception) {
            Log.w(TAG, "Could not post Live Update", error)
            LiveUpdateResult.error("Android refused the Live Update.")
        }
    }

    private fun ensureChannel(context: Context, manager: NotificationManager) {
        if (manager.getNotificationChannel(CHANNEL) != null) return
        // Low importance is silent; a minimum-importance channel could not be promoted.
        val channel = NotificationChannel(CHANNEL, context.getString(R.string.live_updates_channel), NotificationManager.IMPORTANCE_LOW)
        channel.description = context.getString(R.string.live_updates_channel_description)
        manager.createNotificationChannel(channel)
    }

    private fun notification(context: Context, installation: String, packageName: String, state: LiveActivityState, now: Long): Notification {
        val content = LiveActivityStates.content(state, packageName, now)
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val open = Intent(context, MainActivity::class.java)
            .setData(Uri.parse("scriptwidget://package/${Uri.encode(installation)}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        val builder = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_control_timer)
            .setContentTitle(content.title)
            .setSubText(packageName.takeIf { it != content.title })
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(Notification.CATEGORY_PROGRESS)
            .setContentIntent(PendingIntent.getActivity(context, 0, open, flags))
            .setDeleteIntent(PendingIntent.getBroadcast(context, 0, receiverIntent(context, LiveUpdateReceiver.ACTION_DISMISSED, installation), flags))
            .addAction(Notification.Action.Builder(
                Icon.createWithResource(context, R.drawable.ic_control_check), context.getString(R.string.live_updates_end),
                PendingIntent.getBroadcast(context, 0, receiverIntent(context, LiveUpdateReceiver.ACTION_END, installation), flags),
            ).build())
        if (content.text.isNotEmpty()) builder.setContentText(content.text)

        val deadline = content.countdownTo
        if (deadline != null) {
            // A countdown the system keeps current without waking the app.
            builder.setWhen(deadline).setShowWhen(true).setUsesChronometer(true).setChronometerCountDown(true)
            // The system removes the notification at the deadline even if the alarm below is delivered late.
            builder.setTimeoutAfter((deadline - now).coerceAtLeast(1000))
        } else {
            builder.setShowWhen(false)
        }

        val progress = content.progress
        val total = content.total
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            if (progress != null && total != null) {
                builder.setStyle(Notification.ProgressStyle().addProgressSegment(Notification.ProgressStyle.Segment(total)).setProgress(progress))
                // The status-bar chip shows the countdown when there is one, otherwise the progress.
                // Promotion arrived in Android 16 QPR (API 36.1); Android 16.0 has the progress style without it.
                if (deadline == null) "$progress/$total".takeIf { it.length <= 7 }?.let { text -> ifPresent { builder.setShortCriticalText(text) } }
            }
            ifPresent { builder.setRequestPromotedOngoing(true) }
        } else if (progress != null && total != null) {
            builder.setProgress(total, progress, false)
        }
        return builder.build()
    }

    /** Arms or clears the alarm that ends a Live Update at its deadline. Inexact: no exact-alarm permission is used. */
    private fun schedule(context: Context, installation: String, state: LiveActivityState, now: Long) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val deadline = state.endsAt?.takeIf { it > now }
        if (deadline == null) alarms.cancel(expiry(context, installation, 0))
        else alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, deadline, expiry(context, installation, deadline))
    }

    private fun expiry(context: Context, installation: String, deadline: Long): PendingIntent =
        PendingIntent.getBroadcast(context, 0, receiverIntent(context, LiveUpdateReceiver.ACTION_EXPIRE, installation).putExtra(LiveUpdateReceiver.EXTRA_DEADLINE, deadline),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

    private fun receiverIntent(context: Context, action: String, installation: String): Intent =
        Intent(context, LiveUpdateReceiver::class.java).setAction(action)
            .setData(Uri.parse("scriptwidget-live://${Uri.encode(installation)}/${action.substringAfterLast('.')}"))
            .putExtra(LiveUpdateReceiver.EXTRA_INSTALLATION, installation)

    /** Called by the receiver: forgets a Live Update the user swiped away without touching the notification. */
    @Synchronized
    internal fun forget(context: Context, installation: String) {
        val all = load(context)
        if (all.remove(installation) == null) return
        save(context, all)
        context.getSystemService(AlarmManager::class.java)?.cancel(expiry(context, installation, 0))
    }

    /** Called by the receiver: ends the Live Update only if [deadline] is still its deadline. */
    @Synchronized
    internal fun expire(context: Context, installation: String, deadline: Long) {
        val current = load(context)[installation] ?: return
        val state = runCatching { LiveActivityStates.parse(current.stateJson) }.getOrNull()
        if (state?.endsAt == deadline && deadline <= System.currentTimeMillis() + 1000) end(context, installation)
    }

    private fun nextNotificationID(context: Context): Int {
        val preferences = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)
        val id = preferences.getInt(KEY_NEXT, FIRST_NOTIFICATION_ID).coerceIn(FIRST_NOTIFICATION_ID, FIRST_NOTIFICATION_ID + 100_000)
        preferences.edit().putInt(KEY_NEXT, if (id >= FIRST_NOTIFICATION_ID + 100_000) FIRST_NOTIFICATION_ID else id + 1).apply()
        return id
    }

    private fun load(context: Context): MutableMap<String, LiveUpdate> {
        val result = LinkedHashMap<String, LiveUpdate>()
        val text = context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(KEY_ACTIVE, null) ?: return result
        val json = runCatching { JSONObject(text) }.getOrNull() ?: return result
        for (installation in json.keys()) {
            val entry = json.optJSONObject(installation) ?: continue
            val id = entry.optInt("id", -1)
            val state = entry.opt("state") as? String ?: continue
            if (id < 0 || state.toByteArray().size > LiveActivityStates.MAXIMUM_BYTES) continue
            result[installation] = LiveUpdate(installation, id, state, entry.optLong("started"), entry.optLong("updated"))
        }
        return result
    }

    private fun save(context: Context, all: Map<String, LiveUpdate>) {
        val json = JSONObject()
        for (update in all.values) {
            json.put(update.installation, JSONObject().put("id", update.notificationID).put("state", update.stateJson).put("started", update.startedAt).put("updated", update.updatedAt))
        }
        // Committed at once: the receiver may run in a short-lived process.
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(KEY_ACTIVE, json.toString()).commit()
    }
}

/** Handles a Live Update's deadline alarm, its End button and a user dismissal. */
class LiveUpdateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val installation = intent.getStringExtra(EXTRA_INSTALLATION) ?: return
        val application = context.applicationContext
        when (intent.action) {
            ACTION_END -> LiveUpdates.end(application, installation)
            ACTION_DISMISSED -> LiveUpdates.forget(application, installation)
            ACTION_EXPIRE -> LiveUpdates.expire(application, installation, intent.getLongExtra(EXTRA_DEADLINE, 0))
        }
    }

    companion object {
        const val ACTION_END = "com.everettjf.scriptwidget.live.END"
        const val ACTION_DISMISSED = "com.everettjf.scriptwidget.live.DISMISSED"
        const val ACTION_EXPIRE = "com.everettjf.scriptwidget.live.EXPIRE"
        const val EXTRA_INSTALLATION = "installation"
        const val EXTRA_DEADLINE = "deadline"
    }
}

/** Runs [block] and ignores a platform method that this Android version does not have. */
private inline fun ifPresent(block: () -> Unit) {
    try { block() } catch (_: NoSuchMethodError) { /* older platform release */ }
}
