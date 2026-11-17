using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json.Nodes;

namespace ScriptWidget.Core.Runtime;

/// <summary>
/// ICU-backed implementation of the Intl subset installed by the QuickJS host
/// file. QuickJS has no Intl; JavaScriptCore on iPhone and the Android host
/// format with ICU as well, so the same skeletons produce matching text for
/// the same locale data. This calls the ICU that ships with Windows (icu.dll)
/// rather than .NET's own formatting, which words dates and numbers differently.
/// </summary>
public static unsafe class IntlBridge
{
    /// <summary>Overrides the system locale and time zone; used by deterministic tests.</summary>
    public static volatile string? LocaleOverride;
    private static volatile string? timeZoneOverride;

    public static string? TimeZoneOverride
    {
        get => timeZoneOverride;
        set { timeZoneOverride = value; Js.QuickJs.SetTimeZone(value); }
    }

    public static string DefaultLocaleTag() => LocaleOverride ?? (CultureInfo.CurrentCulture.Name is { Length: > 0 } name ? name : "en-US");

    /// <summary>IANA name of the zone local time is shown in.</summary>
    public static string DefaultTimeZone()
    {
        if (timeZoneOverride is { } zone) return zone;
        var local = TimeZoneInfo.Local.Id;
        return TimeZoneInfo.TryConvertWindowsIdToIanaId(local, out var iana) ? iana : local;
    }

    public static bool Handles(string operation) => operation.StartsWith("intl.", StringComparison.Ordinal);

    private static readonly object Gate = new();

    /// <summary>Returns null when <paramref name="operation"/> is not an Intl operation.</summary>
    public static string? Call(string operation, string? payload)
    {
        switch (operation)
        {
            case "intl.locale": return DefaultLocaleTag();
            case "intl.timeZone": return DefaultTimeZone();
            case "intl.validZone": return IsValidZone(payload ?? "") ? "1" : "0";
        }
        if (!Handles(operation)) return null;
        var request = Json.ParseObject(payload ?? throw new ArgumentException("Missing Intl request"));
        lock (Gate)
        {
            return operation switch
            {
                "intl.date" => FormatDate(request),
                "intl.dateParts" => Json.Stringify(DateParts(request)),
                "intl.number" => FormatNumber(request),
                "intl.plural" => Plural(request),
                "intl.relative" => Relative(request),
                "intl.compare" => Compare(request),
                "intl.list" => List(request),
                _ => null,
            };
        }
    }

    // MARK: - Locales and zones

    /// <summary>ICU locale ID ("en_US") as NUL-terminated bytes for a BCP 47 tag ("en-US").</summary>
    private static byte[] Locale(string tag)
    {
        var input = Encoding.ASCII.GetBytes(tag.Replace('_', '-') + "\0");
        var output = new byte[160];
        var status = 0;
        int length;
        fixed (byte* source = input)
        fixed (byte* target = output)
            length = Icu.uloc_forLanguageTag(source, target, output.Length - 1, null, &status);
        if (status > 0 || length <= 0) return "en_US\0"u8.ToArray();
        return output;
    }

    private static string RequiredLocale(JsonObject request) => request.OptStringOrNull("locale") ?? throw new ArgumentException("Missing locale");

    private static bool IsValidZone(string id)
    {
        if (id.Equals("UTC", StringComparison.OrdinalIgnoreCase) || id.Equals("GMT", StringComparison.OrdinalIgnoreCase)) return true;
        if (id.Length == 0 || id.Length > 100) return false;
        var buffer = stackalloc char[128];
        var status = 0;
        byte system = 0;
        fixed (char* chars = id) Icu.ucal_getCanonicalTimeZoneID(chars, id.Length, buffer, 128, &system, &status);
        return status <= 0 && system != 0;
    }

    private static void Check(int status, string what)
    {
        if (status > 0) throw new ArgumentException($"{what} failed (ICU error {status})");
    }

    private delegate int Fill(char* buffer, int capacity, int* status);

    /// <summary>Runs an ICU call that writes UTF-16 into a buffer, growing the buffer once when it is too small.</summary>
    private static string Text(Fill fill, string what)
    {
        var capacity = 256;
        while (true)
        {
            var buffer = new char[capacity];
            var status = 0;
            int length;
            fixed (char* chars = buffer) length = fill(chars, capacity, &status);
            if (status == Icu.BufferOverflow && capacity < 1 << 20) { capacity = Math.Max(length + 1, capacity * 2); continue; }
            Check(status, what);
            return new string(buffer, 0, Math.Min(length, capacity));
        }
    }

    // MARK: - Dates

    /// <summary>Building an ICU formatter is far more expensive than using one; planners format thousands of dates.</summary>
    private static readonly Dictionary<string, nint> FormatCache = new();
    private static readonly LinkedList<string> FormatOrder = new();

    private static nint DateFormat(JsonObject request)
    {
        var options = request.OptObject("options") ?? new JsonObject();
        var key = RequiredLocale(request) + "|" + DefaultTimeZone() + "|" + Json.Stringify(options);
        if (FormatCache.TryGetValue(key, out var cached))
        {
            FormatOrder.Remove(key);
            FormatOrder.AddLast(key);
            return cached;
        }
        var created = CreateDateFormat(request, options);
        FormatCache[key] = created;
        FormatOrder.AddLast(key);
        if (FormatCache.Count > 32)
        {
            var eldest = FormatOrder.First!.Value;
            FormatOrder.RemoveFirst();
            Icu.udat_close(FormatCache[eldest]);
            FormatCache.Remove(eldest);
        }
        return created;
    }

    private static nint CreateDateFormat(JsonObject request, JsonObject options)
    {
        var locale = Locale(RequiredLocale(request));
        var zone = options.OptString("timeZone") is { Length: > 0 } requested ? requested : DefaultTimeZone();
        var dateStyle = Style(options.OptString("dateStyle"));
        var timeStyle = Style(options.OptString("timeStyle"));
        var status = 0;
        nint format;
        fixed (byte* localeID = locale)
        fixed (char* zoneID = zone)
        {
            if (dateStyle is not null || timeStyle is not null)
            {
                format = Icu.udat_open(timeStyle ?? Icu.StyleNone, dateStyle ?? Icu.StyleNone, localeID, zoneID, zone.Length, null, 0, &status);
            }
            else
            {
                var skeleton = Skeleton(options);
                var generator = Icu.udatpg_open(localeID, &status);
                Check(status, "Date pattern generator");
                string pattern;
                try
                {
                    pattern = Text((buffer, capacity, error) => { fixed (char* chars = skeleton) return Icu.udatpg_getBestPattern(generator, chars, skeleton.Length, buffer, capacity, error); }, "Date pattern");
                }
                finally { Icu.udatpg_close(generator); }
                pattern = ApplyHourWidth(pattern, options.OptString("hour"));
                fixed (char* chars = pattern) format = Icu.udat_open(Icu.StylePattern, Icu.StylePattern, localeID, zoneID, zone.Length, chars, pattern.Length, &status);
            }
        }
        Check(status, "Date format");
        return format;
    }

    /// <summary>
    /// ECMA-402 keeps the requested hour width even when the locale pattern
    /// for the skeleton uses another one ("2-digit" gives "08:00 PM" in en-US).
    /// </summary>
    private static string ApplyHourWidth(string pattern, string hour)
    {
        int width;
        switch (hour) { case "2-digit": width = 2; break; case "numeric": width = 1; break; default: return pattern; }
        var result = new StringBuilder();
        var index = 0;
        var quoted = false;
        while (index < pattern.Length)
        {
            var character = pattern[index];
            if (character == '\'') { quoted = !quoted; result.Append(character); index += 1; continue; }
            if (!quoted && "hHkK".Contains(character))
            {
                var end = index;
                while (end < pattern.Length && pattern[end] == character) end += 1;
                result.Append(character, width);
                index = end;
                continue;
            }
            result.Append(character);
            index += 1;
        }
        return result.ToString();
    }

    private static int? Style(string name) => name switch { "full" => 0, "long" => 1, "medium" => 2, "short" => 3, _ => null };

    /// <summary>Maps ECMA-402 date options to an ICU skeleton.</summary>
    private static string Skeleton(JsonObject options)
    {
        var text = new StringBuilder();
        void Width(string name, char letter, int narrow = 5)
        {
            switch (options.OptString(name))
            {
                case "narrow": text.Append(letter, narrow); break;
                case "short": text.Append(letter, 3); break;
                case "long": text.Append(letter, 4); break;
                case "numeric": text.Append(letter); break;
                case "2-digit": text.Append(letter, 2); break;
            }
        }
        switch (options.OptString("era")) { case "narrow": text.Append("GGGGG"); break; case "short": text.Append('G'); break; case "long": text.Append("GGGG"); break; }
        Width("year", 'y');
        Width("month", 'M');
        switch (options.OptString("weekday")) { case "narrow": text.Append("EEEEE"); break; case "short": text.Append("EEE"); break; case "long": text.Append("EEEE"); break; }
        Width("day", 'd');
        var hour = options.OptString("hour");
        if (hour.Length > 0)
        {
            var letter = options.Has("hourCycle") ? options.OptString("hourCycle") switch { "h11" => 'K', "h12" => 'h', "h23" => 'H', "h24" => 'k', _ => 'j' }
                : options.Has("hour12") ? (options.OptBoolean("hour12") ? 'h' : 'H')
                : 'j';
            text.Append(letter, hour == "2-digit" ? 2 : 1);
        }
        switch (options.OptString("dayPeriod")) { case "narrow": text.Append("BBBBB"); break; case "short": text.Append('B'); break; case "long": text.Append("BBBB"); break; }
        if (options.OptString("minute").Length > 0) text.Append(options.OptString("minute") == "2-digit" ? "mm" : "m");
        if (options.OptString("second").Length > 0) text.Append(options.OptString("second") == "2-digit" ? "ss" : "s");
        var fraction = options.OptInt("fractionalSecondDigits");
        if (fraction is >= 1 and <= 3) text.Append('S', fraction);
        switch (options.OptString("timeZoneName"))
        {
            case "short": text.Append('z'); break;
            case "long": text.Append("zzzz"); break;
            case "shortOffset": text.Append('O'); break;
            case "longOffset": text.Append("OOOO"); break;
            case "shortGeneric": text.Append('v'); break;
            case "longGeneric": text.Append("vvvv"); break;
        }
        return text.ToString();
    }

    private static double Time(JsonObject request)
    {
        var time = request.OptDouble("time");
        if (double.IsNaN(time)) throw new ArgumentException("Invalid time value");
        return Math.Truncate(time);
    }

    private static string FormatDate(JsonObject request)
    {
        var format = DateFormat(request);
        var time = Time(request);
        return NormalizeSpaces(Text((buffer, capacity, status) => Icu.udat_format(format, time, buffer, capacity, null, status), "Date format"));
    }

    /// <summary>ICU 72+ separates the day period with U+202F; JavaScriptCore emits a plain space for compatibility.</summary>
    private static string NormalizeSpaces(string text) => text.Replace(' ', ' ');

    private static string PartName(int field) => field switch
    {
        0 => "era",
        1 or 18 or 20 or 30 or 34 => "year",
        2 or 26 => "month",
        3 => "day",
        9 or 19 or 25 => "weekday",
        4 or 5 or 15 or 16 => "hour",
        6 => "minute",
        7 => "second",
        8 => "fractionalSecond",
        14 or 35 or 36 => "dayPeriod",
        17 or 23 or 24 or 29 or 31 or 32 or 33 => "timeZoneName",
        _ => "literal",
    };

    private static JsonArray DateParts(JsonObject request)
    {
        var format = DateFormat(request);
        var time = Time(request);
        var status = 0;
        var iterator = Icu.ufieldpositer_open(&status);
        Check(status, "Date parts");
        var fields = new List<(int Start, int End, int Field)>();
        string text;
        try
        {
            text = Text((buffer, capacity, error) => Icu.udat_formatForFields(format, time, buffer, capacity, iterator, error), "Date parts");
            // The iterator holds the fields of the last successful call.
            int start, end, field;
            while ((field = Icu.ufieldpositer_next(iterator, &start, &end)) >= 0) fields.Add((start, end, field));
        }
        finally { Icu.ufieldpositer_close(iterator); }
        fields.Sort((left, right) => left.Start != right.Start ? left.Start.CompareTo(right.Start) : right.End.CompareTo(left.End));
        var parts = new JsonArray();
        void Add(string type, int start, int end)
        {
            if (end > start) parts.Append(new JsonObject { ["type"] = type, ["value"] = NormalizeSpaces(text[start..end]) });
        }
        var index = 0;
        foreach (var (start, end, field) in fields)
        {
            if (start < index || end > text.Length) continue;
            Add("literal", index, start);
            Add(PartName(field), start, end);
            index = end;
        }
        Add("literal", index, text.Length);
        return parts;
    }

    // MARK: - Numbers

    private static string FormatNumber(JsonObject request)
    {
        var locale = Locale(RequiredLocale(request));
        var options = request.OptObject("options") ?? new JsonObject();
        var raw = request.OptString("value");
        var value = raw switch
        {
            "Infinity" => double.PositiveInfinity,
            "-Infinity" => double.NegativeInfinity,
            _ => double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : double.NaN,
        };
        if (double.IsNaN(value)) return "NaN";
        if (double.IsInfinity(value)) return value > 0 ? "∞" : "-∞";

        var style = options.OptString("style") is { Length: > 0 } requested ? requested : "decimal";
        var skeleton = new StringBuilder();
        var defaultMinimum = 0;
        var defaultMaximum = 3;
        switch (style)
        {
            case "percent":
                skeleton.Append("percent scale/100 ");
                defaultMaximum = 0;
                break;
            case "currency":
            {
                var currency = (options.OptString("currency") is { Length: > 0 } code ? code : "USD").ToUpperInvariant();
                if (currency.Length != 3 || !currency.All(char.IsAsciiLetter)) throw new ArgumentException($"Invalid currency code {currency}");
                skeleton.Append("currency/").Append(currency).Append(' ');
                var status = 0;
                int digits;
                fixed (char* chars = currency) digits = Icu.ucurr_getDefaultFractionDigits(chars, &status);
                if (status > 0) digits = 2;
                defaultMinimum = digits;
                defaultMaximum = digits;
                switch (options.OptString("currencyDisplay"))
                {
                    case "code": skeleton.Append("unit-width-iso-code "); break;
                    case "name": skeleton.Append("unit-width-full-name "); break;
                    case "narrowSymbol": skeleton.Append("unit-width-narrow "); break;
                }
                break;
            }
        }
        switch (options.OptString("notation"))
        {
            case "compact": skeleton.Append(options.OptString("compactDisplay") == "long" ? "compact-long " : "compact-short "); break;
            case "scientific": skeleton.Append("scientific "); break;
            case "engineering": skeleton.Append("engineering "); break;
        }
        var compact = options.OptString("notation") == "compact";
        if (options.Has("minimumSignificantDigits") || options.Has("maximumSignificantDigits"))
        {
            var minimum = Math.Clamp(options.OptInt("minimumSignificantDigits", 1), 1, 21);
            var maximum = Math.Clamp(options.OptInt("maximumSignificantDigits", 21), minimum, 21);
            skeleton.Append('@', minimum).Append('#', maximum - minimum).Append(' ');
        }
        else if (options.Has("minimumFractionDigits") || options.Has("maximumFractionDigits") || !compact)
        {
            var minimum = Math.Clamp(options.OptInt("minimumFractionDigits", Math.Min(defaultMinimum, options.OptInt("maximumFractionDigits", defaultMinimum))), 0, 100);
            var maximum = Math.Clamp(options.OptInt("maximumFractionDigits", Math.Max(defaultMaximum, minimum)), minimum, 100);
            if (maximum == 0) skeleton.Append("precision-integer ");
            else skeleton.Append('.').Append('0', minimum).Append('#', maximum - minimum).Append(' ');
        }
        if (options.Has("minimumIntegerDigits")) skeleton.Append("integer-width/*").Append('0', Math.Clamp(options.OptInt("minimumIntegerDigits", 1), 1, 21)).Append(' ');
        if (options.Has("useGrouping") && !options.OptBoolean("useGrouping", true)) skeleton.Append("group-off ");
        switch (options.OptString("signDisplay"))
        {
            case "always": skeleton.Append("sign-always "); break;
            case "never": skeleton.Append("sign-never "); break;
            case "exceptZero": skeleton.Append("sign-except-zero "); break;
        }

        var skeletonText = skeleton.ToString().TrimEnd();
        var error = 0;
        nint formatter;
        fixed (char* chars = skeletonText)
        fixed (byte* localeID = locale)
            formatter = Icu.unumf_openForSkeletonAndLocale(chars, skeletonText.Length, localeID, &error);
        Check(error, "Number format");
        var result = Icu.unumf_openResult(&error);
        try
        {
            Check(error, "Number format");
            // The exact decimal expansion of the double, like BigDecimal(value) on Android.
            var digits = Encoding.ASCII.GetBytes(value.ToString("E60", CultureInfo.InvariantCulture));
            fixed (byte* decimalText = digits) Icu.unumf_formatDecimal(formatter, decimalText, digits.Length, result, &error);
            Check(error, "Number format");
            return Text((buffer, capacity, status) => Icu.unumf_resultToString(result, buffer, capacity, status), "Number format");
        }
        finally
        {
            if (result != 0) Icu.unumf_closeResult(result);
            Icu.unumf_close(formatter);
        }
    }

    private static string Plural(JsonObject request)
    {
        var locale = Locale(RequiredLocale(request));
        var status = 0;
        nint rules;
        fixed (byte* localeID = locale) rules = Icu.uplrules_openForType(localeID, request.OptString("type") == "ordinal" ? 1 : 0, &status);
        Check(status, "Plural rules");
        try
        {
            var value = request.OptDouble("value");
            return Text((buffer, capacity, error) => Icu.uplrules_select(rules, value, buffer, capacity, error), "Plural rules");
        }
        finally { Icu.uplrules_close(rules); }
    }

    private static string Relative(JsonObject request)
    {
        var options = request.OptObject("options") ?? new JsonObject();
        var style = options.OptString("style") switch { "short" => 1, "narrow" => 2, _ => 0 };
        var name = request.OptString("unit");
        var unit = (name.EndsWith('s') ? name[..^1] : name) switch
        {
            "year" => 0, "quarter" => 1, "month" => 2, "week" => 3, "day" => 4, "hour" => 5, "minute" => 6, "second" => 7,
            _ => throw new ArgumentException("Invalid unit argument for format()"),
        };
        var locale = Locale(RequiredLocale(request));
        var status = 0;
        nint formatter;
        fixed (byte* localeID = locale) formatter = Icu.ureldatefmt_open(localeID, 0, style, Icu.CapitalizationNone, &status);
        Check(status, "Relative time format");
        try
        {
            var value = request.OptDouble("value");
            return options.OptString("numeric") == "auto"
                ? Text((buffer, capacity, error) => Icu.ureldatefmt_format(formatter, value, unit, buffer, capacity, error), "Relative time format")
                : Text((buffer, capacity, error) => Icu.ureldatefmt_formatNumeric(formatter, value, unit, buffer, capacity, error), "Relative time format");
        }
        finally { Icu.ureldatefmt_close(formatter); }
    }

    private static string Compare(JsonObject request)
    {
        var locale = Locale(RequiredLocale(request));
        var left = request.OptString("left");
        var right = request.OptString("right");
        var status = 0;
        nint collator;
        fixed (byte* localeID = locale) collator = Icu.ucol_open(localeID, &status);
        Check(status, "Collator");
        try
        {
            int result;
            fixed (char* first = left)
            fixed (char* second = right)
                result = Icu.ucol_strcoll(collator, first, left.Length, second, right.Length);
            return Math.Clamp(result, -1, 1).ToString(CultureInfo.InvariantCulture);
        }
        finally { Icu.ucol_close(collator); }
    }

    private static string List(JsonObject request)
    {
        var items = (request.OptArray("items") ?? new JsonArray()).Select(item => item?.AsText() ?? "").ToArray();
        var options = request.OptObject("options") ?? new JsonObject();
        var type = options.OptString("type") switch { "disjunction" => 1, "unit" => 2, _ => 0 };
        var width = options.OptString("style") switch { "short" => 1, "narrow" => 2, _ => 0 };
        if (items.Length == 0) return "";
        var locale = Locale(RequiredLocale(request));
        var status = 0;
        nint formatter;
        fixed (byte* localeID = locale) formatter = Icu.ulistfmt_openForType(localeID, type, width, &status);
        Check(status, "List format");
        var handles = new GCHandle[items.Length];
        try
        {
            var pointers = new nint[items.Length];
            var lengths = new int[items.Length];
            for (var index = 0; index < items.Length; index++)
            {
                handles[index] = GCHandle.Alloc(items[index], GCHandleType.Pinned);
                pointers[index] = handles[index].AddrOfPinnedObject();
                lengths[index] = items[index].Length;
            }
            return Text((buffer, capacity, error) =>
            {
                fixed (nint* strings = pointers)
                fixed (int* sizes = lengths)
                    return Icu.ulistfmt_format(formatter, (char**)strings, sizes, items.Length, buffer, capacity, error);
            }, "List format");
        }
        finally
        {
            foreach (var handle in handles) if (handle.IsAllocated) handle.Free();
            Icu.ulistfmt_close(formatter);
        }
    }

    /// <summary>The ICU C API that ships with Windows 10 1903 and later.</summary>
    private static class Icu
    {
        private const string Library = "icu.dll";
        public const int BufferOverflow = 15;
        public const int StyleNone = -1;
        public const int StylePattern = -2;
        public const int CapitalizationNone = 256;

        [DllImport(Library)] public static extern int uloc_forLanguageTag(byte* tag, byte* localeID, int capacity, int* parsedLength, int* status);
        [DllImport(Library)] public static extern int ucal_getCanonicalTimeZoneID(char* id, int length, char* result, int capacity, byte* isSystemID, int* status);

        [DllImport(Library)] public static extern nint udat_open(int timeStyle, int dateStyle, byte* locale, char* zone, int zoneLength, char* pattern, int patternLength, int* status);
        [DllImport(Library)] public static extern void udat_close(nint format);
        [DllImport(Library)] public static extern int udat_format(nint format, double date, char* result, int capacity, void* position, int* status);
        [DllImport(Library)] public static extern int udat_formatForFields(nint format, double date, char* result, int capacity, nint iterator, int* status);
        [DllImport(Library)] public static extern nint ufieldpositer_open(int* status);
        [DllImport(Library)] public static extern void ufieldpositer_close(nint iterator);
        [DllImport(Library)] public static extern int ufieldpositer_next(nint iterator, int* begin, int* end);
        [DllImport(Library)] public static extern nint udatpg_open(byte* locale, int* status);
        [DllImport(Library)] public static extern void udatpg_close(nint generator);
        [DllImport(Library)] public static extern int udatpg_getBestPattern(nint generator, char* skeleton, int length, char* pattern, int capacity, int* status);

        [DllImport(Library)] public static extern nint unumf_openForSkeletonAndLocale(char* skeleton, int length, byte* locale, int* status);
        [DllImport(Library)] public static extern void unumf_close(nint formatter);
        [DllImport(Library)] public static extern nint unumf_openResult(int* status);
        [DllImport(Library)] public static extern void unumf_closeResult(nint result);
        [DllImport(Library)] public static extern void unumf_formatDecimal(nint formatter, byte* value, int length, nint result, int* status);
        [DllImport(Library)] public static extern int unumf_resultToString(nint result, char* buffer, int capacity, int* status);
        [DllImport(Library)] public static extern int ucurr_getDefaultFractionDigits(char* currency, int* status);

        [DllImport(Library)] public static extern nint uplrules_openForType(byte* locale, int type, int* status);
        [DllImport(Library)] public static extern void uplrules_close(nint rules);
        [DllImport(Library)] public static extern int uplrules_select(nint rules, double number, char* keyword, int capacity, int* status);

        [DllImport(Library)] public static extern nint ureldatefmt_open(byte* locale, nint numberFormat, int width, int capitalization, int* status);
        [DllImport(Library)] public static extern void ureldatefmt_close(nint formatter);
        [DllImport(Library)] public static extern int ureldatefmt_format(nint formatter, double offset, int unit, char* result, int capacity, int* status);
        [DllImport(Library)] public static extern int ureldatefmt_formatNumeric(nint formatter, double offset, int unit, char* result, int capacity, int* status);

        [DllImport(Library)] public static extern nint ucol_open(byte* locale, int* status);
        [DllImport(Library)] public static extern void ucol_close(nint collator);
        [DllImport(Library)] public static extern int ucol_strcoll(nint collator, char* source, int sourceLength, char* target, int targetLength);

        [DllImport(Library)] public static extern nint ulistfmt_openForType(byte* locale, int type, int width, int* status);
        [DllImport(Library)] public static extern void ulistfmt_close(nint formatter);
        [DllImport(Library)] public static extern int ulistfmt_format(nint formatter, char** strings, int* lengths, int count, char* result, int capacity, int* status);
    }
}
