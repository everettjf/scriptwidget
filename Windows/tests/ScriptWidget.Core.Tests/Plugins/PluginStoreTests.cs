using System.Diagnostics;
using System.Runtime.InteropServices;
using ScriptWidget.Core.Plugins;
using static ScriptWidget.Core.Tests.Plugins.PluginFixtures;

namespace ScriptWidget.Core.Tests.Plugins;

public sealed class PluginStoreTests : IDisposable
{
    private readonly string temporary = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", "plugins-" + Guid.NewGuid().ToString("N"));
    private readonly string root;
    private readonly PluginStore store;
    private readonly byte[] manifest = Bytes();
    private readonly int builtInCount = PluginStore.BuiltIns.Count;

    public PluginStoreTests()
    {
        Directory.CreateDirectory(temporary);
        root = Path.Combine(temporary, "Plugins");
        store = new PluginStore(root);
    }

    public void Dispose()
    {
        try { Directory.Delete(temporary, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
    }

    private PluginManifest Install(byte[] bytes) => store.Install(new MemoryStream(bytes));

    private static List<string> Names(string directory) =>
        Directory.Exists(directory) ? Directory.EnumerateFileSystemEntries(directory).Select(Path.GetFileName).OfType<string>().Order(StringComparer.Ordinal).ToList() : [];

    /// <summary>Installed plugin directories; the hidden staging directory must be empty.</summary>
    private List<string> InstalledDirectories()
    {
        Assert.Empty(Names(Path.Combine(root, ".staging")));
        return Names(root).Where(name => name != ".staging").ToList();
    }

    private void AssertImportRejected(string expected, byte[] archive)
    {
        var error = Failure(() => Install(archive));
        Assert.True(error.Message.Contains(expected, StringComparison.Ordinal), $"Expected \"{expected}\" in \"{error.Message}\"");
        Assert.Empty(InstalledDirectories());
        Assert.Null(store.Manifest(ID));
    }

    private byte[] Export(string id, PluginStore? from = null)
    {
        using var output = new MemoryStream();
        (from ?? store).Export(id, output);
        return output.ToArray();
    }

    private static byte[] Filled(int count, char value) => Enumerable.Repeat((byte)value, count).ToArray();

    [Fact]
    public void ListsBuiltInsWhenNothingIsInstalled()
    {
        Assert.Equal(["GitHub Public API", "Open-Meteo"], store.List().Select(plugin => plugin.Manifest.Name));
        Assert.All(store.List(), plugin => Assert.True(plugin.BuiltIn && plugin.Readme!.StartsWith("# ", StringComparison.Ordinal)));
        Assert.NotNull(store.Manifest("app.scriptwidget.datasource.open-meteo"));
        Assert.Null(store.Manifest("dev.unknown.plugin"));
        Assert.False(Directory.Exists(root), "listing must not create the directory");
    }

    [Fact]
    public void InstallsBarePluginJson()
    {
        Assert.Equal(ID, Install(manifest).Id);
        Assert.Equal(["test-source"], InstalledDirectories());
        Assert.Equal(["plugin.json"], Names(Path.Combine(root, "test-source")));
        var listed = store.List().First(plugin => plugin.Manifest.Id == ID);
        Assert.False(listed.BuiltIn);
        Assert.Null(listed.Readme);
        Assert.Equal(builtInCount + 1, store.List().Count);
        Assert.Equal(Manifest(), store.Manifest(ID));
    }

    [Fact]
    public void InstallsArchiveWithFilesAtTheRoot()
    {
        Install(ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("README.md", "# Test\n\nHello")));
        Assert.Equal(["README.md", "plugin.json"], Names(Path.Combine(root, "test-source")));
        Assert.Equal("# Test\n\nHello", store.List().First(plugin => plugin.Manifest.Id == ID).Readme);
    }

    [Fact]
    public void InstallsArchiveWithOneDirectoryAndIgnoresHiddenFiles()
    {
        Install(ZipFixtures.DeflatedZip(
            ("Test/", []), ("Test/plugin.json", manifest), ("Test/README.md", Utf8("docs")),
            ("Test/.DS_Store", [1]), ("__MACOSX/Test/._plugin.json", [2]), (".hidden", [3])));
        Assert.Equal(["README.md", "plugin.json"], Names(Path.Combine(root, "test-source")));
    }

    [Fact]
    public void DuplicateIdsAreRefused()
    {
        Install(manifest);
        Assert.Equal($"Plugin {ID} is already installed.", Failure(() => Install(manifest)).Message);
        Assert.Equal(["test-source"], InstalledDirectories());
        var builtIn = PluginStore.BuiltIns[0];
        Assert.Equal($"Plugin {builtIn.Id} is already installed.", Failure(() => Install(Utf8(builtIn.ToJson()))).Message);
    }

    [Fact]
    public void DirectoryNamesAreSlugsAndNeverCollide()
    {
        Install(Bytes(root => root["name"] = "../../Evil  Name!"));
        Install(Bytes(root => { root["name"] = "evil name"; root["id"] = "dev.scriptwidget.second"; }));
        Install(Bytes(root => { root["name"] = "数据"; root["id"] = "dev.scriptwidget.third"; }));
        Assert.Equal(["evil-name", "evil-name-2", "plugin"], InstalledDirectories());
        Assert.Equal(["Plugins"], Names(temporary));
    }

    /// <summary>Windows only: a plugin named after a device does not become a device path.</summary>
    [Fact]
    public void DeviceNamesAreNotUsedAsDirectoryNames()
    {
        Install(Bytes(root => root["name"] = "CON"));
        Install(Bytes(root => { root["name"] = "com1"; root["id"] = "dev.scriptwidget.second"; }));
        Assert.Equal(["plugin-com1", "plugin-con"], InstalledDirectories());
        Assert.NotNull(store.Manifest(ID));
    }

    [Fact]
    public void InvalidManifestsAreNotInstalled()
    {
        AssertImportRejected("plugin.json contains unknown fields.", Bytes(root => root["unexpected"] = true));
        AssertImportRejected("baseURL must be an HTTPS URL", ZipFixtures.RawZip(new RawEntry("plugin.json", Bytes(root => root["baseURL"] = "http://api.example.com"))));
        AssertImportRejected("plugin.json is not valid JSON.", Utf8("not json"));
        AssertImportRejected("Archive must contain one Data Source Plugin 1.0 package.", []);
    }

    [Fact]
    public void OversizeInputIsRejected()
    {
        AssertImportRejected("A plugin package may not exceed 512 KiB.", Filled(PluginStore.MaximumPackageBytes + 1, ' '));
        AssertImportRejected("A plugin package may not exceed 512 KiB.",
            ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("README.md", new byte[PluginStore.MaximumPackageBytes])));
        // A highly compressible README fits the archive limit but not the expanded limit.
        AssertImportRejected("README.md exceeds 512 KiB.",
            ZipFixtures.DeflatedZip(("plugin.json", manifest), ("README.md", Filled(PluginStore.MaximumReadmeBytes + 1, 'a'))));
        AssertImportRejected("plugin.json exceeds 256 KiB.",
            ZipFixtures.DeflatedZip(("plugin.json", Filled(PluginValidator.MaximumManifestBytes + 1, ' '))));
    }

    [Fact]
    public void OnlyPluginJsonAndReadmeAreAllowed()
    {
        const string only = "A plugin package allows only plugin.json and optional README.md.";
        AssertImportRejected(only, ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("main.js", "fetch()")));
        AssertImportRejected(only, ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("lib/native.so", "x")));
        AssertImportRejected(only, ZipFixtures.RawZip(new RawEntry("Test/plugin.json", manifest), new RawEntry("Test/extra/plugin.json", manifest)));
        AssertImportRejected(only, ZipFixtures.RawZip(new RawEntry("Test/README.md", "no manifest")));
        AssertImportRejected(only, ZipFixtures.RawZip(new RawEntry("Test/Plugin.json", manifest)));
        AssertImportRejected(only, ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("readme.md", "wrong case")));
        AssertImportRejected("Archive must contain one Data Source Plugin 1.0 package.", ZipFixtures.RawZip(new RawEntry("A/plugin.json", manifest), new RawEntry("B/plugin.json", manifest)));
        AssertImportRejected("Archive must contain one Data Source Plugin 1.0 package.", ZipFixtures.RawZip(new RawEntry("README.md", "no package")));
        AssertImportRejected("README.md must be UTF-8 text.", ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("README.md", [0xFF])));
    }

    [Fact]
    public void UnsafeArchivesAreRejectedBeforeAnythingIsWritten()
    {
        var plugin = new RawEntry("plugin.json", manifest);
        AssertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.RawZip(plugin, new RawEntry("../README.md", "x")));
        AssertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.RawZip(plugin, new RawEntry("/README.md", "x")));
        AssertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.RawZip(plugin, new RawEntry("Test\\README.md", "x")));
        AssertImportRejected("unsafe or non-UTF-8 path", ZipFixtures.RawZip(plugin, new RawEntry("C:README.md", "x")));
        AssertImportRejected("Symbolic links are not allowed", ZipFixtures.RawZip(plugin, new RawEntry("README.md", Utf8("/etc/hosts"), externalAttributes: 0xA1FFL << 16)));
        AssertImportRejected("duplicate or case-colliding paths", ZipFixtures.RawZip(plugin, new RawEntry("PLUGIN.JSON", manifest)));
        AssertImportRejected("duplicate or case-colliding paths", ZipFixtures.RawZip(plugin, new RawEntry("plugin.json", manifest)));
        AssertImportRejected("Encrypted package entries", ZipFixtures.RawZip(new RawEntry("plugin.json", manifest, flags: 0x0801)));
        AssertImportRejected("Unsupported ZIP compression method", ZipFixtures.RawZip(new RawEntry("plugin.json", manifest, method: 12)));
        AssertImportRejected("no valid ZIP central directory", Utf8("PK" + (char)3 + (char)4 + " truncated"));
        Assert.Empty(Names(temporary));
    }

    [Fact]
    public void ForgedSizesAndCorruptEntriesAreRejected()
    {
        var archive = ZipFixtures.DeflatedZip(("plugin.json", manifest));
        AssertImportRejected("The plugin archive is corrupt.", ZipFixtures.ForgeDeclaredSize(archive, 0, manifest.Length - 1));
        AssertImportRejected("The plugin archive is corrupt.", ZipFixtures.ForgeDeclaredSize(archive, 0, manifest.Length + 1));
        var stored = ZipFixtures.RawZip(new RawEntry("plugin.json", manifest));
        stored[40 + "plugin.json".Length] += 1;
        AssertImportRejected("The plugin archive is corrupt.", stored);
    }

    [Fact]
    public void ExportRoundTripsThroughImport()
    {
        Install(ZipFixtures.RawZip(new RawEntry("plugin.json", manifest), new RawEntry("README.md", "# Docs")));
        var exported = Export(ID);
        var second = new PluginStore(Path.Combine(temporary, "Other"));
        Assert.Equal(ID, second.Install(new MemoryStream(exported)).Id);
        Assert.Equal("# Docs", second.List().First(plugin => plugin.Manifest.Id == ID).Readme);
        Assert.Equal(Manifest(), second.Manifest(ID));
        // The same plugin always yields the same bytes.
        Assert.Equal(exported, Export(ID));
    }

    [Fact]
    public void ExportIncludesOnlyThePluginFiles()
    {
        Install(manifest);
        File.WriteAllText(Path.Combine(root, "test-source", "secret.txt"), "not part of the plugin");
        Assert.Equal(["plugin.json"], ZipFixtures.Read(Export(ID)).Select(entry => entry.Name));
    }

    [Fact]
    public void BuiltInsExportButCannotBeDeleted()
    {
        var id = PluginStore.BuiltIns[1].Id;
        // A built-in id is already present, so the export is checked by decoding it.
        var entries = ZipFixtures.Read(Export(id)).ToDictionary(entry => entry.Name, entry => entry.Data);
        Assert.Equal(["README.md", "plugin.json"], entries.Keys.Order(StringComparer.Ordinal));
        Assert.Equal(PluginStore.BuiltIns[1], PluginValidator.Decode(entries["plugin.json"]));
        Assert.Equal("Built-in plugins cannot be deleted.", Failure(() => store.Delete(id)).Message);
        Assert.Equal("Plugin not found.", Failure(() => store.Delete("dev.unknown.plugin")).Message);
        Assert.Equal("Plugin not found.", Failure(() => store.Export("dev.unknown.plugin", new MemoryStream())).Message);
    }

    [Fact]
    public void DeleteRemovesThePlugin()
    {
        Install(manifest);
        store.Delete(ID);
        Assert.Empty(InstalledDirectories());
        Assert.Null(store.Manifest(ID));
        Assert.Equal(builtInCount, store.List().Count);
        Install(manifest);
        Assert.Equal(["test-source"], InstalledDirectories());
    }

    [Fact]
    public void TamperedOrLinkedDirectoriesAreNotLoaded()
    {
        Install(manifest);
        var file = Path.Combine(root, "test-source", "plugin.json");
        File.WriteAllBytes(file, Bytes(root => root["baseURL"] = "http://api.example.com"));
        Assert.Null(store.Manifest(ID)); // a stored manifest is validated on every read
        File.WriteAllBytes(file, manifest);
        Assert.NotNull(store.Manifest(ID));

        // A link in the store is neither a plugin directory nor a plugin file.
        var outside = Path.Combine(temporary, "outside");
        Directory.CreateDirectory(outside);
        var linked = Path.Combine(outside, "plugin.json");
        File.WriteAllBytes(linked, Bytes(root => root["id"] = "dev.scriptwidget.linked"));
        // The file itself is a valid plugin when it sits in a real directory of the store.
        Directory.CreateDirectory(Path.Combine(root, "control"));
        File.Copy(linked, Path.Combine(root, "control", "plugin.json"));
        Assert.NotNull(store.Manifest("dev.scriptwidget.linked"));
        Directory.Delete(Path.Combine(root, "control"), recursive: true);

        LinkDirectory(Path.Combine(root, "linked"), outside);
        Assert.Null(store.Manifest("dev.scriptwidget.linked"));
        Directory.CreateDirectory(Path.Combine(root, "real"));
        // Creating a file symbolic link needs a privilege or developer mode; a hard link never does.
        try
        {
            File.CreateSymbolicLink(Path.Combine(root, "real", "plugin.json"), linked);
            Assert.Null(store.Manifest("dev.scriptwidget.linked"));
            File.Delete(Path.Combine(root, "real", "plugin.json"));
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        Assert.True(CreateHardLink(Path.Combine(root, "real", "plugin.json"), linked, IntPtr.Zero), "the hard link could not be created");
        Assert.Null(store.Manifest("dev.scriptwidget.linked"));
        Assert.DoesNotContain(store.List(), plugin => plugin.Manifest.Id == "dev.scriptwidget.linked");
    }

    [Fact]
    public void ListIsSortedByNameAcrossBuiltInAndInstalledPlugins()
    {
        Install(Bytes(root => root["name"] = "Alpha"));
        Assert.Equal(["Alpha", "GitHub Public API", "Open-Meteo"], store.List().Select(plugin => plugin.Manifest.Name));
    }

    /// <summary>A directory symbolic link, or a junction where the account may not create symbolic links.</summary>
    private static void LinkDirectory(string link, string target)
    {
        try
        {
            Directory.CreateSymbolicLink(link, target);
            return;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        using var process = Process.Start(new ProcessStartInfo("cmd.exe", $"/c mklink /J \"{link}\" \"{target}\"") { CreateNoWindow = true, UseShellExecute = false, RedirectStandardOutput = true, RedirectStandardError = true })!;
        process.WaitForExit();
        Assert.True(process.ExitCode == 0 && Directory.Exists(link), "the junction could not be created");
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateHardLink(string newFileName, string existingFileName, IntPtr securityAttributes);
}
