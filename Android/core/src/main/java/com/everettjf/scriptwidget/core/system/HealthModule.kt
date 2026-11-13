package com.everettjf.scriptwidget.core.system

import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.SleepSessionRecord
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.OffsetDateTime
import java.time.ZoneId
import java.util.UUID

/** Script-visible `$health` rejections, with the Apple runtime's wording. No message ever contains a reading. */
enum class HealthError(val message: String) {
    INACTIVE("[execution_inactive] Health execution is no longer current"),
    INSTALL("[permission_denied] Install this widget and declare health in widget.json"),
    TIMELINE_READING("[timeline_read_only] Query Health in the current entry, then use a saved display snapshot"),
    TIMELINE_SUMMARY("[timeline_read_only] Read Health in the current app/widget entry"),
    LIMIT_READING("[query_limit] System data query limit exceeded"),
    LIMIT_SUMMARY("[query_limit] Too many system data queries"),
    /** `requestAuthorization()` reports a missing health store without a bracketed code, as on Apple platforms. */
    UNAVAILABLE_REQUEST("Health data not available on this device"),
    UNAVAILABLE_READING("[unavailable] Health data not available on this device"),
    UNAVAILABLE_SUMMARY("[unavailable] Health data is unavailable on this device"),
    INVALID_OPTIONS("[invalid_options] Health queries need a valid bounded range or local date"),
    INVALID_DATA("[invalid_data] Health returned an invalid summary"),
    QUERY_FAILED("[query_failed] Health data could not be read. Review Health access in the app.");

    fun reject(): SystemReject = SystemReject(message)
}

/**
 * A quantity the platform can aggregate over a time window. [id] is the
 * `dailyStatistics` metric name (null for quantities only summaries use),
 * [unit] the unit string scripts see and [average] whether daily values are
 * averages instead of sums.
 */
enum class HealthMetric(val id: String?, val unit: String, val average: Boolean) {
    STEPS("steps", "count", false),
    ACTIVE_ENERGY("activeEnergy", "kcal", false),
    WALKING_DISTANCE("walkingDistance", "m", false),
    WATER("water", "mL", false),
    BODY_MASS("bodyMass", "kg", true),
    HEART_RATE("heartRate", "count/min", true),
    /** Minutes of recorded exercise sessions; used by `activitySummary` only. */
    EXERCISE_MINUTES(null, "min", false);

    companion object {
        /** The metric named [id] in `dailyStatistics`, or null. */
        fun named(id: String): HealthMetric? = entries.firstOrNull { it.id == id }
    }
}

/** A half-open time window in epoch milliseconds. */
class HealthWindow(val start: Long, val end: Long)

/** One heart-rate measurement. */
class HealthHeartRate(val beatsPerMinute: Double, val time: Long)

/** One stage of a sleep session; [type] is a Health Connect `SleepSessionRecord.STAGE_TYPE_*` value. */
class HealthSleepStage(val start: Long, val end: Long, val type: Int)

/** One sleep session. [source] identifies the writing app and is only ever counted, never returned to scripts. */
class HealthSleepSession(val start: Long, val end: Long, val source: String, val stages: List<HealthSleepStage>)

/** Sleep sessions overlapping a window, newest first, and whether more exist than were read. */
class HealthSleepPage(val sessions: List<HealthSleepSession>, val truncated: Boolean)

/** One exercise session; [exerciseType] is a Health Connect `ExerciseSessionRecord.EXERCISE_TYPE_*` value. */
class HealthWorkoutRecord(val id: String, val exerciseType: Int, val start: Long, val end: Long, val energyKcal: Double?, val distanceMeters: Double?)

/**
 * Health Connect behind an interface, so policy, bounds and aggregation run
 * on the JVM. Every method blocks and is called off the JavaScript thread.
 *
 * Privacy contract for implementations: a data type the user did not share
 * reads exactly like a type with no data (null or an empty list). Nothing
 * here reveals which types were granted, and nothing is cached or stored.
 */
interface HealthPlatform {
    /** True when the device has a usable health store. Cheap enough for the JavaScript thread. */
    fun isAvailable(): Boolean

    /** The sum (or average, see [HealthMetric.average]) of [metric] in each window, null where there is no readable sample. */
    fun aggregate(metric: HealthMetric, windows: List<HealthWindow>): List<Double?>

    /** The most recent heart-rate measurement at or before [before], or null. */
    fun latestHeartRate(before: Long): HealthHeartRate?

    /** Sleep sessions overlapping `[start, end)`, newest first. */
    fun sleepSessions(start: Long, end: Long): HealthSleepPage

    /** Up to [limit] exercise sessions wholly inside `[start, end]`, newest first. */
    fun workouts(start: Long, end: Long, limit: Int): List<HealthWorkoutRecord>
}

/** Local Gregorian day math for `$health`. Days follow the device time zone, including 23- and 25-hour DST days. */
object HealthDays {
    private val day = Regex("^\\d{4}-\\d{2}-\\d{2}$")

    /** Epoch milliseconds of the start of the local day containing [milliseconds]. */
    fun startOfDay(milliseconds: Long, zone: ZoneId): Long = start(Instant.ofEpochMilli(milliseconds).atZone(zone).toLocalDate(), zone)

    /** Epoch milliseconds at which [date] begins in [zone]. */
    fun start(date: LocalDate, zone: ZoneId): Long = date.atStartOfDay(zone).toInstant().toEpochMilli()

    /** `YYYY-MM-DD`. */
    fun format(date: LocalDate): String = "%04d-%02d-%02d".format(date.year, date.monthValue, date.dayOfMonth)

    /** A real Gregorian date written exactly as `YYYY-MM-DD` with a year of at least 1, or null. */
    fun parse(text: String): LocalDate? {
        if (!day.matches(text)) return null
        val (year, month, dayOfMonth) = text.split("-").map { it.toInt() }
        if (year < 1) return null
        return runCatching { LocalDate.of(year, month, dayOfMonth) }.getOrNull()
    }

    /**
     * The last [days] local days ending with the day of [now], oldest first. Each
     * window runs from local midnight to the next local midnight; the current day ends at [now].
     */
    fun windows(days: Int, now: Long, zone: ZoneId): List<Pair<LocalDate, HealthWindow>> {
        val today = Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
        return (days - 1 downTo 0).map { back ->
            val date = today.minusDays(back.toLong())
            date to HealthWindow(start(date, zone), minOf(start(date.plusDays(1), zone), now))
        }
    }
}

/** Strict `dailyStatistics(options)` input: `metric` is required, `days` is an integer 1–31 (default 7). */
class HealthHistoryOptions(val metric: HealthMetric, val days: Int) {
    companion object {
        const val MAXIMUM_DAYS = 31

        /** @throws SystemReject `invalid_options` for unknown fields, an unknown metric or days outside 1–31. */
        fun parse(options: JSONObject): HealthHistoryOptions {
            SystemOptions.fields(options, setOf("metric", "days"))
            val name = SystemOptions.text(SystemOptions.member(options, "metric"), 32)
            val days = if (options.has("days")) SystemOptions.integer(options.get("days"), 1..MAXIMUM_DAYS) else 7
            val metric = HealthMetric.named(name) ?: throw SystemServiceError.INVALID_OPTIONS.reject()
            return HealthHistoryOptions(metric, days)
        }
    }
}

/**
 * Validated bounds of `sleepSummary`, `activitySummary` and `workouts`.
 * [start] and [end] are epoch milliseconds; for an activity day they are the
 * local midnights around it.
 */
class HealthReadQuery(val kind: Kind, val start: Long, val end: Long, val limit: Int, val zone: ZoneId) {
    enum class Kind { SLEEP, ACTIVITY, WORKOUTS }

    /** Local date of [start], `YYYY-MM-DD`. */
    val day: String get() = HealthDays.format(Instant.ofEpochMilli(start).atZone(zone).toLocalDate())

    /** `start`, `end` and `timeZone` as scripts see them. */
    fun bounds(): JSONObject = JSONObject().put("start", IsoDates.formatFractional(start)).put("end", IsoDates.formatFractional(end)).put("timeZone", zone.id)

    companion object {
        const val DAY = 86_400_000L
        const val MAXIMUM_SLEEP_SEGMENTS = 256
        const val MAXIMUM_WORKOUTS = 50
        private val instant = Regex("^\\d{4}-\\d{2}-\\d{2}T([01]\\d|2[0-3]):[0-5]\\d:[0-5]\\d(?:\\.\\d{1,9})?(?:Z|[+-](?:[01]\\d|2[0-3]):[0-5]\\d)$")

        private fun invalid(): SystemReject = HealthError.INVALID_OPTIONS.reject()

        /** Epoch milliseconds of a full ISO-8601 date-time with a zone and a real calendar date, or null. */
        fun parseInstant(raw: Any?): Long? {
            val text = raw as? String ?: return null
            if (text.toByteArray().size > 64 || !instant.matches(text) || HealthDays.parse(text.take(10)) == null) return null
            return runCatching { OffsetDateTime.parse(text).toInstant().toEpochMilli() }.getOrNull()
        }

        /**
         * - sleep: `{start?, end?}`, default the last 24 elapsed hours, at most 7 × 24 hours;
         * - workouts: `{start?, end?, limit?}`, default the last 7 × 24 hours, at most 31 × 24 hours, integer limit 1–50 (default 5);
         * - activity: `{date?}`, a local `YYYY-MM-DD` that is not in the future, default today.
         *
         * `end` may not be later than one second after [now]. Unknown fields, values of the wrong type,
         * malformed dates and empty or oversized ranges throw `invalid_options`.
         */
        fun parse(kind: Kind, options: JSONObject?, now: Long, zone: ZoneId): HealthReadQuery {
            val values = options ?: JSONObject()
            val allowed = when (kind) { Kind.ACTIVITY -> setOf("date"); Kind.WORKOUTS -> setOf("start", "end", "limit"); Kind.SLEEP -> setOf("start", "end") }
            if (values.keys().asSequence().any { it !in allowed }) throw invalid()
            if (kind == Kind.ACTIVITY) {
                val date = if (values.has("date")) HealthDays.parse(values.get("date") as? String ?: throw invalid()) ?: throw invalid()
                else Instant.ofEpochMilli(now).atZone(zone).toLocalDate()
                val start = HealthDays.start(date, zone)
                if (start > now) throw invalid()
                return HealthReadQuery(kind, start, HealthDays.start(date.plusDays(1), zone), 1, zone)
            }
            val end = if (values.has("end")) parseInstant(values.get("end")) ?: throw invalid() else now
            val start = if (values.has("start")) parseInstant(values.get("start")) ?: throw invalid() else end - (if (kind == Kind.SLEEP) 1 else 7) * DAY
            val maximum = (if (kind == Kind.SLEEP) 7 else 31) * DAY
            if (end <= start || end > now + 1000 || end - start > maximum) throw invalid()
            val limit = if (!values.has("limit")) (if (kind == Kind.WORKOUTS) 5 else MAXIMUM_SLEEP_SEGMENTS) else {
                val number = (values.get("limit") as? Number)?.toDouble() ?: throw invalid()
                if (!number.isFinite() || Math.rint(number) != number || number < 1 || number > MAXIMUM_WORKOUTS) throw invalid()
                number.toInt()
            }
            return HealthReadQuery(kind, start, end, limit, zone)
        }
    }
}

/**
 * `sleepSummary` aggregation. Identical to the Apple runtime: intervals are
 * clipped to the query, in-bed time is an independent union, and at every
 * instant exactly one detailed stage counts, chosen by
 * **awake > REM > deep > core > unspecified**. Time where more than one
 * detailed stage competes is reported as `conflictSeconds`.
 */
object HealthSleep {
    enum class Stage { IN_BED, UNSPECIFIED, CORE, DEEP, REM, AWAKE }

    /** One interval of one stage from one source. */
    class Segment(val start: Long, val end: Long, val stage: Stage, val source: String)

    const val AGGREGATION = "union-awake-rem-deep-core-unspecified"
    private val priority = listOf(Stage.AWAKE, Stage.REM, Stage.DEEP, Stage.CORE, Stage.UNSPECIFIED)
    private val asleep = listOf(Stage.UNSPECIFIED, Stage.CORE, Stage.DEEP, Stage.REM)

    /**
     * The summary stage of a Health Connect stage type, or null for a type that carries no information.
     * Light sleep is `core`, plain "sleeping" is `unspecified`, and the awake, awake-in-bed and out-of-bed types are `awake`.
     */
    fun stage(type: Int): Stage? = when (type) {
        SleepSessionRecord.STAGE_TYPE_AWAKE, SleepSessionRecord.STAGE_TYPE_AWAKE_IN_BED, SleepSessionRecord.STAGE_TYPE_OUT_OF_BED -> Stage.AWAKE
        SleepSessionRecord.STAGE_TYPE_SLEEPING -> Stage.UNSPECIFIED
        SleepSessionRecord.STAGE_TYPE_LIGHT -> Stage.CORE
        SleepSessionRecord.STAGE_TYPE_DEEP -> Stage.DEEP
        SleepSessionRecord.STAGE_TYPE_REM -> Stage.REM
        else -> null
    }

    /**
     * Health Connect sessions as segments. A session is the time in bed; its stages are the detailed
     * segments. A session without any stage is one `unspecified` sleep segment, because the writing app
     * only said "asleep from start to end".
     */
    fun segments(sessions: List<HealthSleepSession>): List<Segment> = sessions.flatMap { session ->
        val detailed = session.stages.mapNotNull { stage -> stage(stage.type)?.let { Segment(stage.start, stage.end, it, session.source) } }
        listOf(Segment(session.start, session.end, Stage.IN_BED, session.source)) +
            (if (session.stages.isEmpty()) listOf(Segment(session.start, session.end, Stage.UNSPECIFIED, session.source)) else detailed)
    }

    /** The [HealthReadQuery.MAXIMUM_SLEEP_SEGMENTS] segments that end last, and whether any were left out. */
    fun recent(segments: List<Segment>, truncated: Boolean): Pair<List<Segment>, Boolean> {
        val ordered = segments.sortedWith(compareByDescending<Segment> { it.end }.thenByDescending { it.start })
        return ordered.take(HealthReadQuery.MAXIMUM_SLEEP_SEGMENTS) to (truncated || ordered.size > HealthReadQuery.MAXIMUM_SLEEP_SEGMENTS)
    }

    /** @throws SystemReject `invalid_data` for more than 256 segments or a segment that does not end after it starts. */
    fun summary(query: HealthReadQuery, segments: List<Segment>, truncated: Boolean): JSONObject {
        if (segments.size > HealthReadQuery.MAXIMUM_SLEEP_SEGMENTS || segments.any { it.end <= it.start || it.source.toByteArray().size > 256 }) throw HealthError.INVALID_DATA.reject()
        val included = segments.filter { it.start < query.end && it.end > query.start }
        val edges = included.flatMap { listOf(maxOf(query.start, it.start), minOf(query.end, it.end)) }.toSortedSet().toList()
        val seconds = Stage.entries.associateWith { 0.0 }.toMutableMap()
        var conflict = 0.0
        for (index in 0 until edges.size - 1) {
            val from = edges[index]
            val to = edges[index + 1]
            val stages = included.filter { it.start < to && it.end > from }.map { it.stage }.toSet()
            val span = (to - from) / 1000.0
            if (Stage.IN_BED in stages) seconds[Stage.IN_BED] = seconds.getValue(Stage.IN_BED) + span
            val active = priority.filter { it in stages }
            active.firstOrNull()?.let { seconds[it] = seconds.getValue(it) + span }
            if (active.size > 1) conflict += span
        }
        return query.bounds()
            .put("hasSamples", included.isNotEmpty()).put("truncated", truncated).put("sourceCount", included.map { it.source }.toSet().size)
            .put("inBedSeconds", seconds.getValue(Stage.IN_BED)).put("awakeSeconds", seconds.getValue(Stage.AWAKE))
            .put("stages", JSONObject().put("unspecified", seconds.getValue(Stage.UNSPECIFIED)).put("core", seconds.getValue(Stage.CORE))
                .put("deep", seconds.getValue(Stage.DEEP)).put("rem", seconds.getValue(Stage.REM)))
            .put("totalSleepSeconds", asleep.sumOf { seconds.getValue(it) })
            .put("conflictSeconds", conflict).put("aggregation", AGGREGATION)
    }
}

/**
 * `activitySummary` on Android. Health Connect has no activity rings: move is
 * the day's active energy, exercise is the minutes of recorded exercise
 * sessions, and there is no stand measurement and no goal of any kind. Those
 * fields are `null`; nothing is inferred.
 */
object HealthActivity {
    private fun ring(value: Any?, unit: String): JSONObject = JSONObject().put("value", value ?: JSONObject.NULL).put("goal", JSONObject.NULL).put("unit", unit)

    /**
     * [activeEnergyKcal] and [exerciseMinutes] are null when the day has no readable sample of that kind.
     * With neither, the result is the documented empty summary (zero values, null goals, `hasSamples: false`).
     * @throws SystemReject `invalid_data` for a value that is not finite or outside 0…1e9.
     */
    fun summary(query: HealthReadQuery, activeEnergyKcal: Double?, exerciseMinutes: Double?): JSONObject {
        if (listOfNotNull(activeEnergyKcal, exerciseMinutes).any { !HealthValues.valid(it) }) throw HealthError.INVALID_DATA.reject()
        val hasSamples = activeEnergyKcal != null || exerciseMinutes != null
        return JSONObject().put("date", query.day).put("timeZone", query.zone.id).put("hasSamples", hasSamples).put("moveMode", "activeEnergy")
            .put("move", ring(if (hasSamples) activeEnergyKcal else 0, "kcal"))
            .put("exercise", ring(if (hasSamples) exerciseMinutes else 0, "min"))
            .put("stand", ring(if (hasSamples) null else 0, "count"))
    }
}

/** `workouts` summarising: activity names, distance support, identifiers and the result object. */
object HealthWorkouts {
    private val uuid = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private val distanceActivities = setOf("walking", "running", "hiking", "cycling", "swimming")

    /** One of the twelve activity names of the contract; anything else is `other`. */
    fun activity(exerciseType: Int): String = when (exerciseType) {
        ExerciseSessionRecord.EXERCISE_TYPE_WALKING -> "walking"
        ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, ExerciseSessionRecord.EXERCISE_TYPE_RUNNING_TREADMILL -> "running"
        ExerciseSessionRecord.EXERCISE_TYPE_BIKING, ExerciseSessionRecord.EXERCISE_TYPE_BIKING_STATIONARY -> "cycling"
        ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_OPEN_WATER, ExerciseSessionRecord.EXERCISE_TYPE_SWIMMING_POOL -> "swimming"
        ExerciseSessionRecord.EXERCISE_TYPE_HIKING -> "hiking"
        ExerciseSessionRecord.EXERCISE_TYPE_YOGA -> "yoga"
        ExerciseSessionRecord.EXERCISE_TYPE_STRENGTH_TRAINING, ExerciseSessionRecord.EXERCISE_TYPE_WEIGHTLIFTING -> "strength"
        ExerciseSessionRecord.EXERCISE_TYPE_ROWING, ExerciseSessionRecord.EXERCISE_TYPE_ROWING_MACHINE -> "rowing"
        ExerciseSessionRecord.EXERCISE_TYPE_ELLIPTICAL -> "elliptical"
        ExerciseSessionRecord.EXERCISE_TYPE_PILATES -> "pilates"
        ExerciseSessionRecord.EXERCISE_TYPE_DANCING -> "dance"
        else -> "other"
    }

    /** Distance is reported for walking, running, hiking, cycling and swimming only. */
    fun supportsDistance(exerciseType: Int): Boolean = activity(exerciseType) in distanceActivities

    /** A canonical lowercase UUID: the record identifier when it already is one, otherwise a stable UUID derived from it. */
    fun identifier(raw: String): String {
        val lower = raw.lowercase()
        return if (uuid.matches(lower)) lower else UUID.nameUUIDFromBytes(raw.toByteArray()).toString()
    }

    /**
     * `{start, end, timeZone, hasSamples, truncated, items}` with the newest [HealthReadQuery.limit] workouts.
     * Duration is the elapsed time of the session in seconds.
     * @throws SystemReject `invalid_data` for a workout outside the query, without a positive duration,
     * with an invalid amount, or for duplicate identifiers.
     */
    fun result(query: HealthReadQuery, records: List<HealthWorkoutRecord>): JSONObject {
        val ordered = records.map { it to identifier(it.id) }.sortedWith(compareByDescending<Pair<HealthWorkoutRecord, String>> { it.first.start }.thenBy { it.second })
        val items = ordered.take(query.limit)
        val valid = items.all { (record, _) ->
            record.start >= query.start && record.end <= query.end && record.end > record.start &&
                listOfNotNull(record.energyKcal, record.distanceMeters).all { HealthValues.valid(it) }
        }
        if (!valid || items.map { it.second }.toSet().size != items.size) throw HealthError.INVALID_DATA.reject()
        val rows = items.map { (record, id) ->
            JSONObject().put("id", id).put("activity", activity(record.exerciseType))
                .put("start", IsoDates.formatFractional(record.start)).put("end", IsoDates.formatFractional(record.end))
                .put("duration", (record.end - record.start) / 1000.0)
                .put("energyKcal", record.energyKcal ?: JSONObject.NULL)
                .put("distanceMeters", (if (supportsDistance(record.exerciseType)) record.distanceMeters else null) ?: JSONObject.NULL)
        }
        return query.bounds().put("hasSamples", rows.isNotEmpty()).put("truncated", ordered.size > query.limit).put("items", JSONArray(rows))
    }
}

/** Bounds for values that cross the bridge, and the reading objects of the basic queries. */
object HealthValues {
    /** Finite and inside 0…1e9. */
    fun valid(value: Double): Boolean = value.isFinite() && value >= 0 && value <= 1e9

    /**
     * `{value, hasSamples, unit, start, end}` of `stepCountToday` and `activeEnergyToday`. With no readable
     * sample the legacy numeric zero stays and `hasSamples` is false; that never means access was denied.
     */
    fun today(value: Double?, unit: String, start: Long, end: Long): JSONObject = JSONObject()
        .put("value", value ?: 0).put("hasSamples", value != null).put("unit", unit)
        .put("start", IsoDates.formatFractional(start)).put("end", IsoDates.formatFractional(end))

    /** `heartRateLatest`: the sample in bpm with its time, or zero with empty dates and `hasSamples: false`. */
    fun heartRate(sample: HealthHeartRate?): JSONObject {
        val time = sample?.let { IsoDates.formatFractional(it.time) } ?: ""
        return JSONObject().put("value", sample?.beatsPerMinute ?: 0).put("hasSamples", sample != null).put("unit", "bpm").put("start", time).put("end", time)
    }

    /**
     * `{metric, unit, aggregation, timeZone, items:[{date, value, hasSamples}]}`. A day without a readable
     * sample is `value: null, hasSamples: false`; a measured zero stays a zero.
     */
    fun history(metric: HealthMetric, zone: ZoneId, days: List<LocalDate>, values: List<Double?>): JSONObject {
        val items = days.mapIndexed { index, date ->
            val value = values[index]
            JSONObject().put("date", HealthDays.format(date)).put("value", value?.takeIf { it.isFinite() && it >= 0 } ?: JSONObject.NULL).put("hasSamples", value != null)
        }
        return JSONObject().put("metric", metric.id).put("unit", metric.unit).put("aggregation", if (metric.average) "average" else "sum")
            .put("timeZone", zone.id).put("items", JSONArray(items))
    }
}

/**
 * `$health`: read-only health data through Health Connect.
 *
 * Privacy rules, the same as on Apple platforms:
 * - `authorizationStatus()` is `notDisclosed` whenever the store is usable; it never reveals which types were shared;
 * - a type the user did not share reads as "no samples", never as "denied";
 * - nothing is cached, stored, exported or logged (one outcome line per call, no values);
 * - nothing is read in future timeline entries or Live Activity presentations;
 * - a widget never prompts. Access is reviewed in the app.
 */
class HealthModule(
    private val platform: HealthPlatform,
    private val prompts: PermissionPrompts,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
    private val zone: () -> ZoneId = { ZoneId.systemDefault() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$health")

    override fun handles(operation: String): Boolean = operation.startsWith("health.")

    override fun call(request: ExecutionRequest, operation: String, payload: String?): String? {
        val context = CallContext.from(request)
        val value = when (operation) {
            "health.isAvailable" -> isAvailable(context).toString()
            "health.authorizationStatus" -> JSONObject.quote(authorizationStatus(context))
            else -> throw IllegalArgumentException("Unsupported operation $operation")
        }
        SystemLog.call(operation, "ok")
        return value
    }

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        val options = payload?.optJSONObject("options")
        val invalid = payload?.optBoolean("invalid", false) == true
        when (operation) {
            "health.requestAuthorization" -> runSystemCall(operation, done) { requestAuthorization(context).toString() }
            "health.stepCountToday" -> runSystemCall(operation, done) { stepCountToday(context).toString() }
            "health.activeEnergyToday" -> runSystemCall(operation, done) { activeEnergyToday(context).toString() }
            "health.heartRateLatest" -> runSystemCall(operation, done) { heartRateLatest(context).toString() }
            "health.sleepSummary" -> runSystemCall(operation, done) { sleepSummary(context, options, invalid).toString() }
            "health.activitySummary" -> runSystemCall(operation, done) { activitySummary(context, options, invalid).toString() }
            "health.workouts" -> runSystemCall(operation, done) { workouts(context, options, invalid).toString() }
            "health.dailyStatistics" -> runSystemCall(operation, done) { dailyStatistics(context, options).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    private fun available(): Boolean = runCatching { platform.isAvailable() }.getOrDefault(false)

    /** Package 2.0 must declare `health`; a genuine legacy package (no manifest) keeps the basic readings. Previews never qualify. */
    private fun permits(context: CallContext): Boolean = context.isInstalled && (!context.hasManifest || "health" in context.permissions)

    /** False for previews and on devices without a usable health store. */
    fun isAvailable(context: CallContext): Boolean = context.isInstalled && available()

    /**
     * `unavailable` for previews and unusable stores, `undeclared` when the package may not use Health,
     * otherwise `notDisclosed`. There is deliberately no per-type or "authorized" answer.
     */
    fun authorizationStatus(context: CallContext): String = when {
        !context.isInstalled -> "unavailable"
        !permits(context) -> "undeclared"
        available() -> "notDisclosed"
        else -> "unavailable"
    }

    /**
     * Gate of the basic calls, in the Apple runtime's order: current execution, package permission,
     * no future timeline entry or Live Activity, the query budget, then store availability.
     */
    private fun admit(context: CallContext, unavailable: HealthError) {
        if (!context.isActive) throw HealthError.INACTIVE.reject()
        if (!permits(context)) throw HealthError.INSTALL.reject()
        if (context.isTimelineProjection || context.isLiveActivity) throw HealthError.TIMELINE_READING.reject()
        if (!context.consumeDataQuery()) throw HealthError.LIMIT_READING.reject()
        if (!available()) throw unavailable.reject()
    }

    /** Platform failures never reach scripts with their own text. */
    private fun <T> query(failure: SystemReject, block: () -> T): T =
        try { block() } catch (error: SystemReject) { throw error } catch (error: Exception) { throw failure }

    /**
     * Never prompts. Resolves `true` when the user has already been through the Health access review in
     * the app and `false` when that review is still needed. Like the Apple request status, this says
     * nothing about which types were shared.
     */
    fun requestAuthorization(context: CallContext): Boolean {
        admit(context, HealthError.UNAVAILABLE_REQUEST)
        return prompts.asked(PROMPT)
    }

    /** Steps from local start of day to now, in `count`. */
    fun stepCountToday(context: CallContext): JSONObject = today(context, HealthMetric.STEPS, "count")

    /** Active energy from local start of day to now, in `kcal`. */
    fun activeEnergyToday(context: CallContext): JSONObject = today(context, HealthMetric.ACTIVE_ENERGY, "kcal")

    private fun today(context: CallContext, metric: HealthMetric, unit: String): JSONObject {
        admit(context, HealthError.UNAVAILABLE_READING)
        val now = clock.now()
        val start = HealthDays.startOfDay(now, zone())
        val value = query(HealthError.QUERY_FAILED.reject()) { platform.aggregate(metric, listOf(HealthWindow(start, now))).firstOrNull() }
        if (value != null && !HealthValues.valid(value)) throw HealthError.QUERY_FAILED.reject()
        return HealthValues.today(value, unit, start, clock.now())
    }

    /** The latest heart-rate sample in `bpm`. */
    fun heartRateLatest(context: CallContext): JSONObject {
        admit(context, HealthError.UNAVAILABLE_READING)
        val sample = query(HealthError.QUERY_FAILED.reject()) { platform.latestHeartRate(clock.now()) }
        if (sample != null && !HealthValues.valid(sample.beatsPerMinute)) throw HealthError.QUERY_FAILED.reject()
        return HealthValues.heartRate(sample)
    }

    /**
     * Gate of the Runtime 1.4 summaries, in the Apple runtime's order: an installed Package 2.0 widget
     * declaring `health`, no future timeline entry or Live Activity, valid options, the query budget,
     * store availability; availability is checked again before the result is delivered.
     */
    private fun summary(context: CallContext, kind: HealthReadQuery.Kind, options: JSONObject?, invalid: Boolean, read: (HealthReadQuery) -> JSONObject): JSONObject {
        if (!context.isInstalled || !context.declares("health")) throw HealthError.INSTALL.reject()
        if (context.isTimelineProjection || context.isLiveActivity) throw HealthError.TIMELINE_SUMMARY.reject()
        if (invalid) throw HealthError.INVALID_OPTIONS.reject()
        val parsed = HealthReadQuery.parse(kind, options, clock.now(), zone())
        if (!context.consumeDataQuery()) throw HealthError.LIMIT_SUMMARY.reject()
        if (!available()) throw HealthError.UNAVAILABLE_SUMMARY.reject()
        val result = query(HealthError.QUERY_FAILED.reject()) { read(parsed) }
        if (!available()) throw HealthError.UNAVAILABLE_SUMMARY.reject()
        return result
    }

    /** `sleepSummary({start?, end?})`; [invalid] marks options the JavaScript bridge could not convert. */
    fun sleepSummary(context: CallContext, options: JSONObject?, invalid: Boolean = false): JSONObject = summary(context, HealthReadQuery.Kind.SLEEP, options, invalid) { parsed ->
        val page = platform.sleepSessions(parsed.start, parsed.end)
        val (segments, truncated) = HealthSleep.recent(HealthSleep.segments(page.sessions), page.truncated)
        HealthSleep.summary(parsed, segments, truncated)
    }

    /** `activitySummary({date?})`; see [HealthActivity] for what Android can and cannot report. */
    fun activitySummary(context: CallContext, options: JSONObject?, invalid: Boolean = false): JSONObject = summary(context, HealthReadQuery.Kind.ACTIVITY, options, invalid) { parsed ->
        val window = listOf(HealthWindow(parsed.start, parsed.end))
        HealthActivity.summary(parsed, platform.aggregate(HealthMetric.ACTIVE_ENERGY, window).firstOrNull(), platform.aggregate(HealthMetric.EXERCISE_MINUTES, window).firstOrNull())
    }

    /** `workouts({start?, end?, limit?})`: newest first, only sessions wholly inside the range. */
    fun workouts(context: CallContext, options: JSONObject?, invalid: Boolean = false): JSONObject = summary(context, HealthReadQuery.Kind.WORKOUTS, options, invalid) { parsed ->
        // One more than the limit, so `truncated` is known without reading everything.
        HealthWorkouts.result(parsed, platform.workouts(parsed.start, parsed.end, parsed.limit + 1))
    }

    /**
     * `dailyStatistics({metric, days?})`, a Runtime 1.6 system service: the shared gate (`health` declared,
     * `minimumRuntimeVersion` 1.6, not a future entry or Live Activity, the query budget), then strict
     * options, then availability. Health needs no per-widget grant. The gate is checked again before delivery.
     */
    fun dailyStatistics(context: CallContext, options: JSONObject?): JSONObject {
        SystemGate.check(context, "health", writing = false, grants = null)
        val parsed = HealthHistoryOptions.parse(options ?: JSONObject())
        if (!available()) throw SystemServiceError.UNAVAILABLE.reject()
        val current = zone()
        val days = HealthDays.windows(parsed.days, clock.now(), current)
        val values = query(SystemServiceError.UNAVAILABLE.reject()) { platform.aggregate(parsed.metric, days.map { it.second }) }
        if (values.size > days.size) throw SystemServiceError.LIMIT_EXCEEDED.reject()
        if (values.size != days.size) throw SystemServiceError.UNAVAILABLE.reject()
        SystemGate.validate(context, "health", writing = false, grants = null)
        return HealthValues.history(parsed.metric, current, days.map { it.first }, values)
    }

    companion object {
        /** Key under which [PermissionPrompts] remembers that the Health access review was shown. */
        const val PROMPT = "health"
    }
}
