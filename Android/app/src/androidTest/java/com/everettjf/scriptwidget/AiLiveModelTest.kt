package com.everettjf.scriptwidget

import android.graphics.Bitmap
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.ai.AiServices
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.ai.AgentLoop
import com.everettjf.scriptwidget.core.ai.AgentLoopEvent
import com.everettjf.scriptwidget.core.ai.AgentLoopOutcome
import com.everettjf.scriptwidget.core.ai.AgentLoopRequest
import com.everettjf.scriptwidget.core.ai.AiClient
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiProviderKind
import com.everettjf.scriptwidget.core.ai.AiSettings
import com.everettjf.scriptwidget.core.ai.AiWidgetSize
import com.everettjf.scriptwidget.core.ai.PromptBuilder
import com.everettjf.scriptwidget.core.ai.ValidationResult
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * AI generation against the real provider, over the app's own HTTPS
 * transport. Runs only when a key is passed to the instrumentation:
 *
 *     adb shell am instrument -w -e aiKey <key> [-e aiModel <id>] -e class ...AiLiveModelTest ...
 *
 * The key lives in memory for the run; it is never written to the device,
 * to a log or into an assertion message.
 */
@RunWith(AndroidJUnit4::class)
class AiLiveModelTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val arguments = InstrumentationRegistry.getArguments()
    private val key = arguments.getString("aiKey").orEmpty()
    private val model = arguments.getString("aiModel") ?: "claude-fable-5-2"
    private val settings get() = AiSettings(AiProfile(AiProviderKind.ANTHROPIC, "https://api.anthropic.com", model), maxIterations = 5)
    private val created = ArrayList<String>()

    @Before fun start() {
        assumeTrue("no aiKey instrumentation argument", key.isNotEmpty())
        AppServices.attach(context)
    }

    @After fun stop() {
        created.forEach { runCatching { AppServices.library.delete(it) } }
    }

    private fun validate(source: String, manifestJson: String?): ValidationResult {
        val result = AppServices.runtime.run(RunRequest(MemoryPackageFiles(mapOf("main.jsx" to source)), "ai-live-test")).execution
        return ValidationResult.fromExecution(result.tree, result.error?.kind, result.error?.message, result.logs.map { it.message })
    }

    private fun generate(mode: AgentLoopRequest.Mode, size: AiWidgetSize, apiKey: String = key): Pair<AgentLoopOutcome, List<String>> {
        val events = ArrayList<String>()
        val outcome = AgentLoop(AiClient().bind(settings, apiKey)).run(
            AgentLoopRequest(mode, size, PromptBuilder.systemPrompt(AiServices.reference(context)), 5),
            validate = ::validate,
            onEvent = { event -> events += event.javaClass.simpleName + if (event is AgentLoopEvent.RanFailed) ":" + event.errorSummary.take(80) else "" },
        )
        return outcome to events
    }

    /** Installs the accepted source, draws it and saves the picture for inspection. */
    private fun draw(name: String, source: String, width: Float, height: Float): Bitmap {
        val installed = AppServices.library.create("AI Live Test ${System.nanoTime()}", source).also { created += it.name }
        val request = RunRequest(installed.files, installed.installation, buildDirectory = installed.buildDirectory)
        val result = AppServices.runtime.run(request)
        assertTrue("the installed widget runs: ${result.execution.error?.message}", result.execution.error == null)
        val bitmap = AppServices.runtime.render(request, result, width, height, 2f).bitmap
        File(context.getExternalFilesDir(null), "ai-live").apply { mkdirs() }.resolve("$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
        File(context.getExternalFilesDir(null), "ai-live").resolve("$name.jsx").writeText(source)
        return bitmap
    }

    /** More than one colour: the widget drew something, not a blank or a flat card. */
    private fun distinctColours(bitmap: Bitmap): Int {
        val seen = HashSet<Int>()
        for (y in 0 until bitmap.height step 4) for (x in 0 until bitmap.width step 4) seen += bitmap.getPixel(x, y)
        return seen.size
    }

    @Test fun aRealModelWritesAWidgetThatRunsAndDrawsOnTheDevice() {
        val (outcome, events) = generate(
            AgentLoopRequest.Mode.Fresh("A countdown to New Year's Day with a large number of days left, a small caption, and a blue to purple gradient background"),
            AiWidgetSize.MEDIUM,
        )
        assertTrue("outcome ${outcome.javaClass.simpleName} ${(outcome as? AgentLoopOutcome.Failed)?.message.orEmpty()}, events $events", outcome is AgentLoopOutcome.Succeeded)
        outcome as AgentLoopOutcome.Succeeded
        assertTrue("the provider reported token usage", outcome.usage.promptTokens > 0 && outcome.usage.completionTokens > 0)
        assertTrue(outcome.source.contains("\$render"))
        assertFalse(outcome.source.contains(key))
        assertTrue("the widget draws more than a flat colour", distinctColours(draw("countdown", outcome.source, 330f, 160f)) > 8)
    }

    @Test fun aRealModelRefinesAnExistingWidget() {
        val current = "\$render(<vstack frame=\"max\" background=\"#0f172a\"><text color=\"white\" font=\"title3\">Hello</text></vstack>);"
        val (outcome, events) = generate(
            AgentLoopRequest.Mode.Refine(current, "Change the greeting to exactly \"Hello Android\" and make the background #14532d"),
            AiWidgetSize.SMALL,
        )
        assertTrue("outcome ${outcome.javaClass.simpleName} ${(outcome as? AgentLoopOutcome.Failed)?.message.orEmpty()}, events $events", outcome is AgentLoopOutcome.Succeeded)
        outcome as AgentLoopOutcome.Succeeded
        assertTrue(outcome.source, outcome.source.contains("Hello Android"))
        val bitmap = draw("refine", outcome.source, 160f, 160f)
        assertTrue("background ${Integer.toHexString(bitmap.getPixel(4, 4))}", bitmap.getPixel(4, 4) == 0xFF14532D.toInt())
    }

    @Test fun aRejectedKeyFailsWithAMessageThatDoesNotContainIt() {
        val wrong = "sk-ant-not-a-valid-key-0000"
        val (outcome, _) = generate(AgentLoopRequest.Mode.Fresh("anything"), AiWidgetSize.SMALL, wrong)
        assertTrue(outcome.javaClass.simpleName, outcome is AgentLoopOutcome.Failed)
        val message = (outcome as AgentLoopOutcome.Failed).message
        assertTrue(message, message.isNotBlank())
        assertFalse(message.contains(wrong))
    }
}
