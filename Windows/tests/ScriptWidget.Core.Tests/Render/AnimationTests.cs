using System.Text.Json.Nodes;
using ScriptWidget.Core.Render;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Tests.Render;

public sealed class AnimationTests(RendererFixture fixture) : IClassFixture<RendererFixture>
{
    private static JsonObject Clock(string type, string zone = "UTC", double interval = 10) => new()
    {
        ["kind"] = "clock", ["type"] = type, ["timezone"] = zone, ["interval"] = interval,
    };

    [Theory]
    [InlineData("clockHour", "UTC", 90)]
    [InlineData("clockMinute", "UTC", 0)]
    [InlineData("clockSecond", "UTC", 0)]
    [InlineData("clockHour", "Asia/Tokyo", 0)]
    [InlineData("clockHour", "America/New_York", 300)]
    public void HandsFollowLocalTime(string type, string zone, float expected)
    {
        var now = DateTimeOffset.Parse("2026-01-01T03:00:00Z").ToUnixTimeMilliseconds();
        Assert.Equal(expected, AnimationPose.At(Clock(type, zone), now).Degrees, 3);
    }

    [Fact]
    public void CustomClockAndSwingMatchTheirPeriodsAndBounds()
    {
        var reference = DateTimeOffset.Parse("2001-01-01T00:00:00Z").ToUnixTimeMilliseconds();
        Assert.Equal(90, AnimationPose.At(Clock("clock"), reference + 5000).Degrees);
        Assert.Equal(-90, AnimationPose.At(Clock("clock", interval: -10), reference + 5000).Degrees);
        Assert.Equal(180, AnimationPose.At(Clock("clock", interval: 0), reference + 250).Degrees);
        var swing = new JsonObject { ["kind"] = "swing", ["axis"] = "y", ["duration"] = 1, ["distance"] = 10 };
        Assert.Equal(new AnimationPose(0, 0, 10), AnimationPose.At(swing, 500));
        Assert.Equal(-10, AnimationPose.At(swing, 1500).Y);
        Assert.Equal(50, AnimationPose.IntervalMilliseconds(swing));
        Assert.Equal(1000, AnimationPose.IntervalMilliseconds(Clock("clockSecond")));
        Assert.Equal(60000, AnimationPose.IntervalMilliseconds(Clock("clockHour")));
        Assert.Equal(default, AnimationPose.At(Clock("clockHour"), long.MaxValue));
    }

    [Fact]
    public void ClockFollowsDaylightSavingAtTheRequestedDate()
    {
        var before = DateTimeOffset.Parse("2026-03-08T09:59:00Z").ToUnixTimeMilliseconds();
        Assert.Equal(59.5f, AnimationPose.At(Clock("clockHour", "America/Los_Angeles"), before).Degrees, 3);
        Assert.Equal(90, AnimationPose.At(Clock("clockHour", "America/Los_Angeles"), before + 60000).Degrees, 3);
    }

    private RenderOutput Render(string children, IPackageFiles? files = null) => fixture.Renderer.Render(new RenderRequest
    {
        Tree = "{\"$element\":\"zstack\",\"props\":{\"frame\":\"max\",\"background\":\"#000000\"},\"children\":[" + children + "]}",
        Width = 100, Height = 100, Density = 1, DesktopAnimation = true, NowMilliseconds = 0, Files = files,
    });

    private static (byte B, byte G, byte R, byte A) Pixel(byte[] pixels, int x, int y)
    {
        var at = (y * 100 + x) * 4;
        return (pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]);
    }

    [Fact]
    public void NativeTicksPreservePaintOrderAndRoundedCorners()
    {
        var output = Render("""
            {"$element":"rect","props":{"frame":"4,60","color":"red","animation":"clockSecond"},"children":[]},
            {"$element":"circle","props":{"frame":"16,16","color":"white"},"children":[]}
            """);
        var scene = Assert.IsType<AnimationScene>(output.Animation);
        Assert.True(scene.IsAnimated);
        var first = fixture.Renderer.Animate(scene, 0).Pixels;
        var next = fixture.Renderer.Animate(scene, 15000).Pixels;
        Assert.False(first.SequenceEqual(next));
        // The cap remains above the hand at every angle.
        Assert.Equal(((byte)255, (byte)255, (byte)255, (byte)255), Pixel(first, 50, 50));
        Assert.Equal(Pixel(first, 50, 50), Pixel(next, 50, 50));
        Assert.Equal(0, Pixel(next, 0, 0).A);
        var directory = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", "animation");
        Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory, "clock-0.png"), PngEncoder.Encode(first, 100, 100));
        File.WriteAllBytes(Path.Combine(directory, "clock-15.png"), PngEncoder.Encode(next, 100, 100));
    }

    [Fact]
    public void GifFramesAdvanceAndLoopWithoutAnotherLayout()
    {
        var files = new MemoryPackageFiles(new Dictionary<string, string>(), new Dictionary<string, byte[]> { ["image/test.gif"] = PainterTests.TwoFrameGif() });
        var output = Render("""{"$element":"gif","props":{"file":"test.gif","frame":"30,30"},"children":[]}""", files);
        var scene = Assert.IsType<AnimationScene>(output.Animation);
        Assert.True(scene.IsAnimated);
        var first = fixture.Renderer.Animate(scene, 0).Pixels;
        var next = fixture.Renderer.Animate(scene, 320).Pixels;
        var loop = fixture.Renderer.Animate(scene, 400).Pixels;
        Assert.NotEqual(Pixel(first, 50, 50), Pixel(next, 50, 50));
        Assert.Equal(Pixel(first, 50, 50), Pixel(loop, 50, 50));
        Assert.Equal(80, scene.IntervalMilliseconds);
    }

    [Fact]
    public void StaticLayoutsNeedNoAnimationTimer()
    {
        var output = Render("""{"$element":"text","props":{},"children":["Hello"]}""");
        Assert.False(output.Animation!.IsAnimated);
    }

    [Fact]
    public void MovingButtonsKeepTheirClickRegions()
    {
        var output = Render("""{"$element":"button","props":{"title":"Tap","onClick":"tap","frame":"30,30","animation":"swing"},"children":[]}""");
        var scene = Assert.IsType<AnimationScene>(output.Animation);
        var first = Assert.Single(fixture.Renderer.Animate(scene, 0).HitRegions);
        var next = Assert.Single(fixture.Renderer.Animate(scene, 500).HitRegions);
        Assert.Equal(first.Bounds.Left + 10, next.Bounds.Left, 2);
        Assert.Equal(first.Bounds.Top, next.Bounds.Top, 2);
    }

    [Fact]
    public void GifBudgetsHoldEvenForVerySmallBudgets()
    {
        Assert.Null(GifSampler.Sample(PainterTests.TwoFrameGif(), 8, 8, 7));
        var tiny = GifSampler.Sample(PainterTests.TwoFrameGif(), 8, 8, 8);
        Assert.NotNull(tiny);
        Assert.InRange(tiny.Frames.Sum(frame => frame.Length), 1, 8);
        var oversized = PainterTests.TwoFrameGif();
        // Refuse an image whose declared frame dimensions exceed the decode budget.
        oversized[33] = 0xff;
        oversized[34] = 0x7f;
        Assert.Null(GifSampler.Sample(oversized, 8, 8, 1024));
    }
}
