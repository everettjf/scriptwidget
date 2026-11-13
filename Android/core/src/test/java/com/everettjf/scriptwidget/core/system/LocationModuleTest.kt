package com.everettjf.scriptwidget.core.system

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class LocationModuleTest {
    private class FakePlatform(var enabled: Boolean = true, var grant: LocationGrant = LocationGrant.PRECISE, var foreground: Boolean = true, var fix: LocationFix? = null) : LocationPlatform {
        var requests = 0
        var deliver = true
        override fun servicesEnabled() = enabled
        override fun grant() = grant
        override fun isForeground() = foreground
        override fun requestFix(timeoutMilliseconds: Long, callback: (LocationFix?) -> Unit): () -> Unit {
            requests += 1
            if (deliver) callback(fix)
            return {}
        }
    }

    private val directory = temporaryDirectory()
    private var now = NOW
    private val snapshotFile = File(directory, "location-snapshot.json")
    private val store = LocationSnapshotStore(PrivateFile(snapshotFile, LocationSnapshot.MAXIMUM_BYTES)) { now }
    private val prompts = promptsIn(directory)
    private fun module(platform: FakePlatform) = LocationModule(platform, store, prompts) { now }
    private fun fix(ageSeconds: Long = 0, accuracy: Double? = 12.0) = LocationFix(37.3349, -122.009, 20.0, accuracy, null, null, null, now - ageSeconds * 1000)

    private fun current(module: LocationModule, context: CallContext, options: JSONObject? = null): Pair<Boolean, String> {
        var result: Pair<Boolean, String>? = null
        module.current(context, options) { ok, value -> result = ok to value }
        return result ?: error("current() did not complete synchronously")
    }

    @Test fun optionsPreferMillisecondsAndClamp() {
        assertEquals(10.0, LocationPolicy.timeoutSeconds(null), 0.0)
        assertEquals(2.0, LocationPolicy.timeoutSeconds(JSONObject().put("timeoutMs", 2000).put("timeout", 9)), 0.0)
        assertEquals(30.0, LocationPolicy.timeoutSeconds(JSONObject().put("timeout", 120)), 0.0)
        assertEquals(10.0, LocationPolicy.timeoutSeconds(JSONObject().put("timeout", -1)), 0.0)
        assertEquals(10.0, LocationPolicy.timeoutSeconds(JSONObject().put("timeout", "5")), 0.0)
        assertEquals(0.0, LocationPolicy.maxAgeSeconds(JSONObject().put("maxAge", 0)), 0.0)
        assertEquals(3600.0, LocationPolicy.maxAgeSeconds(JSONObject().put("maxAge", 3600)), 0.0)
        assertEquals(86_400.0, LocationPolicy.maxAgeSeconds(JSONObject().put("maxAgeMs", 1e12)), 0.0)
    }

    @Test fun statusStrings() {
        assertEquals("undeclared", LocationPolicy.status(false, true, LocationGrant.PRECISE, true))
        assertEquals("disabled", LocationPolicy.status(true, false, LocationGrant.PRECISE, true))
        assertEquals("authorizedWhenInUse", LocationPolicy.status(true, true, LocationGrant.APPROXIMATE, false))
        assertEquals("denied", LocationPolicy.status(true, true, LocationGrant.NONE, true))
        assertEquals("notDetermined", LocationPolicy.status(true, true, LocationGrant.NONE, false))
    }

    @Test fun legacyPackagesKeepLocationButPackage2MustDeclareIt() {
        assertTrue(LocationPolicy.packageAllows(context(hasManifest = false)))
        assertTrue(LocationPolicy.packageAllows(context(setOf("location"))))
        assertFalse(LocationPolicy.packageAllows(context(setOf("calendar"))))
    }

    @Test fun snapshotRoundTripReportsAgeAndStaleness() {
        val encoded = LocationSnapshot.encode(fix(ageSeconds = 120), "full")!!
        val fresh = LocationSnapshot.decode(encoded, "full", 3600.0, now)!!
        assertEquals(120.0, fresh.getDouble("age"), 0.001)
        assertFalse(fresh.getBoolean("isStale"))
        assertEquals("full", fresh.getString("accuracyAuthorization"))
        assertEquals(12.0, fresh.getDouble("accuracy"), 0.0)
        assertTrue(fresh.isNull("speed")); assertTrue(fresh.isNull("course")); assertTrue(fresh.isNull("verticalAccuracy"))
        assertEquals(setOf("latitude", "longitude", "altitude", "accuracy", "verticalAccuracy", "speed", "course", "timestamp", "accuracyAuthorization", "age", "isStale"), fresh.keys().asSequence().toSet())
        assertTrue(LocationSnapshot.decode(encoded, "full", null, now)!!.getBoolean("isStale"))
        assertTrue(LocationSnapshot.decode(encoded, "full", 60.0, now)!!.getBoolean("isStale"))
    }

    @Test fun snapshotIsDiscardedWhenExpiredFutureInvalidOrTooPrecise() {
        assertNull(LocationSnapshot.decode(LocationSnapshot.encode(fix(ageSeconds = 86_401), "full")!!, "full", 86_400.0, now))
        assertNotNull(LocationSnapshot.decode(LocationSnapshot.encode(fix(ageSeconds = 86_399), "full")!!, "full", 0.0, now))
        assertNull(LocationSnapshot.decode(LocationSnapshot.encode(fix(ageSeconds = -5), "full")!!, "full", 0.0, now))
        // A reduced-accuracy session cannot consume a full-accuracy snapshot; the reverse is fine.
        assertNull(LocationSnapshot.decode(LocationSnapshot.encode(fix(), "full")!!, "reduced", 0.0, now))
        assertNotNull(LocationSnapshot.decode(LocationSnapshot.encode(fix(), "reduced")!!, "full", 0.0, now))
        assertNull(LocationSnapshot.encode(fix(accuracy = null), "full"))
        assertNull(LocationSnapshot.encode(LocationFix(91.0, 0.0, null, 5.0, null, null, null, now), "full"))
        val valid = JSONObject(LocationSnapshot.encode(fix(), "full")!!)
        assertNull(LocationSnapshot.decode(JSONObject(valid.toString()).put("extra", 1).toString(), "full", 0.0, now))
        assertNull(LocationSnapshot.decode(JSONObject(valid.toString()).put("latitude", true).toString(), "full", 0.0, now))
        assertNull(LocationSnapshot.decode(JSONObject(valid.toString()).put("longitude", 181).toString(), "full", 0.0, now))
        assertNull(LocationSnapshot.decode(JSONObject(valid.toString()).put("accuracyAuthorization", "exact").toString(), "full", 0.0, now))
        assertNull(LocationSnapshot.decode("x".repeat(5000), "full", 0.0, now))
    }

    @Test fun admissionOrder() {
        val module = module(FakePlatform(fix = fix()))
        assertEquals("[live_activity_unavailable] Live Activity presentations cannot request location updates; update their state from the app", current(module, context(setOf("location"), liveActivity = true, installation = "preview")).second)
        assertEquals("[permission_denied] Install this widget to use location data", current(module, context(installation = "preview")).second)
        assertEquals("[permission_denied] Declare location in widget.json", current(module, context(setOf("calendar"), queries = 0)).second)
        assertEquals("[query_limit] System data query limit exceeded", current(module, context(setOf("location"), queries = 0)).second)
        assertRejectsWith("[query_limit] System data query limit exceeded") { module.requestAuthorization(context(setOf("location"), queries = 0)) }
    }

    @Test fun foregroundReadStoresASnapshotThatAWidgetThenReads() {
        val platform = FakePlatform(fix = fix())
        val module = module(platform)
        val (ok, value) = current(module, context(setOf("location")))
        assertTrue(value, ok)
        assertFalse(JSONObject(value).getBoolean("isStale"))
        assertTrue(snapshotFile.exists())

        platform.foreground = false
        now += 600_000
        val widget = current(module, context(setOf("location")), JSONObject().put("maxAge", 3600))
        assertTrue(widget.first)
        assertEquals(600.0, JSONObject(widget.second).getDouble("age"), 0.001)
        assertFalse(JSONObject(widget.second).getBoolean("isStale"))
        assertTrue(JSONObject(current(module, context(setOf("location"))).second).getBoolean("isStale"))
        assertEquals(1, platform.requests)
    }

    @Test fun widgetWithoutSnapshotOrGrantGetsDocumentedErrors() {
        val platform = FakePlatform(foreground = false)
        val module = module(platform)
        assertEquals("[no_data] Location data unavailable. Open the main app to refresh location.", current(module, context(setOf("location"))).second)
        platform.grant = LocationGrant.NONE
        assertEquals("[widget_not_authorized] Allow location for widgets in Settings", current(module, context(setOf("location"))).second)
        assertFalse(module.isAuthorizedForWidgetUpdates(context(setOf("location"))))
        assertFalse(module.requestAuthorization(context(setOf("location"))))
        assertEquals(0, platform.requests)
    }

    @Test fun revocationAndPrecisionDowngradeClearTheSnapshot() {
        val platform = FakePlatform(fix = fix())
        val module = module(platform)
        assertTrue(current(module, context(setOf("location"))).first)
        platform.grant = LocationGrant.APPROXIMATE
        platform.foreground = false
        assertEquals("[no_data] Location data unavailable. Open the main app to refresh location.", current(module, context(setOf("location")), JSONObject().put("maxAge", 3600)).second)
        assertFalse(snapshotFile.exists())

        platform.grant = LocationGrant.PRECISE; platform.foreground = true
        assertTrue(current(module, context(setOf("location"))).first)
        platform.enabled = false
        assertFalse(module.isAvailable(context(setOf("location"))))
        assertFalse(snapshotFile.exists())
        assertEquals("disabled", module.authorizationStatus(context(setOf("location"))))
    }

    @Test fun foregroundErrors() {
        val platform = FakePlatform(grant = LocationGrant.NONE)
        val module = module(platform)
        assertEquals("Location permission not determined. Authorize in the main app settings.", current(module, context(setOf("location"))).second)
        prompts.markAsked(LocationModule.PROMPT)
        assertEquals("Location permission denied. Enable Location access in Settings.", current(module, context(setOf("location"))).second)
        assertEquals("denied", module.authorizationStatus(context(setOf("location"))))
        assertEquals("undeclared", module.authorizationStatus(context(setOf("photos"))))
        platform.enabled = false
        assertEquals("[unavailable] Location services are disabled on this device", current(module, context(setOf("location"))).second)
        assertRejectsWith("[unavailable] Location services are disabled on this device") { module.requestAuthorization(context(setOf("location"))) }
        platform.enabled = true; platform.grant = LocationGrant.APPROXIMATE
        assertTrue(module.requestAuthorization(context(setOf("location"))))
        assertEquals("[location_error] Unable to obtain a location fix", current(module, context(setOf("location"))).second)
        platform.fix = fix(accuracy = null)
        assertEquals("[no_data] No valid location fix is available", current(module, context(setOf("location"))).second)
        platform.fix = fix()
        assertEquals("reduced", JSONObject(current(module, context(setOf("location"))).second).getString("accuracyAuthorization"))
    }

    @Test fun timelineProjectionOnlyReadsTheSnapshot() {
        val platform = FakePlatform(fix = fix())
        val module = module(platform)
        assertEquals("[timeline_read_only] No authorized Location snapshot is available", current(module, context(setOf("location"), projection = true)).second)
        assertTrue(current(module, context(setOf("location"))).first)
        assertTrue(current(module, context(setOf("location"), projection = true)).first)
        assertEquals(1, platform.requests)
    }

    @Test fun finishedExecutionLeavesNoSnapshotAndPermissionLossPreventsDelivery() {
        val platform = FakePlatform(fix = fix())
        val module = module(platform)
        current(module, context(setOf("location"), active = { false }))
        assertFalse(snapshotFile.exists())

        platform.deliver = false
        var result: Pair<Boolean, String>? = null
        val pending = object : LocationPlatform by platform {
            override fun requestFix(timeoutMilliseconds: Long, callback: (LocationFix?) -> Unit): () -> Unit {
                platform.grant = LocationGrant.NONE // revoked while the request is in flight
                callback(fix())
                return {}
            }
        }
        LocationModule(pending, store, prompts) { now }.current(context(setOf("location")), null) { ok, value -> result = ok to value }
        assertEquals(false to "[permission_denied] Location access changed", result)
        assertFalse(snapshotFile.exists())
    }
}
