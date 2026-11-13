package com.everettjf.scriptwidget.core.plugin

import com.everettjf.scriptwidget.core.pkg.RawEntry
import com.everettjf.scriptwidget.core.pkg.ZipFixtures
import com.everettjf.scriptwidget.core.plugin.PluginFixtures.failure
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files

class PluginStoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var root: File
    private lateinit var store: PluginStore
    private val manifest = PluginFixtures.json()
    private val builtInCount = PluginStore.BUILT_INS.size

    @Before
    fun setUp() {
        root = File(temporary.root, "Plugins")
        store = PluginStore(root)
    }

    private fun install(bytes: ByteArray): PluginManifest = store.install(bytes.inputStream())

    /** Installed plugin directories; the hidden staging directory must be empty. */
    private fun installedDirectories(): List<String> {
        val staging = File(root, ".staging")
        assertEquals("staging must be clean", emptyList<String>(), staging.list()?.toList() ?: emptyList<String>())
        return (root.list() ?: emptyArray()).filter { it != ".staging" }.sorted()
    }

    private fun assertImportRejected(expected: String, archive: ByteArray) {
        val error = failure { install(archive) }
        assertTrue("Expected \"$expected\" in \"${error.message}\"", error.message.contains(expected))
        assertEquals(emptyList<String>(), installedDirectories())
        assertNull(store.manifest(PluginFixtures.ID))
    }

    @Test
    fun listsBuiltInsWhenNothingIsInstalled() {
        assertEquals(listOf("GitHub Public API", "Open-Meteo"), store.list().map { it.manifest.name })
        assertTrue(store.list().all { it.builtIn && it.readme!!.startsWith("# ") })
        assertNotNull(store.manifest("app.scriptwidget.datasource.open-meteo"))
        assertNull(store.manifest("dev.unknown.plugin"))
        assertFalse("listing must not create the directory", root.exists())
    }

    @Test
    fun installsBarePluginJson() {
        assertEquals(PluginFixtures.ID, install(manifest).id)
        assertEquals(listOf("test-source"), installedDirectories())
        assertEquals(listOf("plugin.json"), File(root, "test-source").list()!!.toList())
        val listed = store.list().first { it.manifest.id == PluginFixtures.ID }
        assertFalse(listed.builtIn)
        assertNull(listed.readme)
        assertEquals(builtInCount + 1, store.list().size)
        assertEquals(PluginFixtures.manifest(), store.manifest(PluginFixtures.ID))
    }

    @Test
    fun installsArchiveWithFilesAtTheRoot() {
        install(ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("README.md", "# Test\n\nHello")))
        assertEquals(listOf("README.md", "plugin.json"), File(root, "test-source").list()!!.sorted())
        assertEquals("# Test\n\nHello", store.list().first { it.manifest.id == PluginFixtures.ID }.readme)
    }

    @Test
    fun installsArchiveWithOneDirectoryAndIgnoresHiddenFiles() {
        install(ZipFixtures.deflatedZip(linkedMapOf(
            "Test/" to ByteArray(0), "Test/plugin.json" to manifest, "Test/README.md" to "docs".toByteArray(),
            "Test/.DS_Store" to byteArrayOf(1), "__MACOSX/Test/._plugin.json" to byteArrayOf(2), ".hidden" to byteArrayOf(3),
        )))
        assertEquals(listOf("README.md", "plugin.json"), File(root, "test-source").list()!!.sorted())
    }

    @Test
    fun duplicateIdsAreRefused() {
        install(manifest)
        assertEquals("Plugin ${PluginFixtures.ID} is already installed.", failure { install(manifest) }.message)
        assertEquals(listOf("test-source"), installedDirectories())
        val builtIn = PluginStore.BUILT_INS[0]
        assertEquals("Plugin ${builtIn.id} is already installed.", failure { install(builtIn.toJson().toByteArray()) }.message)
    }

    @Test
    fun directoryNamesAreSlugsAndNeverCollide() {
        install(PluginFixtures.json { it.put("name", "../../Evil  Name!") })
        install(PluginFixtures.json { it.put("name", "evil name").put("id", "dev.scriptwidget.second") })
        install(PluginFixtures.json { it.put("name", "数据").put("id", "dev.scriptwidget.third") })
        assertEquals(listOf("evil-name", "evil-name-2", "plugin"), installedDirectories())
        assertEquals(listOf("Plugins"), temporary.root.list()!!.toList())
    }

    @Test
    fun invalidManifestsAreNotInstalled() {
        assertImportRejected("plugin.json contains unknown fields.", PluginFixtures.json { it.put("unexpected", true) })
        assertImportRejected("baseURL must be an HTTPS URL", ZipFixtures.rawZip(RawEntry("plugin.json", PluginFixtures.json { it.put("baseURL", "http://api.example.com") })))
        assertImportRejected("plugin.json is not valid JSON.", "not json".toByteArray())
        assertImportRejected("Archive must contain one Data Source Plugin 1.0 package.", ByteArray(0))
    }

    @Test
    fun oversizeInputIsRejected() {
        assertImportRejected("A plugin package may not exceed 512 KiB.", ByteArray(PluginStore.MAXIMUM_PACKAGE_BYTES + 1) { ' '.code.toByte() })
        assertImportRejected("A plugin package may not exceed 512 KiB.",
            ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("README.md", ByteArray(PluginStore.MAXIMUM_PACKAGE_BYTES))))
        // A highly compressible README fits the archive limit but not the expanded limit.
        assertImportRejected("README.md exceeds 512 KiB.",
            ZipFixtures.deflatedZip(linkedMapOf("plugin.json" to manifest, "README.md" to ByteArray(PluginStore.MAXIMUM_README_BYTES + 1) { 'a'.code.toByte() })))
        assertImportRejected("plugin.json exceeds 256 KiB.",
            ZipFixtures.deflatedZip(linkedMapOf("plugin.json" to ByteArray(PluginValidator.MAXIMUM_MANIFEST_BYTES + 1) { ' '.code.toByte() })))
    }

    @Test
    fun onlyPluginJsonAndReadmeAreAllowed() {
        val only = "A plugin package allows only plugin.json and optional README.md."
        assertImportRejected(only, ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("main.js", "fetch()")))
        assertImportRejected(only, ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("lib/native.so", "x")))
        assertImportRejected(only, ZipFixtures.rawZip(RawEntry("Test/plugin.json", manifest), RawEntry("Test/extra/plugin.json", manifest)))
        assertImportRejected(only, ZipFixtures.rawZip(RawEntry("Test/README.md", "no manifest")))
        assertImportRejected(only, ZipFixtures.rawZip(RawEntry("Test/Plugin.json", manifest)))
        assertImportRejected(only, ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("readme.md", "wrong case")))
        assertImportRejected("Archive must contain one Data Source Plugin 1.0 package.", ZipFixtures.rawZip(RawEntry("A/plugin.json", manifest), RawEntry("B/plugin.json", manifest)))
        assertImportRejected("Archive must contain one Data Source Plugin 1.0 package.", ZipFixtures.rawZip(RawEntry("README.md", "no package")))
        assertImportRejected("README.md must be UTF-8 text.", ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("README.md", byteArrayOf(0xFF.toByte()))))
    }

    @Test
    fun unsafeArchivesAreRejectedBeforeAnythingIsWritten() {
        val plugin = RawEntry("plugin.json", manifest)
        assertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.rawZip(plugin, RawEntry("../README.md", "x")))
        assertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.rawZip(plugin, RawEntry("/README.md", "x")))
        assertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.rawZip(plugin, RawEntry("Test\\README.md", "x")))
        assertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.rawZip(plugin, RawEntry("C:README.md", "x")))
        assertImportRejected("Symbolic links are not allowed", ZipFixtures.rawZip(plugin, RawEntry("README.md", "/etc/hosts".toByteArray(), externalAttributes = 0xA1FFL shl 16)))
        assertImportRejected("duplicate or case-colliding paths", ZipFixtures.rawZip(plugin, RawEntry("PLUGIN.JSON", manifest)))
        assertImportRejected("duplicate or case-colliding paths", ZipFixtures.rawZip(plugin, RawEntry("plugin.json", manifest)))
        assertImportRejected("Encrypted package entries", ZipFixtures.rawZip(RawEntry("plugin.json", manifest, flags = 0x0801)))
        assertImportRejected("Unsupported ZIP compression method", ZipFixtures.rawZip(RawEntry("plugin.json", manifest, method = 12)))
        assertImportRejected("no valid ZIP central directory", "PK\u0003\u0004 truncated".toByteArray())
        assertEquals("nothing may be created for a rejected archive", emptyList<String>(), temporary.root.list()!!.toList())
    }

    @Test
    fun forgedSizesAndCorruptEntriesAreRejected() {
        val archive = ZipFixtures.deflatedZip(linkedMapOf("plugin.json" to manifest))
        assertImportRejected("The plugin archive is corrupt.", ZipFixtures.forgeDeclaredSize(archive, 0, manifest.size - 1))
        assertImportRejected("The plugin archive is corrupt.", ZipFixtures.forgeDeclaredSize(archive, 0, manifest.size + 1))
        val stored = ZipFixtures.rawZip(RawEntry("plugin.json", manifest))
        stored[40 + "plugin.json".length] = (stored[40 + "plugin.json".length] + 1).toByte()
        assertImportRejected("The plugin archive is corrupt.", stored)
    }

    @Test
    fun exportRoundTripsThroughImport() {
        install(ZipFixtures.rawZip(RawEntry("plugin.json", manifest), RawEntry("README.md", "# Docs")))
        val exported = ByteArrayOutputStream().also { store.export(PluginFixtures.ID, it) }.toByteArray()
        val second = PluginStore(File(temporary.root, "Other"))
        assertEquals(PluginFixtures.ID, second.install(exported.inputStream()).id)
        assertEquals("# Docs", second.list().first { it.manifest.id == PluginFixtures.ID }.readme)
        assertEquals(PluginFixtures.manifest(), second.manifest(PluginFixtures.ID))
        // The same plugin always yields the same bytes.
        assertTrue(exported.contentEquals(ByteArrayOutputStream().also { store.export(PluginFixtures.ID, it) }.toByteArray()))
    }

    @Test
    fun exportIncludesOnlyThePluginFiles() {
        install(manifest)
        File(root, "test-source/secret.txt").writeText("not part of the plugin")
        val exported = ByteArrayOutputStream().also { store.export(PluginFixtures.ID, it) }.toByteArray()
        val names = java.util.zip.ZipInputStream(exported.inputStream()).use { zip -> generateSequence { zip.nextEntry }.map { it.name }.toList() }
        assertEquals(listOf("plugin.json"), names)
    }

    @Test
    fun builtInsExportButCannotBeDeleted() {
        val id = PluginStore.BUILT_INS[1].id
        val exported = ByteArrayOutputStream().also { store.export(id, it) }.toByteArray()
        // A built-in id is already present, so the export is checked by decoding it.
        val entries = HashMap<String, ByteArray>()
        java.util.zip.ZipInputStream(exported.inputStream()).use { zip -> generateSequence { zip.nextEntry }.forEach { entries[it.name] = zip.readBytes() } }
        assertEquals(setOf("plugin.json", "README.md"), entries.keys)
        assertEquals(PluginStore.BUILT_INS[1], PluginValidator.decode(entries["plugin.json"]!!))
        assertEquals("Built-in plugins cannot be deleted.", failure { store.delete(id) }.message)
        assertEquals("Plugin not found.", failure { store.delete("dev.unknown.plugin") }.message)
        assertEquals("Plugin not found.", failure { store.export("dev.unknown.plugin", ByteArrayOutputStream()) }.message)
    }

    @Test
    fun deleteRemovesThePlugin() {
        install(manifest)
        store.delete(PluginFixtures.ID)
        assertEquals(emptyList<String>(), installedDirectories())
        assertNull(store.manifest(PluginFixtures.ID))
        assertEquals(builtInCount, store.list().size)
        install(manifest)
        assertEquals(listOf("test-source"), installedDirectories())
    }

    @Test
    fun tamperedOrLinkedDirectoriesAreNotLoaded() {
        install(manifest)
        val file = File(root, "test-source/plugin.json")
        file.writeBytes(PluginFixtures.json { it.put("baseURL", "http://api.example.com") })
        assertNull("a stored manifest is validated on every read", store.manifest(PluginFixtures.ID))
        file.writeBytes(manifest)
        assertNotNull(store.manifest(PluginFixtures.ID))

        // A symbolic link in the store is neither a plugin directory nor a plugin file.
        val outside = File(temporary.root, "outside").apply { mkdirs() }
        File(outside, "plugin.json").writeBytes(PluginFixtures.json { it.put("id", "dev.scriptwidget.linked") })
        Files.createSymbolicLink(File(root, "linked").toPath(), outside.toPath())
        assertNull(store.manifest("dev.scriptwidget.linked"))
        File(root, "real").mkdirs()
        Files.createSymbolicLink(File(root, "real/plugin.json").toPath(), File(outside, "plugin.json").toPath())
        assertNull(store.manifest("dev.scriptwidget.linked"))
    }

    @Test
    fun listIsSortedByNameAcrossBuiltInAndInstalledPlugins() {
        install(PluginFixtures.json { it.put("name", "Alpha") })
        assertEquals(listOf("Alpha", "GitHub Public API", "Open-Meteo"), store.list().map { it.manifest.name })
    }
}
