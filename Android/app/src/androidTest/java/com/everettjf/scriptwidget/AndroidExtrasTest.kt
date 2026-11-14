package com.everettjf.scriptwidget

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.automation.AutomationReceiver
import com.everettjf.scriptwidget.automation.AutomationStore
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.surfaces.Automation
import com.everettjf.scriptwidget.core.surfaces.AutomationFailure
import com.everettjf.scriptwidget.widget.WidgetLists
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * What only Android has, against the real runtime: the automation entry
 * point, scrolling lists and the bundled Android-only templates.
 */
@RunWith(AndroidJUnit4::class)
class AndroidExtrasTest {
    private val context: Context = InstrumentationRegistry.getInstrumentation().targetContext
    private val store = AutomationStore(context)
    private val created = ArrayList<InstalledPackage>()
    private var wasEnabled = false
    private var wasAllowed = emptySet<String>()

    @Before fun remember() {
        AppServices.attach(context)
        wasEnabled = store.enabled
        wasAllowed = store.allowedPackages()
    }

    @After fun restore() {
        for (installed in created) {
            store.setAllowed(installed.installation, false)
            runCatching { AppServices.library.delete(installed.name) }
        }
        // The user's own choice and token are left as they were.
        if (store.enabled != wasEnabled) store.enabled = wasEnabled
        assertEquals(wasAllowed, store.allowedPackages())
    }

    private fun template(name: String): InstalledPackage =
        AppServices.library.installBundled(AppServices.library.bundled().first { it.group == "android" && it.name == name }).also { created += it }

    /** Sends an ordered broadcast to the entry point and returns its result code and message. */
    private fun send(action: String, vararg extras: Pair<String, String>): Pair<Int, String?> {
        val intent = Intent(context.packageName + action).setClass(context, AutomationReceiver::class.java)
        for ((name, value) in extras) intent.putExtra(name, value)
        val done = CountDownLatch(1)
        var code = Int.MIN_VALUE
        var data: String? = null
        context.sendOrderedBroadcast(intent, null, object : BroadcastReceiver() {
            override fun onReceive(context: Context, intent: Intent) { code = resultCode; data = resultData; done.countDown() }
        }, null, Int.MIN_VALUE, null, null)
        assertTrue("the request was answered", done.await(15, TimeUnit.SECONDS))
        return code to data
    }

    private fun count(installed: InstalledPackage) = AppServices.runtime.storage.getString(installed.installation, "counter.value")

    @Test fun theStoreStartsClosedAndCreatesATokenWhenTurnedOn() {
        store.enabled = true
        val token = store.token
        assertTrue(Automation.isValidToken(token))
        store.enabled = false
        store.enabled = true
        assertEquals("turning it off and on keeps the token", token, store.token)
        if (!wasEnabled) {
            // Only when the user had not set one up: a new token replaces the old one.
            val renewed = store.renewToken()
            assertNotEquals(token, renewed)
            assertEquals(renewed, store.token)
        }
    }

    @Test fun aRequestRunsADeclaredActionOnlyWithTheTokenAndAnAllowedPackage() {
        val installed = template("Automation Counter")
        store.enabled = true
        val token = store.token!!
        val run = Automation.ACTION_RUN

        assertEquals(Activity.RESULT_CANCELED to AutomationFailure.PACKAGE_NOT_ALLOWED.message, send(run, "package" to installed.name, "action" to "increment", "token" to token))
        assertEquals("", count(installed))

        store.setAllowed(installed.installation, true)
        assertEquals(Activity.RESULT_CANCELED to AutomationFailure.WRONG_TOKEN.message, send(run, "package" to installed.name, "action" to "increment", "token" to "0".repeat(32)))
        assertEquals(Activity.RESULT_CANCELED to AutomationFailure.INVALID_REQUEST.message, send(run, "package" to installed.name, "action" to "increment"))
        assertEquals(Activity.RESULT_CANCELED to AutomationFailure.PACKAGE_NOT_FOUND.message, send(run, "package" to "../${installed.name}", "action" to "increment", "token" to token))
        assertEquals(Activity.RESULT_CANCELED, send(run, "package" to installed.name, "action" to "write", "token" to token).first)
        assertEquals("nothing ran so far", "", count(installed))

        assertEquals(Activity.RESULT_OK to "OK", send(run, "package" to installed.name, "action" to "increment", "token" to token))
        assertEquals(Activity.RESULT_OK to "OK", send(run, "package" to installed.name, "action" to "INCREMENT", "token" to token))
        assertEquals("2", count(installed))
        assertEquals("automation", AppServices.runtime.storage.getString(installed.installation, "counter.source"))
        assertEquals(Activity.RESULT_OK to "OK", send(run, "package" to installed.name, "action" to "reset", "token" to token))
        assertEquals("0", count(installed))

        assertEquals(Activity.RESULT_OK to "OK", send(Automation.ACTION_REFRESH, "package" to installed.name, "token" to token))
        assertEquals(Activity.RESULT_OK to "OK", send(Automation.ACTION_REFRESH, "token" to token))
        assertEquals("a refresh runs no action", "0", count(installed))

        store.enabled = false
        assertEquals(Activity.RESULT_CANCELED to AutomationFailure.DISABLED.message, send(run, "package" to installed.name, "action" to "increment", "token" to token))
        assertEquals("0", count(installed))
    }

    @Test fun listTapsAreLookedUpInWhatTheAppSaved() {
        val installed = template("Scrolling Checklist")
        val runtime = AppServices.runtime
        val request = RunRequest(installed.files, installed.installation, "large", buildDirectory = installed.buildDirectory)
        val result = runtime.run(request)
        assertNull(result.execution.error)
        val output = runtime.render(request, result, 373f, 415f, 2f, liveLists = true)
        val slot = output.listSlots.single()
        assertFalse(slot.truncated)

        val update = WidgetLists.Update()
        val items = WidgetLists.items(context, WidgetLists.Drawn(slot, null), update)
        assertEquals(slot.pieces.size, items.itemCount)
        assertEquals("one tap per row", 20, update.taps.length())
        assertTrue("row images are passed by reference, not copied into the update: ${update.inlineBytes}", update.inlineBytes < 64 * 1024)

        val widget = 987_654
        try {
            WidgetLists.saveTaps(context, widget, update)
            val third = WidgetLists.interaction(context, widget, 3)
            assertNotNull(third)
            assertEquals("toggle", third!!.getString("type"))
            assertEquals("check.3", third.getString("stateKey"))
            // Numbers a launcher could make up lead nowhere.
            assertNull(WidgetLists.interaction(context, widget, 20))
            assertNull(WidgetLists.interaction(context, widget, -1))
            assertNull(WidgetLists.interaction(context, widget, Int.MAX_VALUE))
            assertNull(WidgetLists.interaction(context, widget + 1, 3))
        } finally {
            WidgetLists.remove(context, widget)
        }
        assertNull(WidgetLists.interaction(context, widget, 3))
    }

    @Test fun theAndroidOnlyTemplatesRunAndDeclareWhatTheyUse() {
        val bundled = AppServices.library.bundled().filter { it.group == "android" }
        assertEquals(listOf("Automation Counter", "Scrolling Checklist", "Wallpaper Colors"), bundled.map { it.name })
        for (item in bundled) {
            val installed = AppServices.library.installBundled(item).also { created += it }
            AppServices.validatePackage(installed.files)
            for (family in listOf("small", "medium", "large")) {
                val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation, family, buildDirectory = installed.buildDirectory))
                assertNull("${item.name} $family: ${result.execution.error?.message}", result.execution.error)
                assertNotNull(result.execution.tree)
            }
        }
    }
}
