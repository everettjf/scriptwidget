package com.everettjf.scriptwidget.core.system

import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.SleepSessionRecord
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class HealthModuleTest {
    private class FakePlatform : HealthPlatform {
        var available = true
        var fail = false
        val values = HashMap<HealthMetric, (HealthWindow) -> Double?>()
        var heart: HealthHeartRate? = null
        var sleep = HealthSleepPage(emptyList(), false)
        var records = emptyList<HealthWorkoutRecord>()
        val calls = ArrayList<String>()
        var workoutLimit = 0

        private fun <T> answer(name: String, value: () -> T): T { calls += name; if (fail) throw IllegalStateException("provider said 8421 steps"); return value() }
        override fun isAvailable() = available
        override fun aggregate(metric: HealthMetric, windows: List<HealthWindow>): List<Double?> = answer("aggregate:$metric") { windows.map { values[metric]?.invoke(it) } }
        override fun latestHeartRate(before: Long): HealthHeartRate? = answer("heart") { heart }
        override fun sleepSessions(start: Long, end: Long): HealthSleepPage = answer("sleep") { sleep }
        override fun workouts(start: Long, end: Long, limit: Int): List<HealthWorkoutRecord> = answer("workouts") { workoutLimit = limit; records.take(limit) }
    }

    private val zone = ZoneId.of("America/Los_Angeles")
    private val now = NOW // 2026-11-12T12:00:00Z, 04:00 local time
    private val hour = 3_600_000L
    private val platform = FakePlatform()
    private val prompts = promptsIn(temporaryDirectory())
    private val module = HealthModule(platform, prompts, { now }, { zone })
    private val declared = setOf("health")
    private fun ms(text: String): Long = IsoDates.parse(text)!!
    private fun options(vararg pairs: Pair<String, Any?>): JSONObject = JSONObject().apply { pairs.forEach { put(it.first, it.second ?: JSONObject.NULL) } }
    private fun query(kind: HealthReadQuery.Kind, options: JSONObject? = null) = HealthReadQuery.parse(kind, options, now, zone)

    // MARK: Options and bounds

    @Test fun sleepAndWorkoutRangeValidation() {
        val sleep = query(HealthReadQuery.Kind.SLEEP)
        assertEquals(now, sleep.end); assertEquals(now - 24 * hour, sleep.start); assertEquals(256, sleep.limit)
        val workouts = query(HealthReadQuery.Kind.WORKOUTS)
        assertEquals(now - 7 * 24 * hour, workouts.start); assertEquals(5, workouts.limit)
        // Exactly the maximum range, fractional seconds and offsets are accepted; `end` may be one second ahead of the clock.
        assertEquals(7 * 24 * hour, query(HealthReadQuery.Kind.SLEEP, options("start" to "2026-11-05T12:00:00Z")).let { it.end - it.start })
        assertEquals(31 * 24 * hour, query(HealthReadQuery.Kind.WORKOUTS, options("start" to "2026-10-12T12:00:00.000Z", "limit" to 50)).let { it.end - it.start })
        assertEquals(ms("2026-11-12T11:00:00Z"), query(HealthReadQuery.Kind.SLEEP, options("start" to "2026-11-12T01:00:00-08:00", "end" to "2026-11-12T03:00:00.5-08:00")).end - 500)
        query(HealthReadQuery.Kind.SLEEP, options("end" to "2026-11-12T12:00:01Z"))
        assertEquals(1, query(HealthReadQuery.Kind.WORKOUTS, options("limit" to 1.0)).limit)

        val badSleep = listOf(
            options("start" to "2026-11-05T11:59:59Z"), // more than seven days
            options("end" to "2026-11-12T12:00:02Z"), // future end
            options("start" to "2026-11-12T12:00:00Z"), // empty range
            options("start" to "2026-11-12T11:00:00Z", "end" to "2026-11-12T10:00:00Z"), // reversed
            options("start" to "2026-11-12"), options("start" to "yesterday"), options("start" to 1794484800000L), options("start" to null),
            options("start" to "2026-11-12T11:00:00"), // no zone
            options("start" to "2026-02-30T11:00:00Z"), options("start" to "2026-11-11T24:00:00Z"), options("start" to "2026-11-11T11:60:00Z"),
            options("start" to "0000-11-11T11:00:00Z"), options("end" to "2026-11-12T11:00:00+24:00"),
            options("limit" to 5), options("date" to "2026-11-12"), options("unknown" to true),
        )
        for (bad in badSleep) assertRejectsWith(HealthError.INVALID_OPTIONS.message) { query(HealthReadQuery.Kind.SLEEP, bad) }
        val badWorkouts = listOf(
            options("start" to "2026-10-12T11:59:59Z"), // more than 31 days
            options("limit" to 0), options("limit" to 51), options("limit" to 2.5), options("limit" to "5"), options("limit" to true), options("limit" to null),
            options("maxAgeSeconds" to 5),
        )
        for (bad in badWorkouts) assertRejectsWith(HealthError.INVALID_OPTIONS.message) { query(HealthReadQuery.Kind.WORKOUTS, bad) }
    }

    @Test fun activityDayValidationAndDstDays() {
        val today = query(HealthReadQuery.Kind.ACTIVITY)
        assertEquals("2026-11-12", today.day)
        assertEquals(ms("2026-11-12T00:00:00-08:00"), today.start); assertEquals(ms("2026-11-13T00:00:00-08:00"), today.end)
        // The day clocks go back is 25 hours long, the day they go forward 23.
        val fallBack = query(HealthReadQuery.Kind.ACTIVITY, options("date" to "2026-11-01"))
        assertEquals(25 * hour, fallBack.end - fallBack.start); assertEquals("2026-11-01", fallBack.day)
        val springForward = query(HealthReadQuery.Kind.ACTIVITY, options("date" to "2026-03-08"))
        assertEquals(23 * hour, springForward.end - springForward.start)
        assertEquals(ms("2026-03-08T00:00:00-08:00"), springForward.start); assertEquals(ms("2026-03-09T00:00:00-07:00"), springForward.end)
        // Late evening UTC-wise is still "today" locally; tomorrow is the future.
        for (bad in listOf(options("date" to "2026-11-13"), options("date" to "2026-02-30"), options("date" to "2026-1-5"), options("date" to "0000-01-01"),
            options("date" to 20261112), options("date" to null), options("date" to "2026-11-12T00:00:00Z"), options("start" to "2026-11-12T00:00:00Z"))) {
            assertRejectsWith(HealthError.INVALID_OPTIONS.message) { query(HealthReadQuery.Kind.ACTIVITY, bad) }
        }
        assertEquals(LocalDate.of(2024, 2, 29), HealthDays.parse("2024-02-29")); assertNull(HealthDays.parse("2023-02-29"))
    }

    @Test fun historyOptionValidation() {
        assertEquals(7, HealthHistoryOptions.parse(options("metric" to "steps")).days)
        assertEquals(HealthMetric.BODY_MASS, HealthHistoryOptions.parse(options("metric" to "bodyMass", "days" to 31)).metric)
        assertEquals(1, HealthHistoryOptions.parse(options("metric" to "water", "days" to 1.0)).days)
        for (bad in listOf(JSONObject(), options("metric" to "sleep"), options("metric" to "exerciseMinutes"), options("metric" to 5), options("metric" to null),
            options("metric" to "steps", "days" to 0), options("metric" to "steps", "days" to 32), options("metric" to "steps", "days" to 2.5),
            options("metric" to "steps", "days" to "7"), options("metric" to "steps", "days" to true), options("metric" to "steps", "days" to null),
            options("metric" to "steps", "start" to "2026-11-01T00:00:00Z"), options("invalid" to true))) {
            assertRejects("invalid_options") { HealthHistoryOptions.parse(bad) }
        }
        assertEquals(listOf("steps", "activeEnergy", "walkingDistance", "water", "bodyMass", "heartRate"), HealthMetric.entries.mapNotNull { it.id })
    }

    // MARK: Day windows

    @Test fun dayWindowsFollowLocalMidnightsAcrossDst() {
        val windows = HealthDays.windows(14, now, zone)
        assertEquals(14, windows.size)
        assertEquals("2026-10-30", HealthDays.format(windows.first().first)); assertEquals("2026-11-12", HealthDays.format(windows.last().first))
        val lengths = windows.associate { HealthDays.format(it.first) to (it.second.end - it.second.start) }
        assertEquals(24 * hour, lengths["2026-10-31"]); assertEquals(25 * hour, lengths["2026-11-01"]); assertEquals(24 * hour, lengths["2026-11-02"])
        // The current partial day ends at the query time; every other window ends where the next begins.
        assertEquals(4 * hour, lengths["2026-11-12"]); assertEquals(now, windows.last().second.end)
        for (index in 0 until windows.size - 1) assertEquals(windows[index].second.end, windows[index + 1].second.start)
        assertEquals(ms("2026-11-01T00:00:00-07:00"), windows[2].second.start)

        val spring = HealthDays.windows(3, ms("2026-03-09T18:00:00Z"), zone)
        assertEquals(listOf(24 * hour, 23 * hour, 11 * hour), spring.map { it.second.end - it.second.start })
        assertEquals(ms("2026-11-12T00:00:00-08:00"), HealthDays.startOfDay(now, zone))
        // Just before local midnight the UTC date is already tomorrow.
        assertEquals("2026-11-12", HealthDays.format(HealthDays.windows(1, ms("2026-11-13T07:59:59Z"), zone).single().first))
        // A zone whose DST change skips midnight still yields increasing, gap-free windows.
        val skipped = HealthDays.windows(3, ms("2026-04-25T12:00:00Z"), ZoneId.of("Africa/Cairo"))
        for (index in 0 until skipped.size - 1) { assertTrue(skipped[index].second.end > skipped[index].second.start); assertEquals(skipped[index].second.end, skipped[index + 1].second.start) }
    }

    // MARK: Readings and hasSamples

    @Test fun todayReadingsKeepTheLegacyZeroAndReportSamples() {
        val context = context(declared)
        val empty = module.stepCountToday(context)
        assertEquals(0.0, empty.getDouble("value"), 0.0); assertFalse(empty.getBoolean("hasSamples")); assertEquals("count", empty.getString("unit"))
        assertEquals("2026-11-12T08:00:00.000Z", empty.getString("start")); assertEquals("2026-11-12T12:00:00.000Z", empty.getString("end"))
        assertEquals(setOf("value", "hasSamples", "unit", "start", "end"), empty.keys().asSequence().toSet())

        platform.values[HealthMetric.STEPS] = { window -> if (window.start == ms("2026-11-12T08:00:00Z") && window.end == now) 8421.0 else null }
        platform.values[HealthMetric.ACTIVE_ENERGY] = { 0.0 }
        val steps = module.stepCountToday(context)
        assertEquals(8421.0, steps.getDouble("value"), 0.0); assertTrue(steps.getBoolean("hasSamples"))
        // A measured zero is a sample.
        val energy = module.activeEnergyToday(context)
        assertEquals(0.0, energy.getDouble("value"), 0.0); assertTrue(energy.getBoolean("hasSamples")); assertEquals("kcal", energy.getString("unit"))

        platform.values[HealthMetric.STEPS] = { Double.NaN }
        assertRejectsWith(HealthError.QUERY_FAILED.message) { module.stepCountToday(context) }
        platform.values[HealthMetric.STEPS] = { -1.0 }
        assertRejectsWith(HealthError.QUERY_FAILED.message) { module.stepCountToday(context) }
    }

    @Test fun latestHeartRate() {
        val context = context(declared)
        val empty = module.heartRateLatest(context)
        assertEquals(0.0, empty.getDouble("value"), 0.0); assertFalse(empty.getBoolean("hasSamples")); assertEquals("bpm", empty.getString("unit"))
        assertEquals("", empty.getString("start")); assertEquals("", empty.getString("end"))
        platform.heart = HealthHeartRate(64.0, now - 90_500)
        val sample = module.heartRateLatest(context)
        assertEquals(64.0, sample.getDouble("value"), 0.0); assertTrue(sample.getBoolean("hasSamples"))
        assertEquals("2026-11-12T11:58:29.500Z", sample.getString("start")); assertEquals(sample.getString("start"), sample.getString("end"))
    }

    @Test fun dailyStatisticsShapeUnitsAndMissingDays() {
        val context = context(declared)
        platform.values[HealthMetric.STEPS] = { window -> when (window.start) { ms("2026-11-10T08:00:00Z") -> 0.0; ms("2026-11-12T08:00:00Z") -> 1200.0; else -> null } }
        val result = module.dailyStatistics(context, options("metric" to "steps", "days" to 3))
        assertEquals(setOf("metric", "unit", "aggregation", "timeZone", "items"), result.keys().asSequence().toSet())
        assertEquals("steps", result.getString("metric")); assertEquals("count", result.getString("unit")); assertEquals("sum", result.getString("aggregation"))
        assertEquals("America/Los_Angeles", result.getString("timeZone"))
        val items = result.getJSONArray("items")
        assertEquals(3, items.length())
        assertEquals("""{"date":"2026-11-10","value":0,"hasSamples":true}""", normal(items.getJSONObject(0)))
        assertEquals("2026-11-11", items.getJSONObject(1).getString("date")); assertTrue(items.getJSONObject(1).isNull("value")); assertFalse(items.getJSONObject(1).getBoolean("hasSamples"))
        assertEquals(1200.0, items.getJSONObject(2).getDouble("value"), 0.0)
        assertEquals(7, module.dailyStatistics(context(declared), options("metric" to "water")).getJSONArray("items").length())
        assertEquals(31, module.dailyStatistics(context(declared), options("metric" to "water", "days" to 31)).getJSONArray("items").length())

        val expected = mapOf("steps" to ("count" to "sum"), "activeEnergy" to ("kcal" to "sum"), "walkingDistance" to ("m" to "sum"),
            "water" to ("mL" to "sum"), "bodyMass" to ("kg" to "average"), "heartRate" to ("count/min" to "average"))
        for ((metric, shape) in expected) {
            val value = module.dailyStatistics(context(declared), options("metric" to metric, "days" to 1))
            assertEquals(metric, shape.first, value.getString("unit")); assertEquals(metric, shape.second, value.getString("aggregation"))
        }
        // An impossible value is dropped without turning the day into "no samples".
        platform.values[HealthMetric.BODY_MASS] = { -3.0 }
        val odd = module.dailyStatistics(context(declared), options("metric" to "bodyMass", "days" to 1)).getJSONArray("items").getJSONObject(0)
        assertTrue(odd.isNull("value")); assertTrue(odd.getBoolean("hasSamples"))
    }

    private fun normal(item: JSONObject): String = """{"date":"${item.getString("date")}","value":${if (item.isNull("value")) "null" else item.getDouble("value").toLong()},"hasSamples":${item.getBoolean("hasSamples")}}"""

    // MARK: Sleep

    private val bedtime = now - 10 * hour
    private fun stage(from: Double, to: Double, type: Int) = HealthSleepStage(bedtime + (from * hour).toLong(), bedtime + (to * hour).toLong(), type)
    private fun session(from: Double, to: Double, source: String, vararg stages: HealthSleepStage) = HealthSleepSession(bedtime + (from * hour).toLong(), bedtime + (to * hour).toLong(), source, stages.toList())

    @Test fun sleepUnionAndStagePrecedence() {
        platform.sleep = HealthSleepPage(listOf(
            session(0.0, 8.0, "watch", stage(0.0, 4.0, SleepSessionRecord.STAGE_TYPE_LIGHT), stage(1.0, 2.0, SleepSessionRecord.STAGE_TYPE_DEEP), stage(4.5, 5.0, SleepSessionRecord.STAGE_TYPE_AWAKE)),
            // A second source: a duplicate light interval, REM overlapping light and awake, then unspecified sleep.
            session(0.0, 7.0, "ring", stage(0.0, 1.0, SleepSessionRecord.STAGE_TYPE_LIGHT), stage(3.0, 5.0, SleepSessionRecord.STAGE_TYPE_REM), stage(5.0, 7.0, SleepSessionRecord.STAGE_TYPE_SLEEPING)),
        ), false)
        val result = module.sleepSummary(context(declared), null)
        assertEquals(setOf("start", "end", "timeZone", "hasSamples", "sourceCount", "truncated", "totalSleepSeconds", "inBedSeconds", "awakeSeconds", "conflictSeconds", "stages", "aggregation"),
            result.keys().asSequence().toSet())
        assertEquals("2026-11-11T12:00:00.000Z", result.getString("start")); assertEquals("2026-11-12T12:00:00.000Z", result.getString("end"))
        assertEquals("America/Los_Angeles", result.getString("timeZone")); assertEquals("union-awake-rem-deep-core-unspecified", result.getString("aggregation"))
        assertTrue(result.getBoolean("hasSamples")); assertFalse(result.getBoolean("truncated")); assertEquals(2, result.getInt("sourceCount"))
        val stages = result.getJSONObject("stages")
        assertEquals(setOf("unspecified", "core", "deep", "rem"), stages.keys().asSequence().toSet())
        assertEquals(7200.0, stages.getDouble("core"), 0.0) // 0–1 (counted once) and 2–3
        assertEquals(3600.0, stages.getDouble("deep"), 0.0) // deep beats core
        assertEquals(5400.0, stages.getDouble("rem"), 0.0) // 3–4.5: REM beats core, awake beats REM
        assertEquals(7200.0, stages.getDouble("unspecified"), 0.0)
        assertEquals(1800.0, result.getDouble("awakeSeconds"), 0.0)
        assertEquals(23400.0, result.getDouble("totalSleepSeconds"), 0.0)
        assertEquals(28800.0, result.getDouble("inBedSeconds"), 0.0) // union of both sessions, not their sum
        assertEquals(9000.0, result.getDouble("conflictSeconds"), 0.0) // core+deep 1 h, core+REM 1 h, REM+awake 0.5 h

        // Intervals are clipped to the query.
        val clipped = module.sleepSummary(context(declared), options("start" to IsoDates.format(bedtime + hour / 2), "end" to IsoDates.format(bedtime + 2 * hour)))
        assertEquals(1800.0, clipped.getJSONObject("stages").getDouble("core"), 0.0); assertEquals(3600.0, clipped.getJSONObject("stages").getDouble("deep"), 0.0)
        assertEquals(5400.0, clipped.getDouble("inBedSeconds"), 0.0)
    }

    @Test fun sleepStageMappingSessionsWithoutStagesAndEmptyResults() {
        assertEquals(HealthSleep.Stage.AWAKE, HealthSleep.stage(SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED)); assertEquals(HealthSleep.Stage.AWAKE, HealthSleep.stage(SleepSessionRecord.STAGE_TYPE_OUT_OF_BED))
        assertEquals(HealthSleep.Stage.CORE, HealthSleep.stage(SleepSessionRecord.STAGE_TYPE_LIGHT)); assertEquals(HealthSleep.Stage.UNSPECIFIED, HealthSleep.stage(SleepSessionRecord.STAGE_TYPE_SLEEPING))
        assertNull(HealthSleep.stage(SleepSessionRecord.STAGE_TYPE_UNKNOWN)); assertNull(HealthSleep.stage(99))

        // No stages: the app only said "asleep from start to end".
        platform.sleep = HealthSleepPage(listOf(session(0.0, 6.0, "phone")), false)
        val plain = module.sleepSummary(context(declared), null)
        assertEquals(21600.0, plain.getJSONObject("stages").getDouble("unspecified"), 0.0); assertEquals(21600.0, plain.getDouble("totalSleepSeconds"), 0.0)
        assertEquals(21600.0, plain.getDouble("inBedSeconds"), 0.0); assertEquals(0.0, plain.getDouble("conflictSeconds"), 0.0)
        // Only an uninformative stage: time in bed, no manufactured sleep.
        platform.sleep = HealthSleepPage(listOf(session(0.0, 6.0, "phone", stage(0.0, 6.0, SleepSessionRecord.STAGE_TYPE_UNKNOWN))), false)
        val unknown = module.sleepSummary(context(declared), null)
        assertEquals(0.0, unknown.getDouble("totalSleepSeconds"), 0.0); assertEquals(21600.0, unknown.getDouble("inBedSeconds"), 0.0); assertTrue(unknown.getBoolean("hasSamples"))

        platform.sleep = HealthSleepPage(emptyList(), false)
        val empty = module.sleepSummary(context(declared), null)
        assertFalse(empty.getBoolean("hasSamples")); assertEquals(0, empty.getInt("sourceCount"))
        for (key in listOf("totalSleepSeconds", "inBedSeconds", "awakeSeconds", "conflictSeconds")) assertEquals(key, 0.0, empty.getDouble(key), 0.0)
        // A session outside the window does not count as a sample.
        platform.sleep = HealthSleepPage(listOf(HealthSleepSession(now - 40 * hour, now - 30 * hour, "phone", emptyList())), false)
        assertFalse(module.sleepSummary(context(declared), null).getBoolean("hasSamples"))
    }

    @Test fun sleepIsBoundedTo256SegmentsAndRejectsInvalidData() {
        // 150 sessions without stages are 300 segments; the 256 ending last are kept.
        platform.sleep = HealthSleepPage((0 until 150).map { HealthSleepSession(now - (it + 1) * 600_000L, now - it * 600_000L, "s", emptyList()) }, false)
        val bounded = module.sleepSummary(context(declared), null)
        assertTrue(bounded.getBoolean("truncated")); assertEquals(128 * 600.0, bounded.getDouble("totalSleepSeconds"), 0.0)
        val (kept, truncated) = HealthSleep.recent(HealthSleep.segments(platform.sleep.sessions), false)
        assertEquals(256, kept.size); assertTrue(truncated); assertEquals(now, kept.first().end)
        // The platform saying more sessions exist is reported too.
        platform.sleep = HealthSleepPage(listOf(session(0.0, 6.0, "phone")), true)
        assertTrue(module.sleepSummary(context(declared), null).getBoolean("truncated"))

        platform.sleep = HealthSleepPage(listOf(HealthSleepSession(now - hour, now - hour, "phone", emptyList())), false)
        assertRejectsWith(HealthError.INVALID_DATA.message) { module.sleepSummary(context(declared), null) }
        val parsed = query(HealthReadQuery.Kind.SLEEP)
        assertRejectsWith(HealthError.INVALID_DATA.message) { HealthSleep.summary(parsed, List(257) { HealthSleep.Segment(now - hour, now, HealthSleep.Stage.CORE, "s") }, false) }
        assertRejectsWith(HealthError.INVALID_DATA.message) { HealthSleep.summary(parsed, listOf(HealthSleep.Segment(now - hour, now, HealthSleep.Stage.CORE, "x".repeat(257))), false) }
    }

    // MARK: Activity

    @Test fun activitySummaryReportsOnlyWhatHealthConnectKnows() {
        val context = context(declared)
        val empty = module.activitySummary(context, null)
        assertEquals(setOf("date", "timeZone", "hasSamples", "moveMode", "move", "exercise", "stand"), empty.keys().asSequence().toSet())
        assertEquals("2026-11-12", empty.getString("date")); assertFalse(empty.getBoolean("hasSamples")); assertEquals("activeEnergy", empty.getString("moveMode"))
        for ((ring, unit) in listOf("move" to "kcal", "exercise" to "min", "stand" to "count")) {
            val item = empty.getJSONObject(ring)
            assertEquals(0.0, item.getDouble("value"), 0.0); assertTrue(item.isNull("goal")); assertEquals(unit, item.getString("unit"))
        }

        val day = HealthWindow(ms("2026-11-01T00:00:00-07:00"), ms("2026-11-02T00:00:00-08:00"))
        platform.values[HealthMetric.ACTIVE_ENERGY] = { window -> if (window.start == day.start && window.end == day.end) 412.5 else null }
        platform.values[HealthMetric.EXERCISE_MINUTES] = { 0.0 }
        val full = module.activitySummary(context(declared), options("date" to "2026-11-01"))
        assertTrue(full.getBoolean("hasSamples")); assertEquals("2026-11-01", full.getString("date"))
        assertEquals(412.5, full.getJSONObject("move").getDouble("value"), 0.0)
        assertEquals(0.0, full.getJSONObject("exercise").getDouble("value"), 0.0) // a known zero
        // No stand measurement and no goals exist on Android; they are null, never inferred.
        assertTrue(full.getJSONObject("stand").isNull("value"))
        for (ring in listOf("move", "exercise", "stand")) assertTrue(full.getJSONObject(ring).isNull("goal"))

        platform.values.remove(HealthMetric.ACTIVE_ENERGY)
        val partial = module.activitySummary(context(declared), null)
        assertTrue(partial.getBoolean("hasSamples")); assertTrue(partial.getJSONObject("move").isNull("value"))
        platform.values[HealthMetric.EXERCISE_MINUTES] = { Double.POSITIVE_INFINITY }
        assertRejectsWith(HealthError.INVALID_DATA.message) { module.activitySummary(context(declared), null) }
    }

    // MARK: Workouts

    private fun workout(id: String, type: Int, startHoursAgo: Double, minutes: Int, energy: Double? = null, distance: Double? = null): HealthWorkoutRecord {
        val start = now - (startHoursAgo * hour).toLong()
        return HealthWorkoutRecord(id, type, start, start + minutes * 60_000L, energy, distance)
    }

    @Test fun workoutSummaries() {
        val run = workout("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA", ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, 30.0, 45, 380.0, 7200.0)
        val yoga = workout("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", ExerciseSessionRecord.EXERCISE_TYPE_YOGA, 5.0, 30, null, 12.0)
        val ride = workout("not-a-uuid", ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY, 50.0, 60, 0.0, null)
        platform.records = listOf(run, ride, yoga)
        val result = module.workouts(context(declared), options("limit" to 2))
        assertEquals(3, platform.workoutLimit) // one more than the limit, to detect truncation
        assertEquals(setOf("start", "end", "timeZone", "hasSamples", "truncated", "items"), result.keys().asSequence().toSet())
        assertEquals("2026-11-05T12:00:00.000Z", result.getString("start")); assertTrue(result.getBoolean("hasSamples")); assertTrue(result.getBoolean("truncated"))
        val items = result.getJSONArray("items")
        assertEquals(2, items.length())
        val first = items.getJSONObject(0)
        assertEquals(setOf("id", "activity", "start", "end", "duration", "energyKcal", "distanceMeters"), first.keys().asSequence().toSet())
        assertEquals("yoga", first.getString("activity")); assertEquals(1800.0, first.getDouble("duration"), 0.0)
        assertTrue(first.isNull("energyKcal")); assertTrue("no distance for yoga", first.isNull("distanceMeters"))
        assertEquals("2026-11-12T07:00:00.000Z", first.getString("start")); assertEquals("2026-11-12T07:30:00.000Z", first.getString("end"))
        val second = items.getJSONObject(1)
        assertEquals("running", second.getString("activity")); assertEquals("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", second.getString("id"))
        assertEquals(380.0, second.getDouble("energyKcal"), 0.0); assertEquals(7200.0, second.getDouble("distanceMeters"), 0.0)

        val all = module.workouts(context(declared), null).getJSONArray("items")
        assertEquals(3, all.length())
        val third = all.getJSONObject(2)
        assertEquals("cycling", third.getString("activity")); assertEquals(0.0, third.getDouble("energyKcal"), 0.0); assertTrue(third.isNull("distanceMeters"))
        assertTrue(Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$").matches(third.getString("id")))
        assertEquals(HealthWorkouts.identifier("not-a-uuid"), third.getString("id"))

        platform.records = emptyList()
        val empty = module.workouts(context(declared), null)
        assertFalse(empty.getBoolean("hasSamples")); assertFalse(empty.getBoolean("truncated")); assertEquals(0, empty.getJSONArray("items").length())
    }

    @Test fun workoutActivitiesAndInvalidData() {
        val names = mapOf(ExerciseSessionRecord.EXERCISE_TYPE_WALKING to "walking", ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL to "running",
            ExerciseSessionRecord.EXERCISE_TYPE_BIKING to "cycling", ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL to "swimming", ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER to "swimming",
            ExerciseSessionRecord.EXERCISE_TYPE_HIKING to "hiking", ExerciseSessionRecord.EXERCISE_TYPE_YOGA to "yoga", ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING to "strength",
            ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING to "strength", ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE to "rowing", ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL to "elliptical",
            ExerciseSessionRecord.EXERCISE_TYPE_PILATES to "pilates", ExerciseSessionRecord.EXERCISE_TYPE_DANCING to "dance", ExerciseSessionRecord.EXERCISE_TYPE_TENNIS to "other", -1 to "other")
        for ((type, name) in names) assertEquals(name, HealthWorkouts.activity(type))
        assertEquals(setOf("walking", "running", "cycling", "swimming", "hiking"), names.filterKeys { HealthWorkouts.supportsDistance(it) }.values.toSet())

        val id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        val invalid = listOf(
            listOf(workout(id, ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 0.5, 60)), // ends after the range
            listOf(workout(id, ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 200.0, 60)), // starts before the range
            listOf(workout(id, ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 5.0, 0)), // no duration
            listOf(workout(id, ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 5.0, 30, energy = -1.0)),
            listOf(workout(id, ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 5.0, 30, distance = Double.NaN)),
            listOf(workout(id, ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 5.0, 30), workout(id.uppercase(), ExerciseSessionRecord.EXERCISE_TYPE_WALKING, 9.0, 30)), // duplicate
        )
        for (records in invalid) { platform.records = records; assertRejectsWith(HealthError.INVALID_DATA.message) { module.workouts(context(declared), null) } }
    }

    // MARK: Policy

    @Test fun availabilityAndStatusNeverDiscloseGrants() {
        assertTrue(module.isAvailable(context(declared))); assertEquals("notDisclosed", module.authorizationStatus(context(declared)))
        // A legacy package without a manifest keeps the basic readings.
        assertEquals("notDisclosed", module.authorizationStatus(context(hasManifest = false)))
        assertEquals("undeclared", module.authorizationStatus(context(setOf("calendar"))))
        // Previews are not installations.
        assertFalse(module.isAvailable(context(declared, installation = "preview"))); assertEquals("unavailable", module.authorizationStatus(context(declared, installation = "preview")))
        // The answer is the same whether or not the review happened: it never says "authorized" or "denied".
        prompts.markAsked(HealthModule.PROMPT)
        assertEquals("notDisclosed", module.authorizationStatus(context(declared)))
        platform.available = false
        assertFalse(module.isAvailable(context(declared))); assertEquals("unavailable", module.authorizationStatus(context(declared)))
        assertEquals("undeclared", module.authorizationStatus(context(setOf("calendar"))))
    }

    @Test fun requestAuthorizationNeverPromptsAndReportsOnlyTheReview() {
        assertFalse(module.requestAuthorization(context(declared)))
        prompts.markAsked(HealthModule.PROMPT)
        assertTrue(module.requestAuthorization(context(declared)))
        assertTrue("no platform call is made", platform.calls.isEmpty())
        assertRejectsWith("[permission_denied] Install this widget and declare health in widget.json") { module.requestAuthorization(context(emptySet())) }
        assertRejectsWith("[timeline_read_only] Query Health in the current entry, then use a saved display snapshot") { module.requestAuthorization(context(declared, projection = true)) }
        assertRejectsWith("[query_limit] System data query limit exceeded") { module.requestAuthorization(context(declared, queries = 0)) }
        platform.available = false
        assertRejectsWith("Health data not available on this device") { module.requestAuthorization(context(declared)) }
    }

    @Test fun basicReadingPolicyOrderAndMessages() {
        val calls = listOf<(CallContext) -> Any>({ module.stepCountToday(it) }, { module.activeEnergyToday(it) }, { module.heartRateLatest(it) })
        for (call in calls) {
            platform.available = false
            // Each rule wins over every later one.
            assertRejectsWith("[execution_inactive] Health execution is no longer current") { call(context(emptySet(), projection = true, queries = 0, active = { false })) }
            assertRejectsWith("[permission_denied] Install this widget and declare health in widget.json") { call(context(emptySet(), projection = true, queries = 0)) }
            assertRejectsWith("[permission_denied] Install this widget and declare health in widget.json") { call(context(declared, installation = "preview")) }
            assertRejectsWith("[timeline_read_only] Query Health in the current entry, then use a saved display snapshot") { call(context(declared, projection = true, queries = 0)) }
            assertRejectsWith("[timeline_read_only] Query Health in the current entry, then use a saved display snapshot") { call(context(declared, liveActivity = true)) }
            assertRejectsWith("[query_limit] System data query limit exceeded") { call(context(declared, queries = 0)) }
            assertRejectsWith("[unavailable] Health data not available on this device") { call(context(declared)) }
            platform.available = true
            platform.fail = true
            assertRejectsWith("[query_failed] Health data could not be read. Review Health access in the app.") { call(context(declared)) }
            platform.fail = false
            call(context(hasManifest = false)) // legacy package
        }
        // Denied and future-entry calls leave the budget alone; each admitted call takes one query.
        val budget = context(declared, queries = 2)
        module.stepCountToday(budget); module.heartRateLatest(budget)
        assertRejectsWith("[query_limit] System data query limit exceeded") { module.activeEnergyToday(budget) }
        platform.calls.clear()
        assertRejectsWith("[timeline_read_only] Query Health in the current entry, then use a saved display snapshot") { module.stepCountToday(context(declared, projection = true)) }
        assertTrue("nothing is queried for a future entry", platform.calls.isEmpty())
    }

    @Test fun summaryPolicyOrderAndMessages() {
        val bad = options("unknown" to 1)
        val calls = listOf<(CallContext, JSONObject?, Boolean) -> Any>({ c, o, i -> module.sleepSummary(c, o, i) }, { c, o, i -> module.activitySummary(c, o, i) }, { c, o, i -> module.workouts(c, o, i) })
        for (call in calls) {
            platform.available = false
            assertRejectsWith("[permission_denied] Install this widget and declare health in widget.json") { call(context(emptySet(), projection = true, queries = 0), bad, false) }
            // The summaries need Package 2.0: a legacy package and a preview are refused.
            assertRejectsWith("[permission_denied] Install this widget and declare health in widget.json") { call(context(declared, hasManifest = false), null, false) }
            assertRejectsWith("[permission_denied] Install this widget and declare health in widget.json") { call(context(declared, installation = "preview"), null, false) }
            assertRejectsWith("[timeline_read_only] Read Health in the current app/widget entry") { call(context(declared, projection = true, queries = 0), bad, false) }
            assertRejectsWith("[timeline_read_only] Read Health in the current app/widget entry") { call(context(declared, liveActivity = true), null, false) }
            assertRejectsWith("[invalid_options] Health queries need a valid bounded range or local date") { call(context(declared, queries = 0), bad, false) }
            assertRejectsWith("[invalid_options] Health queries need a valid bounded range or local date") { call(context(declared, queries = 0), null, true) }
            assertRejectsWith("[query_limit] Too many system data queries") { call(context(declared, queries = 0), null, false) }
            assertRejectsWith("[unavailable] Health data is unavailable on this device") { call(context(declared), null, false) }
            platform.available = true
            platform.fail = true
            assertRejectsWith("[query_failed] Health data could not be read. Review Health access in the app.") { call(context(declared), null, false) }
            platform.fail = false
            // Invalid options do not spend the budget.
            val budget = context(declared, queries = 1)
            assertRejects("invalid_options") { call(budget, bad, false) }
            call(budget, null, false)
            assertRejects("query_limit") { call(budget, null, false) }
        }
    }

    @Test fun summaryRechecksAvailabilityBeforeDelivery() {
        val vanishing = object : HealthPlatform by platform {
            var asked = 0
            override fun isAvailable(): Boolean = ++asked <= 1
        }
        val module = HealthModule(vanishing, prompts, { now }, { zone })
        assertRejectsWith(HealthError.UNAVAILABLE_SUMMARY.message) { module.workouts(context(declared), null) }
    }

    @Test fun dailyStatisticsUsesTheSystemServiceGate() {
        val valid = options("metric" to "steps")
        val denied = SystemServiceError.PERMISSION_DENIED.message
        assertRejectsWith(denied) { module.dailyStatistics(context(emptySet(), projection = true, queries = 0), JSONObject()) }
        assertRejectsWith(denied) { module.dailyStatistics(context(declared, hasManifest = false), valid) }
        assertRejectsWith(denied) { module.dailyStatistics(context(declared, installation = "preview"), valid) }
        assertRejectsWith(denied) { module.dailyStatistics(context(declared, runtime = "1.5"), valid) }
        assertRejectsWith(denied) { module.dailyStatistics(context(declared, runtime = null), valid) }
        assertRejectsWith(SystemServiceError.READ_ONLY.message) { module.dailyStatistics(context(declared, projection = true, queries = 0), JSONObject()) }
        assertRejectsWith(SystemServiceError.READ_ONLY.message) { module.dailyStatistics(context(declared, liveActivity = true), valid) }
        assertRejectsWith(SystemServiceError.QUERY_LIMIT.message) { module.dailyStatistics(context(declared, queries = 0), JSONObject()) }
        platform.available = false
        assertRejectsWith(SystemServiceError.INVALID_OPTIONS.message) { module.dailyStatistics(context(declared), options("metric" to "sleep")) }
        assertRejectsWith(SystemServiceError.INVALID_OPTIONS.message) { module.dailyStatistics(context(declared), null) }
        assertRejectsWith(SystemServiceError.UNAVAILABLE.message) { module.dailyStatistics(context(declared), valid) }
        platform.available = true
        platform.fail = true
        assertRejectsWith(SystemServiceError.UNAVAILABLE.message) { module.dailyStatistics(context(declared), valid) }
        platform.fail = false
        // No per-widget grant is involved, and reads work outside user actions.
        assertEquals(7, module.dailyStatistics(context(declared, action = false), valid).getJSONArray("items").length())
        // A platform answer of the wrong size is never passed on.
        val short = object : HealthPlatform by platform { override fun aggregate(metric: HealthMetric, windows: List<HealthWindow>): List<Double?> = listOf(1.0) }
        assertRejectsWith(SystemServiceError.UNAVAILABLE.message) { HealthModule(short, prompts, { now }, { zone }).dailyStatistics(context(declared), valid) }
        val long = object : HealthPlatform by platform { override fun aggregate(metric: HealthMetric, windows: List<HealthWindow>): List<Double?> = List(windows.size + 1) { 1.0 } }
        assertRejectsWith(SystemServiceError.LIMIT_EXCEEDED.message) { HealthModule(long, prompts, { now }, { zone }).dailyStatistics(context(declared), valid) }
    }

    @Test fun logLinesCarryOutcomesOnly() {
        val lines = ArrayList<String>()
        val previous = SystemLog.sink
        SystemLog.sink = { synchronized(lines) { lines += it } }
        try {
            platform.values[HealthMetric.STEPS] = { 8421.0 }
            val results = ArrayList<String?>()
            // One call at a time, so the simulated failure only affects the last one.
            fun run(operation: String, block: () -> String) {
                val latch = CountDownLatch(1)
                runSystemCall(operation, { _, json -> synchronized(results) { results += json }; latch.countDown() }, block)
                assertTrue(latch.await(5, TimeUnit.SECONDS))
            }
            run("health.stepCountToday") { module.stepCountToday(context(declared)).toString() }
            run("health.sleepSummary") { module.sleepSummary(context(declared), options("limit" to 1)).toString() }
            platform.fail = true
            run("health.workouts") { module.workouts(context(declared), null).toString() }
            platform.fail = false
            assertEquals(listOf("health.stepCountToday -> ok", "health.sleepSummary -> invalid_options", "health.workouts -> query_failed"), synchronized(lines) { lines.toList() })
            // Neither the reading nor the provider's own error text reaches the log or the script-visible error.
            assertTrue(lines.none { it.contains("8421") }); assertEquals(1, results.count { it?.contains("8421") == true })
        } finally { SystemLog.sink = previous }
    }
}
