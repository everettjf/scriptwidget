package com.everettjf.scriptwidget.core.ai

/**
 * What changed between two versions of a widget's code, line by line. Port of
 * `AISourceDiff`. Computed on the device; nothing is sent anywhere.
 */
object AiSourceDiff {
    enum class Kind { SAME, ADDED, REMOVED, SKIPPED }

    /** One line to show. For [Kind.SKIPPED], [skipped] unchanged lines are left out and [text] is empty. */
    data class Line(val kind: Kind, val text: String, val skipped: Int = 0)

    data class Summary(val added: Int, val removed: Int) {
        val isEmpty: Boolean get() = added == 0 && removed == 0
    }

    /** Unchanged lines kept around a change. */
    const val CONTEXT_LINES = 3
    /** Above this many lines on a side the comparison is not made; the caller shows the code instead. */
    const val MAX_LINES = 4_000
    /** The changed middle parts may hold this many line pairs. */
    private const val MAX_CELLS = 4_000_000L

    fun split(text: String): List<String> {
        val lines = text.replace("\r\n", "\n").split("\n")
        return if (lines.lastOrNull() == "") lines.dropLast(1) else lines
    }

    /** How many lines were added and removed; null when a side is too long to compare. */
    fun summary(old: String, new: String): Summary? {
        val all = fullLines(old, new) ?: return null
        return Summary(all.count { it.kind == Kind.ADDED }, all.count { it.kind == Kind.REMOVED })
    }

    /** The changed lines with a few unchanged ones around them; null when a side is too long. */
    fun lines(old: String, new: String, context: Int = CONTEXT_LINES): List<Line>? {
        val all = fullLines(old, new) ?: return null
        if (all.none { it.kind != Kind.SAME }) return emptyList()
        val keep = BooleanArray(all.size)
        all.forEachIndexed { index, line ->
            if (line.kind != Kind.SAME) for (near in maxOf(0, index - context)..minOf(all.size - 1, index + context)) keep[near] = true
        }
        val result = ArrayList<Line>()
        var skipped = 0
        fun flush() { if (skipped > 0) result += Line(Kind.SKIPPED, "", skipped); skipped = 0 }
        all.forEachIndexed { index, line -> if (keep[index]) { flush(); result += line } else skipped += 1 }
        flush()
        return result
    }

    private fun fullLines(old: String, new: String): List<Line>? {
        val before = split(old)
        val after = split(new)
        if (before.size > MAX_LINES || after.size > MAX_LINES) return null
        // What both sides start and end with needs no comparison.
        var head = 0
        while (head < before.size && head < after.size && before[head] == after[head]) head += 1
        var tail = 0
        while (tail < before.size - head && tail < after.size - head && before[before.size - 1 - tail] == after[after.size - 1 - tail]) tail += 1
        val a = before.subList(head, before.size - tail)
        val b = after.subList(head, after.size - tail)
        if (a.size.toLong() * b.size.toLong() > MAX_CELLS) return null

        // Longest common subsequence of the middle parts.
        val table = Array(a.size + 1) { IntArray(b.size + 1) }
        for (i in a.indices.reversed()) for (j in b.indices.reversed()) {
            table[i][j] = if (a[i] == b[j]) table[i + 1][j + 1] + 1 else maxOf(table[i + 1][j], table[i][j + 1])
        }
        val result = ArrayList<Line>(before.size + after.size)
        for (index in 0 until head) result += Line(Kind.SAME, after[index])
        var i = 0
        var j = 0
        while (i < a.size || j < b.size) {
            when {
                i < a.size && j < b.size && a[i] == b[j] -> { result += Line(Kind.SAME, b[j]); i += 1; j += 1 }
                i < a.size && (j >= b.size || table[i + 1][j] >= table[i][j + 1]) -> { result += Line(Kind.REMOVED, a[i]); i += 1 }
                else -> { result += Line(Kind.ADDED, b[j]); j += 1 }
            }
        }
        for (index in after.size - tail until after.size) result += Line(Kind.SAME, after[index])
        return result
    }
}
