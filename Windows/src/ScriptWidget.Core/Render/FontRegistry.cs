using System.Collections.Concurrent;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI.Text;

namespace ScriptWidget.Core.Render;

/// <summary>
/// One resolved face: the DirectWrite family string, the weight, and the
/// ascent and descent of the font as fractions of its size.
/// </summary>
public sealed record Typeface(string Family, int Weight, float Ascent, float Descent);

/// <summary>
/// Resolves the CSS font-family strings the shared renderer emits to
/// DirectWrite families. The default face is the bundled Inter, so layout is
/// the same on every device; Chinese text and emoji fall back to the system
/// fonts through DirectWrite (Noto Sans SC is not shipped on Windows).
/// <see cref="UseSystemFont"/> switches the default face to Segoe UI.
/// </summary>
public sealed class FontRegistry
{
    public const string SystemFamily = "Segoe UI";
    private const string MonospaceFamily = "Consolas";
    private const string SerifFamily = "Georgia";

    private readonly string directory;
    private readonly ConcurrentDictionary<string, Typeface> cache = new();
    private volatile bool useSystemFont;

    /// <param name="directory">Folder with Inter.ttf and the display fonts; defaults to <c>assets/fonts</c> next to the program.</param>
    public FontRegistry(string? directory = null)
    {
        this.directory = directory ?? Path.Combine(AppContext.BaseDirectory, "assets", "fonts");
    }

    /// <summary>When true, default-design text uses the device's own sans-serif face.</summary>
    public bool UseSystemFont { get => useSystemFont; set => useSystemFont = value; }

    /// <summary>Bundled display fonts selectable with <c>font="custom,&lt;name&gt;,&lt;size&gt;"</c>: file and the family name inside it.</summary>
    private static readonly Dictionary<string, (string File, string Family)> CustomFonts = new()
    {
        ["apple ]["] = ("Apple ][.ttf", "Apple ]["), ["apple"] = ("Apple ][.ttf", "Apple ]["),
        ["larabiefont free"] = ("Larabiefont Free.ttf", "Larabiefont Free"), ["larabiefontfree"] = ("Larabiefont Free.ttf", "Larabiefont Free"),
        ["monofonto"] = ("Monofonto.ttf", "Monofonto"),
        ["white rabbit"] = ("New.ttf", "White Rabbit"), ["whiterabbit"] = ("New.ttf", "White Rabbit"), ["new"] = ("New.ttf", "White Rabbit"),
        ["oneslot"] = ("OneSlot.ttf", "OneSlot"),
        ["unispace"] = ("Unispace.ttf", "Unispace"),
    };

    public Typeface Typeface(string family, int weight)
    {
        var clamped = Math.Clamp(weight, 100, 900);
        var key = $"{useSystemFont}|{family}|{clamped}";
        return cache.GetOrAdd(key, _ => Resolve(family, clamped));
    }

    private Typeface Resolve(string family, int weight)
    {
        var comma = family.IndexOf(',');
        var first = (comma < 0 ? family : family[..comma]).Trim().Trim('"');
        var lower = first.ToLowerInvariant();
        if (CustomFonts.TryGetValue(lower, out var custom))
        {
            // A display font has one face; its weight is not synthesized, as on Android.
            return FontFile(custom.File, custom.Family, 400) ?? Bundled(weight);
        }
        if (lower == "ui-monospace" || lower.Contains("mono") || lower == "consolas") return SystemFace(MonospaceFamily, weight);
        if (lower == "new york" || lower == "ui-serif") return SystemFace(SerifFamily, weight);
        if (useSystemFont) return SystemFace(SystemFamily, weight);
        return Bundled(weight);
    }

    /// <summary>Inter is a variable font; DirectWrite picks its named instance nearest to the weight.</summary>
    private Typeface Bundled(int weight) => FontFile("Inter.ttf", "Inter", weight) ?? SystemFace(SystemFamily, weight);

    /// <summary>
    /// A font file next to the program. Win2D loads it from the family string
    /// <c>&lt;absolute path&gt;#&lt;family name&gt;</c>, which works in an unpackaged process.
    /// </summary>
    private Typeface? FontFile(string file, string family, int weight)
    {
        var path = Path.Combine(directory, file);
        if (!System.IO.File.Exists(path)) return null;
        try
        {
            using var fonts = new CanvasFontSet(new Uri(path));
            var faces = fonts.Fonts;
            if (faces.Count == 0) return null;
            var face = faces.OrderBy(item => Math.Abs(item.Weight.Weight - weight)).First();
            var result = new Typeface($"{path}#{family}", weight, face.Ascent, face.Descent);
            foreach (var item in faces) item.Dispose();
            return result;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static Typeface SystemFace(string family, int weight)
    {
        try
        {
            using var fonts = CanvasFontSet.GetSystemFontSet();
            using var matching = fonts.GetMatchingFonts(family, new FontWeight((ushort)weight), FontStretch.Normal, FontStyle.Normal);
            var faces = matching.Fonts;
            if (faces.Count > 0)
            {
                var result = new Typeface(family, weight, faces[0].Ascent, faces[0].Descent);
                foreach (var item in faces) item.Dispose();
                return result;
            }
        }
        catch (Exception)
        {
            // Fall through to typical metrics; the text is still measured and drawn with the same layout.
        }
        return new Typeface(family, weight, 1.079f, 0.251f);
    }
}
