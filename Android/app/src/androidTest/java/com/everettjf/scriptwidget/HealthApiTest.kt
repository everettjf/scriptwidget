package com.everettjf.scriptwidget

import androidx.health.connect.client.HealthConnectClient
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.system.AndroidHealthPlatform
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeNoException
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * `$health` against the device's Health Connect. The tests assert result
 * shapes and policy only: they never depend on, print or store a reading,
 * and they pass on a device with an empty health store. They are skipped
 * when Health Connect is unavailable or its permissions cannot be granted.
 */
@RunWith(AndroidJUnit4::class)
class HealthApiTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val created = ArrayList<String>()

    @Before fun prepare() {
        AppServices.attach(context)
        val platform = SystemModules.stores(context).healthPlatform
        assumeTrue("Health Connect is not available on this device", platform.sdkStatus() == HealthConnectClient.SDK_AVAILABLE)
        try {
            for (permission in platform.requestPermissions()) instrumentation.uiAutomation.grantRuntimePermission(context.packageName, permission)
        } catch (error: Exception) { assumeNoException("Health Connect permissions could not be granted", error) }
        assumeTrue("Health Connect permissions were not granted", platform.grantedPermissions().containsAll(AndroidHealthPlatform.READ_PERMISSIONS))
    }

    @After fun cleanUp() { created.forEach { runCatching { AppServices.library.delete(it) } } }

    private fun manifest(permissions: List<String>) =
        """{"entry":"main.jsx","formatVersion":2,"id":"com.example.health","name":"Health Test","minimumRuntimeVersion":"1.6","networkDomains":[],"permissions":${org.json.JSONArray(permissions)},"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"}"""

    private fun install(source: String, manifest: String): InstalledPackage =
        AppServices.library.create("Health Test ${System.nanoTime()}", source, manifest).also { created += it.name }

    /** Runs the package and returns the JSON its script rendered. */
    private fun run(installed: InstalledPackage): JSONObject {
        val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation))
        assertEquals(result.execution.error?.message, null, result.execution.error)
        val text = Regex("\"children\":\\[(\".*\")\\]\\}$").find(result.execution.tree!!)!!.groupValues[1].let { JSONObject("{\"v\":$it}").getString("v") }
        return JSONObject(text)
    }

    private val report = """.then(v => ${'$'}render(<text>{JSON.stringify(v)}</text>), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""
    private fun keys(value: JSONObject): Set<String> = value.keys().asSequence().toSet()

    @Test fun availabilityAndStatusNeverRevealGrants() {
        val script = """Promise.resolve({available: ${'$'}health.isAvailable(), status: ${'$'}health.authorizationStatus()})$report"""
        val declared = run(install(script, manifest(listOf("health"))))
        assertTrue(declared.toString(), declared.getBoolean("available"))
        assertEquals("notDisclosed", declared.getString("status"))
        val undeclared = run(install(script, manifest(emptyList())))
        assertEquals("undeclared", undeclared.getString("status"))
    }

    @Test fun stepCountTodayHasTheDocumentedShape() {
        val result = run(install("""${'$'}health.stepCountToday()$report""", manifest(listOf("health"))))
        assertFalse(result.toString().take(200), result.has("error"))
        assertEquals(setOf("value", "hasSamples", "unit", "start", "end"), keys(result))
        assertEquals("count", result.getString("unit"))
        assertTrue(result.getDouble("value") >= 0)
        // With no readable sample the legacy zero stays and the flag is false.
        if (!result.getBoolean("hasSamples")) assertEquals(0.0, result.getDouble("value"), 0.0)
        assertTrue(Regex("^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}\\.\\d{3}Z$").matches(result.getString("start")))
    }

    @Test fun dailyStatisticsHasTheDocumentedShape() {
        val result = run(install("""${'$'}health.dailyStatistics({metric: "steps", days: 7})$report""", manifest(listOf("health"))))
        assertFalse(result.optString("error"), result.has("error"))
        assertEquals(setOf("metric", "unit", "aggregation", "timeZone", "items"), keys(result))
        assertEquals("steps", result.getString("metric")); assertEquals("count", result.getString("unit")); assertEquals("sum", result.getString("aggregation"))
        val items = result.getJSONArray("items")
        assertEquals(7, items.length())
        for (index in 0 until items.length()) {
            val item = items.getJSONObject(index)
            assertEquals(setOf("date", "value", "hasSamples"), keys(item))
            assertTrue(Regex("^\\d{4}-\\d{2}-\\d{2}$").matches(item.getString("date")))
            assertEquals("a day without samples has a null value", !item.getBoolean("hasSamples"), item.isNull("value"))
        }
        val invalid = run(install("""${'$'}health.dailyStatistics({metric: "steps", days: 32})$report""", manifest(listOf("health"))))
        assertTrue(invalid.optString("error"), invalid.optString("error").contains("[invalid_options]"))
    }

    @Test fun summariesHaveTheDocumentedShapes() {
        val script = """Promise.all([${'$'}health.sleepSummary(), ${'$'}health.activitySummary(), ${'$'}health.workouts({limit: 3})]).then(v => ${'$'}render(<text>{JSON.stringify({sleep: v[0], activity: v[1], workouts: v[2]})}</text>), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""
        val result = run(install(script, manifest(listOf("health"))))
        assertFalse(result.optString("error"), result.has("error"))
        val sleep = result.getJSONObject("sleep")
        assertEquals(setOf("start", "end", "timeZone", "hasSamples", "sourceCount", "truncated", "totalSleepSeconds", "inBedSeconds", "awakeSeconds", "conflictSeconds", "stages", "aggregation"), keys(sleep))
        assertEquals(setOf("unspecified", "core", "deep", "rem"), keys(sleep.getJSONObject("stages")))
        val activity = result.getJSONObject("activity")
        assertEquals(setOf("date", "timeZone", "hasSamples", "moveMode", "move", "exercise", "stand"), keys(activity))
        // Android has no activity goals.
        for (ring in listOf("move", "exercise", "stand")) assertTrue(activity.getJSONObject(ring).isNull("goal"))
        val workouts = result.getJSONObject("workouts")
        assertEquals(setOf("start", "end", "timeZone", "hasSamples", "truncated", "items"), keys(workouts))
        assertTrue(workouts.getJSONArray("items").length() <= 3)
    }

    @Test fun undeclaredPackagesAreRejectedBeforeAnyRead() {
        val undeclared = manifest(emptyList())
        for (call in listOf("stepCountToday()", "heartRateLatest()", "sleepSummary()", "workouts()", "dailyStatistics({metric: \"steps\"})", "requestAuthorization()")) {
            val result = run(install("""${'$'}health.$call$report""", undeclared))
            assertTrue("$call: ${result.optString("error")}", result.optString("error").contains("[permission_denied]"))
        }
    }
}
