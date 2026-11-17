using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Runtime;
using Xunit.Abstractions;

namespace ScriptWidget.Core.Tests;

/// <summary>
/// Runs every bundled package that needs no live data through QuickJS and
/// compares the canonical element tree with the one JavaScriptCore produced
/// (Web/preview-engine/test/parity/native-trees.json).
/// </summary>
[Collection("Intl overrides")]
public class ParityTests(ITestOutputHelper output)
{
    [Fact]
    public void BundledPackagesProduceTheSameTreesAsJavaScriptCore()
    {
        var corpus = Json.ParseObject(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "testassets", "parity-corpus.json")));
        IntlBridge.TimeZoneOverride = corpus.OptString("timeZone");
        IntlBridge.LocaleOverride = corpus.OptString("locale", "en-US");
        try
        {
            var scripts = new SharedScripts();
            using var compiler = new PackageCompiler(scripts);
            var executor = new ScriptExecutor(scripts);
            // Each package starts with empty storage, like the JavaScriptCore reference run.
            var storageDirectory = Path.Combine(Path.GetTempPath(), "scriptwidget-tests", "parity-storage-" + Guid.NewGuid().ToString("N"));
            var storage = new StorageModule(storageDirectory);
            var prelude = corpus.OptString("prelude");
            var packages = corpus.OptArray("corpus")!;
            var failures = new List<string>();
            long compileMilliseconds = 0, executeMilliseconds = 0, slowest = 0;

            for (var index = 0; index < packages.Count; index++)
            {
                var item = (JsonObject)packages[index]!;
                var name = item.OptString("name");
                var text = new Dictionary<string, string>();
                foreach (var (path, content) in item.OptObject("files")!) text[path] = content!.AsText()!;
                var binaries = new Dictionary<string, byte[]>();
                foreach (var path in item.OptArray("binaries") ?? new JsonArray()) binaries[path!.AsText()!] = [];
                var files = new MemoryPackageFiles(text, binaries);
                var expected = item.OptObject("expected");
                var expectedTree = expected is not null && expected.Has("tree") ? expected.OptString("tree") : null;

                var compileStart = System.Diagnostics.Stopwatch.GetTimestamp();
                PreparedPackage prepared;
                try { prepared = compiler.Prepare(files, prelude: prelude); }
                catch (RuntimeError error)
                {
                    failures.Add($"{name}: prepare failed [{error.Kind}] {Clip(error.Message, 300)}");
                    continue;
                }
                compileMilliseconds += (long)System.Diagnostics.Stopwatch.GetElapsedTime(compileStart).TotalMilliseconds;
                var result = executor.Execute(new ExecutionRequest { Prepared = prepared, Files = files, Modules = [storage], PackageID = $"parity-{index}" });
                executeMilliseconds += result.ElapsedMilliseconds;
                slowest = Math.Max(slowest, result.ElapsedMilliseconds);

                if (expectedTree is null) { failures.Add($"{name}: no native reference tree"); continue; }
                if (result.Tree == expectedTree) continue;
                if (result.Tree is not { } actual) { failures.Add($"{name}: error [{result.Error?.Kind}] {Clip(result.Error?.Message ?? "", 400)}"); continue; }
                var at = 0;
                while (at < actual.Length && at < expectedTree.Length && actual[at] == expectedTree[at]) at++;
                failures.Add($"{name}: tree differs at {at}\n      native : {Window(expectedTree, at)}\n      windows: {Window(actual, at)}");
            }
            try { Directory.Delete(storageDirectory, true); } catch (IOException) { }
            var total = packages.Count;
            var summary = $"parity {total - failures.Count}/{total}; compile {compileMilliseconds} ms total; execute {executeMilliseconds} ms total, slowest {slowest} ms";
            output.WriteLine(summary);
            Assert.True(total > 0, "corpus is empty");
            Assert.True(failures.Count == 0, summary + "\n" + string.Join("\n", failures));
        }
        finally
        {
            IntlBridge.TimeZoneOverride = null;
            IntlBridge.LocaleOverride = null;
        }
    }

    private static string Clip(string text, int length) => text.Length <= length ? text : text[..length];
    private static string Window(string text, int at) => text[Math.Max(0, at - 60)..Math.Min(text.Length, at + 100)];
}

/// <summary>Tests that change the process-wide locale or time zone run one at a time.</summary>
[CollectionDefinition("Intl overrides", DisableParallelization = true)]
public class IntlOverridesCollection;
