package com.everettjf.scriptwidget.core.system

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class AlarmsModuleTest {
    private class FakePlatform(var allowed: Boolean = true) : AlarmPlatform {
        val armed = LinkedHashMap<String, Long>()
        var fail = false
        override fun enabled() = allowed
        override fun arm(record: AlarmRecord, triggerAtMilliseconds: Long) { if (fail) throw IllegalStateException("alarms unavailable"); armed["${record.owner}/${record.key}"] = triggerAtMilliseconds }
        override fun disarm(owner: String, key: String) { armed.remove("$owner/$key") }
    }

    private var now = NOW
    private val directory = temporaryDirectory()
    private val platform = FakePlatform()
    private val store = AlarmStore(PrivateFile(File(directory, "alarms.json"), 256 * 1024))
    private val grants = grantsIn(directory, "alarms").also { it.set(OTHER_OWNER, "alarms", true) }
    private val prompts = promptsIn(directory)
    private val module = AlarmsModule(platform, store, grants, prompts, File(directory, "alarms")) { now }
    private val declared = setOf("alarms")
    private fun action(installation: String = OWNER, queries: Int = 8) = context(declared, installation = installation, action = true, queries = queries)
    private fun timer(key: String = "focus", seconds: Any = 1500, request: String = REQUEST_A) = JSONObject().put("requestID", request).put("key", key).put("title", "Focus complete").put("seconds", seconds)
    private fun dated(key: String = "wake", date: String = "2026-11-13T07:00:00Z", request: String = REQUEST_B) = JSONObject().put("requestID", request).put("key", key).put("title", "Wake up").put("date", date)
    private fun request(index: Int) = "%08x-0000-4000-8000-000000000000".format(index)
    private fun states(installation: String = OWNER): Map<String, String> = module.pending(context(declared, installation = installation)).let { rows ->
        (0 until rows.length()).associate { rows.getJSONObject(it).getString("key") to rows.getJSONObject(it).getString("state") }
    }

    @Test fun optionValidation() {
        val countdown = AlarmRules.parse(timer(), now)
        assertEquals(1500.0, countdown.seconds!!, 0.0); assertNull(countdown.date); assertEquals("focus", countdown.key)
        assertEquals(IsoDates.parse("2026-11-13T07:00:00Z"), AlarmRules.parse(dated(), now).date)
        AlarmRules.parse(timer(seconds = 60), now); AlarmRules.parse(timer(seconds = 86400), now); AlarmRules.parse(timer(seconds = 90.5), now)
        AlarmRules.parse(dated(date = "2027-11-13T12:00:00Z"), now) // exactly 366 days
        AlarmRules.parse(timer().put("title", "é".repeat(64)), now)
        val bad = listOf(
            timer().put("date", "2026-11-13T07:00:00Z"), // both
            JSONObject().put("requestID", REQUEST_A).put("key", "k").put("title", "t"), // neither
            timer(seconds = 59), timer(seconds = 86401), timer(seconds = "1500"), timer(seconds = true), timer().put("seconds", JSONObject.NULL),
            dated(date = "2026-11-12T12:00:00Z"), dated(date = "2026-11-12T11:00:00Z"), dated(date = "2027-11-13T12:00:01Z"), dated(date = "2026-11-13"), dated(date = "soon"),
            timer(key = "has space"), timer(key = "x".repeat(65)), timer().put("key", 7), JSONObject().put("requestID", REQUEST_A).put("title", "t").put("seconds", 60),
            timer().put("title", "  "), timer().put("title", "é".repeat(65)), timer().put("title", "two\nlines"), timer().put("title", 5),
            timer(request = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"), timer(request = "not-a-uuid"), timer().put("requestID", 1),
            JSONObject().put("key", "focus").put("title", "t").put("seconds", 60), // no requestID
            timer().put("sound", "loud"), timer().put("id", "11111111-1111-4111-8111-111111111111"),
        )
        for (options in bad) assertRejects("invalid_options") { AlarmRules.parse(options, now) }
    }

    @Test fun identifiersAreDerivedFromInstallationAndKey() {
        val id = AlarmRules.id(OWNER, "focus")
        assertTrue(SystemOptions.validRequestID(id))
        assertEquals(Canonical.sha256("$OWNER:alarm:focus").take(8), id.take(8))
        assertEquals(id, AlarmRules.id(OWNER, "focus"))
        assertNotEquals(id, AlarmRules.id(OTHER_OWNER, "focus"))
        assertNotEquals(id, AlarmRules.id(OWNER, "focus2"))
        assertRejects("invalid_options") { AlarmRules.id(OWNER, "not a key") }
        assertRejects("invalid_options") { AlarmRules.id("preview", "focus") }
    }

    @Test fun stateMachine() {
        val countdown = AlarmRules.start(OWNER, AlarmRules.parse(timer(), now), now)
        assertEquals("countdown", countdown.state); assertEquals(now + 1_500_000, countdown.fireAt); assertTrue(countdown.timer)
        val scheduled = AlarmRules.start(OWNER, AlarmRules.parse(dated(), now), now)
        assertEquals("scheduled", scheduled.state); assertEquals(IsoDates.parse("2026-11-13T07:00:00Z"), scheduled.fireAt); assertFalse(scheduled.timer)

        val paused = AlarmRules.transition(countdown, "pause", now + 600_000)!!
        assertEquals("paused", paused.state); assertNull(paused.fireAt); assertEquals(900_000L, paused.remaining); assertFalse(paused.armed)
        val resumed = AlarmRules.transition(paused, "resume", now + 3_600_000)!!
        assertEquals("countdown", resumed.state); assertEquals(now + 3_600_000 + 900_000, resumed.fireAt); assertNull(resumed.remaining); assertTrue(resumed.armed)
        // A countdown paused at or after its time keeps at least one second.
        assertEquals(1_000L, AlarmRules.transition(countdown, "pause", now + 1_500_000)!!.remaining)
        val stopped = AlarmRules.transition(countdown, "stop", now)!!
        assertEquals("stopped", stopped.state); assertNull(stopped.fireAt); assertNull(stopped.remaining)
        assertEquals("stopped", AlarmRules.transition(paused, "stop", now)!!.state)
        assertEquals("stopped", AlarmRules.transition(scheduled, "stop", now)!!.state)

        // Transitions the current state does not allow.
        assertNull(AlarmRules.transition(scheduled, "pause", now)) // a fixed-date alarm has no countdown
        assertNull(AlarmRules.transition(paused, "pause", now))
        assertNull(AlarmRules.transition(countdown, "resume", now))
        assertNull(AlarmRules.transition(scheduled, "resume", now))
        assertNull(AlarmRules.transition(stopped, "stop", now)); assertNull(AlarmRules.transition(stopped, "pause", now)); assertNull(AlarmRules.transition(stopped, "resume", now))
        assertNull(AlarmRules.transition(countdown, "snooze", now))
        assertEquals(AlarmRules.STATES, setOf("scheduled", "countdown", "paused", "stopped"))
    }

    @Test fun gateOrder() {
        assertRejects("permission_denied") { module.status(context(emptySet())) }
        assertRejects("permission_denied") { module.schedule(context(declared, action = true, runtime = "1.5"), timer()) }
        assertRejects("read_only") { module.schedule(context(declared), timer()) }
        for (method in listOf("cancel", "stop", "pause", "resume")) assertRejects("read_only") { module.control(context(declared), method, "focus") }
        assertRejects("read_only") { module.pending(context(declared, projection = true)) }
        assertRejects("read_only") { module.status(context(declared, liveActivity = true)) }
        assertRejects("permission_denied") { module.schedule(context(declared, action = true, installation = "33333333-3333-4333-8333-333333333333"), timer()) }
        assertRejects("permission_denied") { module.status(context(declared, installation = "33333333-3333-4333-8333-333333333333")) }
        assertRejects("query_limit") { module.schedule(action(queries = 0), timer()) }
        assertRejects("invalid_options") { module.schedule(action(), timer(seconds = 5)) }
        assertRejects("invalid_options") { module.schedule(action(), null) }
        assertRejects("invalid_options") { module.control(action(), "cancel", "not a key") }
        assertRejects("invalid_options") { module.control(action(), "pause", null) }
        assertRejects("unavailable") { module.control(action(), "pause", "focus") } // no such alarm

        // Notification authorization comes before the options, as AlarmKit authorization does.
        platform.allowed = false
        assertRejects("permission_denied") { module.schedule(action(), timer(seconds = 5)) }
        assertRejects("permission_denied") { module.pending(context(declared)) }
        assertRejects("permission_denied") { module.control(action(), "cancel", "focus") }
        assertEquals("notDetermined", module.status(context(declared)).getString("authorization"))
        prompts.markAsked(NotificationsModule.PROMPT)
        assertEquals("denied", module.status(context(declared)).getString("authorization"))
        platform.allowed = true
        assertEquals("{\"authorization\":\"authorized\"}", Canonical.encode(module.status(context(declared))))
        assertTrue(platform.armed.isEmpty()); assertTrue(store.all().isEmpty())
    }

    @Test fun scheduleControlAndPendingArePerInstallation() {
        assertEquals("{\"key\":\"focus\",\"replayed\":false,\"status\":\"scheduled\"}", Canonical.encode(module.schedule(action(), timer())))
        module.schedule(action(), dated())
        module.schedule(action(OTHER_OWNER), timer(key = "theirs", request = request(1)))
        assertEquals(now + 1_500_000, platform.armed["$OWNER/focus"]); assertEquals(IsoDates.parse("2026-11-13T07:00:00Z"), platform.armed["$OWNER/wake"])
        val pending = module.pending(context(declared))
        assertEquals("[{\"key\":\"focus\",\"state\":\"countdown\"},{\"key\":\"wake\",\"state\":\"scheduled\"}]", Canonical.encode(pending))
        assertEquals(mapOf("theirs" to "countdown"), states(OTHER_OWNER))

        now += 300_000
        assertEquals("{\"key\":\"focus\",\"status\":\"requested\"}", Canonical.encode(module.control(action(), "pause", "focus")))
        assertEquals("paused", states()["focus"]); assertFalse(platform.armed.containsKey("$OWNER/focus"))
        assertRejects("unavailable") { module.control(action(), "pause", "focus") }
        assertRejects("unavailable") { module.control(action(), "pause", "wake") }
        now += 3_600_000
        module.control(action(), "resume", "focus")
        assertEquals("countdown", states()["focus"]); assertEquals(now + 1_200_000, platform.armed["$OWNER/focus"])
        assertRejects("unavailable") { module.control(action(), "resume", "focus") }
        module.control(action(), "stop", "focus")
        assertEquals("stopped", states()["focus"]); assertFalse(platform.armed.containsKey("$OWNER/focus"))
        assertRejects("unavailable") { module.control(action(), "stop", "focus") }

        // Another installation can neither see nor control this one's alarms.
        assertRejects("unavailable") { module.control(action(OTHER_OWNER), "cancel", "wake") }
        assertEquals("scheduled", states()["wake"])
        module.control(action(), "cancel", "wake")
        assertEquals(mapOf("focus" to "stopped"), states()); assertFalse(platform.armed.containsKey("$OWNER/wake"))
        assertRejects("unavailable") { module.control(action(), "cancel", "wake") }
        module.control(action(), "cancel", "focus")
        assertTrue(states().isEmpty()); assertEquals(setOf("$OTHER_OWNER/theirs"), platform.armed.keys)
    }

    @Test fun receiptsReplayAndActiveAlarmsAreNeverReplaced() {
        module.schedule(action(), timer())
        val armedAt = platform.armed["$OWNER/focus"]
        now += 60_000
        // The same request again is the confirmed result, not a second alarm.
        assertEquals("{\"key\":\"focus\",\"replayed\":true,\"status\":\"scheduled\"}", Canonical.encode(module.schedule(action(), timer())))
        assertEquals(armedAt, platform.armed["$OWNER/focus"])
        // The same identifier with other arguments is a conflict.
        assertRejects("request_conflict") { module.schedule(action(), timer(seconds = 1501)) }
        assertRejects("request_conflict") { module.schedule(action(), timer(key = "other")) }
        // A new request cannot replace an alarm that is counting down, scheduled or paused.
        assertRejects("request_conflict") { module.schedule(action(), timer(request = request(2))) }
        module.control(action(), "pause", "focus")
        assertRejects("request_conflict") { module.schedule(action(), timer(request = request(3))) }
        assertEquals("paused", states()["focus"])
        // A rejected request left no receipt behind: it may be sent again once the key is free.
        module.control(action(), "stop", "focus")
        assertFalse(module.schedule(action(), timer(request = request(3))).getBoolean("replayed"))
        assertEquals("countdown", states()["focus"]); assertEquals(now + 1_500_000, platform.armed["$OWNER/focus"])
        // After cancel, an old receipt still replays instead of scheduling again.
        module.control(action(), "cancel", "focus")
        assertTrue(module.schedule(action(), timer()).getBoolean("replayed"))
        assertTrue(states().isEmpty())
        // Receipts are per installation.
        assertFalse(module.schedule(action(OTHER_OWNER), timer()).getBoolean("replayed"))
    }

    @Test fun limitsAndFailures() {
        repeat(32) { module.schedule(action(), timer(key = "k$it", request = request(it))) }
        assertRejects("limit_exceeded") { module.schedule(action(), timer(key = "one-more", request = request(100))) }
        assertEquals(32, states().size)
        // A stopped alarm still holds its key, and can be scheduled again in place.
        module.control(action(), "stop", "k0")
        assertRejects("limit_exceeded") { module.schedule(action(), timer(key = "one-more", request = request(100))) }
        module.schedule(action(), timer(key = "k0", request = request(101)))
        module.control(action(), "cancel", "k1")
        // The system refusing the alarm after the receipt was prepared is an unknown outcome and is never retried blindly.
        platform.fail = true
        assertRejects("outcome_unknown") { module.schedule(action(), timer(key = "k1", request = request(102))) }
        platform.fail = false
        assertRejects("outcome_unknown") { module.schedule(action(), timer(key = "k1", request = request(102))) }

        File(directory, "alarms.json").writeText("{\"formatVersion\":1,\"alarms\":[{\"owner\":\"x\"}]}")
        assertRejects("unavailable") { module.pending(context(declared)) }
        assertRejects("unavailable") { module.control(action(), "cancel", "k2") }
        assertRejects("unavailable") { module.schedule(action(), timer(key = "k2", request = request(103))) }
        // Records that contradict their state are refused as a whole.
        fun record(state: String, timer: Boolean, fireAt: Any, remaining: Any) = JSONObject().put("owner", OWNER).put("key", "k").put("title", "t").put("state", state).put("timer", timer).put("fireAt", fireAt).put("remaining", remaining)
        for (bad in listOf(record("countdown", false, now, JSONObject.NULL), record("paused", true, now, 5), record("paused", true, JSONObject.NULL, 0), record("scheduled", false, JSONObject.NULL, JSONObject.NULL), record("alerting", true, now, JSONObject.NULL))) {
            File(directory, "alarms.json").writeText(JSONObject().put("formatVersion", 1).put("alarms", JSONArray().put(bad)).toString())
            assertRejects("unavailable") { store.all() }
        }
    }

    @Test fun revokedGrantStopsEveryCallAndRetireCancelsEverything() {
        module.schedule(action(), timer())
        module.schedule(action(OTHER_OWNER), timer(key = "theirs"))
        grants.set(OWNER, "alarms", false)
        assertRejects("permission_denied") { module.status(context(declared)) }
        assertRejects("permission_denied") { module.pending(context(declared)) }
        assertRejects("permission_denied") { module.control(action(), "cancel", "focus") }
        assertRejects("permission_denied") { module.schedule(action(), timer(key = "second", request = request(7))) }
        assertEquals(2, store.all().size)

        module.retire(OWNER)
        assertEquals(listOf("theirs"), store.all().map { it.key }); assertEquals(setOf("$OTHER_OWNER/theirs"), platform.armed.keys)
        // Retiring also drops the receipts, so a new installation with the same identity starts clean.
        grants.set(OWNER, "alarms", true)
        assertFalse(module.schedule(action(), timer()).getBoolean("replayed"))
    }
}
