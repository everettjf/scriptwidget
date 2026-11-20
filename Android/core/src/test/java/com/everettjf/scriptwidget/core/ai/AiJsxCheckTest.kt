package com.everettjf.scriptwidget.core.ai

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** The check for tags and attributes ScriptWidget does not have. Mirrors the Swift tests. */
class AiJsxCheckTest {
    private val apple = AiJsxCheck.parseSurface(AiJsxSurfaceData.TEXT, null)

    private fun problems(source: String) = AiJsxCheck.problems(source, AiJsxCheck.ANDROID)

    @Test
    fun aWidgetThatUsesOnlyWhatExistsHasNoProblem() {
        val source = """
            // <nothing here="x"> is a tag
            const title = "a <b c> in a string";
            const wide = count<limit && other < 3;
            ${'$'}render(
              <vstack frame="max" alignment="leading" background="#0a84ff" padding="16" spacing="6" {...extra}>
                <text font="title,bold" weight="bold" fontDesign="rounded" color={dark ? "white" : "black"}>It's {title}</text>
                <date date={new Date()} style="timer" />
                <date date={now} style={"relative"} />
                {rows.map((row) => <hstack key={row.id}><Card title={row.title} flavour="x" /></hstack>)}
                <image systemName="sun.max" mode="fit" clip="circle" />
              </vstack>,
            );
        """.trimIndent()
        assertEquals(emptyList<String>(), problems(source))
        assertNull(AiJsxCheck.summary(source))
    }

    @Test
    fun anAttributeOrValueOrTagThatDoesNotExistIsNamed() {
        val weekday = problems("${'$'}render(<date date={now} style=\"weekday\" />)")
        assertEquals(1, weekday.size)
        assertTrue(weekday[0], weekday[0].contains("style=\"weekday\"") && weekday[0].contains("time, date, relative, offset, timer"))

        val format = problems("${'$'}render(<vstack><date date={now} format=\"EEEE\" /></vstack>)")
        assertTrue(format[0], format[0].contains("<date> has no attribute \"format\"") && format[0].contains("style"))

        val tag = problems("${'$'}render(<row><text>a</text></row>)")
        assertTrue(tag[0], tag[0].contains("<row> is not a ScriptWidget tag") && tag[0].contains("vstack"))

        assertTrue(problems("return <text fontWeight={\"huge\"}>a</text>")[0].contains("fontWeight=\"huge\""))
        assertEquals("a value that is computed is not judged", emptyList<String>(), problems("${'$'}render(<text fontWeight={weight}>a</text>)"))
        assertTrue(AiJsxCheck.summary("${'$'}render(<row/>)")!!.startsWith("The code uses tags or attributes that ScriptWidget does not have:\n- "))
    }

    /** The three spellings the DeepSeek batch run produced, and the rest of the frame grammar. Same text as the Swift test. */
    @Test
    fun aFrameTheRuntimeWouldNotReadIsNamed() {
        val auto = problems("${'$'}render(<vstack><hstack frame=\"max,auto\" spacing=\"6\"><text>a</text></hstack></vstack>)")
        assertEquals(
            listOf(
                "frame=\"max,auto\" on <hstack> is not a frame ScriptWidget reads; it would be ignored or centered. " +
                    "Write it without spaces as one of: \"max\", \"max,leading\", \"60\", \"60,40\", \"60,40,leading\", " +
                    "\"max,40\", \"max,40,leading\", \"60,max\", \"60,max,leading\". The alignments are: center, leading, trailing, top, bottom, " +
                    "topLeading, topTrailing, bottomLeading, bottomTrailing. There is no \"auto\": for a row as wide as the widget " +
                    "and as tall as its content, put a <spacer/> inside an <hstack>.",
            ),
            auto,
        )
        for (read in listOf("max", "max,center", "max,leading", "max,max", "60", "12.5", "0", "36,4", "max,24", "60,max",
            "60,40,topLeading", "max,24,bottomTrailing", "60,max,trailing", "10,,20")) {
            assertTrue(read, AiJsxCheck.frameIsRead(read))
            assertEquals(read, emptyList<String>(), problems("${'$'}render(<vstack frame=\"$read\"></vstack>)"))
        }
        for (dropped in listOf("", "auto", "-4", "max,", "max,auto", "max, leading", "60, 60", "60,leading", "leading,max", "max,max,center",
            "60,40,middle", "60,40,center,top", "full", "100%", "1e3")) {
            assertFalse(dropped, AiJsxCheck.frameIsRead(dropped))
        }
        assertEquals(1, problems("${'$'}render(<vstack frame={\"60, 60\"}></vstack>)").size)
        assertEquals(
            "a value that is computed, or written as a number, is not judged", emptyList<String>(),
            problems("${'$'}render(<vstack frame={side}><circle frame={48} /><spacer frame=\"8\" /></vstack>)"),
        )
        assertEquals(1, problems("${'$'}render(<vstack><hstack frame=\"max,auto\" /><hstack frame=\"max,auto\" /></vstack>)").size)
    }

    @Test
    fun aTagInsideATagWithoutChildrenIsNamed() {
        val nested = problems("${'$'}render(<vstack><text font=\"caption\"><date date=\"now\" style=\"date\" /></text></vstack>)")
        assertEquals(listOf("<text> takes no tags inside it, so the <date> in it is not shown. Put it next to the <text>, not in it."), nested)
        assertEquals(emptyList<String>(), problems("${'$'}render(<vstack><text>{rows.map((row) => <Row />)} a < b</text><text>Plain {value}</text><date date=\"now\" /></vstack>)"))
    }

    @Test
    fun theSameProblemIsReportedOnceAndTheListIsShort() {
        val many = (1..12).joinToString("") { "<text madeUp$it=\"1\">a</text>" } + "<text madeUp1=\"1\">a</text>"
        assertEquals(AiJsxCheck.MAX_PROBLEMS, problems("${'$'}render(<vstack>$many</vstack>)").size)
        assertEquals(1, problems("${'$'}render(<vstack><row/><row/></vstack>)").size)
    }

    @Test
    fun theScrollingListIsATagOnAndroidOnly() {
        val source = "${'$'}render(<list spacing=\"4\"><text>a</text></list>)"
        assertEquals(emptyList<String>(), AiJsxCheck.problems(source, AiJsxCheck.ANDROID))
        assertTrue(AiJsxCheck.problems(source, apple)[0].contains("<list> is not a ScriptWidget tag"))
    }

    private class FakeChat(private val replies: List<String>) : AiChat {
        val conversations = ArrayList<List<AiMessage>>()
        override fun chat(messages: List<AiMessage>, cancellation: AiCancellation): AiChatResult {
            conversations += messages
            return AiChatResult(replies[minOf(conversations.size, replies.size) - 1], AiTokenUsage(10, 5, 15))
        }
    }

    private fun request(maxIterations: Int) = AgentLoopRequest(AgentLoopRequest.Mode.Fresh("the weekday"), AiWidgetSize.MEDIUM, "SYSTEM", maxIterations)

    @Test
    fun theLoopSendsAMadeUpValueBackAlthoughTheWidgetRuns() {
        val wrong = "```jsx\n${'$'}render(<date date={new Date()} style=\"weekday\" />)\n```"
        val right = "```jsx\n${'$'}render(<date date={new Date()} style=\"date\" />)\n```"
        val chat = FakeChat(listOf(wrong, right))
        val ran = ArrayList<String>()
        val outcome = AgentLoop(chat).run(request(4), { source, _ -> ran += source; ValidationResult.success() })
        assertTrue((outcome as AgentLoopOutcome.Succeeded).source.contains("style=\"date\""))
        assertEquals("both ran; running alone would have accepted the first", 2, ran.size)
        assertTrue(chat.conversations[1].last().content.contains("style=\"weekday\" on <date> is not one of its values"))
    }

    @Test
    fun onTheLastAttemptAWidgetThatRunsIsKept() {
        val wrong = "```jsx\n${'$'}render(<date date={new Date()} style=\"weekday\" />)\n```"
        val chat = FakeChat(listOf(wrong))
        val outcome = AgentLoop(chat).run(request(3), { _, _ -> ValidationResult.success() })
        assertTrue(outcome is AgentLoopOutcome.Succeeded)
        assertEquals(3, chat.conversations.size)
    }

    /** Every template, example and Gallery widget in the repository passes: the check must not cry wolf. */
    @Test
    fun everyBundledWidgetPasses() {
        var root = File("").absoluteFile
        while (!File(root, "Shared/ScriptWidgetRuntime/Resource/Script.bundle").isDirectory) root = root.parentFile ?: error("repository root not found")
        val folders = listOf("Shared/ScriptWidgetRuntime/Resource/Script.bundle", "Gallery", "Android/app/src/main/assets/Script.android", "Scripts")
        val files = folders.map { File(root, it) }.filter { it.isDirectory }
            .flatMap { folder -> folder.walkTopDown().filter { it.isFile && it.extension == "jsx" && !it.path.contains("__Build") }.toList() }
        assertTrue("found ${files.size} widgets", files.size > 50)
        val wrong = files.mapNotNull { file ->
            AiJsxCheck.problems(file.readText()).takeIf { it.isNotEmpty() }?.let { "${file.relativeTo(root)}: ${it.joinToString(" | ") { text -> text.take(110) }}" }
        }
        assertEquals(wrong.joinToString("\n"), 0, wrong.size)
    }
}
