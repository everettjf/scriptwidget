package com.everettjf.scriptwidget.core.runtime

import android.icu.number.Notation
import android.icu.number.NumberFormatter
import android.icu.number.Precision
import android.icu.text.Collator
import android.icu.text.DateFormat
import android.icu.text.DateTimePatternGenerator
import android.icu.text.ListFormatter
import android.icu.text.PluralRules
import android.icu.text.RelativeDateTimeFormatter
import android.icu.text.SimpleDateFormat
import android.icu.util.Currency
import android.icu.util.TimeZone
import android.icu.util.ULocale
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigDecimal
import java.text.FieldPosition
import java.util.Date

/**
 * ICU-backed implementation of the Intl subset installed by android-host.js.
 * QuickJS has no Intl; JavaScriptCore on iPhone formats with ICU as well, so
 * the same skeletons produce matching text for the same locale data.
 */
object IntlBridge {
    /** Overrides the device locale and time zone; used by deterministic tests. */
    @Volatile var localeOverride: String? = null
    @Volatile var timeZoneOverride: String? = null

    fun defaultLocaleTag(): String = localeOverride ?: ULocale.getDefault().toLanguageTag()
    fun defaultTimeZone(): String = timeZoneOverride ?: TimeZone.getDefault().id

    /** Returns null when [operation] is not an Intl operation. */
    fun call(operation: String, payload: String?): String? = when (operation) {
        "intl.locale" -> defaultLocaleTag()
        "intl.timeZone" -> defaultTimeZone()
        "intl.validZone" -> if (isValidZone(payload.orEmpty())) "1" else "0"
        "intl.date" -> JSONObject(payload!!).let { formatDate(it).toString() }
        "intl.dateParts" -> JSONObject(payload!!).let { dateParts(it).toString() }
        "intl.number" -> formatNumber(JSONObject(payload!!))
        "intl.plural" -> plural(JSONObject(payload!!))
        "intl.relative" -> relative(JSONObject(payload!!))
        "intl.compare" -> compare(JSONObject(payload!!))
        "intl.list" -> list(JSONObject(payload!!))
        else -> null
    }

    fun handles(operation: String): Boolean = operation.startsWith("intl.")

    private fun locale(tag: String): ULocale = ULocale.forLanguageTag(tag.replace('_', '-'))

    private fun isValidZone(id: String): Boolean {
        if (id.equals("UTC", ignoreCase = true) || id.equals("GMT", ignoreCase = true)) return true
        return TimeZone.getCanonicalID(id) != null && TimeZone.getTimeZone(id).id != TimeZone.UNKNOWN_ZONE_ID
    }

    /** Building an ICU formatter is far more expensive than using one; planners format thousands of dates. */
    private val formatCache = object : LinkedHashMap<String, DateFormat>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, DateFormat>?): Boolean = size > 32
    }

    private fun dateFormat(request: JSONObject): DateFormat {
        val options = request.optJSONObject("options") ?: JSONObject()
        val key = request.getString("locale") + "|" + defaultTimeZone() + "|" + options.toString()
        synchronized(formatCache) { formatCache[key]?.let { return it.clone() as DateFormat } }
        return createDateFormat(request, options).also { created -> synchronized(formatCache) { formatCache[key] = created.clone() as DateFormat } }
    }

    private fun createDateFormat(request: JSONObject, options: JSONObject): DateFormat {
        val locale = locale(request.getString("locale"))
        val zone = TimeZone.getTimeZone(options.optString("timeZone").ifEmpty { defaultTimeZone() })
        val dateStyle = style(options.optString("dateStyle"))
        val timeStyle = style(options.optString("timeStyle"))
        val format: DateFormat = if (dateStyle != null || timeStyle != null) {
            when {
                dateStyle != null && timeStyle != null -> DateFormat.getDateTimeInstance(dateStyle, timeStyle, locale)
                dateStyle != null -> DateFormat.getDateInstance(dateStyle, locale)
                else -> DateFormat.getTimeInstance(timeStyle!!, locale)
            }
        } else {
            val pattern = DateTimePatternGenerator.getInstance(locale).getBestPattern(skeleton(options))
            SimpleDateFormat(applyHourWidth(pattern, options.optString("hour")), locale)
        }
        format.timeZone = zone
        return format
    }

    /**
     * ECMA-402 keeps the requested hour width even when the locale pattern
     * for the skeleton uses another one ("2-digit" gives "08:00 PM" in en-US).
     */
    private fun applyHourWidth(pattern: String, hour: String): String {
        val width = when (hour) { "2-digit" -> 2; "numeric" -> 1; else -> return pattern }
        val result = StringBuilder()
        var index = 0
        var quoted = false
        while (index < pattern.length) {
            val character = pattern[index]
            if (character == '\'') { quoted = !quoted; result.append(character); index += 1; continue }
            if (!quoted && character in "hHkK") {
                var end = index
                while (end < pattern.length && pattern[end] == character) end += 1
                repeat(width) { result.append(character) }
                index = end
                continue
            }
            result.append(character)
            index += 1
        }
        return result.toString()
    }

    private fun style(name: String): Int? = when (name) {
        "full" -> DateFormat.FULL
        "long" -> DateFormat.LONG
        "medium" -> DateFormat.MEDIUM
        "short" -> DateFormat.SHORT
        else -> null
    }

    /** Maps ECMA-402 date options to an ICU skeleton. */
    private fun skeleton(options: JSONObject): String {
        val text = StringBuilder()
        fun width(name: String, letter: Char, narrow: Int = 5) {
            when (options.optString(name)) {
                "narrow" -> repeat(narrow) { text.append(letter) }
                "short" -> repeat(3) { text.append(letter) }
                "long" -> repeat(4) { text.append(letter) }
                "numeric" -> text.append(letter)
                "2-digit" -> repeat(2) { text.append(letter) }
            }
        }
        when (options.optString("era")) { "narrow" -> text.append("GGGGG"); "short" -> text.append("G"); "long" -> text.append("GGGG") }
        width("year", 'y')
        width("month", 'M')
        when (options.optString("weekday")) { "narrow" -> text.append("EEEEE"); "short" -> text.append("EEE"); "long" -> text.append("EEEE") }
        width("day", 'd')
        val hour = options.optString("hour")
        if (hour.isNotEmpty()) {
            val letter = when {
                options.has("hourCycle") -> when (options.optString("hourCycle")) { "h11" -> 'K'; "h12" -> 'h'; "h23" -> 'H'; "h24" -> 'k'; else -> 'j' }
                options.has("hour12") -> if (options.optBoolean("hour12")) 'h' else 'H'
                else -> 'j'
            }
            repeat(if (hour == "2-digit") 2 else 1) { text.append(letter) }
        }
        when (options.optString("dayPeriod")) { "narrow" -> text.append("BBBBB"); "short" -> text.append("B"); "long" -> text.append("BBBB") }
        if (options.optString("minute").isNotEmpty()) text.append(if (options.optString("minute") == "2-digit") "mm" else "m")
        if (options.optString("second").isNotEmpty()) text.append(if (options.optString("second") == "2-digit") "ss" else "s")
        val fraction = options.optInt("fractionalSecondDigits", 0)
        if (fraction in 1..3) repeat(fraction) { text.append('S') }
        when (options.optString("timeZoneName")) {
            "short" -> text.append("z"); "long" -> text.append("zzzz")
            "shortOffset" -> text.append("O"); "longOffset" -> text.append("OOOO")
            "shortGeneric" -> text.append("v"); "longGeneric" -> text.append("vvvv")
        }
        return text.toString()
    }

    private fun formatDate(request: JSONObject): String =
        normalizeSpaces(dateFormat(request).format(Date(request.getDouble("time").toLong())))

    /** ICU 72+ separates the day period with U+202F; JavaScriptCore emits a plain space for compatibility. */
    private fun normalizeSpaces(text: String): String = text.replace('\u202F', ' ')

    private val partNames = mapOf(
        DateFormat.Field.ERA to "era", DateFormat.Field.YEAR to "year", DateFormat.Field.MONTH to "month",
        DateFormat.Field.DAY_OF_MONTH to "day", DateFormat.Field.DAY_OF_WEEK to "weekday",
        DateFormat.Field.HOUR_OF_DAY0 to "hour", DateFormat.Field.HOUR_OF_DAY1 to "hour",
        DateFormat.Field.HOUR0 to "hour", DateFormat.Field.HOUR1 to "hour",
        DateFormat.Field.MINUTE to "minute", DateFormat.Field.SECOND to "second",
        DateFormat.Field.MILLISECOND to "fractionalSecond", DateFormat.Field.AM_PM to "dayPeriod",
        DateFormat.Field.TIME_ZONE to "timeZoneName",
    )

    private fun dateParts(request: JSONObject): JSONArray {
        val format = dateFormat(request)
        val iterator = format.formatToCharacterIterator(Date(request.getDouble("time").toLong()))
        val text = StringBuilder()
        var character = iterator.first()
        while (character != java.text.CharacterIterator.DONE) { text.append(character); character = iterator.next() }
        val parts = JSONArray()
        var index = 0
        while (index < text.length) {
            iterator.index = index
            val end = iterator.runLimit
            val field = iterator.attributes.keys.firstOrNull { it is DateFormat.Field }
            parts.put(JSONObject().put("type", partNames[field] ?: "literal").put("value", normalizeSpaces(text.substring(index, end))))
            index = end
        }
        return parts
    }

    private fun formatNumber(request: JSONObject): String {
        val locale = locale(request.getString("locale"))
        val options = request.optJSONObject("options") ?: JSONObject()
        val raw = request.getString("value")
        val value = raw.toDoubleOrNull() ?: Double.NaN
        if (value.isNaN()) return "NaN"
        if (value.isInfinite()) return if (value > 0) "∞" else "-∞"
        val style = options.optString("style").ifEmpty { "decimal" }
        var formatter = NumberFormatter.withLocale(locale)
        var defaultMinimum = 0
        var defaultMaximum = 3
        when (style) {
            "percent" -> { formatter = formatter.unit(android.icu.util.MeasureUnit.PERCENT).scale(android.icu.number.Scale.powerOfTen(2)); defaultMaximum = 0 }
            "currency" -> {
                val currency = Currency.getInstance(options.optString("currency").ifEmpty { "USD" }.uppercase())
                formatter = formatter.unit(currency)
                defaultMinimum = currency.defaultFractionDigits
                defaultMaximum = currency.defaultFractionDigits
                when (options.optString("currencyDisplay")) {
                    "code" -> formatter = formatter.unitWidth(NumberFormatter.UnitWidth.ISO_CODE)
                    "name" -> formatter = formatter.unitWidth(NumberFormatter.UnitWidth.FULL_NAME)
                    "narrowSymbol" -> formatter = formatter.unitWidth(NumberFormatter.UnitWidth.NARROW)
                }
            }
        }
        when (options.optString("notation")) {
            "compact" -> formatter = formatter.notation(if (options.optString("compactDisplay") == "long") Notation.compactLong() else Notation.compactShort())
            "scientific" -> formatter = formatter.notation(Notation.scientific())
            "engineering" -> formatter = formatter.notation(Notation.engineering())
        }
        val compact = options.optString("notation") == "compact"
        formatter = if (options.has("minimumSignificantDigits") || options.has("maximumSignificantDigits")) {
            val minimum = options.optInt("minimumSignificantDigits", 1).coerceIn(1, 21)
            val maximum = options.optInt("maximumSignificantDigits", 21).coerceIn(minimum, 21)
            formatter.precision(Precision.minMaxSignificantDigits(minimum, maximum))
        } else if (options.has("minimumFractionDigits") || options.has("maximumFractionDigits") || !compact) {
            val minimum = options.optInt("minimumFractionDigits", minOf(defaultMinimum, options.optInt("maximumFractionDigits", defaultMinimum))).coerceIn(0, 100)
            val maximum = options.optInt("maximumFractionDigits", maxOf(defaultMaximum, minimum)).coerceIn(minimum, 100)
            formatter.precision(Precision.minMaxFraction(minimum, maximum))
        } else formatter
        if (options.has("minimumIntegerDigits")) {
            formatter = formatter.integerWidth(android.icu.number.IntegerWidth.zeroFillTo(options.optInt("minimumIntegerDigits", 1).coerceIn(1, 21)))
        }
        if (options.has("useGrouping")) {
            val grouping = options.opt("useGrouping")
            if (grouping == false || grouping == "false") formatter = formatter.grouping(NumberFormatter.GroupingStrategy.OFF)
        }
        when (options.optString("signDisplay")) {
            "always" -> formatter = formatter.sign(NumberFormatter.SignDisplay.ALWAYS)
            "never" -> formatter = formatter.sign(NumberFormatter.SignDisplay.NEVER)
            "exceptZero" -> formatter = formatter.sign(NumberFormatter.SignDisplay.EXCEPT_ZERO)
        }
        return formatter.format(BigDecimal(value)).toString()
    }

    private fun plural(request: JSONObject): String {
        val type = if (request.optString("type") == "ordinal") PluralRules.PluralType.ORDINAL else PluralRules.PluralType.CARDINAL
        return PluralRules.forLocale(locale(request.getString("locale")), type).select(request.getDouble("value"))
    }

    private fun relative(request: JSONObject): String {
        val options = request.optJSONObject("options") ?: JSONObject()
        val style = when (options.optString("style")) {
            "short" -> RelativeDateTimeFormatter.Style.SHORT
            "narrow" -> RelativeDateTimeFormatter.Style.NARROW
            else -> RelativeDateTimeFormatter.Style.LONG
        }
        val formatter = RelativeDateTimeFormatter.getInstance(locale(request.getString("locale")), null, style, android.icu.text.DisplayContext.CAPITALIZATION_NONE)
        val unit = when (request.getString("unit").removeSuffix("s")) {
            "second" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.SECOND
            "minute" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.MINUTE
            "hour" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.HOUR
            "day" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.DAY
            "week" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.WEEK
            "month" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.MONTH
            "quarter" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.QUARTER
            "year" -> RelativeDateTimeFormatter.RelativeDateTimeUnit.YEAR
            else -> throw IllegalArgumentException("Invalid unit argument for format()")
        }
        val value = request.getDouble("value")
        return if (options.optString("numeric") == "auto") formatter.format(value, unit) else formatter.formatNumeric(value, unit)
    }

    private fun compare(request: JSONObject): String =
        Collator.getInstance(locale(request.getString("locale"))).compare(request.getString("left"), request.getString("right")).coerceIn(-1, 1).toString()

    private fun list(request: JSONObject): String {
        val items = request.getJSONArray("items").let { array -> List(array.length()) { array.getString(it) } }
        val options = request.optJSONObject("options") ?: JSONObject()
        val type = when (options.optString("type")) {
            "disjunction" -> ListFormatter.Type.OR
            "unit" -> ListFormatter.Type.UNITS
            else -> ListFormatter.Type.AND
        }
        val width = when (options.optString("style")) {
            "short" -> ListFormatter.Width.SHORT
            "narrow" -> ListFormatter.Width.NARROW
            else -> ListFormatter.Width.WIDE
        }
        return ListFormatter.getInstance(locale(request.getString("locale")), type, width).format(items)
    }

    @Suppress("unused") private val unusedFieldPosition = FieldPosition(0)
}
