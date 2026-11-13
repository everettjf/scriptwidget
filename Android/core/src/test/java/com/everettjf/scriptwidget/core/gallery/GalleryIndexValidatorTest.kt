package com.everettjf.scriptwidget.core.gallery

import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.assertKind
import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.bytes
import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.index
import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.json
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.Instant

class GalleryIndexValidatorTest {
    private val widget = GalleryFixtures.widget().first
    private val skill = GalleryFixtures.skill().first
    private val valid = index(widget, skill)

    private fun rules(index: GalleryIndex) = GalleryIndexValidator.validate(index).map { it.id }.toSet()
    private fun rules(item: GalleryItem) = GalleryIndexValidator.validateItem(item).map { it.id.removePrefix(item.id.ifEmpty { "item" } + ".") }.toSet()
    private fun withFile(item: GalleryItem, position: Int, change: (GalleryFile) -> GalleryFile) =
        item.copy(files = item.files.mapIndexed { index, file -> if (index == position) change(file) else file })
    private fun rejectsJson(change: (JSONObject) -> Unit): GalleryException =
        assertKind(GalleryException.Kind.INVALID_INDEX) { GalleryIndexValidator.decode(bytes(json(valid).also(change))) }
    private fun firstItem(root: JSONObject) = root.getJSONArray("items").getJSONObject(0)
    private fun firstFile(root: JSONObject) = firstItem(root).getJSONArray("files").getJSONObject(0)

    // MARK: - Accepted

    @Test
    fun checkedInIndexValidatesAndMatchesTheCheckedInFiles() {
        val index = GalleryIndexValidator.decode(GalleryFixtures.checkedInIndex())
        assertTrue(index.items.size >= 2)
        assertTrue(index.items.any { it.kind == GalleryItemKind.WIDGET } && index.items.any { it.kind == GalleryItemKind.SKILL })
        for (item in index.items) for (file in item.files) {
            val local = GalleryFixtures.checkedInFile(file)
            assertEquals(file.url, file.bytes, local.size.toLong())
            assertEquals(file.url, file.sha256, GalleryInstaller.sha256(local))
        }
    }

    @Test
    fun decodesAValidIndexExactly() {
        val decoded = GalleryIndexValidator.decode(bytes(json(valid)))
        assertEquals(valid.items, decoded.items)
        assertEquals(1, decoded.schemaVersion)
        assertEquals(Instant.parse(GalleryFixtures.GENERATED_AT).toEpochMilli(), decoded.generatedAt)
        assertTrue(GalleryIndexValidator.validate(valid).isEmpty())
    }

    // MARK: - Decoding rejections

    @Test
    fun rejectsAnIndexAboveOneMebibyte() {
        val padded = bytes(json(valid)) + ByteArray(GalleryIndexValidator.MAX_INDEX_BYTES) { ' '.code.toByte() }
        assertTrue(assertKind(GalleryException.Kind.INVALID_INDEX) { GalleryIndexValidator.decode(padded) }.message!!.contains("1 MiB"))
    }

    @Test
    fun rejectsBytesThatAreNotOneUtf8JsonObject() {
        for (data in listOf(
            byteArrayOf(0xFF.toByte(), 0xFE.toByte()), "[]".toByteArray(), "".toByteArray(), "{".toByteArray(), "null".toByteArray(),
            bytes(json(valid)) + "{}".toByteArray(), bytes(json(valid)) + "x".toByteArray(),
        )) assertKind(GalleryException.Kind.INVALID_INDEX) { GalleryIndexValidator.decode(data) }
    }

    @Test
    fun rejectsUnknownFieldsAtEveryLevel() {
        rejectsJson { it.put("futureField", true) }
        rejectsJson { firstItem(it).put("permissions", JSONArray()) }
        rejectsJson { firstFile(it).put("executable", true) }
    }

    @Test
    fun rejectsMissingFields() {
        for (key in listOf("schemaVersion", "generatedAt", "repository", "items")) rejectsJson { it.remove(key) }
        for (key in listOf("id", "kind", "name", "version", "summary", "symbol", "author", "license", "tags", "minimumRuntimeVersion", "sourceURL", "featured", "files")) {
            rejectsJson { firstItem(it).remove(key) }
        }
        for (key in listOf("path", "url", "sha256", "bytes")) rejectsJson { firstFile(it).remove(key) }
    }

    @Test
    fun rejectsWronglyTypedFields() {
        rejectsJson { it.put("schemaVersion", "1") }
        rejectsJson { it.put("schemaVersion", 1.5) }
        rejectsJson { it.put("generatedAt", 1794589673) }
        rejectsJson { it.put("generatedAt", "yesterday") }
        rejectsJson { it.put("repository", JSONObject.NULL) }
        rejectsJson { it.put("items", JSONObject()) }
        rejectsJson { it.getJSONArray("items").put(0, "widget") }
        rejectsJson { firstItem(it).put("name", 7) }
        rejectsJson { firstItem(it).put("featured", "true") }
        rejectsJson { firstItem(it).put("tags", "starter") }
        rejectsJson { firstItem(it).put("tags", JSONArray(listOf(1))) }
        rejectsJson { firstItem(it).put("files", JSONObject()) }
        rejectsJson { firstItem(it).getJSONArray("files").put(0, "main.jsx") }
        rejectsJson { firstFile(it).put("bytes", "605") }
        rejectsJson { firstFile(it).put("bytes", 60.5) }
        rejectsJson { firstFile(it).put("sha256", 1) }
    }

    @Test
    fun rejectsUnknownKinds() {
        rejectsJson { firstItem(it).put("kind", "plugin") }
        rejectsJson { firstItem(it).put("kind", "Widget") }
    }

    @Test
    fun decodeReportsSemanticFailures() {
        val error = rejectsJson { firstFile(it).put("path", "../main.jsx") }
        assertTrue(error.message!!.contains("unsafe path"))
        rejectsJson { it.put("items", JSONArray()) }
        rejectsJson { it.put("schemaVersion", 2) }
    }

    // MARK: - Index rules

    @Test
    fun rejectsUnsupportedSchemaVersions() {
        assertTrue("schema" in rules(valid.copy(schemaVersion = 2)))
        assertTrue("schema" in rules(valid.copy(schemaVersion = 0)))
    }

    @Test
    fun rejectsEmptyAndOversizedCatalogs() {
        assertTrue("items" in rules(valid.copy(items = emptyList())))
        val many = List(GalleryIndexValidator.MAX_ITEMS + 1) { widget.copy(id = "com.example.item$it") }
        assertTrue("items" in rules(valid.copy(items = many)))
        assertFalse("items" in rules(valid.copy(items = many.dropLast(1))))
    }

    @Test
    fun rejectsRepositoriesThatAreNotHttpsGitHub() {
        for (url in listOf("http://github.com/a/b", "https://gitlab.com/a/b", "https://github.com.evil.example/a", "https://user@github.com/a", "https://github.com:8443/a", "github.com/a/b", "")) {
            assertTrue(url, "repository" in rules(valid.copy(repository = url)))
        }
    }

    @Test
    fun rejectsDuplicateItemIdentifiersIgnoringCase() {
        assertTrue("duplicate_item" in rules(valid.copy(items = listOf(widget, widget.copy(id = widget.id.uppercase())))))
    }

    // MARK: - Item rules

    @Test
    fun rejectsInvalidIdentifiers() {
        for (id in listOf("", "ab", "-abc", ".abc", "com.example/x", "com example", "a".repeat(129), "com.ex\u00e4mple")) {
            assertTrue(id, "id" in rules(widget.copy(id = id)))
        }
    }

    @Test
    fun rejectsInvalidDisplayFields() {
        assertTrue("name" in rules(widget.copy(name = "  ")))
        assertTrue("name" in rules(widget.copy(name = "n".repeat(81))))
        assertFalse("name" in rules(widget.copy(name = "n".repeat(80))))
        assertTrue("summary" in rules(widget.copy(summary = "")))
        assertTrue("summary" in rules(widget.copy(summary = "s".repeat(241))))
        assertTrue("symbol" in rules(widget.copy(symbol = "")))
        assertTrue("symbol" in rules(widget.copy(symbol = "s".repeat(81))))
        assertTrue("author" in rules(widget.copy(author = " ")))
        assertTrue("author" in rules(widget.copy(author = "a".repeat(121))))
        assertTrue("license" in rules(widget.copy(license = "")))
        assertTrue("license" in rules(widget.copy(license = "l".repeat(41))))
    }

    @Test
    fun rejectsVersionsThatAreNotSemantic() {
        for (version in listOf("latest", "1.0", "1", "v1.0.0", "1.0.0+build", "1.0.0-", "1.0.0 ", "")) assertTrue(version, "version" in rules(widget.copy(version = version)))
        assertFalse("version" in rules(widget.copy(version = "1.0.0-beta.1")))
    }

    @Test
    fun rejectsUnsupportedRuntimeContracts() {
        for (runtime in listOf("2.0", "1.1", "1", "")) assertTrue(runtime, "runtime" in rules(widget.copy(minimumRuntimeVersion = runtime)))
    }

    @Test
    fun rejectsTooManyOrCaseDuplicateTags() {
        assertTrue("tags" in rules(widget.copy(tags = List(21) { "tag$it" })))
        assertFalse("tags" in rules(widget.copy(tags = List(20) { "tag$it" })))
        assertTrue("tags" in rules(widget.copy(tags = listOf("Offline", "offline"))))
    }

    @Test
    fun rejectsSourceLinksThatAreNotHttpsGitHub() {
        for (url in listOf("http://github.com/a", "https://raw.githubusercontent.com/a", "https://evil.example/github.com", "https://github.com:443/a")) {
            assertTrue(url, "source" in rules(widget.copy(sourceUrl = url)))
        }
    }

    @Test
    fun rejectsInvalidFileCounts() {
        assertTrue("files" in rules(widget.copy(files = widget.files.take(1))))
        assertTrue("files" in rules(widget.copy(files = emptyList())))
        val many = widget.files + List(GalleryIndexValidator.MAX_FILES - 1) { widget.files[1].copy(path = "lib/file$it.js") }
        assertTrue("files" in rules(widget.copy(files = many)))
        assertFalse("files" in rules(widget.copy(files = many.dropLast(1))))
    }

    @Test
    fun rejectsDuplicateAndCaseCollidingPaths() {
        val extra = widget.files[1]
        assertTrue("paths" in rules(widget.copy(files = widget.files + extra)))
        assertTrue("paths" in rules(widget.copy(files = widget.files + extra.copy(path = "MAIN.jsx"))))
        // U+00E9 and "e" + U+0301 are one name after NFC normalization.
        assertTrue("paths" in rules(widget.copy(files = widget.files + extra.copy(path = "caf\u00e9.js") + extra.copy(path = "cafe\u0301.js"))))
    }

    @Test
    fun rejectsUnsafePaths() {
        val unsafe = listOf(
            "", "/main.jsx", "\\main.jsx", "../main.jsx", "lib/../../main.jsx", "./main.jsx", "lib/./a.js", "lib//a.js", "lib/", "..",
            "lib\\a.js", "C:/a.js", "a:b", "a\u0000b", "a\nb", "a/".repeat(16) + "a", "a".repeat(513),
        )
        for (path in unsafe) {
            assertFalse(path, GalleryIndexValidator.isSafeRelativePath(path))
            assertTrue(path, "path" in rules(withFile(widget, 1) { it.copy(path = path) }))
        }
        for (path in listOf("main.jsx", "lib/helpers/a.js", "a/".repeat(15) + "a", "assets/icon@2x.png", "a".repeat(512))) {
            assertTrue(path, GalleryIndexValidator.isSafeRelativePath(path))
        }
    }

    @Test
    fun rejectsFileUrlsOutsideTheTrustedHost() {
        for (url in GalleryTrustTest.untrusted) assertTrue(url, "url" in rules(withFile(widget, 0) { it.copy(url = url) }))
    }

    @Test
    fun rejectsInvalidHashes() {
        val hash = widget.files[0].sha256
        for (value in listOf(hash.uppercase(), hash.dropLast(1), hash + "0", "g".repeat(64), "", "sha256:$hash")) {
            assertTrue(value, "hash" in rules(withFile(widget, 0) { it.copy(sha256 = value) }))
        }
    }

    @Test
    fun rejectsInvalidFileSizes() {
        for (size in listOf(0L, -1L, GalleryIndexValidator.MAX_FILE_BYTES + 1, Long.MAX_VALUE)) {
            assertTrue("$size", "bytes" in rules(withFile(widget, 0) { it.copy(bytes = size) }))
        }
        assertFalse("bytes" in rules(withFile(widget, 0) { it.copy(bytes = GalleryIndexValidator.MAX_FILE_BYTES) }))
        val overflow = widget.copy(files = widget.files.map { it.copy(bytes = Long.MAX_VALUE) })
        assertTrue("total" in rules(overflow))
    }

    @Test
    fun rejectsWidgetsWithoutRequiredFilesOrAboveThirtyTwoMebibytes() {
        assertTrue("required" in rules(withFile(widget, 1) { it.copy(path = "index.jsx") }))
        assertTrue("required" in rules(withFile(widget, 0) { it.copy(path = "Widget.json") }))
        val large = widget.copy(files = widget.files.map { it.copy(bytes = 17L * 1024 * 1024) })
        assertEquals(setOf("total"), rules(large))
        assertTrue(rules(widget.copy(files = widget.files.map { it.copy(bytes = 16L * 1024 * 1024) })).isEmpty())
    }

    @Test
    fun rejectsSkillsThatAreNotExactlyTwoFilesOrAboveTheLimit() {
        assertTrue("required" in rules(skill.copy(files = skill.files + skill.files[0].copy(path = "run.sh"))))
        assertTrue("required" in rules(withFile(skill, 1) { it.copy(path = "README.md") }))
        assertTrue("required" in rules(withFile(skill, 1) { it.copy(path = "skill.md") }))
        assertTrue("required" in rules(skill.copy(kind = GalleryItemKind.WIDGET)))
        assertEquals(setOf("total"), rules(skill.copy(files = skill.files.map { it.copy(bytes = 128L * 1024 + 1) })))
        assertTrue(rules(skill.copy(files = skill.files.map { it.copy(bytes = 128L * 1024) })).isEmpty())
    }
}
