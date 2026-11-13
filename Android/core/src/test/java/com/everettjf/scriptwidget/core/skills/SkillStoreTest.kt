package com.everettjf.scriptwidget.core.skills

import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.skillManifest
import com.everettjf.scriptwidget.core.gallery.GalleryFixtures.tree
import com.everettjf.scriptwidget.core.pkg.RawEntry
import com.everettjf.scriptwidget.core.pkg.ZipFixtures
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
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
import java.util.zip.ZipInputStream

class SkillStoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private lateinit var root: File
    private lateinit var store: SkillStore

    private val id = "com.example.weather"
    private val manifest = skillManifest(id, "Weather Expert", "1.0.0")
    private val instruction = "Prefer concise forecasts.\nMention the data source."

    @Before
    fun setUp() {
        root = File(temporary.root, "Skills")
        store = SkillStore(root)
    }

    private fun custom() = store.list().filter { !it.isBuiltIn }.map { it.id }
    private fun install(manifest: String = this.manifest, instruction: String = this.instruction, replace: Boolean = false) =
        store.install(manifest.toByteArray(), instruction.toByteArray(), replace)
    private fun export(skillId: String = id) = ByteArrayOutputStream().also { store.exportArchive(skillId, it) }.toByteArray()
    private fun import(archive: ByteArray, into: SkillStore = store) = into.importArchive(archive.inputStream())
    private fun parsed() = SkillValidator.parseManifest(manifest.toByteArray())

    private fun assertCode(code: String, block: () -> Unit): SkillException {
        try {
            block()
        } catch (error: SkillException) {
            assertEquals(error.message, code, error.code)
            return error
        }
        fail("Expected SkillException($code)")
        throw AssertionError()
    }

    /** The import was refused and left neither a Skill nor staging files. */
    private fun assertImportRefused(code: String, archive: ByteArray) {
        assertCode(code) { import(archive) }
        assertTrue(custom().isEmpty())
        assertTrue(tree(root).toString(), tree(root).isEmpty())
    }

    // MARK: - Validation

    @Test
    fun validatorAcceptsAValidSkillAndReportsEachInvalidField() {
        assertTrue(SkillValidator.validate(parsed(), instruction).isEmpty())
        fun rules(manifest: SkillManifest, text: String = instruction) = SkillValidator.validate(manifest, text).map { it.id }.toSet()

        assertEquals(setOf("invalid_version", "invalid_prompt_file", "empty_instruction"), rules(parsed().copy(version = "latest", promptFile = "prompt.txt"), "  "))
        assertEquals(setOf("unsupported_format"), rules(parsed().copy(formatVersion = 2)))
        for (bad in listOf("ab", "-abc", "com.example/x", "a".repeat(129), "")) assertEquals(bad, setOf("invalid_id"), rules(parsed().copy(id = bad)))
        assertEquals(setOf("invalid_name"), rules(parsed().copy(name = " ")))
        assertEquals(setOf("invalid_name"), rules(parsed().copy(name = "n".repeat(81))))
        assertEquals(setOf("unsupported_runtime"), rules(parsed().copy(minimumRuntimeVersion = "2.0")))
        for (file in listOf("../SKILL.md", "skill.md", "run.sh", "")) assertEquals(setOf("invalid_prompt_file"), rules(parsed().copy(promptFile = file)))
        assertEquals(setOf("invalid_summary"), rules(parsed().copy(summary = "")))
        assertEquals(setOf("invalid_summary"), rules(parsed().copy(summary = "s".repeat(241))))
        assertEquals(setOf("invalid_symbol"), rules(parsed().copy(symbol = "")))
        assertEquals(setOf("invalid_symbol"), rules(parsed().copy(symbol = "s".repeat(81))))
        assertEquals(setOf("invalid_tags"), rules(parsed().copy(tags = List(21) { "t$it" })))
        assertEquals(setOf("invalid_tags"), rules(parsed().copy(tags = listOf("Layout", "layout"))))
        assertEquals(setOf("instruction_too_large"), rules(parsed(), "x".repeat(SkillValidator.MAX_INSTRUCTION_BYTES + 1)))
        assertTrue(rules(parsed(), "x".repeat(SkillValidator.MAX_INSTRUCTION_BYTES)).isEmpty())
    }

    @Test
    fun manifestWithUnknownKeysFailsClosed() {
        for (extra in listOf("\"executable\":\"payload.sh\"", "\"permissions\":[\"network\"]", "\"tools\":[]", "\"networkDomains\":[\"example.com\"]", "\"Id\":\"x\"")) {
            val error = assertCode(SkillErrors.UNKNOWN_FIELD) { SkillValidator.parseManifest(skillManifest(id, "Weather Expert", "1.0.0", ",$extra").toByteArray()) }
            assertTrue(error.message!!.contains(extra.substringAfter('"').substringBefore('"')))
        }
    }

    @Test
    fun manifestThatIsNotOneJsonObjectIsRejected() {
        for (bytes in listOf(
            "".toByteArray(), "not json".toByteArray(), "[]".toByteArray(), "null".toByteArray(), "{\"id\":".toByteArray(),
            (manifest + "{}").toByteArray(), (manifest + " trailing").toByteArray(), byteArrayOf(0xC3.toByte(), 0x28),
        )) assertCode(SkillErrors.INVALID_MANIFEST) { SkillValidator.parseManifest(bytes) }
    }

    @Test
    fun manifestWithMissingOrWronglyTypedFieldsIsRejected() {
        for (key in listOf("formatVersion", "id", "name", "version", "summary", "symbol", "promptFile", "tags", "minimumRuntimeVersion")) {
            val json = JSONObject(manifest).apply { remove(key) }
            assertCode(SkillErrors.INVALID_MANIFEST) { SkillValidator.parseManifest(json.toString().toByteArray()) }
        }
        val wrong = mapOf<String, Any>(
            "formatVersion" to "1", "id" to 7, "name" to JSONObject.NULL, "version" to 1.0, "tags" to "layout",
            "author" to 7, "promptFile" to listOf("SKILL.md"), "minimumRuntimeVersion" to 1.0,
        )
        for ((key, value) in wrong) {
            val json = JSONObject(manifest).put(key, if (value is List<*>) org.json.JSONArray(value) else value)
            assertCode(SkillErrors.INVALID_MANIFEST) { SkillValidator.parseManifest(json.toString().toByteArray()) }
        }
        assertCode(SkillErrors.INVALID_MANIFEST) { SkillValidator.parseManifest(JSONObject(manifest).put("formatVersion", 1.5).toString().toByteArray()) }
        assertCode(SkillErrors.INVALID_MANIFEST) { SkillValidator.parseManifest(JSONObject(manifest).put("tags", org.json.JSONArray(listOf("a", 1))).toString().toByteArray()) }
        assertEquals("Ada", SkillValidator.parseManifest(JSONObject(manifest).put("author", "Ada").toString().toByteArray()).author)
    }

    @Test
    fun oversizedOrNonTextFilesAreRejected() {
        val padded = manifest.dropLast(1) + ",\"author\":\"" + "a".repeat(SkillValidator.MAX_MANIFEST_BYTES) + "\"}"
        assertCode(SkillErrors.TOO_LARGE) { SkillValidator.parseManifest(padded.toByteArray()) }
        assertCode(SkillErrors.TOO_LARGE) { SkillValidator.load(manifest.toByteArray(), ByteArray(SkillValidator.MAX_INSTRUCTION_BYTES + 1) { 'x'.code.toByte() }) }
        assertCode(SkillErrors.INVALID_INSTRUCTION) { SkillValidator.load(manifest.toByteArray(), byteArrayOf('a'.code.toByte(), 0xFF.toByte())) }
        assertCode(SkillErrors.INVALID_SKILL) { SkillValidator.load(manifest.toByteArray(), " \n\t".toByteArray()) }
        assertCode(SkillErrors.TOO_LARGE) { install(instruction = "x".repeat(SkillValidator.MAX_INSTRUCTION_BYTES + 1)) }
        assertTrue(tree(root).isEmpty())
    }

    // MARK: - Store

    @Test
    fun installListFindDeleteLifecycle() {
        assertEquals(BuiltInSkills.all, store.list())
        val skill = install()
        assertEquals(id, skill.id)
        assertEquals("Weather Expert", skill.title)
        assertEquals(instruction, skill.instruction)
        assertFalse(skill.isBuiltIn)
        assertEquals(BuiltInSkills.all + skill, store.list())
        assertEquals(skill, store.find(id))
        assertTrue(store.isInstalled(id))
        assertEquals(listOf("weather-expert/", "weather-expert/SKILL.md", "weather-expert/skill.json"), tree(root))
        assertEquals(manifest, File(root, "weather-expert/skill.json").readText())

        // A second store on the same directory sees the same Skill.
        assertEquals(skill, SkillStore(root).find(id))

        store.delete(id)
        assertNull(store.find(id))
        assertFalse(store.isInstalled(id))
        assertFalse(File(root, "weather-expert").exists())
        assertCode(SkillErrors.NOT_FOUND) { store.delete(id) }
    }

    @Test
    fun duplicateIdentifiersAreRejectedUnlessReplacementIsExplicit() {
        install()
        assertCode(SkillErrors.DUPLICATE) { install(instruction = "Something else.") }
        assertEquals(instruction, store.find(id)!!.instruction)

        val replaced = install(skillManifest(id, "Weather Expert", "1.1.0"), "Updated guidance.", replace = true)
        assertEquals("1.1.0", replaced.version)
        assertEquals("Updated guidance.", store.find(id)!!.instruction)
        assertEquals(listOf(id), custom())
        assertEquals(listOf("weather-expert/", "weather-expert/SKILL.md", "weather-expert/skill.json"), tree(root))

        // A different Skill with the same display name gets its own directory.
        install(skillManifest("com.example.weather2", "Weather Expert", "1.0.0"))
        assertTrue(File(root, "weather-expert-2/skill.json").isFile)
    }

    @Test
    fun builtInSkillsAreReadOnly() {
        val builtIn = BuiltInSkills.all.first()
        assertEquals(5, BuiltInSkills.all.size)
        assertTrue(BuiltInSkills.all.all { it.isBuiltIn && SkillValidator.slug(it.title).isNotEmpty() })
        assertCode(SkillErrors.BUILT_IN) { store.delete(builtIn.id) }
        assertCode(SkillErrors.DUPLICATE) { install(skillManifest(builtIn.id, "Shadow", "1.0.0")) }
        assertEquals(builtIn, store.find(builtIn.id))
    }

    @Test
    fun enabledStateIsOffByDefaultPersistsAndIsDroppedOnDelete() {
        install()
        assertTrue(store.enabledIds().isEmpty())
        assertEquals("", store.enabledSkillsPromptText())
        assertEquals("hello", store.augment("hello"))

        store.setEnabled(id, true)
        store.setEnabled("accessible-design", true)
        assertTrue(store.isEnabled(id))
        assertEquals(setOf(id, "accessible-design"), SkillStore(root).enabledIds())
        assertCode(SkillErrors.NOT_FOUND) { store.setEnabled("com.example.missing", true) }

        store.setEnabled("accessible-design", false)
        assertEquals(setOf(id), store.enabledIds())
        store.delete(id)
        assertTrue(store.enabledIds().isEmpty())
        assertEquals("", store.enabledSkillsPromptText())
    }

    @Test
    fun promptTextIsDeterministicAndContainsOnlyEnabledSkills() {
        install()
        install(skillManifest("com.example.alpha", "Alpha Guide", "2.1.0"), "Be brief.")
        for (skill in listOf(id, "com.example.alpha", "responsive-layout")) store.setEnabled(skill, true)
        val responsive = BuiltInSkills.all.first { it.id == "responsive-layout" }
        val expected = "Apply these ScriptWidget skills:\n" +
            "- Responsive Layout v1.0.0:\n  ${responsive.instruction}\n" +
            "- Alpha Guide v2.1.0:\n  Be brief.\n" +
            "- Weather Expert v1.0.0:\n  Prefer concise forecasts.\n  Mention the data source."
        assertEquals(expected, store.enabledSkillsPromptText())
        assertEquals(expected, SkillStore(root).enabledSkillsPromptText())
        assertEquals("Make a clock\n\n$expected", store.augment("Make a clock"))
    }

    @Test
    fun aCorruptEnabledFileEnablesNothing() {
        install()
        store.setEnabled(id, true)
        for (content in listOf("not json", "{}", "[1]", "[\"$id\", null]")) {
            File(root, ".enabled.json").writeText(content)
            assertTrue(content, store.enabledIds().isEmpty())
            assertEquals("", store.enabledSkillsPromptText())
        }
    }

    // MARK: - Tampered directories

    @Test
    fun aDirectoryThatIsNotExactlyTheTwoFilesIsNotASkill() {
        install()
        val directory = File(root, "weather-expert")
        store.setEnabled(id, true)

        val extra = File(directory, "run.sh").apply { writeText("#!/bin/sh") }
        assertNull("extra file", store.find(id))
        assertEquals("", store.enabledSkillsPromptText())
        extra.delete()
        assertNotNull(store.find(id))

        val nested = File(directory, "assets").apply { mkdir() }
        assertNull("extra directory", store.find(id))
        nested.delete()

        val instructionFile = File(directory, "SKILL.md")
        val saved = instructionFile.readBytes()
        instructionFile.delete()
        assertNull("missing file", store.find(id))
        File(directory, "skill.md").writeBytes(saved)
        assertNull("wrong case", store.find(id))
        File(directory, "skill.md").delete()
        instructionFile.writeBytes(saved)
        assertNotNull(store.find(id))

        // Hidden bookkeeping files do not count.
        File(directory, ".DS_Store").writeText("x")
        assertNotNull(store.find(id))
    }

    @Test
    fun filesAlteredOnDiskAreValidatedAgain() {
        install()
        val directory = File(root, "weather-expert")
        val manifestFile = File(directory, "skill.json")

        manifestFile.writeText(skillManifest(id, "Weather Expert", "1.0.0", ",\"executable\":\"payload.sh\""))
        assertNull("unknown key", store.find(id))
        manifestFile.writeText("not json")
        assertNull("bad JSON", store.find(id))
        manifestFile.writeText(manifest.dropLast(1) + ",\"author\":\"" + "a".repeat(SkillValidator.MAX_MANIFEST_BYTES) + "\"}")
        assertNull("oversized manifest", store.find(id))
        manifestFile.writeText(manifest)
        assertNotNull(store.find(id))

        File(directory, "SKILL.md").writeBytes(ByteArray(SkillValidator.MAX_INSTRUCTION_BYTES + 1) { 'x'.code.toByte() })
        assertNull("oversized instruction", store.find(id))
        assertTrue(custom().isEmpty())
    }

    @Test
    fun linksAreNeverFollowed() {
        install()
        val directory = File(root, "weather-expert")
        val outside = File(temporary.root, "outside").apply { mkdir() }
        File(outside, "skill.json").writeText(skillManifest("com.example.linked", "Linked", "1.0.0"))
        File(outside, "SKILL.md").writeText("From outside the store.")

        Files.createSymbolicLink(File(root, "linked").toPath(), outside.toPath())
        assertEquals(listOf(id), custom())

        val instructionFile = File(directory, "SKILL.md")
        instructionFile.delete()
        Files.createSymbolicLink(instructionFile.toPath(), File(outside, "SKILL.md").toPath())
        assertTrue(custom().isEmpty())
    }

    // MARK: - Archives

    @Test
    fun exportImportRoundTripAndDuplicateRejection() {
        install()
        val archive = export()
        val names = ArrayList<String>()
        ZipInputStream(archive.inputStream()).use { zip -> generateSequence { zip.nextEntry }.forEach { names.add(it.name) } }
        assertEquals(listOf("skill.json", "SKILL.md"), names)

        val destination = SkillStore(File(temporary.root, "Other"))
        val imported = import(archive, destination)
        assertEquals(store.find(id), imported)
        assertFalse(destination.isEnabled(id))
        assertCode(SkillErrors.DUPLICATE) { import(archive, destination) }
        assertEquals(listOf("weather-expert/", "weather-expert/SKILL.md", "weather-expert/skill.json"), tree(File(temporary.root, "Other")))
        assertCode(SkillErrors.NOT_FOUND) { export("com.example.missing") }
    }

    @Test
    fun builtInSkillsExportAsValidPackages() {
        val builtIn = BuiltInSkills.all.first()
        val files = HashMap<String, ByteArray>()
        ZipInputStream(export(builtIn.id).inputStream()).use { zip -> generateSequence { zip.nextEntry }.forEach { files[it.name] = zip.readBytes() } }
        assertEquals(setOf("skill.json", "SKILL.md"), files.keys)
        assertEquals(builtIn.copy(isBuiltIn = false), SkillValidator.load(files.getValue("skill.json"), files.getValue("SKILL.md")))
    }

    @Test
    fun importsFromOneTopLevelDirectoryAndIgnoresPlatformMetadata() {
        val archive = ZipFixtures.deflatedZip(linkedMapOf(
            "Weather/skill.json" to manifest.toByteArray(),
            "Weather/SKILL.md" to instruction.toByteArray(),
            "Weather/.DS_Store" to "x".toByteArray(),
            "__MACOSX/Weather/._skill.json" to "x".toByteArray(),
        ))
        assertEquals(id, import(archive).id)
        assertEquals(listOf("weather-expert/", "weather-expert/SKILL.md", "weather-expert/skill.json"), tree(root))
    }

    @Test
    fun oversizedArchiveIsRejectedBeforeExtraction() {
        val error = assertCode(SkillErrors.TOO_LARGE) { import(ByteArray(SkillValidator.MAX_PACKAGE_BYTES + 1)) }
        assertTrue(error.message!!.contains("256 KiB"))
        assertTrue(tree(root).isEmpty())
    }

    @Test
    fun archivesThatAreNotExactlyTheTwoFilesAreRejected() {
        val json = RawEntry("skill.json", manifest)
        val text = RawEntry("SKILL.md", instruction)
        val invalid = listOf(
            arrayOf(json, text, RawEntry("run.sh", "#!/bin/sh")),
            arrayOf(json, text, RawEntry("assets/icon.png", "x")),
            arrayOf(json, text, RawEntry("assets/")),
            arrayOf(json),
            arrayOf(text),
            arrayOf(json, RawEntry("skill.md", instruction)),
            arrayOf(RawEntry("Skill.json", manifest), text),
            arrayOf(json, RawEntry("docs/SKILL.md", instruction)),
            arrayOf(RawEntry("a/skill.json", manifest), RawEntry("b/SKILL.md", instruction)),
            arrayOf(RawEntry("a/skill.json", manifest), RawEntry("a/SKILL.md", instruction), RawEntry("b/skill.json", manifest), RawEntry("b/SKILL.md", instruction)),
            arrayOf(RawEntry("a/b/skill.json", manifest), RawEntry("a/b/SKILL.md", instruction)),
            arrayOf(RawEntry("a/skill.json", manifest), RawEntry("a/SKILL.md", instruction), RawEntry("a/extra.md", "x")),
            arrayOf(RawEntry(".hidden/skill.json", manifest), RawEntry(".hidden/SKILL.md", instruction)),
        )
        for (entries in invalid) assertImportRefused(SkillErrors.INVALID_PACKAGE, ZipFixtures.rawZip(*entries))
    }

    @Test
    fun hostileArchivesAreRejectedByThePreflight() {
        val json = RawEntry("skill.json", manifest)
        val text = RawEntry("SKILL.md", instruction)
        val hostile = mapOf(
            "traversal" to ZipFixtures.rawZip(json, text, RawEntry("../escape.md", "x")),
            "nested traversal" to ZipFixtures.rawZip(RawEntry("a/../../skill.json", manifest), text),
            "absolute" to ZipFixtures.rawZip(json, RawEntry("/SKILL.md", instruction)),
            "backslash" to ZipFixtures.rawZip(json, RawEntry("..\\SKILL.md", instruction)),
            "drive" to ZipFixtures.rawZip(json, RawEntry("C:SKILL.md", instruction)),
            "symlink" to ZipFixtures.rawZip(json, RawEntry("SKILL.md", "/etc/passwd".toByteArray(), externalAttributes = 0xA1FFL shl 16)),
            "duplicate" to ZipFixtures.rawZip(json, text, RawEntry("SKILL.md", "Second copy.")),
            "case collision" to ZipFixtures.rawZip(json, text, RawEntry("skill.JSON", manifest)),
            "encrypted" to ZipFixtures.rawZip(json, RawEntry("SKILL.md", instruction.toByteArray(), flags = 0x0801)),
            "unknown compression" to ZipFixtures.rawZip(json, RawEntry("SKILL.md", instruction.toByteArray(), method = 12)),
            "too deep" to ZipFixtures.rawZip(RawEntry("a/b/c/skill.json", manifest), RawEntry("a/b/c/SKILL.md", instruction)),
            "too many entries" to ZipFixtures.rawZip(json, text, *Array(15) { RawEntry(".pad$it", "x") }),
            "declared file too large" to ZipFixtures.rawZip(json, RawEntry("SKILL.md", instruction.toByteArray(), declaredSize = 65L * 1024)),
            "not a zip" to "plain text".toByteArray(),
            "empty" to ByteArray(0),
            "truncated" to ZipFixtures.rawZip(json, text).dropLast(8).toByteArray(),
        )
        for ((name, archive) in hostile) {
            try {
                assertImportRefused(SkillErrors.INVALID_ARCHIVE, archive)
            } catch (error: AssertionError) {
                throw AssertionError("$name: ${error.message}", error)
            }
        }
        assertFalse(File(temporary.root, "escape.md").exists())
    }

    @Test
    fun entriesMustMatchTheirDeclaredSizesAndLimits() {
        val json = RawEntry("skill.json", manifest)
        // Declares fewer bytes than are stored: the content read back fails its CRC.
        assertImportRefused(SkillErrors.INVALID_ARCHIVE, ZipFixtures.rawZip(json, RawEntry("SKILL.md", instruction.toByteArray(), declaredSize = 4, declaredCompressedSize = 4)))
        // A deflated entry whose central directory understates the real size (zip bomb shape).
        val deflated = ZipFixtures.deflatedZip(linkedMapOf("skill.json" to manifest.toByteArray(), "SKILL.md" to "x".repeat(40_000).toByteArray()))
        assertImportRefused(SkillErrors.INVALID_ARCHIVE, ZipFixtures.forgeDeclaredSize(deflated, 1, 10))
        // skill.json above 32 KiB is refused although it fits the per-file archive limit.
        val largeManifest = manifest.dropLast(1) + ",\"author\":\"" + "a".repeat(40_000) + "\"}"
        assertImportRefused(SkillErrors.TOO_LARGE, ZipFixtures.deflatedZip(linkedMapOf("skill.json" to largeManifest.toByteArray(), "SKILL.md" to instruction.toByteArray())))
    }

    @Test
    fun archiveContentIsValidatedLikeAnyOtherSkill() {
        fun zip(manifest: String, text: String = instruction) = ZipFixtures.deflatedZip(linkedMapOf("skill.json" to manifest.toByteArray(), "SKILL.md" to text.toByteArray()))
        assertImportRefused(SkillErrors.UNKNOWN_FIELD, zip(skillManifest(id, "Weather Expert", "1.0.0", ",\"executable\":\"payload.sh\"")))
        assertImportRefused(SkillErrors.INVALID_MANIFEST, zip("not json"))
        assertImportRefused(SkillErrors.INVALID_SKILL, zip(skillManifest(id, "Weather Expert", "latest")))
        assertImportRefused(SkillErrors.INVALID_SKILL, zip(manifest, "   "))
        assertImportRefused(SkillErrors.DUPLICATE, zip(skillManifest("visual-polish", "Shadow", "1.0.0")))
    }
}
