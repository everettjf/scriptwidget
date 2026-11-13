package com.everettjf.scriptwidget

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.graphics.drawable.BitmapDrawable
import android.view.View
import android.view.ViewGroup
import android.widget.Chronometer
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.widget.MediumWidgetProvider
import com.everettjf.scriptwidget.widget.SmallWidgetProvider
import com.everettjf.scriptwidget.widget.WidgetBinding
import com.everettjf.scriptwidget.widget.WidgetUpdater
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Binds real app widgets through an AppWidgetHost and inflates the
 * RemoteViews the updater sends, the way a launcher does. Needs
 * `adb shell appwidget grantbind --package com.everettjf.scriptwidget --user 0`
 * once (scripts/device-test.sh does it).
 */
@RunWith(AndroidJUnit4::class)
class WidgetHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val manager = AppWidgetManager.getInstance(context)
    private val host = AppWidgetHost(context, 4711)
    private val created = ArrayList<String>()
    private val widgetIds = ArrayList<Int>()

    @Before fun attach() { AppServices.attach(context) }

    @After fun cleanUp() {
        widgetIds.forEach { host.deleteAppWidgetId(it); AppServices.widgets.remove(it) }
        created.forEach { runCatching { AppServices.library.delete(it) } }
    }

    private fun install(source: String, manifest: String? = null): InstalledPackage =
        AppServices.library.create("Host Test ${System.nanoTime()}", source, manifest).also { created += it.name }

    private fun place(installed: InstalledPackage, provider: Class<*> = MediumWidgetProvider::class.java, parameter: String = ""): Int {
        val id = host.allocateAppWidgetId()
        widgetIds += id
        assumeTrue("grant widget binding first: adb shell appwidget grantbind --package ${context.packageName} --user 0",
            manager.bindAppWidgetIdIfAllowed(id, ComponentName(context, provider)))
        AppServices.widgets.set(id, WidgetBinding(installed.installation, parameter))
        return id
    }

    /** Inflates what the launcher would show. */
    private fun inflate(id: Int): View {
        val views = WidgetUpdater.update(context, id)
        assertNotNull(views)
        lateinit var view: View
        instrumentation.runOnMainSync { view = views!!.apply(context, FrameLayout(context)) }
        return view
    }

    private fun children(view: View, id: Int): List<View> = (view.findViewById<ViewGroup>(id)).let { group -> List(group.childCount) { group.getChildAt(it) } }

    private fun manifest(permissions: String = "[]", extra: String = "") =
        """{"entry":"main.jsx","formatVersion":2,"id":"com.example.hosttest","name":"Host Test","networkDomains":[],"permissions":$permissions,"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall","systemMedium"],"version":"1.0.0"$extra}"""

    @Test fun drawsABitmapAndOpensTheAppWhenThereAreNoTapTargets() {
        val id = place(install("""${'$'}render(<vstack frame="max" background="#2563eb"><text color="white">{${'$'}getenv("widget-size") + ":" + ${'$'}getenv("widget-param")}</text></vstack>)"""), parameter = "hello")
        val view = inflate(id)
        val bitmap = (view.findViewById<ImageView>(R.id.widget_image).drawable as BitmapDrawable).bitmap
        assertTrue(bitmap.width > 100 && bitmap.height > 50)
        // The background color reached the bitmap.
        assertEquals(0xFF2563EB.toInt(), bitmap.getPixel(4, bitmap.height / 2))
        assertEquals(0, children(view, R.id.widget_overlay).size)
        assertTrue(view.findViewById<View>(R.id.widget_image).hasOnClickListeners())
    }

    @Test fun smallProviderReportsTheSmallFamily() {
        val id = place(install("""${'$'}render(<text>{${'$'}getenv("widget-size")}</text>)"""), SmallWidgetProvider::class.java)
        inflate(id)
        assertEquals("small", com.everettjf.scriptwidget.widget.ScriptWidgetProvider.family(context, id))
    }

    @Test fun tappingAButtonRunsItsFunctionAndRedraws() {
        val source = """
            const count = Number(${'$'}storage.getString("count") || "0");
            function bump() { ${'$'}storage.setString("count", String(count + 1)); }
            ${'$'}render(<vstack frame="max"><text>{"count " + count}</text><button onClick="bump"><text>Add</text></button></vstack>)
        """
        val installed = install(source)
        val id = place(installed)
        val view = inflate(id)
        val targets = children(view, R.id.widget_overlay)
        assertEquals(1, targets.size)
        instrumentation.runOnMainSync { targets[0].performClick() }
        waitFor { AppServices.runtime.storage.getString(installed.installation, "count") == "1" }
        assertEquals("1", AppServices.runtime.storage.getString(installed.installation, "count"))
    }

    @Test fun tappingAToggleSavesItsStateAndRunsTheDeclaredAction() {
        val source = """
            const on = ${'$'}storage.getString("lamp") === "true";
            function setLamp() { ${'$'}storage.setString("seen", ${'$'}getenv("action-value") + "/" + ${'$'}getenv("action-id") + "/" + ${'$'}getenv("action-source")); }
            ${'$'}render(<vstack frame="max"><toggle on={on} actionID="lamp" stateKey="lamp"><text>Lamp</text></toggle></vstack>)
        """
        val actions = ""","actions":[{"id":"lamp","title":"Lamp","systemImage":"lightbulb","function":"setLamp"}]"""
        val installed = install(source, manifest("[\"storage\"]", actions))
        val id = place(installed)
        val targets = children(inflate(id), R.id.widget_overlay)
        assertEquals(1, targets.size)
        instrumentation.runOnMainSync { targets[0].performClick() }
        waitFor { AppServices.runtime.storage.getString(installed.installation, "seen").isNotEmpty() }
        assertEquals("true", AppServices.runtime.storage.getString(installed.installation, "lamp"))
        assertEquals("true/lamp/widget", AppServices.runtime.storage.getString(installed.installation, "seen"))
    }

    @Test fun linksBecomeTapTargetsInsideTheWidgetBounds() {
        val id = place(install("""${'$'}render(<hstack frame="max"><link url="https://example.com/a"><text>A</text></link><spacer/><link url="https://example.com/b"><text>B</text></link></hstack>)"""))
        val view = inflate(id)
        val targets = children(view, R.id.widget_overlay)
        assertEquals(2, targets.size)
        assertTrue(targets.all { it.hasOnClickListeners() })
        val first = targets[0].layoutParams as FrameLayout.LayoutParams
        val second = targets[1].layoutParams as FrameLayout.LayoutParams
        assertTrue("targets are placed left and right", first.leftMargin < second.leftMargin)
    }

    @Test fun runningTimersAreChronometersNotPixels() {
        val id = place(install("""${'$'}render(<vstack frame="max"><date date={Date.now() + 600000} style="timer" font="title" /></vstack>)"""))
        val live = children(inflate(id), R.id.widget_dynamic)
        assertEquals(1, live.size)
        assertTrue(live[0] is Chronometer)
        assertTrue((live[0] as Chronometer).isCountDown)
    }

    @Test fun scriptErrorsBecomeAVisibleCardNotABlankWidget() {
        val id = place(install("""const broken = ; ${'$'}render(<text>never</text>)"""))
        val view = inflate(id)
        val bitmap = (view.findViewById<ImageView>(R.id.widget_image).drawable as BitmapDrawable).bitmap
        // The error card's light red background.
        assertEquals(0xFFFEF2F2.toInt(), bitmap.getPixel(2, 2))
    }

    @Test fun aWidgetWhosePackageWasDeletedAsksToChooseAgain() {
        val installed = install("""${'$'}render(<text>soon gone</text>)""")
        val id = place(installed)
        AppServices.library.delete(installed.name)
        created.remove(installed.name)
        val message = inflate(id).findViewById<TextView>(R.id.widget_message)
        assertEquals(context.getString(R.string.widget_missing), message.text.toString())
    }

    @Test fun bitmapsStayInsideTheAndroid17Budget() {
        val id = place(install("""${'$'}render(<vstack frame="max" background="#111827"><text color="white">budget</text></vstack>)"""))
        val view = inflate(id)
        val bitmap = (view.findViewById<ImageView>(R.id.widget_image).drawable as BitmapDrawable).bitmap
        val metrics = context.resources.displayMetrics
        val budget = metrics.widthPixels.toLong() * metrics.heightPixels * 6L
        assertTrue("one size uses ${bitmap.allocationByteCount} of $budget", bitmap.allocationByteCount * 2L < budget)
    }

    private fun waitFor(condition: () -> Boolean) {
        val deadline = System.currentTimeMillis() + 10_000
        while (System.currentTimeMillis() < deadline && !condition()) Thread.sleep(100)
    }
}
