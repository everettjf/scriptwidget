package com.everettjf.scriptwidget.core.surfaces

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class LiveActivityStateTest {
    private fun rejects(code: String, text: String) {
        try {
            LiveActivityStates.parse(text)
            fail("expected $code")
        } catch (error: LiveActivityStateException) {
            assertEquals(code, error.code)
            // The message explains the rule and never repeats what was supplied.
            if (text.length > 12) assertFalse(error.message!!.contains(text))
        }
    }

    @Test fun readsTheDocumentedProgressExample() {
        val state = LiveActivityStates.parse("""{"title":"Reading","detail":"Chapter finished","progress":3,"total":8}""")
        assertEquals("Reading", state.title)
        assertEquals("Chapter finished", state.detail)
        assertEquals(3, state.progress)
        assertEquals(8, state.total)
        assertNull(state.endsAt)
    }

    @Test fun readsTheDocumentedDeadlineExample() {
        val state = LiveActivityStates.parse("""{"title":"Focus","detail":"One focused session","endsAt":"2026-12-01T18:25:00Z"}""")
        assertEquals(1796149500000L, state.endsAt)
        assertEquals(state.endsAt, LiveActivityStates.parse("""{"endsAt":"2026-12-01T10:25:00.000-08:00"}""").endsAt)
        assertEquals(state.endsAt, LiveActivityStates.parse("""{"endsAt":"2026-12-01T18:25Z"}""").endsAt)
    }

    @Test fun theEmptyStateIsValid() {
        for (text in listOf("", "   \n", "{}")) {
            val state = LiveActivityStates.parse(text)
            assertNull(state.title)
            assertNull(state.progress)
        }
    }

    @Test fun theFourKibibyteLimitCountsUtf8Bytes() {
        val padding = " ".repeat(4096 - """{"title":"A"}""".length)
        assertEquals("A", LiveActivityStates.parse("""{"title":"A"}$padding""").title)
        rejects("too_large", """{"title":"A"}$padding """)
        // 1366 three-byte characters are 4098 bytes although they are only 1366 UTF-16 units.
        rejects("too_large", "中".repeat(1366))
    }

    @Test fun onlyAJsonObjectWithKnownFieldsIsAccepted() {
        rejects("invalid_json", "[1]")
        rejects("invalid_json", "\"text\"")
        rejects("invalid_json", "{title:'A'}")
        rejects("invalid_json", """{"title":"A"} trailing""")
        rejects("invalid_json", """{"title":"A","title":"B"}""")
        rejects("unknown_field", """{"title":"A","subtitle":"B"}""")
        rejects("unknown_field", """{"layout":"<vstack/>"}""")
    }

    @Test fun titleAndDetailBounds() {
        assertEquals(40, LiveActivityStates.parse("""{"title":"${"t".repeat(40)}"}""").title!!.length)
        rejects("invalid_title", """{"title":"${"t".repeat(41)}"}""")
        rejects("invalid_title", """{"title":""}""")
        rejects("invalid_title", """{"title":7}""")
        rejects("invalid_title", """{"title":null}""")
        assertEquals(80, LiveActivityStates.parse("""{"detail":"${"d".repeat(80)}"}""").detail!!.length)
        assertEquals("", LiveActivityStates.parse("""{"detail":""}""").detail)
        rejects("invalid_detail", """{"detail":"${"d".repeat(81)}"}""")
        rejects("invalid_detail", """{"detail":["a"]}""")
    }

    @Test fun progressBounds() {
        assertEquals(0, LiveActivityStates.parse("""{"progress":0,"total":1}""").progress)
        assertEquals(10000, LiveActivityStates.parse("""{"progress":10000,"total":10000}""").total)
        // 3.0 is the integer 3 in JSON on every platform.
        assertEquals(3, LiveActivityStates.parse("""{"progress":3.0,"total":8}""").progress)
        rejects("invalid_progress", """{"progress":3}""")
        rejects("invalid_progress", """{"total":8}""")
        rejects("invalid_progress", """{"progress":9,"total":8}""")
        rejects("invalid_progress", """{"progress":-1,"total":8}""")
        rejects("invalid_progress", """{"progress":0,"total":0}""")
        rejects("invalid_progress", """{"progress":0,"total":10001}""")
        rejects("invalid_progress", """{"progress":1.5,"total":8}""")
        rejects("invalid_progress", """{"progress":"3","total":8}""")
        rejects("invalid_progress", """{"progress":true,"total":8}""")
        rejects("invalid_progress", """{"progress":1,"total":99999999999999999999}""")
    }

    @Test fun deadlinesNeedATimeZoneAndRealFields() {
        rejects("invalid_deadline", """{"endsAt":"2026-12-01T18:25:00"}""")
        rejects("invalid_deadline", """{"endsAt":"2026-12-01"}""")
        rejects("invalid_deadline", """{"endsAt":"2026-13-01T18:25:00Z"}""")
        rejects("invalid_deadline", """{"endsAt":"2026-12-01T25:00:00Z"}""")
        rejects("invalid_deadline", """{"endsAt":1796149500000}""")
        rejects("invalid_deadline", """{"endsAt":"tomorrow"}""")
    }

    @Test fun templateContentShowsTheDocumentedFields() {
        val state = LiveActivityStates.parse("""{"title":"Focus","detail":"One session","progress":2,"total":5,"endsAt":"2026-12-01T18:25:00Z"}""")
        val running = LiveActivityStates.content(state, "My Package", state.endsAt!! - 60_000)
        assertEquals("Focus", running.title)
        assertEquals("One session", running.text)
        assertEquals(2, running.progress)
        assertEquals(5, running.total)
        assertEquals(state.endsAt, running.countdownTo)
        val expired = LiveActivityStates.content(state, "My Package", state.endsAt)
        assertEquals("Time is up", expired.text)
        assertNull(expired.countdownTo)
    }

    @Test fun templateContentFallsBackToThePackageName() {
        val content = LiveActivityStates.content(LiveActivityStates.parse(""), "My Package", 0)
        assertEquals("My Package", content.title)
        assertEquals("", content.text)
        assertNull(content.progress)
        assertNull(content.countdownTo)
    }
}
