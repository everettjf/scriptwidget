package com.everettjf.scriptwidget

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.push.Push
import com.everettjf.scriptwidget.push.PushTransport
import com.everettjf.scriptwidget.widget.MediumWidgetProvider
import com.everettjf.scriptwidget.widget.WidgetBinding
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * A real Firebase Cloud Messaging delivery. Runs only on a build with
 * `Android/firebase.properties` and when a wait is passed:
 *
 *     adb shell am instrument -w -e pushWait 300 -e class ...PushDeliveryTest ...
 *
 * The test registers a placed package with the device's real FCM token,
 * saves the token to the app's external files (`push/token.txt`, never to
 * the log) and waits for a message carrying `packageID=com.example.scores`
 * and `channel=scores`, which someone sends to that token meanwhile.
 */
@RunWith(AndroidJUnit4::class)
class PushDeliveryTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val host = AppWidgetHost(context, 4712)
    private val created = ArrayList<String>()
    private val widgetIds = ArrayList<Int>()
    private val originalTransport = Push.transport

    @After fun cleanUp() {
        Push.transport = originalTransport
        Push.onHandled = null
        widgetIds.forEach { host.deleteAppWidgetId(it); AppServices.widgets.remove(it) }
        created.forEach { runCatching { AppServices.library.delete(it) } }
        File(context.getExternalFilesDir(null), "push/token.txt").delete()
    }

    @Test fun aMessageSentThroughFirebaseReachesTheDeviceAndSchedulesThePackagesWidget() {
        val wait = InstrumentationRegistry.getArguments().getString("pushWait")?.toLongOrNull()
        assumeTrue("no pushWait instrumentation argument", wait != null)
        assumeTrue("this build has no Firebase project", Push.configured)
        AppServices.attach(context)
        Push.start(context)

        val manifest = """{"entry":"main.jsx","formatVersion":2,"id":"com.example.scores","name":"Scores","networkDomains":["push.example.com"],"permissions":["network"],"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemMedium"],"version":"1.0.0","pushUpdates":{"registrationURL":"https://push.example.com/register","channel":"scores"}}"""
        val installed = AppServices.library.create("Push Delivery ${System.nanoTime()}", "\$render(<text>scores</text>)", manifest).also { created += it.name }
        val widget = host.allocateAppWidgetId().also { widgetIds += it }
        assumeTrue("grant widget binding first", AppWidgetManager.getInstance(context).bindAppWidgetIdIfAllowed(widget, ComponentName(context, MediumWidgetProvider::class.java)))
        AppServices.widgets.set(widget, WidgetBinding(installed.installation, ""))

        // The real token is registered for the placed package; the post is captured instead of sent to example.com.
        val token = Tasks.await(FirebaseMessaging.getInstance().token, 60, TimeUnit.SECONDS)
        assertTrue("Firebase returned a token", token.length > 50)
        val posted = ArrayList<JSONObject>()
        Push.transport = PushTransport { _, body -> posted += JSONObject(String(body)); 200 }
        context.getSharedPreferences("push", android.content.Context.MODE_PRIVATE).edit().clear().commit()
        assertEquals(1, Push.register(context, token))
        assertEquals(token, posted.single().getString("token"))
        assertEquals("android", posted.single().getString("platform"))
        File(context.getExternalFilesDir(null), "push").apply { mkdirs() }.resolve("token.txt").writeText(token)

        // With the app on screen a message that also carries a notification is handed to the app.
        val delivered = CountDownLatch(1)
        var scheduled = IntArray(0)
        Push.onHandled = { ids -> if (widget in ids) { scheduled = ids; delivered.countDown() } }
        context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        assertTrue("no push for com.example.scores arrived within $wait s", delivered.await(wait!!, TimeUnit.SECONDS))
        assertTrue(widget in scheduled)
    }
}
