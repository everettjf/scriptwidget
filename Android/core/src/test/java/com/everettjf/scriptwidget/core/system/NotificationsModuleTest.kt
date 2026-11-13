package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId

class NotificationsModuleTest {
    private class FakePlatform(var allowed: Boolean = true) : NotificationPlatform {
        val armed = LinkedHashMap<String, Long>()
        var fail = false
        override fun enabled() = allowed
        override fun schedule(entry: ScheduledNotification, triggerAtMilliseconds: Long) { if (fail) throw IllegalStateException("alarms unavailable"); armed["${entry.owner}/${entry.key}"] = triggerAtMilliseconds }
        override fun cancel(owner: String, key: String) { armed.remove("$owner/$key") }
    }

    private val zone = ZoneId.of("America/Los_Angeles")
    private val directory = temporaryDirectory()
    private val now = NOW // 04:00 local time
    private val platform = FakePlatform()
    private val store = NotificationStore(PrivateFile(File(directory, "notifications.json"), 256 * 1024))
    private val grants = grantsIn(directory, "notifications").also { it.set(OTHER_OWNER, "notifications", true) }
    private val prompts = promptsIn(directory)
    private val module = NotificationsModule(platform, store, grants, prompts, { now }, { zone })
    private val declared = setOf("notifications")
    private fun action(installation: String = OWNER, queries: Int = 8) = context(declared, installation = installation, action = true, queries = queries)
    private fun daily(key: String = "reading", hour: Int = 20, minute: Int = 0) = JSONObject().put("key", key).put("title", "Time to read").put("body", "One chapter").put("daily", JSONObject().put("hour", hour).put("minute", minute))
    private fun once(key: String = "one-time", date: String = "2026-11-13T12:00:00Z") = JSONObject().put("key", key).put("title", "A reminder").put("body", "Take a break").put("date", date)

    @Test fun optionValidation() {
        val entry = NotificationRules.parse(OWNER, daily(), now)
        assertTrue(entry.repeats); assertEquals(20, entry.hour); assertNull(entry.date)
        assertEquals(IsoDates.parse("2026-11-13T12:00:00Z"), NotificationRules.parse(OWNER, once(), now).date)
        val bad = listOf(
            daily().put("date", "2026-11-13T12:00:00Z"), // both
            JSONObject().put("key", "k").put("title", "t").put("body", "b"), // neither
            once(date = "2026-11-12T11:59:59Z"), // past
            once(date = "2027-11-14T12:00:00Z"), // more than 366 days away
            once(date = "2026-11-13"), once(date = "tomorrow"),
            daily(hour = 24), daily(minute = 60), daily(hour = -1),
            daily().put("daily", JSONObject().put("hour", 7.5).put("minute", 0)),
            daily().put("daily", JSONObject().put("hour", 7).put("minute", 0).put("weekday", 1)),
            daily().put("daily", JSONObject().put("hour", true).put("minute", 0)),
            daily().put("daily", "20:00"),
            daily(key = "has space"), daily(key = "x".repeat(65)), daily().put("key", 7),
            daily().put("title", "   "), daily().put("title", "é".repeat(129)), daily().put("body", "x".repeat(1025)), daily().put("body", "line\nbreak"),
            daily().put("sound", "loud"),
        )
        for (options in bad) assertRejects("invalid_options") { NotificationRules.parse(OWNER, options, now) }
        NotificationRules.parse(OWNER, daily().put("title", "é".repeat(128)).put("body", "x".repeat(1024)), now)
        NotificationRules.parse(OWNER, once(date = "2027-11-13T12:00:00Z"), now) // exactly 366 days
    }

    @Test fun dailyTriggerUsesTheLocalClock() {
        val evening = NotificationRules.parse(OWNER, daily(hour = 20), now)
        assertEquals(IsoDates.parse("2026-11-12T20:00:00-08:00"), NotificationRules.nextTrigger(evening, now, zone))
        val early = NotificationRules.parse(OWNER, daily(hour = 3, minute = 30), now)
        assertEquals(IsoDates.parse("2026-11-13T03:30:00-08:00"), NotificationRules.nextTrigger(early, now, zone))
        val exactlyNow = NotificationRules.parse(OWNER, daily(hour = 4, minute = 0), now)
        assertEquals(IsoDates.parse("2026-11-13T04:00:00-08:00"), NotificationRules.nextTrigger(exactlyNow, now, zone))
        // Across the end of daylight saving the reminder stays at 20:00 local time.
        val beforeChange = IsoDates.parse("2026-10-31T21:00:00-07:00")!!
        assertEquals(IsoDates.parse("2026-11-01T20:00:00-08:00"), NotificationRules.nextTrigger(evening, beforeChange, zone))
        val single = NotificationRules.parse(OWNER, once(), now)
        assertEquals(single.date, NotificationRules.nextTrigger(single, now, zone))
    }

    @Test fun capacityIs32PerInstallationAnd60Overall() {
        fun entries(owner: String, count: Int) = (0 until count).map { ScheduledNotification(owner, "k$it", "t", "b", null, 8, 0) }
        val mine = entries(OWNER, 32)
        assertFalse(NotificationRules.hasCapacity(mine, OWNER, "new"))
        assertTrue(NotificationRules.hasCapacity(mine, OWNER, "k5")) // replacing
        assertTrue(NotificationRules.hasCapacity(mine, OTHER_OWNER, "new"))
        val crowded = entries(OWNER, 30) + entries(OTHER_OWNER, 30)
        assertFalse(NotificationRules.hasCapacity(crowded, OWNER, "new"))
        assertTrue(NotificationRules.hasCapacity(crowded, OWNER, "k0"))
    }

    @Test fun gateOrder() {
        assertRejects("permission_denied") { module.status(context(emptySet())) }
        assertRejects("permission_denied") { module.schedule(context(declared, action = true, runtime = "1.4"), daily()) }
        assertRejects("read_only") { module.schedule(context(declared), daily()) }
        assertRejects("read_only") { module.cancel(context(declared), "reading") }
        assertRejects("read_only") { module.pending(context(declared, projection = true)) }
        assertRejects("read_only") { module.status(context(declared, liveActivity = true)) }
        assertRejects("permission_denied") { module.schedule(context(declared, action = true, installation = "33333333-3333-4333-8333-333333333333"), daily()) }
        assertRejects("query_limit") { module.schedule(action(queries = 0), daily()) }
        assertRejects("invalid_options") { module.schedule(action(), daily(hour = 99)) }
        assertRejects("invalid_options") { module.schedule(action(), null) }
        assertRejects("invalid_options") { module.cancel(action(), "not a key") }
        assertRejects("invalid_options") { module.cancel(action(), null) }
        platform.allowed = false
        assertRejects("permission_denied") { module.schedule(action(), daily()) }
        assertEquals("notDetermined", module.status(context(declared)).getString("authorization"))
        prompts.markAsked(NotificationsModule.PROMPT)
        assertEquals("denied", module.status(context(declared)).getString("authorization"))
        platform.allowed = true
        assertEquals("authorized", module.status(context(declared)).getString("authorization"))
        assertTrue(platform.armed.isEmpty()); assertTrue(store.all().isEmpty())
    }

    @Test fun scheduleReplacesBySameKeyAndPendingIsPerInstallation() {
        assertEquals("{\"key\":\"reading\",\"status\":\"scheduled\"}", Canonical.encode(module.schedule(action(), daily())))
        module.schedule(action(), daily(hour = 21))
        module.schedule(action(), once())
        module.schedule(action(OTHER_OWNER), daily(key = "theirs"))
        assertEquals(3, store.all().size)
        assertEquals(IsoDates.parse("2026-11-12T21:00:00-08:00"), platform.armed["$OWNER/reading"])
        val pending = module.pending(context(declared))
        assertEquals(listOf("reading", "one-time"), (0 until pending.length()).map { pending.getJSONObject(it).getString("key") })
        val reading = pending.getJSONObject(0)
        assertEquals(setOf("key", "title", "body", "repeats", "date"), reading.keys().asSequence().toSet())
        assertTrue(reading.getBoolean("repeats")); assertEquals("2026-11-13T05:00:00Z", reading.getString("date"))
        assertFalse(pending.getJSONObject(1).getBoolean("repeats")); assertEquals("2026-11-13T12:00:00Z", pending.getJSONObject(1).getString("date"))

        // Another installation cannot cancel or see this one's slot.
        module.cancel(action(OTHER_OWNER), "reading")
        assertEquals(2, module.pending(context(declared)).length())
        assertEquals("{\"key\":\"reading\",\"status\":\"cancellationRequested\"}", Canonical.encode(module.cancel(action(), "reading")))
        assertEquals(1, module.pending(context(declared)).length())
        assertFalse(platform.armed.containsKey("$OWNER/reading")); assertTrue(platform.armed.containsKey("$OTHER_OWNER/theirs"))
        module.retire(OTHER_OWNER)
        assertEquals(listOf("one-time"), store.all().map { it.key })
    }

    @Test fun limitsAndFailures() {
        repeat(32) { module.schedule(action(), daily(key = "k$it")) }
        assertRejects("limit_exceeded") { module.schedule(action(), daily(key = "one-more")) }
        module.schedule(action(), daily(key = "k3", hour = 6)) // replacing still works at capacity
        assertEquals(32, store.all().size)
        platform.fail = true
        module.cancel(action(), "k0")
        assertRejects("unavailable") { module.schedule(action(), daily(key = "k0")) }
        assertEquals(31, store.all().size) // a refused alarm leaves no pending slot behind
        File(directory, "notifications.json").writeText("{\"pending\":[{\"owner\":\"x\"}]}")
        assertRejects("unavailable") { module.pending(context(declared)) }
        assertRejects("unavailable") { module.schedule(action(), daily()) }
    }

    @Test fun revokedGrantStopsEveryCall() {
        module.schedule(action(), daily())
        grants.set(OWNER, "notifications", false)
        assertRejects("permission_denied") { module.pending(context(declared)) }
        assertRejects("permission_denied") { module.cancel(action(), "reading") }
        assertEquals(1, store.all().size)
    }
}
