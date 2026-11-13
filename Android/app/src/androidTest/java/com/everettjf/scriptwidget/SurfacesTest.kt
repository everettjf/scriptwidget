package com.everettjf.scriptwidget

import android.Manifest
import android.app.NotificationManager
import android.content.pm.ShortcutManager
import android.service.notification.StatusBarNotification
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.actions.ActionRunner
import com.everettjf.scriptwidget.actions.ControlTileStore
import com.everettjf.scriptwidget.actions.ControlTiles
import com.everettjf.scriptwidget.actions.ShortcutPublisher
import com.everettjf.scriptwidget.actions.SurfaceHooks
import com.everettjf.scriptwidget.core.surfaces.ActionFailure
import com.everettjf.scriptwidget.core.surfaces.ShortcutPlanner
import com.everettjf.scriptwidget.live.LiveUpdates
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The system surfaces of Android 1.1 against the real runtime, launcher and
 * notification services: declared actions, Quick Settings slots, launcher
 * shortcuts and Live Updates.
 */
@RunWith(AndroidJUnit4::class)
class SurfacesTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val notifications = context.getSystemService(NotificationManager::class.java)
    private val created = ArrayList<InstalledPackage>()

    @Before fun attach() {
        AppServices.attach(context)
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
    }

    @After fun cleanUp() {
        for (installed in created) {
            LiveUpdates.end(context, installed.installation)
            ControlTileStore.get(context).retire(installed.installation)
            runCatching { AppServices.library.delete(installed.name) }
        }
        ShortcutPublisher.sync(context)
    }

    private val source = """
        const on = ${'$'}storage.getString("focus.enabled") === "true";
        function record(name) {
            ${'$'}storage.setString("seen", [name, ${'$'}getenv("action-id"), ${'$'}getenv("action-source"), ${'$'}getenv("action-value"), ${'$'}getenv("control-id"), ${'$'}getenv("control-value"), ${'$'}getenv("widget-size")].join("/"));
        }
        function refreshWidget() { record("refresh"); }
        function setFocus() { record("focus"); }
        function legacy() { record("legacy"); }
        function hidden() { record("hidden"); }
        ${'$'}render(<vstack frame="max"><text>{on ? "on" : "off"}</text></vstack>)
    """

    private val surfaces = ""","actions":[
        {"id":"refresh","title":"Refresh Dashboard","systemImage":"arrow.clockwise","function":"refreshWidget"},
        {"id":"focus","title":"Set Focus","systemImage":"timer","function":"setFocus"}],
        "controls":[
        {"id":"refresh-tile","type":"button","title":"Refresh","systemImage":"arrow.clockwise","actionID":"refresh"},
        {"id":"focus-tile","type":"toggle","title":"Focus","subtitle":"Deep work","systemImage":"timer","actionID":"focus","stateKey":"focus.enabled"},
        {"id":"old","type":"button","title":"Old","systemImage":"star","action":"legacy"}]"""

    private fun manifest(permissions: String = "[\"storage\"]", extra: String = surfaces) =
        """{"entry":"main.jsx","formatVersion":2,"id":"com.example.surfaces","name":"Surfaces Test","networkDomains":[],"permissions":$permissions,"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall","systemMedium"],"version":"1.0.0"$extra}"""

    private fun install(manifest: String? = manifest()): InstalledPackage =
        AppServices.library.create("Surfaces Test ${System.nanoTime()}", source, manifest).also { created += it }

    private fun seen(installed: InstalledPackage) = AppServices.runtime.storage.getString(installed.installation, "seen")

    private fun waitFor(timeoutMilliseconds: Long = 5000, condition: () -> Boolean): Boolean {
        val deadline = System.currentTimeMillis() + timeoutMilliseconds
        while (System.currentTimeMillis() < deadline) {
            if (condition()) return true
            Thread.sleep(50)
        }
        return condition()
    }

    private fun posted(installation: String): StatusBarNotification? {
        val id = LiveUpdates.find(context, installation)?.notificationID ?: return null
        return notifications.activeNotifications.firstOrNull { it.tag == LiveUpdates.NOTIFICATION_TAG && it.id == id }
    }

    // MARK: - Actions

    @Test fun runsADeclaredActionWithTheDocumentedEnvironment() {
        val installed = install()
        val result = ActionRunner.run(context, installed.installation, "refresh", "shortcut", null, null)
        assertTrue(result.message, result.ok)
        assertEquals("refresh/refresh/shortcut////action", seen(installed).replace("undefined", "").replace("null", ""))
    }

    @Test fun rejectsAnUndeclaredActionWithoutRunningAnything() {
        val installed = install()
        // A real function of the entry file that the manifest does not declare.
        val result = ActionRunner.run(context, installed.installation, "hidden", "shortcut", null, null)
        assertFalse(result.ok)
        assertEquals(ActionFailure.ACTION_NOT_FOUND.message, result.message)
        assertEquals("", seen(installed))
        assertFalse(ActionRunner.run(context, installed.installation, "refresh", "siri", null, null).ok)
        assertFalse(ActionRunner.run(context, "00000000-0000-4000-8000-000000000000", "refresh", "shortcut", null, null).ok)
        assertEquals("", seen(installed))
    }

    @Test fun aMalformedManifestFailsClosed() {
        val installed = install()
        File(installed.directory, "widget.json").writeText("{ not json")
        val result = ActionRunner.run(context, installed.installation, "refresh", "shortcut", null, null)
        assertFalse(result.ok)
        assertEquals("", seen(installed))
        assertNull(ActionRunner.declared(AppServices.library.findByInstallation(installed.installation)!!))
    }

    @Test fun aControlToggleStoresItsStateBeforeItsActionRuns() {
        val installed = install()
        val control = ActionRunner.declared(installed)!!.control("focus-tile")!!
        assertFalse(ActionRunner.toggleValue(installed, control))
        val on = ActionRunner.run(context, installed.installation, null, "control", true, "focus-tile")
        assertTrue(on.message, on.ok)
        assertEquals("true", AppServices.runtime.storage.getString(installed.installation, "focus.enabled"))
        assertEquals("focus/focus/control/true/focus-tile/true/action", seen(installed))
        assertTrue(ActionRunner.toggleValue(installed, control))
        assertTrue(ActionRunner.run(context, installed.installation, null, "control", false, "focus-tile").ok)
        assertEquals("false", AppServices.runtime.storage.getString(installed.installation, "focus.enabled"))
        assertFalse(ActionRunner.toggleValue(installed, control))
    }

    @Test fun aWidgetToggleNeedsTheStoragePermissionToPersist() {
        val denied = install(manifest(permissions = "[]", extra = ""","actions":[{"id":"focus","title":"Set Focus","systemImage":"timer","function":"setFocus"}]"""))
        val result = ActionRunner.run(context, denied.installation, "focus", "widget", true, null, "focus.enabled")
        assertFalse(result.ok)
        assertEquals(ActionFailure.STORAGE_DENIED.message, result.message)
        assertEquals("", AppServices.runtime.storage.getString(denied.installation, "focus.enabled"))

        val allowed = install()
        assertFalse(ActionRunner.run(context, allowed.installation, "focus", "widget", true, null, "../escape").ok)
        assertTrue(ActionRunner.run(context, allowed.installation, "focus", "widget", true, null, "focus.enabled").ok)
        assertEquals("true", AppServices.runtime.storage.getString(allowed.installation, "focus.enabled"))
    }

    @Test fun aLegacyControlFunctionRunsOnlyThroughItsControl() {
        val installed = install()
        val result = ActionRunner.run(context, installed.installation, null, "control", null, "old")
        assertTrue(result.message, result.ok)
        assertTrue(seen(installed), seen(installed).startsWith("legacy/old/control/"))
        assertFalse(ActionRunner.run(context, installed.installation, "legacy", "shortcut", null, null).ok)
    }

    @Test fun runAsyncReportsOnTheMainThread() {
        val installed = install()
        var ok: Boolean? = null
        var onMain = false
        ActionRunner.runAsync(context, installed.installation, "refresh", "widget", null, null) { result ->
            onMain = android.os.Looper.myLooper() == android.os.Looper.getMainLooper()
            ok = result.ok
        }
        assertTrue(waitFor(10_000) { ok != null })
        assertEquals(true, ok)
        assertTrue(onMain)
    }

    // MARK: - Quick Settings slots

    @Test fun tileSlotsResolveToDeclaredControlsAndAreFreedWithThePackage() {
        val installed = install()
        val store = ControlTileStore.get(context)
        val slot = store.assign(installed.installation, "focus-tile")
        val resolved = ControlTiles.resolve(context, slot)
        assertNotNull(resolved)
        assertEquals("Focus", resolved!!.control.title)
        assertEquals("${installed.displayName} · Deep work", resolved.subtitle)
        assertEquals("${context.packageName}.actions.ControlTileService$slot", ControlTiles.component(context, slot).className)

        AppServices.library.delete(installed.name)
        assertNull(ControlTiles.resolve(context, slot))
        SurfaceHooks.reconcile(context)
        assertNull(store.slots().get(slot))
    }

    // MARK: - Shortcuts

    @Test fun publishingShortcutsProducesTheExpectedIds() {
        val manager = context.getSystemService(ShortcutManager::class.java)
        assumeTrue("the launcher has no room for dynamic shortcuts", manager != null && manager.maxShortcutCountPerActivity >= 2)
        val installed = install()
        val refresh = ShortcutPlanner.id(installed.installation, "refresh")
        val focus = ShortcutPlanner.id(installed.installation, "focus")
        assertEquals("action/${installed.installation}/refresh", refresh)
        // Using both makes them the two most recent, so they are published whatever else is installed.
        ShortcutPublisher.recordUse(context, installed.installation, "refresh")
        ShortcutPublisher.recordUse(context, installed.installation, "focus")

        val published = ShortcutPublisher.sync(context)
        assumeTrue("shortcut updates are rate limited right now", published.isNotEmpty())
        assertEquals(listOf(focus, refresh), published.take(2))
        val dynamic = manager!!.dynamicShortcuts.associateBy { it.id }
        assertEquals("Set Focus", dynamic[focus]?.shortLabel?.toString())
        assertEquals("Refresh Dashboard", dynamic[refresh]?.shortLabel?.toString())
        assertTrue(dynamic.getValue(focus).rank < dynamic.getValue(refresh).rank)
        // Legacy control functions are never offered as shortcuts.
        assertTrue(dynamic.keys.none { it.endsWith("/old") || it.endsWith("/legacy") })

        AppServices.library.delete(installed.name)
        val after = ShortcutPublisher.sync(context)
        assertFalse(after.contains(refresh) || after.contains(focus))
        assertTrue(manager.dynamicShortcuts.none { it.id == refresh || it.id == focus })
    }

    // MARK: - Live Updates

    @Test fun liveUpdateStartUpdateEndPostsAndCancelsANotification() {
        assumeTrue("notifications are disabled for the app", LiveUpdates.notificationsAllowed(context))
        val installed = install()
        val started = LiveUpdates.start(context, installed.installation, """{"title":"Reading","detail":"Chapter finished","progress":3,"total":8}""")
        assertTrue(started.message, started.ok)
        assertTrue(waitFor { posted(installed.installation) != null })
        val first = posted(installed.installation)!!.notification
        assertEquals("Reading", first.extras.getCharSequence(android.app.Notification.EXTRA_TITLE)?.toString())
        assertEquals("Chapter finished", first.extras.getCharSequence(android.app.Notification.EXTRA_TEXT)?.toString())
        assertTrue(first.flags and android.app.Notification.FLAG_ONGOING_EVENT != 0)
        assertEquals(LiveUpdates.CHANNEL, first.channelId)
        if (LiveUpdates.promotionSupported) assertTrue(first.isRequestPromotedOngoing)

        // A second start for the same installation is refused; an update keeps the same notification.
        assertFalse(LiveUpdates.start(context, installed.installation, "{}").ok)
        val id = LiveUpdates.find(context, installed.installation)!!.notificationID
        assertTrue(LiveUpdates.update(context, installed.installation, """{"title":"Reading","detail":"Almost done","progress":7,"total":8}""").ok)
        assertTrue(waitFor { posted(installed.installation)?.notification?.extras?.getCharSequence(android.app.Notification.EXTRA_TEXT)?.toString() == "Almost done" })
        assertEquals(id, LiveUpdates.find(context, installed.installation)!!.notificationID)
        assertEquals(1, LiveUpdates.active(context).count { it.installation == installed.installation })

        assertTrue(LiveUpdates.end(context, installed.installation))
        assertTrue(waitFor { notifications.activeNotifications.none { it.tag == LiveUpdates.NOTIFICATION_TAG && it.id == id } })
        assertNull(LiveUpdates.find(context, installed.installation))
        assertFalse(LiveUpdates.end(context, installed.installation))
    }

    @Test fun liveUpdateRejectsInvalidStateAndUnknownPackages() {
        val installed = install()
        val oversized = LiveUpdates.start(context, installed.installation, """{"detail":"${"d".repeat(5000)}"}""")
        assertFalse(oversized.ok)
        assertFalse(oversized.message!!.contains("ddddd"))
        assertFalse(LiveUpdates.start(context, installed.installation, """{"title":"A","layout":"x"}""").ok)
        assertFalse(LiveUpdates.start(context, installed.installation, """{"progress":9,"total":8}""").ok)
        assertFalse(LiveUpdates.start(context, "00000000-0000-4000-8000-000000000000", "{}").ok)
        assertFalse(LiveUpdates.update(context, installed.installation, "{}").ok)
        assertNull(LiveUpdates.find(context, installed.installation))
    }

    @Test fun aCountdownUsesTheChronometerAndDeletingThePackageEndsTheLiveUpdate() {
        assumeTrue("notifications are disabled for the app", LiveUpdates.notificationsAllowed(context))
        val installed = install()
        val deadline = com.everettjf.scriptwidget.core.system.IsoDates.format(System.currentTimeMillis() + 10 * 60_000L)
        assertTrue(LiveUpdates.start(context, installed.installation, """{"title":"Focus","endsAt":"$deadline"}""").ok)
        assertTrue(waitFor { posted(installed.installation) != null })
        val notification = posted(installed.installation)!!.notification
        assertTrue(notification.extras.getBoolean(android.app.Notification.EXTRA_SHOW_CHRONOMETER))
        assertTrue(notification.extras.getBoolean(android.app.Notification.EXTRA_CHRONOMETER_COUNT_DOWN))
        assertTrue(notification.`when` > System.currentTimeMillis())
        val id = LiveUpdates.find(context, installed.installation)!!.notificationID

        AppServices.library.delete(installed.name)
        LiveUpdates.reconcile(context)
        assertNull(LiveUpdates.find(context, installed.installation))
        assertTrue(waitFor { notifications.activeNotifications.none { it.tag == LiveUpdates.NOTIFICATION_TAG && it.id == id } })
    }
}
