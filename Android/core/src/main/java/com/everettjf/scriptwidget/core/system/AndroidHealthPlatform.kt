package com.everettjf.scriptwidget.core.system

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.aggregate.AggregateMetric
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ActiveCaloriesBurnedRecord
import androidx.health.connect.client.records.DistanceRecord
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HydrationRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.records.WeightRecord
import androidx.health.connect.client.records.metadata.DataOrigin
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import java.time.Instant

/**
 * [HealthPlatform] on Health Connect. Read-only: the app declares no write
 * permission and this class calls no insert, update or delete.
 *
 * A record type the user did not share, and a read Health Connect refuses
 * (for example a background read without the background permission), is
 * reported as "no data", exactly like an empty store. Results are returned
 * to the caller and never kept.
 */
class AndroidHealthPlatform(context: Context) : HealthPlatform {
    private val appContext = context.applicationContext
    private val client: HealthConnectClient by lazy { HealthConnectClient.getOrCreate(appContext) }

    /** `HealthConnectClient.SDK_*`: available, unavailable, or the provider needs an update. */
    fun sdkStatus(): Int = runCatching { HealthConnectClient.getSdkStatus(appContext) }.getOrDefault(HealthConnectClient.SDK_UNAVAILABLE)

    override fun isAvailable(): Boolean = sdkStatus() == HealthConnectClient.SDK_AVAILABLE

    /**
     * The permissions the app's Health review asks for: the eight read types and, where the
     * device supports it, reading in the background (widgets refresh while the app is closed).
     */
    fun requestPermissions(): Set<String> = if (backgroundReadSupported()) READ_PERMISSIONS + HealthPermission.PERMISSION_READ_HEALTH_DATA_IN_BACKGROUND else READ_PERMISSIONS

    /** True when this device can grant background reads. */
    fun backgroundReadSupported(): Boolean = runCatching {
        client.features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_IN_BACKGROUND) == HealthConnectFeatures.FEATURE_STATUS_AVAILABLE
    }.getOrDefault(false)

    /**
     * What the user currently shares, for the app's own System Access screen. Blocking; call off the
     * main thread. This is never exposed to scripts.
     */
    fun grantedPermissions(): Set<String> = runCatching { blocking { client.permissionController.getGrantedPermissions() } }.getOrDefault(emptySet())

    private fun <T> blocking(block: suspend () -> T): T = runBlocking { withTimeout(TIMEOUT_MILLISECONDS) { block() } }

    private fun range(start: Long, end: Long): TimeRangeFilter = TimeRangeFilter.between(Instant.ofEpochMilli(start), Instant.ofEpochMilli(end))

    /** One aggregate over one window; null for an empty window, no data, or a refused read. */
    private suspend fun <T : Any> total(metric: AggregateMetric<T>, start: Long, end: Long, origins: Set<DataOrigin> = emptySet(), convert: (T) -> Double): Double? {
        if (end <= start) return null
        return try { client.aggregate(AggregateRequest(setOf(metric), range(start, end), origins))[metric]?.let(convert) } catch (error: SecurityException) { null }
    }

    private suspend fun value(metric: HealthMetric, window: HealthWindow): Double? = when (metric) {
        HealthMetric.STEPS -> total(StepsRecord.COUNT_TOTAL, window.start, window.end) { it.toDouble() }
        HealthMetric.ACTIVE_ENERGY -> total(ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL, window.start, window.end) { it.inKilocalories }
        HealthMetric.WALKING_DISTANCE -> total(DistanceRecord.DISTANCE_TOTAL, window.start, window.end) { it.inMeters }
        HealthMetric.WATER -> total(HydrationRecord.VOLUME_TOTAL, window.start, window.end) { it.inMilliliters }
        HealthMetric.BODY_MASS -> total(WeightRecord.WEIGHT_AVG, window.start, window.end) { it.inKilograms }
        HealthMetric.HEART_RATE -> total(HeartRateRecord.BPM_AVG, window.start, window.end) { it.toDouble() }
        HealthMetric.EXERCISE_MINUTES -> total(ExerciseSessionRecord.EXERCISE_DURATION_TOTAL, window.start, window.end) { it.toMillis() / 60_000.0 }
    }

    override fun aggregate(metric: HealthMetric, windows: List<HealthWindow>): List<Double?> = blocking {
        if (permission(metric) !in client.permissionController.getGrantedPermissions()) windows.map { null }
        else windows.map { value(metric, it) }
    }

    override fun latestHeartRate(before: Long): HealthHeartRate? = blocking {
        if (HEART_RATE !in client.permissionController.getGrantedPermissions()) return@blocking null
        try {
            val request = ReadRecordsRequest(HeartRateRecord::class, TimeRangeFilter.before(Instant.ofEpochMilli(before + 1)), ascendingOrder = false, pageSize = 1)
            client.readRecords(request).records.firstOrNull()?.samples?.maxByOrNull { it.time }?.let { HealthHeartRate(it.beatsPerMinute.toDouble(), it.time.toEpochMilli()) }
        } catch (error: SecurityException) { null }
    }

    override fun sleepSessions(start: Long, end: Long): HealthSleepPage = blocking {
        if (SLEEP !in client.permissionController.getGrantedPermissions()) return@blocking HealthSleepPage(emptyList(), false)
        try {
            // The time filter matches a session by its start, so look one day further back for sessions already running at `start`.
            val request = ReadRecordsRequest(SleepSessionRecord::class, range(start - HealthReadQuery.DAY, end), ascendingOrder = false, pageSize = MAXIMUM_SLEEP_SESSIONS)
            val response = client.readRecords(request)
            val sessions = response.records.filter { it.endTime.toEpochMilli() > start && it.startTime.toEpochMilli() < end }.map { record ->
                HealthSleepSession(record.startTime.toEpochMilli(), record.endTime.toEpochMilli(), record.metadata.dataOrigin.packageName,
                    record.stages.map { HealthSleepStage(it.startTime.toEpochMilli(), it.endTime.toEpochMilli(), it.stage) })
            }
            HealthSleepPage(sessions, !response.pageToken.isNullOrEmpty())
        } catch (error: SecurityException) { HealthSleepPage(emptyList(), false) }
    }

    override fun workouts(start: Long, end: Long, limit: Int): List<HealthWorkoutRecord> = blocking {
        val granted = client.permissionController.getGrantedPermissions()
        if (EXERCISE !in granted) return@blocking emptyList()
        try {
            val request = ReadRecordsRequest(ExerciseSessionRecord::class, range(start, end), ascendingOrder = false, pageSize = MAXIMUM_WORKOUT_SCAN)
            client.readRecords(request).records
                .filter { it.startTime.toEpochMilli() >= start && it.endTime.toEpochMilli() <= end && it.endTime > it.startTime }
                .take(limit).map { record ->
                    val from = record.startTime.toEpochMilli()
                    val to = record.endTime.toEpochMilli()
                    // Amounts come from the app that recorded the session, so another app's data for the same time is not added.
                    val origin = setOf(record.metadata.dataOrigin)
                    val energy = if (ACTIVE_ENERGY in granted) total(ActiveCaloriesBurnedRecord.ACTIVE_CALORIES_TOTAL, from, to, origin) { it.inKilocalories } else null
                    val distance = if (DISTANCE in granted && HealthWorkouts.supportsDistance(record.exerciseType)) total(DistanceRecord.DISTANCE_TOTAL, from, to, origin) { it.inMeters } else null
                    HealthWorkoutRecord(record.metadata.id, record.exerciseType, from, to, energy, distance)
                }
        } catch (error: SecurityException) { emptyList() }
    }

    companion object {
        private const val TIMEOUT_MILLISECONDS = 4_000L
        private const val MAXIMUM_SLEEP_SESSIONS = 64
        private const val MAXIMUM_WORKOUT_SCAN = 100

        private val STEPS = HealthPermission.getReadPermission(StepsRecord::class)
        private val ACTIVE_ENERGY = HealthPermission.getReadPermission(ActiveCaloriesBurnedRecord::class)
        private val HEART_RATE = HealthPermission.getReadPermission(HeartRateRecord::class)
        private val SLEEP = HealthPermission.getReadPermission(SleepSessionRecord::class)
        private val EXERCISE = HealthPermission.getReadPermission(ExerciseSessionRecord::class)
        private val DISTANCE = HealthPermission.getReadPermission(DistanceRecord::class)
        private val HYDRATION = HealthPermission.getReadPermission(HydrationRecord::class)
        private val WEIGHT = HealthPermission.getReadPermission(WeightRecord::class)

        /** The read permissions of the eight record types `$health` uses. Keep in sync with the app manifest. */
        val READ_PERMISSIONS: Set<String> = linkedSetOf(STEPS, ACTIVE_ENERGY, HEART_RATE, SLEEP, EXERCISE, DISTANCE, HYDRATION, WEIGHT)

        /** The permission that lets widgets read while the app is not open. */
        const val BACKGROUND_PERMISSION: String = HealthPermission.PERMISSION_READ_HEALTH_DATA_IN_BACKGROUND

        private fun permission(metric: HealthMetric): String = when (metric) {
            HealthMetric.STEPS -> STEPS
            HealthMetric.ACTIVE_ENERGY -> ACTIVE_ENERGY
            HealthMetric.WALKING_DISTANCE -> DISTANCE
            HealthMetric.WATER -> HYDRATION
            HealthMetric.BODY_MASS -> WEIGHT
            HealthMetric.HEART_RATE -> HEART_RATE
            HealthMetric.EXERCISE_MINUTES -> EXERCISE
        }
    }
}
