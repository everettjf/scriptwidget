package com.everettjf.scriptwidget.core.plugin

/**
 * RFC 8259 JSON reader and writer for untrusted plugin manifests and data source responses.
 *
 * `org.json` accepts unquoted strings, single quotes, comments and trailing text, and its
 * Android and JVM builds disagree on number types and duplicate keys. A manifest that one
 * platform reads and another refuses is not a contract, so manifests are parsed here: exactly
 * one JSON value, nothing after it, no raw control characters, bounded nesting.
 */
internal object StrictJson {
    /** Deepest container nesting accepted; `JSONSerialization` on Apple platforms stops at 512 as well. */
    const val MAXIMUM_DEPTH = 512

    /** What a document's top-level value is, for callers that only validate. */
    enum class Kind { OBJECT, ARRAY, STRING, NUMBER, BOOLEAN, NULL }

    class JsonException(message: String) : Exception(message)

    /**
     * Parses [text] into `LinkedHashMap<String, Any?>`, `ArrayList<Any?>`, `String`, `Long`,
     * `Double`, `Boolean` and `null`.
     *
     * A repeated object key is rejected unless [allowDuplicateKeys]: two values for one key let
     * a validator and a later reader disagree about what the document says.
     */
    fun parse(text: String, allowDuplicateKeys: Boolean = false): Any? = Reader(text, true, allowDuplicateKeys).document()

    /** Checks that [text] is one well-formed JSON value without building it, and returns its kind. */
    fun validate(text: String): Kind {
        val reader = Reader(text, false, true)
        reader.document()
        return reader.topLevel
    }

    /** JSON string literal for [value]. Slashes are not escaped, like `.withoutEscapingSlashes` in Swift. */
    fun quote(value: String): String {
        val out = StringBuilder(value.length + 2).append('"')
        for (char in value) {
            when (char) {
                '"' -> out.append("\\\"")
                '\\' -> out.append("\\\\")
                '\n' -> out.append("\\n")
                '\r' -> out.append("\\r")
                '\t' -> out.append("\\t")
                '\b' -> out.append("\\b")
                '\u000C' -> out.append("\\f")
                else -> if (char < ' ' || char == ' ' || char == ' ') out.append("\\u%04x".format(char.code)) else out.append(char)
            }
        }
        return out.append('"').toString()
    }

    private class Reader(private val text: String, private val build: Boolean, private val allowDuplicateKeys: Boolean) {
        private var index = 0
        lateinit var topLevel: Kind

        fun document(): Any? {
            skipWhitespace()
            topLevel = kindAt()
            val result = value(0)
            skipWhitespace()
            if (index != text.length) fail("Unexpected text after the JSON value")
            return result
        }

        private fun kindAt(): Kind = when (peek()) {
            '{' -> Kind.OBJECT
            '[' -> Kind.ARRAY
            '"' -> Kind.STRING
            't', 'f' -> Kind.BOOLEAN
            'n' -> Kind.NULL
            else -> Kind.NUMBER
        }

        private fun value(depth: Int): Any? {
            if (depth > MAXIMUM_DEPTH) fail("JSON is nested too deeply")
            return when (peek()) {
                '{' -> objectValue(depth)
                '[' -> arrayValue(depth)
                '"' -> string()
                't' -> literal("true", true)
                'f' -> literal("false", false)
                'n' -> literal("null", null)
                else -> number()
            }
        }

        private fun objectValue(depth: Int): Any? {
            index += 1
            val result = if (build) LinkedHashMap<String, Any?>() else null
            val seen = if (!allowDuplicateKeys) HashSet<String>() else null
            skipWhitespace()
            if (peek() == '}') { index += 1; return result }
            while (true) {
                skipWhitespace()
                if (peek() != '"') fail("Expected an object key")
                val key = string()
                if (seen != null && !seen.add(key)) fail("Duplicate object key $key")
                skipWhitespace()
                if (peek() != ':') fail("Expected ':' after an object key")
                index += 1
                skipWhitespace()
                val member = value(depth + 1)
                result?.put(key, member)
                skipWhitespace()
                when (peek()) {
                    ',' -> index += 1
                    '}' -> { index += 1; return result }
                    else -> fail("Expected ',' or '}' in an object")
                }
            }
        }

        private fun arrayValue(depth: Int): Any? {
            index += 1
            val result = if (build) ArrayList<Any?>() else null
            skipWhitespace()
            if (peek() == ']') { index += 1; return result }
            while (true) {
                skipWhitespace()
                val member = value(depth + 1)
                result?.add(member)
                skipWhitespace()
                when (peek()) {
                    ',' -> index += 1
                    ']' -> { index += 1; return result }
                    else -> fail("Expected ',' or ']' in an array")
                }
            }
        }

        private fun string(): String {
            index += 1
            val out = StringBuilder()
            while (true) {
                if (index >= text.length) fail("Unterminated string")
                val char = text[index]
                index += 1
                when {
                    char == '"' -> return out.toString()
                    char < ' ' -> fail("Control character in a string")
                    char != '\\' -> out.append(char)
                    else -> {
                        if (index >= text.length) fail("Unterminated escape")
                        val escape = text[index]
                        index += 1
                        when (escape) {
                            '"', '\\', '/' -> out.append(escape)
                            'b' -> out.append('\b')
                            'f' -> out.append('\u000C')
                            'n' -> out.append('\n')
                            'r' -> out.append('\r')
                            't' -> out.append('\t')
                            'u' -> {
                                if (index + 4 > text.length) fail("Truncated unicode escape")
                                var code = 0
                                repeat(4) {
                                    val digit = Character.digit(text[index], 16)
                                    if (digit < 0) fail("Invalid unicode escape")
                                    code = code * 16 + digit
                                    index += 1
                                }
                                out.append(code.toChar())
                            }
                            else -> fail("Invalid escape")
                        }
                    }
                }
            }
        }

        private fun number(): Any {
            val start = index
            if (peek() == '-') index += 1
            when {
                peek() == '0' -> index += 1
                peek() in '1'..'9' -> digits()
                else -> fail("Unexpected character")
            }
            var integral = true
            if (peek() == '.') { integral = false; index += 1; digits() }
            if (peek() == 'e' || peek() == 'E') {
                integral = false
                index += 1
                if (peek() == '+' || peek() == '-') index += 1
                digits()
            }
            val literal = text.substring(start, index)
            return (if (integral) literal.toLongOrNull() else null) ?: literal.toDouble()
        }

        private fun digits() {
            val start = index
            while (peek() in '0'..'9') index += 1
            if (index == start) fail("Expected a digit")
        }

        private fun literal(word: String, value: Any?): Any? {
            if (!text.startsWith(word, index)) fail("Unexpected character")
            index += word.length
            return value
        }

        private fun skipWhitespace() {
            while (index < text.length && (text[index] == ' ' || text[index] == '\n' || text[index] == '\r' || text[index] == '\t')) index += 1
        }

        /** The current character, or NUL at the end (NUL is never valid outside a string). */
        private fun peek(): Char = if (index < text.length) text[index] else '\u0000'

        private fun fail(message: String): Nothing = throw JsonException("$message at offset $index")
    }
}
