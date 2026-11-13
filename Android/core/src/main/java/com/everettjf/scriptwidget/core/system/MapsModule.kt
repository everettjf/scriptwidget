package com.everettjf.scriptwidget.core.system

import android.content.Context
import android.location.Address
import android.location.Geocoder
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** A latitude/longitude rectangle, south-west to north-east. */
class MapBounds(val south: Double, val west: Double, val north: Double, val east: Double) {
    /** True when the point lies inside the rectangle, edges included. */
    fun contains(latitude: Double, longitude: Double): Boolean = latitude in south..north && longitude in west..east
}

/**
 * The coordinate options of `$maps.search` and `$maps.reverseGeocode`.
 *
 * Rules (`invalid_options` otherwise): only `latitude`, `longitude`, `radiusMeters` and the extra
 * fields of the method; `latitude` −90…90 and `longitude` −180…180 are required finite numbers;
 * `radiusMeters` is 100…50000 and 2000 when absent.
 */
class MapOptions(val latitude: Double, val longitude: Double, val radiusMeters: Double) {
    /**
     * The square region of side `2 × radiusMeters` around the coordinate, the region the Apple
     * runtime gives MapKit. Clamped to valid latitudes and longitudes; it does not wrap the antimeridian.
     */
    val bounds: MapBounds get() {
        val latitudeDelta = radiusMeters / METERS_PER_DEGREE
        val longitudeDelta = radiusMeters / (METERS_PER_DEGREE * Math.cos(Math.toRadians(latitude)).coerceAtLeast(0.01))
        return MapBounds((latitude - latitudeDelta).coerceAtLeast(-90.0), (longitude - longitudeDelta).coerceAtLeast(-180.0),
            (latitude + latitudeDelta).coerceAtMost(90.0), (longitude + longitudeDelta).coerceAtMost(180.0))
    }

    companion object {
        const val METERS_PER_DEGREE = 111_320.0
        private val shared = setOf("latitude", "longitude", "radiusMeters")

        /** @throws SystemReject `invalid_options` for any violation of the rules above. */
        fun parse(options: JSONObject, extraFields: Set<String>): MapOptions {
            SystemOptions.fields(options, shared + extraFields)
            return MapOptions(SystemOptions.number(options.opt("latitude"), -90.0..90.0), SystemOptions.number(options.opt("longitude"), -180.0..180.0),
                if (SystemOptions.member(options, "radiusMeters") != null) SystemOptions.number(options.get("radiusMeters"), 100.0..50000.0) else 2000.0)
        }
    }
}

/** What a geocoder returned for one place. Coordinates are null when the provider gave none. */
class MapPlace(val name: String?, val addressLines: List<String>, val locality: String?, val region: String?, val country: String?, val latitude: Double?, val longitude: Double?)

/** The device geocoder, replaceable in tests. [done] is called at most once, on any thread; null means the lookup failed. */
interface MapsPlatform {
    /** False when the device has no geocoder backend. */
    val isPresent: Boolean
    fun forward(text: String, maximum: Int, bounds: MapBounds?, done: (List<MapPlace>?) -> Unit)
    fun reverse(latitude: Double, longitude: Double, maximum: Int, done: (List<MapPlace>?) -> Unit)
}

/** Pure rules of `$maps`: the result shape and its bounds. */
object MapRules {
    const val MAXIMUM_RESULTS = 5
    const val MAXIMUM_TEXT_BYTES = 256
    const val MAXIMUM_NAME_CHARACTERS = 256
    const val MAXIMUM_ADDRESS_CHARACTERS = 512
    const val SNAPSHOT_UNSUPPORTED = "[unsupported_platform] \$maps.snapshot is not supported on Android in this release"

    private fun cut(text: String, maximum: Int): String = text.substring(0, text.offsetByCodePoints(0, minOf(maximum, text.codePointCount(0, text.length))))

    /**
     * `[{name, address, latitude, longitude}]`, at most five rows.
     *
     * - `name` is the place's own name, else its locality, else empty; at most 256 characters.
     * - `address` is the provider's address lines joined with ", "; without lines, the name,
     *   locality, region and country that exist. At most 512 characters.
     * - A place without valid coordinates takes [fallback] (the queried point of a reverse lookup)
     *   or is left out when there is none. Coordinates outside −90…90 / −180…180 count as missing.
     * - With [within], places outside the rectangle are left out before the five are taken.
     */
    fun rows(places: List<MapPlace>, fallback: Pair<Double, Double>? = null, within: MapBounds? = null): JSONArray {
        val rows = JSONArray()
        for (place in places) {
            val valid = place.latitude != null && place.longitude != null && place.latitude.isFinite() && place.longitude.isFinite() &&
                place.latitude in -90.0..90.0 && place.longitude in -180.0..180.0
            val latitude = if (valid) place.latitude!! else fallback?.first ?: continue
            val longitude = if (valid) place.longitude!! else fallback?.second ?: continue
            if (within != null && !within.contains(latitude, longitude)) continue
            val name = place.name?.takeIf { it.isNotBlank() } ?: place.locality?.takeIf { it.isNotBlank() } ?: ""
            val lines = place.addressLines.filter { it.isNotBlank() }
            val address = if (lines.isNotEmpty()) lines.joinToString(", ") else listOfNotNull(place.name, place.locality, place.region, place.country).filter { it.isNotBlank() }.distinct().joinToString(", ")
            rows.put(JSONObject().put("name", cut(name, MAXIMUM_NAME_CHARACTERS)).put("address", cut(address, MAXIMUM_ADDRESS_CHARACTERS)).put("latitude", latitude).put("longitude", longitude))
            if (rows.length() == MAXIMUM_RESULTS) break
        }
        return rows
    }
}

/**
 * `$maps` on Android, backed by the platform geocoder. Nothing is read from the device: only the
 * text or coordinates the script supplies are sent to the geocoder backend.
 *
 * Order of checks for `geocode`, `reverseGeocode` and `search`:
 * 1. the system gate (`maps` declared by an installed Runtime 1.6 package, not a future timeline
 *    entry or Live Activity, the eight-query budget);
 * 2. `invalid_options` for the arguments;
 * 3. `unavailable` when the device has no geocoder, the lookup fails or does not answer in time.
 * The gate is checked again before a result is delivered.
 *
 * `search` is a geocoder lookup of the query limited to the square region around the coordinate;
 * it finds named places and addresses, not categories of businesses as MapKit does.
 * `snapshot` has no keyless Android equivalent and rejects with `unsupported_platform` for a
 * package that passes steps 1 to 3 of the gate (it takes no query from the budget).
 * Android has no per-widget native grant for maps, as for `$weather`.
 */
class MapsModule(private val platform: MapsPlatform, private val timeoutMilliseconds: Long = TIMEOUT_MILLISECONDS) : NativeModule {
    override val apis: Set<String> = setOf("\$maps")

    override fun handles(operation: String): Boolean = operation.startsWith("maps.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        val finish = { ok: Boolean, value: String ->
            SystemLog.call(operation, if (ok) "ok" else SystemLog.code(value))
            done(ok, if (ok) value else JSONObject.quote(value))
        }
        when (operation) {
            "maps.geocode" -> geocode(context, payload?.opt("address"), finish)
            "maps.reverseGeocode" -> reverseGeocode(context, payload?.optJSONObject("options"), finish)
            "maps.search" -> search(context, payload?.optJSONObject("options"), finish)
            "maps.snapshot" -> guarded(finish) { snapshot(context) }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    /** Up to five places for an address: nonblank text without control characters, at most 256 UTF-8 bytes. */
    fun geocode(context: CallContext, address: Any?, done: (ok: Boolean, value: String) -> Unit) = guarded(done) {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        val text = SystemOptions.text(address, MapRules.MAXIMUM_TEXT_BYTES)
        lookup(context, done, { MapRules.rows(it) }) { platform.forward(text, MapRules.MAXIMUM_RESULTS, null, it) }
    }

    /** Up to five places at a coordinate; a place without its own coordinates reports the queried point. */
    fun reverseGeocode(context: CallContext, options: JSONObject?, done: (ok: Boolean, value: String) -> Unit) = guarded(done) {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        val query = MapOptions.parse(options ?: JSONObject(), emptySet())
        lookup(context, done, { MapRules.rows(it, fallback = query.latitude to query.longitude) }) { platform.reverse(query.latitude, query.longitude, MapRules.MAXIMUM_RESULTS, it) }
    }

    /** Up to five geocoder matches for `query` (nonblank, at most 256 UTF-8 bytes) inside the region; matches outside it are dropped. */
    fun search(context: CallContext, options: JSONObject?, done: (ok: Boolean, value: String) -> Unit) = guarded(done) {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        val query = MapOptions.parse(options ?: JSONObject(), setOf("query"))
        val text = SystemOptions.text(options?.opt("query"), MapRules.MAXIMUM_TEXT_BYTES)
        val bounds = query.bounds
        lookup(context, done, { MapRules.rows(it, within = bounds) }) { platform.forward(text, MapRules.MAXIMUM_RESULTS, bounds, it) }
    }

    /** Always rejects: `permission_denied`/`read_only` from the gate first, then `unsupported_platform`. */
    fun snapshot(context: CallContext): Nothing {
        SystemGate.validate(context, PERMISSION, writing = false, grants = null)
        throw SystemReject(MapRules.SNAPSHOT_UNSUPPORTED)
    }

    private fun guarded(done: (ok: Boolean, value: String) -> Unit, block: () -> Unit) {
        try { block() } catch (error: SystemReject) { done(false, error.message ?: SystemServiceError.FAILED) } catch (error: Exception) { done(false, SystemServiceError.FAILED) }
    }

    /** Runs one platform lookup and completes [done] exactly once: with the mapped rows, or `unavailable` on failure or after the timeout. */
    private fun lookup(context: CallContext, done: (ok: Boolean, value: String) -> Unit, map: (List<MapPlace>) -> JSONArray, run: ((List<MapPlace>?) -> Unit) -> Unit) {
        if (!platform.isPresent) throw SystemServiceError.UNAVAILABLE.reject()
        val finished = AtomicBoolean(false)
        val unavailable = { if (finished.compareAndSet(false, true)) done(false, SystemServiceError.UNAVAILABLE.message) }
        val timeout = try { SystemExecutor.pool.schedule(unavailable, timeoutMilliseconds, TimeUnit.MILLISECONDS) } catch (error: java.util.concurrent.RejectedExecutionException) { null }
        try {
            run { places ->
                if (finished.compareAndSet(false, true)) {
                    timeout?.cancel(false)
                    guarded(done) {
                        if (places == null) throw SystemServiceError.UNAVAILABLE.reject()
                        SystemGate.validate(context, PERMISSION, writing = false, grants = null)
                        done(true, map(places).toString())
                    }
                }
            }
        } catch (error: Exception) { timeout?.cancel(false); unavailable() }
    }

    companion object {
        const val PERMISSION = "maps"
        /** Below the five-second execution limit, so a silent geocoder still produces a clear error. */
        const val TIMEOUT_MILLISECONDS = 4_000L
    }
}

/** [MapsPlatform] over `android.location.Geocoder` and its asynchronous listener API. No Play Services dependency. */
class AndroidMapsPlatform(context: Context) : MapsPlatform {
    private val appContext = context.applicationContext

    override val isPresent: Boolean get() = Geocoder.isPresent()

    private fun listener(done: (List<MapPlace>?) -> Unit) = object : Geocoder.GeocodeListener {
        override fun onGeocode(addresses: MutableList<Address>) = done(addresses.map { place(it) })
        override fun onError(errorMessage: String?) = done(null)
    }

    override fun forward(text: String, maximum: Int, bounds: MapBounds?, done: (List<MapPlace>?) -> Unit) {
        val geocoder = Geocoder(appContext, Locale.getDefault())
        if (bounds == null) geocoder.getFromLocationName(text, maximum, listener(done))
        else geocoder.getFromLocationName(text, maximum, bounds.south, bounds.west, bounds.north, bounds.east, listener(done))
    }

    override fun reverse(latitude: Double, longitude: Double, maximum: Int, done: (List<MapPlace>?) -> Unit) {
        Geocoder(appContext, Locale.getDefault()).getFromLocation(latitude, longitude, maximum, listener(done))
    }

    private fun place(address: Address): MapPlace = MapPlace(
        address.featureName, (0..address.maxAddressLineIndex).mapNotNull { address.getAddressLine(it) }, address.locality, address.adminArea, address.countryName,
        if (address.hasLatitude()) address.latitude else null, if (address.hasLongitude()) address.longitude else null,
    )
}
