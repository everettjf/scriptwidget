package com.everettjf.scriptwidget

import android.location.Geocoder
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.RunRequest
import com.everettjf.scriptwidget.core.system.CloudFolder
import com.everettjf.scriptwidget.core.system.CloudJsonStore
import com.everettjf.scriptwidget.core.system.FileSyncFolder
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeFalse
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * The Android 1.2 system APIs on a device: `$icloud` through the real runtime with a directory
 * under the app's cache standing in for the picked sync folder, and `$maps` against the device
 * geocoder. Each script renders one JSON string that the test reads.
 */
@RunWith(AndroidJUnit4::class)
class RealFolderSyncTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext
    private val created = ArrayList<InstalledPackage>()
    private val folderDirectory = File(context.cacheDir, "sync-folder-test-${System.nanoTime()}")
    private val otherDeviceDirectory = File(context.cacheDir, "sync-device-b-${System.nanoTime()}")
    private val account = "d".repeat(64)
    /** The installation of the same widget on the simulated second device. */
    private val otherInstallation = "99999999-9999-4999-8999-999999999999"

    @Before fun prepare() {
        AppServices.attach(context)
        folderDirectory.mkdirs()
        // The folder the user picked with the system picker: a real documents provider, not a plain directory.
        SystemModules.stores(context).cloudFolder.testFolder = null
        org.junit.Assume.assumeTrue("choose a sync folder in System Access first", SystemModules.stores(context).cloudFolder.choice()?.kind == "tree")
    }

    @After fun cleanUp() {
        for (installed in created) {
            runCatching { SystemModules.retireInstallation(context, installed.installation) }
            runCatching { AppServices.library.delete(installed.name) }
        }
        SystemModules.stores(context).cloudFolder.testFolder = null
        folderDirectory.deleteRecursively()
        otherDeviceDirectory.deleteRecursively()
    }

    private fun manifest(permissions: List<String>, actions: String = "") =
        """{"entry":"main.jsx","formatVersion":2,"id":"com.example.system12","name":"System 1.2 Test","minimumRuntimeVersion":"1.6","networkDomains":[],"permissions":${JSONArray(permissions)},"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"$actions}"""

    private fun install(source: String, manifest: String): InstalledPackage =
        AppServices.library.create("System 1.2 Test ${System.nanoTime()}", source, manifest).also { created += it }

    /** Runs the package (optionally one of its actions) and returns the JSON its script rendered. */
    private fun run(installed: InstalledPackage, actionID: String? = null): String {
        val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation, actionID = actionID,
            extraEnvironments = if (actionID == null) emptyMap() else mapOf("action-source" to "widget")))
        if (actionID != null) return result.execution.error?.message ?: "ok"
        assertEquals(result.execution.error?.message, null, result.execution.error)
        return Regex("\"children\":\\[(\".*\")\\]\\}$").find(result.execution.tree!!)!!.groupValues[1].let { JSONObject("{\"v\":$it}").getString("v") }
    }

    private val report = """.then(v => ${'$'}render(<text>{JSON.stringify(v)}</text>), e => ${'$'}render(<text>{JSON.stringify({error: String(e)})}</text>))"""

    @Test fun twoDevicesExchangeThroughTheFolderChosenWithTheSystemPicker() {
        fun store(body: String) = """try { const before = await ${'$'}icloud.readJSON("note.json"); const r = await $body; ${'$'}storage.setString("result", JSON.stringify(r)); } catch (e) { ${'$'}storage.setString("result", JSON.stringify({error: String(e)})); }"""
        val source = """
            async function save() { ${store("""${'$'}icloud.writeJSON("note.json", {text: "first note"}, before.revision)""")} }
            async function edit() { ${store("""${'$'}icloud.writeJSON("note.json", {text: "edited on A"}, before.revision)""")} }
            async function merge() { ${store("""${'$'}icloud.resolveJSON("note.json", {text: before.conflicts.map(c => c.value.text).sort().join(" + ")}, before.revision)""")} }
            async function sync() { ${store("""${'$'}icloud.sync()""")} }
            if (${'$'}getenv("action-id") === "") { Promise.all([${'$'}icloud.readJSON("note.json"), ${'$'}icloud.status()])$report }
        """
        val actions = listOf("save", "edit", "merge", "sync").joinToString(",", ""","actions":[""", "]") { """{"id":"$it","title":"$it","systemImage":"doc","function":"$it"}""" }
        val installed = install(source, manifest(listOf("icloud", "storage"), actions))
        val stores = SystemModules.stores(context)
        fun stored() = JSONObject(AppServices.runtime.storage.getString(installed.installation, "result"))
        fun rendered() = JSONArray(run(installed))
        /** Waits for this device's exchange with the folder; the one a write starts in the background is serialized with it. */
        fun exchange() = assertEquals(null, stores.cloud.exchange(installed.installation))

        // Declared but not connected: nothing is readable, and an action cannot write.
        assertTrue(run(installed), JSONObject(run(installed)).optString("error").contains("[icloud:notConnected]"))
        run(installed, "save")
        assertTrue(stored().toString(), stored().optString("error").contains("[icloud:notConnected]"))

        val storeID = stores.cloudStore.connect(installed.installation)
        val empty = rendered()
        val nothing = empty.getJSONObject(0)
        assertEquals(setOf("value", "revision", "state", "conflicts"), nothing.keys().asSequence().toSet())
        assertTrue(nothing.isNull("value")); assertEquals("", nothing.getString("revision")); assertEquals("cached", nothing.getString("state")); assertEquals(0, nothing.getJSONArray("conflicts").length())
        assertEquals("connected", empty.getJSONObject(1).getString("state"))
        assertEquals(storeID, empty.getJSONObject(1).getString("store"))
        assertTrue(empty.getJSONObject(1).isNull("uploaded"))
        assertEquals("preserveAllVersions", empty.getJSONObject(1).getString("conflictPolicy"))

        run(installed, "save")
        assertEquals(stored().toString(), "pending", stored().optString("state"))
        assertEquals("first note", stored().getJSONObject("value").getString("text"))
        assertEquals("cached", rendered().getJSONObject(0).getString("state"))
        exchange()

        // A second device with its own cache joins the same store through the same folder.
        val other = CloudJsonStore(otherDeviceDirectory) { SystemModules.stores(context).cloudFolder.current() }
        assertEquals(storeID, other.connect(otherInstallation, existingStore = storeID))
        assertEquals(1, JSONObject(other.synchronize(otherInstallation)).getInt("downloadedRevisions"))
        val seen = JSONObject(other.read(otherInstallation, "note.json"))
        assertEquals("first note", seen.getJSONObject("value").getString("text"))

        // Both write on the same version before exchanging.
        other.write(otherInstallation, "note.json", JSONObject().put("text", "edited on B"), seen.getString("revision"), false)
        run(installed, "edit")
        assertEquals(stored().toString(), "pending", stored().optString("state"))
        exchange()
        other.synchronize(otherInstallation)
        run(installed, "sync")
        assertEquals(stored().toString(), "pending", stored().optString("state"))
        assertTrue(stored().isNull("uploaded")); assertTrue(stored().has("materializedRevisions")); assertTrue(stored().has("downloadedRevisions"))

        val conflict = rendered().getJSONObject(0)
        assertEquals(conflict.toString(), "conflict", conflict.getString("state"))
        assertTrue(conflict.isNull("value"))
        assertEquals(2, conflict.getJSONArray("conflicts").length())
        assertEquals(setOf("edited on A", "edited on B"), (0..1).map { conflict.getJSONArray("conflicts").getJSONObject(it).getJSONObject("value").getString("text") }.toSet())
        // An ordinary write cannot choose a winner; both files are still in the folder.
        run(installed, "edit")
        assertTrue(stored().toString(), stored().optString("error").contains("[icloud:conflict]"))

        run(installed, "merge")
        assertEquals(stored().toString(), "pending", stored().optString("state"))
        assertEquals("edited on A + edited on B", stored().getJSONObject("value").getString("text"))
        exchange()
        other.synchronize(otherInstallation)
        val merged = JSONObject(other.read(otherInstallation, "note.json"))
        assertEquals("cached", merged.getString("state")); assertEquals("edited on A + edited on B", merged.getJSONObject("value").getString("text"))
    }
}
