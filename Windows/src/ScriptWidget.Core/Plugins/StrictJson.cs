using System.Globalization;
using System.Text;

namespace ScriptWidget.Core.Plugins;

/// <summary>
/// RFC 8259 JSON reader and writer for untrusted plugin manifests and data source responses.
///
/// Lenient readers accept unquoted strings, single quotes, comments and trailing text, and
/// platforms disagree on number types and duplicate keys. A manifest that one platform reads and
/// another refuses is not a contract, so manifests are parsed here: exactly one JSON value,
/// nothing after it, no raw control characters, bounded nesting.
/// </summary>
internal static class StrictJson
{
    /// <summary>Deepest container nesting accepted; <c>JSONSerialization</c> on Apple platforms stops at 512 as well.</summary>
    public const int MaximumDepth = 512;

    /// <summary>What a document's top-level value is, for callers that only validate.</summary>
    public enum Kind { Object, Array, String, Number, Boolean, Null }

    public sealed class JsonException(string message) : Exception(message);

    /// <summary>
    /// Parses <paramref name="text"/> into <c>Dictionary&lt;string, object?&gt;</c>, <c>List&lt;object?&gt;</c>,
    /// <c>string</c>, <c>long</c>, <c>double</c>, <c>bool</c> and <c>null</c>.
    ///
    /// A repeated object key is rejected unless <paramref name="allowDuplicateKeys"/>: two values for one key let
    /// a validator and a later reader disagree about what the document says.
    /// </summary>
    public static object? Parse(string text, bool allowDuplicateKeys = false) => new Reader(text, true, allowDuplicateKeys).Document();

    /// <summary>Checks that <paramref name="text"/> is one well-formed JSON value without building it, and returns its kind.</summary>
    public static Kind Validate(string text)
    {
        var reader = new Reader(text, false, true);
        reader.Document();
        return reader.TopLevel;
    }

    /// <summary>JSON string literal for <paramref name="value"/>. Slashes are not escaped, like <c>.withoutEscapingSlashes</c> in Swift.</summary>
    public static string Quote(string value)
    {
        var output = new StringBuilder(value.Length + 2).Append('"');
        foreach (var character in value)
        {
            switch (character)
            {
                case '"': output.Append("\\\""); break;
                case '\\': output.Append("\\\\"); break;
                case '\n': output.Append("\\n"); break;
                case '\r': output.Append("\\r"); break;
                case '\t': output.Append("\\t"); break;
                case '\b': output.Append("\\b"); break;
                case '\f': output.Append("\\f"); break;
                default:
                    if (character < ' ' || character == '\u2028' || character == '\u2029') output.Append("\\u").Append(((int)character).ToString("x4", CultureInfo.InvariantCulture));
                    else output.Append(character);
                    break;
            }
        }
        return output.Append('"').ToString();
    }

    private sealed class Reader(string text, bool build, bool allowDuplicateKeys)
    {
        private int index;
        public Kind TopLevel { get; private set; }

        public object? Document()
        {
            SkipWhitespace();
            TopLevel = KindAt();
            var result = Value(0);
            SkipWhitespace();
            if (index != text.Length) throw Fail("Unexpected text after the JSON value");
            return result;
        }

        private Kind KindAt() => Peek() switch
        {
            '{' => Kind.Object,
            '[' => Kind.Array,
            '"' => Kind.String,
            't' or 'f' => Kind.Boolean,
            'n' => Kind.Null,
            _ => Kind.Number,
        };

        private object? Value(int depth)
        {
            if (depth > MaximumDepth) throw Fail("JSON is nested too deeply");
            return Peek() switch
            {
                '{' => ObjectValue(depth),
                '[' => ArrayValue(depth),
                '"' => String(),
                't' => Literal("true", true),
                'f' => Literal("false", false),
                'n' => Literal("null", null),
                _ => Number(),
            };
        }

        private object? ObjectValue(int depth)
        {
            index += 1;
            var result = build ? new Dictionary<string, object?>(StringComparer.Ordinal) : null;
            var seen = !allowDuplicateKeys ? new HashSet<string>(StringComparer.Ordinal) : null;
            SkipWhitespace();
            if (Peek() == '}') { index += 1; return result; }
            while (true)
            {
                SkipWhitespace();
                if (Peek() != '"') throw Fail("Expected an object key");
                var key = String();
                if (seen is not null && !seen.Add(key)) throw Fail($"Duplicate object key {key}");
                SkipWhitespace();
                if (Peek() != ':') throw Fail("Expected ':' after an object key");
                index += 1;
                SkipWhitespace();
                var member = Value(depth + 1);
                if (result is not null) result[key] = member;
                SkipWhitespace();
                switch (Peek())
                {
                    case ',': index += 1; break;
                    case '}': index += 1; return result;
                    default: throw Fail("Expected ',' or '}' in an object");
                }
            }
        }

        private object? ArrayValue(int depth)
        {
            index += 1;
            var result = build ? new List<object?>() : null;
            SkipWhitespace();
            if (Peek() == ']') { index += 1; return result; }
            while (true)
            {
                SkipWhitespace();
                var member = Value(depth + 1);
                result?.Add(member);
                SkipWhitespace();
                switch (Peek())
                {
                    case ',': index += 1; break;
                    case ']': index += 1; return result;
                    default: throw Fail("Expected ',' or ']' in an array");
                }
            }
        }

        private string String()
        {
            index += 1;
            var output = new StringBuilder();
            while (true)
            {
                if (index >= text.Length) throw Fail("Unterminated string");
                var character = text[index];
                index += 1;
                if (character == '"') return output.ToString();
                if (character < ' ') throw Fail("Control character in a string");
                if (character != '\\') { output.Append(character); continue; }
                if (index >= text.Length) throw Fail("Unterminated escape");
                var escape = text[index];
                index += 1;
                switch (escape)
                {
                    case '"' or '\\' or '/': output.Append(escape); break;
                    case 'b': output.Append('\b'); break;
                    case 'f': output.Append('\f'); break;
                    case 'n': output.Append('\n'); break;
                    case 'r': output.Append('\r'); break;
                    case 't': output.Append('\t'); break;
                    case 'u':
                    {
                        if (index + 4 > text.Length) throw Fail("Truncated unicode escape");
                        var code = 0;
                        for (var count = 0; count < 4; count++)
                        {
                            var digit = HexDigit(text[index]);
                            if (digit < 0) throw Fail("Invalid unicode escape");
                            code = code * 16 + digit;
                            index += 1;
                        }
                        output.Append((char)code);
                        break;
                    }
                    default: throw Fail("Invalid escape");
                }
            }
        }

        /// <summary>
        /// <c>Character.digit(c, 16)</c> of the Android implementation: besides ASCII it accepts every
        /// Unicode decimal digit and the full-width Latin letters A to F.
        /// </summary>
        private static int HexDigit(char character)
        {
            if (character is >= '0' and <= '9') return character - '0';
            if (character is >= 'a' and <= 'f') return character - 'a' + 10;
            if (character is >= 'A' and <= 'F') return character - 'A' + 10;
            if (character is >= '\uFF21' and <= '\uFF26') return character - '\uFF21' + 10;
            if (character is >= '\uFF41' and <= '\uFF46') return character - '\uFF41' + 10;
            return character > '\u007F' ? CharUnicodeInfo.GetDecimalDigitValue(character) : -1;
        }

        private object Number()
        {
            var start = index;
            if (Peek() == '-') index += 1;
            if (Peek() == '0') index += 1;
            else if (Peek() is >= '1' and <= '9') Digits();
            else throw Fail("Unexpected character");
            var integral = true;
            if (Peek() == '.') { integral = false; index += 1; Digits(); }
            if (Peek() is 'e' or 'E')
            {
                integral = false;
                index += 1;
                if (Peek() is '+' or '-') index += 1;
                Digits();
            }
            var literal = text[start..index];
            if (integral && long.TryParse(literal, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var whole)) return whole;
            return double.Parse(literal, NumberStyles.Float, CultureInfo.InvariantCulture);
        }

        private void Digits()
        {
            var start = index;
            while (Peek() is >= '0' and <= '9') index += 1;
            if (index == start) throw Fail("Expected a digit");
        }

        private object? Literal(string word, object? value)
        {
            if (string.CompareOrdinal(text, index, word, 0, word.Length) != 0) throw Fail("Unexpected character");
            index += word.Length;
            return value;
        }

        private void SkipWhitespace()
        {
            while (index < text.Length && text[index] is ' ' or '\n' or '\r' or '\t') index += 1;
        }

        /// <summary>The current character, or NUL at the end (NUL is never valid outside a string).</summary>
        private char Peek() => index < text.Length ? text[index] : '\0';

        private JsonException Fail(string message) => new($"{message} at offset {index}");
    }
}
