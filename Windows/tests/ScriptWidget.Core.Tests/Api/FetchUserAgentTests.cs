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
    public void CredentialsStayWithTheOriginTheScriptAddressed()
    {
        var handler = new FakeHandler(message => message.RequestUri!.Host switch
        {
            "api.example.com" when message.RequestUri.AbsolutePath == "/start" => FakeHandler.Redirect(302, "/same-origin"),
            "api.example.com" when message.RequestUri.AbsolutePath == "/same-origin" => FakeHandler.Redirect(302, "https://cdn.example.net/elsewhere"),
            _ => FakeHandler.Text(200, "arrived"),
        });
        var module = new FetchModule(_ => Public, handler);
        var headers = new Dictionary<string, string> { ["Authorization"] = "Bearer secret", ["Cookie"] = "session=1", ["Accept"] = "application/json" };
        module.Perform("GET", new Uri("https://api.example.com/start"), headers, null, 3000, _ => true);

        Assert.Equal(3, handler.Requests.Count);
        // The same origin keeps the credentials across a redirect.
        Assert.Equal("Bearer secret", handler.Requests[1].Headers["Authorization"]);
        Assert.Equal("session=1", handler.Requests[1].Headers["Cookie"]);
        // Another origin gets the ordinary headers only.
        var elsewhere = handler.Requests[2];
        Assert.Equal("cdn.example.net", elsewhere.Uri.Host);
        Assert.False(elsewhere.Headers.ContainsKey("Authorization"));
        Assert.False(elsewhere.Headers.ContainsKey("Cookie"));
        Assert.Equal("application/json", elsewhere.Headers["Accept"]);
    }

    [Fact]
    public void AScriptsOwnUserAgentWins()
    {
        Assert.Equal("my-widget/2.0", UserAgent(new Dictionary<string, string> { ["user-agent"] = "my-widget/2.0" }));
    }
}
