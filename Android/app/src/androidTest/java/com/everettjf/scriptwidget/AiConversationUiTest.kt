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
    /** The gate holds back the requests from this one on, counted over the whole test; 1 holds every request. */
    @Volatile private var gateFrom = 1

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
            object : AiChat {
                override fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult = chatStream(messages, cancellation) {}
                // The reply is written out in two pieces, as a model that streams would.
                override fun chatStream(messages: List<AiMessage>, cancellation: AiCancellation, onText: (String) -> Unit): AiChatResult {
                    requests += messages.last().content
                    replies.firstOrNull()?.let { onText(it.take(it.length / 2)) }
                    if (requests.size >= gateFrom) gate?.await(20, TimeUnit.SECONDS)
                    Thread.sleep(400)
                    val reply = replies.removeFirst()
                    onText(reply)
                    return AiChatResult(reply, AiTokenUsage(1200, 180, 1380))
                }
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

    private fun openApp() {
        device.executeShellCommand("am start --activity-clear-task -n ${context.packageName}/${MainActivity::class.java.name}")
        wait(By.desc("New widget"))
    }

    private fun eventually(what: String, seconds: Long = 10, check: () -> Boolean) {
        val end = System.currentTimeMillis() + seconds * 1000
        while (System.currentTimeMillis() < end) { if (check()) return; Thread.sleep(200) }
        assertTrue(what, check())
    }

    /** A widget.json that is there and can not be read turns the conversation off; it is never run as a legacy widget. */
    @Test fun aWidgetWhoseManifestCanNotBeReadIsRefused() {
        // The name sorts first, so that its tile is on screen.
        val broken = AppServices.library.create("0 Broken manifest ${System.nanoTime() % 100_000}", widget("#111827", "Broken"))
        File(broken.directory, "widget.json").writeText("{ not json")
        openApp()
        tap(By.text(broken.name))
        tap(By.text("Improve with AI"))
        wait(By.textContains("widget.json can not be read"))
        picture("40-manifest-unreadable")
        assertTrue("there is no request field", device.findObject(By.clazz("android.widget.EditText")) == null)
        assertTrue("no preview ran the widget as a legacy one", device.findObject(By.desc("Widget preview")) == null)
        assertTrue("nothing was sent", requests.isEmpty())
        assertEquals("the file is left as it was", "{ not json", File(broken.directory, "widget.json").readText())
        assertTrue("no conversation was started", AiServices.conversations(context).latest(broken.installation) == null)
    }

    /**
     * A widget that fails when it runs: the preview says so and offers Fix Runtime Error, which
     * sends what the run reported. Logs shows what the run printed. The repair counts its
     * attempts against the limit of a turn.
     */
    @Test fun aWidgetThatFailsWhenItRunsIsFixedWithWhatTheRunReported() {
        val failing = "console.log(\"reading the stock\");\nconst stock = undefined;\n\$render(\n  <vstack frame=\"max\">\n    <text>{stock.price}</text>\n  </vstack>\n);"
        val item = AppServices.library.create("0 Runtime error ${System.nanoTime() % 100_000}", failing)
        openApp()
        tap(By.text(item.name))
        tap(By.text("Improve with AI"))
        wait(By.text("Fix Runtime Error"))
        picture("30-runtime-error")

        tap(By.desc("More"))
        tap(By.text("Logs"))
        wait(By.text("Logs of the last run"))
        wait(By.textContains("reading the stock"))
        picture("31-logs")
        tap(By.text("Close"))

        // The first answer does not run either; while the repair is awaited the line counts against the four attempts of a turn.
        replies += reply("Shows a dash while there is no price.", "\$render(<vstack>")
        replies += reply("Shows a dash while there is no price.", widget("#0f766e", "No price yet"))
        val first = requests.size
        gate = CountDownLatch(1)
        gateFrom = first + 2
        tap(By.text("Fix Runtime Error"))
        // The line changes its text in place ("Writing…", "Checking…", then this). Looked for at once, it was not
        // found on the Pixel 6 although the picture shows it, so the first look waits until the repair has begun.
        Thread.sleep(2500)
        wait(By.text("It did not run. Fixing it, attempt 2 of 4…"))
        picture("32-attempt-of-limit")
        gate!!.countDown(); gate = null; gateFrom = 1
        wait(By.text("Shows a dash while there is no price."))
        wait(By.text("Fix the current runtime error while keeping the widget's design."))
        assertTrue("the version that runs is not offered a fix", device.wait(Until.gone(By.text("Fix Runtime Error")), 10_000))
        picture("33-fixed")

        val sent = requests[first]
        assertTrue("the request is the fixed sentence", sent.contains("The user now asks:\nFix the current runtime error while keeping the widget's design."))
        assertTrue("the diagnostic is sent", sent.contains("The latest local ScriptWidget runtime diagnostic is:"))
        assertTrue("with what the run printed", sent.contains("reading the stock"))
        assertTrue("and the failing code", sent.contains("stock.price"))
        assertTrue("the widget is untouched until Apply", AppServices.library.find(item.name)!!.files.readText("main.jsx")!!.contains("stock.price"))
    }

    /** Skills chosen in a conversation are sent with its turns and kept in its file; what is enabled in the app does not change. */
    @Test fun theSkillsChosenInAConversationAreSentAndKeptWithIt() {
        val store = GalleryServices.get(context).skills
        val enabled = store.enabledIds()
        val skill = store.list().first { it.id !in enabled }
        fun saved() = AiServices.conversations(context).summaries().singleOrNull()?.let { AiServices.conversations(context).load(it.id) }

        openNewConversation()
        tap(By.desc("More"))
        tap(By.text("Skills"))
        wait(By.text("Skills for this conversation"))
        picture("50-skills")
        tap(By.text(skill.title))
        tap(By.text("Done"))
        replies += reply("A plain card.", widget("#334155", "Hello"))
        ask("A plain card that says hello")
        wait(By.text("A plain card."))
        assertTrue("the Skill is part of the turn", requests.last().contains("Apply these ScriptWidget skills in every turn:") && requests.last().contains("- ${skill.title} v${skill.version}:"))
        eventually("the choice is in the conversation's file") { saved()?.skillIds == (enabled + skill.id).sorted() && saved()?.currentVersion != null }
        assertEquals("choosing in a conversation enables nothing in the app", enabled, store.enabledIds())

        // Taking it out again applies from the next turn.
        tap(By.desc("More"))
        tap(By.text("Skills"))
        wait(By.text("Skills for this conversation"))
        tap(By.text(skill.title))
        tap(By.text("Done"))
        replies += reply("Blue now.", widget("#1d4ed8", "Hello"))
        ask("Make it blue")
        wait(By.text("Blue now."))
        assertTrue("the Skill is no longer sent", !requests.last().contains("- ${skill.title} v${skill.version}:"))
        if (enabled.isEmpty()) assertTrue("no Skill at all is sent", !requests.last().contains("Apply these ScriptWidget skills"))
        eventually("the file holds the new choice") { saved()?.skillIds == enabled.sorted() && saved()?.versions?.size == 2 }
        assertEquals(enabled, store.enabledIds())
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
        assertTrue("the code so far is shown", wait(By.desc("Code being written")).text.contains("render"))
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

        // A small change may come as edit blocks. The version says how many lines it changed, and shows them.
        replies += "SUMMARY: The time reads 12:45.\n```edit\n<<<<<<< SEARCH\n    <text font=\"title\" color=\"white\">12:30</text>\n=======\n" +
            "    <text font=\"title\" color=\"white\">12:45</text>\n>>>>>>> REPLACE\n```"
        ask("Make the time say 12:45")
        wait(By.text("The time reads 12:45."))
        assertTrue("the reply form offers edit blocks", requests.last().contains("<<<<<<< SEARCH"))
        tap(By.descContains("1 lines added, 1 removed"))
        wait(By.textContains("Changes in version"))
        wait(By.textContains("12:45</text>"))
        wait(By.textContains("12:30</text>"))
        picture("15-changes")
        tap(By.text("Close"))
        val edited = AiServices.conversations(context).latest(saved.installation)!!.currentVersion!!.source
        assertTrue("only that line changed", edited.contains("12:45") && !edited.contains("12:30") && edited.contains("#15803d") && edited.contains("example.org"))
        // The widget is drawn at the three sizes under the preview, besides the preview itself.
        assertEquals(4, device.findObjects(By.desc("Widget preview")).size)

        // The editor leads into the same conversation, and shows what was applied when it comes back.
        tap(By.text("Apply to widget"))
        tap(By.text("Apply"))
        wait(By.text("In the widget"))
        device.pressBack()
        tap(By.text("Edit code"))
        wait(By.desc("Improve with AI"))
        picture("16-editor")
        tap(By.desc("Improve with AI"))
        wait(By.text("The time reads 12:45."))
        replies += "SUMMARY: The time reads 13:00.\n```edit\n<<<<<<< SEARCH\n    <text font=\"title\" color=\"white\">12:45</text>\n=======\n" +
            "    <text font=\"title\" color=\"white\">13:00</text>\n>>>>>>> REPLACE\n```"
        ask("Make the time say 13:00")
        wait(By.text("The time reads 13:00."))
        tap(By.text("Apply to widget"))
        tap(By.text("Apply"))
        wait(By.text("In the widget"))
        assertTrue(AppServices.library.find(saved.name)!!.files.readText("main.jsx")!!.contains("13:00"))
        device.pressBack()
        // Back in the editor, with the applied code; leaving it must not write the old code back.
        wait(By.desc("Improve with AI"))
        picture("17-editor-after-apply")
        device.pressBack()
        wait(By.text("Edit code"))
        assertTrue("the editor did not overwrite the applied version", AppServices.library.find(saved.name)!!.files.readText("main.jsx")!!.contains("13:00"))
    }
}
