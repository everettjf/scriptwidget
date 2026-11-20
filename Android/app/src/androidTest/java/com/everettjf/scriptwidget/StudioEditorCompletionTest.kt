package com.everettjf.scriptwidget

import android.view.KeyEvent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import org.junit.After
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The code editor, typed into the way a person does: the real app, a new blank widget, the
 * Studio editor in its WebView. It proves that the editor offers what only Android has, the
 * `<list>` tag and the `material.<role>` colors, which `android-bridge.js` describes to it.
 *
 * Pictures are saved under the app's external files directory (the `editor-completion` folder).
 */
@RunWith(AndroidJUnit4::class)
class StudioEditorCompletionTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val pictures = File(context.getExternalFilesDir(null), "editor-completion")
    private val name = "Editor Completion ${System.currentTimeMillis() % 100000}"

    @Before fun prepare() {
        AppServices.attach(context)
        pictures.mkdirs()
    }

    @After fun remove() {
        runCatching { AppServices.library.delete(name) }
        device.pressHome()
    }

    private fun wait(selector: BySelector, seconds: Long = 20): UiObject2 {
        val found = device.wait(Until.findObject(selector), seconds * 1000)
        if (found == null) picture("not-on-screen")
        assertNotNull("not on screen: $selector", found)
        return device.findObject(selector)
    }

    private fun tap(selector: BySelector) { wait(selector).click(); device.waitForIdle() }

    private fun picture(name: String) { device.waitForIdle(); Thread.sleep(500); device.takeScreenshot(File(pictures, "$name.png")) }

    /** Types into whatever has the focus; `%s` is a space. */
    private fun type(text: String) { device.executeShellCommand("input text $text"); device.waitForIdle() }

    @Test fun theListTagAndTheMaterialColorsAreOffered() {
        // Started the way a launcher does; a start from the test's own context is held back as a background launch.
        device.executeShellCommand("am start --activity-clear-task -n ${context.packageName}/${MainActivity::class.java.name}")
        tap(By.desc("New widget"))
        tap(By.text("Blank widget"))
        wait(By.clazz("android.widget.EditText")).text = name
        tap(By.text("OK"))

        // The editor shows the new widget's code. A tap gives it the focus and brings the keyboard up,
        // which leaves only a few lines in view; the cursor goes to the first line, where the list of
        // completions has room to show.
        wait(By.textContains("Hello, ScriptWidget"), 30)
        val editor = wait(By.clazz("android.webkit.WebView"))
        val bounds = editor.visibleBounds
        device.click(bounds.centerX(), bounds.top + bounds.height() * 2 / 5)
        device.waitForIdle()
        Thread.sleep(1200)
        device.pressKeyCode(KeyEvent.KEYCODE_MOVE_HOME, KeyEvent.META_CTRL_ON)
        device.waitForIdle()

        // What is offered is judged by what Enter writes: only "<li" and "material.onSurfaceV" are typed,
        // so "<list>" and "material.onSurfaceVariant" in the saved file came from the completions. The
        // lists themselves are in the pictures; the WebView does not report them reliably to a test.
        type("<li")
        picture("01-list-offered")
        device.pressEnter()
        device.waitForIdle()

        // On a line of its own, so that the value and its list stay inside the narrow screen.
        device.pressEnter()
        device.waitForIdle()
        type("<text%scolor=\"material.onSurfaceV")
        picture("02-material-color-offered")
        device.pressEnter()
        device.waitForIdle()
        picture("03-accepted")

        // Leaving saves; the file holds what the two completions wrote.
        device.pressBack()
        device.waitForIdle()
        val deadline = System.currentTimeMillis() + 10_000
        var source = ""
        while (System.currentTimeMillis() < deadline) {
            source = AppServices.library.find(name)?.files?.readText("main.jsx").orEmpty()
            if (source.contains("material.onSurfaceVariant")) break
            device.pressBack()
            Thread.sleep(500)
        }
        assertTrue(source, source.contains("<list>") && source.contains("</list>"))
        assertTrue(source, source.contains("<text color=\"material.onSurfaceVariant"))
    }
}
