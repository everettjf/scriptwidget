package com.everettjf.scriptwidget.core.skills

import com.everettjf.scriptwidget.core.gallery.GalleryFiles
import com.everettjf.scriptwidget.core.pkg.SafeFiles
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale

/**
 * A usable Skill: validated metadata plus its instruction text (`AIWidgetSkill` in Swift).
 *
 * A Skill is prompt text and nothing else. No field names a file to run, a tool, a permission
 * or a network host, and nothing in this layer evaluates [instruction].
 */
data class Skill(
    val id: String,
    val title: String,
    val version: String,
    val symbol: String,
    val summary: String,
    val instruction: String,
    val tags: List<String> = emptyList(),
    val author: String? = null,
    val minimumRuntimeVersion: String = SkillManifest.RUNTIME_CONTRACT_VERSION,
    val isBuiltIn: Boolean = false,
)

/** The content of `skill.json` (`AIWidgetSkillManifest` in Swift, `skill.schema.json`). */
data class SkillManifest(
    val formatVersion: Int,
    val id: String,
    val name: String,
    val version: String,
    val summary: String,
    val symbol: String,
    val promptFile: String,
    val tags: List<String>,
    val author: String?,
    val minimumRuntimeVersion: String,
) {
    /** Canonical JSON of this manifest, containing only schema fields. */
    fun encode(): ByteArray {
        val json = JSONObject()
            .put("formatVersion", formatVersion).put("id", id).put("name", name).put("version", version)
            .put("summary", summary).put("symbol", symbol).put("promptFile", promptFile)
            .put("tags", JSONArray(tags)).put("minimumRuntimeVersion", minimumRuntimeVersion)
        if (author != null) json.put("author", author)
        return (json.toString(2) + "\n").toByteArray(Charsets.UTF_8)
    }

    companion object {
        /** `AIWidgetSkillManifest.currentFormatVersion`. */
        const val CURRENT_FORMAT_VERSION = 1
        /** `ScriptWidgetBuildContract.runtimeAPIVersion`. */
        const val RUNTIME_CONTRACT_VERSION = "1.0"
        const val FILE_NAME = "skill.json"
        const val INSTRUCTION_FILE_NAME = "SKILL.md"
    }
}

/** One reason a Skill was refused; [id] matches the Swift issue identifiers. */
data class SkillValidationIssue(val id: String, val message: String)

/**
 * The single failure type of the Skills layer. [code] is stable and machine-readable (see
 * [SkillErrors]); [issues] lists every broken validation rule when there are several.
 */
class SkillException(val code: String, message: String, val issues: List<SkillValidationIssue> = emptyList(), cause: Throwable? = null) :
    Exception(message, cause)

object SkillErrors {
    /** `skill.json` or `SKILL.md` is larger than its limit. */
    const val TOO_LARGE = "too_large"
    /** `skill.json` is not one UTF-8 JSON object with every required, correctly typed field. */
    const val INVALID_MANIFEST = "invalid_manifest"
    /** `skill.json` has a key that Skills 1.0 does not define. */
    const val UNKNOWN_FIELD = "unknown_field"
    /** `SKILL.md` is not valid UTF-8. */
    const val INVALID_INSTRUCTION = "invalid_instruction"
    /** The manifest or instruction breaks a validation rule; see [SkillException.issues]. */
    const val INVALID_SKILL = "invalid_skill"
    /** The package is not exactly `skill.json` and `SKILL.md`. */
    const val INVALID_PACKAGE = "invalid_package"
    /** The ZIP archive failed the hardened preflight or could not be read back exactly. */
    const val INVALID_ARCHIVE = "invalid_archive"
    const val DUPLICATE = "duplicate_skill"
    const val NOT_FOUND = "skill_not_found"
    const val BUILT_IN = "built_in_skill"
    const val STORAGE_UNAVAILABLE = "storage_unavailable"
}

/** Strict Skills 1.0 validation, ported from `AIWidgetSkillValidator` and `AIWidgetSkillPackage.load`. */
object SkillValidator {
    /** `maximumInstructionBytes`: `SKILL.md`. */
    const val MAX_INSTRUCTION_BYTES = 64 * 1024
    /** `maximumManifestBytes`: `skill.json`. */
    const val MAX_MANIFEST_BYTES = 32 * 1024
    /** `maximumPackageBytes`: a whole `.swskill` archive. */
    const val MAX_PACKAGE_BYTES = 256 * 1024
    const val MAX_NAME_LENGTH = 80
    const val MAX_SUMMARY_LENGTH = 240
    const val MAX_SYMBOL_LENGTH = 80
    const val MAX_TAGS = 20

    private val identifier = Regex("^[A-Za-z0-9][A-Za-z0-9.-]{2,127}$")
    private val semanticVersion = Regex("^[0-9]+\\.[0-9]+\\.[0-9]+(?:-[0-9A-Za-z.-]+)?$")
    private val allowedKeys = setOf(
        "formatVersion", "id", "name", "version", "summary", "symbol", "promptFile", "tags", "author", "minimumRuntimeVersion",
    )
    private val requiredStrings = listOf("id", "name", "version", "summary", "symbol", "promptFile", "minimumRuntimeVersion")

    /**
     * Decodes `skill.json`.
     *
     * Refused: more than 32 KiB; bytes that are not strict UTF-8; anything but one JSON object;
     * a key outside the schema (an unknown capability such as `executable` must fail closed, not
     * be ignored); a missing required field; a field of the wrong JSON type.
     */
    fun parseManifest(bytes: ByteArray): SkillManifest {
        if (bytes.size > MAX_MANIFEST_BYTES) throw SkillException(SkillErrors.TOO_LARGE, "skill.json exceeds 32 KiB.")
        val json = SafeFiles.decodeUtf8(bytes)?.let(GalleryFiles::parseObject)
            ?: throw SkillException(SkillErrors.INVALID_MANIFEST, "skill.json must be one UTF-8 JSON object.")
        val unknown = json.keys().asSequence().filter { it !in allowedKeys }.sorted().toList()
        if (unknown.isNotEmpty()) throw SkillException(SkillErrors.UNKNOWN_FIELD, "skill.json contains unknown fields: ${unknown.joinToString(", ")}.")
        fun malformed(key: String): Nothing = throw SkillException(SkillErrors.INVALID_MANIFEST, "skill.json field $key is missing or has the wrong type.")
        val strings = requiredStrings.associateWith { key -> json.opt(key) as? String ?: malformed(key) }
        val formatVersion = json.opt("formatVersion") as? Int ?: malformed("formatVersion")
        val tagArray = json.opt("tags") as? JSONArray ?: malformed("tags")
        val tags = List(tagArray.length()) { tagArray.opt(it) as? String ?: malformed("tags") }
        val author = if (json.has("author")) json.opt("author") as? String ?: malformed("author") else null
        return SkillManifest(
            formatVersion = formatVersion,
            id = strings.getValue("id"),
            name = strings.getValue("name"),
            version = strings.getValue("version"),
            summary = strings.getValue("summary"),
            symbol = strings.getValue("symbol"),
            promptFile = strings.getValue("promptFile"),
            tags = tags,
            author = author,
            minimumRuntimeVersion = strings.getValue("minimumRuntimeVersion"),
        )
    }

    /**
     * Semantic rules; an empty result means the Skill is acceptable.
     *
     * Refused: a format other than 1; an id outside `[A-Za-z0-9][A-Za-z0-9.-]{2,127}`; a blank
     * or over-long name, summary or symbol; a version that is not `major.minor.patch[-pre]`; a
     * runtime contract other than `1.0`; a `promptFile` other than `SKILL.md` (a Skill cannot
     * point at another file); more than 20 tags or tags equal ignoring case; blank instructions;
     * instructions above 64 KiB.
     */
    fun validate(manifest: SkillManifest, instruction: String): List<SkillValidationIssue> {
        val issues = ArrayList<SkillValidationIssue>()
        fun reject(id: String, message: String) { issues.add(SkillValidationIssue(id, message)) }
        if (manifest.formatVersion != SkillManifest.CURRENT_FORMAT_VERSION) reject("unsupported_format", "Skill format ${manifest.formatVersion} is not supported.")
        if (!identifier.matches(manifest.id)) reject("invalid_id", "Skill id must use 3–128 letters, numbers, dots, or hyphens.")
        if (!bounded(manifest.name, MAX_NAME_LENGTH)) reject("invalid_name", "Skill name must contain 1–80 characters.")
        if (!semanticVersion.matches(manifest.version)) reject("invalid_version", "Skill version must be semantic, for example 1.0.0.")
        if (manifest.minimumRuntimeVersion != SkillManifest.RUNTIME_CONTRACT_VERSION) {
            reject("unsupported_runtime", "Skill requires runtime ${manifest.minimumRuntimeVersion}, but this app supports ${SkillManifest.RUNTIME_CONTRACT_VERSION}.")
        }
        if (manifest.promptFile != SkillManifest.INSTRUCTION_FILE_NAME) reject("invalid_prompt_file", "Skills 1.0 requires promptFile to be SKILL.md.")
        if (!bounded(manifest.summary, MAX_SUMMARY_LENGTH)) reject("invalid_summary", "Skill summary must contain 1–240 characters.")
        if (manifest.symbol.isEmpty() || manifest.symbol.codePointCount(0, manifest.symbol.length) > MAX_SYMBOL_LENGTH) reject("invalid_symbol", "Skill symbol is invalid.")
        if (manifest.tags.size > MAX_TAGS || manifest.tags.map { it.lowercase(Locale.ROOT) }.toSet().size != manifest.tags.size) {
            reject("invalid_tags", "Use at most 20 unique tags.")
        }
        if (instruction.isBlank()) reject("empty_instruction", "SKILL.md must contain instructions.")
        if (instruction.toByteArray(Charsets.UTF_8).size > MAX_INSTRUCTION_BYTES) reject("instruction_too_large", "SKILL.md exceeds 64 KiB.")
        return issues
    }

    /**
     * Decodes and validates the two files of a Skills 1.0 package. Sizes are checked on the
     * bytes that will be stored, and `SKILL.md` must be strict UTF-8.
     *
     * @throws SkillException for every rule of [parseManifest] and [validate].
     */
    fun load(manifestBytes: ByteArray, instructionBytes: ByteArray): Skill {
        val manifest = parseManifest(manifestBytes)
        if (instructionBytes.size > MAX_INSTRUCTION_BYTES) throw SkillException(SkillErrors.TOO_LARGE, "SKILL.md exceeds 64 KiB.")
        val instruction = SafeFiles.decodeUtf8(instructionBytes) ?: throw SkillException(SkillErrors.INVALID_INSTRUCTION, "SKILL.md must be UTF-8 text.")
        val issues = validate(manifest, instruction)
        if (issues.isNotEmpty()) throw SkillException(SkillErrors.INVALID_SKILL, issues.joinToString("\n") { it.message }, issues)
        return Skill(
            id = manifest.id, title = manifest.name, version = manifest.version, symbol = manifest.symbol, summary = manifest.summary,
            instruction = instruction, tags = manifest.tags, author = manifest.author, minimumRuntimeVersion = manifest.minimumRuntimeVersion,
        )
    }

    /** Directory name for a Skill: lowercase ASCII letters and digits joined by `-`, or `skill`. */
    fun slug(value: String): String =
        value.lowercase(Locale.ROOT).replace(Regex("[^a-z0-9]+"), "-").trim('-').take(64).trim('-').ifEmpty { "skill" }

    private fun bounded(text: String, maximum: Int): Boolean = text.isNotBlank() && text.codePointCount(0, text.length) <= maximum
}

/** The read-only Skills shipped with the app (`AIWidgetSkills.builtIns` in Swift). */
object BuiltInSkills {
    val all: List<Skill> = listOf(
        Skill(
            id = "responsive-layout", title = "Responsive Layout", version = "1.0.0", symbol = "rectangle.3.group",
            summary = "Adapt one script to every widget family.",
            instruction = "Use \$getenv(\"widget-size\") to create intentional small, medium, and large layouts. Keep the information hierarchy readable in every family.",
            tags = listOf("layout"), isBuiltIn = true,
        ),
        Skill(
            id = "accessible-design", title = "Accessible Design", version = "1.0.0", symbol = "accessibility",
            summary = "Improve contrast, hierarchy, and legibility.",
            instruction = "Use strong text/background contrast, avoid color as the only signal, keep important text legible, and prefer concise labels.",
            tags = listOf("accessibility"), isBuiltIn = true,
        ),
        Skill(
            id = "resilient-data", title = "Resilient Data", version = "1.0.0", symbol = "network.badge.shield.half.filled",
            summary = "Handle network and missing-data failures.",
            instruction = "When data is remote or optional, validate it and render a useful fallback state. Never expose secrets or invent unsupported runtime APIs.",
            tags = listOf("network", "safety"), isBuiltIn = true,
        ),
        Skill(
            id = "visual-polish", title = "Visual Polish", version = "1.0.0", symbol = "paintbrush.pointed",
            summary = "Apply a coherent native visual system.",
            instruction = "Create a restrained native-looking visual system with consistent spacing, typography, color, and alignment. Avoid decorative clutter.",
            tags = listOf("design"), isBuiltIn = true,
        ),
        Skill(
            id = "runtime-debugger", title = "Runtime Debugger", version = "1.0.0", symbol = "ladybug",
            summary = "Repair errors with the smallest safe change.",
            instruction = "Prioritize the supplied runtime diagnostic. Make the smallest correction that fixes it, preserve unrelated behavior, and use only documented ScriptWidget APIs.",
            tags = listOf("debugging"), isBuiltIn = true,
        ),
    )
}
