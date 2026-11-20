using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core;
using ScriptWidget.Core.Skills;
using ScriptWidget.Core.Gallery;
using ScriptWidget.Core.AI;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Cli;

/// <summary>
/// swcli: runs ScriptWidget packages from the command line with the same
/// runtime as the desktop host. Used by CI to check packages and to draw
/// reference images, and for debugging.
/// </summary>
internal static partial class Program
{
    private const string Usage = """
        Usage: swcli <command> [options]

        Package commands (take a package folder):
          validate <dir>                      Check widget.json and compile the package.
          run <dir> [options]                 Run the script and print the element tree, logs and errors as JSON.
          render <dir> --output <png> [opts]  Run the script and draw the widget to a PNG file.
          timeline <dir>                      Print the current timeline slot and the next transition.
          pack <dir> <file.swt>               Write the package as a .swt archive.

        Options for run and render:
          --family <name>   small, medium, large or extraLarge (default medium)
          --param <text>    value of $getenv("widget-param")
          --dark            run and draw in the dark theme
          --scale <n>       pixels per point for render (default 2)
          --now <ms>        fixed clock for dates in render (milliseconds since 1970)
          --data <dir>      data folder for storage and caches (default: a temporary folder)

        Library and desktop commands (use the signed-in user's data):
          list                                List installed packages.
          install <file.swt>                  Install an archive into the library.
          templates                           List the bundled templates that run on Windows.
          widgets                             List the widgets on the desktop (needs the host running).
          add <package> [--family <name>]     Put a package on the desktop (needs the host running).
          refresh                             Refresh every desktop widget (needs the host running).
          host <json>                         Send one request to the host and print the answer (for scripts).
          skills <command>                    list, show, import, export, enable, disable, remove (--data <dir>).
          gallery <command>                   list, show <id>, install <id>, update <id> (--data <dir>).
          ai <command>                        configure, profiles, key, models, new, continue, retry, list, show, fork, select, apply.

        --data <dir> also isolates list, install, skills, gallery and ai from your desktop library.
        """;

    private static int Main(string[] arguments)
    {
        Console.OutputEncoding = new UTF8Encoding(false);
        if (arguments.Length == 0 || arguments[0] is "--help" or "-h" or "help") { Console.WriteLine(Usage); return arguments.Length == 0 ? 2 : 0; }
        try
        {
            var options = new Options(arguments.Skip(1).ToArray());
            return arguments[0] switch
            {
                "validate" => Validate(options),
                "run" => Run(options),
                "render" => Render(options),
                "timeline" => Timeline(options),
                "pack" => Pack(options),
                "list" => List(options),
                "install" => Install(options),
                "templates" => Templates(),
                "skills" => Skills(options),
                "gallery" => Gallery(options).GetAwaiter().GetResult(),
                "ai" => Ai(options).GetAwaiter().GetResult(),
                "widgets" => Host(new JsonObject { ["command"] = "list" }),
                "add" => Add(options),
                "refresh" => Host(new JsonObject { ["command"] = "refresh" }),
                "host" => Host(Json.ParseObject(options.Positional(0, "request"))),
                _ => Fail($"Unknown command {arguments[0]}\n\n{Usage}", 2),
            };
        }
        catch (ArgumentException error) { return Fail(error.Message, 2); }
        catch (PackageException error) { return Fail($"[{error.Code}] {error.Message}", 1); }
        catch (SkillException error) { return Fail($"[{error.Code}] {error.Message}", 1); }
        catch (GalleryException error) { return Fail($"[{error.Code}] {error.Message}", 1); }
        catch (AiException error) { return Fail($"[{error.Code}] {error.Message}", 1); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return Fail(error.Message, 1); }
    }

    private static int Fail(string message, int code)
    {
        Console.Error.WriteLine(message);
        return code;
    }

    private static async Task<int> Gallery(Options options)
    {
        var command = options.Positional(0, "Gallery command");
        if (command is not ("list" or "show" or "install" or "update")) throw new ArgumentException("Usage: swcli gallery list|show <id>|install <id>|update <id> [--data <dir>]");
        var paths = new DataPaths(options.Value("data"));
        var library = new Library(paths);
        using var transport = new GalleryHttpTransport();
        var service = new GalleryService(paths, library, new SkillStore(paths.Skills), transport);
        var loaded = await service.LoadAsync();
        JsonObject Describe(GalleryItem item) => new()
        {
            ["id"] = item.Id, ["kind"] = item.Kind, ["name"] = item.Name, ["version"] = item.Version,
            ["summary"] = item.Summary, ["state"] = service.State(item), ["sourceURL"] = item.SourceUrl,
        };
        if (command == "list")
        {
            var items = new JsonArray();
            foreach (var entry in loaded.Index.Items) items.Append(Describe(entry));
            Print(new JsonObject { ["ok"] = true, ["offline"] = loaded.IsOffline, ["warning"] = loaded.Warning, ["items"] = items });
            return 0;
        }
        var item = loaded.Index.Items.FirstOrDefault(item => item.Id == options.Positional(1, "Gallery item id")) ?? throw new GalleryException("not_found", "Gallery item not found.");
        if (command == "show") { Print(Describe(item)); return 0; }
        using var runtime = new WidgetRuntime(paths);
        var installed = await service.InstallAsync(item, runtime.ValidatePackage, updateExisting: command == "update");
        if (options.Value("data") is null) HostPipe.Send(new JsonObject { ["command"] = "library-changed" }, 300, 3000);
        Print(new JsonObject { ["ok"] = true, ["id"] = item.Id, ["localName"] = installed.Installation.LocalName, ["updated"] = installed.Updated });
        return 0;
    }

    private static int Skills(Options options)
    {
        var store = new SkillStore(new DataPaths(options.Value("data")).Skills);
        var command = options.Positional(0, "Skills command");
        JsonObject Describe(WidgetSkill skill) => new()
        {
            ["id"] = skill.Id, ["name"] = skill.Name, ["version"] = skill.Version, ["summary"] = skill.Summary,
            ["builtIn"] = skill.IsBuiltIn, ["enabled"] = store.EnabledIds().Contains(skill.Id),
        };
        switch (command)
        {
            case "list":
                var items = new JsonArray();
                foreach (var skill in store.List()) items.Append(Describe(skill));
                Print(new JsonObject { ["ok"] = true, ["skills"] = items });
                break;
            case "show":
                var found = store.Find(options.Positional(1, "Skill id")) ?? throw new SkillException("skill_not_found", "Skill not found.");
                var detail = Describe(found);
                detail["instruction"] = found.Instruction;
                Print(detail);
                break;
            case "import":
                using (var input = File.OpenRead(options.Positional(1, "Skill archive"))) Print(Describe(store.ImportArchive(input)));
                break;
            case "export":
                // Do not truncate an existing archive without an explicit choice by its owner.
                using (var archive = new MemoryStream())
                {
                    store.Export(options.Positional(1, "Skill id"), archive);
                    using var output = new FileStream(options.Positional(2, "output .swskill file"), FileMode.CreateNew, FileAccess.Write);
                    archive.Position = 0;
                    archive.CopyTo(output);
                }
                Print(new JsonObject { ["ok"] = true });
                break;
            case "enable" or "disable":
                store.SetEnabled(options.Positional(1, "Skill id"), command == "enable");
                Print(new JsonObject { ["ok"] = true });
                break;
            case "remove":
                store.Delete(options.Positional(1, "Skill id"));
                Print(new JsonObject { ["ok"] = true });
                break;
            default: throw new ArgumentException("Usage: swcli skills list|show <id>|import <archive>|export <id> <file>|enable <id>|disable <id>|remove <id> [--data <dir>]");
        }
        return 0;
    }

    private static void Print(JsonObject json) => Console.WriteLine(Json.Stringify(json, indented: true));

    // MARK: - Package commands

    private static DataPaths ScratchData(Options options) =>
        new(options.Value("data") ?? Path.Combine(Path.GetTempPath(), "scriptwidget-cli", Environment.ProcessId.ToString(System.Globalization.CultureInfo.InvariantCulture)));

    private static (DiskPackageFiles Files, string Directory) Package(Options options)
    {
        var directory = Path.GetFullPath(options.Positional(0, "package folder"));
        if (!Directory.Exists(directory)) throw new ArgumentException($"Not a package folder: {directory}");
        return (new DiskPackageFiles(directory), directory);
    }

    private static int Validate(Options options)
    {
        var (files, directory) = Package(options);
        using var compiler = new PackageCompiler(new SharedScripts());
        var report = new JsonObject { ["package"] = directory };
        var manifestText = files.ReadText(PackageManifests.FileName);
        if (manifestText is not null)
        {
            var validation = compiler.ValidateManifest(manifestText, files.Paths());
            report["manifest"] = validation;
            if (!validation.OptBoolean("ok")) { report["ok"] = false; Print(report); return 1; }
        }
        else report["manifest"] = null;
        try
        {
            compiler.Prepare(files);
            report["ok"] = true;
        }
        catch (RuntimeError error)
        {
            report["ok"] = false;
            report["error"] = new JsonObject { ["kind"] = error.Kind, ["message"] = error.Message };
        }
        Print(report);
        return report.OptBoolean("ok") ? 0 : 1;
    }

    private static RunRequest Request(Options options, DiskPackageFiles files, string directory) => new()
    {
        Files = files,
        PackageID = "cli:" + directory,
        Family = WidgetFamilies.IsKnown(options.Value("family") ?? "medium") ? options.Value("family") ?? "medium" : throw new ArgumentException($"Unknown family {options.Value("family")}"),
        Parameter = options.Value("param") ?? "",
        DarkMode = options.Flag("dark"),
    };

    private static JsonObject Describe(RunResult result)
    {
        var logs = new JsonArray();
        foreach (var entry in result.Execution.Logs) logs.Append(new JsonObject { ["level"] = entry.Level, ["message"] = entry.Message });
        return new JsonObject
        {
            ["ok"] = result.Execution.Error is null,
            ["error"] = result.Execution.Error is { } error ? new JsonObject { ["kind"] = error.Kind, ["message"] = error.Message } : null,
            ["elapsedMilliseconds"] = result.Execution.ElapsedMilliseconds,
            ["logs"] = logs,
            ["diagnostics"] = result.Execution.Diagnostics.DeepClone(),
            ["nextTimelineTransition"] = result.NextTimelineTransition,
        };
    }

    private static int Run(Options options)
    {
        var (files, directory) = Package(options);
        using var runtime = new WidgetRuntime(ScratchData(options));
        var result = runtime.Run(Request(options, files, directory));
        var report = Describe(result);
        report["tree"] = result.Execution.Tree is { } tree ? Json.TryParse(tree) : null;
        Print(report);
        return result.Execution.Error is null ? 0 : 1;
    }

    private static int Render(Options options)
    {
        var (files, directory) = Package(options);
        var output = Path.GetFullPath(options.Value("output") ?? throw new ArgumentException("render needs --output <png>"));
        var scale = float.TryParse(options.Value("scale") ?? "2", System.Globalization.CultureInfo.InvariantCulture, out var parsed) && parsed is >= 0.5f and <= 8 ? parsed : throw new ArgumentException("--scale must be between 0.5 and 8");
        long? now = options.Value("now") is { } text ? long.Parse(text, System.Globalization.CultureInfo.InvariantCulture) : null;
        using var runtime = new WidgetRuntime(ScratchData(options));
        var request = Request(options, files, directory);
        var result = runtime.Run(request);
        var (width, height) = WidgetFamilies.Size(request.Family);
        var rendered = runtime.Render(request, result, (float)width, (float)height, scale, nowMilliseconds: now);
        Directory.CreateDirectory(Path.GetDirectoryName(output)!);
        File.WriteAllBytes(output, rendered.EncodePng());
        var report = Describe(result);
        report["output"] = output;
        report["pixelWidth"] = rendered.PixelWidth;
        report["pixelHeight"] = rendered.PixelHeight;
        report["layoutMilliseconds"] = rendered.LayoutMilliseconds;
        report["paintMilliseconds"] = rendered.PaintMilliseconds;
        report["renderDiagnostics"] = rendered.Diagnostics.DeepClone();
        var regions = new JsonArray();
        foreach (var region in rendered.HitRegions)
        {
            regions.Append(new JsonObject
            {
                ["x"] = Math.Round(region.Bounds.Left, 1), ["y"] = Math.Round(region.Bounds.Top, 1),
                ["width"] = Math.Round(region.Bounds.Width, 1), ["height"] = Math.Round(region.Bounds.Height, 1),
                ["interaction"] = region.Interaction.DeepClone(),
            });
        }
        report["hitRegions"] = regions;
        Print(report);
        return result.Execution.Error is null ? 0 : 1;
    }

    private static int Timeline(Options options)
    {
        var (files, _) = Package(options);
        var scripts = new SharedScripts();
        var manifest = files.ReadText(PackageManifests.FileName) is { } text ? PackageManifests.Parse(text) : null;
        var state = new TimelinePlanner(scripts).State(manifest);
        Print(new JsonObject
        {
            ["hasSchedule"] = state is not null,
            ["environments"] = state is null ? null : Json.Object(state.Environments),
            ["nextTransition"] = state?.NextTransitionMilliseconds,
        });
        return 0;
    }

    private static int Pack(Options options)
    {
        var (_, directory) = Package(options);
        var output = Path.GetFullPath(options.Positional(1, "output file"));
        // Export through a temporary library so the archive is written by the same hardened code as the app's export.
        var scratch = Path.Combine(Path.GetTempPath(), "scriptwidget-cli", "pack-" + Guid.NewGuid().ToString("N"));
        try
        {
            var store = new PackageStore(Path.Combine(scratch, "library"), Path.Combine(scratch, "staging"));
            var source = new DiskPackageFiles(directory);
            var main = source.ReadText(PackageManifests.LegacyEntry) ?? throw new ArgumentException("The package has no main.jsx");
            var name = store.UniqueName(Path.GetFileName(directory.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar)));
            var created = store.Create(name, main, source.ReadText(PackageManifests.FileName));
            foreach (var path in source.Paths())
            {
                if (path is PackageManifests.LegacyEntry or PackageManifests.FileName) continue;
                if (source.ReadBytes(path) is { } bytes) store.WriteFile(created.Name, path, bytes);
            }
            using var stream = File.Create(output);
            store.ExportArchive(created.Name, stream);
        }
        finally
        {
            try { Directory.Delete(scratch, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        Console.WriteLine(output);
        return 0;
    }

    // MARK: - Library and desktop commands

    private static int List(Options options)
    {
        var library = new Library(new DataPaths(options.Value("data")));
        var items = new JsonArray();
        foreach (var package in library.List()) items.Append(new JsonObject { ["name"] = package.Name, ["title"] = package.DisplayName, ["installation"] = package.Installation, ["directory"] = package.Directory });
        Print(new JsonObject { ["packages"] = items });
        return 0;
    }

    private static int Templates()
    {
        var library = new Library(new DataPaths());
        var items = new JsonArray();
        foreach (var template in library.Bundled()) items.Append(new JsonObject { ["group"] = template.Group, ["name"] = template.Name });
        Print(new JsonObject { ["templates"] = items });
        return 0;
    }

    private static int Install(Options options)
    {
        var file = Path.GetFullPath(options.Positional(0, "archive"));
        var paths = new DataPaths(options.Value("data"));
        var library = new Library(paths);
        using var runtime = new WidgetRuntime(paths);
        using var stream = File.OpenRead(file);
        var installed = library.ImportArchive(stream, Path.GetFileNameWithoutExtension(file), files =>
        {
            try { runtime.ValidatePackage(files); }
            catch (RuntimeError error) { throw new PackageException(PackageErrors.InvalidManifest, error.Message); }
        });
        if (options.Value("data") is null) HostPipe.Send(new JsonObject { ["command"] = "library-changed" }, 300, 3000);
        Print(new JsonObject { ["name"] = installed.Name, ["installation"] = installed.Installation });
        return 0;
    }

    private static int Add(Options options)
    {
        var name = options.Positional(0, "package name");
        var library = new Library(new DataPaths());
        var package = library.Find(name) ?? library.FindByInstallation(name) ?? throw new ArgumentException($"No installed package named {name}");
        return Host(new JsonObject { ["command"] = "add", ["package"] = package.Installation, ["family"] = options.Value("family") ?? "medium", ["parameter"] = options.Value("param") ?? "" });
    }

    private static int Host(JsonObject request)
    {
        if (HostPipe.Send(request) is not { } response) return Fail("ScriptWidget is not running.", 1);
        Print(response);
        return response.OptBoolean("ok") ? 0 : 1;
    }

    /// <summary><c>--name value</c> options, <c>--flag</c> switches and positional arguments.</summary>
    private sealed class Options
    {
        private static readonly HashSet<string> Flags = ["dark", "stdin", "stream", "allow-network"];
        private readonly Dictionary<string, string> values = new();
        private readonly HashSet<string> flags = new();
        private readonly List<string> positional = new();

        public Options(string[] arguments)
        {
            for (var index = 0; index < arguments.Length; index++)
            {
                var argument = arguments[index];
                if (!argument.StartsWith("--", StringComparison.Ordinal)) { positional.Add(argument); continue; }
                var name = argument[2..];
                if (Flags.Contains(name)) { flags.Add(name); continue; }
                if (index + 1 >= arguments.Length) throw new ArgumentException($"--{name} needs a value");
                values[name] = arguments[++index];
            }
        }

        public string? Value(string name) => values.GetValueOrDefault(name);
        public bool Flag(string name) => flags.Contains(name);
        public string Positional(int index, string what) => index < positional.Count ? positional[index] : throw new ArgumentException($"Missing {what}");
    }
}
