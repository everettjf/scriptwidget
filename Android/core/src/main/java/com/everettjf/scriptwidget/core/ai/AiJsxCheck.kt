package com.everettjf.scriptwidget.core.ai

/**
 * Finds tags and attributes in generated code that ScriptWidget does not have.
 * Port of `AIJSXCheck`; the two must report the same problems for the same code.
 *
 * The runtime ignores an unknown attribute, and a value outside a closed list,
 * without an error: the widget runs and shows something else. The repair loop
 * can only fix what it is told, so this check tells it before the widget runs.
 *
 * It reads the code loosely, not as a parser would, and is built to stay
 * silent when unsure: a tag whose name starts with a capital letter is taken
 * for the script's own component, and anything that is not plainly a tag is
 * skipped. It grants nothing and blocks nothing at
 * run time; the runtime's own switch stays the authority.
 */
object AiJsxCheck {
    /** Attribute name to its closed list of values, or null when any value goes. */
    class Surface(val globals: Map<String, Set<String>?>, val tags: Map<String, Map<String, Set<String>?>>)

    const val MAX_PROBLEMS = 5

    /** The tags of this system: the shared ones and those marked `@android`. */
    val ANDROID: Surface by lazy { parseSurface(AiJsxSurfaceData.TEXT, "android") }

    /** Reads the generated list; [system] chooses which system-only tags count. */
    fun parseSurface(text: String, system: String?): Surface {
        val globals = LinkedHashMap<String, Set<String>?>()
        val tags = LinkedHashMap<String, Map<String, Set<String>?>>()
        fun attribute(word: String): Pair<String, Set<String>?> {
            val at = word.indexOf('=')
            return if (at < 0) word to null else word.substring(0, at) to word.substring(at + 1).split("|").toSet()
        }
        for (line in text.lines()) {
            val words = line.trim().split(" ").filter { it.isNotEmpty() }
            if (words.size < 2) continue
            when {
                words[0] == "global" -> attribute(words[1]).let { globals[it.first] = it.second }
                words[0] == "tag" || (system != null && words[0] == "tag@$system") ->
                    tags[words[1]] = words.drop(2).associate { attribute(it) }
            }
        }
        return Surface(globals, tags)
    }

    /** What is wrong with [source], at most [MAX_PROBLEMS] sentences; empty when nothing is. */
    fun problems(source: String, surface: Surface = ANDROID): List<String> {
        val found = LinkedHashSet<String>()
        for (tag in tags(source)) {
            if (found.size >= MAX_PROBLEMS) break
            // A capital letter marks the script's own component, even one named like a tag; a dotted name is a member.
            if (tag.name.first() !in 'a'..'z' || tag.name.contains('.')) continue
            val name = tag.name
            val own = surface.tags[name]
            if (own == null) {
                found += "<$name> is not a ScriptWidget tag. The tags are: ${surface.tags.keys.joinToString(", ")}."
                continue
            }
            for (attribute in tag.attributes) {
                if (found.size >= MAX_PROBLEMS) break
                val known = own.containsKey(attribute.name) || surface.globals.containsKey(attribute.name)
                if (!known) {
                    val names = (own.keys + surface.globals.keys).joinToString(", ")
                    found += "<$name> has no attribute \"${attribute.name}\"; it would be ignored. Its attributes are: $names."
                    continue
                }
                val allowed = own[attribute.name] ?: surface.globals[attribute.name] ?: continue
                val value = attribute.literal ?: continue
                if (value !in allowed) {
                    found += "${attribute.name}=\"$value\" on <$name> is not one of its values; it would be ignored. Use one of: ${allowed.joinToString(", ")}."
                }
            }
        }
        return found.toList()
    }

    /** One line for the model, or null when [source] has no problem. */
    fun summary(source: String, surface: Surface = ANDROID): String? {
        val problems = problems(source, surface)
        if (problems.isEmpty()) return null
        return "The code uses tags or attributes that ScriptWidget does not have:\n" + problems.joinToString("\n") { "- $it" }
    }

    internal class Attribute(val name: String, /** The value when it is written as a plain string. */ val literal: String?)
    internal class Tag(val name: String, val attributes: List<Attribute>)

    private val TAG_BEFORE_KEYWORDS = setOf("return", "yield", "case", "default", "await", "else", "do", "in", "of", "typeof", "void", "delete", "new", "throw")

    /** The opening tags of [source], read loosely. */
    internal fun tags(source: String): List<Tag> {
        val text = source
        val length = text.length
        val result = ArrayList<Tag>()
        var index = 0
        while (index < length) {
            val character = text[index]
            when {
                character == '/' && index + 1 < length && text[index + 1] == '/' -> {
                    index = text.indexOf('\n', index).let { if (it < 0) length else it }
                }
                character == '/' && index + 1 < length && text[index + 1] == '*' -> {
                    index = text.indexOf("*/", index + 2).let { if (it < 0) length else it + 2 }
                }
                character == '"' || character == '\'' -> index = skipQuoted(text, index, sameLineOnly = true)
                character == '`' -> index = skipQuoted(text, index, sameLineOnly = false)
                character == '<' && index + 1 < length && text[index + 1].isAsciiLetter() && startsTag(text, index) -> {
                    val read = readTag(text, index + 1)
                    if (read == null) {
                        index += 1
                    } else {
                        result += read.first
                        index = read.second
                    }
                }
                else -> index += 1
            }
        }
        return result
    }

    /** Whether the `<` at [at] can open a tag: after an operator or a keyword, not after a value. */
    private fun startsTag(text: String, at: Int): Boolean {
        var before = at - 1
        while (before >= 0 && text[before].isWhitespace()) before -= 1
        if (before < 0) return true
        val character = text[before]
        if (character == ')' || character == ']') return false
        if (!character.isWordCharacter()) return true
        var start = before
        while (start >= 0 && text[start].isWordCharacter()) start -= 1
        return text.substring(start + 1, before + 1) in TAG_BEFORE_KEYWORDS
    }

    /** Reads a tag whose name starts at [from]; the tag and the index after its `>`, or null when it is not one. */
    private fun readTag(text: String, from: Int): Pair<Tag, Int>? {
        val length = text.length
        var index = from
        while (index < length && (text[index].isAsciiLetter() || text[index] in '0'..'9' || text[index] == '.' || text[index] == '_')) index += 1
        val name = text.substring(from, index)
        val attributes = ArrayList<Attribute>()
        while (true) {
            while (index < length && text[index].isWhitespace()) index += 1
            if (index >= length) return null
            val character = text[index]
            if (character == '>') return Tag(name, attributes) to index + 1
            if (character == '/') {
                return if (index + 1 < length && text[index + 1] == '>') Tag(name, attributes) to index + 2 else null
            }
            if (character == '{') {
                // {...spread}
                index = skipBraces(text, index) ?: return null
                continue
            }
            if (!(character.isAsciiLetter() || character == '_')) return null
            val start = index
            while (index < length && (text[index].isAsciiLetter() || text[index] in '0'..'9' || text[index] == '_' || text[index] == '-' || text[index] == ':')) index += 1
            val attributeName = text.substring(start, index)
            while (index < length && text[index].isWhitespace()) index += 1
            if (index >= length || text[index] != '=') {
                attributes += Attribute(attributeName, null)
                continue
            }
            index += 1
            while (index < length && text[index].isWhitespace()) index += 1
            if (index >= length) return null
            when (text[index]) {
                '"', '\'' -> {
                    val end = text.indexOf(text[index], index + 1)
                    if (end < 0) return null
                    attributes += Attribute(attributeName, text.substring(index + 1, end))
                    index = end + 1
                }
                '{' -> {
                    val end = skipBraces(text, index) ?: return null
                    val inner = text.substring(index + 1, end - 1).trim()
                    // {"value"} is as plain as "value".
                    val literal = if (inner.length >= 2 && (inner.first() == '"' || inner.first() == '\'') && inner.last() == inner.first() &&
                        inner.indexOf(inner.first(), 1) == inner.length - 1 && !inner.contains('\\')) inner.substring(1, inner.length - 1) else null
                    attributes += Attribute(attributeName, literal)
                    index = end
                }
                else -> return null
            }
        }
    }

    /** The index after the `}` that closes the `{` at [from], or null when it is not closed. */
    private fun skipBraces(text: String, from: Int): Int? {
        var depth = 0
        var index = from
        while (index < text.length) {
            when (text[index]) {
                '{' -> { depth += 1; index += 1 }
                '}' -> { depth -= 1; index += 1; if (depth == 0) return index }
                '"', '\'' -> index = skipQuoted(text, index, sameLineOnly = true)
                '`' -> index = skipQuoted(text, index, sameLineOnly = false)
                else -> index += 1
            }
        }
        return null
    }

    /**
     * The index after the quoted text that starts at [from]. A quote that is not closed on its line,
     * an apostrophe in a sentence for one, is passed over as a single character.
     */
    private fun skipQuoted(text: String, from: Int, sameLineOnly: Boolean): Int {
        val quote = text[from]
        var index = from + 1
        while (index < text.length) {
            val character = text[index]
            if (character == '\\') { index += 2; continue }
            if (character == quote) return index + 1
            if (sameLineOnly && character == '\n') return from + 1
            index += 1
        }
        return from + 1
    }

    private fun Char.isAsciiLetter(): Boolean = this in 'a'..'z' || this in 'A'..'Z'
    private fun Char.isWordCharacter(): Boolean = isAsciiLetter() || this in '0'..'9' || this == '_' || this == '$'
}
