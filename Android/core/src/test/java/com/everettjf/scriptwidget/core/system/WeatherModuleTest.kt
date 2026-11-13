package com.everettjf.scriptwidget.core.system

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import java.net.URI

class WeatherModuleTest {
    private class FakeTransport(var status: Int = 200, var body: ByteArray = ByteArray(0)) : WeatherTransport {
        val urls = ArrayList<String>()
        val agents = ArrayList<String?>()
        var timeout = 0
        var fail = false
        var redirect: URI? = null
        var redirectAllowed: Boolean? = null
        override fun get(url: String, headers: Map<String, String>, timeoutMilliseconds: Int, allowRedirect: (URI) -> Boolean): WeatherResponse {
            urls += url; agents += headers["User-Agent"]; timeout = timeoutMilliseconds
            redirect?.let { redirectAllowed = allowRedirect(it) }
            if (fail) throw java.io.IOException("offline")
            return WeatherResponse(status, body)
        }
    }

    /** A recorded response for lat=59.91&lon=10.75: 85 entries from 2026-11-13T07:00:00Z, hourly for 53 hours and without `next_1_hours` after that. */
    private val recorded = javaClass.getResourceAsStream("/weather/met-norway-compact.json")!!.use { it.readBytes() }
    private var now = IsoDates.parse("2026-11-13T07:30:00Z")!!
    private val directory = temporaryDirectory()
    private val transport = FakeTransport(body = recorded)
    private val module = WeatherModule(transport, directory, WeatherModule.userAgent("1.1.0")) { now }
    private val declared = setOf("weather", "network")
    private val domains = listOf("api.met.no")
    private fun widget(installation: String = OWNER, queries: Int = 8, network: Int = 32) = context(declared, installation = installation, domains = domains, queries = queries, network = network)
    private fun oslo(hours: Int? = null) = JSONObject().put("latitude", 59.91).put("longitude", 10.75).apply { if (hours != null) put("hours", hours) }
    private fun series(vararg items: JSONObject) = JSONObject().put("properties", JSONObject().put("timeseries", JSONArray(items.toList()))).toString().toByteArray()
    private fun entry(time: String, details: JSONObject, next: JSONObject? = null) =
        JSONObject().put("time", time).put("data", JSONObject().put("instant", JSONObject().put("details", details)).apply { if (next != null) put("next_1_hours", next) })
    private fun details(temperature: Any? = 1.5, wind: Any? = 2.0) = JSONObject().apply { if (temperature != null) put("air_temperature", temperature); if (wind != null) put("wind_speed", wind) }

    @Test fun optionValidationAndRounding() {
        val options = WeatherOptions.parse(JSONObject().put("latitude", 37.3349).put("longitude", -122.00902))
        assertEquals(37.33, options.latitude, 0.0); assertEquals(-122.01, options.longitude, 0.0); assertEquals(24, options.hours)
        assertEquals("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=37.33&lon=-122.01", options.url)
        // Halves round away from zero, and whole numbers keep one decimal in the URL.
        assertEquals(0.13, WeatherOptions.round2(0.125), 0.0); assertEquals(-0.13, WeatherOptions.round2(-0.125), 0.0)
        assertEquals("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=60.0&lon=-180.0", WeatherOptions.parse(JSONObject().put("latitude", 60).put("longitude", -180)).url)
        assertEquals(48, WeatherOptions.parse(oslo(48)).hours); assertEquals(1, WeatherOptions.parse(oslo(1)).hours)
        val bad = listOf(
            JSONObject(), JSONObject().put("latitude", 59.91), JSONObject().put("longitude", 10.75),
            oslo().put("latitude", 90.01), oslo().put("latitude", -90.01), oslo().put("longitude", 180.5), oslo().put("longitude", -181),
            oslo().put("latitude", "59.91"), oslo().put("latitude", true), oslo().put("latitude", JSONObject.NULL),
            oslo(0), oslo(49), oslo().put("hours", 1.5), oslo().put("hours", "24"), oslo().put("hours", JSONObject.NULL),
            oslo().put("units", "imperial"), JSONObject().put("invalid", true),
        )
        for (options in bad) assertRejects("invalid_options") { WeatherOptions.parse(options) }
    }

    @Test fun normalizesARecordedMetNorwayPayload() {
        val result = WeatherRules.normalize(recorded, WeatherOptions.parse(oslo()), now)
        assertEquals(setOf("provider", "attribution", "latitude", "longitude", "fetchedAt", "isStale", "hours"), result.keys().asSequence().toSet())
        assertEquals("MET Norway", result.getString("provider"))
        assertEquals("{\"text\":\"Weather data from MET Norway\",\"url\":\"https://www.met.no/en/free-meteorological-data/Download-services\"}", Canonical.encode(result.getJSONObject("attribution")))
        assertEquals(59.91, result.getDouble("latitude"), 0.0); assertEquals(10.75, result.getDouble("longitude"), 0.0)
        assertEquals("2026-11-13T07:30:00Z", result.getString("fetchedAt")); assertFalse(result.getBoolean("isStale"))
        val hours = result.getJSONArray("hours")
        assertEquals(24, hours.length())
        val first = hours.getJSONObject(0)
        assertEquals(setOf("time", "temperatureC", "windMetersPerSecond", "precipitationMM", "condition"), first.keys().asSequence().toSet())
        assertEquals("2026-11-13T07:00:00Z", first.getString("time"))
        assertEquals(1.7, first.getDouble("temperatureC"), 0.0); assertEquals(3.0, first.getDouble("windMetersPerSecond"), 0.0)
        assertEquals(0.0, first.getDouble("precipitationMM"), 0.0); assertEquals("fair_day", first.getString("condition"))
        assertEquals("2026-11-14T06:00:00Z", hours.getJSONObject(23).getString("time"))

        // Entries more than an hour old are skipped; the rest keep their order.
        val later = WeatherRules.normalize(recorded, WeatherOptions.parse(oslo(48)), IsoDates.parse("2026-11-13T17:30:00Z")!!).getJSONArray("hours")
        assertEquals(48, later.length())
        assertEquals("2026-11-13T17:00:00Z", later.getJSONObject(0).getString("time"))
        // After the hourly part the provider has no next-hour data: both fields stay null.
        assertFalse(later.getJSONObject(42).isNull("condition"))
        assertEquals("2026-11-15T12:00:00Z", later.getJSONObject(43).getString("time"))
        for (index in 43..47) { assertTrue(later.getJSONObject(index).isNull("precipitationMM")); assertTrue(later.getJSONObject(index).isNull("condition")) }
        assertEquals(1, WeatherRules.normalize(recorded, WeatherOptions.parse(oslo(1)), now).getJSONArray("hours").length())
        // A forecast that is entirely in the past has no usable row.
        assertRejects("unavailable") { WeatherRules.normalize(recorded, WeatherOptions.parse(oslo()), IsoDates.parse("2026-12-24T00:00:00Z")!!) }
    }

    @Test fun normalizationBounds() {
        val options = WeatherOptions.parse(oslo())
        fun normalize(body: ByteArray) = WeatherRules.normalize(body, options, now)
        for (body in listOf("not json", "[]", "{}", "{\"properties\":{}}", "{\"properties\":{\"timeseries\":{}}}", "{\"properties\":{\"timeseries\":[1]}}", "{\"properties\":{\"timeseries\":[]}}")) {
            assertRejects("unavailable") { normalize(body.toByteArray()) }
        }
        assertRejects("unavailable") { normalize(ByteArray(WeatherRules.MAXIMUM_RESPONSE_BYTES + 1) { ' '.code.toByte() }) }
        val many = Array(301) { entry("2026-11-13T08:00:00Z", details()) }
        assertRejects("unavailable") { normalize(series(*many)) }
        assertEquals(24, normalize(series(*many.copyOf(300).requireNoNulls())).getJSONArray("hours").length())
        // Entries without a usable time or instant details are skipped, not fatal.
        val skipped = normalize(series(
            JSONObject().put("time", 5), JSONObject().put("time", "2026-11-13T08:00"), JSONObject().put("time", "2026-11-13T08:00:00Z"),
            JSONObject().put("time", "2026-11-13T08:00:00Z").put("data", JSONObject().put("instant", JSONObject())),
            entry("2026-11-13T06:29:59Z", details()), entry("2026-11-13T06:30:00Z", details(temperature = -40, wind = 0)),
        ))
        assertEquals(1, skipped.getJSONArray("hours").length())
        assertEquals(-40.0, skipped.getJSONArray("hours").getJSONObject(0).getDouble("temperatureC"), 0.0)
        // Values outside the physical bounds reject the payload.
        for (bad in listOf(details(temperature = 100.1), details(temperature = -150.5), details(temperature = null), details(temperature = "1"), details(wind = -0.1), details(wind = 200.5), details(wind = null))) {
            assertRejects("invalid_options") { normalize(series(entry("2026-11-13T08:00:00Z", bad))) }
        }
        fun next(amount: Any?, symbol: Any?) = JSONObject().apply {
            if (amount != null) put("details", JSONObject().put("precipitation_amount", amount))
            if (symbol != null) put("summary", JSONObject().put("symbol_code", symbol))
        }
        assertRejects("invalid_options") { normalize(series(entry("2026-11-13T08:00:00Z", details(), next(1000.5, null)))) }
        assertRejects("invalid_options") { normalize(series(entry("2026-11-13T08:00:00Z", details(), next(-1, null)))) }
        assertRejects("invalid_options") { normalize(series(entry("2026-11-13T08:00:00Z", details(), next(JSONObject.NULL, null)))) }
        val row = normalize(series(entry("2026-11-13T08:00:00Z", details(), next(1000, "x".repeat(70))))).getJSONArray("hours").getJSONObject(0)
        assertEquals(1000.0, row.getDouble("precipitationMM"), 0.0); assertEquals("x".repeat(64), row.getString("condition"))
        val untyped = normalize(series(entry("2026-11-13T08:00:00Z", details(), next(null, 7)))).getJSONArray("hours").getJSONObject(0)
        assertTrue(untyped.isNull("precipitationMM")); assertTrue(untyped.isNull("condition"))
    }

    @Test fun cacheFreshnessRules() {
        val options = WeatherOptions.parse(oslo())
        val fetched = WeatherRules.normalize(recorded, options, now).toString()
        fun cached(ageMilliseconds: Long, query: WeatherOptions = options) = WeatherRules.fromCache(fetched, query, now + ageMilliseconds)
        assertFalse(cached(0)!!.getBoolean("isStale"))
        assertFalse(cached(3_599_999)!!.getBoolean("isStale"))
        assertTrue(cached(3_600_000)!!.getBoolean("isStale"))
        assertTrue(cached(6 * 3_600_000L)!!.getBoolean("isStale"))
        assertNull(cached(6 * 3_600_000L + 1))
        assertNull(cached(-1)) // fetched in the future: the clock moved
        // Fewer hours are served from a longer cache; more are not.
        assertEquals(6, cached(0, WeatherOptions.parse(oslo(6)))!!.getJSONArray("hours").length())
        assertNull(cached(0, WeatherOptions.parse(oslo(25))))
        // Other coordinates never match, even when they are close.
        assertNull(cached(0, WeatherOptions.parse(oslo().put("latitude", 59.92))))
        assertNull(cached(0, WeatherOptions.parse(oslo().put("longitude", -10.75))))
        for (text in listOf(null, "", "not json", "{}", "{\"latitude\":59.91,\"longitude\":10.75,\"fetchedAt\":\"yesterday\",\"hours\":[]}", "x".repeat(WeatherRules.MAXIMUM_CACHE_BYTES + 1))) {
            assertNull(WeatherRules.fromCache(text, options, now))
        }
    }

    @Test fun policyOrder() {
        assertRejects("permission_denied") { module.forecast(context(setOf("network"), domains = domains), oslo()) }
        assertRejects("permission_denied") { module.forecast(context(declared, domains = domains, runtime = "1.5"), oslo()) }
        assertRejects("permission_denied") { module.forecast(context(declared, domains = domains, hasManifest = false), oslo()) }
        assertRejects("permission_denied") { module.forecast(context(declared, domains = domains, installation = "preview"), oslo()) }
        assertRejects("read_only") { module.forecast(context(declared, domains = domains, projection = true), oslo()) }
        assertRejects("read_only") { module.forecast(context(declared, domains = domains, liveActivity = true), oslo()) }
        assertRejects("query_limit") { module.forecast(widget(queries = 0), oslo()) }
        // Options are checked before the network declaration.
        assertRejects("invalid_options") { module.forecast(context(setOf("weather")), oslo(99)) }
        assertRejects("invalid_options") { module.forecast(widget(), null) }
        assertRejects("permission_denied") { module.forecast(context(setOf("weather"), domains = domains), oslo()) }
        assertRejects("permission_denied") { module.forecast(context(declared), oslo()) }
        assertRejects("permission_denied") { module.forecast(context(declared, domains = listOf("met.no", "*.example.com")), oslo()) }
        assertRejects("query_limit") { module.forecast(widget(network = 0), oslo()) }
        assertTrue("nothing reached the network", transport.urls.isEmpty())
        assertEquals(24, module.forecast(context(declared, domains = listOf("*.met.no")), oslo()).getJSONArray("hours").length())
    }

    @Test fun requestShapeAndFreshCache() {
        val first = module.forecast(widget(), JSONObject().put("latitude", 59.9149).put("longitude", 10.7461).put("hours", 12))
        assertEquals(listOf("https://api.met.no/weatherapi/locationforecast/2.0/compact?lat=59.91&lon=10.75"), transport.urls)
        assertEquals("ScriptWidget-Android/1.1.0 https://github.com/everettjf/scriptwidget", transport.agents.single())
        assertEquals(3000, transport.timeout)
        assertEquals(12, first.getJSONArray("hours").length()); assertFalse(first.getBoolean("isStale"))

        // Within the hour the cache answers without a request and without the network budget.
        now += 3_599_000
        val second = module.forecast(widget(network = 0), oslo(6))
        assertEquals(1, transport.urls.size)
        assertEquals(6, second.getJSONArray("hours").length()); assertFalse(second.getBoolean("isStale"))
        assertEquals("2026-11-13T07:30:00Z", second.getString("fetchedAt"))
        // More hours than were cached, other coordinates and another installation all go to the network.
        module.forecast(widget(), oslo(24)); assertEquals(2, transport.urls.size)
        module.forecast(widget(), oslo().put("latitude", 60)); assertEquals(3, transport.urls.size)
        module.forecast(widget(OTHER_OWNER), oslo().put("latitude", 60)); assertEquals(4, transport.urls.size)
        assertEquals("ScriptWidget-Android/0 https://github.com/everettjf/scriptwidget", WeatherModule.userAgent(""))
    }

    @Test fun staleCacheStandsInForAFailedRequest() {
        module.forecast(widget(), oslo())
        now += 3_600_000
        transport.fail = true
        val stale = module.forecast(widget(), oslo(3))
        assertTrue(stale.getBoolean("isStale")); assertEquals(3, stale.getJSONArray("hours").length())
        assertEquals("2026-11-13T07:30:00Z", stale.getString("fetchedAt"))
        assertEquals(2, transport.urls.size)
        transport.fail = false
        for (status in listOf(304, 403, 429, 500)) { transport.status = status; assertTrue(module.forecast(widget(), oslo()).getBoolean("isStale")) }
        transport.status = 200; transport.body = "{}".toByteArray()
        assertTrue(module.forecast(widget(), oslo()).getBoolean("isStale"))
        // A stale cache is not returned when the network budget is spent: the request was never attempted.
        assertRejects("query_limit") { module.forecast(widget(network = 0), oslo()) }
        now += 5 * 3_600_000L + 1
        assertRejects("unavailable") { module.forecast(widget(), oslo()) }
        transport.fail = true
        assertRejects("unavailable") { module.forecast(widget(), oslo()) }
        // A good response replaces the cache and is fresh again.
        transport.fail = false; transport.body = recorded; now = IsoDates.parse("2026-11-13T15:00:00Z")!!
        val fresh = module.forecast(widget(), oslo())
        assertFalse(fresh.getBoolean("isStale")); assertEquals("2026-11-13T15:00:00Z", fresh.getString("fetchedAt"))
    }

    @Test fun redirectsStayInsideTheDeclaredHostsAndCachesAreRetired() {
        transport.redirect = URI("https://example.com/forecast")
        module.forecast(widget(), oslo())
        assertEquals(false, transport.redirectAllowed)
        transport.redirect = URI("https://api.met.no/weatherapi/other")
        now += 3_600_000
        module.forecast(widget(), oslo())
        assertEquals(true, transport.redirectAllowed)
        now += 3_600_000
        module.forecast(context(declared, domains = domains, active = { false }), oslo())
        assertEquals("a finished execution follows no redirect", false, transport.redirectAllowed)

        val files = directory.listFiles()!!.map { it.name }
        assertEquals(listOf(ownerFileName(OWNER, ".json")), files)
        assertFalse("the installation identity is not a file name", files.single().contains(OWNER))
        module.retire(OWNER)
        assertTrue(directory.listFiles()!!.isEmpty())
        // A cache file that is not a regular bounded file is ignored, never trusted.
        File(directory, ownerFileName(OWNER, ".json")).writeText("x".repeat(WeatherRules.MAXIMUM_CACHE_BYTES + 1))
        transport.fail = true
        assertRejects("unavailable") { module.forecast(widget(), oslo()) }
    }
}
