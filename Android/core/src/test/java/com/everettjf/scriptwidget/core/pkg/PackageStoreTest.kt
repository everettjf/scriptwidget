package com.everettjf.scriptwidget.core.pkg

import com.everettjf.scriptwidget.core.pkg.ZipFixtures.assertCode
import com.everettjf.scriptwidget.core.pkg.ZipFixtures.rawZip
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files

class PackageStoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var library: File
    private lateinit var staging: File
    private lateinit var store: PackageStore

    @Before
    fun setUp() {
        library = File(temporary.root, "library")
        staging = File(temporary.root, "staging")
        store = PackageStore(library, staging)
    }

    private val source = "\$render(<text>Hello</text>);"
    private fun names() = store.list().map { it.name }
    private fun stagingTree() = if (staging.exists()) ZipFixtures.tree(staging) else emptyList()
    private fun import(archive: ByteArray, suggested: String? = null) = store.importArchive(archive.inputStream(), suggested)
    private fun export(name: String) = ByteArrayOutputStream().also { store.exportArchive(name, it) }.toByteArray()

    // create / list

    @Test
    fun createWritesSourceAndDefaultManifestAtomically() {
        val created = store.create("My Widget", source)
        assertEquals("My Widget", created.name)
        assertEquals(File(library, "My Widget").absoluteFile, created.directory.absoluteFile)
        assertTrue(created.hasManifest)
        assertEquals("My Widget", created.manifestName)
        assertEquals("1.0.0", created.manifestVersion)
        assertTrue(created.manifestId!!.matches(Regex("local\\.[0-9a-f-]{36}")))
        assertEquals(source, File(created.directory, "main.jsx").readText())
        val manifest = JSONObject(File(created.directory, "widget.json").readText())
        assertEquals(2, manifest.getInt("formatVersion"))
        assertEquals("1.0", manifest.getString("runtimeVersion"))
        assertEquals("main.jsx", manifest.getString("entry"))
        assertEquals(0, manifest.getJSONArray("permissions").length())
        assertEquals(listOf("main.jsx", "widget.json"), ZipFixtures.tree(created.directory))
        assertEquals(listOf(created), store.list())
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun createHonorsASuppliedManifestAndItsEntry() {
        val manifest = ZipFixtures.manifest("Custom").replace("\"main.jsx\"", "\"src/app.jsx\"")
        val created = store.create("Custom", source, manifest)
        assertEquals("com.example.widget", created.manifestId)
        assertEquals("1.2.3", created.manifestVersion)
        assertEquals(manifest, File(created.directory, "widget.json").readText())
        assertEquals(source, File(created.directory, "src/app.jsx").readText())
    }

    @Test
    fun createFailsClosedAndLeavesNothingBehind() {
        store.create("Widget", source)
        assertCode(PackageErrors.PACKAGE_EXISTS) { store.create("Widget", "other") }
        assertCode(PackageErrors.PACKAGE_EXISTS) { store.create("WIDGET", "other") }
        for (name in listOf("", " ", "..", "../escape", "a/b", "a\\b", ".hidden", "__Build", "C:x", "a".repeat(81))) {
            assertCode(PackageErrors.INVALID_NAME) { store.create(name, source) }
        }
        assertCode(PackageErrors.INVALID_MANIFEST) { store.create("Bad", source, "{not json") }
        assertCode(PackageErrors.INVALID_MANIFEST) { store.create("Bad", source, "[]") }
        assertCode(PackageErrors.INVALID_MANIFEST) { store.create("Bad", source, "{\"name\":\"Bad\"}") }
        for (entry in listOf("../main.jsx", "/main.jsx", "a\\\\b.jsx", "main.txt", "widget.json", ".hidden.js", "__Build/main.js")) {
            assertCode(PackageErrors.INVALID_ENTRY) { store.create("Bad", source, "{\"entry\":\"$entry\"}") }
        }
        assertCode(PackageErrors.FILE_TOO_LARGE) { store.create("Big", "a".repeat(PackageLimits.MAX_SCRIPT_BYTES + 1)) }
        assertCode(PackageErrors.FILE_TOO_LARGE) { store.create("Big", source, "{\"entry\":\"main.jsx\",\"description\":\"${"d".repeat(PackageLimits.MAX_METADATA_BYTES)}\"}") }
        assertEquals("Hello", Regex("Hello").find(File(library, "Widget/main.jsx").readText())!!.value)
        assertEquals(listOf("Widget"), names())
        assertEquals(listOf("Widget/", "Widget/main.jsx", "Widget/widget.json"), ZipFixtures.tree(library))
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun listReportsOnlyRealPackageDirectories() {
        store.create("Beta", source)
        store.create("Alpha", source)
        File(library, "Legacy").mkdirs()
        File(library, "Legacy/main.jsx").writeText(source)
        File(library, "Broken").mkdirs()
        File(library, "Broken/widget.json").writeText("{not json")
        File(library, "Typed").mkdirs()
        File(library, "Typed/widget.json").writeText("{\"id\":7,\"name\":[\"x\"],\"version\":\"2.0.0\"}")
        File(library, "WrongCase").mkdirs()
        File(library, "WrongCase/Widget.JSON").writeText(ZipFixtures.manifest("WrongCase"))
        File(library, ".hidden").mkdirs()
        File(library, "__Build").mkdirs()
        File(library, "stray.txt").writeText("file")
        Files.createSymbolicLink(File(library, "Linked").toPath(), File(library, "Alpha").toPath())

        val listed = store.list().associateBy { it.name }
        assertEquals(listOf("Alpha", "Beta", "Broken", "Legacy", "Typed", "WrongCase"), store.list().map { it.name })
        assertFalse(listed.getValue("Legacy").hasManifest)
        assertNull(listed.getValue("Legacy").manifestName)
        assertTrue(listed.getValue("Broken").hasManifest)
        assertNull(listed.getValue("Broken").manifestId)
        assertNull(listed.getValue("Typed").manifestId)
        assertNull(listed.getValue("Typed").manifestName)
        assertEquals("2.0.0", listed.getValue("Typed").manifestVersion)
        assertTrue(listed.getValue("WrongCase").hasManifest)
        assertNull(listed.getValue("WrongCase").manifestName)
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.files("Linked") }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.readFile("Linked", "main.jsx") }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.delete("Linked") }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.files("ALPHA") }
    }

    @Test
    fun libraryRootMustNotBeALink() {
        val real = temporary.newFolder("real")
        val alias = File(temporary.root, "alias")
        Files.createSymbolicLink(alias.toPath(), real.toPath())
        val linked = PackageStore(alias, staging)
        assertCode(PackageErrors.STORAGE_UNAVAILABLE) { linked.list() }
        assertCode(PackageErrors.STORAGE_UNAVAILABLE) { linked.create("Widget", source) }
        assertEquals(emptyList<String>(), ZipFixtures.tree(real))
    }

    // import

    @Test
    fun importInstallsUnderTheManifestNameNotTheArchiveName() {
        val installed = import(ZipFixtures.packageZip(root = "ArchiveFolder", name = "Manifest Name", extra = mapOf("src/a.js" to "a")), "FileName")
        assertEquals("Manifest Name", installed.name)
        assertEquals("Manifest Name", installed.manifestName)
        assertEquals("com.example.widget", installed.manifestId)
        assertEquals("1.2.3", installed.manifestVersion)
        assertEquals(listOf("main.jsx", "src/a.js", "widget.json"), store.files("Manifest Name").paths())
        assertEquals(listOf("Manifest Name"), names())
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun importPicksAUniqueNameOnCollision() {
        assertEquals("Widget", import(ZipFixtures.packageZip()).name)
        assertEquals("Widget (1)", import(ZipFixtures.packageZip()).name)
        assertEquals("Widget (2)", import(ZipFixtures.packageZip()).name)
        assertEquals("WIDGET (3)", import(ZipFixtures.packageZip(name = "WIDGET")).name)
        assertEquals("Widget", JSONObject(store.readFile("Widget (1)", "widget.json").decodeToString()).getString("name"))
        assertEquals(listOf("WIDGET (3)", "Widget", "Widget (1)", "Widget (2)"), names())
    }

    @Test
    fun uniqueNameShortensTheStemAndSkipsCaseAndNormalizationAliases() {
        assertEquals("Fresh", store.uniqueName("Fresh"))
        val long = "a".repeat(80)
        store.create(long, source)
        assertEquals("a".repeat(76) + " (1)", store.uniqueName(long))
        store.create("Café", source)
        assertEquals("Café (1)", store.uniqueName("Café"))
        assertEquals("CAFÉ (1)", store.uniqueName("CAFÉ"))
        store.create("Café (1)", source)
        assertEquals("Café (2)", store.uniqueName("Café"))
        assertCode(PackageErrors.INVALID_NAME) { store.uniqueName("../x") }
    }

    @Test
    fun importMigratesLegacyPackages() {
        val meta = "{\"description\":\"Old\",\"category\":\"Tools\",\"tags\":[\"a\",\"b\"],\"featured\":true,\"icon\":5}"
        val nested = import(rawZip(RawEntry("Old Widget/main.jsx", source), RawEntry("Old Widget/meta.json", meta)), "ignored")
        assertEquals("Old Widget", nested.name)
        assertTrue(nested.hasManifest)
        assertEquals("legacy.old-widget", nested.manifestId)
        val manifest = JSONObject(store.readFile("Old Widget", "widget.json").decodeToString())
        assertEquals("Old", manifest.getString("description"))
        assertEquals("Tools", manifest.getString("category"))
        assertEquals(2, manifest.getJSONArray("tags").length())
        assertFalse(manifest.has("featured"))
        assertFalse(manifest.has("icon"))
        assertEquals("main.jsx", manifest.getString("entry"))

        assertEquals("Shared File", import(rawZip(RawEntry("main.jsx", source), RawEntry("meta.json", "{broken")), "Shared File").name)
        assertEquals("Imported Widget", import(rawZip(RawEntry("main.jsx", source)), "../bad").name)
        assertEquals("Imported Widget (1)", import(rawZip(RawEntry("main.jsx", source)), null).name)
    }

    @Test
    fun rejectedImportsLeaveNothingInLibraryOrStaging() {
        store.create("Existing", source)
        val before = ZipFixtures.tree(library)
        val link = 0xA1FFL shl 16
        val rejected = linkedMapOf(
            "traversal" to (PackageErrors.ARCHIVE_UNSAFE_PATH to rawZip(RawEntry("W/main.jsx", source), RawEntry("../Existing/main.jsx", "owned"))),
            "absolute" to (PackageErrors.ARCHIVE_UNSAFE_PATH to rawZip(RawEntry("/W/main.jsx", source))),
            "backslash" to (PackageErrors.ARCHIVE_UNSAFE_PATH to rawZip(RawEntry("W\\main.jsx", source))),
            "symlink" to (PackageErrors.ARCHIVE_SYMLINK to rawZip(RawEntry("W/main.jsx", source), RawEntry("W/link", "../Existing".toByteArray(), link))),
            "collision" to (PackageErrors.ARCHIVE_PATH_COLLISION to rawZip(RawEntry("W/main.jsx", source), RawEntry("W/MAIN.jsx", source))),
            "entries" to (PackageErrors.ARCHIVE_TOO_MANY_ENTRIES to rawZip(*(0..500).map { RawEntry("W/f$it.js", "x") }.toTypedArray())),
            "file size" to (PackageErrors.ARCHIVE_FILE_TOO_LARGE to rawZip(RawEntry("W/main.jsx", source.toByteArray(), declaredSize = PackageLimits.MAX_FILE_BYTES + 1))),
            "bomb" to (PackageErrors.ARCHIVE_SIZE_MISMATCH to ZipFixtures.forgeDeclaredSize(
                ZipFixtures.deflatedZip(linkedMapOf("W/main.jsx" to source.toByteArray(), "W/bomb.bin" to ByteArray(8 * 1024 * 1024))), 1, 8,
            )),
            "no package" to (PackageErrors.ARCHIVE_NO_PACKAGE to rawZip(RawEntry("A/main.jsx", source), RawEntry("B/main.jsx", source))),
            "wrong-case manifest" to (PackageErrors.INVALID_MANIFEST_CASE to rawZip(RawEntry("W/Widget.json", ZipFixtures.manifest("W")), RawEntry("W/main.jsx", source))),
            "malformed manifest" to (PackageErrors.INVALID_MANIFEST to rawZip(RawEntry("W/widget.json", "{bad"), RawEntry("W/main.jsx", source))),
            "non-object manifest" to (PackageErrors.INVALID_MANIFEST to rawZip(RawEntry("W/widget.json", "[1]"), RawEntry("W/main.jsx", source))),
            "non-UTF-8 manifest" to (PackageErrors.INVALID_MANIFEST to rawZip(RawEntry("W/widget.json", byteArrayOf(0x7B, 0xC3.toByte(), 0x28, 0x7D)), RawEntry("W/main.jsx", source))),
            "nameless manifest" to (PackageErrors.INVALID_MANIFEST to rawZip(RawEntry("W/widget.json", "{\"name\":5}"), RawEntry("W/main.jsx", source))),
            "unsafe manifest name" to (PackageErrors.INVALID_NAME to ZipFixtures.packageZip(name = "../Existing")),
            "reserved manifest name" to (PackageErrors.INVALID_NAME to ZipFixtures.packageZip(name = "__Build")),
            "legacy without entry" to (PackageErrors.MISSING_ENTRY to rawZip(RawEntry("W/other.jsx", source))),
            "unsafe legacy name" to (PackageErrors.INVALID_NAME to rawZip(RawEntry("${"n".repeat(81)}/main.jsx", source))),
        )
        for ((label, case) in rejected) {
            try {
                import(case.second, "Suggested")
                throw AssertionError("$label was imported")
            } catch (error: PackageException) {
                assertEquals(label, case.first, error.code)
            }
            assertEquals(label, before, ZipFixtures.tree(library))
            assertEquals(label, emptyList<String>(), stagingTree())
        }
    }

    @Test
    fun validationHookRunsBeforePublicationAndCanVeto() {
        var seen: List<String>? = null
        assertCode("unsupported_runtime") {
            store.importArchive(ZipFixtures.packageZip().inputStream(), null) { files ->
                seen = files.paths()
                assertTrue(files.readText("widget.json")!!.contains("\"runtimeVersion\""))
                throw PackageException("unsupported_runtime", "Runtime 9.0 is incompatible with 1.0.")
            }
        }
        assertEquals(listOf("main.jsx", "widget.json"), seen)
        assertEquals(emptyList<String>(), names())
        assertEquals(emptyList<String>(), ZipFixtures.tree(library))
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun importNeverInstallsBuildCachesOrHiddenFiles() {
        val archive = rawZip(
            RawEntry("W/widget.json", ZipFixtures.manifest("Clean")), RawEntry("W/main.jsx", source), RawEntry("W/__Build/main.js", "planted"),
            RawEntry("W/src/__Build/deep.js", "planted"), RawEntry("W/src/ok.js", "ok"), RawEntry("W/.env", "SECRET=1"), RawEntry("__MACOSX/W/._main.jsx", "fork"),
        )
        assertEquals("Clean", import(archive).name)
        assertEquals(listOf("main.jsx", "src/", "src/ok.js", "widget.json"), ZipFixtures.tree(File(library, "Clean")))
    }

    // export

    @Test
    fun exportThenImportRoundTripsThePackage() {
        store.create("Round Trip", source)
        store.writeFile("Round Trip", "src/lib/util.js", "export default 1;".toByteArray())
        store.writeFile("Round Trip", "image/logo.png", ByteArray(4096) { (it * 7).toByte() })
        File(library, "Round Trip/__Build").mkdirs()
        File(library, "Round Trip/__Build/main.js").writeText("compiled")
        File(library, "Round Trip/.DS_Store").writeText("junk")
        Files.createSymbolicLink(File(library, "Round Trip/link.js").toPath(), File(library, "Round Trip/main.jsx").toPath())

        val archive = export("Round Trip")
        assertArrayEquals("export must be deterministic", archive, export("Round Trip"))
        assertEquals(
            listOf("Round Trip/image/logo.png", "Round Trip/main.jsx", "Round Trip/src/lib/util.js", "Round Trip/widget.json"),
            PackageArchive.preflight(archive),
        )
        val copy = import(archive)
        assertEquals("Round Trip (1)", copy.name)
        val original = store.files("Round Trip")
        val imported = store.files(copy.name)
        assertEquals(original.paths(), imported.paths())
        for (path in original.paths()) assertArrayEquals(path, original.readBytes(path), imported.readBytes(path))
        assertEquals(store.list().first { it.name == "Round Trip" }.manifestId, copy.manifestId)
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun exportMigratesLegacyPackagesWithoutTouchingTheLibrary() {
        File(library, "Legacy").mkdirs()
        File(library, "Legacy/main.jsx").writeText(source)
        File(library, "Legacy/meta.json").writeText("{\"description\":\"Old\"}")
        val archive = export("Legacy")
        assertEquals(listOf("Legacy/main.jsx", "Legacy/meta.json", "Legacy/widget.json"), PackageArchive.preflight(archive))
        assertFalse(File(library, "Legacy/widget.json").exists())
        File(library, "Legacy").deleteRecursively()
        val imported = import(archive)
        assertEquals("Legacy", imported.name)
        assertEquals("legacy.legacy", imported.manifestId)
        assertEquals("Old", JSONObject(store.readFile("Legacy", "widget.json").decodeToString()).getString("description"))
    }

    @Test
    fun exportRefusesInvalidPackages() {
        val output = ByteArrayOutputStream()
        File(library, "Broken").mkdirs()
        File(library, "Broken/widget.json").writeText("{bad")
        File(library, "Broken/main.jsx").writeText(source)
        File(library, "Cased").mkdirs()
        File(library, "Cased/WIDGET.json").writeText(ZipFixtures.manifest("Cased"))
        File(library, "Empty").mkdirs()
        assertCode(PackageErrors.INVALID_MANIFEST) { store.exportArchive("Broken", output) }
        assertCode(PackageErrors.INVALID_MANIFEST_CASE) { store.exportArchive("Cased", output) }
        assertCode(PackageErrors.MISSING_ENTRY) { store.exportArchive("Empty", output) }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.exportArchive("Missing", output) }
        assertCode(PackageErrors.INVALID_NAME) { store.exportArchive("../Broken", output) }
        assertEquals(0, output.size())
    }

    // duplicate / rename / delete

    @Test
    fun duplicateCopiesFilesAndRefreshesIdentity() {
        val original = store.create("Widget", source)
        store.writeFile("Widget", "src/a.js", "a".toByteArray())
        File(library, "Widget/__Build").mkdirs()
        File(library, "Widget/__Build/main.js").writeText("compiled")
        File(library, "Widget/.DS_Store").writeText("junk")

        val copy = store.duplicate("Widget")
        assertEquals("Widget Remix", copy.name)
        assertEquals("Widget Remix", copy.manifestName)
        assertNotEquals(original.manifestId, copy.manifestId)
        assertTrue(copy.manifestId!!.startsWith("local."))
        assertEquals(listOf("main.jsx", "src/", "src/a.js", "widget.json"), ZipFixtures.tree(copy.directory))
        assertEquals(source, store.readFile("Widget Remix", "main.jsx").decodeToString())
        assertEquals("Widget", store.list().first { it.name == "Widget" }.manifestName)
        assertEquals("Widget Remix (1)", store.duplicate("Widget").name)
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun duplicateKeepsLegacyPackagesLegacyAndRejectsUnsafeSources() {
        File(library, "Legacy").mkdirs()
        File(library, "Legacy/main.jsx").writeText(source)
        val copy = store.duplicate("Legacy")
        assertEquals("Legacy Remix", copy.name)
        assertFalse(copy.hasManifest)
        assertEquals(listOf("main.jsx"), ZipFixtures.tree(copy.directory))

        val secret = temporary.newFile("secret.txt")
        Files.createSymbolicLink(File(library, "Legacy/link.txt").toPath(), secret.toPath())
        assertCode(PackageErrors.UNSAFE_FILE) { store.duplicate("Legacy") }
        File(library, "Broken").mkdirs()
        File(library, "Broken/widget.json").writeText("{bad")
        assertCode(PackageErrors.INVALID_MANIFEST) { store.duplicate("Broken") }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.duplicate("Missing") }
        assertEquals(listOf("Broken", "Legacy", "Legacy Remix"), names())
        assertEquals(emptyList<String>(), stagingTree())
    }

    @Test
    fun renameMovesTheDirectoryAndRefusesCollisions() {
        store.create("Widget", source)
        store.create("Other", source)
        val renamed = store.rename("Widget", "阅读记录")
        assertEquals("阅读记录", renamed.name)
        assertEquals("Widget", renamed.manifestName)
        assertEquals(listOf("Other", "阅读记录"), names())
        assertEquals("阅读记录", store.rename("阅读记录", "阅读记录").name)
        assertCode(PackageErrors.PACKAGE_EXISTS) { store.rename("阅读记录", "Other") }
        assertCode(PackageErrors.PACKAGE_EXISTS) { store.rename("阅读记录", "OTHER") }
        assertCode(PackageErrors.PACKAGE_EXISTS) { store.rename("Other", "other") }
        assertCode(PackageErrors.INVALID_NAME) { store.rename("Other", "../escape") }
        assertCode(PackageErrors.INVALID_NAME) { store.rename("Other", "__Build") }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.rename("Widget", "Again") }
        assertEquals(listOf("Other", "阅读记录"), names())
    }

    @Test
    fun deleteRemovesThePackageWithoutFollowingLinks() {
        store.create("Widget", source)
        val keep = temporary.newFolder("keep")
        File(keep, "precious.txt").writeText("keep me")
        Files.createSymbolicLink(File(library, "Widget/link").toPath(), keep.toPath())
        store.delete("Widget")
        assertEquals(emptyList<String>(), names())
        assertFalse(File(library, "Widget").exists())
        assertEquals("keep me", File(keep, "precious.txt").readText())
        assertEquals(emptyList<String>(), stagingTree())
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.delete("Widget") }
        assertCode(PackageErrors.INVALID_NAME) { store.delete("..") }
    }

    // writeFile / readFile

    @Test
    fun writeFileReplacesContentAtomically() {
        store.create("Widget", source)
        store.writeFile("Widget", "main.jsx", "new source".toByteArray())
        store.writeFile("Widget", "src/deep/util.js", "util".toByteArray())
        store.writeFile("Widget", "src/deep/util.js", "util 2".toByteArray())
        assertEquals("new source", store.readFile("Widget", "main.jsx").decodeToString())
        assertEquals("util 2", store.readFile("Widget", "src/deep/util.js").decodeToString())
        assertEquals(listOf("main.jsx", "src/", "src/deep/", "src/deep/util.js", "widget.json"), ZipFixtures.tree(File(library, "Widget")))
        assertEquals("no temporary file may remain", emptyList<String>(), File(library, "Widget").walkTopDown().filter { it.name.startsWith(".write-") }.map { it.name }.toList())
    }

    @Test
    fun writeFileRejectsUnsafePathsAndKeepsOldContent() {
        store.create("Widget", source)
        File(library, "Sibling").mkdirs()
        val before = ZipFixtures.tree(library)
        val unsafe = listOf(
            "", "/", "..", "../Sibling/main.jsx", "src/../../Sibling/x.js", "src/../main.jsx", "./main.jsx", "/main.jsx",
            File(library, "Sibling/x.js").absolutePath, "src\\x.js", "..\\Sibling\\x.js", "main\u0000.jsx", "C:x.js", ".hidden", "src/.hidden/x.js",
            "__Build/main.js", "src/__BUILD/main.js", (1..17).joinToString("/") { "d" }, "x".repeat(256),
        )
        for (path in unsafe) assertCode(PackageErrors.INVALID_PATH) { store.writeFile("Widget", path, "owned".toByteArray()) }
        assertCode(PackageErrors.INVALID_MANIFEST_CASE) { store.writeFile("Widget", "Widget.json", "{}".toByteArray()) }
        assertCode(PackageErrors.UNSAFE_FILE) { store.writeFile("Widget", "MAIN.jsx", "owned".toByteArray()) }
        assertCode(PackageErrors.UNSAFE_FILE) { store.writeFile("Widget", "main.jsx/child.js", "owned".toByteArray()) }
        assertCode(PackageErrors.FILE_TOO_LARGE) { store.writeFile("Widget", "big.bin", ByteArray(PackageLimits.MAX_FILE_BYTES.toInt() + 1)) }
        assertCode(PackageErrors.FILE_TOO_LARGE) { store.writeFile("Widget", "widget.json", ByteArray(PackageLimits.MAX_METADATA_BYTES + 1)) }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.writeFile("Missing", "main.jsx", "x".toByteArray()) }
        assertCode(PackageErrors.INVALID_NAME) { store.writeFile("../Sibling", "main.jsx", "x".toByteArray()) }
        assertEquals(before, ZipFixtures.tree(library))
        assertEquals(source, store.readFile("Widget", "main.jsx").decodeToString())
    }

    @Test
    fun writeFileNeverWritesThroughLinks() {
        store.create("Widget", source)
        val outside = temporary.newFolder("outside")
        val victim = File(outside, "victim.txt").also { it.writeText("original") }
        Files.createSymbolicLink(File(library, "Widget/link.txt").toPath(), victim.toPath())
        Files.createSymbolicLink(File(library, "Widget/linkdir").toPath(), outside.toPath())
        Files.createSymbolicLink(File(library, "Widget/dangling.txt").toPath(), File(outside, "created.txt").toPath())
        Files.createLink(File(library, "Widget/hard.txt").toPath(), victim.toPath())

        for (path in listOf("link.txt", "linkdir/victim.txt", "linkdir/new.txt", "linkdir/sub/new.txt", "dangling.txt", "hard.txt")) {
            assertCode(PackageErrors.UNSAFE_FILE) { store.writeFile("Widget", path, "owned".toByteArray()) }
        }
        assertEquals("original", victim.readText())
        assertEquals(listOf("victim.txt"), ZipFixtures.tree(outside))
        for (path in listOf("link.txt", "linkdir/victim.txt", "dangling.txt", "hard.txt")) {
            assertCode(PackageErrors.FILE_NOT_FOUND) { store.readFile("Widget", path) }
        }
    }

    @Test
    fun writeFileEnforcesTheEntryLimit() {
        store.create("Widget", source)
        repeat(PackageLimits.MAX_FILE_COUNT - 2) { File(library, "Widget/f$it.txt").writeText("x") }
        assertCode(PackageErrors.TOO_MANY_ENTRIES) { store.writeFile("Widget", "one-more.txt", "x".toByteArray()) }
        store.writeFile("Widget", "f0.txt", "replaced".toByteArray())
        assertEquals("replaced", store.readFile("Widget", "f0.txt").decodeToString())
    }

    @Test
    fun readFileReportsMissingAndUnsafePaths() {
        store.create("Widget", source)
        assertEquals(source, store.readFile("Widget", "main.jsx").decodeToString())
        assertCode(PackageErrors.FILE_NOT_FOUND) { store.readFile("Widget", "missing.js") }
        assertCode(PackageErrors.FILE_NOT_FOUND) { store.readFile("Widget", "MAIN.JSX") }
        assertCode(PackageErrors.INVALID_PATH) { store.readFile("Widget", "../Widget/main.jsx") }
        assertCode(PackageErrors.INVALID_PATH) { store.readFile("Widget", "/etc/hosts") }
        assertCode(PackageErrors.INVALID_PATH) { store.readFile("Widget", "a\\b") }
        assertCode(PackageErrors.PACKAGE_NOT_FOUND) { store.readFile("Missing", "main.jsx") }
    }
}
