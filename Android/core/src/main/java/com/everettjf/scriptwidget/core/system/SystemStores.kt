package com.everettjf.scriptwidget.core.system

import android.content.Context
import com.everettjf.scriptwidget.core.runtime.NativeModule
import java.io.File

/**
 * The stores, platform adapters and native modules of the system data APIs,
 * one set per process. Everything lives under the app-private
 * `files/SystemData` directory, which no script path can reach and which is
 * never part of an exported package.
 */
class SystemStores private constructor(context: Context, notificationReceiver: Class<*>) {
    private val appContext = context.applicationContext
    val root = File(appContext.filesDir, "SystemData")

    val prompts = PermissionPrompts(PrivateFile(File(root, "prompts.json"), 4 * 1024))
    val grants = SystemAccessGrants(PrivateFile(File(root, "grants.json"), 128 * 1024))

    val locationPlatform = AndroidLocationPlatform(appContext)
    val location = LocationModule(locationPlatform, LocationSnapshotStore(PrivateFile(File(root, "location-snapshot.json"), LocationSnapshot.MAXIMUM_BYTES)) { System.currentTimeMillis() }, prompts)

    val calendarPlatform = AndroidCalendarPlatform(appContext)
    val calendarSelection = CalendarSelectionStore(PrivateFile(File(root, "calendar-access.v1.json"), 128 * 1024))
    val calendar = CalendarModule(calendarPlatform, calendarSelection, grants, prompts, File(root, "calendar"))

    val photoLibrary = PhotoLibrary(File(root, "photos"))
    val photoImporter = PhotoImporter(appContext, photoLibrary)
    val photos = PhotosModule(photoLibrary, File(root, "photo-snapshots"))

    val notificationPlatform = AndroidNotificationPlatform(appContext, notificationReceiver)
    val notificationStore = NotificationStore(PrivateFile(File(root, "notifications.json"), 256 * 1024))
    val notifications = NotificationsModule(notificationPlatform, notificationStore, grants, prompts)

    val serviceConnections = ServiceConnections(KeystoreServiceVault(File(root, "services/github.bin")), FetchServiceTransport())
    val services = ServicesModule(serviceConnections)

    val healthPlatform = AndroidHealthPlatform(appContext)
    val health = HealthModule(healthPlatform, prompts)

    /** The six modules to pass to `WidgetRuntime(context, extraModules)`. */
    val modules: List<NativeModule> = listOf(location, calendar, photos, notifications, services, health)

    companion object {
        @Volatile private var instance: SystemStores? = null

        /** [notificationReceiver] is the app's broadcast receiver that forwards alarms to [NotificationDelivery]. */
        fun get(context: Context, notificationReceiver: Class<*>): SystemStores =
            instance ?: synchronized(this) { instance ?: SystemStores(context, notificationReceiver).also { instance = it } }
    }
}
