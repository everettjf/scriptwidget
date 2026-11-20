using System.Globalization;

namespace ScriptWidget.Core.AI;

/// <summary>Loose authoring checks, using the generated Studio surface. The runtime remains authoritative.</summary>
public static class AiJsxCheck
{
    private static readonly Dictionary<string, HashSet<string>?> Globals = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, Dictionary<string, HashSet<string>?>> Surface = new(StringComparer.Ordinal);
    private static readonly HashSet<string> Leaves = new(StringComparer.Ordinal);
    private static readonly HashSet<string> Alignments = ["center", "leading", "trailing", "top", "bottom", "topLeading", "topTrailing", "bottomLeading", "bottomTrailing"];
    private static readonly HashSet<string> Keywords = ["return", "yield", "case", "default", "await", "else", "do", "in", "of", "typeof", "void", "delete", "new", "throw"];
    private sealed record Attribute(string Name, string? Literal);
    private sealed record Tag(string Name, List<Attribute> Attributes, int End, bool SelfClosing);

    static AiJsxCheck()
    {
        KeyValuePair<string, HashSet<string>?> AttributeOf(string word)
        {
            var at = word.IndexOf('=');
            return at < 0 ? new(word, null) : new(word[..at], word[(at + 1)..].Split('|').ToHashSet(StringComparer.Ordinal));
        }
        foreach (var line in AiJsxSurfaceData.Text.Split('\n'))
        {
            var words = line.Split(' ', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
            if (words.Length < 2) continue;
            if (words[0] == "global") { var entry = AttributeOf(words[1]); Globals[entry.Key] = entry.Value; }
            else if (words[0] == "leaf") foreach (var name in words.Skip(1)) Leaves.Add(name);
            else if (words[0] is "tag" or "tag@windows") Surface[words[1]] = words.Skip(2).Select(AttributeOf).ToDictionary(entry => entry.Key, entry => entry.Value, StringComparer.Ordinal);
        }
    }

    public const string FrameHelp = "Write it without spaces as max, max,leading, 60, 60,40, 60,40,leading, max,40, max,40,leading, 60,max or 60,max,leading. There is no auto; max,leading fills both directions.";
    public static bool FrameIsRead(string value)
    {
        bool Number(string text) => text.Length > 0 && text.Any(char.IsAsciiDigit) && text.Count(character => character == '.') <= 1 &&
            text.Select((character, index) => char.IsAsciiDigit(character) || character == '.' || index == 0 && character is '+' or '-').All(valid => valid) &&
            double.TryParse(text, NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var number) && double.IsFinite(number);
        var parts = value.Split(',');
        return parts.Length switch
        {
            1 => parts[0] == "max" || Number(parts[0]),
            2 => Number(parts[0]) ? Number(parts[1]) || parts[1] == "max" : parts[0] == "max" && (Number(parts[1]) || parts[1] == "max" || Alignments.Contains(parts[1])),
            3 => Alignments.Contains(parts[2]) && (Number(parts[0]) && (Number(parts[1]) || parts[1] == "max") || parts[0] == "max" && Number(parts[1])),
            _ => false,
        };
    }

    public static IReadOnlyList<string> Problems(string source)
    {
        var found = new List<string>();
        void Add(string text) { if (found.Count < 5 && !found.Contains(text, StringComparer.Ordinal)) found.Add(text); }
        foreach (var tag in Tags(source))
        {
            if (found.Count >= 5) break;
            if (tag.Name[0] is not (>= 'a' and <= 'z') || tag.Name.Contains('.')) continue;
            if (!Surface.TryGetValue(tag.Name, out var own)) { Add($"<{tag.Name}> is not a ScriptWidget tag. The tags are: {string.Join(", ", Surface.Keys)}."); continue; }
            if (Leaves.Contains(tag.Name) && !tag.SelfClosing && FirstTagInside(source, tag.End) is { } inner)
                Add($"<{tag.Name}> takes no tags inside it, so the <{inner}> in it is not shown. Put it next to the <{tag.Name}>, not in it.");
            foreach (var attribute in tag.Attributes)
            {
                if (!own.ContainsKey(attribute.Name) && !Globals.ContainsKey(attribute.Name))
                { Add($"<{tag.Name}> has no attribute \"{attribute.Name}\"; it would be ignored. Its attributes are: {string.Join(", ", own.Keys.Concat(Globals.Keys).Distinct())}."); continue; }
                if (attribute.Literal is not { } value) continue;
                if (attribute.Name == "frame" && !FrameIsRead(value)) { Add($"frame=\"{value}\" on <{tag.Name}> is not a frame ScriptWidget reads; it would be ignored or centered. {FrameHelp}"); continue; }
                var allowed = own.GetValueOrDefault(attribute.Name) ?? Globals.GetValueOrDefault(attribute.Name);
                if (allowed is not null && !allowed.Contains(value)) Add($"{attribute.Name}=\"{value}\" on <{tag.Name}> is not one of its values; it would be ignored. Use one of: {string.Join(", ", allowed)}.");
            }
        }
        return found;
    }

    public static string? Summary(string source) => Problems(source) is { Count: > 0 } problems ? "The code uses tags or attributes that ScriptWidget does not have:\n" + string.Join('\n', problems.Select(problem => "- " + problem)) : null;
    private static bool Letter(char character) => char.IsAsciiLetter(character);
    private static bool Word(char character) => Letter(character) || char.IsAsciiDigit(character) || character is '_' or '$';
    private static bool Name(char character) => Letter(character) || char.IsAsciiDigit(character) || character is '.' or '_';

    private static IEnumerable<Tag> Tags(string text)
    {
        var index = 0;
        while (index < text.Length)
        {
            var character = text[index];
            if (character == '/' && index + 1 < text.Length && text[index + 1] == '/')
            { var next = text.IndexOf('\n', index); index = next < 0 ? text.Length : next; }
            else if (character == '/' && index + 1 < text.Length && text[index + 1] == '*')
            { var next = text.IndexOf("*/", index + 2, StringComparison.Ordinal); index = next < 0 ? text.Length : next + 2; }
            else if (character is '\'' or '"' or '`') index = SkipQuoted(text, index, character != '`');
            else if (character == '<' && index + 1 < text.Length && Letter(text[index + 1]) && StartsTag(text, index) && ReadTag(text, index + 1) is { } tag)
            { yield return tag; index = tag.End; }
            else index++;
        }
    }

    private static bool StartsTag(string text, int at)
    {
        var before = at - 1;
        while (before >= 0 && char.IsWhiteSpace(text[before])) before--;
        if (before < 0) return true;
        if (text[before] is ')' or ']') return false;
        if (!Word(text[before])) return true;
        var start = before;
        while (start >= 0 && Word(text[start])) start--;
        return Keywords.Contains(text[(start + 1)..(before + 1)]);
    }

    private static Tag? ReadTag(string text, int from)
    {
        var index = from;
        while (index < text.Length && Name(text[index])) index++;
        var name = text[from..index];
        var attributes = new List<Attribute>();
        while (index < text.Length)
        {
            while (index < text.Length && char.IsWhiteSpace(text[index])) index++;
            if (index >= text.Length) return null;
            if (text[index] == '>') return new Tag(name, attributes, index + 1, false);
            if (text[index] == '/') return index + 1 < text.Length && text[index + 1] == '>' ? new Tag(name, attributes, index + 2, true) : null;
            if (text[index] == '{') { if (SkipBraces(text, index) is not { } next) return null; index = next; continue; }
            if (!Letter(text[index]) && text[index] != '_') return null;
            var start = index;
            while (index < text.Length && (Letter(text[index]) || char.IsAsciiDigit(text[index]) || text[index] is '_' or '-' or ':')) index++;
            var attribute = text[start..index];
            while (index < text.Length && char.IsWhiteSpace(text[index])) index++;
            if (index >= text.Length || text[index] != '=') { attributes.Add(new Attribute(attribute, null)); continue; }
            index++;
            while (index < text.Length && char.IsWhiteSpace(text[index])) index++;
            if (index >= text.Length) return null;
            if (text[index] is '\'' or '"')
            {
                var end = text.IndexOf(text[index], index + 1);
                if (end < 0) return null;
                attributes.Add(new Attribute(attribute, text[(index + 1)..end])); index = end + 1;
            }
            else if (text[index] == '{')
            {
                if (SkipBraces(text, index) is not { } end) return null;
                var inner = text[(index + 1)..(end - 1)].Trim();
                var literal = inner.Length >= 2 && inner[0] is '\'' or '"' && inner[^1] == inner[0] && !inner[1..^1].Contains(inner[0]) ? inner[1..^1] : null;
                attributes.Add(new Attribute(attribute, literal)); index = end;
            }
            else return null;
        }
        return null;
    }

    private static string? FirstTagInside(string text, int from)
    {
        var index = from;
        while (index < text.Length)
        {
            if (text[index] == '{') { if (SkipBraces(text, index) is not { } next) return null; index = next; }
            else if (text[index] == '<')
            {
                if (index + 1 >= text.Length || !Letter(text[index + 1])) return null;
                var end = index + 1;
                while (end < text.Length && Name(text[end])) end++;
                return text[(index + 1)..end];
            }
            else index++;
        }
        return null;
    }

    private static int? SkipBraces(string text, int from)
    {
        var depth = 0;
        var index = from;
        while (index < text.Length)
        {
            if (text[index] == '{') { depth++; index++; }
            else if (text[index] == '}') { depth--; index++; if (depth == 0) return index; }
            else if (text[index] is '\'' or '"' or '`') index = SkipQuoted(text, index, text[index] != '`');
            else index++;
        }
        return null;
    }

    private static int SkipQuoted(string text, int from, bool sameLine)
    {
        for (var index = from + 1; index < text.Length; index++)
        {
            if (text[index] == '\\') { index++; continue; }
            if (text[index] == text[from]) return index + 1;
            if (sameLine && text[index] == '\n') return from + 1;
        }
        return from + 1;
    }
}
