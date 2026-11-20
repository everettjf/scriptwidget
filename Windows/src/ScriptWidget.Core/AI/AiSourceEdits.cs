namespace ScriptWidget.Core.AI;

public sealed record AiSourceEdit(string Search, string Replace);
public sealed class AiException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>Exact SEARCH/REPLACE blocks. A partial or ambiguous edit never changes the current source.</summary>
public static class AiSourceEdits
{
    public const string SearchMarker = "<<<<<<< SEARCH", DividerMarker = "=======", ReplaceMarker = ">>>>>>> REPLACE";
    public static string Normalize(string text) => text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n');
    public static IReadOnlyList<AiSourceEdit>? Parse(string reply)
    {
        var lines = Normalize(reply).Split('\n');
        if (!lines.Any(line => line.Trim() == SearchMarker)) return null;
        var edits = new List<AiSourceEdit>();
        List<string>? search = null, replace = null;
        foreach (var line in lines)
        {
            var marker = line.Trim();
            if (marker == SearchMarker)
            {
                if (search is not null) throw new AiException("invalid_edit", "An edit starts before the previous block ends.");
                search = [];
            }
            else if (marker == DividerMarker && search is not null && replace is null) replace = [];
            else if (marker == ReplaceMarker)
            {
                if (search is null || replace is null) throw new AiException("invalid_edit", "An edit has no SEARCH part or divider.");
                var from = string.Join('\n', search);
                if (string.IsNullOrWhiteSpace(from)) throw new AiException("invalid_edit", "An edit has nothing to search for.");
                edits.Add(new AiSourceEdit(from, string.Join('\n', replace)));
                if (edits.Count > 20) throw new AiException("invalid_edit", "There are more than 20 edit blocks.");
                search = null;
                replace = null;
            }
            else if (replace is not null) replace.Add(line);
            else search?.Add(line);
        }
        if (search is not null) throw new AiException("invalid_edit", "The last edit block has no REPLACE line.");
        return edits;
    }

    public static string Apply(IReadOnlyList<AiSourceEdit> edits, string source)
    {
        var text = Normalize(source);
        foreach (var edit in edits)
        {
            if (string.IsNullOrWhiteSpace(edit.Search)) throw new AiException("invalid_edit", "An edit has nothing to search for.");
            var at = text.IndexOf(edit.Search, StringComparison.Ordinal);
            if (at < 0) throw new AiException("invalid_edit", "The SEARCH text is not in the current code; copy it exactly with its indentation.");
            if (text.IndexOf(edit.Search, at + edit.Search.Length, StringComparison.Ordinal) >= 0) throw new AiException("invalid_edit", "The SEARCH text occurs more than once; include neighbouring lines.");
            text = text[..at] + edit.Replace + text[(at + edit.Search.Length)..];
        }
        return text.TrimEnd('\n', ' ', '\t') + "\n";
    }
}

public enum AiDiffKind { Same, Added, Removed, Skipped }
public sealed record AiDiffLine(AiDiffKind Kind, string Text, int Skipped = 0);

/// <summary>A bounded line diff between adjacent versions, computed locally.</summary>
public static class AiSourceDiff
{
    public static IReadOnlyList<AiDiffLine>? Lines(string before, string after)
    {
        string[] Split(string text)
        {
            var lines = AiSourceEdits.Normalize(text).Split('\n');
            return lines.Length > 0 && lines[^1] == "" ? lines[..^1] : lines;
        }
        var a = Split(before);
        var b = Split(after);
        if (a.Length > 4000 || b.Length > 4000) return null;
        var head = 0;
        while (head < a.Length && head < b.Length && a[head] == b[head]) head++;
        var tail = 0;
        while (tail < a.Length - head && tail < b.Length - head && a[^(tail + 1)] == b[^(tail + 1)]) tail++;
        var m = a.Length - head - tail;
        var n = b.Length - head - tail;
        if ((long)m * n > 4000000) return null;
        var table = new int[m + 1, n + 1];
        for (var i = m - 1; i >= 0; i--) for (var j = n - 1; j >= 0; j--)
            table[i, j] = a[head + i] == b[head + j] ? table[i + 1, j + 1] + 1 : Math.Max(table[i + 1, j], table[i, j + 1]);
        var full = new List<AiDiffLine>();
        for (var i = 0; i < head; i++) full.Add(new(AiDiffKind.Same, a[i]));
        var x = 0;
        var y = 0;
        while (x < m || y < n)
        {
            if (x < m && y < n && a[head + x] == b[head + y]) { full.Add(new(AiDiffKind.Same, b[head + y])); x++; y++; }
            else if (x < m && (y >= n || table[x + 1, y] >= table[x, y + 1])) full.Add(new(AiDiffKind.Removed, a[head + x++]));
            else full.Add(new(AiDiffKind.Added, b[head + y++]));
        }
        for (var i = b.Length - tail; i < b.Length; i++) full.Add(new(AiDiffKind.Same, b[i]));
        if (full.All(line => line.Kind == AiDiffKind.Same)) return [];
        var keep = new bool[full.Count];
        for (var i = 0; i < full.Count; i++) if (full[i].Kind != AiDiffKind.Same)
            for (var j = Math.Max(0, i - 3); j <= Math.Min(full.Count - 1, i + 3); j++) keep[j] = true;
        var result = new List<AiDiffLine>();
        var skipped = 0;
        for (var i = 0; i < full.Count; i++)
        {
            if (!keep[i]) { skipped++; continue; }
            if (skipped > 0) { result.Add(new(AiDiffKind.Skipped, "", skipped)); skipped = 0; }
            result.Add(full[i]);
        }
        if (skipped > 0) result.Add(new(AiDiffKind.Skipped, "", skipped));
        return result;
    }
}
