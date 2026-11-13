package com.everettjf.scriptwidget

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.ai.AiServices
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.ai.AgentLoop
import com.everettjf.scriptwidget.core.ai.AgentLoopEvent
import com.everettjf.scriptwidget.core.ai.AgentLoopOutcome
import com.everettjf.scriptwidget.core.ai.AgentLoopRequest
import com.everettjf.scriptwidget.core.ai.AiClient
import com.everettjf.scriptwidget.core.ai.AiHttpResponse
import com.everettjf.scriptwidget.core.ai.AiProfile
import com.everettjf.scriptwidget.core.ai.AiProviderKind
import com.everettjf.scriptwidget.core.ai.AiSettings
import com.everettjf.scriptwidget.core.ai.AiTransport
import com.everettjf.scriptwidget.core.ai.AiWidgetSize
import com.everettjf.scriptwidget.core.ai.PromptBuilder
import com.everettjf.scriptwidget.core.ai.ValidationResult
import com.everettjf.scriptwidget.core.runtime.MemoryPackageFiles
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import kotlin.concurrent.thread

/**
 * The AI generation loop on a device: a real HTTP exchange with a local
 * server that answers like the Anthropic Messages API, and validation of
 * each candidate by the real runtime. The model itself is scripted, so this
 * proves the loop, the request format and the on-device validation, not the
 * quality of a live model's output.
 */
@RunWith(AndroidJUnit4::class)
class AiLoopOnDeviceTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private lateinit var server: ServerSocket
    private val requests = ArrayList<JSONObject>()
    private val headers = ArrayList<String>()
    private val replies = ArrayDeque<String>()
    private val created = ArrayList<String>()

    @Before fun start() {
        AppServices.attach(context)
        server = ServerSocket(0, 8, InetAddress.getLoopbackAddress())
        thread(isDaemon = true, name = "fake-model") {
            while (!server.isClosed) {
                val socket = runCatching { server.accept() }.getOrNull() ?: break
                socket.use { serve(it) }
            }
        }
    }

    @After fun stop() {
        server.close()
        created.forEach { runCatching { AppServices.library.delete(it) } }
    }

    /** Reads one HTTP request and answers with the next scripted model reply. */
    private fun serve(socket: Socket) {
        val input = socket.getInputStream().buffered()
        val head = StringBuilder()
        while (!head.endsWith("\r\n\r\n")) { val byte = input.read(); if (byte < 0) return; head.append(byte.toChar()) }
        val length = Regex("(?i)content-length: (\\d+)").find(head)?.groupValues?.get(1)?.toInt() ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) { val count = input.read(body, read, length - read); if (count < 0) break; read += count }
        synchronized(requests) { requests += JSONObject(body.toString(Charsets.UTF_8)); headers += head.toString() }
        val text = replies.removeFirstOrNull() ?: "no more replies"
        val reply = JSONObject().put("content", JSONArray().put(JSONObject().put("type", "text").put("text", text))).put("stop_reason", "end_turn")
            .put("usage", JSONObject().put("input_tokens", 100).put("output_tokens", 50)).toString().toByteArray()
        socket.getOutputStream().apply {
            write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${reply.size}\r\nConnection: close\r\n\r\n".toByteArray())
            write(reply); flush()
        }
    }

    /** Sends the client's request over a real socket to the local server instead of the provider's host. */
    private val transport = AiTransport { request, _ ->
        Socket(InetAddress.getLoopbackAddress(), server.localPort).use { socket ->
            val body = request.body ?: ByteArray(0)
            val head = StringBuilder("${request.method} ${java.net.URI(request.url).rawPath} HTTP/1.1\r\nHost: localhost\r\nContent-Length: ${body.size}\r\nConnection: close\r\n")
            for ((name, value) in request.headers) head.append("$name: $value\r\n")
            socket.getOutputStream().apply { write(head.append("\r\n").toString().toByteArray()); write(body); flush() }
            val raw = socket.getInputStream().readBytes()
            val split = raw.toString(Charsets.ISO_8859_1).indexOf("\r\n\r\n")
            AiHttpResponse(raw.toString(Charsets.ISO_8859_1).substringAfter(' ').take(3).toInt(), raw.copyOfRange(split + 4, raw.size))
        }
    }

    /** The same judgement the app applies: compile and execute the candidate in the real runtime. */
    private fun validate(source: String, manifestJson: String?): ValidationResult {
        val files = MemoryPackageFiles(mapOf("main.jsx" to source))
        val result = AppServices.runtime.run(RunRequest(files, "ai-loop-test")).execution
        return ValidationResult.fromExecution(result.tree, result.error?.kind, result.error?.message, result.logs.map { it.message })
    }

    @Test fun aBrokenFirstAnswerIsFedBackAndTheFixedAnswerRendersOnTheDevice() {
        replies += "```jsx\nconst label = ;\n\$render(<text>{label}</text>);\n```"
        replies += "```jsx\n\$render(<vstack frame=\"max\" background=\"#0f172a\"><text color=\"white\" font=\"title3\">Fixed by the model</text></vstack>);\n```"
        val settings = AiSettings(AiProfile(AiProviderKind.ANTHROPIC, "https://api.anthropic.com", "claude-fable-5-2"), maxIterations = 5)
        val secret = "sk-test-not-a-real-key"
        val loop = AgentLoop(AiClient(transport).bind(settings, secret))
        val events = ArrayList<String>()
        val outcome = loop.run(
            AgentLoopRequest(AgentLoopRequest.Mode.Fresh("A dark card that says the widget was fixed"), AiWidgetSize.MEDIUM, PromptBuilder.systemPrompt(AiServices.reference(context)), 5),
            validate = ::validate,
            onEvent = { event -> events += event.javaClass.simpleName + if (event is AgentLoopEvent.RanFailed) ":" + event.errorSummary.take(60) else "" },
        )
        assertTrue("outcome ${outcome.javaClass.simpleName}, events $events", outcome is AgentLoopOutcome.Succeeded)
        outcome as AgentLoopOutcome.Succeeded
        assertTrue(outcome.source.contains("Fixed by the model"))
        assertEquals("two model calls", 2, requests.size)
        assertEquals(1, events.count { it.startsWith("RanFailed") })
        assertEquals(1, events.count { it == "RanSucceeded" })

        // The request is a Messages API call with the key in a header, never in the body.
        val first = requests[0]
        assertEquals("claude-fable-5-2", first.getString("model"))
        assertTrue(first.getInt("max_tokens") > 0)
        assertTrue(first.getString("system").contains("ScriptWidget"))
        assertTrue(headers[0].contains("x-api-key: $secret", ignoreCase = true))
        assertFalse(first.toString().contains(secret))
        // The second call carries the first attempt and the device's error for it.
        val conversation = requests[1].getJSONArray("messages").toString()
        assertTrue(conversation.contains("const label = ;"))
        assertTrue("the runtime error is fed back", conversation.contains("SyntaxError") || conversation.contains("Unexpected token"))

        // The accepted source installs and draws like any other package.
        val installed = AppServices.library.create("AI Loop Test ${System.nanoTime()}", outcome.source).also { created += it.name }
        val request = RunRequest(installed.files, installed.installation, buildDirectory = installed.buildDirectory)
        val bitmap = AppServices.runtime.render(request, AppServices.runtime.run(request), 330f, 160f, 2f).bitmap
        assertEquals(0xFF0F172A.toInt(), bitmap.getPixel(4, 4))
    }

    @Test fun theLoopStopsAtItsLimitWhenEveryAnswerFails() {
        repeat(3) { replies += "```jsx\nthrow new Error(\"attempt $it\");\n```" }
        val settings = AiSettings(AiProfile(AiProviderKind.ANTHROPIC, "https://api.anthropic.com", "claude-fable-5-2"), maxIterations = 5)
        val outcome = AgentLoop(AiClient(transport).bind(settings, "sk-test-not-a-real-key")).run(
            AgentLoopRequest(AgentLoopRequest.Mode.Fresh("anything"), AiWidgetSize.SMALL, PromptBuilder.systemPrompt(AiServices.reference(context)), 3),
            validate = ::validate,
        )
        assertTrue(outcome.javaClass.simpleName, outcome is AgentLoopOutcome.Exhausted)
        assertEquals(3, requests.size)
    }
}
