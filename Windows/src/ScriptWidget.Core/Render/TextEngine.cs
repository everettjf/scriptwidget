using Microsoft.Graphics.Canvas;
using Microsoft.Graphics.Canvas.Brushes;
using Microsoft.Graphics.Canvas.Text;
using Windows.UI.Text;

namespace ScriptWidget.Core.Render;

/// <summary>Font description shared by measurement and drawing. Sizes are in points.</summary>
public readonly record struct TextStyle(string Family, float Size, int Weight, float Leading);

public sealed record TextLine(string Text, float Width);

/// <summary>
/// Text measurement and line breaking. The shared layout asks for sizes
/// through this class and the painter draws with it, so what was measured is
/// what gets drawn: both go through the same DirectWrite text format, with
/// natural (unhinted) glyph advances, no trimming and no pixel snapping.
/// All values are in points; the painter scales the canvas.
/// Use an instance on one thread at a time.
/// </summary>
public sealed class TextEngine(FontRegistry fonts)
{
    private readonly Dictionary<(string Family, int Weight, float Size), CanvasTextFormat> formats = new();
    /// <summary>Text layouts are device independent; any device can create them. Asked for each time, so a lost device is replaced.</summary>
    private static CanvasDevice Device => CanvasDevice.GetSharedDevice();

    /// <summary>The DirectWrite format of a style: the Windows counterpart of Android's TextPaint.</summary>
    public CanvasTextFormat Paint(TextStyle style)
    {
        var typeface = fonts.Typeface(style.Family, style.Weight);
        var size = style.Size > 0f && float.IsFinite(style.Size) ? style.Size : 0.01f;
        var key = (typeface.Family, typeface.Weight, size);
        if (formats.TryGetValue(key, out var existing)) return existing;
        if (formats.Count > MaximumFormats)
        {
            foreach (var format in formats.Values) format.Dispose();
            formats.Clear();
        }
        var created = new CanvasTextFormat
        {
            FontFamily = typeface.Family,
            FontSize = size,
            FontWeight = new FontWeight((ushort)typeface.Weight),
            FontStyle = FontStyle.Normal,
            FontStretch = FontStretch.Normal,
            WordWrapping = CanvasWordWrapping.NoWrap,
            HorizontalAlignment = CanvasHorizontalAlignment.Left,
            VerticalAlignment = CanvasVerticalAlignment.Top,
            TrimmingGranularity = CanvasTextTrimmingGranularity.None,
            // Color emoji, and glyphs placed where they were measured rather than on whole pixels.
            Options = DrawOptions,
        };
        formats[key] = created;
        return created;
    }

    /// <summary>Width of <paramref name="text"/> on one line, trailing spaces included.</summary>
    public float Measure(string text, TextStyle style)
    {
        if (text.Length == 0) return 0f;
        using var layout = new CanvasTextLayout(Device, text, Paint(style), 0f, 0f);
        return (float)layout.LayoutBoundsIncludingTrailingWhitespace.Width;
    }

    /// <summary>
    /// Lines of <paramref name="text"/> in a box <paramref name="width"/> points wide. Explicit newlines always
    /// break. With a width, text wraps like CSS <c>white-space: pre-wrap</c> with
    /// <c>overflow-wrap: break-word</c>; without one it does not wrap.
    /// </summary>
    public List<TextLine> Lines(string text, TextStyle style, float? width)
    {
        var result = new List<TextLine>();
        foreach (var paragraph in text.Split('\n'))
        {
            if (paragraph.Length == 0) { result.Add(new TextLine("", 0f)); continue; }
            var whole = Measure(paragraph, style);
            if (width is not { } limit || whole <= limit + 0.01f)
            {
                result.Add(new TextLine(paragraph, whole));
                continue;
            }
            // Break at word boundaries, and inside a word only when the word alone does not fit.
            // Every line gets the same height, so the line a point falls on is known without asking for
            // line metrics: the WinRT array of line metrics cannot be marshalled under native AOT.
            var lineHeight = Math.Max(style.Size * 1.5f, 1f);
            using var layout = new CanvasTextLayout(Device, paragraph, Paint(style), Math.Max(limit, 0.01f), 0f)
            {
                WordWrapping = CanvasWordWrapping.EmergencyBreak,
                LineSpacingMode = CanvasLineSpacingMode.Uniform,
                LineSpacing = lineHeight,
                LineSpacingBaseline = lineHeight * 0.8f,
            };
            var count = layout.LineCount;
            var start = 0;
            for (var index = 1; index <= count; index++)
            {
                // The first character of the next line; the end of the text after the last line.
                var end = paragraph.Length;
                if (index < count && layout.HitTest(0f, (index + 0.5f) * lineHeight, out var region)) end = Math.Clamp(region.CharacterIndex, start, paragraph.Length);
                if (end <= start) continue;
                var line = paragraph[start..end].TrimEnd(' ');
                result.Add(new TextLine(line, Measure(line, style)));
                start = end;
            }
            if (start < paragraph.Length)
            {
                var rest = paragraph[start..].TrimEnd(' ');
                result.Add(new TextLine(rest, Measure(rest, style)));
            }
        }
        return result;
    }

    /// <summary>First baseline below the top of a line box of the style's leading (CSS half-leading).</summary>
    public float Baseline(TextStyle style)
    {
        var typeface = fonts.Typeface(style.Family, style.Weight);
        var ascent = typeface.Ascent * style.Size;
        var descent = typeface.Descent * style.Size;
        return (style.Leading - (ascent + descent)) / 2f + ascent;
    }

    /// <summary>
    /// Draws one line with its left edge at <paramref name="x"/> and its baseline at <paramref name="baseline"/>,
    /// using the layout that <see cref="Measure"/> uses.
    /// </summary>
    public void Draw(CanvasDrawingSession session, string text, TextStyle style, float x, float baseline, ICanvasBrush brush)
    {
        if (text.Length == 0) return;
        // A fallback font may be taller than the style's font and would move the line. A fixed line box
        // puts the baseline where this code says, whatever fonts the line ends up using. (Reading the
        // line's own baseline from its metrics is not possible under native AOT.)
        var ascent = fonts.Typeface(style.Family, style.Weight).Ascent * style.Size;
        var height = Math.Max(style.Size * 2f, 1f);
        var offset = Math.Min(Math.Max(ascent, 0f), height);
        using var layout = new CanvasTextLayout(Device, text, Paint(style), 0f, 0f)
        {
            Options = DrawOptions,
            LineSpacingMode = CanvasLineSpacingMode.Uniform,
            LineSpacing = height,
            LineSpacingBaseline = offset,
        };
        session.DrawTextLayout(layout, x, baseline - offset, brush);
    }

    private const int MaximumFormats = 512;
    private const CanvasDrawTextOptions DrawOptions = CanvasDrawTextOptions.EnableColorFont | CanvasDrawTextOptions.NoPixelSnap;
}
