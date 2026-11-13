package com.everettjf.scriptwidget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.everettjf.scriptwidget.core.runtime.NativeModule
import com.everettjf.scriptwidget.core.system.NotificationDelivery
import com.everettjf.scriptwidget.core.system.SystemExecutor
import com.everettjf.scriptwidget.core.system.SystemStores

/**
 * The system data APIs: `$location`, `$calendar`, `$photos`, `$notifications`
 * and `$services` (Android 1.0) and `$health` (Android 1.1). Register them with
 * `WidgetRuntime(context, SystemModules.create(context))`.
 */
object SystemModules {
    /** Stores shared by the native modules and the System Access screen. */
    fun stores(context: Context): SystemStores = SystemStores.get(context, SystemNotificationReceiver::class.java)

    /** The six native modules, backed by the process-wide [stores]. */
    fun create(context: Context): List<NativeModule> = stores(context).modules

    /**
     * Call after a package is deleted: cancels its pending notifications and removes its grants.
     * Calendar events it created are user data and are never deleted.
     */
    fun retireInstallation(context: Context, installation: String) {
        val stores = stores(context)
        stores.notifications.retire(installation)
        for (capability in stores.grants.capabilities(installation)) stores.grants.set(installation, capability, false)
        runCatching { stores.serviceConnections.setGrant(installation, false) }
    }
}

/**
 * Receives the notification alarms and the broadcasts after which alarms
 * must be armed again (boot, app update, clock or time-zone change). Slots
 * of packages that no longer exist are dropped instead of delivered.
 */
class SystemNotificationReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in ACTIONS) return
        val pending = goAsync()
        val appContext = context.applicationContext
        SystemExecutor.pool.execute {
            try {
                NotificationDelivery.handle(appContext, intent, SystemNotificationReceiver::class.java) { installation ->
                    runCatching { AppServices.library.findByInstallation(installation) != null }.getOrDefault(true)
                }
            } finally { pending.finish() }
        }
    }

    private companion object {
        val ACTIONS = setOf(NotificationDelivery.ACTION_FIRE, Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED, Intent.ACTION_TIME_CHANGED, Intent.ACTION_TIMEZONE_CHANGED)
    }
}
