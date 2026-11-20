using System.Text.Json.Nodes;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Core.Tests.Api;

namespace ScriptWidget.Core.Tests.Runtime;

public sealed class ExecutionDiagnosticsTests(ScriptRuntimeFixture runtime) : IClassFixture<ScriptRuntimeFixture>
{
    private sealed class PendingNetwork(bool complete) : INativeModule
    {
        public bool Handles(string operation) => operation == "http.request";
        public void Start(ExecutionRequest request, string operation, JsonObject? payload, NativeCompletion done)
        {
            if (complete) done(true, Json.Quote("ok"));
        }
    }

    private ExecutionResult Run(string source, bool complete = false)
    {
        var files = new MemoryPackageFiles(new Dictionary<string, string> { ["main.jsx"] = source });
        var request = new ExecutionRequest
        {
            Files = files, Prepared = runtime.Compiler.Prepare(files), Modules = [new PendingNetwork(complete)], TimeoutMilliseconds = 200,
        };
        var result = runtime.Executor.Execute(request);
        Assert.True(request.Session.Finished);
        Assert.True(request.Session.Cancellation.IsCancellationRequested);
        return result;
    }

    [Fact]
    public void PendingNetworkIsIdentifiedWithoutDisclosingTheUrl()
    {
        var result = Run("await fetch('https://example.com/private?token=secret'); $render(<text>done</text>);");
        Assert.Equal("resourceLimit", result.Error?.Kind);
        Assert.Contains("0.2-second", result.Error!.Message);
        Assert.Contains("network request", result.Error.Message);
        Assert.DoesNotContain("example.com", result.Error.Message);
        Assert.DoesNotContain("secret", result.Error.Message);
    }

    [Fact]
    public void SynchronousLoopIsStillAnExecutionLimit()
    {
        var result = Run("for (;;) {}");
        Assert.Equal("resourceLimit", result.Error?.Kind);
        Assert.DoesNotContain("network", result.Error!.Message);
    }

    [Fact]
    public void CompletedNetworkIsNotBlamedForALaterLoop()
    {
        var result = Run("const value = await fetch('https://example.com/'); for (;;) {} $render(<text>{value}</text>);", complete: true);
        Assert.True(result.Error?.Kind == "resourceLimit", $"{result.Error}; tree: {result.Tree}; logs: {string.Join(';', result.Logs)}");
        Assert.DoesNotContain("network", result.Error!.Message);
    }

    [Fact]
    public void SuccessfulNetworkKeepsItsResult()
    {
        var result = Run("const text = await fetch('https://example.com/'); $render(<text>{text}</text>);", complete: true);
        Assert.Null(result.Error);
        Assert.Contains("ok", result.Tree);
    }
}
