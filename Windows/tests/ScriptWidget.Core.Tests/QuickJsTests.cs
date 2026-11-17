using ScriptWidget.Core.Js;

namespace ScriptWidget.Core.Tests;

public class QuickJsTests
{
    private static T OnJsThread<T>(Func<QuickJs, T> block, JsHost? host = null, long memory = QuickJs.DefaultMemoryLimit) => JsThread.Run(() =>
    {
        using var engine = new QuickJs(host ?? ((_, _) => null), memory);
        return block(engine);
    });

    [Fact]
    public void EvaluatesAndReturnsStrings()
    {
        Assert.Equal("2,4,6", OnJsThread(engine => engine.Evaluate("[1,2,3].map(x => x * 2).join(',')")));
        Assert.Null(OnJsThread(engine => engine.Evaluate("undefined")));
        Assert.Null(OnJsThread(engine => engine.Evaluate("null")));
    }

    [Fact]
    public void KeepsAstralCharactersAndLoneSurrogates()
    {
        Assert.Equal("你好 🌤️", OnJsThread(engine => engine.Evaluate("'你好 🌤️'")));
        Assert.Equal("\ud83d", OnJsThread(engine => engine.Evaluate("'\\ud83d'")));
        Assert.Equal("a\ud83db", OnJsThread(engine => { engine.Evaluate("globalThis.echo = (text) => text;"); return engine.Call("echo", "a\ud83db"); }));
    }

    [Fact]
    public void TopLevelDeclarationsAreVisibleToLaterScripts()
    {
        Assert.Equal("3", OnJsThread(engine => { engine.Evaluate("const a = 1; let b = 2; class C {}"); return engine.Evaluate("String(a + b)"); }));
    }

    [Fact]
    public void CallsFunctionsWithNullArguments()
    {
        Assert.Equal("null|x", OnJsThread(engine => { engine.Evaluate("globalThis.f = (a, b) => String(a) + '|' + b;"); return engine.Call("f", null, "x"); }));
    }

    [Fact]
    public void RunsPromiseJobs()
    {
        Assert.Equal("done", OnJsThread(engine =>
        {
            engine.Evaluate("globalThis.r = 'pending'; (async () => { r = await Promise.resolve('done'); })();");
            Assert.True(engine.RunJobs() > 0);
            return engine.Evaluate("r");
        }));
    }

    [Fact]
    public void HostCallsReturnValuesNullAndErrors()
    {
        JsHost host = (operation, payload) => operation switch
        {
            "echo" => payload,
            "null" => null,
            _ => throw new InvalidOperationException("host refused " + operation),
        };
        Assert.Equal("payload ✓", OnJsThread(engine => engine.Evaluate("__swNative('echo', 'payload ✓')"), host));
        Assert.Equal("true", OnJsThread(engine => engine.Evaluate("String(__swNative('null') === null)"), host));
        Assert.Equal("host refused other", OnJsThread(engine => engine.Evaluate("try { __swNative('other'); 'no error' } catch (error) { error.message }"), host));
    }

    [Fact]
    public void HostCallsCanReenterTheEngine()
    {
        QuickJs? current = null;
        JsHost host = (operation, _) => operation == "outer" ? current!.Evaluate("__swNative('inner')") + "+outer" : "inner";
        Assert.Equal("inner+outer", JsThread.Run(() =>
        {
            using var engine = new QuickJs(host);
            current = engine;
            return engine.Evaluate("__swNative('outer')");
        }));
    }

    [Fact]
    public void UncaughtErrorsCarryMessageAndStack()
    {
        var error = Assert.Throws<JsException>(() => OnJsThread(engine => engine.Evaluate("function boom() { throw new TypeError('bad thing'); } boom();", "widget.js")));
        Assert.False(error.Interrupted);
        Assert.Contains("TypeError: bad thing", error.Message);
        Assert.Contains("widget.js", error.Message);
    }

    [Fact]
    public void DeadlineInterruptsAnEndlessLoop()
    {
        var error = Assert.Throws<JsException>(() => OnJsThread(engine => { engine.SetDeadline(200); return engine.Evaluate("for (;;) {}"); }));
        Assert.True(error.Interrupted);
    }

    [Fact]
    public void ClearingTheDeadlineLetsLaterCodeRun()
    {
        Assert.Equal("ok", OnJsThread(engine =>
        {
            engine.SetDeadline(100);
            Assert.Throws<JsException>(() => engine.Evaluate("for (;;) {}"));
            engine.SetDeadline(0);
            return engine.Evaluate("'ok'");
        }));
    }

    [Fact]
    public void MemoryLimitStopsRunawayAllocation()
    {
        var error = Assert.Throws<JsException>(() => OnJsThread(engine => engine.Evaluate("const a = []; for (;;) a.push(new Array(100000).fill(1));"), memory: 16L * 1024 * 1024));
        Assert.Contains("out of memory", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void DeepRecursionRaisesARangeError()
    {
        var error = Assert.Throws<JsException>(() => OnJsThread(engine => engine.Evaluate("function f() { return f() + 1 } f()")));
        Assert.Contains("stack", error.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void BytecodeRoundTrips()
    {
        var bytes = OnJsThread(engine => engine.Compile("globalThis.answer = 6 * 7; String(answer)"));
        Assert.NotEmpty(bytes);
        Assert.Equal("42", OnJsThread(engine => engine.EvaluateBytecode(bytes)));
    }

    [Fact]
    public void LocalTimeUsesTheOffsetOfTheDateNotOfToday()
    {
        QuickJs.SetTimeZone("America/Los_Angeles");
        try
        {
            // Winter and summer of the same year differ by the daylight-saving hour.
            Assert.Equal("480,420", OnJsThread(engine => engine.Evaluate("new Date(Date.UTC(2026, 0, 15, 12)).getTimezoneOffset() + ',' + new Date(Date.UTC(2026, 6, 15, 12)).getTimezoneOffset()")));
            Assert.Equal("4", OnJsThread(engine => engine.Evaluate("String(new Date(Date.UTC(2026, 6, 15, 11, 30)).getHours())")));
            QuickJs.SetTimeZone("Asia/Shanghai");
            Assert.Equal("-480", OnJsThread(engine => engine.Evaluate("String(new Date(Date.UTC(2026, 6, 15, 12)).getTimezoneOffset())")));
        }
        finally { QuickJs.SetTimeZone(null); }
    }

    [Fact]
    public void ReportsMemoryInUse() => Assert.True(OnJsThread(engine => engine.MemoryUsed()) > 0);
}
