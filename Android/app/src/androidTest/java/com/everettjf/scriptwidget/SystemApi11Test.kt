package com.everettjf.scriptwidget

import android.Manifest
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.RunRequest
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.UUID

/**
 * The Android 1.1 system APIs against the real device: the MET Norway
 * forecast over the network, AlarmManager and the notification manager, the
 * document and contact stores, and the media session manager. Each script
 * renders one JSON string that the test reads.
 */
@RunWith(AndroidJUnit4::class)
class SystemApi11Test {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val created = ArrayList<InstalledPackage>()

    @Before fun prepare() {
        AppServices.attach(context)
        instrumentation.uiAutomation.grantRuntimePermission(context.packageName, Manifest.permission.POST_NOTIFICATIONS)
    }

    @After fun cleanUp() {
        for (installed in created) {
            runCatching { SystemModules.retireInstallation(context, installed.installation) }
            runCatching { AppServices.library.delete(installed.name) }
        }
    }

    private fun manifest(permissions: List<String>, domains: List<String> = emptyList(), actions: String = "") =
        """{"entry":"main.jsx","formatVersion":2,"id":"com.example.system11","name":"System 1.1 Test","minimumRuntimeVersion":"1.6","networkDomains":${JSONArray(domains)},"permissions":${JSONArray(permissions)},"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"$actions}"""

    private fun install(source: String, manifest: String): InstalledPackage =
        AppServices.library.create("System 1.1 Test ${System.nanoTime()}", source, manifest).also { created += it }

    /** Runs the package (optionally one of its actions) and returns the JSON its script rendered. */
    private fun run(installed: InstalledPackage, actionID: String? = null): String {
        val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation, actionID = actionID,
            extraEnvironments = if (actionID == null) emptyMap() else mapOf("action-source" to "widget")))
        if (actionID != null) return result.execution.error?.message ?: "ok"
        assertEquals(result.execution.error?.message, null, result.execution.error)
        return Regex("\"children\":\\[(\".*\")\\]\\}$").find(result.execution.tree!!)!!.groupValues[1].let { JSONObject("{\"v\":$it}").getString("v") }
    }

    private val report = """.then(v => ${'$'}render(<text>{JSON.stringify(v)}</text>), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""

    @Test fun weatherForecastFromMetNorway() {
        val script = """${'$'}weather.forecast({latitude: 59.9139, longitude: 10.7522, hours: 6})$report"""
        // Without the network declaration nothing is requested.
        val undeclared = JSONObject(run(install(script, manifest(listOf("weather")))))
        assertTrue(undeclared.toString(), undeclared.optString("error").contains("[permission_denied]"))
        val invalid = JSONObject(run(install(script.replace("hours: 6", "hours: 49"), manifest(listOf("weather", "network"), listOf("api.met.no")))))
        assertTrue(invalid.toString(), invalid.optString("error").contains("[invalid_options]"))

        val installed = install(script, manifest(listOf("weather", "network"), listOf("api.met.no")))
        val result = JSONObject(run(installed))
        // No connection or a slow provider is not a failure of this build.
        assumeFalse("MET Norway was not reachable: $result", result.optString("error").contains("[unavailable]"))
        assertFalse(result.toString(), result.has("error"))
        assertEquals("MET Norway", result.getString("provider"))
        assertEquals("Weather data from MET Norway", result.getJSONObject("attribution").getString("text"))
        assertTrue(result.getJSONObject("attribution").getString("url").startsWith("https://www.met.no/"))
        assertEquals(59.91, result.getDouble("latitude"), 0.0); assertEquals(10.75, result.getDouble("longitude"), 0.0)
        assertFalse(result.getBoolean("isStale"))
        val hours = result.getJSONArray("hours")
        assertEquals(6, hours.length())
        val first = hours.getJSONObject(0)
        assertEquals(setOf("time", "temperatureC", "windMetersPerSecond", "precipitationMM", "condition"), first.keys().asSequence().toSet())
        assertTrue(first.getDouble("temperatureC") in -150.0..100.0)

        // The second run is answered from the private cache: same fetch time.
        val cached = JSONObject(run(installed))
        assertEquals(result.getString("fetchedAt"), cached.getString("fetchedAt"))
    }

    @Test fun alarmsScheduleListAndCancelFromAnAction() {
        val requestID = UUID.randomUUID().toString()
        fun store(call: String) = """try { const r = await $call; ${'$'}storage.setString("result", JSON.stringify(r)); } catch (e) { ${'$'}storage.setString("result", JSON.stringify({error: String(e)})); }"""
        val source = """
            async function start() { ${store("""${'$'}alarms.schedule({requestID: "$requestID", key: "focus", title: "Focus complete", seconds: 1500})""")} }
            async function pause() { ${store("""${'$'}alarms.pause("focus")""")} }
            async function resume() { ${store("""${'$'}alarms.resume("focus")""")} }
            async function cancel() { ${store("""${'$'}alarms.cancel("focus")""")} }
            if (${'$'}getenv("action-id") === "") { Promise.all([${'$'}alarms.status(), ${'$'}alarms.pending()])$report }
        """
        val actions = ""","actions":[{"id":"start","title":"Start","systemImage":"timer","function":"start"},{"id":"pause","title":"Pause","systemImage":"pause","function":"pause"},""" +
            """{"id":"resume","title":"Resume","systemImage":"play","function":"resume"},{"id":"cancel","title":"Cancel","systemImage":"xmark","function":"cancel"}]"""
        val installed = install(source, manifest(listOf("alarms", "storage"), actions = actions))
        fun stored() = JSONObject(AppServices.runtime.storage.getString(installed.installation, "result"))
        fun pending(): JSONArray = JSONArray(run(installed)).getJSONArray(1)

        // Reads and writes need the per-widget grant.
        assertTrue(run(installed), JSONObject(run(installed)).optString("error").contains("[permission_denied]"))
        run(installed, "start")
        assertTrue("without the grant: ${stored()}", stored().optString("error").contains("[permission_denied]"))

        SystemModules.stores(context).grants.set(installed.installation, "alarms", true)
        assertEquals("authorized", JSONArray(run(installed)).getJSONObject(0).getString("authorization"))
        assertEquals(0, pending().length())
        run(installed, "start")
        assertEquals(stored().toString(), "scheduled", stored().optString("status"))
        assertFalse(stored().getBoolean("replayed"))
        assertEquals("""[{"key":"focus","state":"countdown"}]""", pending().toString())
        // The same request again replays; it does not start a second timer.
        run(installed, "start")
        assertTrue(stored().toString(), stored().optBoolean("replayed"))

        run(installed, "pause")
        assertEquals(stored().toString(), "requested", stored().optString("status"))
        assertEquals("paused", pending().getJSONObject(0).getString("state"))
        run(installed, "resume")
        assertEquals("countdown", pending().getJSONObject(0).getString("state"))
        run(installed, "cancel")
        assertEquals(stored().toString(), "focus", stored().optString("key"))
        assertEquals(0, pending().length())
        run(installed, "cancel")
        assertTrue(stored().toString(), stored().optString("error").contains("[unavailable]"))
    }

    @Test fun documentsAndContactsAreEmptyUntilTheUserPicksSomething() {
        val documents = """${'$'}documents.list().then(list => ${'$'}documents.readJSON("11111111-1111-4111-8111-111111111111").then(v => ${'$'}render(<text>{JSON.stringify({list, v})}</text>), e => ${'$'}render(<text>{JSON.stringify({list, error: String(e)})}</text>)), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""
        val empty = JSONObject(run(install(documents, manifest(listOf("documents")))))
        assertEquals(empty.toString(), 0, empty.getJSONArray("list").length())
        assertTrue(empty.toString(), empty.optString("error").contains("[permission_denied]"))
        val undeclared = JSONObject(run(install(documents, manifest(emptyList()))))
        assertTrue(undeclared.toString(), undeclared.optString("error").contains("[permission_denied]"))
        assertFalse(undeclared.has("list"))

        // An imported copy is readable by its installation only.
        val owner = install("""${'$'}documents.list().then(list => Promise.all([${'$'}documents.readJSON(list[0].id), ${'$'}documents.readCSV(list[1].id)]).then(v => ${'$'}render(<text>{JSON.stringify({list, v})}</text>)))""" +
            """.catch(e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))""", manifest(listOf("documents")))
        val store = SystemModules.stores(context).documentStore
        store.add(owner.installation, "goals.json", "json", """{"goal":3}""".toByteArray(), null)
        store.add(owner.installation, "table.csv", "csv", "name,\"city, country\"\nAda,\"London, UK\"\n".toByteArray(), null)
        val read = JSONObject(run(owner))
        assertEquals(read.toString(), 2, read.getJSONArray("list").length())
        assertEquals(setOf("id", "name", "type", "bytes"), read.getJSONArray("list").getJSONObject(0).keys().asSequence().toSet())
        assertEquals(3, read.getJSONArray("v").getJSONObject(0).getInt("goal"))
        assertEquals("""{"headers":["name","city, country"],"rows":[["Ada","London, UK"]],"truncated":false}""", read.getJSONArray("v").getJSONObject(1).toString())
        assertEquals(0, JSONObject(run(install(documents, manifest(listOf("documents"))))).getJSONArray("list").length())

        val contacts = """${'$'}contacts.selected()$report"""
        assertEquals("[]", run(install(contacts, manifest(listOf("contacts")))))
        assertTrue(JSONObject(run(install(contacts, manifest(emptyList())))).optString("error").contains("[permission_denied]"))
        val chosen = install(contacts, manifest(listOf("contacts")))
        SystemModules.stores(context).contactStore.put(chosen.installation, "test-lookup", "Ada Lovelace", "Analytical Engines", listOf("+44 20 7946 0000"), listOf("ada@example.com"))
        val people = JSONArray(run(chosen))
        assertEquals(1, people.length())
        assertEquals(setOf("id", "name", "organization", "phones", "emails"), people.getJSONObject(0).keys().asSequence().toSet())
        assertEquals("Ada Lovelace", people.getJSONObject(0).getString("name"))
    }

    @Test fun musicReportsThatAccessIsNotAuthorized() {
        // Notification access can only be enabled by the user in system settings; a test device has it off.
        assumeFalse("notification access is enabled on this device", SystemModules.stores(context).musicPlatform.accessEnabled())
        val script = """
            const flags = {available: ${'$'}music.isAvailable(), status: ${'$'}music.authorizationStatus()};
            ${'$'}music.current().then(v => ${'$'}render(<text>{JSON.stringify({...flags, v})}</text>), e => ${'$'}render(<text>{JSON.stringify({...flags, error: String(e)})}</text>))
        """
        val declared = JSONObject(run(install(script, manifest(listOf("music")))))
        assertTrue(declared.toString(), declared.getBoolean("available"))
        assertTrue(declared.toString(), declared.getString("status") in setOf("notDetermined", "denied"))
        assertTrue(declared.toString(), declared.optString("error").contains("[music_permission]"))
        val undeclared = JSONObject(run(install(script, manifest(emptyList()))))
        assertFalse(undeclared.getBoolean("available"))
        assertEquals("undeclared", undeclared.getString("status"))
        assertTrue(undeclared.toString(), undeclared.optString("error").contains("[music_permission]"))
    }
}
