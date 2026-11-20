using System.IO.Compression;
using System.Text;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Plugins;
using ScriptWidget.Core.Runtime;
using ScriptWidget.Core.Skills;

namespace ScriptWidget.Core.AI;

public sealed record AiProgress(string State, int Attempt, string? Text = null, AiUsage? Usage = null);
public sealed record AiValidation(bool Ok, string? Error = null, IReadOnlyList<string>? Logs = null);

/// <summary>In-memory candidate packages and explicit publication of a chosen version.</summary>
public static class AiCandidates
{
    private sealed class Overlay(IPackageFiles? original, string entry, string source, string? manifest) : IPackageFiles
    {
        public IReadOnlyList<string> Paths() => (original?.Paths() ?? []).Concat(manifest is null ? [entry] : [entry, "widget.json"]).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList();
        public bool Exists(string path) => path == entry || path == "widget.json" && manifest is not null || original?.Exists(path) == true;
        public string? ReadText(string path) => path == entry ? source : path == "widget.json" && manifest is not null ? manifest : original?.ReadText(path);
        public byte[]? ReadBytes(string path) => path == entry ? Encoding.UTF8.GetBytes(source) : path == "widget.json" && manifest is not null ? Encoding.UTF8.GetBytes(manifest) : original?.ReadBytes(path);
    }
    public static JsonObject? ManifestOf(InstalledPackage? package)
    {
        if (package is null || !package.ManifestPresent) return null;
        var text = package.Files.ReadText("widget.json") ?? throw new AiException("invalid_manifest", "widget.json cannot be read. Nothing was changed.");
        try { StrictJson.Parse(text); return Json.ParseObject(text); }
        catch (Exception error) when (error is StrictJson.JsonException or System.Text.Json.JsonException) { throw new AiException("invalid_manifest", "widget.json is invalid. Nothing was changed."); }
    }
    public static string Entry(InstalledPackage? package) => ManifestOf(package).OptStringOrNull("entry") ?? "main.jsx";
    public static IReadOnlyList<string> AllowedHosts(InstalledPackage? package) => ManifestOf(package).OptArray("networkDomains")?.Where(value => value.IsString()).Select(value => value!.AsText()!).ToList() ?? [];
    public static IReadOnlyList<string> NewHosts(InstalledPackage? package, AiVersion version) => version.NetworkDomains.Except(AllowedHosts(package), StringComparer.Ordinal).ToList();

    public static string? ManifestText(InstalledPackage? package, IReadOnlyList<string> domains, string name)
    {
        var current = ManifestOf(package);
        if (package is not null && current is null) return null; // Preserve legacy packages.
        var manifest = current?.DeepClone() as JsonObject ?? PackageManifests.NewManifest(name);
        var hosts = AllowedHosts(package).Concat(domains).Distinct(StringComparer.Ordinal).ToList();
        AiNetworkDeclaration.ValidateHosts(hosts);
        if (hosts.Count > 0)
        {
            var permissions = manifest.OptArray("permissions")?.Where(value => value.IsString()).Select(value => value!.AsText()!).ToList() ?? [];
            if (!permissions.Contains("network", StringComparer.Ordinal)) permissions.Add("network");
            manifest["permissions"] = Json.Array(permissions);
            manifest["networkDomains"] = Json.Array(hosts);
        }
        return Json.Stringify(manifest);
    }
    public static IPackageFiles Files(InstalledPackage? package, string source, IReadOnlyList<string> domains, string name) =>
        new Overlay(package?.Files, Entry(package), source, ManifestText(package, domains, name));

    public static InstalledPackage SaveNew(Library library, string name, AiVersion version, bool allowNewHosts, Action<IPackageFiles>? validate = null)
    {
        if (version.NetworkDomains.Count > 0 && !allowNewHosts) throw new AiException("network_confirmation_required", "Review and approve the widget's network hosts before saving.");
        name = PackageNames.DirectoryName(string.IsNullOrWhiteSpace(name) ? "AI Widget" : name.Trim());
        validate?.Invoke(Files(null, version.Source, version.NetworkDomains, name));
        return library.Create(name, version.Source, ManifestText(null, version.NetworkDomains, name));
    }
    public static InstalledPackage Apply(Library library, InstalledPackage package, AiVersion version, Action<IPackageFiles> validate, bool allowNewHosts)
    {
        if (NewHosts(package, version).Count > 0 && !allowNewHosts) throw new AiException("network_confirmation_required", "Review and approve the new network hosts before applying this version.");
        var manifest = ManifestOf(package); // Fail closed before touching an entry.
        var files = Files(package, version.Source, version.NetworkDomains, package.Name);
        validate(files);
        if (manifest is null)
        {
            library.WriteFile(package.Name, "main.jsx", Encoding.UTF8.GetBytes(version.Source));
        }
        else
        {
            // Source and manifest change together, retaining imports, assets and the installation identity.
            using var archive = new MemoryStream();
            using (var zip = new ZipArchive(archive, ZipArchiveMode.Create, leaveOpen: true))
                foreach (var path in files.Paths())
                {
                    var bytes = files.ReadBytes(path) ?? throw new AiException("package_changed", "A package file cannot be read. Nothing was changed.");
                    var entry = zip.CreateEntry("package/" + path);
                    using var stream = entry.Open();
                    stream.Write(bytes);
                }
            archive.Position = 0;
            library.Store.ReplaceArchive(package.Name, archive, manifest.OptString("id"), Library.InstallationFile, validate);
            library.ClearBuild(package.Name);
        }
        return library.Find(package.Name) ?? throw new AiException("not_found", "The widget could not be found after saving.");
    }
}

/// <summary>Four-attempt conversation turns: bounded execution and drawing before a version is accepted.</summary>
public sealed class AiRunner(DataPaths paths, Library library, SkillStore skills, AiConversationStore store)
{
    private readonly Lazy<string> systemPrompt = new(() => AiPrompt.System(library));
    public async Task<AiTurn> RunAsync(AiConversation conversation, string request, IAiChat chat, Action<AiProgress>? onProgress = null, string? runtimeDiagnostic = null, CancellationToken cancellation = default)
    {
        cancellation.ThrowIfCancellationRequested();
        var installed = conversation.PackageId is null ? null : library.FindByInstallation(conversation.PackageId) ?? throw new AiException("not_found", "The widget for this conversation was removed.");
        var baseManifest = AiCandidates.ManifestOf(installed);
        if (baseManifest is not null)
        {
            using var compiler = new PackageCompiler(new SharedScripts());
            var validation = compiler.ValidateManifest(Json.Stringify(baseManifest), installed!.Files.Paths());
            if (!validation.OptBoolean("ok")) throw new AiException("invalid_manifest", "widget.json is invalid. Fix the manifest before starting an AI request.");
        }
        if (installed is not null)
            conversation.ReconcileInstalledSource(installed.Files.ReadText(AiCandidates.Entry(installed)) ?? throw new AiException("invalid_package", "The widget entry cannot be read."), AiCandidates.AllowedHosts(installed));
        if (conversation.SkillIds is null) conversation.ChooseSkills(skills.EnabledIds());
        var current = conversation.CurrentVersion;
        var turn = conversation.Begin(request);
        store.Save(conversation);
        var first = new AiMessage("user", AiPrompt.Turn(conversation, turn.Request, skills.PromptText(conversation.SkillIds), runtimeDiagnostic));
        var system = new AiMessage("system", systemPrompt.Value);
        AiCandidate? latest = null;
        var editBase = current?.Source;
        string? lastError = null;
        IReadOnlyList<string> lastLogs = [];
        try
        {
            for (var attempt = 1; attempt <= 4; attempt++)
            {
                cancellation.ThrowIfCancellationRequested();
                onProgress?.Invoke(new AiProgress("thinking", attempt));
                IReadOnlyList<AiMessage> messages = latest is not null && lastError is not null
                    ? [system, first, new AiMessage("assistant", "```jsx\n" + latest.Source + "\n```" + (latest.DeclarationJson is null ? "" : "\n```json\n" + latest.DeclarationJson + "\n```")), new AiMessage("user", AiPrompt.Fix(latest, lastError, lastLogs))]
                    : [system, first];
                var reply = await chat.ChatAsync(messages, text => onProgress?.Invoke(new AiProgress("partial", attempt, text)), cancellation).ConfigureAwait(false);
                turn.Usage += reply.Usage;
                onProgress?.Invoke(new AiProgress("usage", attempt, Usage: turn.Usage));
                cancellation.ThrowIfCancellationRequested();
                AiCandidate candidate;
                IReadOnlyList<string> domains = current?.NetworkDomains ?? [];
                AiValidation validation;
                try
                {
                    candidate = AiOutput.Extract(reply.Content);
                    if (!string.IsNullOrWhiteSpace(candidate.Note)) turn.Note = candidate.Note;
                    var edits = AiSourceEdits.Parse(reply.Content);
                    if (edits is not null)
                    {
                        if (string.IsNullOrEmpty(editBase)) throw new AiException("invalid_edit", "There is no current code to edit. Return the full widget code.");
                        candidate = candidate with { Source = AiSourceEdits.Apply(edits, editBase) };
                    }
                    latest = candidate;
                    if (candidate.DeclarationJson is not null) domains = AiNetworkDeclaration.Parse(candidate.DeclarationJson).Domains;
                    domains = AiCandidates.AllowedHosts(installed).Concat(domains).Distinct(StringComparer.Ordinal).ToList();
                    latest = candidate;
                    if (candidate.Source.Length > 0) editBase = candidate.Source;
                    turn.FailedSource = Encoding.UTF8.GetByteCount(candidate.Source) <= 512 * 1024 ? candidate.Source : AiConversation.Clip(candidate.Source, 64000);
                    onProgress?.Invoke(new AiProgress("running", attempt));
                    validation = reply.Truncated ? new(false, "The reply was cut off at the output limit. Return a shorter, complete widget.") :
                        await Task.Run(() => Validate(installed, candidate.Source, domains, conversation.Family), cancellation).ConfigureAwait(false);
                    var unknown = AiJsxCheck.Summary(candidate.Source);
                    if (unknown is not null && (attempt < 4 || !validation.Ok)) validation = new(false, (validation.Ok ? "" : validation.Error + "\n\n") + unknown, validation.Logs);
                }
                catch (AiException error)
                {
                    latest ??= new AiCandidate(editBase ?? "", null, null);
                    candidate = latest;
                    validation = new(false, error.Message);
                }
                cancellation.ThrowIfCancellationRequested();
                if (validation.Ok)
                {
                    var version = conversation.AddVersion(candidate.Source, domains);
                    turn.Status = AiTurnStatus.Succeeded;
                    turn.VersionId = version.Id;
                    turn.Note ??= "Done.";
                    turn.ErrorSummary = null;
                    turn.FailedSource = null;
                    onProgress?.Invoke(new AiProgress("succeeded", attempt, turn.Note));
                    return turn;
                }
                lastError = validation.Error ?? "The widget did not render real content.";
                lastLogs = validation.Logs ?? [];
                turn.Repairs++;
                turn.ErrorSummary = AiConversation.Clip(lastError, 600);
                onProgress?.Invoke(new AiProgress("repairing", attempt, turn.ErrorSummary));
                store.Save(conversation);
            }
            turn.Status = AiTurnStatus.Unconverged;
            return turn;
        }
        catch (OperationCanceledException) { turn.Status = AiTurnStatus.Cancelled; turn.ErrorSummary = null; return turn; }
        catch (AiException error) { turn.Status = AiTurnStatus.Failed; turn.ErrorSummary = AiConversation.Clip(error.Message, 600); return turn; }
        catch (Exception error) when (error is not OutOfMemoryException) { turn.Status = AiTurnStatus.Failed; turn.ErrorSummary = "The AI request could not be completed."; return turn; }
        finally
        {
            conversation.UpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            store.Save(conversation);
        }
    }

    private AiValidation Validate(InstalledPackage? installed, string source, IReadOnlyList<string> domains, string family)
    {
        if (string.IsNullOrWhiteSpace(source)) return new(false, "The reply contained no JSX code.");
        if (Encoding.UTF8.GetByteCount(source) > 512 * 1024) return new(false, "Widget source exceeds 512 KiB.");
        if (!Library.SupportsBundled(new MemoryPackageFiles(new Dictionary<string, string> { ["main.jsx"] = source })))
            return new(false, "The code uses a data API not supported on Windows: " + string.Join(", ", Library.UnsupportedGlobals.Select(name => "$" + name)) + ". Render a short explanation instead.");
        string? scratch = null;
        try
        {
            scratch = PluginFiles.NewWorkDirectory(Path.Combine(paths.Cache, "ai-trials"), "trial");
            using var runtime = new WidgetRuntime(new DataPaths(scratch));
            var files = AiCandidates.Files(installed, source, domains, "AI Widget");
            var request = new RunRequest { Files = files, PackageID = "ai-trial", Family = family };
            var result = runtime.Run(request);
            var logs = result.Execution.Logs.Select(log => $"[{log.Level}] {log.Message}").ToList();
            if (result.Execution.Error is { } error) return new(false, error.Kind + ": " + AiConversation.Clip(error.Message, 2000), logs);
            if (result.Execution.Tree is not { } tree || Json.TryParse(tree) is not JsonObject root || root.OptString("$element").Length == 0) return new(false, "Runtime returned no element.", logs);
            if (root.OptArray("children")?.Any(value => value.IsString() && value!.AsText() is "#UI Not Found#" or "#Failed#" or "#Loading#") == true) return new(false, "Runtime returned a fallback/placeholder element.", logs);
            if (logs.FirstOrDefault(log => log.StartsWith("[error]", StringComparison.Ordinal) || log.Contains("uncaught", StringComparison.OrdinalIgnoreCase)) is { } failing) return new(false, "The widget rendered but logged an error: " + AiConversation.Clip(failing, 2000), logs);
            var (width, height) = WidgetFamilies.Size(family);
            runtime.Renderer.Render(new Render.RenderRequest { Tree = tree, Files = files, Width = (float)width, Height = (float)height, Density = 1, Family = family });
            return new(true, Logs: logs);
        }
        catch (Exception error) when (error is RuntimeError or PackageException or AiException) { return new(false, AiConversation.Clip(error.Message, 2000)); }
        catch (Exception error) when (error is not OutOfMemoryException) { return new(false, "The widget could not be drawn by the Windows renderer."); }
        finally { if (scratch is not null) PluginFiles.DeleteTree(scratch); }
    }
}
