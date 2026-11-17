using System.Text;
using ScriptWidget.Core.Hosting;

namespace ScriptWidget.Core.Tests.Packages;

/// <summary>
/// A bundled template without <c>widget.json</c> gets a manifest when it is copied into the library.
/// A manifest without <c>network</c> stops every request, so the hosts the template names are declared.
/// </summary>
public class BundledManifestTests
{
    private static Dictionary<string, byte[]> Files(string main, string? meta = null)
    {
        var files = new Dictionary<string, byte[]>(StringComparer.Ordinal) { ["main.jsx"] = Encoding.UTF8.GetBytes(main) };
        if (meta is not null) files["meta.json"] = Encoding.UTF8.GetBytes(meta);
        return files;
    }

    [Fact]
    public void DeclaresTheHostsNamedInTheSource()
    {
        var manifest = Library.BundledManifest("Daily Quote", Files(
            "// https://atomsprout.com/scriptwidget\nconst url = \"https://ZenQuotes.io/api/today\";\nconst other = `http://api.example.com/${id}`;\nconst result = await fetch(url);\n",
            "{\"description\":\"A quote\",\"category\":\"productivity\"}"));
        Assert.Equal(["network"], manifest.OptArray("permissions")!.Select(node => node!.GetValue<string>()));
        Assert.Equal(["api.example.com", "zenquotes.io"], manifest.OptArray("networkDomains")!.Select(node => node!.GetValue<string>()));
        Assert.Equal("A quote", manifest.OptString("description"));
        Assert.StartsWith("local.", manifest.OptString("id"));
    }

    [Fact]
    public void ATemplateWithoutUrlsGetsNoNetworkPermission()
    {
        var manifest = Library.BundledManifest("Clock", Files("// see https://example.com\n$render(<text>hi</text>)\n"));
        Assert.Empty(manifest.OptArray("permissions")!);
        Assert.Empty(manifest.OptArray("networkDomains")!);
    }

    [Fact]
    public void NamesTheGlobalsWindowsDoesNotImplement()
    {
        foreach (var name in new[] { "health", "calendar", "location", "music" }) Assert.True(Library.IsUnsupportedApi(name), name);
        foreach (var name in new[] { "storage", "device", "system", "file", "http", "xml", "weather", "dataSource", "healthy", "" }) Assert.False(Library.IsUnsupportedApi(name), name);
    }

    [Fact]
    public void HostsThatCannotBeDeclaredAreLeftOut()
    {
        var manifest = Library.BundledManifest("Odd", Files(
            "fetch(`https://api.${region}.example.com/x`); fetch(\"http://localhost/x\"); fetch(\"http://192.168.1.1/x\"); fetch(\"https://-bad.example.com\");\n"));
        Assert.Empty(manifest.OptArray("permissions")!);
        Assert.Empty(manifest.OptArray("networkDomains")!);
    }
}
