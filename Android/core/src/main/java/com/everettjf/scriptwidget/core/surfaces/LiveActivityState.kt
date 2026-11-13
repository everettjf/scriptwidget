package com.everettjf.scriptwidget.core.surfaces

import com.everettjf.scriptwidget.core.plugin.StrictJson
import java.time.OffsetDateTime
import java.time.format.DateTimeFormatter

/** A validated Live Activity state. Every field is optional; [json] is the text that was validated. */
class LiveActivityState(
    val title: String?,
    val detail: String?,
    val progress: Int?,
    val total: Int?,
    /** Deadline in epoch milliseconds. */
    val endsAt: Long?,
    val json: String,
)

/** A state that breaks the documented contract. The message never repeats the supplied data. */
class LiveActivityStateException(val code: String, message: String) : Exception(message)

/** What the system notification template shows for a state at one moment. */
class LiveUpdateContent(
    val title: String,
    val text: String,
    /** Progress out of [total], or null to show no bar. */
    val progress: Int?,
    val total: Int?,
    /** Deadline to count down to, or null when there is none or it has passed. */
    val countdownTo: Long?,
)

/**
 * The Live Activity state contract shared with iOS: `title` (1–40
 * characters), `detail` (up to 80), integer `progress` and `total`
 * (0 ≤ progress ≤ total, 1 ≤ total ≤ 10000, declared together) and a
 * timezone-qualified ISO `endsAt`, in at most 4 KiB of UTF-8.
 */
object LiveActivityStates {
    const val MAXIMUM_BYTES = 4096
    const val MAXIMUM_TITLE = 40
    const val MAXIMUM_DETAIL = 80
    const val MAXIMUM_TOTAL = 10000
    /** Shown instead of the detail once the deadline has passed, as on iOS. */
    const val EXPIRED_TEXT = "Time is up"

    private val keys = setOf("title", "detail", "progress", "total", "endsAt")
    private val zoned = Regex("^\\d{4}-\\d{2}-\\d{2}T.*(?:Z|[+-]\\d{2}:\\d{2})$")

    /**
     * Validates state JSON. Blank text is the empty state.
     * @throws LiveActivityStateException with a code of `too_large`, `invalid_json`, `unknown_field`,
     * `invalid_title`, `invalid_detail`, `invalid_progress` or `invalid_deadline`.
     */
    fun parse(text: String): LiveActivityState {
        if (text.toByteArray(Charsets.UTF_8).size > MAXIMUM_BYTES) fail("too_large", "State must fit in 4 KiB of UTF-8.")
        if (text.isBlank()) return LiveActivityState(null, null, null, null, null, "")
        val parsed = try { StrictJson.parse(text) } catch (_: Exception) { fail("invalid_json", "State must be a JSON object.") }
        val data = parsed as? Map<*, *> ?: fail("invalid_json", "State must be a JSON object.")
        if (data.keys.any { it !in keys }) fail("unknown_field", "Only title, detail, progress, total and endsAt are supported.")

        val title = data["title"]?.let { it as? String ?: fail("invalid_title", "title must be text of 1–40 characters.") }
            ?: if (data.containsKey("title")) fail("invalid_title", "title must be text of 1–40 characters.") else null
        // UTF-16 length, the unit the shared template checks, so a state accepted here is accepted on iOS.
        if (title != null && (title.isEmpty() || title.length > MAXIMUM_TITLE)) fail("invalid_title", "title must be text of 1–40 characters.")
        val detail = data["detail"]?.let { it as? String ?: fail("invalid_detail", "detail must be text of at most 80 characters.") }
            ?: if (data.containsKey("detail")) fail("invalid_detail", "detail must be text of at most 80 characters.") else null
        if (detail != null && detail.length > MAXIMUM_DETAIL) fail("invalid_detail", "detail must be text of at most 80 characters.")

        var progress: Int? = null
        var total: Int? = null
        if (data.containsKey("progress") || data.containsKey("total")) {
            val message = "progress and total must be whole numbers with 0 ≤ progress ≤ total and 1 ≤ total ≤ 10000."
            total = integer(data["total"]) ?: fail("invalid_progress", message)
            progress = integer(data["progress"]) ?: fail("invalid_progress", message)
            if (total < 1 || total > MAXIMUM_TOTAL || progress < 0 || progress > total) fail("invalid_progress", message)
        }

        var endsAt: Long? = null
        if (data.containsKey("endsAt")) {
            val message = "endsAt must be an ISO date and time with a time zone, such as 2026-12-01T18:25:00Z."
            val value = data["endsAt"] as? String ?: fail("invalid_deadline", message)
            if (value.length > 64 || !zoned.matches(value)) fail("invalid_deadline", message)
            endsAt = runCatching { OffsetDateTime.parse(value, DateTimeFormatter.ISO_OFFSET_DATE_TIME).toInstant().toEpochMilli() }.getOrNull() ?: fail("invalid_deadline", message)
        }
        return LiveActivityState(title, detail, progress, total, endsAt, text)
    }

    /** The template content for [state] at [now]; [fallbackTitle] (the package name) stands in for a missing title. */
    fun content(state: LiveActivityState, fallbackTitle: String, now: Long): LiveUpdateContent {
        val expired = state.endsAt != null && state.endsAt <= now
        return LiveUpdateContent(
            title = state.title ?: fallbackTitle,
            text = if (expired) EXPIRED_TEXT else state.detail.orEmpty(),
            progress = state.progress,
            total = state.total,
            countdownTo = state.endsAt?.takeIf { !expired },
        )
    }

    /** A JSON number that is a whole value inside the Int range; booleans and text are not numbers. */
    private fun integer(value: Any?): Int? = when (value) {
        is Long -> value.takeIf { it in Int.MIN_VALUE..Int.MAX_VALUE }?.toInt()
        is Double -> value.takeIf { it.isFinite() && it == Math.floor(it) && it >= Int.MIN_VALUE && it <= Int.MAX_VALUE }?.toInt()
        else -> null
    }

    private fun fail(code: String, message: String): Nothing = throw LiveActivityStateException(code, message)
}
