package com.everettjf.scriptwidget

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.everettjf.scriptwidget.core.RunRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

/** The library on a real device: archives, validation, identity, bundled templates. */
@RunWith(AndroidJUnit4::class)
class LibraryTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val created = ArrayList<String>()

    @Before fun attach() { AppServices.attach(context) }
    @After fun cleanUp() { created.forEach { runCatching { AppServices.library.delete(it) } } }

    private fun archive(entries: Map<String, String>): ByteArrayInputStream {
        val bytes = ByteArrayOutputStream()
        ZipOutputStream(bytes).use { zip -> for ((name, text) in entries) { zip.putNextEntry(ZipEntry(name)); zip.write(text.toByteArray()); zip.closeEntry() } }
        return ByteArrayInputStream(bytes.toByteArray())
    }

    private val manifest = """{"entry":"main.jsx","formatVersion":2,"id":"com.example.imported","name":"Imported","networkDomains":[],"permissions":[],"plugins":[],"runtimeVersion":"1.0","supportedFamilies":["systemSmall"],"version":"1.0.0"}"""

    private fun import(entries: Map<String, String>, name: String = "Import Test ${System.nanoTime()}"): InstalledPackage =
        AppServices.library.importArchive(archive(entries), name).also { created += it.name }

    private fun rejected(entries: Map<String, String>): String {
        val before = AppServices.library.list().map { it.name }.toSet()
        try {
            import(entries)
            fail("the archive should have been rejected")
        } catch (error: Exception) {
            assertEquals("a rejected import must leave the library unchanged", before, AppServices.library.list().map { it.name }.toSet())
            return error.message.orEmpty()
        }
        return ""
    }

    @Test fun importsAPackageExportedWithATopLevelFolderAndRunsIt() {
        val installed = import(mapOf("Imported/widget.json" to manifest, "Imported/main.jsx" to "\$render(<text>from archive</text>)", "Imported/lib/util.js" to "var helper = 1;"))
        assertEquals(setOf("lib/util.js", "main.jsx", "widget.json"), installed.files.paths().toSet())
        val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation, buildDirectory = installed.buildDirectory))
        assertNull(result.execution.error?.message, result.execution.error)
        assertTrue(result.execution.tree!!.contains("from archive"))
    }

    @Test fun exportThenImportKeepsTheFilesButNotTheInstallationIdentity() {
        val original = import(mapOf("widget.json" to manifest, "main.jsx" to "\$render(<text>round trip</text>)"))
        val exported = ByteArrayOutputStream()
        AppServices.library.exportArchive(original.name, exported)
        val copy = AppServices.library.importArchive(ByteArrayInputStream(exported.toByteArray()), "Round Trip Copy").also { created += it.name }
        assertEquals(original.files.readText("main.jsx"), copy.files.readText("main.jsx"))
        assertNotEquals(original.installation, copy.installation)
        assertFalse(copy.files.paths().any { it.startsWith(".") })
    }

    @Test fun rejectsTraversalInvalidManifestsAndSourceThatDoesNotCompile() {
        rejected(mapOf("../escape/main.jsx" to "1"))
        rejected(mapOf("widget.json" to manifest.replace("\"formatVersion\":2", "\"formatVersion\":3"), "main.jsx" to "\$render(<text>x</text>)"))
        rejected(mapOf("widget.json" to manifest.replace("\"permissions\":[]", "\"permissions\":[],\"surprise\":true"), "main.jsx" to "\$render(<text>x</text>)"))
        rejected(mapOf("widget.json" to manifest.replace("\"entry\":\"main.jsx\"", "\"entry\":\"missing.jsx\""), "main.jsx" to "\$render(<text>x</text>)"))
        rejected(mapOf("widget.json" to manifest, "main.jsx" to "const broken = ;"))
    }

    @Test fun renameKeepsTheIdentityAndDuplicateGetsANewOne() {
        val original = import(mapOf("main.jsx" to "\$render(<text>identity</text>)"))
        val renamed = AppServices.library.rename(original.name, "Renamed ${System.nanoTime()}")
        created.remove(original.name); created += renamed.name
        assertEquals(original.installation, renamed.installation)
        val duplicate = AppServices.library.duplicate(renamed.name).also { created += it.name }
        assertNotEquals(renamed.installation, duplicate.installation)
        assertNotNull(AppServices.library.findByInstallation(renamed.installation))
    }

    /**
     * Most bundled templates have no widget.json. The copy in the library always has one, and a
     * manifest without `network` stops every request, so the copy must declare the hosts the
     * template names, and no others.
     */
    @Test fun aCopyOfABundledTemplateThatUsesTheNetworkDeclaresItsOwnHostsOnly() {
        val bundled = AppServices.library.bundled()
        val expected = mapOf(
            "template/Daily Quote" to listOf("zenquotes.io"),
            "template/Currency Pulse" to listOf("open.er-api.com"),
            "template/Weather" to listOf("api.open-meteo.com"),
            "api/http" to listOf("api.github.com", "jsonplaceholder.typicode.com"),
        )
        for ((key, hosts) in expected) {
            val item = bundled.first { "${it.group}/${it.name}" == key }
            assertFalse("$key is expected to ship without widget.json", AppServices.library.bundledFiles(item).containsKey("widget.json"))
            val installed = AppServices.library.installBundled(item).also { created += it.name }
            val result = AppServices.runtime.run(RunRequest(installed.files, installed.installation, buildDirectory = installed.buildDirectory))
            // The request itself may fail when the device is offline; it may not be refused by the manifest.
            val message = result.execution.error?.message.orEmpty()
            assertFalse("$key: $message", message.contains("not declared in widget.json"))
            assertEquals(key, listOf("network"), installed.permissions)
            val domains = installed.manifest!!.getJSONArray("networkDomains")
            assertEquals(key, hosts, List(domains.length()) { domains.getString(it) })
        }
        // A template that names no host gets no network permission.
        val offline = AppServices.library.installBundled(bundled.first { it.group == "template" && it.name == "Month Calendar" }).also { created += it.name }
        assertEquals(emptyList<String>(), offline.permissions)
        assertEquals(0, offline.manifest!!.getJSONArray("networkDomains").length())
    }

    @Test fun everyBundledTemplateInstallsAndRendersWithoutAnInternalError() {
        val failures = ArrayList<String>()
        val bundled = AppServices.library.bundled()
        assertTrue("templates are bundled", bundled.size > 100)
        for (item in bundled) {
            val installed = try { AppServices.library.installBundled(item).also { created += it.name } } catch (error: Exception) { failures += "${item.assetPath}: install ${error.message}"; continue }
            val request = RunRequest(installed.files, installed.installation, buildDirectory = installed.buildDirectory)
            val result = AppServices.runtime.run(request)
            val kind = result.execution.error?.kind
            // A template may report that Android lacks a capability or that it needs setup; it may not crash the runtime.
            // A template waiting on a live service may reach the time limit when the network is slow or absent.
            val waitsOnNetwork = installed.permissions.contains("network")
            if (kind == "internalError" || (kind == "resourceLimit" && !waitsOnNetwork)) failures += "${item.assetPath}: [$kind] ${result.execution.error?.message?.take(160)}"
            val output = AppServices.runtime.render(request, result, 330f, 160f, 2f)
            if (output.bitmap.width < 10) failures += "${item.assetPath}: no bitmap"
            output.bitmap.recycle()
            AppServices.library.delete(installed.name); created.remove(installed.name)
        }
        assertEquals(failures.joinToString("\n"), 0, failures.size)
    }
}
