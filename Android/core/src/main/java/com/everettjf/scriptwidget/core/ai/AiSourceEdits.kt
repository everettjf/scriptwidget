package com.everettjf.scriptwidget.core.ai

/** One change to a widget's source: [search] is replaced by [replace]. */
data class AiSourceEdit(val search: String, val replace: String)

/**
 * A reply that changes part of the current code instead of sending all of it.
 * Port of `AISourceEdits`; the two must read and apply the same replies in the
 * same way.
 *
 * The model writes one block per place:
 *
 *     <<<<<<< SEARCH
 *     lines copied from the current code
 *     =======
 *     the lines that replace them
 *     >>>>>>> REPLACE
 *
 * Nothing is guessed. The searched text has to be in the code exactly once;
 * otherwise the whole reply is refused and the model is asked again. What comes
 * out is run and checked like any other candidate.
 */
object AiSourceEdits {
    const val SEARCH_MARKER = "<<<<<<< SEARCH"
    const val DIVIDER_MARKER = "======="
    const val REPLACE_MARKER = ">>>>>>> REPLACE"
    const val MAX_EDITS = 20

    class Failure(val reason: String) : Exception(reason)

    /** Whether [reply] is written as edit blocks. */
    fun isEditReply(reply: String): Boolean = lines(reply).any { it.trim() == SEARCH_MARKER }

    /**
     * The edits of [reply], in order; null when it has no edit block.
     * @throws Failure for a block that is not complete, has nothing to search for, or too many blocks.
     */
    fun parse(reply: String): List<AiSourceEdit>? {
        if (!isEditReply(reply)) return null
        val edits = ArrayList<AiSourceEdit>()
        var search: ArrayList<String>? = null
        var replace: ArrayList<String>? = null
        for (line in lines(reply)) {
            val marker = line.trim()
            when {
                marker == SEARCH_MARKER -> {
                    if (search != null) throw Failure("an edit block starts before the one before it ends")
                    search = ArrayList()
                }
                marker == DIVIDER_MARKER && search != null && replace == null -> replace = ArrayList()
                marker == REPLACE_MARKER -> {
                    val from = search
                    val to = replace
                    if (from == null || to == null) throw Failure("an edit block ends without its SEARCH part and its ======= line")
                    val text = from.joinToString("\n")
                    if (text.isBlank()) throw Failure("edit ${edits.size + 1} has nothing in its SEARCH part")
                    edits += AiSourceEdit(text, to.joinToString("\n"))
                    if (edits.size > MAX_EDITS) throw Failure("there are more than $MAX_EDITS edit blocks")
                    search = null
                    replace = null
                }
                replace != null -> replace.add(line)
                search != null -> search.add(line)
            }
        }
        if (search != null) throw Failure("the last edit block has no >>>>>>> REPLACE line")
        return edits
    }

    /**
     * [source] with [edits] applied one after the other. The result ends with a line break.
     * @throws Failure when a searched text is not in the code, or is there more than once.
     */
    fun apply(edits: List<AiSourceEdit>, source: String): String {
        var text = normalized(source)
        edits.forEachIndexed { index, edit ->
            val count = occurrences(text, edit.search)
            if (count == 0) throw Failure("the SEARCH text of edit ${index + 1} is not in the current code; it has to be copied exactly, with its indentation")
            if (count > 1) throw Failure("the SEARCH text of edit ${index + 1} is in the current code $count times; add neighbouring lines so that it is there once")
            val at = text.indexOf(edit.search)
            text = text.substring(0, at) + edit.replace + text.substring(at + edit.search.length)
        }
        return text.trimEnd('\n', ' ', '\t') + "\n"
    }

    private fun normalized(text: String): String = text.replace("\r\n", "\n").replace('\r', '\n')

    private fun lines(text: String): List<String> = normalized(text).split("\n")

    private fun occurrences(text: String, part: String): Int {
        var count = 0
        var from = text.indexOf(part)
        while (from >= 0) {
            count += 1
            from = text.indexOf(part, from + part.length)
        }
        return count
    }
}
