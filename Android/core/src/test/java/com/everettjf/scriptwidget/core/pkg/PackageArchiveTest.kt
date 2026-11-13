package com.everettjf.scriptwidget.core.pkg

import com.everettjf.scriptwidget.core.pkg.ZipFixtures.assertCode
import com.everettjf.scriptwidget.core.pkg.ZipFixtures.rawZip
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.file.Files
import java.text.Normalizer
import java.util.zip.ZipInputStream

class PackageArchiveTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var staging: File
    private lateinit var library: File

    @Before
    fun setUp() {
        staging = temporary.newFolder("staging")
        library = temporary.newFolder("library")
    }

    private val symlinkMode = 0xA1FFL shl 16
    private fun file(name: String, text: String = "x") = RawEntry(name, text)

    private fun assertRejected(code: String, archive: ByteArray, limits: ArchiveLimits = ArchiveLimits()) {
        assertCode(code) { PackageArchive.preflight(archive, limits) }
        val destination = File(library, "Target")
        assertCode(code) { PackageArchive.importTo(archive.inputStream(), staging, destination, limits) }
        assertFalse(destination.exists())
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
        assertEquals(emptyList<String>(), ZipFixtures.tree(library))
    }

    // Preflight: paths

    @Test
    fun rejectsTraversalPaths() {
        for (name in listOf("../escape.txt", "Widget/../../escape.txt", "Widget/../main.jsx", "..", "Widget/./main.jsx", "./main.jsx")) {
            assertRejected(PackageErrors.ARCHIVE_UNSAFE_PATH, rawZip(file("Widget/main.jsx"), file(name)))
        }
    }

    @Test
    fun rejectsAbsoluteBackslashDriveAndControlPaths() {
        val names = listOf(
            "/etc/passwd", "/Widget/main.jsx", "\\Widget\\main.jsx", "Widget\\main.jsx", "Widget/..\\..\\escape.txt", "C:/Widget/main.jsx",
            "C:main.jsx", "Widget/main.jsx:stream", "Widget/ma\u0000in.jsx", "Widget/line\nbreak.js", "Widget/" + "n".repeat(256),
        )
        for (name in names) assertRejected(PackageErrors.ARCHIVE_UNSAFE_PATH, rawZip(file("Widget/main.jsx"), file(name)))
    }

    @Test
    fun rejectsNonUtf8Names() {
        val name = byteArrayOf('W'.code.toByte(), '/'.code.toByte(), 0xC3.toByte(), 0x28)
        assertRejected(PackageErrors.ARCHIVE_UNSAFE_PATH, rawZip(RawEntry("ignored", nameBytes = name)))
    }

    @Test
    fun rejectsExcessiveNesting() {
        val deep = (1..16).joinToString("/") { "d" }
        assertEquals(listOf("$deep"), PackageArchive.preflight(rawZip(file(deep))))
        assertRejected(PackageErrors.ARCHIVE_UNSAFE_PATH, rawZip(file("$deep/main.jsx")))
    }

    @Test
    fun rejectsDuplicateAndCaseCollidingPaths() {
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx", "one"), file("widget/MAIN.jsx", "two")))
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx", "one"), file("Widget/main.jsx", "two")))
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx"), file("Widget/a.js"), file("Widget/A.js")))
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx"), file("Widget/src/a.js"), file("Widget/SRC/b.js")))
    }

    @Test
    fun rejectsUnicodeNormalizationCollisions() {
        val composed = Normalizer.normalize("Widget/café.js", Normalizer.Form.NFC)
        val decomposed = Normalizer.normalize("Widget/café.js", Normalizer.Form.NFD)
        assertFalse(composed == decomposed)
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx"), file(composed), file(decomposed)))
    }

    @Test
    fun rejectsAPathUsedAsBothFileAndDirectory() {
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx"), file("Widget/data"), file("Widget/data/a.json")))
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx"), file("Widget/data/a.json"), file("Widget/data")))
    }

    // Preflight: entry kinds

    @Test
    fun rejectsSymbolicLinkEntries() {
        assertRejected(PackageErrors.ARCHIVE_SYMLINK, rawZip(file("Widget/main.jsx"), RawEntry("Widget/link.js", "/etc/passwd".toByteArray(), symlinkMode)))
    }

    @Test
    fun rejectsSymbolicLinkDirectoryEntries() {
        // A link named like a directory, followed by a file that would be written through it.
        assertRejected(
            PackageErrors.ARCHIVE_SYMLINK,
            rawZip(file("Widget/main.jsx"), RawEntry("Widget/out/", "/tmp".toByteArray(), symlinkMode), file("Widget/out/escape.txt")),
        )
        assertRejected(PackageErrors.ARCHIVE_PATH_COLLISION, rawZip(file("Widget/main.jsx"), RawEntry("Widget/out", "/tmp".toByteArray()), file("Widget/out/escape.txt")))
    }

    @Test
    fun rejectsSpecialFilesEncryptionAndUnknownCompression() {
        assertRejected(PackageErrors.ARCHIVE_SYMLINK, rawZip(RawEntry("Widget/fifo", externalAttributes = 0x11A4L shl 16)))
        assertRejected(PackageErrors.ARCHIVE_ENCRYPTED, rawZip(RawEntry("Widget/main.jsx", "x".toByteArray(), flags = 0x0801)))
        assertRejected(PackageErrors.ARCHIVE_UNSUPPORTED_COMPRESSION, rawZip(RawEntry("Widget/main.jsx", "x".toByteArray(), method = 12)))
    }

    // Preflight: limits

    @Test
    fun rejectsTooManyEntries() {
        val entries = (0..PackageLimits.MAX_FILE_COUNT).map { file("Widget/f$it.js") }.toTypedArray()
        assertEquals(501, entries.size)
        assertRejected(PackageErrors.ARCHIVE_TOO_MANY_ENTRIES, rawZip(*entries))
        assertEquals(500, PackageArchive.preflight(rawZip(*entries.copyOfRange(0, 500))).size)
    }

    @Test
    fun rejectsOversizedEntryByDeclaredSize() {
        val limit = PackageLimits.MAX_FILE_BYTES
        assertRejected(PackageErrors.ARCHIVE_FILE_TOO_LARGE, rawZip(file("Widget/main.jsx"), RawEntry("Widget/big.bin", "x".toByteArray(), declaredSize = limit + 1)))
        PackageArchive.preflight(rawZip(file("Widget/main.jsx"), RawEntry("Widget/big.bin", "x".toByteArray(), declaredSize = limit)))
    }

    @Test
    fun rejectsOversizedTotalByDeclaredSize() {
        val each = 22L * 1024 * 1024
        val entries = (1..3).map { RawEntry("Widget/part$it.bin", "x".toByteArray(), declaredSize = each) }.toTypedArray()
        assertRejected(PackageErrors.ARCHIVE_EXPANDED_TOO_LARGE, rawZip(file("Widget/main.jsx"), *entries))
    }

    @Test
    fun rejectsOversizedEntryAndTotalWithRealData() {
        val limits = ArchiveLimits(maximumFileBytes = 1024, maximumExpandedBytes = 2048)
        assertRejected(PackageErrors.ARCHIVE_FILE_TOO_LARGE, rawZip(file("Widget/main.jsx"), RawEntry("Widget/big.bin", ByteArray(1025))), limits)
        val parts = (1..3).map { RawEntry("Widget/part$it.bin", ByteArray(1000)) }.toTypedArray()
        assertRejected(PackageErrors.ARCHIVE_EXPANDED_TOO_LARGE, rawZip(file("Widget/main.jsx"), *parts), limits)
    }

    @Test
    fun rejectsEmptyOversizedAndMalformedArchives() {
        assertRejected(PackageErrors.ARCHIVE_SIZE, ByteArray(0))
        assertRejected(PackageErrors.ARCHIVE_SIZE, ZipFixtures.packageZip(), ArchiveLimits(maximumArchiveBytes = 64))
        assertRejected(PackageErrors.ARCHIVE_MALFORMED, ByteArray(10))
        assertRejected(PackageErrors.ARCHIVE_MALFORMED, "this is not a zip archive at all, just text".toByteArray())
        assertRejected(PackageErrors.ARCHIVE_MALFORMED, ZipFixtures.packageZip() + byteArrayOf(1, 2, 3))
        val valid = ZipFixtures.packageZip()
        assertRejected(PackageErrors.ARCHIVE_MALFORMED, valid.copyOf().also { it[it.size - 22 + 16] = 0x7F })
        assertRejected(PackageErrors.ARCHIVE_MULTI_DISK, valid.copyOf().also { it[it.size - 22 + 4] = 1 })
        assertRejected(PackageErrors.ARCHIVE_INVALID_RATIO, rawZip(RawEntry("Widget/main.jsx", declaredSize = 2L * 1024 * 1024, declaredCompressedSize = 0)))
    }

    // Extraction

    @Test
    fun zipBombWithLyingSizeHeadersStopsAtTheDeclaredSize() {
        val bomb = ZipFixtures.deflatedZip(linkedMapOf("Widget/main.jsx" to "x".toByteArray(), "Widget/bomb.bin" to ByteArray(48 * 1024 * 1024)))
        assertTrue("the bomb must be small on the wire", bomb.size < 128 * 1024)
        val forged = ZipFixtures.forgeDeclaredSize(bomb, 1, 16)
        assertEquals(2, PackageArchive.preflight(forged).size)
        val destination = File(library, "Bomb")
        assertCode(PackageErrors.ARCHIVE_SIZE_MISMATCH) { PackageArchive.importTo(forged.inputStream(), staging, destination) }
        assertFalse(destination.exists())
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun inflationIsCountedAgainstTheLimitsEvenWhenHeadersAgree() {
        // Declared sizes pass a generous preflight, then the real stream is checked against tight limits.
        val archive = ZipFixtures.deflatedZip(linkedMapOf("Widget/main.jsx" to "x".toByteArray(), "Widget/a.bin" to ByteArray(4096)))
        val forged = ZipFixtures.forgeDeclaredSize(archive, 1, 100)
        assertCode(PackageErrors.ARCHIVE_SIZE_MISMATCH) { PackageArchive.extract(forged.inputStream(), staging) }
        val inflated = ZipFixtures.forgeDeclaredSize(archive, 1, 8192)
        assertCode(PackageErrors.ARCHIVE_SIZE_MISMATCH) { PackageArchive.extract(inflated.inputStream(), staging) }
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun storedEntryWithLyingSizeIsRejected() {
        val archive = rawZip(file("Widget/main.jsx"), RawEntry("Widget/data.bin", ByteArray(4096) { 7 }, declaredSize = 16))
        try {
            PackageArchive.extract(archive.inputStream(), staging).close()
            fail("Expected rejection")
        } catch (error: PackageException) {
            assertTrue(error.code, error.code in setOf(PackageErrors.ARCHIVE_SIZE_MISMATCH, PackageErrors.ARCHIVE_CORRUPT))
        }
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun corruptedContentFailsTheChecksum() {
        val archive = rawZip(file("Widget/main.jsx", "render()"))
        archive[30 + "Widget/main.jsx".length] = 'X'.code.toByte()
        assertCode(PackageErrors.ARCHIVE_CORRUPT) { PackageArchive.extract(archive.inputStream(), staging) }
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun extractsOnlyAuthoredFilesOfTheSinglePackageRoot() {
        val archive = rawZip(
            file("Widget/widget.json", "{}"), file("Widget/main.jsx", "main"), file("Widget/src/util.js", "util"), RawEntry("Widget/empty/"),
            file("Widget/__Build/main.js", "planted"), file("Widget/src/__build/x.js", "planted"), file("Widget/src/deep/__BUILD/y.js", "planted"),
            file("Widget/.DS_Store", "junk"), file("Widget/.git/config", "junk"), file("__MACOSX/Widget/._main.jsx", "junk"), file("__MACOSX/other.txt", "junk"),
            file("README.txt", "stray top-level file"),
        )
        PackageArchive.extract(archive.inputStream(), staging).use { extracted ->
            assertEquals("Widget", extracted.rootName)
            assertEquals(listOf("main.jsx", "src/", "src/util.js", "widget.json"), ZipFixtures.tree(extracted.directory))
            assertEquals("util", File(extracted.directory, "src/util.js").readText())
            assertTrue(extracted.directory.absolutePath.startsWith(staging.absolutePath))
        }
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun acceptsFilesAtTheArchiveRootAndRejectsAmbiguousRoots() {
        val flat = rawZip(file("main.jsx", "main"), file("image/a.png", "png"), file("__Build/main.js", "planted"))
        PackageArchive.extract(flat.inputStream(), staging).use { extracted ->
            assertNull(extracted.rootName)
            assertEquals(listOf("image/", "image/a.png", "main.jsx"), ZipFixtures.tree(extracted.directory))
        }
        assertRejectedOnExtract(PackageErrors.ARCHIVE_NO_PACKAGE, rawZip(file("One/main.jsx"), file("Two/main.jsx")))
        assertRejectedOnExtract(PackageErrors.ARCHIVE_NO_PACKAGE, rawZip(file("readme.txt")))
        assertRejectedOnExtract(PackageErrors.ARCHIVE_NO_PACKAGE, rawZip(file("__Build/main.jsx"), file(".hidden/main.jsx")))
        assertRejectedOnExtract(PackageErrors.ARCHIVE_NO_PACKAGE, rawZip(RawEntry("Widget/")))
    }

    private fun assertRejectedOnExtract(code: String, archive: ByteArray) {
        assertCode(code) { PackageArchive.extract(archive.inputStream(), staging) }
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun importMovesIntoPlaceAndNeverReplacesAnExistingDirectory() {
        val destination = File(library, "Installed")
        assertEquals("Widget", PackageArchive.importTo(ZipFixtures.packageZip().inputStream(), staging, destination))
        assertEquals(listOf("main.jsx", "widget.json"), ZipFixtures.tree(destination))
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
        File(destination, "main.jsx").writeText("mine")
        assertCode(PackageErrors.PACKAGE_EXISTS) { PackageArchive.importTo(ZipFixtures.packageZip().inputStream(), staging, destination) }
        assertEquals("mine", File(destination, "main.jsx").readText())
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun importsDeflatedArchives() {
        val archive = ZipFixtures.deflatedZip(linkedMapOf("Widget/main.jsx" to "a".repeat(100_000).toByteArray(), "Widget/widget.json" to "{}".toByteArray()))
        PackageArchive.extract(archive.inputStream(), staging).use { extracted ->
            assertEquals("a".repeat(100_000), File(extracted.directory, "main.jsx").readText())
        }
    }

    // Export

    private fun samplePackage(): File {
        val root = temporary.newFolder("source", "My Widget")
        File(root, "widget.json").writeText(ZipFixtures.manifest("My Widget"))
        File(root, "main.jsx").writeText("\$render(<text>阅读</text>);")
        File(root, "src").mkdirs()
        File(root, "src/b.js").writeText("b")
        File(root, "src/a.js").writeText("a")
        File(root, "image").mkdirs()
        File(root, "image/logo.png").writeBytes(ByteArray(2048) { (it * 31).toByte() })
        File(root, "__Build").mkdirs()
        File(root, "__Build/main.js").writeText("compiled")
        File(root, "src/__Build").mkdirs()
        File(root, "src/__Build/a.js").writeText("compiled")
        File(root, ".DS_Store").writeText("junk")
        File(root, ".git").mkdirs()
        File(root, ".git/config").writeText("junk")
        val secret = temporary.newFile("secret.txt").also { it.writeText("secret") }
        Files.createSymbolicLink(File(root, "link.txt").toPath(), secret.toPath())
        Files.createSymbolicLink(File(root, "linkdir").toPath(), secret.parentFile.toPath())
        return root
    }

    private fun export(root: File, name: String = root.name): ByteArray =
        ByteArrayOutputStream().also { PackageArchive.export(root, name, it) }.toByteArray()

    private fun entryNames(archive: ByteArray): List<String> {
        val names = ArrayList<String>()
        ZipInputStream(archive.inputStream()).use { zip ->
            while (true) names.add((zip.nextEntry ?: break).name)
        }
        return names
    }

    @Test
    fun exportSkipsCachesDotFilesAndLinksAndSortsEntries() {
        val archive = export(samplePackage())
        val expected = listOf("My Widget/image/logo.png", "My Widget/main.jsx", "My Widget/src/a.js", "My Widget/src/b.js", "My Widget/widget.json")
        assertEquals(expected, entryNames(archive))
        assertEquals(expected, PackageArchive.preflight(archive))
    }

    @Test
    fun exportIsDeterministic() {
        val root = samplePackage()
        val first = export(root)
        File(root, "main.jsx").setLastModified(1_000_000_000_000L)
        Thread.sleep(5)
        assertArrayEquals(first, export(root))
    }

    @Test
    fun exportThenImportRoundTripsEveryFile() {
        val root = samplePackage()
        val destination = File(library, "Copy")
        assertEquals("My Widget", PackageArchive.importTo(export(root).inputStream(), staging, destination))
        val original = DiskPackageFiles(root)
        val copy = DiskPackageFiles(destination)
        assertEquals(original.paths(), copy.paths())
        assertEquals(5, copy.paths().size)
        for (path in original.paths()) assertArrayEquals(path, original.readBytes(path), copy.readBytes(path))
        assertEquals(emptyList<String>(), ZipFixtures.tree(staging))
    }

    @Test
    fun exportAppliesLimitsAndSanitizesTheRootName() {
        val root = samplePackage()
        assertEquals("Ratio 16-9/image/logo.png", entryNames(export(root, "Ratio 16:9")).first())
        val output = ByteArrayOutputStream()
        assertCode(PackageErrors.FILE_TOO_LARGE) { PackageArchive.export(root, "W", output, limits = ArchiveLimits(maximumFileBytes = 1024)) }
        assertCode(PackageErrors.PACKAGE_TOO_LARGE) { PackageArchive.export(root, "W", output, limits = ArchiveLimits(maximumExpandedBytes = 2048)) }
        assertCode(PackageErrors.TOO_MANY_ENTRIES) { PackageArchive.export(root, "W", output, limits = ArchiveLimits(maximumFileCount = 4)) }
        assertCode(PackageErrors.ARCHIVE_SIZE) { PackageArchive.export(root, "W", output, limits = ArchiveLimits(maximumArchiveBytes = 512)) }
        assertCode(PackageErrors.ARCHIVE_NO_PACKAGE) { PackageArchive.export(temporary.newFolder("empty"), "W", output) }
        File(root, "a:b.txt").writeText("colon")
        assertCode(PackageErrors.INVALID_PATH) { PackageArchive.export(root, "W", output) }
        assertEquals("nothing may reach the output of a failed export", 0, output.size())
    }
}
