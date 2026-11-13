package com.everettjf.scriptwidget.core

import androidx.test.ext.junit.runners.AndroidJUnit4
import com.everettjf.scriptwidget.core.js.JsException
import com.everettjf.scriptwidget.core.js.JsHost
import com.everettjf.scriptwidget.core.js.JsThread
import com.everettjf.scriptwidget.core.js.QuickJs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class QuickJsTest {
    private fun <T> js(host: JsHost = JsHost { _, _ -> null }, block: (QuickJs) -> T): T =
        JsThread.run { QuickJs(host).use(block) }

    @Test fun evaluatesModernSyntax() {
        assertEquals("6", js { it.evaluate("const f = async (a) => a?.b ?? 3; [1,2,3].reduce((x, y) => x + y)") })
    }

    @Test fun stringsCrossTheBridgeAsUtf16() {
        val text = "中文 😀 \uD83D ok"
        val seen = mutableListOf<String?>()
        val echoed = js(JsHost { op, payload -> seen += payload; "$op:$payload" }) {
            it.evaluate("__swNative('echo', ${'"'}中文 😀 \\uD83D ok${'"'})")
        }
        assertEquals(text, seen.single())
        assertEquals("echo:$text", echoed)
    }

    @Test fun hostExceptionsBecomeJavaScriptErrors() {
        val result = js(JsHost { _, _ -> throw IllegalStateException("denied") }) {
            it.evaluate("try { __swNative('x') } catch (e) { e.message }")
        }
        assertEquals("denied", result)
    }

    @Test fun uncaughtErrorsCarryMessageAndStack() {
        try {
            js { it.evaluate("function boom() { throw new TypeError('bad') } boom()", "main.js") }
            fail("expected JsException")
        } catch (error: JsException) {
            assertTrue(error.message!!.startsWith("TypeError: bad"))
            assertTrue(error.message!!.contains("main.js"))
            assertEquals(false, error.interrupted)
        }
    }

    @Test fun deadlineInterruptsRunawayLoopsAndCannotBeCaught() {
        val started = System.nanoTime()
        try {
            js { it.setDeadline(300); it.evaluate("while (true) { try { for (;;) {} } catch (e) {} }") }
            fail("expected JsException")
        } catch (error: JsException) {
            assertTrue(error.interrupted)
        }
        assertTrue((System.nanoTime() - started) / 1_000_000 < 3000)
    }

    @Test fun memoryLimitStopsAllocation() {
        try {
            JsThread.run { QuickJs(JsHost { _, _ -> null }, memoryLimitBytes = 8L * 1024 * 1024).use { it.evaluate("const a = []; for (;;) a.push(new Array(1000).fill('x'.repeat(100)))") } }
            fail("expected JsException")
        } catch (error: JsException) {
            assertTrue(error.message!!.contains("out of memory", ignoreCase = true))
        }
    }

    @Test fun promiseJobsRunWhenPumped() {
        val value = js {
            it.evaluate("globalThis.out = 0; Promise.resolve(41).then(v => { out = v + 1 })")
            val ran = it.runJobs()
            assertTrue(ran >= 1)
            it.evaluate("String(out)")
        }
        assertEquals("42", value)
    }

    @Test fun bytecodeRoundTrips() {
        val value = js {
            val bytecode = it.compile("globalThis.answer = () => 7 * 6")
            it.evaluateBytecode(bytecode)
            it.call("answer")
        }
        assertEquals("42", value)
    }

    @Test fun deepRecursionIsAStackErrorNotACrash() {
        val value = js { it.evaluate("function r(n) { return r(n + 1) + 1 } try { r(0) } catch (e) { e instanceof RangeError ? 'range' : String(e) }") }
        assertEquals("range", value)
    }
}
