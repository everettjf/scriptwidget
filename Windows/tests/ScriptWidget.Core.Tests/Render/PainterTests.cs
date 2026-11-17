using Microsoft.Graphics.Canvas;
using ScriptWidget.Core.Render;

namespace ScriptWidget.Core.Tests.Render;

/// <summary>The painter, text engine and CSS parsers on their own, without the layout engine.</summary>
public class PainterTests
{
    private sealed class NoImages : IImageSource
    {
        public CanvasBitmap? Bitmap(string source, int maximumPixels) => null;
    }

    private static readonly FontRegistry Fonts = new();

    /// <summary>Paints a recorded element tree (JSON as render/entry.mjs writes it) and returns premultiplied BGRA pixels.</summary>
    private static byte[] Paint(string json, int width, int height, float scale, out DomPainter painter, bool liveMotion = false)
    {
        var device = CanvasDevice.GetSharedDevice();
        using var target = new CanvasRenderTarget(device, width, height, 96f);
        var session = target.CreateDrawingSession();
        session.Clear(Css.Transparent);
        painter = new DomPainter(new TextEngine(Fonts), new NoImages()) { LiveMotion = liveMotion };
        using (var canvas = new PaintCanvas(device, session)) painter.Paint(canvas, new DomNode(Json.ParseObject(json)), scale);
        return target.GetPixelBytes();
    }

    private static byte[] Paint(string json, int width, int height, float scale = 1f) => Paint(json, width, height, scale, out _);

    private static (byte B, byte G, byte R, byte A) Pixel(byte[] pixels, int width, int x, int y)
    {
        var at = (y * width + x) * 4;
        return (pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]);
    }

    private static int Inked(byte[] pixels)
    {
        var count = 0;
        for (var at = 3; at < pixels.Length; at += 4) if (pixels[at] != 0) count += 1;
        return count;
    }

    /// <summary>Left, top, right, bottom of the pixels that are not transparent.</summary>
    private static (int Left, int Top, int Right, int Bottom) InkBounds(byte[] pixels, int width)
    {
        int left = int.MaxValue, top = int.MaxValue, right = -1, bottom = -1;
        for (var at = 0; at + 3 < pixels.Length; at += 4)
        {
            if (pixels[at + 3] == 0) continue;
            var x = at / 4 % width;
            var y = at / 4 / width;
            left = Math.Min(left, x); right = Math.Max(right, x); top = Math.Min(top, y); bottom = Math.Max(bottom, y);
        }
        return (left, top, right, bottom);
    }

    private static string Number(float value) => value.ToString("R", System.Globalization.CultureInfo.InvariantCulture);

    private static string Root(int width, int height, string children) =>
        "{\"t\":\"div\",\"s\":{\"width\":\"" + width + "px\",\"height\":\"" + height + "px\"},\"c\":[" + children + "]}";

    private static string TextBox(string text, float left, float top, float width, float height, string extraStyle = "") =>
        "{\"t\":\"div\",\"s\":{\"position\":\"absolute\",\"left\":\"" + Number(left) + "px\",\"top\":\"" + Number(top) + "px\",\"width\":\"" + Number(width) + "px\",\"height\":\"" + Number(height) + "px\"," +
        "\"fontFamily\":\"\\\"ScriptWidget Inter\\\", Arial, sans-serif\",\"fontSize\":\"17px\",\"fontWeight\":\"400\",\"lineHeight\":\"22px\",\"color\":\"rgb(0, 0, 0)\"" + extraStyle + "},\"x\":" + Json.Quote(text) + "}";

    // MARK: - Fonts and text

    [Fact]
    public void TheBundledInterIsLoadedAndDiffersFromTheSystemFont()
    {
        var engine = new TextEngine(new FontRegistry());
        var system = new TextEngine(new FontRegistry { UseSystemFont = true });
        var style = new TextStyle("\"ScriptWidget Inter\", Arial, sans-serif", 20f, 400, 24f);
        const string sample = "Hello world, Widget 123";
        var inter = engine.Measure(sample, style);
        var segoe = system.Measure(sample, style);
        Assert.True(inter > 100f && segoe > 100f);
        Assert.True(Math.Abs(inter - segoe) > 2f, $"Inter {inter} and Segoe UI {segoe} should differ");
        // Inter's metrics: ascent 0.96875 and descent 0.2412 of the size, placed with CSS half-leading.
        Assert.Equal((24f - (0.96875f + 0.24121094f) * 20f) / 2f + 0.96875f * 20f, engine.Baseline(style), 3);
        // The weight changes the advance; the display fonts are their own families.
        Assert.True(engine.Measure(sample, style with { Weight = 700 }) > inter + 2f);
        foreach (var family in new[] { "Apple ][", "Larabiefont Free", "Monofonto", "White Rabbit", "OneSlot", "Unispace" })
        {
            var custom = engine.Measure(sample, style with { Family = $"\"{family}\", -apple-system, \"ScriptWidget Inter\", system-ui, sans-serif" });
            Assert.True(Math.Abs(custom - inter) > 1f, $"{family} measures {custom}, the same as Inter");
        }
        Assert.True(Math.Abs(engine.Measure(sample, style with { Family = "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, monospace" }) - 23 * engine.Measure("0", style with { Family = "ui-monospace" })) < 0.5f);
    }

    [Fact]
    public void LinesBreakLikePreWrapWithBreakWord()
    {
        var engine = new TextEngine(Fonts);
        var style = new TextStyle("\"ScriptWidget Inter\", Arial, sans-serif", 17f, 400, 22f);
        // Explicit newlines always break, and an empty line stays.
        Assert.Equal(["one", "", "two"], engine.Lines("one\n\ntwo", style, null).Select(line => line.Text));
        // Without a width nothing wraps.
        Assert.Single(engine.Lines("a long line of text that would never fit a narrow box", style, null));
        // With a width, words wrap and trailing spaces are trimmed.
        var wrapped = engine.Lines("alpha beta gamma delta epsilon", style, engine.Measure("alpha beta gam", style));
        Assert.Equal(["alpha beta", "gamma delta", "epsilon"], wrapped.Select(line => line.Text));
        foreach (var line in wrapped) Assert.Equal(engine.Measure(line.Text, style), line.Width, 3);
        // A word breaks inside only when it does not fit on a line of its own.
        var narrow = engine.Measure("abcdef", style);
        var broken = engine.Lines("hi abcdefghijkl", style, narrow + 0.5f);
        Assert.Equal("hi", broken[0].Text);
        Assert.True(broken.Count >= 3 && string.Concat(broken.Skip(1).Select(line => line.Text)) == "abcdefghijkl", string.Join("|", broken.Select(line => line.Text)));
        foreach (var line in broken) Assert.True(line.Width <= narrow + 0.51f);
        // Chinese breaks between characters.
        var chinese = engine.Lines("这是一个很长的中文句子用来测试换行", style, engine.Measure("这是一个很长", style) + 1f);
        Assert.True(chinese.Count >= 3);
        Assert.Equal("这是一个很长的中文句子用来测试换行", string.Concat(chinese.Select(line => line.Text)));
    }

    /// <summary>A line measured without a width is one line again when laid out in a box of exactly that width.</summary>
    [Fact]
    public void AMeasuredLineIsNotWrappedInABoxOfItsMeasuredWidth()
    {
        var engine = new TextEngine(Fonts);
        string[] samples = ["Hello widget world", "Tuesday, November 17", "72°F · Partly Cloudy", "1,234,567.89 kWh", "你好，世界 hello", "Steps 🚶 8,432 today", "AV To. WAVE fi ffl", "a b c d e f g h i j k l m n o p"];
        string[] families = ["\"ScriptWidget Inter\", Arial, sans-serif", "ui-monospace, Consolas, monospace", "\"New York\", ui-serif, Georgia, serif", "\"Unispace\", -apple-system, sans-serif"];
        foreach (var family in families)
            foreach (var size in new[] { 9f, 12f, 13.5f, 17f, 28f, 51.3f })
                foreach (var weight in new[] { 300, 400, 600, 700, 900 })
                    foreach (var sample in samples)
                    {
                        var style = new TextStyle(family, size, weight, size * 1.2f);
                        var measured = engine.Lines(sample, style, null);
                        Assert.Single(measured);
                        var laidOut = engine.Lines(sample, style, measured[0].Width);
                        Assert.True(laidOut.Count == 1 && laidOut[0].Text == sample, $"{family} {size} {weight} '{sample}' wrapped into {laidOut.Count} lines at its own width {measured[0].Width}");
                        Assert.Equal(measured[0].Width, laidOut[0].Width);
                    }
    }

    /// <summary>What is drawn in a box of the measured width is, pixel for pixel, what is drawn with room to spare.</summary>
    [Fact]
    public void TextDrawnAtItsMeasuredWidthIsNotWrappedOrCut()
    {
        var engine = new TextEngine(Fonts);
        var style = new TextStyle("\"ScriptWidget Inter\", Arial, sans-serif", 17f, 400, 22f);
        foreach (var sample in new[] { "Hello widget world", "Weather in 北京 ☀ 23°", "Wavy AVATAR Type" })
        {
            var width = engine.Measure(sample, style);
            var exact = Paint(Root(400, 60, TextBox(sample, 10f, 10f, width, 22f)), 800, 120, 2f);
            var roomy = Paint(Root(400, 60, TextBox(sample, 10f, 10f, 380f, 22f, ",\"whiteSpace\":\"pre\"")), 800, 120, 2f);
            Assert.True(Inked(exact) > 200, sample);
            Assert.True(exact.AsSpan().SequenceEqual(roomy), $"'{sample}' is drawn differently in a box of its measured width");
            // One line: the ink stays inside the 22-point line box, and inside the measured width.
            var (left, top, right, bottom) = InkBounds(exact, 800);
            Assert.True(top >= 20 - 4 && bottom <= (10 + 22) * 2 + 4, $"'{sample}' ink rows {top}..{bottom}");
            Assert.True(left >= 20 - 4 && right <= (10 + width) * 2f + 4f, $"'{sample}' ink columns {left}..{right} for width {width}");
        }
    }

    [Fact]
    public void TextAlignmentPlacesTheLineInItsBox()
    {
        var left = InkBounds(Paint(Root(200, 30, TextBox("Hi", 0f, 0f, 200f, 22f)), 200, 30), 200);
        var center = InkBounds(Paint(Root(200, 30, TextBox("Hi", 0f, 0f, 200f, 22f, ",\"textAlign\":\"center\"")), 200, 30), 200);
        var right = InkBounds(Paint(Root(200, 30, TextBox("Hi", 0f, 0f, 200f, 22f, ",\"textAlign\":\"right\"")), 200, 30), 200);
        Assert.True(left.Left < 4 && left.Right < 30);
        Assert.True(Math.Abs((center.Left + center.Right) / 2f - 100f) < 2f, $"{center}");
        Assert.True(right.Right >= 196 && right.Left > 170, $"{right}");
        // Wrapped text takes one line box per line.
        var wrapped = InkBounds(Paint(Root(60, 100, TextBox("alpha beta gamma", 0f, 0f, 60f, 66f)), 60, 100), 60);
        Assert.True(wrapped.Bottom > 44 && wrapped.Bottom < 66, $"{wrapped}");
    }

    [Fact]
    public void ChineseAndEmojiTextIsDrawn()
    {
        var chinese = Paint(Root(200, 40, TextBox("你好世界", 4f, 4f, 190f, 22f)), 400, 80, 2f);
        Assert.True(Inked(chinese) > 400, $"Chinese ink {Inked(chinese)}");
        var emoji = Paint(Root(200, 40, TextBox("😀🌈🔥", 4f, 4f, 190f, 22f)), 400, 80, 2f);
        Assert.True(Inked(emoji) > 400, $"emoji ink {Inked(emoji)}");
        // Emoji are drawn in color, not as black outlines.
        var colored = 0;
        for (var at = 0; at + 3 < emoji.Length; at += 4)
            if (emoji[at + 3] > 200 && Math.Max(emoji[at], Math.Max(emoji[at + 1], emoji[at + 2])) - Math.Min(emoji[at], Math.Min(emoji[at + 1], emoji[at + 2])) > 60) colored += 1;
        Assert.True(colored > 100, $"colored emoji pixels {colored}");
        // Text in the default color with no fallback needed is black.
        var latin = Paint(Root(200, 40, TextBox("Widget", 4f, 4f, 190f, 22f)), 400, 80, 2f);
        Assert.Contains(Enumerable.Range(0, latin.Length / 4), index => latin[index * 4 + 3] == 255 && latin[index * 4] == 0 && latin[index * 4 + 1] == 0 && latin[index * 4 + 2] == 0);
    }

    // MARK: - Boxes

    private static string Box(string style, string extra = "") => "{\"t\":\"div\",\"s\":{\"position\":\"absolute\"," + style + "}" + extra + "}";

    [Fact]
    public void BoxesAreFilledClippedAndRounded()
    {
        var pixels = Paint(Root(100, 100,
            Box("\"left\":\"10px\",\"top\":\"10px\",\"width\":\"80px\",\"height\":\"80px\",\"backgroundColor\":\"rgb(0, 0, 255)\",\"borderRadius\":\"20px\",\"overflow\":\"hidden\"",
                ",\"c\":[" + Box("\"left\":\"-10px\",\"top\":\"-10px\",\"width\":\"50px\",\"height\":\"50px\",\"backgroundColor\":\"#ff0000\"") + "]")), 200, 200, 2f);
        // Outside the box, and in the cut-off corner of the rounded outline.
        Assert.Equal(0, Pixel(pixels, 200, 10, 10).A);
        Assert.Equal(0, Pixel(pixels, 200, 24, 24).A);
        // The child is clipped by the rounded corner but shows inside it.
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(pixels, 200, 60, 60));
        // The rest of the box is blue.
        Assert.Equal(((byte)255, (byte)0, (byte)0, (byte)255), Pixel(pixels, 200, 140, 140));
        // A percentage radius is an ellipse.
        var circle = Paint(Root(100, 100, Box("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"100px\",\"height\":\"100px\",\"backgroundColor\":\"#00ff00\",\"borderRadius\":\"50%\"")), 100, 100);
        Assert.Equal(0, Pixel(circle, 100, 5, 5).A);
        Assert.Equal(((byte)0, (byte)255, (byte)0, (byte)255), Pixel(circle, 100, 50, 50));
    }

    [Fact]
    public void OpacityTransformsAndHitRegionsFollowTheElement()
    {
        var pixels = Paint(Root(100, 100,
            Box("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"40px\",\"height\":\"40px\",\"backgroundColor\":\"#ff0000\",\"opacity\":\"0.5\"") + "," +
            "{\"t\":\"div\",\"s\":{\"position\":\"absolute\",\"left\":\"50px\",\"top\":\"50px\",\"width\":\"40px\",\"height\":\"20px\",\"backgroundColor\":\"#0000ff\",\"transform\":\"rotate(90deg)\"},\"d\":{\"swInteraction\":\"{\\\"kind\\\":\\\"link\\\"}\"}}"),
            100, 100, 1f, out var painter);
        var faded = Pixel(pixels, 100, 20, 20);
        Assert.InRange(faded.A, 126, 129);
        Assert.InRange(faded.R, 126, 129);
        // The 40x20 box turned a quarter about its centre (70, 60) covers x 60..80, y 40..80.
        Assert.Equal(((byte)255, (byte)0, (byte)0, (byte)255), Pixel(pixels, 100, 70, 45));
        Assert.Equal(0, Pixel(pixels, 100, 54, 60).A);
        var hit = Assert.Single(painter.HitRegions);
        Assert.Equal("link", hit.Interaction.OptString("kind"));
        Assert.Equal(60f, hit.Bounds.Left, 2);
        Assert.Equal(40f, hit.Bounds.Top, 2);
        Assert.Equal(80f, hit.Bounds.Right, 2);
        Assert.Equal(80f, hit.Bounds.Bottom, 2);
    }

    [Fact]
    public void GradientsAndShadowsArePainted()
    {
        var linear = Paint(Root(100, 100, Box("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"100px\",\"height\":\"100px\",\"backgroundImage\":\"linear-gradient(90deg, rgb(255, 0, 0) 0px, rgb(0, 0, 255) 100px)\"")), 100, 100);
        var start = Pixel(linear, 100, 2, 50);
        var end = Pixel(linear, 100, 97, 50);
        Assert.True(start.R > 240 && start.B < 15 && end.B > 240 && end.R < 15, $"{start} {end}");
        var radial = Paint(Root(100, 100, Box("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"100px\",\"height\":\"100px\",\"backgroundImage\":\"radial-gradient(circle at 50px 50px, rgb(255, 255, 255) 0px, rgb(0, 0, 0) 50px)\"")), 100, 100);
        Assert.True(Pixel(radial, 100, 50, 50).R > 240 && Pixel(radial, 100, 2, 50).R < 15);
        // A conic gradient starts at 12 o'clock and runs clockwise.
        var conic = Paint(Root(100, 100, Box("\"left\":\"0px\",\"top\":\"0px\",\"width\":\"100px\",\"height\":\"100px\",\"backgroundImage\":\"conic-gradient(from 0deg at 50px 50px, rgb(255, 0, 0) 0deg, rgb(0, 0, 255) 360deg)\"")), 100, 100);
        var justAfterTwelve = Pixel(conic, 100, 53, 10);
        var justBeforeTwelve = Pixel(conic, 100, 46, 10);
        var six = Pixel(conic, 100, 50, 90);
        Assert.True(justAfterTwelve.R > 235 && justBeforeTwelve.B > 235, $"{justAfterTwelve} {justBeforeTwelve}");
        Assert.True(Math.Abs(six.R - six.B) < 12, $"{six}");
        // A drop shadow lies under and beside the element, softly.
        var shadow = Paint(Root(100, 100, Box("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"backgroundColor\":\"#ffffff\",\"filter\":\"drop-shadow(8px 8px 3px rgba(0, 0, 0, 1))\"")), 100, 100);
        Assert.Equal(((byte)255, (byte)255, (byte)255, (byte)255), Pixel(shadow, 100, 45, 45));
        var cast = Pixel(shadow, 100, 64, 64);
        Assert.True(cast.A > 200 && cast.R < 30, $"{cast}");
        Assert.Equal(0, Pixel(shadow, 100, 10, 10).A);
        Assert.InRange(Pixel(shadow, 100, 70, 50).A, 1, 254);
        // A box shadow is drawn under the box, an inset one as an inner border.
        var box = Paint(Root(100, 100, Box("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"backgroundColor\":\"#ffffff\",\"boxShadow\":\"0px 10px 6px rgba(0, 0, 0, 0.5)\"")), 100, 100);
        Assert.InRange(Pixel(box, 100, 45, 66).A, 60, 140);
        var inset = Paint(Root(100, 100, Box("\"left\":\"30px\",\"top\":\"30px\",\"width\":\"30px\",\"height\":\"30px\",\"boxShadow\":\"inset 0 0 0 2px rgb(255, 0, 0)\"")), 100, 100);
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(inset, 100, 31, 45));
        Assert.Equal(0, Pixel(inset, 100, 45, 45).A);
    }

    // MARK: - SVG

    private static string Svg(string attributes, string children, string style = "") =>
        "{\"t\":\"svg\",\"g\":1,\"s\":{\"position\":\"absolute\",\"left\":\"0px\",\"top\":\"0px\"" + style + "},\"a\":{" + attributes + "},\"c\":[" + children + "]}";

    private static string Shape(string tag, string attributes) => "{\"t\":\"" + tag + "\",\"g\":1,\"a\":{" + attributes + "}}";

    [Fact]
    public void SvgShapesStrokesAndDashesAreDrawn()
    {
        var pixels = Paint(Root(100, 100, Svg("\"width\":\"100\",\"height\":\"100\",\"viewBox\":\"0 0 50 50\"",
            Shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"10\",\"height\":\"10\",\"fill\":\"#ff0000\"") + "," +
            Shape("path", "\"d\":\"M30 0h10v10h-10z M32 2v6h6v-6z\",\"fill\":\"currentColor\",\"fill-rule\":\"evenodd\"") + "," +
            Shape("circle", "\"cx\":\"25\",\"cy\":\"30\",\"r\":\"10\",\"fill\":\"none\",\"stroke\":\"#0000ff\",\"stroke-width\":\"4\",\"pathLength\":\"100\",\"stroke-dasharray\":\"25 75\"") + "," +
            Shape("line", "\"x1\":\"0\",\"y1\":\"48\",\"x2\":\"50\",\"y2\":\"48\",\"stroke\":\"#00ff00\",\"stroke-width\":\"2\""),
            ",\"color\":\"rgb(0, 128, 0)\"")), 100, 100);
        // The view box doubles everything.
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(pixels, 100, 10, 10));
        Assert.Equal(0, Pixel(pixels, 100, 30, 10).A);
        // currentColor is the CSS color; the even-odd hole stays empty.
        Assert.Equal(((byte)0, (byte)128, (byte)0, (byte)255), Pixel(pixels, 100, 62, 10));
        Assert.Equal(0, Pixel(pixels, 100, 70, 10).A);
        // A quarter of the circle is stroked: from 3 o'clock clockwise to 6 o'clock.
        Assert.Equal(((byte)255, (byte)0, (byte)0, (byte)255), Pixel(pixels, 100, 64, 74));
        Assert.Equal(0, Pixel(pixels, 100, 36, 46).A);
        Assert.Equal(0, Pixel(pixels, 100, 64, 46).A);
        Assert.Equal(0, Pixel(pixels, 100, 36, 74).A);
        Assert.Equal(((byte)0, (byte)255, (byte)0, (byte)255), Pixel(pixels, 100, 50, 96));
    }

    [Fact]
    public void SvgArcsMasksAndTransformsAreDrawn()
    {
        // A half disc on the right of x = 50, drawn with an arc.
        var arc = Paint(Root(100, 100, Svg("\"width\":\"100\",\"height\":\"100\"", Shape("path", "\"d\":\"M50 10 A40 40 0 0 1 50 90 Z\",\"fill\":\"#ff0000\""))), 100, 100);
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(arc, 100, 70, 50));
        Assert.Equal(0, Pixel(arc, 100, 30, 50).A);
        // A mask keeps the drawing where the mask is white.
        var masked = Paint(Root(100, 100, Svg("\"width\":\"100\",\"height\":\"100\"",
            "{\"t\":\"mask\",\"g\":1,\"a\":{\"id\":\"m\"},\"c\":[" + Shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"50\",\"height\":\"100\",\"fill\":\"white\"") + "]}," +
            Shape("rect", "\"x\":\"10\",\"y\":\"10\",\"width\":\"80\",\"height\":\"80\",\"fill\":\"#0000ff\",\"mask\":\"url(#m)\""))), 100, 100);
        Assert.Equal(((byte)255, (byte)0, (byte)0, (byte)255), Pixel(masked, 100, 30, 50));
        Assert.Equal(0, Pixel(masked, 100, 70, 50).A);
        // A group transform moves and turns its children.
        var moved = Paint(Root(100, 100, Svg("\"width\":\"100\",\"height\":\"100\"",
            "{\"t\":\"g\",\"g\":1,\"a\":{\"transform\":\"translate(50 50) rotate(90)\",\"opacity\":\"0.5\"},\"c\":[" + Shape("rect", "\"x\":\"0\",\"y\":\"0\",\"width\":\"40\",\"height\":\"10\",\"fill\":\"#ff0000\"") + "]}")), 100, 100);
        Assert.InRange(Pixel(moved, 100, 45, 70).A, 126, 129);
        Assert.Equal(0, Pixel(moved, 100, 70, 55).A);
    }

    // MARK: - Parsers

    [Fact]
    public void CssValuesAreParsed()
    {
        Assert.Equal(Windows.UI.Color.FromArgb(255, 255, 0, 0), Css.Color("#f00"));
        Assert.Equal(Windows.UI.Color.FromArgb(255, 18, 52, 86), Css.Color("#123456"));
        Assert.Equal(Windows.UI.Color.FromArgb(0x80, 0x11, 0x22, 0x33), Css.Color("#11223380"));
        Assert.Equal(Windows.UI.Color.FromArgb(128, 1, 2, 3), Css.Color("rgba(1, 2, 3, 0.5)"));
        Assert.Equal(Windows.UI.Color.FromArgb(255, 0, 128, 0), Css.Color(" Green "));
        Assert.Null(Css.Color("none"));
        Assert.Null(Css.Color("#12"));
        Assert.Null(Css.Color("nonsense"));
        Assert.Equal(12.5f, Css.Pixels("12.5px"));
        Assert.Null(Css.Pixels("50%"));
        Assert.Null(Css.Pixels("auto"));
        Assert.Equal(25f, Css.Length("50%", 50f));
        Assert.Equal(["a(1, 2)", "b", "c(d(e, f))"], Css.SplitTopLevel("a(1, 2), b, c(d(e, f))"));
        var shadow = Css.DropShadow("blur(1px) drop-shadow(1px -2px 3.5px rgba(0, 0, 0, 0.25))")!;
        Assert.Equal((1f, -2f, 3.5f, (byte)64), (shadow.Dx, shadow.Dy, shadow.Blur, shadow.Color.A));
        var box = Css.BoxShadow("inset 0 0 0 1.5px rgba(255, 255, 255, 0.5)")!;
        Assert.True(box.Inset && box.Spread == 1.5f && box.Color.A == 128);
        var outer = Css.BoxShadow("0px 4px 8px rgb(0, 0, 0)")!;
        Assert.Equal((false, 0f, 4f, 8f, 0f), (outer.Inset, outer.Dx, outer.Dy, outer.Blur, outer.Spread));
        Assert.Null(Css.BoxShadow("4px"));
    }

    [Fact]
    public void MatricesMapPointsLikeAndroid()
    {
        var matrix = new Matrix();
        matrix.PreTranslate(10f, 20f);
        matrix.PreConcat(Matrix.Rotation(90f));
        // Rotation applies first, then the translation.
        var point = matrix.MapPoint(1f, 0f);
        Assert.Equal(10f, point.X, 3);
        Assert.Equal(21f, point.Y, 3);
        var rect = matrix.MapRect(new RectF(0f, 0f, 4f, 2f));
        Assert.Equal(new RectF(8f, 20f, 10f, 24f), new RectF(MathF.Round(rect.Left), MathF.Round(rect.Top), MathF.Round(rect.Right), MathF.Round(rect.Bottom)));
        Assert.True(Matrix.Translation(3f, 4f).IsTranslation && !matrix.IsTranslation && matrix.IsAffine);
        Assert.Null(new RectF(0f, 0f, 1f, 1f).Intersect(new RectF(2f, 2f, 3f, 3f)));
        Assert.Equal(new RectF(1f, 1f, 2f, 2f), new RectF(0f, 0f, 2f, 2f).Intersect(new RectF(1f, 1f, 3f, 3f)));
    }

    /// <summary>A view turned in 3D with perspective is still drawn, narrower than flat.</summary>
    [Fact]
    public void PerspectiveRotationIsDrawn()
    {
        const string box = "\"left\":\"20px\",\"top\":\"20px\",\"width\":\"60px\",\"height\":\"60px\",\"backgroundColor\":\"#ff0000\"";
        var flat = Paint(Root(100, 100, Box(box)), 200, 200, 2f);
        var turned = Paint(Root(100, 100, Box(box + ",\"transform\":\"perspective(400px) rotate3d(0, 1, 0, 60deg)\"")), 200, 200, 2f);
        var flatBounds = InkBounds(flat, 200);
        var turnedBounds = InkBounds(turned, 200);
        Assert.Equal((40, 40, 159, 159), flatBounds);
        var width = turnedBounds.Right - turnedBounds.Left;
        Assert.InRange(width, 50, 75);
        Assert.True(Math.Abs((turnedBounds.Left + turnedBounds.Right) / 2f - 100f) < 6f, $"{turnedBounds}");
        // Perspective makes the near edge taller than the far one.
        Assert.True(turnedBounds.Bottom - turnedBounds.Top > 120, $"{turnedBounds}");
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(turned, 200, 100, 100));
    }

    // MARK: - GIF and PNG

    /// <summary>Two 1x1 frames, red then blue, 200 ms each.</summary>
    private static byte[] TwoFrameGif() =>
    [
        0x47, 0x49, 0x46, 0x38, 0x39, 0x61, 0x01, 0x00, 0x01, 0x00, 0x80, 0x00, 0x00,
        0xFF, 0x00, 0x00, 0x00, 0x00, 0xFF,
        0x21, 0xF9, 0x04, 0x00, 0x14, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x44, 0x01, 0x00,
        0x21, 0xF9, 0x04, 0x00, 0x14, 0x00, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x02, 0x02, 0x4C, 0x01, 0x00,
        0x3B,
    ];

    [Fact]
    public void AnAnimatedGifIsSampledIntoFrames()
    {
        var frames = GifSampler.Sample(TwoFrameGif(), 8, 8, 1024 * 1024);
        Assert.NotNull(frames);
        // 400 ms at no less than 80 ms a frame.
        Assert.Equal(5, frames.Frames.Count);
        Assert.Equal(80, frames.IntervalMilliseconds);
        Assert.Equal((8, 8), (frames.Width, frames.Height));
        Assert.All(frames.Frames, frame => Assert.Equal(8 * 8 * 4, frame.Length));
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(frames.Frames[0], 8, 3, 3));
        Assert.Equal(((byte)255, (byte)0, (byte)0, (byte)255), Pixel(frames.Frames[^1], 8, 3, 3));
        // The byte budget shrinks every frame.
        var small = GifSampler.Sample(TwoFrameGif(), 8, 8, 5 * 4 * 4 * 4)!;
        Assert.True(small.Width <= 4 && small.Height <= 4);
        // Not a GIF, or a still one.
        Assert.Null(GifSampler.Sample([1, 2, 3], 8, 8, 1024));
        Assert.Null(GifSampler.Sample(TwoFrameGif(), 0, 8, 1024));
    }

    [Fact]
    public void PngKeepsStraightColorsOfTranslucentPixels()
    {
        // One opaque red pixel and one half-transparent green one (premultiplied).
        byte[] pixels = [0, 0, 255, 255, 0, 128, 0, 128];
        var png = PngEncoder.Encode(pixels, 2, 1);
        Assert.Equal([0x89, 0x50, 0x4E, 0x47], png.Take(4));
        using var stream = new MemoryStream(png).AsRandomAccessStream();
        using var bitmap = CanvasBitmap.LoadAsync(CanvasDevice.GetSharedDevice(), stream, 96f).AsTask().GetAwaiter().GetResult();
        Assert.Equal((2u, 1u), (bitmap.SizeInPixels.Width, bitmap.SizeInPixels.Height));
        var decoded = bitmap.GetPixelBytes();
        Assert.Equal(pixels, decoded);
    }
}
