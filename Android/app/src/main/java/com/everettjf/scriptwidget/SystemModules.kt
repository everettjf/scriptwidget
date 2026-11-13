package com.everettjf.scriptwidget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.everettjf.scriptwidget.core.runtime.NativeModule
import com.everettjf.scriptwidget.core.system.AlarmDelivery
import com.everettjf.scriptwidget.core.system.NotificationDelivery
import com.everettjf.scriptwidget.core.system.SystemExecutor
import com.everettjf.scriptwidget.core.system.SystemStores

/**
 * The system data APIs of Android 1.0 (`$location`, `$calendar`, `$photos`,
 * `$notifications`, `$services`) and 1.1 (`$weather`, `$alarms`, `$documents`,
 * `$contacts`, `$music`, `$health`). Register them with
 * `WidgetRuntime(context, SystemModules.create(context))`.
 */
object SystemModules {
    /** Stores shared by the native modules and the System Access screen. */
    fun stores(context: Context): SystemStores = SystemStores.get(context, SystemNotificationReceiver::class.java)

    /** The native modules, backed by the process-wide [stores]. */
    fun create(context: Context): List<NativeModule> = stores(context).modules

    /**
     * Call after a package is deleted: cancels its pending notifications and alarms, deletes its
     * imported documents, selected contacts and forecast cache, and removes its grants.
     * Calendar events it created are user data and are never deleted.
     */
    fun retireInstallation(context: Context, installation: String) {
        val stores = stores(context)
        stores.notifications.retire(installation)
        runCatching { stores.retire(installation, AppServices.library.list().map { it.installation }) }
        for (capability in stores.grants.capabilities(installation)) stores.grants.set(installation, capability, false)
        runCatching { stores.serviceConnections.setGrant(installation, false) }
    }
}

/**
 * Receives the `$notifications` and `$alarms` alarms and the broadcasts after
 * which alarms must be armed again (boot, app update, clock or time-zone
 * change). Slots of packages that no longer exist are dropped instead of delivered.
 */
class SystemNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in ACTIONS) return
        val pending = goAsync()
        val appContext = context.applicationContext
        SystemExecutor.pool.execute {
            try {
                val exists = { installation: String -> runCatching { AppServices.library.findByInstallation(installation) != null }.getOrDefault(true) }
                // A fire broadcast belongs to one of the two; every other broadcast re-arms both.
                if (intent.action != AlarmDelivery.ACTION_FIRE) NotificationDelivery.handle(appContext, intent, SystemNotificationReceiver::class.java, exists)
                if (intent.action != NotificationDelivery.ACTION_FIRE) AlarmDelivery.handle(appContext, intent, SystemNotificationReceiver::class.java, exists)
            } finally { pending.finish() }
        }
    }

    private companion object {
        val ACTIONS = setOf(NotificationDelivery.ACTION_FIRE, AlarmDelivery.ACTION_FIRE, Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED)
    }
}
