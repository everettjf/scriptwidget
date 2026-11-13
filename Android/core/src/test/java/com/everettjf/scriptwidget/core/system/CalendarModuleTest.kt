package com.everettjf.scriptwidget.core.system

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.time.ZoneId

class CalendarModuleTest {
    private class FakePlatform : CalendarPlatform {
        var read = true
        var write = true
        var sources = listOf(CalendarSource("1", "Personal", true), CalendarSource("2", "Work", true), CalendarSource("3", "Holidays", false))
        var events = ArrayList<CalendarEvent>()
        var recurring = HashSet<String>()
        var truncated = false
        var queries = 0
        var inserts = 0
        var updates = 0
        var failWrites = false
        override fun canRead() = read
        override fun canWrite() = write
        override fun sources() = sources
        override fun events(start: Long, end: Long, calendarIDs: List<String>): Pair<List<CalendarEvent>, Boolean> { queries += 1; return events.filter { it.calendarID in calendarIDs } to truncated }
        override fun insert(calendarID: String, title: String, start: Long, end: Long, allDay: Boolean): String? {
            if (failWrites) throw IllegalStateException("provider unavailable")
            inserts += 1
            val id = (100 + inserts).toString()
            events += CalendarEvent(id, calendarID, title, start, end, allDay)
            return id
        }
        override fun update(eventID: String, title: String, start: Long, end: Long, allDay: Boolean): Boolean {
            val index = events.indexOfFirst { it.id == eventID }
            if (index < 0) return false
            updates += 1
            events[index] = CalendarEvent(eventID, events[index].calendarID, title, start, end, allDay)
            return true
        }
        override fun event(eventID: String): CalendarEventInfo? = events.firstOrNull { it.id == eventID }?.let { CalendarEventInfo(it.calendarID, eventID in recurring) }
    }

    private val zone = ZoneId.of("America/Los_Angeles")
    private val directory = temporaryDirectory()
    private var now = NOW
    private val platform = FakePlatform()
    private val selections = CalendarSelectionStore(PrivateFile(File(directory, "calendar-access.v1.json"), 128 * 1024))
    private val grants = grantsIn(directory, "calendarWrite")
    private val module = CalendarModule(platform, selections, grants, promptsIn(directory), File(directory, "calendar"), { now }, { zone })
    private val reader = setOf("calendar")
    private val writer = setOf("calendar", "calendarWrite")
    private val hour = 3_600_000L

    private fun event(id: String, calendar: String, startOffsetHours: Int, title: String = "Event $id") = CalendarEvent(id, calendar, title, now + startOffsetHours * hour, now + (startOffsetHours + 1) * hour, false)
    private fun window() = JSONObject().put("start", IsoDates.format(now - hour)).put("end", IsoDates.format(now + 24 * hour))
    private fun writeOptions(requestID: String = REQUEST_A, calendarID: String = "1", title: String = "Focus") = JSONObject()
        .put("requestID", requestID).put("calendarID", calendarID).put("title", title).put("start", "2026-11-13T12:00:00Z").put("end", "2026-11-13T12:30:00Z").put("allDay", false)

    // MARK: - Query parsing

    @Test fun queryDefaultsToTheLocalDayAcrossDaylightSaving() {
        val query = CalendarQuery.parse(null, NOW, zone)
        assertEquals(IsoDates.parse("2026-11-12T00:00:00-08:00"), query.start)
        assertEquals(24 * hour, query.end - query.start)
        assertEquals(10, query.limit); assertEquals(60.0, query.maxAgeSeconds, 0.0); assertTrue(query.calendarIDs.isEmpty())
        // 2026-11-01 is the 25-hour day on which Pacific time leaves daylight saving.
        val fallBack = CalendarQuery.parse(null, IsoDates.parse("2026-11-01T12:00:00-08:00")!!, zone)
        assertEquals(25 * hour, fallBack.end - fallBack.start)
    }

    @Test fun queryBounds() {
        fun parse(options: JSONObject) = CalendarQuery.parse(options, NOW, zone)
        val start = "2026-11-01T00:00:00Z"
        assertEquals(50, parse(JSONObject().put("limit", 50)).limit)
        parse(JSONObject().put("start", start).put("end", "2026-12-02T00:00:00Z"))
        assertRejectsWith("[invalid_options] Calendar range must be positive and at most 31 days") { parse(JSONObject().put("start", start).put("end", "2026-12-02T00:00:01Z")) }
        assertRejectsWith("[invalid_options] Calendar range must be positive and at most 31 days") { parse(JSONObject().put("start", start).put("end", start)) }
        assertRejectsWith("[invalid_options] Unknown calendar query option") { parse(JSONObject().put("notes", true)) }
        assertRejectsWith("[invalid_options] start must be an ISO-8601 string") { parse(JSONObject().put("start", "2026-11-01")) }
        assertRejectsWith("[invalid_options] start must be an ISO-8601 string") { parse(JSONObject().put("start", 5)) }
        assertRejectsWith("[invalid_options] Invalid end date") { parse(JSONObject().put("end", "2026-02-31T00:00:00Z")) }
        assertRejectsWith("[invalid_options] Invalid limit") { parse(JSONObject().put("limit", 51)) }
        assertRejectsWith("[invalid_options] Invalid limit") { parse(JSONObject().put("limit", 0)) }
        assertRejectsWith("[invalid_options] Invalid limit") { parse(JSONObject().put("limit", true)) }
        assertRejectsWith("[invalid_options] limit must be an integer") { parse(JSONObject().put("limit", 2.5)) }
        assertRejectsWith("[invalid_options] Invalid maxAgeSeconds") { parse(JSONObject().put("maxAgeSeconds", 86_401)) }
        assertRejectsWith("[invalid_options] calendarIDs must contain 1–16 unique identifiers") { parse(JSONObject().put("calendarIDs", JSONArray())) }
        assertRejectsWith("[invalid_options] calendarIDs must contain 1–16 unique identifiers") { parse(JSONObject().put("calendarIDs", JSONArray(listOf("a", "a")))) }
        assertRejectsWith("[invalid_options] calendarIDs must contain 1–16 unique identifiers") { parse(JSONObject().put("calendarIDs", JSONArray((1..17).map { "c$it" }))) }
        assertRejectsWith("[invalid_options] calendarIDs must contain 1–16 unique identifiers") { parse(JSONObject().put("calendarIDs", JSONArray(listOf("x".repeat(257))))) }
        assertRejectsWith("[invalid_options] calendarIDs must contain 1–16 unique identifiers") { parse(JSONObject().put("calendarIDs", "1")) }
        assertEquals(listOf("1", "2"), parse(JSONObject().put("calendarIDs", JSONArray(listOf("2", "1")))).calendarIDs)
        assertNotEquals(parse(JSONObject().put("limit", 5)).cacheIdentity, parse(JSONObject().put("limit", 6)).cacheIdentity)
    }

    // MARK: - Selection

    @Test fun selectionDecodingFailsClosed() {
        assertEquals(CalendarSelection(listOf("2", "1")), CalendarSelection.decode(CalendarSelection(listOf("1", "2")).encoded))
        assertEquals(CalendarSelection.ALL, CalendarSelection.decode(CalendarSelection.ALL.encoded))
        assertNotEquals(CalendarSelection.ALL.identity, CalendarSelection.NONE.identity)
        for (bad in listOf("{}", "not json", "{\"formatVersion\":2,\"mode\":\"all\",\"calendarIDs\":[]}", "{\"formatVersion\":1,\"mode\":\"all\",\"calendarIDs\":[\"1\"]}",
            "{\"formatVersion\":1,\"mode\":\"some\",\"calendarIDs\":[]}", "{\"formatVersion\":1,\"mode\":\"selected\",\"calendarIDs\":[\"1\",\"1\"]}",
            "{\"formatVersion\":1,\"mode\":\"selected\",\"calendarIDs\":[1]}", "{\"formatVersion\":1,\"mode\":\"selected\",\"calendarIDs\":[],\"extra\":1}")) {
            assertRejectsWith(CalendarAccessError.UNAVAILABLE.message) { CalendarSelection.decode(bad) }
        }
        // Android default: nothing is selected until the user chooses calendars.
        assertEquals(CalendarSelection.NONE, selections.load())
    }

    @Test fun permittedIDsNeverExceedTheSelection() {
        val available = listOf("1", "2", "3")
        assertEquals(listOf("1", "2", "3"), CalendarSelection.ALL.permittedIDs(available, emptyList()))
        assertEquals(listOf("2"), CalendarSelection(listOf("2", "9")).permittedIDs(available, emptyList()))
        assertEquals(listOf("2"), CalendarSelection(listOf("1", "2")).permittedIDs(available, listOf("2")))
        assertRejectsWith(CalendarAccessError.OUTSIDE_SELECTION.message) { CalendarSelection(listOf("1")).permittedIDs(available, listOf("2")) }
        assertRejectsWith(CalendarAccessError.OUTSIDE_SELECTION.message) { CalendarSelection.ALL.permittedIDs(available, listOf("9")) }
        assertRejectsWith(CalendarAccessError.OUTSIDE_SELECTION.message) { CalendarSelection(listOf("9")).permittedIDs(available, emptyList()) }
        assertRejectsWith(CalendarAccessError.NONE_SELECTED.message) { CalendarSelection.NONE.permittedIDs(available, emptyList()) }
    }

    // MARK: - Reads

    @Test fun readGateOrder() {
        selections.save(CalendarSelection.ALL)
        val install = "[permission_denied] Install this widget and declare calendar in widget.json"
        assertRejectsWith(install) { module.events(context(emptySet()), JSONObject().put("bogus", 1)) }
        assertRejectsWith(install) { module.events(context(reader, hasManifest = false), null) }
        assertRejectsWith(install) { module.calendars(context(reader, installation = "preview")) }
        // Options are validated before the budget is charged and before authorization is consulted.
        platform.read = false; platform.write = false
        assertRejectsWith("[invalid_options] Unknown calendar query option") { module.events(context(reader, queries = 0), JSONObject().put("bogus", 1)) }
        assertRejectsWith("[query_limit] Too many system data queries") { module.events(context(reader, queries = 0), null) }
        assertRejectsWith("[permission_denied] Allow calendar access in ScriptWidget") { module.events(context(reader), null) }
        assertEquals("notDetermined", module.authorizationStatus(context(reader)))
        assertEquals("undeclared", module.authorizationStatus(context(emptySet())))
        assertFalse(module.requestAuthorization(context(reader)))
        platform.write = true
        assertEquals("writeOnly", module.authorizationStatus(context(reader)))
        platform.read = true
        assertEquals("authorized", module.authorizationStatus(context(reader)))
        assertTrue(module.requestAuthorization(context(reader)))
        File(directory, "calendar-access.v1.json").writeText("{broken")
        assertRejectsWith(CalendarAccessError.UNAVAILABLE.message) { module.events(context(reader), null) }
        assertRejectsWith(CalendarAccessError.UNAVAILABLE.message) { module.calendars(context(reader)) }
    }

    @Test fun nothingSelectedIsASetupStateNotAnEmptyAgenda() {
        platform.events += event("a", "1", 1)
        assertRejectsWith("[permission_denied] No Calendar sources are selected in ScriptWidget Settings.") { module.events(context(reader), window()) }
        assertEquals(0, module.calendars(context(reader)).length())
        assertEquals(0, platform.queries)
    }

    @Test fun eventsAreFilteredSortedAndTruncated() {
        selections.save(CalendarSelection(listOf("1", "2")))
        platform.events += listOf(event("b", "1", 3), event("a", "1", 3), event("c", "2", 1), event("d", "3", 2), event("late", "1", 30), event("early", "1", -5))
        val result = module.events(context(reader), window().put("limit", 2))
        assertEquals(listOf("c", "a"), (0 until 2).map { result.getJSONArray("items").getJSONObject(it).getString("id") })
        assertEquals("ready", result.getString("status")); assertEquals("system", result.getString("source"))
        assertFalse(result.getBoolean("stale")); assertTrue(result.getBoolean("truncated"))
        assertEquals(setOf("status", "items", "fetchedAt", "source", "stale", "truncated"), result.keys().asSequence().toSet())
        assertEquals(setOf("id", "calendarID", "title", "start", "end", "allDay"), result.getJSONArray("items").getJSONObject(0).keys().asSequence().toSet())
        assertEquals(listOf("1", "2"), module.calendars(context(reader)).let { rows -> (0 until rows.length()).map { rows.getJSONObject(it).getString("id") } })

        val narrowed = module.events(context(reader), window().put("calendarIDs", JSONArray(listOf("2"))).put("maxAgeSeconds", 0))
        assertEquals(1, narrowed.getJSONArray("items").length()); assertFalse(narrowed.getBoolean("truncated"))
        assertRejectsWith(CalendarAccessError.OUTSIDE_SELECTION.message) { module.events(context(reader), window().put("calendarIDs", JSONArray(listOf("3"))).put("maxAgeSeconds", 0)) }
        platform.events.clear()
        assertEquals("empty", module.events(context(reader), window().put("maxAgeSeconds", 0)).getString("status"))
    }

    @Test fun cacheIsScopedToQuerySelectionAndAge() {
        selections.save(CalendarSelection(listOf("1", "2")))
        platform.events += listOf(event("a", "1", 1), event("c", "2", 2))
        val fixedWindow = window().toString()
        val options = { JSONObject(fixedWindow).put("maxAgeSeconds", 3600) }
        assertEquals("system", module.events(context(reader), options()).getString("source"))
        now += 30_000
        val cached = module.events(context(reader), options())
        assertEquals("cache", cached.getString("source")); assertFalse(cached.getBoolean("stale"))
        now += 60_000
        // Older than 60 seconds is stale even though the caller allows an hour.
        assertTrue(module.events(context(reader), options()).getBoolean("stale"))
        assertEquals(1, platform.queries)
        // maxAgeSeconds 0 bypasses the cache; a different query never reuses the snapshot.
        assertEquals("system", module.events(context(reader), JSONObject(fixedWindow).put("maxAgeSeconds", 0)).getString("source"))
        assertEquals("system", module.events(context(reader), options().put("limit", 3)).getString("source"))
        // Future entries may only use a matching snapshot.
        assertEquals("cache", module.events(context(reader, projection = true), options().put("limit", 3)).getString("source"))
        assertRejectsWith("[timeline_read_only] No matching Calendar snapshot is available") { module.events(context(reader, projection = true), options().put("limit", 4)) }
        assertRejectsWith("[timeline_read_only] No matching Calendar snapshot is available") { module.calendars(context(reader, projection = true)) }
        // Narrowing the selection invalidates the broader snapshot, also for future entries.
        selections.save(CalendarSelection(listOf("1")))
        assertRejectsWith("[timeline_read_only] No matching Calendar snapshot is available") { module.events(context(reader, projection = true), options().put("limit", 3)) }
        val narrowed = module.events(context(reader), options().put("limit", 3))
        assertEquals("system", narrowed.getString("source")); assertEquals(1, narrowed.getJSONArray("items").length())
    }

    @Test fun cacheDecodingValidatesUntrustedContent() {
        val query = CalendarQuery.parse(window().put("maxAgeSeconds", 3600), now, zone)
        val selection = CalendarSelection(listOf("1"))
        val value = CalendarResults.build(query, listOf("1"), listOf(event("a", "1", 1)), false, now)
        val encoded = CalendarResults.encodeCache(query, selection, value, now)
        assertNotNull(CalendarResults.decodeCache(encoded, query, selection, now + 1000))
        assertNull(CalendarResults.decodeCache(encoded, query, selection, now - 1000)) // from the future
        assertNull(CalendarResults.decodeCache(encoded, query, selection, now + 3_601_000)) // too old
        assertNull(CalendarResults.decodeCache(encoded, query, CalendarSelection(listOf("2")), now))
        assertNull(CalendarResults.decodeCache(encoded, CalendarQuery.parse(window().put("maxAgeSeconds", 0), now, zone), selection, now))
        val foreign = JSONObject(encoded).apply { getJSONObject("value").getJSONArray("items").getJSONObject(0).put("calendarID", "2") }
        assertNull(CalendarResults.decodeCache(foreign.toString(), query, selection, now))
        val extra = JSONObject(encoded).apply { getJSONObject("value").getJSONArray("items").getJSONObject(0).put("notes", "secret") }
        assertNull(CalendarResults.decodeCache(extra.toString(), query, selection, now))
        assertNull(CalendarResults.decodeCache("x".repeat(70_000), query, selection, now))
    }

    @Test fun revocationDuringAQueryRejectsAndClearsTheSnapshot() {
        selections.save(CalendarSelection.ALL)
        platform.events += event("a", "1", 1)
        module.events(context(reader), window().put("maxAgeSeconds", 3600))
        val revoking = object : CalendarPlatform by platform {
            override fun events(start: Long, end: Long, calendarIDs: List<String>): Pair<List<CalendarEvent>, Boolean> { platform.read = false; return platform.events(start, end, calendarIDs) }
        }
        val second = CalendarModule(revoking, selections, grants, promptsIn(directory), File(directory, "calendar"), { now }, { zone })
        assertRejectsWith("[permission_denied] Calendar access was revoked") { second.events(context(reader), window().put("maxAgeSeconds", 0)) }
        platform.read = true
        assertEquals("system", module.events(context(reader), window().put("maxAgeSeconds", 3600)).getString("source"))
    }

    @Test fun titlesAreBoundedAndAllDayDatesAreLocalMidnights() {
        assertEquals(1024, CalendarResults.bounded("é".repeat(600), 1024).toByteArray().size)
        assertEquals("ab", CalendarResults.bounded("ab😀", 5))
        val utcMidnight = IsoDates.parse("2026-11-12T00:00:00Z")!!
        val localMidnight = IsoDates.parse("2026-11-12T00:00:00-08:00")!!
        assertEquals(localMidnight, AllDayDates.utcToLocal(utcMidnight, zone))
        assertEquals(utcMidnight, AllDayDates.localToUtc(localMidnight, zone))
        assertEquals(utcMidnight + 24 * hour, AllDayDates.localToUtc(localMidnight + hour, zone, roundUp = true))
        assertEquals(utcMidnight, AllDayDates.localToUtc(localMidnight, zone, roundUp = true))
    }

    // MARK: - Writes

    @Test fun writeGateOrder() {
        selections.save(CalendarSelection.ALL)
        assertRejects("permission_denied") { module.mutate(context(reader, action = true), writeOptions(), false) }
        assertRejects("permission_denied") { module.mutate(context(writer, action = true, runtime = "1.5"), writeOptions(), false) }
        assertRejects("read_only") { module.mutate(context(writer), writeOptions(), false) }
        assertRejects("read_only") { module.mutate(context(writer, action = true, projection = true), writeOptions(), false) }
        assertRejects("permission_denied") { module.mutate(context(writer, action = true, installation = OTHER_OWNER), writeOptions(), false) }
        assertRejects("query_limit") { module.mutate(context(writer, action = true, queries = 0), writeOptions(), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions().put("notes", "x"), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions(requestID = REQUEST_A.uppercase()), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions().put("end", "2026-11-13T12:00:00Z"), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions().put("end", "2027-11-15T12:00:00Z"), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions(title = "x".repeat(513)), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions().put("allDay", 1), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), writeOptions().put("id", "101"), false) }
        assertRejects("invalid_options") { module.mutate(context(writer, action = true), null, false) }
        // The calendar permission, full system access, the selection and a writable calendar.
        assertRejects("permission_denied") { module.mutate(context(setOf("calendarWrite"), action = true), writeOptions(), false) }
        platform.write = false
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions(), false) }
        platform.write = true
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions(calendarID = "3"), false) }
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions(calendarID = "9"), false) }
        selections.save(CalendarSelection(listOf("2")))
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions(), false) }
        assertEquals(0, platform.inserts)
    }

    @Test fun createReplaysAndUpdateIsLimitedToOwnedEvents() {
        selections.save(CalendarSelection.ALL)
        val created = module.mutate(context(writer, action = true), writeOptions(), false)
        assertEquals("applied", created.getString("status")); assertFalse(created.getBoolean("replayed")); assertEquals("1", created.getString("calendarID"))
        assertEquals(setOf("id", "calendarID", "status", "replayed"), created.keys().asSequence().toSet())
        val replay = module.mutate(context(writer, action = true), writeOptions(), false)
        assertEquals(created.getString("id"), replay.getString("id")); assertTrue(replay.getBoolean("replayed"))
        assertEquals(1, platform.inserts)
        assertRejects("request_conflict") { module.mutate(context(writer, action = true), writeOptions(title = "Other"), false) }

        val id = created.getString("id")
        val updated = module.mutate(context(writer, action = true), writeOptions(REQUEST_B, title = "Updated").put("id", id), true)
        assertEquals(id, updated.getString("id")); assertEquals(1, platform.updates)
        assertEquals("Updated", platform.events.first { it.id == id }.title)

        // An event the installation did not create, even in a permitted calendar.
        platform.events += event("900", "1", 1)
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions("cccccccc-cccc-4ccc-8ccc-cccccccccccc").put("id", "900"), true) }
        // Another installation cannot update this one's event.
        grants.set(OTHER_OWNER, "calendarWrite", true)
        assertRejects("permission_denied") { module.mutate(context(writer, action = true, installation = OTHER_OWNER), writeOptions("dddddddd-dddd-4ddd-8ddd-dddddddddddd").put("id", id), true) }
        // The owned event moved to another calendar id in the request, or became recurring.
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", calendarID = "2").put("id", id), true) }
        platform.recurring += id
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions("ffffffff-ffff-4fff-8fff-ffffffffffff").put("id", id), true) }
        assertEquals(1, platform.updates)
    }

    @Test fun aFailedProviderWriteIsAnUnknownOutcomeThatIsNotRetried() {
        selections.save(CalendarSelection.ALL)
        platform.failWrites = true
        assertRejects("outcome_unknown") { module.mutate(context(writer, action = true), writeOptions(), false) }
        platform.failWrites = false
        assertRejects("outcome_unknown") { module.mutate(context(writer, action = true), writeOptions(), false) }
        assertEquals(0, platform.inserts)
    }

    @Test fun revokedGrantStopsWrites() {
        selections.save(CalendarSelection.ALL)
        grants.set(OWNER, "calendarWrite", false)
        assertRejects("permission_denied") { module.mutate(context(writer, action = true), writeOptions(), false) }
        assertEquals(0, platform.inserts)
    }
}
