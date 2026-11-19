package com.everettjf.scriptwidget

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.BySelector
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.Until
import com.everettjf.scriptwidget.ai.AiServices
import com.everettjf.scriptwidget.core.ai.AiCancellation
import com.everettjf.scriptwidget.core.ai.AiChat
import com.everettjf.scriptwidget.core.ai.AiChatResult
import com.everettjf.scriptwidget.core.ai.AiMessage
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiProviderKind
import com.everettjf.scriptwidget.core.ai.AiTokenUsage
import com.everettjf.scriptwidget.ui.AiConversationViewModel
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * The AI conversation screen, driven the way a person uses it: the real app,
 * the real runtime checking every version, and a scripted model in place of
 * a provider. It proves the screen and the saving, not a live model's output.
 *
 * Each step saves a picture under the app's external files directory
 * (the `ai-conversation` folder) for a person to look at.
 */
@RunWith(AndroidJUnit4::class)
class AiConversationUiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val pictures = File(context.getExternalFilesDir(null), "ai-conversation")
    private val replies = ArrayDeque<String>()
    private val requests = ArrayList<String>()
    /** When set, the next reply waits for it, so that the running state can be looked at. */
    @Volatile private var gate: CountDownLatch? = null

    private var previousKind: AiProviderKind? = null
    private var previousProfile: AiProfile? = null
    private var previousKey: String? = null
    private val created = ArrayList<String>()
    private val before = HashSet<String>()

    @Before fun prepare() {
        AppServices.attach(context)
        pictures.mkdirs()
        File(context.noBackupFilesDir, "ai-conversations").deleteRecursively()
        before += AppServices.library.list().map { it.name }
        // A provider must look set up; the scripted model never sends the key anywhere.
        val settings = AiServices.settings(context)
        previousKind = settings.activeKind
        previousProfile = settings.profile(AiProviderKind.ANTHROPIC)
        previousKey = AiServices.credentials(context).get(AiProviderKind.ANTHROPIC.id)
        settings.activeKind = AiProviderKind.ANTHROPIC
        settings.save(AiProfile.defaults(AiProviderKind.ANTHROPIC), "scripted-model-no-real-key")
        AiConversationViewModel.chatFactory = { _, _ ->
            AiChat { messages: List<AiMessage>, _: AiCancellation ->
                requests += messages.last().content
                gate?.await(20, TimeUnit.SECONDS)
                Thread.sleep(400)
                AiChatResult(replies.removeFirst(), AiTokenUsage(1200, 180, 1380))
            }
        }
    }

    @After fun restore() {
        val settings = AiServices.settings(context)
        previousProfile?.let { settings.save(it, null) }
        val key = previousKey
        if (key != null) AiServices.credentials(context).set(AiProviderKind.ANTHROPIC.id, key) else AiServices.credentials(context).remove(AiProviderKind.ANTHROPIC.id)
        previousKind?.let { settings.activeKind = it }
        for (item in AppServices.library.list()) if (item.name !in before) runCatching { AppServices.library.delete(item.name) }
        File(context.noBackupFilesDir, "ai-conversations").deleteRecursively()
    }

    private fun widget(color: String, title: String, extra: String = "") = "\$render(\n  <vstack frame=\"max\" background=\"$color\" padding=\"16\">\n    <text font=\"title\" color=\"white\">$title</text>\n    <text font=\"caption\" color=\"white\">Tuesday, 3 March</text>$extra\n  </vstack>\n);"

    private fun reply(note: String, code: String, hosts: String? = null) =
        "SUMMARY: $note\n```jsx\n$code\n```" + (hosts?.let { "\n```json\n{\"permissions\":[\"network\"],\"networkDomains\":[\"$it\"]}\n```" } ?: "")

    private fun wait(selector: BySelector, seconds: Long = 20): UiObject2 =
        assertNotNull("not on screen: $selector", device.wait(Until.findObject(selector), seconds * 1000)).let { device.findObject(selector) }

    private fun tap(selector: BySelector) { wait(selector).click(); device.waitForIdle() }

    private fun picture(name: String) { device.waitForIdle(); Thread.sleep(700); device.takeScreenshot(File(pictures, "$name.png")) }

    private fun ask(text: String) {
        wait(By.clazz("android.widget.EditText")).text = text
        tap(By.desc("Send"))
    }

    /** Opens the app at its first screen and goes to a new AI conversation. */
    private fun openNewConversation() {
        // Started the way a launcher does; a start from the test's own context is held back as a background launch.
        device.executeShellCommand("am start --activity-clear-task -n ${context.packageName}/${MainActivity::class.java.name}")
        tap(By.desc("New widget"))
        tap(By.text("Generate with AI"))
        wait(By.text("What should the widget show?"))
    }

    @Test fun aStoppedTurnChangesNothingAndTheDraftIsKept() {
        openNewConversation()
        gate = CountDownLatch(1)
        ask("A big red countdown to Friday")
        wait(By.text("Writing the widget…"))
        tap(By.desc("Stop"))
        wait(By.text("Stopped. The widget is unchanged."))
        gate!!.countDown(); gate = null
        assertTrue("nothing was made", device.findObject(By.text("Save widget")) == null)
        picture("20-stopped")

        // The same request, sent again, runs.
        replies += reply("A red countdown card.", widget("#b91c1c", "3 days"))
        tap(By.text("Send again"))
        wait(By.text("A red countdown card."))
        wait(By.text("Save widget"))

        // Leaving keeps it as a draft, offered the next time.
        tap(By.desc("Back"))
        tap(By.desc("New widget"))
        tap(By.text("Generate with AI"))
        wait(By.text("Continue a draft"))
        picture("21-continue-a-draft")
        tap(By.text("A big red countdown to Friday"))
        wait(By.text("A red countdown card."))
        wait(By.text("shown above"))
        picture("22-draft-reopened")

        tap(By.desc("More"))
        tap(By.text("Delete this draft"))
        wait(By.text("What should the widget show?"))
        assertTrue(AiServices.conversations(context).summaries().isEmpty())
    }

    @Test fun aWidgetIsMadeChangedSavedAndImproved() {
        openNewConversation()
        picture("01-empty")

        // An example fills the field; nothing is sent until Send.
        tap(By.text("Clock"))
        assertTrue(wait(By.clazz("android.widget.EditText")).text.contains("minimalist clock"))
        picture("02-example")

        // The first turn. While the model works there is a Stop button and no version yet.
        replies += reply("A dark clock card with the time and the date.", widget("#1e1b4b", "12:30"))
        gate = CountDownLatch(1)
        tap(By.desc("Send"))
        wait(By.desc("Stop"))
        wait(By.text("Writing the widget…"))
        picture("03-writing")
        gate!!.countDown(); gate = null
        wait(By.text("A dark clock card with the time and the date."))
        wait(By.text("shown above"))
        wait(By.text("Save widget"))
        picture("04-first-version")
        // The request field stays above the keyboard, with the preview still in view.
        wait(By.clazz("android.widget.EditText")).click()
        Thread.sleep(1200)
        picture("04b-keyboard")
        device.pressBack()
        Thread.sleep(800)
        tap(By.text("Medium"))
        picture("04c-medium")
        wait(By.checked(true).hasChild(By.text("Medium")))
        tap(By.text("Small"))

        // A change that does not run at first is repaired, and says so.
        replies += reply("Made the background blue.", "\$render(<vstack>")
        replies += reply("Made the background blue.", widget("#1d4ed8", "12:30"))
        ask("Make the background blue")
        wait(By.text("Fixed automatically 1 time"))
        wait(By.text("Made the background blue."))
        assertTrue("the current code is sent with the request", requests[1].contains("#1e1b4b") && requests[1].contains("Make the background blue"))
        assertTrue("the failure is sent back", requests[2].contains("Your previous code failed to run"))
        picture("05-repaired")

        // A widget that uses the network says which host it contacts.
        replies += reply("Added a line fetched from example.com.", "let line = \"offline\";\ntry { line = (await fetch(\"https://example.com/\")).slice(0, 12); } catch (error) {}\n" + widget("#1d4ed8", "12:30", "\n    <text font=\"caption2\" color=\"white\">{line}</text>"), "example.com")
        ask("Add a line with the first characters of example.com")
        wait(By.text("May contact: example.com"))
        picture("06-network")

        // A change that never runs leaves the widget as it was.
        repeat(4) { replies += reply("Tried a chart.", "\$render(<vstack>") }
        ask("Add a chart of my steps")
        wait(By.text("It did not run, so the widget is unchanged."), 40)
        wait(By.text("Try again"))
        wait(By.text("May contact: example.com"))
        picture("07-did-not-run")

        // Going back to the first version, and saving that one: it uses no network, so nothing is asked.
        tap(By.desc("Previous version"))
        tap(By.desc("Previous version"))
        wait(By.text("1 of 3"))
        assertTrue(device.wait(Until.gone(By.text("May contact: example.com")), 10_000))
        picture("08-older-version")
        tap(By.text("Save widget"))
        wait(By.text("Save as a widget"))
        assertEquals("the suggested name is short", "A minimalist clock widget", wait(By.clazz("android.widget.EditText")).text)
        picture("09-name")
        tap(By.text("OK"))
        wait(By.text("Improve with AI"))
        val saved = AppServices.library.list().single { it.name !in before }
        created += saved.name
        assertTrue(saved.files.readText("main.jsx")!!.contains("#1e1b4b"))
        assertEquals("a widget that uses no network gets no permission", 0, saved.permissions.size)
        assertNotNull("the conversation follows the widget", AiServices.conversations(context).latest(saved.installation))
        picture("10-saved")

        // The widget's own screen leads back into the same conversation.
        tap(By.text("Improve with AI"))
        // The list opens at its newest turn.
        wait(By.text("It did not run, so the widget is unchanged."))
        wait(By.text("In the widget"))
        picture("11-improve")

        // The AI works on a copy; the widget changes when Apply is confirmed, and gains the host then.
        replies += reply("Green now, with a line from example.org.", "let line = \"offline\";\ntry { line = (await fetch(\"https://example.org/\")).slice(0, 12); } catch (error) {}\n" + widget("#15803d", "12:30", "\n    <text font=\"caption2\" color=\"white\">{line}</text>"), "example.org")
        ask("Make it green and add a line from example.org")
        wait(By.text("Apply to widget"))
        assertTrue("the widget is untouched until Apply", AppServices.library.find(saved.name)!!.files.readText("main.jsx")!!.contains("#1e1b4b"))
        picture("12-not-applied")
        tap(By.text("Apply to widget"))
        wait(By.text("Allow and apply"))
        picture("13-confirm-apply")
        tap(By.text("Allow and apply"))
        wait(By.text("In the widget"))
        val applied = AppServices.library.find(saved.name)!!
        assertTrue(applied.files.readText("main.jsx")!!.contains("#15803d"))
        assertTrue(applied.files.readText("widget.json")!!.contains("example.org"))
        assertEquals(listOf("network"), applied.permissions)
        picture("14-applied")
    }
}
