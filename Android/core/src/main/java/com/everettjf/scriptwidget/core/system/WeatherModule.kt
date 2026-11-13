package com.everettjf.scriptwidget.core.system

import com.everettjf.scriptwidget.core.api.FetchModule
import com.everettjf.scriptwidget.core.runtime.ExecutionRequest
import com.everettjf.scriptwidget.core.runtime.NativeModule
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.io.File
import java.net.URI

/**
 * `$weather.forecast(options)` input.
 *
 * Rules: closed fields (`latitude`, `longitude`, `hours`); latitude −90…90 and longitude −180…180,
 * rounded to two decimals before anything leaves the device; `hours` an integer 1…48, 24 when absent.
 */
class WeatherOptions(val latitude: Double, val longitude: Double, val hours: Int) {
    /** The MET Norway compact forecast for the rounded coordinates. */
    val url: String get() = "https://$HOST/weatherapi/locationforecast/2.0/compact?lat=$latitude&lon=$longitude"

    companion object {
        const val HOST = "api.met.no"
        private val fields = setOf("latitude", "longitude", "hours")

        /** @throws SystemReject `invalid_options` for any violation of the rules above. */
        fun parse(options: JSONObject): WeatherOptions {
            SystemOptions.fields(options, fields)
            val latitude = round2(SystemOptions.number(options.opt("latitude"), -90.0..90.0))
            val longitude = round2(SystemOptions.number(options.opt("longitude"), -180.0..180.0))
            val hours = if (options.has("hours")) SystemOptions.integer(options.get("hours"), 1..48) else 24
            return WeatherOptions(latitude, longitude, hours)
        }

        /** Two decimals, halves away from zero, as `rounded()` does in the Apple runtime. */
        fun round2(value: Double): Double {
            val scaled = value * 100
            return (if (scaled < 0) -Math.floor(-scaled + 0.5) else Math.floor(scaled + 0.5)) / 100
        }
    }
}

/** Pure rules of `$weather`: provider normalisation and the private cache. */
object WeatherRules {
    const val MAXIMUM_RESPONSE_BYTES = 2 * 1024 * 1024
    const val MAXIMUM_SERIES = 300
    const val MAXIMUM_CACHE_BYTES = 128 * 1024
    /** A matching cache younger than this is returned without a request. */
    const val FRESH_MILLISECONDS = 3_600_000L
    /** A matching cache up to this age may stand in for a failed request, marked `isStale`. */
    const val USABLE_MILLISECONDS = 6 * 3_600_000L
    const val PROVIDER = "MET Norway"
    const val ATTRIBUTION_TEXT = "Weather data from MET Norway"
    const val ATTRIBUTION_URL = "https://www.met.no/en/free-meteorological-data/Download-services"

    /**
     * Turns a MET Norway compact forecast into the documented result.
     *
     * - The body is at most 2 MiB and `properties.timeseries` is an array of at most 300 objects, else `unavailable`.
     * - Entries older than one hour before [nowMilliseconds], or without a time and instant details, are skipped.
     * - `air_temperature` must be −150…100 and `wind_speed` 0…200; a present `precipitation_amount`
     *   must be 0…1000. A violation rejects the whole payload (`invalid_options`, the Apple runtime's code).
     * - Missing precipitation and condition stay null; a condition is cut to 64 characters.
     * - At most `options.hours` rows; no usable row is `unavailable`.
     */
    fun normalize(body: ByteArray, options: WeatherOptions, nowMilliseconds: Long): JSONObject {
        val unavailable = { SystemServiceError.UNAVAILABLE.reject() }
        if (body.size > MAXIMUM_RESPONSE_BYTES) throw unavailable()
        val series = try {
            (JSONObject(body.toString(Charsets.UTF_8)).opt("properties") as? JSONObject)?.opt("timeseries") as? JSONArray
        } catch (error: JSONException) { null } ?: throw unavailable()
        if (series.length() > MAXIMUM_SERIES || (0 until series.length()).any { series.opt(it) !is JSONObject }) throw unavailable()
        val rows = JSONArray()
        for (index in 0 until series.length()) {
            val item = series.getJSONObject(index)
            val time = item.opt("time") as? String ?: continue
            val date = (if (time.isBlank() || SystemOptions.hasControlCharacters(time)) null else IsoDates.parse(time)) ?: continue
            if (date < nowMilliseconds - 3_600_000L) continue
            val values = item.opt("data") as? JSONObject ?: continue
            val details = (values.opt("instant") as? JSONObject)?.opt("details") as? JSONObject ?: continue
            val temperature = SystemOptions.number(details.opt("air_temperature"), -150.0..100.0)
            val wind = SystemOptions.number(details.opt("wind_speed"), 0.0..200.0)
            val next = values.opt("next_1_hours") as? JSONObject
            val nextDetails = next?.opt("details") as? JSONObject
            val precipitation = if (nextDetails != null && nextDetails.has("precipitation_amount")) SystemOptions.number(nextDetails.opt("precipitation_amount"), 0.0..1000.0) else null
            val symbol = (next?.opt("summary") as? JSONObject)?.opt("symbol_code") as? String
            rows.put(JSONObject().put("time", time).put("temperatureC", temperature).put("windMetersPerSecond", wind)
                .put("precipitationMM", precipitation ?: JSONObject.NULL)
                .put("condition", symbol?.let { it.substring(0, it.offsetByCodePoints(0, minOf(64, it.codePointCount(0, it.length)))) } ?: JSONObject.NULL))
            if (rows.length() == options.hours) break
        }
        if (rows.length() == 0) throw unavailable()
        return JSONObject().put("provider", PROVIDER)
            .put("attribution", JSONObject().put("text", ATTRIBUTION_TEXT).put("url", ATTRIBUTION_URL))
            .put("latitude", options.latitude).put("longitude", options.longitude)
            .put("fetchedAt", IsoDates.format(nowMilliseconds)).put("isStale", false).put("hours", rows)
    }

    /**
     * A cached forecast that may answer [options], or null.
     *
     * It matches only when the rounded coordinates are equal, `fetchedAt` is not in the future and at
     * most six hours old, and it holds at least the requested number of hours. The result carries the
     * first `options.hours` rows and `isStale` (true from one hour of age).
     */
    fun fromCache(text: String?, options: WeatherOptions, nowMilliseconds: Long): JSONObject? {
        if (text == null || text.toByteArray().size > MAXIMUM_CACHE_BYTES) return null
        return try {
            val cached = JSONObject(text)
            if ((cached.opt("latitude") as? Number)?.toDouble() != options.latitude || (cached.opt("longitude") as? Number)?.toDouble() != options.longitude) return null
            val fetched = (cached.opt("fetchedAt") as? String)?.let { IsoDates.parse(it) } ?: return null
            val age = nowMilliseconds - fetched
            val hours = cached.opt("hours") as? JSONArray ?: return null
            if (age < 0 || age > USABLE_MILLISECONDS || hours.length() < options.hours) return null
            val rows = JSONArray()
            for (index in 0 until options.hours) rows.put(hours.get(index))
            cached.put("hours", rows).put("isStale", age >= FRESH_MILLISECONDS)
        } catch (error: JSONException) { null }
    }
}

/** A provider response: the HTTP status and the bounded body. */
class WeatherResponse(val status: Int, val body: ByteArray)

/** The network side of `$weather`, replaceable in tests. Implementations throw on any transport failure. */
fun interface WeatherTransport {
    /** One GET. [allowRedirect] decides for every redirect target; a refused redirect is a failure. */
    fun get(url: String, headers: Map<String, String>, timeoutMilliseconds: Int, allowRedirect: (URI) -> Boolean): WeatherResponse
}

/** [WeatherTransport] over the bounded `fetch` transport: public hosts only, resolved addresses checked, at most 2 MiB. */
class FetchWeatherTransport(private val fetch: FetchModule = FetchModule()) : WeatherTransport {
    override fun get(url: String, headers: Map<String, String>, timeoutMilliseconds: Int, allowRedirect: (URI) -> Boolean): WeatherResponse {
        val uri = URI(url)
        if (fetch.validationError(uri) != null) throw FetchModule.FetchException("blocked")
        val response = fetch.perform("GET", uri, headers, null, timeoutMilliseconds) { target -> fetch.validationError(target) == null && allowRedirect(target) }
        return WeatherResponse(response.status, response.body)
    }
}

/**
 * `$weather.forecast`: MET Norway's compact forecast for coordinates the script supplies. The
 * device location is never read here. The order of checks is the Apple runtime's:
 * 1. the system gate (`weather` declared by an installed Runtime 1.6 package, not a future
 *    timeline entry or Live Activity, the eight-query budget);
 * 2. `invalid_options` for the options;
 * 3. `permission_denied` unless the package declares `network` and `api.met.no`;
 * 4. a matching cache younger than one hour is returned without a request;
 * 5. `query_limit` when the 32-request network budget of the execution is spent;
 * 6. the request (3 s timeout, redirects only to declared hosts); a failure returns a matching
 *    cache up to six hours old with `isStale: true`, else the failure.
 *
 * Android has no per-widget native grant for weather: nothing is read from the device.
 */
class WeatherModule(
    private val transport: WeatherTransport,
    private val directory: File,
    private val userAgent: String,
    private val clock: SystemClock = SystemClock { System.currentTimeMillis() },
) : NativeModule {
    override val apis: Set<String> = setOf("\$weather")

    override fun handles(operation: String): Boolean = operation.startsWith("weather.")

    override fun start(request: ExecutionRequest, operation: String, payload: JSONObject?, done: (ok: Boolean, json: String?) -> Unit) {
        val context = CallContext.from(request)
        when (operation) {
            "weather.forecast" -> runSystemCall(operation, done) { forecast(context, payload?.optJSONObject("options")).toString() }
            else -> done(false, JSONObject.quote("Unsupported operation $operation"))
        }
    }

    fun forecast(context: CallContext, options: JSONObject?): JSONObject {
        SystemGate.check(context, PERMISSION, writing = false, grants = null)
        val query = WeatherOptions.parse(options ?: JSONObject())
        if (!context.allowsHost(WeatherOptions.HOST)) throw SystemServiceError.PERMISSION_DENIED.reject()
        val cache = cache(context.installation)
        val cached = synchronized(cache.lock) { WeatherRules.fromCache(runCatching { cache.read() }.getOrNull(), query, clock.now()) }
        if (cached != null && !cached.getBoolean("isStale")) return cached
        if (!context.consumeNetworkRequest()) throw SystemServiceError.QUERY_LIMIT.reject()
        return try {
            val response = try {
                transport.get(query.url, mapOf("User-Agent" to userAgent), TIMEOUT_MILLISECONDS) { target -> context.isActive && context.allowsHost(target.host.orEmpty()) }
            } catch (error: Exception) { throw SystemServiceError.UNAVAILABLE.reject() }
            SystemGate.validate(context, PERMISSION, writing = false, grants = null)
            if (!context.allowsHost(WeatherOptions.HOST) || response.status != 200) throw SystemServiceError.UNAVAILABLE.reject()
            val normalized = WeatherRules.normalize(response.body, query, clock.now())
            val encoded = normalized.toString()
            if (encoded.toByteArray().size > WeatherRules.MAXIMUM_CACHE_BYTES) throw SystemServiceError.LIMIT_EXCEEDED.reject()
            if (!synchronized(cache.lock) { cache.write(encoded) }) throw SystemServiceError.UNAVAILABLE.reject()
            normalized
        } catch (error: SystemReject) { cached ?: throw error }
    }

    /** Removes the forecast cache of a deleted installation. */
    fun retire(installation: String) {
        if (CallContext.isOwner(installation)) cache(installation).delete()
        SystemLog.call("weather.retire", "ok")
    }

    /** One forecast per installation, outside every script-reachable path. */
    private fun cache(installation: String) = PrivateFile(File(directory, ownerFileName(installation, ".json")), WeatherRules.MAXIMUM_CACHE_BYTES)

    companion object {
        const val PERMISSION = "weather"
        const val TIMEOUT_MILLISECONDS = 3_000

        /** MET Norway asks every client to identify itself; no user or device detail is included. */
        fun userAgent(versionName: String): String = "ScriptWidget-Android/${versionName.ifEmpty { "0" }} https://github.com/everettjf/scriptwidget"
    }
}
