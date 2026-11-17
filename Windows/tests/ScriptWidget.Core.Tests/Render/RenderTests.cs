using System.Text.Json.Nodes;
using Microsoft.Graphics.Canvas;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Render;
using ScriptWidget.Core.Runtime;
using Xunit.Abstractions;

namespace ScriptWidget.Core.Tests.Render;

/// <summary>One renderer (and its layout engine) for the whole class.</summary>
public sealed class RendererFixture : IDisposable
{
    public SharedScripts Scripts { get; } = new();
    public WidgetRenderer Renderer { get; }

    public RendererFixture() { Renderer = new WidgetRenderer(Scripts); }

    public void Dispose() => Renderer.Dispose();
}

/// <summary>
/// Renders every corpus tree to a bitmap. Fails on layout or paint errors and
/// on blank output; the PNGs are saved for visual review.
/// Ported from Android's RenderTest, with pixel checks on premultiplied BGRA.
/// </summary>
[Collection("Intl overrides")]
public class RenderTests(RendererFixture fixture, ITestOutputHelper output) : IClassFixture<RendererFixture>
{
    private const long FixedNow = 1767268800000;
    private static readonly string PngDirectory = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", "render");

    /// <summary>Packages whose pictures are written for review: shapes, text, gradients, charts, images, animation and full templates.</summary>
    private static readonly HashSet<string> Reviewed =
    [
        "api/gradient", "component/chart", "component/gauge", "component/ring", "component/text", "template/Activity Rings",
        "template/Animation Clock", "template/Month Calendar", "template/Personal Dashboard", "template/Weather Glance",
        "template/Shape", "component/icon", "template/Daily Agenda", "template/System Status Panel",
    ];

    private WidgetRenderer Renderer => fixture.Renderer;

    private static JsonObject Corpus() => Json.ParseObject(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "testassets", "parity-corpus.json")));

    private static string FileName(string name) => name.Replace('/', '_').Replace(' ', '_');

    // MARK: - Pixels

    /// <summary>Blue, green, red, alpha of one pixel.</summary>
    private static (byte B, byte G, byte R, byte A) Pixel(RenderOutput output, int x, int y) => Pixel(output.Pixels, output.PixelWidth, x, y);

    private static (byte B, byte G, byte R, byte A) Pixel(byte[] pixels, int width, int x, int y)
    {
        var at = (y * width + x) * 4;
        return (pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]);
    }

    private static int Count(byte[] pixels, Func<byte, byte, byte, byte, bool> matches)
    {
        var count = 0;
        for (var at = 0; at + 3 < pixels.Length; at += 4) if (matches(pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3])) count += 1;
        return count;
    }

    private static bool IsFlat(byte[] pixels)
    {
        for (var at = 4; at + 3 < pixels.Length; at += 4)
            if (pixels[at] != pixels[0] || pixels[at + 1] != pixels[1] || pixels[at + 2] != pixels[2] || pixels[at + 3] != pixels[3]) return false;
        return true;
    }

    private static bool IsRed(byte b, byte g, byte r, byte a) => b == 0 && g == 0 && r == 255 && a == 255;

    private static (byte[] Pixels, int Width, int Height) DecodePng(byte[] png)
    {
        using var stream = new MemoryStream(png).AsRandomAccessStream();
        using var bitmap = CanvasBitmap.LoadAsync(CanvasDevice.GetSharedDevice(), stream, 96f).AsTask().GetAwaiter().GetResult();
        return (bitmap.GetPixelBytes(), (int)bitmap.SizeInPixels.Width, (int)bitmap.SizeInPixels.Height);
    }

    // MARK: - Corpus

    [Fact]
    public void CorpusTreesRenderToBitmaps()
    {
        var corpus = Corpus();
        IntlBridge.TimeZoneOverride = corpus.OptString("timeZone");
        IntlBridge.LocaleOverride = "en-US";
        try
        {
            var directory = Path.Combine(PngDirectory, "expected-trees");
            if (Directory.Exists(directory)) Directory.Delete(directory, true);
            Directory.CreateDirectory(directory);
            var packages = corpus.OptArray("corpus")!;
            var failures = new List<string>();
            long layout = 0, paint = 0, slowest = 0;
            foreach (var node in packages)
            {
                var item = (JsonObject)node!;
                var name = item.OptString("name");
                var tree = item.OptObject("expected").OptString("tree");
                try
                {
                    var rendered = Renderer.Render(new RenderRequest { Tree = tree, Width = 338f, Height = 158f, Density = 2.625f, Family = "medium", NowMilliseconds = FixedNow });
                    layout += rendered.LayoutMilliseconds;
                    paint += rendered.PaintMilliseconds;
                    slowest = Math.Max(slowest, rendered.LayoutMilliseconds + rendered.PaintMilliseconds);
                    Assert.Equal((int)MathF.Ceiling(338f * 2.625f), rendered.PixelWidth);
                    Assert.Equal((int)MathF.Ceiling(158f * 2.625f), rendered.PixelHeight);
                    if (IsFlat(rendered.Pixels) && !tree.Contains("\"children\":[]}")) failures.Add($"{name}: bitmap is a single flat color");
                    if (Reviewed.Contains(name)) File.WriteAllBytes(Path.Combine(directory, FileName(name) + ".png"), rendered.EncodePng());
                }
                catch (Exception error)
                {
                    failures.Add($"{name}: {(error.Message.Length > 500 ? error.Message[..500] : error.Message)}");
                }
            }
            var summary = $"rendered {packages.Count - failures.Count}/{packages.Count}; layout {layout} ms, paint {paint} ms, slowest {slowest} ms; {directory}";
            output.WriteLine(summary);
            Assert.True(packages.Count > 0);
            Assert.True(failures.Count == 0, summary + "\n" + string.Join("\n", failures));
        }
        finally
        {
            IntlBridge.TimeZoneOverride = null;
            IntlBridge.LocaleOverride = null;
        }
    }

    /// <summary>Every corpus package is executed and its own tree drawn at the three macOS widget sizes.</summary>
    [Fact]
    public void EveryCorpusPackageRendersAtEverySize()
    {
        var corpus = Corpus();
        IntlBridge.TimeZoneOverride = corpus.OptString("timeZone");
        IntlBridge.LocaleOverride = corpus.OptString("locale", "en-US");
        var storageDirectory = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", "render-storage-" + Guid.NewGuid().ToString("N"));
        try
        {
            var writeAll = Environment.GetEnvironmentVariable("SCRIPTWIDGET_RENDER_ALL") == "1";
            foreach (var family in new[] { "small", "medium", "large" }) Directory.CreateDirectory(Path.Combine(PngDirectory, family));
            using var compiler = new PackageCompiler(fixture.Scripts);
            var executor = new ScriptExecutor(fixture.Scripts);
            var storage = new StorageModule(storageDirectory);
            var prelude = corpus.OptString("prelude");
            var packages = corpus.OptArray("corpus")!;
            (string Family, float Width, float Height)[] sizes = [("small", 170f, 170f), ("medium", 329f, 170f), ("large", 329f, 345f)];
            var failures = new List<string>();
            long layout = 0, paint = 0, slowest = 0;
            var renders = 0;
            for (var index = 0; index < packages.Count; index++)
            {
                var item = (JsonObject)packages[index]!;
                var name = item.OptString("name");
                var text = new Dictionary<string, string>();
                foreach (var (path, content) in item.OptObject("files")!) text[path] = content!.AsText()!;
                var binaries = new Dictionary<string, byte[]>();
                foreach (var path in item.OptArray("binaries") ?? new JsonArray()) binaries[path!.AsText()!] = [];
                var files = new MemoryPackageFiles(text, binaries);
                string tree;
                try
                {
                    var prepared = compiler.Prepare(files, prelude: prelude);
                    var result = executor.Execute(new ExecutionRequest { Prepared = prepared, Files = files, Modules = [storage], PackageID = $"render-{index}" });
                    tree = result.Tree ?? throw new InvalidOperationException($"no tree: [{result.Error?.Kind}] {result.Error?.Message}");
                }
                catch (Exception error)
                {
                    failures.Add($"{name}: execute failed: {error.Message}");
                    continue;
                }
                foreach (var (family, width, height) in sizes)
                {
                    try
                    {
                        var rendered = Renderer.Render(new RenderRequest { Tree = tree, Width = width, Height = height, Density = 2f, Family = family, Files = files, NowMilliseconds = FixedNow });
                        renders += 1;
                        layout += rendered.LayoutMilliseconds;
                        paint += rendered.PaintMilliseconds;
                        slowest = Math.Max(slowest, rendered.LayoutMilliseconds + rendered.PaintMilliseconds);
                        Assert.Equal((int)(width * 2f), rendered.PixelWidth);
                        Assert.Equal((int)(height * 2f), rendered.PixelHeight);
                        Assert.Equal(rendered.PixelWidth * rendered.PixelHeight * 4, rendered.Pixels.Length);
                        if (Count(rendered.Pixels, (_, _, _, a) => a != 0) == 0) failures.Add($"{name} ({family}): bitmap is empty");
                        if (writeAll || Reviewed.Contains(name)) File.WriteAllBytes(Path.Combine(PngDirectory, family, FileName(name) + ".png"), rendered.EncodePng());
                        // The recorded elements, to compare a picture with the CSS it was drawn from.
                        if (writeAll) File.WriteAllText(Path.Combine(PngDirectory, family, FileName(name) + ".json"), Renderer.Layout(new RenderRequest { Tree = tree, Width = width, Height = height, Density = 2f, Family = family, Files = files, NowMilliseconds = FixedNow }));
                    }
                    catch (Exception error)
                    {
                        failures.Add($"{name} ({family}): {(error.Message.Length > 500 ? error.Message[..500] : error.Message)}");
                    }
                }
            }
            var summary = $"rendered {renders} bitmaps of {packages.Count} packages; layout {layout} ms, paint {paint} ms (mean {(double)layout / Math.Max(1, renders):F1} + {(double)paint / Math.Max(1, renders):F1} ms), slowest {slowest} ms; {PngDirectory}";
            output.WriteLine(summary);
            Assert.True(packages.Count > 0);
            Assert.True(failures.Count == 0, summary + "\n" + string.Join("\n", failures));
        }
        finally
        {
            IntlBridge.TimeZoneOverride = null;
            IntlBridge.LocaleOverride = null;
            try { Directory.Delete(storageDirectory, true); } catch (IOException) { }
        }
    }

    // MARK: - Lists and theme colors (Android inputs that the shared layout still understands)

    private static string ListTree(int rows)
    {
        var items = string.Join(",", Enumerable.Range(1, rows).Select(row =>
            "{\"$element\":\"toggle\",\"props\":{\"stateKey\":\"check." + row + "\",\"on\":false},\"children\":[{\"$element\":\"text\",\"props\":{\"color\":\"material.primary\"},\"children\":[\"Row " + row + "\"]}]}"));
        return "{\"$element\":\"vstack\",\"props\":{\"frame\":\"max\",\"alignment\":\"leading\",\"background\":\"material.surface\"},\"children\":[" +
            "{\"$element\":\"text\",\"props\":null,\"children\":[\"Header\"]},{\"$element\":\"list\",\"props\":{\"spacing\":\"2\"},\"children\":[" + items + "]}]}";
    }

    private static JsonObject TestColors() => Json.ParseObject("{\"light\":{\"primary\":[255,0,0,1],\"surface\":[0,0,255,1]},\"dark\":{\"primary\":[0,255,0,1],\"surface\":[10,20,30,1]}}");

    /// <summary>A scrolling list leaves its rows out of the widget bitmap and hands them over as pieces with their own tap targets.</summary>
    [Fact]
    public void AListIsDrawnAsPiecesWithTapTargets()
    {
        var rendered = Renderer.Render(new RenderRequest { Tree = ListTree(40), Width = 338f, Height = 300f, Density = 2f, Family = "large", LiveLists = true, Colors = TestColors() });
        Assert.Single(rendered.ListSlots);
        var slot = rendered.ListSlots[0];
        Assert.True(slot.Bounds.Width > 300f && slot.Bounds.Height > 200f && slot.Bounds.Bottom <= 300.5f, $"the list fills the widget below the header: {slot.Bounds}");
        Assert.InRange(slot.Pieces.Count, 2, 20);
        Assert.False(slot.Truncated);
        // Every row keeps its tap target, inside the piece that shows it.
        var hits = slot.Pieces.SelectMany(piece => piece.HitRegions.Select(hit => (Piece: piece, Hit: hit))).ToList();
        Assert.Equal(40, hits.Count);
        Assert.Equal(Enumerable.Range(1, 40).Select(row => $"check.{row}"), hits.Select(item => item.Hit.Interaction.OptString("stateKey")));
        foreach (var (piece, hit) in hits) Assert.True(hit.Bounds.Top >= -0.5f && hit.Bounds.Bottom <= piece.HeightPoints + 0.5f, $"{hit.Bounds} in {piece.HeightPoints}");
        // The pieces together are as tall as the rows, far more than the visible part.
        Assert.True(slot.Pieces.Sum(piece => (double)piece.HeightPoints) > slot.Bounds.Height * 2);
        // Each piece is a PNG at the list's width that shows the row text in the theme color.
        var red = 0;
        foreach (var piece in slot.Pieces)
        {
            var (pixels, width, height) = DecodePng(piece.Png);
            Assert.Equal((int)MathF.Ceiling(slot.Bounds.Width * rendered.Scale), width);
            Assert.Equal((int)MathF.Ceiling(piece.HeightPoints * rendered.Scale), height);
            red += Count(pixels, IsRed);
        }
        Assert.True(red > 1000, $"row text uses material.primary: {red}");
        // The rows are not in the widget bitmap, and none of their taps are in the widget's own list.
        Assert.Empty(rendered.HitRegions);
        // The background is the theme surface color.
        Assert.Equal(((byte)255, (byte)0, (byte)0, (byte)255), Pixel(rendered, 4, rendered.PixelHeight - 4));
        // Drawing the same list again reuses the pieces byte for byte.
        var again = Renderer.Render(new RenderRequest { Tree = ListTree(40), Width = 338f, Height = 300f, Density = 2f, Family = "large", LiveLists = true, Colors = TestColors() });
        Assert.True(Enumerable.Range(0, slot.Pieces.Count).All(index => slot.Pieces[index].Png.AsSpan().SequenceEqual(again.ListSlots[0].Pieces[index].Png)));
    }

    /// <summary>Without a host that scrolls, the list is drawn in place and only the visible rows can be tapped.</summary>
    [Fact]
    public void AListDrawnInPlaceKeepsOnlyVisibleTapTargets()
    {
        var rendered = Renderer.Render(new RenderRequest { Tree = ListTree(40), Width = 338f, Height = 300f, Density = 2f, Family = "large", Colors = TestColors() });
        Assert.Empty(rendered.ListSlots);
        Assert.InRange(rendered.HitRegions.Count, 3, 15);
        foreach (var hit in rendered.HitRegions) Assert.True(hit.Bounds.Top >= 0f && hit.Bounds.Bottom <= 300.5f, $"{hit.Bounds}");
        // The rows are part of the bitmap now.
        Assert.True(Count(rendered.Pixels, IsRed) > 500);
    }

    /// <summary>The dark bitmap takes the dark palette, and without a palette the names are unknown, as on iPhone.</summary>
    [Fact]
    public void ThemeColorsFollowTheAppearanceAndAreUnknownWithoutAPalette()
    {
        var dark = Renderer.Render(new RenderRequest { Tree = ListTree(3), Width = 200f, Height = 200f, Density = 1f, DarkMode = true, Colors = TestColors() });
        Assert.Equal(((byte)0x1E, (byte)0x14, (byte)0x0A, (byte)0xFF), Pixel(dark, 2, 198));
        var plain = Renderer.Render(new RenderRequest { Tree = ListTree(3), Width = 200f, Height = 200f, Density = 1f });
        // The widget keeps the system background: white in light mode.
        Assert.Equal(((byte)255, (byte)255, (byte)255, (byte)255), Pixel(plain, 2, 198));
        // A malformed palette is ignored rather than failing the render.
        var broken = Renderer.Render(new RenderRequest { Tree = ListTree(3), Width = 200f, Height = 200f, Density = 1f, Colors = Json.ParseObject("{\"light\":{\"surface\":\"red\",\"primary\":[1,2]}}") });
        Assert.Equal(((byte)255, (byte)255, (byte)255, (byte)255), Pixel(broken, 2, 198));
    }

    // MARK: - Output

    private const string RedCard = "{\"$element\":\"vstack\",\"props\":{\"frame\":\"max\",\"background\":\"#ff0000\"},\"children\":[{\"$element\":\"text\",\"props\":{\"color\":\"white\"},\"children\":[\"Hello\"]}]}";

    /// <summary>The bitmap budget lowers the scale instead of failing, and the PNG helper keeps the pixels.</summary>
    [Fact]
    public void TheBitmapBudgetScalesTheOutputAndPngKeepsThePixels()
    {
        var full = Renderer.Render(new RenderRequest { Tree = RedCard, Width = 200f, Height = 100f, Density = 2f });
        Assert.Equal((400, 200, 2f), (full.PixelWidth, full.PixelHeight, full.Scale));
        var limited = Renderer.Render(new RenderRequest { Tree = RedCard, Width = 200f, Height = 100f, Density = 2f, MaximumBitmapBytes = 80_000 });
        Assert.True(limited.Scale < 2f && limited.Scale > 0.9f, $"scale {limited.Scale}");
        Assert.True((long)limited.PixelWidth * limited.PixelHeight * 4 <= 82_000, $"{limited.PixelWidth}x{limited.PixelHeight}");
        Assert.True(Count(limited.Pixels, IsRed) > limited.PixelWidth * limited.PixelHeight / 2);

        var (pixels, width, height) = DecodePng(full.EncodePng());
        Assert.Equal((full.PixelWidth, full.PixelHeight), (width, height));
        Assert.Equal(full.Pixels.Length, pixels.Length);
        // Straight alpha and back may move a translucent channel by one step.
        for (var at = 0; at < pixels.Length; at++) Assert.True(Math.Abs(pixels[at] - full.Pixels[at]) <= 2, $"byte {at}: {pixels[at]} vs {full.Pixels[at]}");
    }

    /// <summary>Outside the rounded widget background nothing is drawn: those pixels stay fully transparent.</summary>
    [Fact]
    public void PixelsOutsideTheRoundedBackgroundAreTransparent()
    {
        // A 120-point red square with 30-point corners, centred in a 170-point widget with a clear background.
        const string tree = "{\"$element\":\"zstack\",\"props\":{\"frame\":\"max\",\"background\":\"clear\"},\"children\":[{\"$element\":\"roundedrect\",\"props\":{\"color\":\"#ff0000\",\"frame\":\"120,120\",\"radius\":\"30\"},\"children\":[]}]}";
        var rendered = Renderer.Render(new RenderRequest { Tree = tree, Width = 170f, Height = 170f, Density = 2f, Family = "small" });
        Assert.Equal((340, 340), (rendered.PixelWidth, rendered.PixelHeight));
        // The widget's own corners and edges.
        foreach (var (x, y) in new[] { (0, 0), (339, 0), (0, 339), (339, 339), (170, 20), (20, 170), (170, 320), (320, 170) })
            Assert.Equal((0, 0, 0, 0), ((int, int, int, int))Pixel(rendered, x, y));
        // Inside the square's bounding box (50..290) but outside its rounded corners.
        foreach (var (x, y) in new[] { (54, 54), (285, 54), (54, 285), (285, 285), (62, 58) })
            Assert.Equal(0, Pixel(rendered, x, y).A);
        // The square itself, up to the middle of each edge and well inside each corner arc.
        foreach (var (x, y) in new[] { (170, 170), (170, 53), (53, 170), (286, 170), (170, 286), (75, 75), (265, 265) })
            Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(rendered, x, y));
        // Only the anti-aliased edge is translucent, and premultiplied: no channel exceeds alpha.
        var red = Count(rendered.Pixels, IsRed);
        var clear = Count(rendered.Pixels, (_, _, _, a) => a == 0);
        Assert.InRange(red, 240 * 240 - 4 * 900 - 1500, 240 * 240);
        Assert.True(340 * 340 - red - clear < 1500, $"{340 * 340 - red - clear} translucent pixels");
        Assert.Equal(0, Count(rendered.Pixels, (b, g, r, a) => b > a || g > a || r > a));

        // A widget with its own background fills the bitmap; the host rounds its corners.
        var card = Renderer.Render(new RenderRequest { Tree = RedCard, Width = 170f, Height = 170f, Density = 2f, Family = "small" });
        Assert.Equal(((byte)0, (byte)0, (byte)255, (byte)255), Pixel(card, 0, 0));
        // Its text is drawn in white on the red card.
        Assert.True(Count(card.Pixels, (b, g, r, a) => b == 255 && g == 255 && r == 255 && a == 255) > 50);
    }

    /// <summary>A layout that never finishes is stopped, and the renderer works again afterwards.</summary>
    [Fact]
    public void AMalformedTreeFailsAndTheNextRenderWorks()
    {
        Assert.ThrowsAny<Exception>(() => Renderer.Render(new RenderRequest { Tree = "{not json", Width = 100f, Height = 100f, Density = 1f }));
        var rendered = Renderer.Render(new RenderRequest { Tree = RedCard, Width = 100f, Height = 100f, Density = 1f });
        Assert.True(Count(rendered.Pixels, IsRed) > 1000);
    }

    // MARK: - Slots

    private static string CorpusTree(string name)
    {
        foreach (var node in Corpus().OptArray("corpus")!)
            if (node is JsonObject item && item.OptString("name") == name) return item.OptObject("expected").OptString("tree");
        throw new InvalidOperationException($"{name} is not in the corpus");
    }

    /// <summary>Clock hands are handed to the host as bitmaps centred on their rotation point, and left out of the widget bitmap.</summary>
    [Fact]
    public void ClockAnimationsBecomeMotionSlots()
    {
        var tree = CorpusTree("template/Animation Clock");
        var still = Renderer.Render(new RenderRequest { Tree = tree, Width = 170f, Height = 170f, Density = 2f, Family = "small", NowMilliseconds = FixedNow });
        Assert.Empty(still.MotionSlots);
        var live = Renderer.Render(new RenderRequest { Tree = tree, Width = 170f, Height = 170f, Density = 2f, Family = "small", NowMilliseconds = FixedNow, LiveMotion = true });
        Assert.InRange(live.MotionSlots.Count, 1, 8);
        foreach (var slot in live.MotionSlots)
        {
            Assert.Equal("clock", slot.Description.OptString("kind"));
            Assert.Equal((int)MathF.Ceiling(slot.SizePoints * live.Scale), slot.PixelSize);
            Assert.Equal(slot.PixelSize * slot.PixelSize * 4, slot.Pixels.Length);
            Assert.True(Count(slot.Pixels, (_, _, _, a) => a != 0) > 0, "the hand is drawn in its bitmap");
            Assert.InRange(slot.Anchor.X, 0f, 170f);
            Assert.InRange(slot.Anchor.Y, 0f, 170f);
        }
        // The hands are no longer in the widget bitmap.
        Assert.False(still.Pixels.AsSpan().SequenceEqual(live.Pixels));
    }

    /// <summary>A live date style leaves its text out of the bitmap and reports where the host should put its own view.</summary>
    [Fact]
    public void LiveDateStylesBecomeDateSlots()
    {
        const string tree = "{\"$element\":\"vstack\",\"props\":{\"frame\":\"max\"},\"children\":[{\"$element\":\"date\",\"props\":{\"date\":\"now\",\"style\":\"timer\",\"color\":\"#ff0000\"},\"children\":[]}]}";
        var drawn = Renderer.Render(new RenderRequest { Tree = tree, Width = 200f, Height = 100f, Density = 2f, NowMilliseconds = FixedNow });
        Assert.Empty(drawn.DateSlots);
        Assert.True(Count(drawn.Pixels, IsRed) > 20, "the date text is drawn in red");
        var live = Renderer.Render(new RenderRequest { Tree = tree, Width = 200f, Height = 100f, Density = 2f, NowMilliseconds = FixedNow, LiveDateStyles = new HashSet<string> { "timer" } });
        Assert.Single(live.DateSlots);
        var slot = live.DateSlots[0];
        Assert.Equal("timer", slot.Description.OptString("style"));
        Assert.Equal(Windows.UI.Color.FromArgb(255, 255, 0, 0), slot.Color);
        Assert.True(slot.Bounds.Width > 10f && slot.Bounds.Height > 10f && slot.Bounds.Left >= 0f && slot.Bounds.Right <= 200.5f, $"{slot.Bounds}");
        Assert.NotNull(slot.Style);
        Assert.Equal(0, Count(live.Pixels, IsRed));
    }
}
