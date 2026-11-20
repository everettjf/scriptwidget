using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Packages;
using ScriptWidget.Core.Plugins;
using ScriptWidget.Core.Hosting;

namespace ScriptWidget.Core.Skills;

public sealed class SkillException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

public sealed record WidgetSkill(string Id, string Name, string Version, string Summary, string Symbol,
    IReadOnlyList<string> Tags, string Instruction, string? Author = null, bool IsBuiltIn = false);

/// <summary>Skills 1.0 is text for prompts only. Unknown fields never grant capabilities.</summary>
public static partial class SkillValidator
{
    public const int MaximumManifestBytes = 32 * 1024;
    public const int MaximumInstructionBytes = 64 * 1024;
    public const int MaximumPackageBytes = 256 * 1024;
    private static readonly HashSet<string> Keys = ["formatVersion", "id", "name", "version", "summary", "symbol", "promptFile", "tags", "author", "minimumRuntimeVersion"];
    [GeneratedRegex(@"\A[A-Za-z0-9][A-Za-z0-9.-]{2,127}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Identifier();
    [GeneratedRegex(@"\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?\z", RegexOptions.CultureInvariant)]
    private static partial Regex Version();

    public static WidgetSkill Load(byte[] manifest, byte[] instruction)
    {
        if (manifest.Length > MaximumManifestBytes || instruction.Length > MaximumInstructionBytes)
            throw new SkillException("too_large", "Skill files exceed their size limits.");
        var utf8 = new UTF8Encoding(false, true);
        JsonObject json;
        string text;
        try
        {
            var source = utf8.GetString(manifest);
            StrictJson.Parse(source);
            json = Json.Parse(source) as JsonObject ?? throw new SkillException("invalid_manifest", "skill.json must be one JSON object.");
        }
        catch (Exception error) when (error is DecoderFallbackException or StrictJson.JsonException or System.Text.Json.JsonException)
        { throw new SkillException("invalid_manifest", "skill.json must be one strict UTF-8 JSON object."); }
        try { text = utf8.GetString(instruction); }
        catch (DecoderFallbackException) { throw new SkillException("invalid_instruction", "SKILL.md must be UTF-8 text."); }
        if (json.Any(field => !Keys.Contains(field.Key))) throw new SkillException("unknown_field", "skill.json contains an unknown field.");
        string Required(string key, int maximum = int.MaxValue)
        {
            if (!json[key].IsString() || json.OptString(key) is not { } value || string.IsNullOrWhiteSpace(value) || value.EnumerateRunes().Count() > maximum)
                throw new SkillException("invalid_manifest", $"skill.json field {key} is missing or invalid.");
            return value;
        }
        if (json["formatVersion"] is not JsonValue format || !format.TryGetValue<int>(out var number) || number != 1)
            throw new SkillException("invalid_skill", "Only Skill format 1 is supported.");
        var id = Required("id");
        var name = Required("name", 80);
        var version = Required("version");
        var summary = Required("summary", 240);
        var symbol = Required("symbol", 80);
        if (!Identifier().IsMatch(id) || !Version().IsMatch(version) || Required("promptFile") != "SKILL.md" || Required("minimumRuntimeVersion") != "1.0" || string.IsNullOrWhiteSpace(text))
            throw new SkillException("invalid_skill", "The Skill id, version, runtime, prompt file or instructions are invalid.");
        var tags = json.OptArray("tags");
        if (tags is null || tags.Count > 20 || tags.Any(tag => !tag.IsString()) || tags.Select(tag => tag!.AsText()!).Distinct(StringComparer.OrdinalIgnoreCase).Count() != tags.Count)
            throw new SkillException("invalid_skill", "Use at most 20 unique text tags.");
        if (json.Has("author") && !json["author"].IsString()) throw new SkillException("invalid_manifest", "Skill author must be text.");
        return new WidgetSkill(id, name, version, summary, symbol, tags.Select(tag => tag!.AsText()!).ToList(), text, json.OptStringOrNull("author"));
    }

    public static byte[] Manifest(WidgetSkill skill)
    {
        var json = new JsonObject
        {
        ["formatVersion"] = 1, ["id"] = skill.Id, ["name"] = skill.Name, ["version"] = skill.Version,
        ["summary"] = skill.Summary, ["symbol"] = skill.Symbol, ["promptFile"] = "SKILL.md",
        ["tags"] = Json.Array(skill.Tags), ["minimumRuntimeVersion"] = "1.0",
        };
        if (skill.Author is not null) json["author"] = skill.Author;
        return Encoding.UTF8.GetBytes(Json.Stringify(json, indented: true));
    }
}

/// <summary>
/// Validates on every read, stages installs before publication, and refuses links, extra files
/// and oversized text. This store never evaluates an instruction or exposes it to widgets.
/// </summary>
public sealed class SkillStore
{
    public static readonly IReadOnlyList<WidgetSkill> BuiltIns =
    [
        BuiltIn("responsive-layout", "Responsive Layout", "rectangle.3.group", "Adapt one script to every widget family.", "Use $getenv(\"widget-size\") to create intentional small, medium, and large layouts. Keep the information hierarchy readable in every family.", "layout"),
        BuiltIn("accessible-design", "Accessible Design", "accessibility", "Improve contrast, hierarchy, and legibility.", "Use strong text/background contrast, avoid color as the only signal, keep important text legible, and prefer concise labels.", "accessibility"),
        BuiltIn("resilient-data", "Resilient Data", "network.badge.shield.half.filled", "Handle network and missing-data failures.", "When data is remote or optional, validate it and render a useful fallback state. Never expose secrets or invent unsupported runtime APIs.", "network", "safety"),
        BuiltIn("visual-polish", "Visual Polish", "paintbrush.pointed", "Apply a coherent native visual system.", "Create a restrained native-looking visual system with consistent spacing, typography, color, and alignment. Avoid decorative clutter.", "design"),
        BuiltIn("runtime-debugger", "Runtime Debugger", "ladybug", "Repair errors with the smallest safe change.", "Prioritize the supplied runtime diagnostic. Make the smallest correction that fixes it, preserve unrelated behavior, and use only documented ScriptWidget APIs.", "debugging"),
    ];
    private static WidgetSkill BuiltIn(string id, string name, string symbol, string summary, string instruction, params string[] tags) =>
        new(id, name, "1.0.0", summary, symbol, tags, instruction, IsBuiltIn: true);
    private static readonly ArchiveLimits Limits = new()
    {
        MaximumArchiveBytes = SkillValidator.MaximumPackageBytes, MaximumExpandedBytes = SkillValidator.MaximumPackageBytes,
        MaximumFileBytes = SkillValidator.MaximumInstructionBytes, MaximumFileCount = 16, MaximumPathDepth = 3,
    };
    private readonly string root;
    private readonly object gate = new();
    private readonly SafeJsonFile enabled;
    public SkillStore(string root)
    {
        this.root = Path.GetFullPath(root);
        enabled = new SafeJsonFile(Path.Combine(this.root, ".enabled.json"), 256 * 1024);
    }

    private static string DirectoryName(string id) => "skill-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(id)))[..32];

    private WidgetSkill? Load(string directory)
    {
        if (PluginFiles.RealDirectory(directory) is null || PluginFiles.Names(directory) is not { Count: 2 } names ||
            !names.Contains("skill.json", StringComparer.Ordinal) || !names.Contains("SKILL.md", StringComparer.Ordinal)) return null;
        var manifestPath = PluginFiles.ExistingFile(directory, "skill.json");
        var instructionPath = PluginFiles.ExistingFile(directory, "SKILL.md");
        if (manifestPath is null || instructionPath is null || PluginFiles.ReadBounded(manifestPath, SkillValidator.MaximumManifestBytes) is not { } manifest ||
            PluginFiles.ReadBounded(instructionPath, SkillValidator.MaximumInstructionBytes) is not { } instruction) return null;
        try { return SkillValidator.Load(manifest, instruction); } catch (SkillException) { return null; }
    }

    public IReadOnlyList<WidgetSkill> List()
    {
        lock (gate)
        {
            var custom = new List<WidgetSkill>();
            if (PluginFiles.RealDirectory(root) is not null)
                foreach (var name in PluginFiles.Names(root) ?? [])
                    if (name.StartsWith("skill-", StringComparison.Ordinal) && Load(Path.Combine(root, name)) is { } skill && name == DirectoryName(skill.Id)) custom.Add(skill);
            var ids = custom.Select(skill => skill.Id).ToHashSet(StringComparer.Ordinal);
            return BuiltIns.Where(skill => !ids.Contains(skill.Id)).Concat(custom.OrderBy(skill => skill.Name, StringComparer.OrdinalIgnoreCase)).ToList();
        }
    }

    public WidgetSkill? Find(string id) => List().FirstOrDefault(skill => skill.Id == id);

    public WidgetSkill Install(byte[] manifest, byte[] instruction, bool replaceExisting = false)
    {
        var skill = SkillValidator.Load(manifest, instruction);
        lock (gate)
        {
            if (!replaceExisting && Find(skill.Id) is not null) throw new SkillException("duplicate_skill", "A Skill with that id already exists.");
            Directory.CreateDirectory(root);
            if (PluginFiles.RealDirectory(root) is null) throw new SkillException("storage_unavailable", "The Skills folder is unavailable.");
            var work = PluginFiles.NewWorkDirectory(root, ".staging");
            var target = Path.Combine(root, DirectoryName(skill.Id));
            var backup = Path.Combine(root, ".backup-" + Guid.NewGuid().ToString("N"));
            try
            {
                PluginFiles.WriteNew(Path.Combine(work, "skill.json"), manifest);
                PluginFiles.WriteNew(Path.Combine(work, "SKILL.md"), instruction);
                var hadPrevious = PluginFiles.Occupied(target);
                if (hadPrevious) Directory.Move(target, backup);
                try { PluginFiles.Publish(work, target); }
                catch { if (hadPrevious) Directory.Move(backup, target); throw; }
                PluginFiles.DeleteTree(backup);
                return skill;
            }
            finally { PluginFiles.DeleteTree(work); }
        }
    }

    public void Delete(string id)
    {
        lock (gate)
        {
            var skill = Find(id) ?? throw new SkillException("skill_not_found", "Skill not found.");
            if (skill.IsBuiltIn) throw new SkillException("built_in_skill", "Built-in Skills cannot be deleted.");
            var target = Path.Combine(root, DirectoryName(id));
            var trash = Path.Combine(root, ".deleted-" + Guid.NewGuid().ToString("N"));
            Directory.Move(target, trash);
            PluginFiles.DeleteTree(trash);
            SetEnabled(id, false);
        }
    }

    public IReadOnlySet<string> EnabledIds()
    {
        lock (gate)
        {
            if (PluginFiles.RealDirectory(root) is null) return new HashSet<string>();
            try
            {
                return Json.TryParse(enabled.Read() ?? "[]") is JsonArray ids && ids.All(id => id.IsString())
                    ? ids.Select(id => id!.AsText()!).ToHashSet(StringComparer.Ordinal) : new HashSet<string>();
            }
            catch (PrivateFile.Unreadable) { return new HashSet<string>(); }
        }
    }

    public void SetEnabled(string id, bool value)
    {
        lock (gate)
        {
            if (value && Find(id) is null) throw new SkillException("skill_not_found", "Skill not found.");
            Directory.CreateDirectory(root);
            if (PluginFiles.RealDirectory(root) is null) throw new SkillException("storage_unavailable", "The Skills folder is unavailable.");
            var ids = EnabledIds().ToHashSet(StringComparer.Ordinal);
            if (value) ids.Add(id); else ids.Remove(id);
            if (!enabled.Write(Json.Stringify(Json.Array(ids.Order(StringComparer.Ordinal))))) throw new SkillException("storage_unavailable", "Skill selection could not be saved.");
        }
    }

    public string PromptText(IEnumerable<string>? chosen = null)
    {
        var ids = chosen?.ToHashSet(StringComparer.Ordinal) ?? EnabledIds();
        var skills = List().Where(skill => ids.Contains(skill.Id)).ToList();
        return skills.Count == 0 ? "" : "Apply these ScriptWidget skills:\n" + string.Join("\n", skills.Select(skill => $"- {skill.Name} v{skill.Version}:\n  {skill.Instruction.Replace("\n", "\n  ", StringComparison.Ordinal)}"));
    }

    public WidgetSkill ImportArchive(Stream input)
    {
        using var bytes = new MemoryStream();
        var buffer = new byte[8192];
        while (bytes.Length <= SkillValidator.MaximumPackageBytes)
        {
            var count = input.Read(buffer, 0, (int)Math.Min(buffer.Length, SkillValidator.MaximumPackageBytes + 1 - bytes.Length));
            if (count == 0) break;
            bytes.Write(buffer, 0, count);
        }
        if (bytes.Length > SkillValidator.MaximumPackageBytes) throw new SkillException("too_large", "A Skill archive may not exceed 256 KiB.");
        var archive = bytes.ToArray();
        var entries = ArchivePreflight.Validate(archive, Limits);
        var names = entries.Select(entry => entry.Name).ToList();
        var files = names.Where(name => !name.EndsWith('/')).ToList();
        var prefix = files.Count > 0 && files[0].Contains('/') ? files[0][..(files[0].IndexOf('/') + 1)] : "";
        if (files.Count != 2 || !files.Contains(prefix + "skill.json", StringComparer.Ordinal) || !files.Contains(prefix + "SKILL.md", StringComparer.Ordinal) ||
            names.Any(name => name.EndsWith('/') && name != prefix)) throw new SkillException("invalid_package", "A Skill contains exactly skill.json and SKILL.md.");
        // Inflate only the two validated entries, in memory, with real byte counts and CRC checks.
        try
        {
            using var zip = new System.IO.Compression.ZipArchive(new MemoryStream(archive, writable: false), System.IO.Compression.ZipArchiveMode.Read);
            byte[] Read(string name, int maximum)
            {
                var entry = entries.Single(entry => entry.Name == prefix + name);
                return PluginArchive.Inflate(zip, new PluginArchive.Entry(entry.Name, entry.Parts, entry.IsDirectory, entry.UncompressedSize, entry.Crc), maximum);
            }
            return Install(Read("skill.json", SkillValidator.MaximumManifestBytes), Read("SKILL.md", SkillValidator.MaximumInstructionBytes));
        }
        catch (InvalidDataException) { throw new SkillException("invalid_archive", "The Skill archive is corrupt or exceeds its declared size."); }
    }

    public void Export(string id, Stream output)
    {
        var skill = Find(id) ?? throw new SkillException("skill_not_found", "Skill not found.");
        using var buffer = new MemoryStream();
        using (var zip = new System.IO.Compression.ZipArchive(buffer, System.IO.Compression.ZipArchiveMode.Create, leaveOpen: true))
        {
            foreach (var (name, bytes) in new[] { ("skill.json", SkillValidator.Manifest(skill)), ("SKILL.md", Encoding.UTF8.GetBytes(skill.Instruction)) })
            {
                var entry = zip.CreateEntry(name);
                entry.LastWriteTime = new DateTimeOffset(1980, 1, 1, 0, 0, 0, TimeSpan.Zero);
                using var stream = entry.Open();
                stream.Write(bytes);
            }
        }
        buffer.Position = 0;
        buffer.CopyTo(output);
    }
}
