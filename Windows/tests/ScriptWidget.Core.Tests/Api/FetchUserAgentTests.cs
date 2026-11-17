using System.Net;
using ScriptWidget.Core.Api;

namespace ScriptWidget.Core.Tests.Api;

public class FetchUserAgentTests
{
    private static readonly IReadOnlyList<IPAddress> Public = [new IPAddress(new byte[] { 93, 184, 216, 34 })];

    private static string? UserAgent(IReadOnlyDictionary<string, string> headers)
    {
        var handler = new FakeHandler(_ => FakeHandler.Text(200, "ok"));
        var module = new FetchModule(_ => Public, handler);
        module.Perform("GET", new Uri("https://example.com/"), headers, null, 3000, _ => true);
        var sent = Assert.Single(handler.Requests).Headers;
        return sent.FirstOrDefault(header => header.Key.Equals("User-Agent", StringComparison.OrdinalIgnoreCase)).Value;
    }

    [Fact]
    public void RequestsNameTheClientWhenTheScriptDoesNot()
    {
        var agent = UserAgent(new Dictionary<string, string>());
        Assert.Equal(FetchModule.DefaultUserAgent, agent);
        Assert.StartsWith("ScriptWidget-Windows/", agent);
        // Nothing about the user or the machine.
        Assert.DoesNotContain(Environment.MachineName, agent!, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain(Environment.UserName, agent!, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void AScriptsOwnUserAgentWins()
    {
        Assert.Equal("my-widget/2.0", UserAgent(new Dictionary<string, string> { ["user-agent"] = "my-widget/2.0" }));
    }
}
