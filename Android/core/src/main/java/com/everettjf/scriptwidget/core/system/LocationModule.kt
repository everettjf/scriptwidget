package com.everettjf.scriptwidget.core.system

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationManager
import android.os.CancellationSignal
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** One position from the system. Fields the provider did not measure are null. */
class LocationFix(
    val latitude: Double, val longitude: Double, val altitude: Double?, val accuracy: Double?,
    val verticalAccuracy: Double?, val speed: Double?, val course: Double?, val timestampMilliseconds: Long,
)

/** What the user granted the app: nothing, approximate (coarse) or precise (fine) location. */
enum class LocationGrant { NONE, APPROXIMATE, PRECISE }

/** The Android location services the module needs, behind an interface so policy runs on the JVM. */
interface LocationPlatform {
    fun servicesEnabled(): Boolean
    fun grant(): LocationGrant
    /** True while the app is visible. Without background-location permission Android only serves positions then. */
    fun isForeground(): Boolean
    /** Delivers one current or last-known fix, or null, exactly once. Returns a function that cancels the request. */
    fun requestFix(timeoutMilliseconds: Long, callback: (LocationFix?) -> Unit): () -> Unit
}

/** Pure `$location` rules: package permission, status strings, option parsing. */
object LocationPolicy {
    const val MAXIMUM_AGE_SECONDS = 86_400.0

    /** Package 2.0 must declare `location`; a genuine legacy package (no manifest) keeps its access. */
    fun packageAllows(context: CallContext): Boolean = !context.hasManifest || "location" in context.permissions

    /**
     * `undeclared`, `disabled`, `authorizedWhenInUse`, `denied` or `notDetermined`.
     * Android never grants this app background location, so `authorizedAlways` is not produced;
     * `denied` and `notDetermined` are told apart by whether the app has asked.
     */
    fun status(declared: Boolean, servicesEnabled: Boolean, grant: LocationGrant, asked: Boolean): String = when {
        !declared -> "undeclared"
        !servicesEnabled -> "disabled"
        grant != LocationGrant.NONE -> "authorizedWhenInUse"
        asked -> "denied"
        else -> "notDetermined"
    }

    /** A position may be read when services are on and the user granted approximate or precise location. */
    fun canRead(servicesEnabled: Boolean, grant: LocationGrant): Boolean = servicesEnabled && grant != LocationGrant.NONE

    /** `full` for a precise grant, `reduced` for an approximate one. */
    fun accuracyAuthorization(grant: LocationGrant): String = if (grant == LocationGrant.PRECISE) "full" else "reduced"

    /** `timeoutMs` wins over `timeout` (seconds); invalid or nonpositive values use [default]; capped at 30 seconds. */
    fun timeoutSeconds(options: JSONObject?, default: Double = 10.0): Double = seconds(options, "timeoutMs", "timeout", default, 30.0)

    /** `maxAgeMs` wins over `maxAge` (seconds); invalid or nonpositive values use [default]; capped at one day. */
    fun maxAgeSeconds(options: JSONObject?, default: Double = 0.0): Double = seconds(options, "maxAgeMs", "maxAge", default, MAXIMUM_AGE_SECONDS)

    private fun seconds(options: JSONObject?, millisecondsKey: String, secondsKey: String, default: Double, maximum: Double): Double {
        fun positive(key: String): Double? = (options?.opt(key) as? Number)?.toDouble()?.takeIf { it.isFinite() && it > 0 }
        positive(millisecondsKey)?.let { return minOf(maximum, it / 1000) }
        positive(secondsKey)?.let { return minOf(maximum, it) }
        return default
    }
}

/**
 * The stored position snapshot. Anything that is not exactly the expected
 * shape is discarded: more than 4 KiB, unknown or missing keys, non-finite
 * numbers, coordinates out of range, a timestamp in the future or older than
 * 24 hours. A reduced-accuracy session cannot read a full-accuracy snapshot.
 */
object LocationSnapshot {
    const val MAXIMUM_BYTES = 4 * 1024
    private val numberKeys = listOf("latitude", "longitude", "altitude", "accuracy", "verticalAccuracy", "speed", "course", "timestampSeconds")
    /** Optional readings: stored as JSON null when the provider had no measurement. */
    private val nullableKeys = setOf("altitude", "verticalAccuracy", "speed", "course")

    /** Null when the fix has no usable horizontal accuracy or coordinates; such a fix is not a position. */
    fun encode(fix: LocationFix, accuracyAuthorization: String): String? {
        val accuracy = fix.accuracy ?: return null
        if (!fix.latitude.isFinite() || !fix.longitude.isFinite() || fix.latitude !in -90.0..90.0 || fix.longitude !in -180.0..180.0 || !accuracy.isFinite() || accuracy < 0) return null
        fun optional(value: Double?): Any = value?.takeIf { it.isFinite() } ?: JSONObject.NULL
        return JSONObject()
            .put("latitude", fix.latitude).put("longitude", fix.longitude).put("altitude", optional(fix.altitude)).put("accuracy", accuracy)
            .put("verticalAccuracy", optional(fix.verticalAccuracy)).put("speed", optional(fix.speed)).put("course", optional(fix.course))
            .put("timestampSeconds", fix.timestampMilliseconds / 1000.0).put("accuracyAuthorization", accuracyAuthorization).toString()
    }

    /**
     * The script result for a stored snapshot, or null when it must be discarded.
     * `isStale` is true when the snapshot is older than [maxAgeSeconds] (0 to one day).
     */
    fun decode(text: String, accuracyAuthorization: String, maxAgeSeconds: Double?, nowMilliseconds: Long): JSONObject? {
        if (text.toByteArray().size > MAXIMUM_BYTES) return null
        val raw = runCatching { JSONObject(text) }.getOrNull() ?: return null
        if (raw.keys().asSequence().toSet() != numberKeys.toSet() + "accuracyAuthorization") return null
        val precision = raw.opt("accuracyAuthorization") as? String ?: return null
        if (precision !in setOf("full", "reduced") || accuracyAuthorization !in setOf("full", "reduced")) return null
        if (accuracyAuthorization == "reduced" && precision != "reduced") return null
        val payload = JSONObject()
        for (key in numberKeys) {
            val value = raw.opt(key)
            if (value == JSONObject.NULL && key in nullableKeys) { payload.put(key, JSONObject.NULL); continue }
            val number = (value as? Number)?.toDouble()?.takeIf { it.isFinite() } ?: return null
            payload.put(key, number)
        }
        if (payload.getDouble("latitude") !in -90.0..90.0 || payload.getDouble("longitude") !in -180.0..180.0 || payload.getDouble("accuracy") < 0) return null
        val timestamp = payload.getDouble("timestampSeconds")
        val age = nowMilliseconds / 1000.0 - timestamp
        if (age < 0 || age > LocationPolicy.MAXIMUM_AGE_SECONDS) return null
        payload.remove("timestampSeconds")
        return payload.put("timestamp", IsoDates.formatFractional((timestamp * 1000).toLong())).put("accuracyAuthorization", precision)
            .put("age", age).put("isStale", age > (maxAgeSeconds ?: 0.0).coerceIn(0.0, LocationPolicy.MAXIMUM_AGE_SECONDS))
    }
}

/** The single app-private snapshot file. Reading it while access is not allowed, or finding it invalid, deletes it. */
class LocationSnapshotStore(private val file: PrivateFile, private val clock: SystemClock) {
    fun read(allowed: Boolean, accuracyAuthorization: String, maxAgeSeconds: Double?): JSONObject? = synchronized(file.lock) {
        val payload = if (!allowed) null else runCatching { file.read() }.getOrNull()?.let { LocationSnapshot.decode(it, accuracyAuthorization, maxAgeSeconds, clock.now()) }
        if (payload == null) file.delete()
        payload
    }

    fun write(encoded: String): Boolean = synchronized(file.lock) { file.write(encoded) }

    fun clear() = synchronized(file.lock) { file.delete() }

    fun exists(): Boolean = file.exists()
}

/**
 * `$location`. The app reads positions with [LocationManager] while it is
 * visible and keeps one snapshot; a widget, which runs in the background and
 * has no background-location permission, reads that snapshot with its age.
 * Nothing here can show a permission prompt: authorization is requested only
 * from the app's System Access screen.
 */
class LocationModule(
    private val platform: LocationPlatform,
    private val snapshots: LocationSnapshotStore,
    private val prompts: PermissionPrompts,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$location")

    override fun handles(operation: String): Boolean = operation.startsWith("location.")

    override fun call(request: ExecutionRequest, operation: String, payload: String?): String? {
        val context = CallContext.from(request)
        val value = when (operation) {
            "location.isAvailable" -> isAvailable(context).toString()
            "location.authorizationStatus" -> JSONObject.quote(authorizationStatus(context))
            "location.isAuthorizedForWidgetUpdates" -> isAuthorizedForWidgetUpdates(context).toString()
            else -> throw IllegalArgumentException("Unsupported operation $operation")
        }
        SystemLog.call(operation, "ok")
        return value
    }

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        val options = payload?.optJSONObject("options")
        when (operation) {
            "location.requestAuthorization" -> runSystemCall(operation, done) { requestAuthorization(context).toString() }
            // Off the JavaScript thread: the checks read the snapshot file and query system services.
            "location.current" -> SystemExecutor.pool.execute {
                current(context, options) { ok, value ->
                    SystemLog.call(operation, if (ok) "ok" else SystemLog.code(value))
                    done(ok, if (ok) value else JSONObject.quote(value))
                }
            }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** System location services are on, for an installed execution. Observing them off clears the snapshot. */
    fun isAvailable(context: CallContext): Boolean {
        if (!context.isInstalled) return false
        val enabled = platform.servicesEnabled()
        if (!enabled) snapshots.clear()
        return enabled
    }

    fun authorizationStatus(context: CallContext): String {
        if (!context.isInstalled) return "unavailable"
        recheck()
        return LocationPolicy.status(LocationPolicy.packageAllows(context), platform.servicesEnabled(), platform.grant(), prompts.asked(PROMPT))
    }

    /**
     * Android has no separate per-widget location consent: a widget may use the
     * snapshot whenever the package declares `location`, services are on and the app holds the grant.
     */
    fun isAuthorizedForWidgetUpdates(context: CallContext): Boolean =
        context.isInstalled && LocationPolicy.packageAllows(context) && LocationPolicy.canRead(platform.servicesEnabled(), platform.grant())

    /** Drops the snapshot when access was revoked, services were disabled, or precision was reduced. Also called by the app UI. */
    fun recheck() {
        val grant = platform.grant()
        snapshots.read(LocationPolicy.canRead(platform.servicesEnabled(), grant), LocationPolicy.accuracyAuthorization(grant), null)
    }

    /**
     * Checks shared by both promise methods, in the Apple runtime's order:
     * Live Activity, installed owner, package permission, then the query budget.
     */
    private fun admit(context: CallContext) {
        if (context.isLiveActivity) throw SystemReject("[live_activity_unavailable] Live Activity presentations cannot request location updates; update their state from the app")
        if (!context.isInstalled) throw SystemReject("[permission_denied] Install this widget to use location data")
        if (!LocationPolicy.packageAllows(context)) throw SystemReject("[permission_denied] Declare location in widget.json")
        if (!context.consumeDataQuery()) throw SystemReject("[query_limit] System data query limit exceeded")
        recheck()
    }

    /** Resolves to the current state. It never prompts: permission is requested in the app's System Access screen. */
    fun requestAuthorization(context: CallContext): Boolean {
        admit(context)
        val readable = LocationPolicy.canRead(platform.servicesEnabled(), platform.grant())
        if (context.isTimelineProjection || !platform.isForeground()) return readable
        if (!platform.servicesEnabled()) throw SystemReject("[unavailable] Location services are disabled on this device")
        return readable
    }

    /** `current(options)`. [deliver] receives JSON on success or the rejection message. */
    fun current(context: CallContext, options: JSONObject?, deliver: (ok: Boolean, value: String) -> Unit) {
        try {
            admit(context)
            val maxAge = LocationPolicy.maxAgeSeconds(options)
            val cached = { snapshots.read(LocationPolicy.canRead(platform.servicesEnabled(), platform.grant()), LocationPolicy.accuracyAuthorization(platform.grant()), maxAge) }
            if (context.isTimelineProjection) {
                deliver(true, (cached() ?: throw SystemReject("[timeline_read_only] No authorized Location snapshot is available")).toString())
                return
            }
            if (!platform.isForeground()) {
                if (!isAuthorizedForWidgetUpdates(context)) throw SystemReject("[widget_not_authorized] Allow location for widgets in Settings")
                deliver(true, (cached() ?: throw SystemReject("[no_data] Location data unavailable. Open the main app to refresh location.")).toString())
                return
            }
            if (!platform.servicesEnabled()) throw SystemReject("[unavailable] Location services are disabled on this device")
            if (platform.grant() == LocationGrant.NONE) {
                throw SystemReject(if (prompts.asked(PROMPT)) "Location permission denied. Enable Location access in Settings." else "Location permission not determined. Authorize in the main app settings.")
            }
            cached()?.takeIf { !it.getBoolean("isStale") }?.let { deliver(true, it.toString()); return }
            val finished = AtomicBoolean(false)
            val timeout = (LocationPolicy.timeoutSeconds(options) * 1000).toLong()
            var cancel: () -> Unit = {}
            val timer = SystemExecutor.pool.schedule({
                if (finished.compareAndSet(false, true)) { cancel(); deliver(false, "Location request timed out") }
            }, timeout, TimeUnit.MILLISECONDS)
            cancel = platform.requestFix(timeout) { fix ->
                if (finished.compareAndSet(false, true)) {
                    timer.cancel(false)
                    try { deliver(true, accept(context, fix, maxAge).toString()) } catch (error: SystemReject) { deliver(false, error.message.orEmpty()) }
                }
            }
        } catch (error: SystemReject) {
            deliver(false, error.message.orEmpty())
        } catch (error: Exception) {
            deliver(false, "[location_error] Unable to obtain a location fix")
        }
    }

    /** Validates a fresh fix against the current grant, stores it as the snapshot and builds the script result. */
    private fun accept(context: CallContext, fix: LocationFix?, maxAge: Double): JSONObject {
        val grant = platform.grant()
        if (!LocationPolicy.packageAllows(context)) throw SystemReject("[permission_denied] Declare location in widget.json")
        if (!LocationPolicy.canRead(platform.servicesEnabled(), grant)) { snapshots.clear(); throw SystemReject("[permission_denied] Location access changed") }
        if (fix == null) throw SystemReject("[location_error] Unable to obtain a location fix")
        val precision = LocationPolicy.accuracyAuthorization(grant)
        val encoded = LocationSnapshot.encode(fix, precision) ?: throw SystemReject("[no_data] No valid location fix is available")
        val payload = LocationSnapshot.decode(encoded, precision, maxAge, clock.now()) ?: throw SystemReject("[no_data] No valid location fix is available")
        // A finished execution receives nothing and leaves no snapshot behind.
        if (context.isActive) snapshots.write(encoded)
        return payload
    }

    /** Refreshes the snapshot from the app UI, outside any script deadline. [done] receives true when a valid fix was stored. */
    fun refreshFromApp(timeoutMilliseconds: Long = 20_000, done: (Boolean) -> Unit) {
        val grant = platform.grant()
        if (!LocationPolicy.canRead(platform.servicesEnabled(), grant)) { snapshots.clear(); SystemLog.call("location.refresh", "permission_denied"); done(false); return }
        platform.requestFix(timeoutMilliseconds) { fix ->
            val now = platform.grant()
            val encoded = fix?.let { LocationSnapshot.encode(it, LocationPolicy.accuracyAuthorization(now)) }
            val stored = encoded != null && LocationPolicy.canRead(platform.servicesEnabled(), now) &&
                LocationSnapshot.decode(encoded, LocationPolicy.accuracyAuthorization(now), null, clock.now()) != null && snapshots.write(encoded)
            SystemLog.call("location.refresh", if (stored) "ok" else "no_data")
            done(stored)
        }
    }

    /** Snapshot age in seconds for the app UI, or null when there is no valid snapshot. Coordinates are not exposed here. */
    fun snapshotAgeSeconds(): Double? {
        val grant = platform.grant()
        return snapshots.read(LocationPolicy.canRead(platform.servicesEnabled(), grant), LocationPolicy.accuracyAuthorization(grant), null)?.optDouble("age")
    }

    companion object { const val PROMPT = "location" }
}

/**
 * [LocationPlatform] on the framework [LocationManager]; no Play Services.
 * Only `ACCESS_COARSE_LOCATION` and `ACCESS_FINE_LOCATION` are used, never background location.
 */
class AndroidLocationPlatform(context: Context) : LocationPlatform {
    private val appContext = context.applicationContext
    private val manager: LocationManager? = appContext.getSystemService(LocationManager::class.java)

    override fun servicesEnabled(): Boolean = manager?.isLocationEnabled == true

    override fun grant(): LocationGrant = when {
        appContext.checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED -> LocationGrant.PRECISE
        appContext.checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION) == PackageManager.PERMISSION_GRANTED -> LocationGrant.APPROXIMATE
        else -> LocationGrant.NONE
    }

    override fun isForeground(): Boolean {
        val state = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(state)
        return state.importance <= ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    override fun requestFix(timeoutMilliseconds: Long, callback: (LocationFix?) -> Unit): () -> Unit {
        val locations = manager
        val provider = locations?.let { provider(it) }
        if (locations == null || provider == null || grant() == LocationGrant.NONE) { callback(null); return {} }
        val signal = CancellationSignal()
        try {
            locations.getCurrentLocation(provider, signal, SystemExecutor.pool) { location ->
                // The system reports null when it has no current fix; the last known one is still useful with its age.
                val fix = location ?: runCatching { locations.getLastKnownLocation(provider) }.getOrNull()
                callback(fix?.let { convert(it) })
            }
        } catch (error: SecurityException) {
            callback(null)
        } catch (error: IllegalArgumentException) {
            callback(null)
        }
        return { runCatching { signal.cancel() } }
    }

    private fun provider(locations: LocationManager): String? = listOf(
        LocationManager.FUSED_PROVIDER,
        if (grant() == LocationGrant.PRECISE) LocationManager.GPS_PROVIDER else LocationManager.NETWORK_PROVIDER,
        LocationManager.NETWORK_PROVIDER, LocationManager.GPS_PROVIDER,
    ).firstOrNull { name -> runCatching { locations.hasProvider(name) && locations.isProviderEnabled(name) }.getOrDefault(false) }

    private fun convert(location: Location): LocationFix = LocationFix(
        latitude = location.latitude, longitude = location.longitude,
        altitude = if (location.hasAltitude()) location.altitude else null,
        accuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else null,
        verticalAccuracy = if (location.hasVerticalAccuracy()) location.verticalAccuracyMeters.toDouble() else null,
        speed = if (location.hasSpeed()) location.speed.toDouble() else null,
        course = if (location.hasBearing()) location.bearing.toDouble() else null,
        timestampMilliseconds = location.time,
    )
}
