package com.everettjf.scriptwidget.core.system

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

class MapsModuleTest {
    /** Records what was asked and answers with [places]; `silent` never answers, `fail` reports an error. */
    private class FakeGeocoder(var places: List<MapPlace> = emptyList(), override var isPresent: Boolean = true, var silent: Boolean = false, var fail: Boolean = false, var throws: Boolean = false) : MapsPlatform {
        val calls = ArrayList<String>()
        var bounds: MapBounds? = null
        private fun answer(done: (List<MapPlace>?) -> Unit) { if (throws) error("geocoder"); if (!silent) done(if (fail) null else places) }
        override fun forward(text: String, maximum: Int, bounds: MapBounds?, done: (List<MapPlace>?) -> Unit) { calls += "forward:$text:$maximum"; this.bounds = bounds; answer(done) }
        override fun reverse(latitude: Double, longitude: Double, maximum: Int, done: (List<MapPlace>?) -> Unit) { calls += "reverse:$latitude:$longitude:$maximum"; answer(done) }
    }

    private val declared = setOf("maps")
    private fun place(name: String? = "Apple Park", lines: List<String> = listOf("1 Apple Park Way", "Cupertino, CA"), latitude: Double? = 37.33, longitude: Double? = -122.01,
                      locality: String? = "Cupertino", region: String? = "CA", country: String? = "United States") = MapPlace(name, lines, locality, region, country, latitude, longitude)

    /** Runs one call and returns `ok` and the delivered value; fails when nothing is delivered in two seconds. */
    private fun run(call: ((Boolean, String) -> Unit) -> Unit): Pair<Boolean, String> {
        val latch = CountDownLatch(1)
        var result: Pair<Boolean, String>? = null
        var deliveries = 0
        call { ok, value -> synchronized(this) { deliveries += 1; result = ok to value }; latch.countDown() }
        assertTrue("no result delivered", latch.await(2, TimeUnit.SECONDS))
        assertEquals(1, deliveries)
        return result!!
    }
    private fun code(result: Pair<Boolean, String>): String { assertFalse(result.second, result.first); return SystemLog.code(result.second) }
    private fun options(text: String) = JSONObject(text)

    @Test fun optionRulesAndBounds() {
        val parsed = MapOptions.parse(options("""{"latitude":37.33,"longitude":-122.01}"""), emptySet())
        assertEquals(2000.0, parsed.radiusMeters, 0.0)
        assertEquals(50000.0, MapOptions.parse(options("""{"latitude":-90,"longitude":180,"radiusMeters":50000}"""), emptySet()).radiusMeters, 0.0)
        assertEquals(100.0, MapOptions.parse(options("""{"latitude":0,"longitude":0,"radiusMeters":100,"query":"x"}"""), setOf("query")).radiusMeters, 0.0)
        val invalid = listOf(
            """{}""", """{"latitude":37.33}""", """{"longitude":1}""", // both coordinates are required
            """{"latitude":90.01,"longitude":0}""", """{"latitude":-90.01,"longitude":0}""", """{"latitude":0,"longitude":180.5}""", """{"latitude":0,"longitude":-181}""",
            """{"latitude":"37","longitude":0}""", """{"latitude":true,"longitude":0}""", """{"latitude":null,"longitude":0}""",
            """{"latitude":0,"longitude":0,"radiusMeters":99.9}""", """{"latitude":0,"longitude":0,"radiusMeters":50001}""", """{"latitude":0,"longitude":0,"radiusMeters":"2000"}""",
            """{"latitude":0,"longitude":0,"query":"park"}""", """{"latitude":0,"longitude":0,"size":256}""", """{"invalid":true}""", // unknown fields
        )
        for (text in invalid) assertRejects("invalid_options") { MapOptions.parse(options(text), emptySet()) }

        // The region is a square of side 2 x radius: about 0.027 degrees of latitude for 3 km, wider in longitude away from the equator.
        val bounds = MapOptions(37.33, -122.01, 3000.0).bounds
        assertEquals(37.33 - 3000 / 111_320.0, bounds.south, 1e-9); assertEquals(37.33 + 3000 / 111_320.0, bounds.north, 1e-9)
        assertEquals(3000 / (111_320.0 * Math.cos(Math.toRadians(37.33))), bounds.east + 122.01, 1e-9)
        assertTrue(bounds.contains(37.33, -122.01)); assertTrue(bounds.contains(bounds.north, bounds.west))
        assertFalse(bounds.contains(37.40, -122.01)); assertFalse(bounds.contains(37.33, -122.10))
        // Clamped at the poles and the antimeridian instead of producing impossible coordinates.
        val polar = MapOptions(89.99, 179.99, 50000.0).bounds
        assertEquals(90.0, polar.north, 0.0); assertEquals(180.0, polar.east, 0.0); assertTrue(polar.west >= -180.0)
    }

    @Test fun resultShapeAndBounds() {
        val rows = MapRules.rows(listOf(place()))
        assertEquals(1, rows.length())
        val row = rows.getJSONObject(0)
        assertEquals(setOf("name", "address", "latitude", "longitude"), row.keys().asSequence().toSet())
        assertEquals("Apple Park", row.getString("name"))
        assertEquals("1 Apple Park Way, Cupertino, CA", row.getString("address"))
        assertEquals(37.33, row.getDouble("latitude"), 0.0); assertEquals(-122.01, row.getDouble("longitude"), 0.0)

        // Without address lines the parts that exist are joined; without a name the locality stands in.
        val bare = MapRules.rows(listOf(place(name = null, lines = emptyList()))).getJSONObject(0)
        assertEquals("Cupertino", bare.getString("name")); assertEquals("Cupertino, CA, United States", bare.getString("address"))
        val empty = MapRules.rows(listOf(place(name = " ", lines = listOf(""), locality = null, region = null, country = null))).getJSONObject(0)
        assertEquals("", empty.getString("name")); assertEquals("", empty.getString("address"))

        // At most five rows, 256 characters of name and 512 of address; a surrogate pair is never split.
        assertEquals(5, MapRules.rows(List(9) { place(name = "P$it") }).length())
        val long = MapRules.rows(listOf(place(name = "😀".repeat(300), lines = listOf("a".repeat(600))))).getJSONObject(0)
        assertEquals(256, long.getString("name").codePointCount(0, long.getString("name").length))
        assertEquals(512, long.getString("address").length)

        // Missing or impossible coordinates: dropped for a forward lookup, the queried point for a reverse lookup.
        val missing = listOf(place(latitude = null), place(longitude = Double.NaN), place(latitude = 91.0), place(name = "Kept"))
        assertEquals("Kept", MapRules.rows(missing).let { assertEquals(1, it.length()); it.getJSONObject(0).getString("name") })
        val reversed = MapRules.rows(missing, fallback = 1.5 to 2.5)
        assertEquals(4, reversed.length())
        assertEquals(1.5, reversed.getJSONObject(0).getDouble("latitude"), 0.0); assertEquals(2.5, reversed.getJSONObject(2).getDouble("longitude"), 0.0)

        // A region keeps only what lies inside it, before the five are counted.
        val bounds = MapOptions(37.33, -122.01, 2000.0).bounds
        val mixed = List(6) { place(name = "Far$it", latitude = 40.0) } + place(name = "Near")
        assertEquals("""["Near"]""", MapRules.rows(mixed, within = bounds).let { rows -> JSONArray(List(rows.length()) { rows.getJSONObject(it).getString("name") }).toString() })
    }

    @Test fun geocodeReverseAndSearchUseTheGeocoder() {
        val geocoder = FakeGeocoder(listOf(place()))
        val module = MapsModule(geocoder)
        val geocoded = run { module.geocode(context(declared), "Cupertino, California", it) }
        assertTrue(geocoded.second, geocoded.first)
        assertEquals("Apple Park", JSONArray(geocoded.second).getJSONObject(0).getString("name"))
        assertEquals(listOf("forward:Cupertino, California:5"), geocoder.calls)
        assertNull(geocoder.bounds)

        geocoder.places = listOf(place(latitude = null, longitude = null))
        val reversed = run { module.reverseGeocode(context(declared), options("""{"latitude":37.33,"longitude":-122.01,"radiusMeters":500}"""), it) }
        assertEquals(37.33, JSONArray(reversed.second).getJSONObject(0).getDouble("latitude"), 0.0)
        assertEquals("reverse:37.33:-122.01:5", geocoder.calls.last())

        geocoder.places = listOf(place(name = "Elsewhere", latitude = 48.85, longitude = 2.35), place(name = "Memorial Park", latitude = 37.335, longitude = -122.015))
        val found = run { module.search(context(declared), options("""{"query":"park","latitude":37.33,"longitude":-122.01,"radiusMeters":3000}"""), it) }
        assertEquals("""["Memorial Park"]""", JSONArray(found.second).let { rows -> JSONArray(List(rows.length()) { rows.getJSONObject(it).getString("name") }).toString() })
        assertEquals("forward:park:5", geocoder.calls.last())
        assertTrue(geocoder.bounds!!.contains(37.335, -122.015)); assertFalse(geocoder.bounds!!.contains(48.85, 2.35))
        // No match in the region is an empty list, not an error.
        geocoder.places = emptyList()
        assertEquals("[]", run { module.search(context(declared), options("""{"query":"park","latitude":0,"longitude":0}"""), it) }.second)
    }

    @Test fun argumentValidation() {
        val geocoder = FakeGeocoder(listOf(place()))
        val module = MapsModule(geocoder)
        for (address in listOf<Any?>(null, JSONObject.NULL, 5, "", "   ", "a\u0000b", "line\nbreak", "x".repeat(257), "é".repeat(129))) {
            assertEquals("invalid_options", code(run { module.geocode(context(declared), address, it) }))
        }
        assertTrue(run { module.geocode(context(declared), "é".repeat(128), it) }.first)
        assertEquals("invalid_options", code(run { module.reverseGeocode(context(declared), null, it) }))
        assertEquals("invalid_options", code(run { module.reverseGeocode(context(declared), options("""{"latitude":1,"longitude":2,"query":"x"}"""), it) }))
        for (text in listOf("""{"latitude":1,"longitude":2}""", """{"latitude":1,"longitude":2,"query":""}""", """{"latitude":1,"longitude":2,"query":7}""",
            """{"latitude":1,"longitude":2,"query":"${"q".repeat(257)}"}""", """{"latitude":1,"longitude":2,"query":"x","size":256}""", """{"query":"x"}""")) {
            assertEquals(text, "invalid_options", code(run { module.search(context(declared), options(text), it) }))
        }
        // Nothing reached the geocoder for an invalid call except the one valid address.
        assertEquals(1, geocoder.calls.size)
    }

    @Test fun policyOrderAndErrorStrings() {
        val geocoder = FakeGeocoder(listOf(place()))
        val module = MapsModule(geocoder)
        val good = options("""{"latitude":1,"longitude":2}""")
        val denied = listOf(context(emptySet()), context(declared, hasManifest = false), context(declared, runtime = "1.5"), context(declared, runtime = null), context(declared, installation = "preview"))
        for (widget in denied) {
            assertEquals(SystemServiceError.PERMISSION_DENIED.message, run { module.geocode(widget, "", it) }.second)
            assertEquals("permission_denied", code(run { module.reverseGeocode(widget, good, it) }))
            assertEquals("permission_denied", code(run { module.search(widget, null, it) }))
        }
        // A future timeline entry and a Live Activity are read only, even with invalid options.
        assertEquals(SystemServiceError.READ_ONLY.message, run { module.geocode(context(declared, projection = true), "", it) }.second)
        assertEquals("read_only", code(run { module.reverseGeocode(context(declared, liveActivity = true), null, it) }))
        // The gate comes before option validation, and a rejected call still takes a query.
        val budget = context(declared, queries = 2)
        assertEquals("invalid_options", code(run { module.geocode(budget, "", it) }))
        assertTrue(run { module.geocode(budget, "Paris", it) }.first)
        assertEquals(SystemServiceError.QUERY_LIMIT.message, run { module.geocode(budget, "Paris", it) }.second)
        // Reads need no user action; an action may call too.
        assertTrue(run { module.reverseGeocode(context(declared, action = true), good, it) }.first)

        // Options are validated before availability is looked at.
        geocoder.isPresent = false
        assertEquals("invalid_options", code(run { module.geocode(context(declared), "", it) }))
        assertEquals(SystemServiceError.UNAVAILABLE.message, run { module.geocode(context(declared), "Paris", it) }.second)
        geocoder.isPresent = true
        geocoder.fail = true
        assertEquals("unavailable", code(run { module.search(context(declared), options("""{"latitude":1,"longitude":2,"query":"x"}"""), it) }))
        geocoder.fail = false; geocoder.throws = true
        assertEquals("unavailable", code(run { module.reverseGeocode(context(declared), good, it) }))
    }

    @Test fun silentGeocoderTimesOutAndLateOrRevokedResultsAreDropped() {
        val silent = FakeGeocoder(listOf(place()), silent = true)
        assertEquals("unavailable", code(run { MapsModule(silent, timeoutMilliseconds = 50).geocode(context(declared), "Paris", it) }))

        // An answer after the timeout is ignored: exactly one completion.
        var late: ((List<MapPlace>?) -> Unit)? = null
        val slow = object : MapsPlatform {
            override val isPresent = true
            override fun forward(text: String, maximum: Int, bounds: MapBounds?, done: (List<MapPlace>?) -> Unit) { late = done }
            override fun reverse(latitude: Double, longitude: Double, maximum: Int, done: (List<MapPlace>?) -> Unit) { late = done }
        }
        var deliveries = 0
        val latch = CountDownLatch(1)
        MapsModule(slow, timeoutMilliseconds = 50).geocode(context(declared), "Paris") { _, _ -> deliveries += 1; latch.countDown() }
        assertTrue(latch.await(2, TimeUnit.SECONDS))
        late!!(listOf(place())); late!!(null)
        assertEquals(1, deliveries)

        // The gate is checked again when the answer arrives.
        val permissions = mutableSetOf("maps")
        var pending: ((List<MapPlace>?) -> Unit)? = null
        val held = object : MapsPlatform {
            override val isPresent = true
            override fun forward(text: String, maximum: Int, bounds: MapBounds?, done: (List<MapPlace>?) -> Unit) { pending = done }
            override fun reverse(latitude: Double, longitude: Double, maximum: Int, done: (List<MapPlace>?) -> Unit) { pending = done }
        }
        val widget = CallContext(OWNER, true, permissions, emptyList(), "1.6", false, false, false)
        var outcome: Pair<Boolean, String>? = null
        MapsModule(held, timeoutMilliseconds = 5_000).geocode(widget, "Paris") { ok, value -> outcome = ok to value }
        assertNull(outcome)
        permissions.clear()
        pending!!(listOf(place()))
        assertEquals(SystemServiceError.PERMISSION_DENIED.message, outcome!!.second)
    }

    @Test fun snapshotIsRejectedAfterTheGate() {
        val geocoder = FakeGeocoder()
        val module = MapsModule(geocoder)
        assertRejectsWith("[unsupported_platform] \$maps.snapshot is not supported on Android in this release") { module.snapshot(context(declared)) }
        assertRejectsWith(SystemServiceError.PERMISSION_DENIED.message) { module.snapshot(context(emptySet())) }
        assertRejectsWith(SystemServiceError.READ_ONLY.message) { module.snapshot(context(declared, liveActivity = true)) }
        // It takes nothing from the query budget and never reaches the geocoder.
        val budget = context(declared, queries = 1)
        repeat(3) { assertRejects("unsupported_platform") { module.snapshot(budget) } }
        assertTrue(run { module.geocode(budget, "Paris", it) }.first)
        assertEquals(listOf("forward:Paris:5"), geocoder.calls)
        assertEquals("unsupported_platform", SystemLog.code(MapRules.SNAPSHOT_UNSUPPORTED))
    }

    @Test fun moduleDeclaresItsGlobal() {
        val module = MapsModule(FakeGeocoder())
        assertEquals(setOf("\$maps"), module.apis)
        assertTrue(module.handles("maps.geocode")); assertFalse(module.handles("weather.forecast"))
    }
}
