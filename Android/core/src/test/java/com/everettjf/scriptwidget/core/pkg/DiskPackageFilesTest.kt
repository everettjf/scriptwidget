package com.everettjf.scriptwidget.core.pkg

import com.everettjf.scriptwidget.core.pkg.ZipFixtures.assertCode
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.nio.file.Files

class DiskPackageFilesTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var root: File
    private lateinit var outside: File
    private lateinit var files: DiskPackageFiles

    @Before
    fun setUp() {
        root = temporary.newFolder("library", "Widget")
        outside = temporary.newFolder("outside")
        File(outside, "secret.txt").writeText("secret")
        File(outside, "secret.js").writeText("secret()")
        write("main.jsx", "\$render(<text/>);")
        write("widget.json", "{}")
        write("src/util/helper.js", "export const a = 1;")
        write("image/logo.png", "PNG")
        files = DiskPackageFiles(root)
    }

    private fun write(path: String, text: String) = write(path, text.toByteArray())

    private fun write(path: String, bytes: ByteArray) {
        val file = File(root, path)
        file.parentFile.mkdirs()
        file.writeBytes(bytes)
    }

    private fun link(path: String, target: File) {
        val link = File(root, path)
        link.parentFile.mkdirs()
        Files.createSymbolicLink(link.toPath(), target.toPath())
    }

    @Test
    fun listsRegularFilesAsSortedNormalizedPaths() {
        assertEquals(listOf("image/logo.png", "main.jsx", "src/util/helper.js", "widget.json"), files.paths())
    }

    @Test
    fun listingSkipsDotFilesBuildCacheAndLinks() {
        write(".DS_Store", "x")
        write(".git/config", "x")
        write("src/.cache/tmp.js", "x")
        write("__Build/main.js", "compiled")
        write("src/__build/main.js", "compiled")
        link("linked.js", File(outside, "secret.js"))
        link("linkedDir", outside)
        link("dangling.js", File(outside, "missing.js"))
        assertEquals(listOf("image/logo.png", "main.jsx", "src/util/helper.js", "widget.json"), files.paths())
    }

    @Test
    fun readsExistingFiles() {
        assertTrue(files.exists("main.jsx"))
        assertTrue(files.exists("src/util/helper.js"))
        assertEquals("export const a = 1;", files.readText("src/util/helper.js"))
        assertArrayEquals("PNG".toByteArray(), files.readBytes("image/logo.png"))
        assertArrayEquals("{}".toByteArray(), files.readBytes("widget.json"))
    }

    @Test
    fun rejectsPathsThatAreNotNormalizedPackageRelativePaths() {
        File(root.parentFile, "sibling.js").writeText("sibling")
        val unsafe = listOf(
            "", "/", ".", "..", "../sibling.js", "../Widget/main.jsx", "src/../main.jsx", "src/../../sibling.js", "./main.jsx", "src//util/helper.js",
            "main.jsx/", "/main.jsx", File(root, "main.jsx").absolutePath, File(outside, "secret.js").absolutePath, "src\\util\\helper.js",
            "..\\sibling.js", "main.jsx\u0000", "main\u0000.jsx", "C:main.jsx", "src/util/helper.js\n",
            (1..17).joinToString("/") { "d" } + ".js", "x".repeat(256) + ".js",
        )
        for (path in unsafe) {
            assertFalse(path, files.exists(path))
            assertNull(path, files.readText(path))
            assertNull(path, files.readBytes(path))
        }
    }

    @Test
    fun existsIsTrueOnlyForRegularFiles() {
        assertFalse(files.exists("src"))
        assertFalse(files.exists("src/util"))
        assertFalse(files.exists("missing.js"))
        assertFalse(files.exists("main.jsx/child.js"))
        assertNull(files.readBytes("src"))
    }

    @Test
    fun rejectsSymbolicLinksAtEveryComponent() {
        link("linked.js", File(outside, "secret.js"))
        link("linkedDir", outside)
        link("src/deep/link", outside)
        link("inside.js", File(root, "main.jsx"))
        link("dangling.js", File(outside, "missing.js"))
        for (path in listOf("linked.js", "linkedDir/secret.js", "linkedDir/secret.txt", "src/deep/link/secret.js", "inside.js", "dangling.js", "linkedDir")) {
            assertFalse(path, files.exists(path))
            assertNull(path, files.readText(path))
            assertNull(path, files.readBytes(path))
        }
    }

    @Test
    fun rejectsAPackageRootThatIsItselfALink() {
        val alias = File(temporary.root, "alias")
        Files.createSymbolicLink(alias.toPath(), root.toPath())
        val linked = DiskPackageFiles(alias)
        assertEquals(emptyList<String>(), linked.paths())
        assertFalse(linked.exists("main.jsx"))
        assertNull(linked.readText("main.jsx"))
        assertEquals(emptyList<String>(), DiskPackageFiles(File(temporary.root, "missing")).paths())
    }

    @Test
    fun rejectsHardLinkedFiles() {
        Files.createLink(File(root, "hard.js").toPath(), File(outside, "secret.js").toPath())
        assertFalse(files.exists("hard.js"))
        assertNull(files.readText("hard.js"))
        assertFalse(files.paths().contains("hard.js"))
    }

    @Test
    fun rejectsCaseAliasesAndHiddenOrCachePaths() {
        write(".env", "TOKEN=1")
        write("__Build/main.js", "compiled")
        for (path in listOf("MAIN.jsx", "Main.JSX", "SRC/util/helper.js", "Widget.json", ".env", "__Build/main.js", "__build/main.js")) {
            assertFalse(path, files.exists(path))
            assertNull(path, files.readBytes(path))
        }
    }

    @Test
    fun readTextReturnsOnlyBoundedUtf8TextFiles() {
        write("data.bin", "text in a binary file")
        write("bad.txt", byteArrayOf(0x66, 0xC3.toByte(), 0x28))
        write("big.jsx", ByteArray(PackageLimits.MAX_SCRIPT_BYTES + 1) { 'a'.code.toByte() })
        write("edge.jsx", ByteArray(PackageLimits.MAX_SCRIPT_BYTES) { 'a'.code.toByte() })
        write("notes.txt", ByteArray(PackageLimits.MAX_SCRIPT_BYTES + 1) { 'a'.code.toByte() })
        write("huge.txt", ByteArray(PackageLimits.MAX_TEXT_BYTES + 1) { 'a'.code.toByte() })
        write("unicode.md", "阅读 👩‍💻")
        assertNull(files.readText("image/logo.png"))
        assertNull(files.readText("data.bin"))
        assertNull(files.readText("bad.txt"))
        assertNull(files.readText("big.jsx"))
        assertEquals(PackageLimits.MAX_SCRIPT_BYTES, files.readText("edge.jsx")!!.length)
        assertEquals(PackageLimits.MAX_SCRIPT_BYTES + 1, files.readText("notes.txt")!!.length)
        assertNull(files.readText("huge.txt"))
        assertEquals("阅读 👩‍💻", files.readText("unicode.md"))
        assertEquals(PackageLimits.MAX_TEXT_BYTES + 1, files.readBytes("huge.txt")!!.size)
    }

    @Test
    fun readBytesIsCappedAtSixteenMebibytes() {
        write("edge.bin", ByteArray(PackageLimits.MAX_BINARY_READ_BYTES))
        write("big.bin", ByteArray(PackageLimits.MAX_BINARY_READ_BYTES + 1))
        assertEquals(PackageLimits.MAX_BINARY_READ_BYTES, files.readBytes("edge.bin")!!.size)
        assertNull(files.readBytes("big.bin"))
        assertTrue(files.exists("big.bin"))
    }

    @Test
    fun listingFailsClosedBeyondTheEntryLimit() {
        repeat(PackageLimits.MAX_FILE_COUNT) { write("many/f$it.txt", "x") }
        assertCode(PackageErrors.TOO_MANY_ENTRIES) { files.paths() }
    }

    @Test
    fun listingStopsAtTheDepthLimit() {
        write((1..15).joinToString("/") { "d" } + "/ok.js", "x")
        write((1..16).joinToString("/") { "e" } + "/deep.js", "x")
        val listed = files.paths()
        assertTrue(listed.any { it.endsWith("/ok.js") })
        assertFalse(listed.any { it.endsWith("/deep.js") })
    }
}
