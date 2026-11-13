package com.everettjf.scriptwidget.core.system

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class MusicModuleTest {
    private class FakePlatform(var available: Boolean = true, var enabled: Boolean = true, var reading: MediaSessionReading? = null) : MusicPlatform {
        var reads = 0
        var failure: Exception? = null
        var revokeDuringRead = false
        override fun isAvailable() = available
        override fun accessEnabled() = enabled
        override fun read(): MediaSessionReading? { reads += 1; failure?.let { throw it }; if (revokeDuringRead) enabled = false; return reading }
    }

    // PlaybackState.STATE_* values.
    private val stopped = 1; private val paused = 2; private val playing = 3; private val fastForwarding = 4; private val rewinding = 5
    private val buffering = 6; private val error = 7; private val connecting = 8; private val skippingPrevious = 9; private val skippingNext = 10; private val skippingQueue = 11

    private val song = MediaSessionReading(3, true, "Clair de lune", "Claude Debussy", "Suite bergamasque", 303_000, 61_500)
    private val platform = FakePlatform(reading = song)
    private val prompts = promptsIn(temporaryDirectory())
    private val module = MusicModule(platform, prompts) { NOW }
    private val declared = setOf("music")
    private fun widget(queries: Int = 8) = context(declared, queries = queries)

    @Test fun stateMapping() {
        assertEquals("playing", MusicRules.state(playing)); assertEquals("paused", MusicRules.state(paused))
        assertEquals("stopped", MusicRules.state(stopped)); assertEquals("stopped", MusicRules.state(0))
        for (state in listOf(fastForwarding, rewinding, skippingPrevious, skippingNext, skippingQueue)) assertEquals("seeking", MusicRules.state(state))
        for (state in listOf(buffering, error, connecting, 12, 99, -1)) assertEquals("unknown", MusicRules.state(state))
        assertTrue((0..12).all { MusicRules.state(it) in MusicRules.STATES })
    }

    @Test fun snapshotFieldsAndBounds() {
        val snapshot = MusicRules.snapshot(song, NOW)
        assertEquals("{\"album\":\"Suite bergamasque\",\"artist\":\"Claude Debussy\",\"capturedAt\":\"2026-11-12T12:00:00Z\",\"duration\":303,\"hasItem\":true,\"position\":61.5,\"provider\":\"androidMediaSession\",\"state\":\"playing\",\"title\":\"Clair de lune\"}",
            Canonical.encode(snapshot.toJson()))
        assertEquals(setOf("provider", "state", "hasItem", "title", "artist", "album", "duration", "position", "capturedAt"), snapshot.toJson().keys().asSequence().toSet())
        assertTrue(MusicRules.valid(snapshot))

        // Nothing active: stopped, no item, every detail null.
        val idle = MusicRules.snapshot(null, NOW).toJson()
        assertEquals("stopped", idle.getString("state")); assertFalse(idle.getBoolean("hasItem"))
        for (field in listOf("title", "artist", "album", "duration", "position")) assertTrue(field, idle.isNull(field))

        // A session without metadata keeps its state and position; missing details never imply stopped playback.
        val withheld = MusicRules.snapshot(MediaSessionReading(playing, false, "ignored", "ignored", "ignored", 200_000, 5_000), NOW)
        assertEquals("playing", withheld.state); assertFalse(withheld.hasItem)
        assertNull(withheld.title); assertNull(withheld.artist); assertNull(withheld.album); assertNull(withheld.duration); assertEquals(5.0, withheld.position!!, 0.0)
        assertTrue(MusicRules.valid(withheld))

        // Unknown or impossible numbers are null, never zero or clamped.
        fun numbers(duration: Long?, position: Long?) = MusicRules.snapshot(MediaSessionReading(paused, true, "t", null, null, duration, position), NOW)
        assertNull(numbers(null, null).duration); assertNull(numbers(null, null).position)
        assertNull(numbers(0, 0).duration); assertEquals(0.0, numbers(0, 0).position!!, 0.0)
        assertNull(numbers(-1, -1).duration); assertNull(numbers(-1, -1).position)
        assertEquals(604_800.0, numbers(604_800_000, 604_800_000).duration!!, 0.0); assertEquals(604_800.0, numbers(604_800_000, 604_800_000).position!!, 0.0)
        assertNull(numbers(604_800_001, 604_800_001).duration); assertNull(numbers(604_800_001, 604_800_001).position)

        // Text from other apps is cleaned and bounded: 256 characters and 512 UTF-8 bytes.
        assertEquals("Line one Line two", MusicRules.text(" Line one\u0000 Line​ two\n"))
        assertNull(MusicRules.text(null)); assertNull(MusicRules.text("")); assertNull(MusicRules.text(" \n\t"))
        assertEquals(256, MusicRules.text("x".repeat(400))!!.length)
        assertEquals(512, MusicRules.text("é".repeat(400))!!.toByteArray().size)
        val wide = MusicRules.text("🗼".repeat(400))!!
        assertEquals(128, wide.codePointCount(0, wide.length)); assertEquals(512, wide.toByteArray().size)
        assertTrue(MusicRules.valid(MusicRules.snapshot(MediaSessionReading(playing, true, "🗼".repeat(400), "é".repeat(400), "a\u0007b", 1, 1), NOW)))
        assertFalse(MusicRules.valid(MusicSnapshot("playing", false, "title without an item", null, null, null, null, NOW)))
        assertFalse(MusicRules.valid(MusicSnapshot("buffering", true, null, null, null, null, null, NOW)))
        assertFalse(MusicRules.valid(MusicSnapshot("playing", true, "a\nb", null, null, null, null, NOW)))
        assertFalse(MusicRules.valid(MusicSnapshot("playing", true, null, null, null, 0.0, null, NOW)))
        assertFalse(MusicRules.valid(MusicSnapshot("playing", true, null, null, null, null, Double.NaN, NOW)))
    }

    @Test fun availabilityAndAuthorization() {
        assertTrue(module.isAvailable(widget())); assertEquals("authorized", module.authorizationStatus(widget()))
        // Without package access the widget learns nothing about the device.
        for (undeclared in listOf(context(emptySet()), context(declared, hasManifest = false), context(declared, installation = "preview"))) {
            assertFalse(module.isAvailable(undeclared)); assertEquals("undeclared", module.authorizationStatus(undeclared))
        }
        platform.enabled = false
        assertTrue("available does not mean authorized", module.isAvailable(widget()))
        assertEquals("notDetermined", module.authorizationStatus(widget())); assertEquals("notDetermined", module.systemStatus())
        prompts.markAsked(MusicModule.PROMPT)
        assertEquals("denied", module.authorizationStatus(widget()))
        platform.available = false
        assertFalse(module.isAvailable(widget())); assertEquals("unavailable", module.authorizationStatus(widget()))
        // Music access does not depend on the Runtime 1.6 system services.
        platform.available = true; platform.enabled = true
        assertEquals("authorized", module.authorizationStatus(context(declared, runtime = "1.4")))
    }

    @Test fun currentPolicyOrderAndMessages() {
        val permission = "[music_permission] Install this widget, declare music and allow Music access in ScriptWidget Settings."
        assertRejectsWith(permission) { module.current(context(emptySet()), Any()) }
        assertRejectsWith(permission) { module.current(context(declared, installation = "preview"), Any()) }
        assertRejectsWith(permission) { module.current(context(declared, hasManifest = false), Any()) }
        // Package access is checked before the presentation, the presentation before the budget.
        assertRejectsWith(permission) { module.current(context(emptySet(), projection = true), Any()) }
        assertRejectsWith("[timeline_read_only] Prepare Music display data in the current entry") { module.current(context(declared, projection = true, queries = 0), Any()) }
        assertRejectsWith("[timeline_read_only] Prepare Music display data in the current entry") { module.current(context(declared, liveActivity = true), Any()) }
        platform.available = false; platform.enabled = false
        assertRejectsWith("[query_limit] Too many system data queries") { module.current(widget(queries = 0), Any()) }
        assertRejectsWith("[music_unavailable] Current Music app playback is unavailable on this platform.") { module.current(widget(), Any()) }
        platform.available = true
        assertRejectsWith(permission) { module.current(widget(), Any()) }
        assertEquals("nothing was read without authorization", 0, platform.reads)
        platform.enabled = true
        assertEquals("Clair de lune", module.current(widget(), Any()).getString("title"))
    }

    @Test fun oneSnapshotPerExecutionAndRecheckBeforeDelivery() {
        val execution = Any()
        val context = widget()
        val first = module.current(context, execution)
        platform.reading = MediaSessionReading(paused, true, "Another track", null, null, null, null)
        val second = module.current(context, execution)
        assertEquals(1, platform.reads)
        assertEquals(first.toString(), second.toString())
        assertFalse("scripts receive independent objects", first === second)
        // Every call still spends one of the eight queries.
        repeat(6) { module.current(context, execution) }
        assertRejectsWith("[query_limit] Too many system data queries") { module.current(context, execution) }
        // Another execution reads again.
        assertEquals("Another track", module.current(widget(), Any()).getString("title"))
        assertEquals(2, platform.reads)

        // Access revoked while reading: the snapshot is not delivered.
        platform.revokeDuringRead = true
        assertRejects("music_permission") { module.current(widget(), Any()) }
        platform.revokeDuringRead = false; platform.enabled = true
        // The system refusing the read is a permission error; any other failure is an unreadable snapshot.
        platform.failure = SecurityException("listener disabled")
        assertRejects("music_permission") { module.current(widget(), Any()) }
        platform.failure = IllegalStateException("dead session")
        val failed = Any()
        assertRejectsWith("[music_snapshot] Playback information could not be read.") { module.current(widget(), failed) }
        platform.failure = null
        assertRejects("music_snapshot") { module.current(widget(), failed) } // the failure is the execution's snapshot too
        assertEquals("Another track", module.current(widget(), Any()).getString("title"))
    }
}
