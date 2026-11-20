using System.Text;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Plugins;

namespace ScriptWidget.Core.AI;

public sealed record AiVersion(string Id, int Number, string Source, string? ParentId, long CreatedAt, IReadOnlyList<string> NetworkDomains);
public enum AiTurnStatus { Running, Succeeded, Unconverged, Cancelled, Failed, Interrupted }
public sealed class AiTurn
{
    public string Id { get; init; } = Guid.NewGuid().ToString("D");
    public string Request { get; init; } = "";
    public string? BaseVersionId { get; init; }
    public AiTurnStatus Status { get; set; } = AiTurnStatus.Running;
    public string? Note { get; set; }
    public string? ErrorSummary { get; set; }
    public int Repairs { get; set; }
    public string? VersionId { get; set; }
    public string? FailedSource { get; set; }
    public AiUsage Usage { get; set; } = new();
    public long CreatedAt { get; init; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public bool IsAbandoned { get; set; }
    public bool IsManualEdit { get; init; }
}

/// <summary>One local versioned conversation. A failed turn never moves its current version.</summary>
public sealed class AiConversation
{
    public const int MaximumVersions = 30, MaximumConversations = 50, MaximumRequestCharacters = 4000, MaximumFileBytes = 12 * 1024 * 1024;
    public string Id { get; init; } = Guid.NewGuid().ToString("D");
    public string Title { get; set; } = "";
    public string Family { get; set; } = "medium";
    public string? PackageId { get; set; }
    public long CreatedAt { get; init; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public long UpdatedAt { get; set; } = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    public string? CurrentVersionId { get; private set; }
    /// <summary>Last observed installed entry, independent of the selected or unapplied draft version.</summary>
    public string? AppliedSourceHash { get; private set; }
    public int VersionCounter { get; private set; }
    public List<AiVersion> Versions { get; } = [];
    public List<AiTurn> Turns { get; } = [];
    public List<string>? SkillIds { get; private set; }
    public AiVersion? CurrentVersion => Version(CurrentVersionId);
    public bool IsRunning => Turns.Any(turn => turn.Status == AiTurnStatus.Running);
    public AiUsage TotalUsage => Turns.Aggregate(new AiUsage(), (usage, turn) => usage + turn.Usage);
    public AiVersion? Version(string? id) => Versions.FirstOrDefault(version => version.Id == id);
    public IReadOnlyList<AiTurn> History => Turns.Where(turn => turn.Status == AiTurnStatus.Succeeded && !turn.IsAbandoned && !turn.IsManualEdit).TakeLast(12).ToList();

    public AiTurn Begin(string request)
    {
        if (IsRunning) throw new AiException("already_running", "This conversation already has a running request.");
        if (string.IsNullOrWhiteSpace(request) || request.Length > MaximumRequestCharacters) throw new AiException("invalid_request", "Enter a request of 1 to 4000 characters.");
        AbandonOtherBranches();
        var turn = new AiTurn { Request = request.Trim(), BaseVersionId = CurrentVersionId };
        Turns.Add(turn);
        if (Title.Length == 0) Title = Clip(request.Split('\n').FirstOrDefault(line => !string.IsNullOrWhiteSpace(line))?.Trim() ?? "AI Widget", 40);
        UpdatedAt = turn.CreatedAt;
        return turn;
    }
    public AiVersion AddVersion(string source, IEnumerable<string>? domains = null)
    {
        if (Encoding.UTF8.GetByteCount(source) > 512 * 1024) throw new AiException("source_too_large", "Widget source exceeds 512 KiB.");
        var hosts = domains?.Distinct(StringComparer.Ordinal).ToArray() ?? [];
        AiNetworkDeclaration.ValidateHosts(hosts);
        var version = new AiVersion(Guid.NewGuid().ToString("D"), ++VersionCounter, source, CurrentVersionId, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), hosts);
        Versions.Add(version);
        CurrentVersionId = version.Id;
        while (Versions.Count > MaximumVersions) Versions.Remove(Versions.Where(item => item.Id != CurrentVersionId).MinBy(item => item.Number)!);
        UpdatedAt = version.CreatedAt;
        return version;
    }
    public bool SelectVersion(string id)
    {
        if (IsRunning || Version(id) is null) return false;
        CurrentVersionId = id;
        UpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        return true;
    }
    public void ChooseSkills(IEnumerable<string> ids)
    {
        SkillIds = ids.Where(id => id.Length is > 0 and <= 128).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).Take(64).ToList();
        UpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }
    public AiConversation Fork()
    {
        if (CurrentVersion is not { } current || IsRunning) throw new AiException("invalid_conversation", "Choose a completed version before starting a new conversation.");
        var fork = new AiConversation { Title = Title, Family = Family, PackageId = PackageId, AppliedSourceHash = AppliedSourceHash };
        if (SkillIds is not null) fork.ChooseSkills(SkillIds);
        fork.AddVersion(current.Source, current.NetworkDomains);
        return fork;
    }
    public void AdoptExternalSource(string source, IEnumerable<string>? domains = null)
    {
        if (CurrentVersion?.Source == source) return;
        if (IsRunning) throw new AiException("already_running", "Wait for the current request before recording manual changes.");
        AbandonOtherBranches();
        var parent = CurrentVersionId;
        var version = AddVersion(source, domains);
        Turns.Add(new AiTurn { BaseVersionId = parent, VersionId = version.Id, Status = AiTurnStatus.Succeeded, IsManualEdit = true });
    }
    private static string SourceHash(string source) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(source)));
    public void RecordAppliedSource(string source)
    {
        AppliedSourceHash = SourceHash(source);
        UpdatedAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
    }
    /// <summary>Old files without a fingerprint may recognize an installed version still in their history.</summary>
    public bool CanApplyToSource(string source) => AppliedSourceHash is { } hash
        ? SourceHash(source) == hash : Versions.Any(version => version.Source == source);
    /// <summary>Keep unapplied drafts on reopen, but adopt edits made since the last observed installation.</summary>
    public bool ReconcileInstalledSource(string source, IEnumerable<string>? domains = null)
    {
        if (IsRunning) throw new AiException("already_running", "Wait for the current request before recording manual changes.");
        var changed = !CanApplyToSource(source);
        if (changed) AdoptExternalSource(source, domains);
        RecordAppliedSource(source);
        return changed;
    }
    public string RetryRequest(string turnId)
    {
        var turn = Turns.FirstOrDefault(turn => turn.Id == turnId) ?? throw new AiException("not_found", "Turn not found.");
        if (IsRunning || turn.IsManualEdit || turn.Status == AiTurnStatus.Succeeded) throw new AiException("invalid_request", "This turn cannot be retried.");
        if (Version(turn.BaseVersionId) is not null) CurrentVersionId = turn.BaseVersionId;
        Turns.Remove(turn);
        return turn.Request;
    }
    private void AbandonOtherBranches()
    {
        var path = new HashSet<string>(StringComparer.Ordinal);
        var cursor = CurrentVersion;
        while (cursor is not null && path.Add(cursor.Id)) cursor = Version(cursor.ParentId);
        foreach (var turn in Turns)
            if (turn.VersionId is { } produced && Version(produced) is not null) turn.IsAbandoned = !path.Contains(produced);
    }
    public static string Clip(string text, int characters) => text.Length <= characters ? text : text[..characters];

    public JsonObject ToJson()
    {
        var versions = new JsonArray();
        foreach (var version in Versions) versions.Append(new JsonObject
        {
            ["id"] = version.Id, ["number"] = version.Number, ["source"] = version.Source, ["parentId"] = version.ParentId,
            ["createdAt"] = version.CreatedAt, ["networkDomains"] = Json.Array(version.NetworkDomains),
        });
        var turns = new JsonArray();
        foreach (var turn in Turns) turns.Append(new JsonObject
        {
            ["id"] = turn.Id, ["request"] = turn.Request, ["baseVersionId"] = turn.BaseVersionId, ["status"] = turn.Status.ToString().ToLowerInvariant(),
            ["note"] = turn.Note, ["errorSummary"] = turn.ErrorSummary, ["repairs"] = turn.Repairs, ["versionId"] = turn.VersionId, ["failedSource"] = turn.FailedSource,
            ["promptTokens"] = turn.Usage.PromptTokens, ["completionTokens"] = turn.Usage.CompletionTokens, ["totalTokens"] = turn.Usage.TotalTokens,
            ["createdAt"] = turn.CreatedAt, ["isAbandoned"] = turn.IsAbandoned, ["isManualEdit"] = turn.IsManualEdit,
        });
        var json = new JsonObject
        {
            ["formatVersion"] = 1, ["id"] = Id, ["title"] = Title, ["size"] = Family, ["packageId"] = PackageId,
            ["currentVersionId"] = CurrentVersionId, ["versionCounter"] = VersionCounter, ["createdAt"] = CreatedAt, ["updatedAt"] = UpdatedAt,
            ["versions"] = versions, ["turns"] = turns,
        };
        if (SkillIds is not null) json["skillIds"] = Json.Array(SkillIds);
        if (AppliedSourceHash is not null) json["appliedSourceHash"] = AppliedSourceHash;
        return json;
    }

    public static AiConversation FromJson(string text)
    {
        StrictJson.Parse(text);
        var json = Json.ParseObject(text);
        string Required(JsonObject row, string key, int maximum = int.MaxValue)
        {
            if (!row[key].IsString() || row.OptString(key) is not { } value || value.Length > maximum) throw new AiException("invalid_conversation", "Conversation contains invalid text.");
            return value;
        }
        string? OptionalId(JsonObject row, string key)
        {
            if (!row.Has(key)) throw new AiException("invalid_conversation", "Conversation is missing an identifier.");
            if (row.IsNull(key)) return null;
            var value = Required(row, key, 128);
            if (!Guid.TryParse(value, out _)) throw new AiException("invalid_conversation", "Conversation has an invalid identifier.");
            return value;
        }
        string? OptionalText(JsonObject row, string key, int maximum)
        {
            if (!row.Has(key)) throw new AiException("invalid_conversation", "Conversation is missing a field.");
            return row.IsNull(key) ? null : Required(row, key, maximum);
        }
        long Integer(JsonObject row, string key, long maximum = long.MaxValue)
        {
            if (row[key] is not JsonValue value || !value.TryGetValue<long>(out var number) || number < 0 || number > maximum)
                throw new AiException("invalid_conversation", "Conversation contains an invalid number.");
            return number;
        }
        var known = new HashSet<string>(["formatVersion", "id", "title", "size", "packageId", "currentVersionId", "versionCounter", "createdAt", "updatedAt", "versions", "turns", "skillIds", "appliedSourceHash"], StringComparer.Ordinal);
        if (json.Any(pair => !known.Contains(pair.Key)) || Integer(json, "formatVersion", 1) != 1 || !Guid.TryParseExact(Required(json, "id", 36), "D", out _) ||
            json.OptArray("versions") is not { Count: <= MaximumVersions } versions || json.OptArray("turns") is not { Count: <= 10000 } turns) throw new AiException("invalid_conversation", "Unsupported or invalid conversation file.");
        var conversation = new AiConversation
        {
            Id = Required(json, "id"), Title = Required(json, "title", 240), Family = Required(json, "size", 20), PackageId = OptionalId(json, "packageId"),
            CreatedAt = Integer(json, "createdAt"), UpdatedAt = Integer(json, "updatedAt"), CurrentVersionId = OptionalId(json, "currentVersionId"), VersionCounter = (int)Integer(json, "versionCounter", int.MaxValue),
        };
        if (!WidgetFamilies.IsKnown(conversation.Family) || conversation.VersionCounter < 0) throw new AiException("invalid_conversation", "Invalid conversation size or version number.");
        if (json.Has("appliedSourceHash"))
        {
            var hash = Required(json, "appliedSourceHash", 64);
            if (hash.Length != 64 || hash.Any(character => character is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
                throw new AiException("invalid_conversation", "Invalid applied-source fingerprint.");
            conversation.AppliedSourceHash = hash;
        }
        foreach (var value in versions)
        {
            if (value is not JsonObject row || row.Count != 6 || row.OptArray("networkDomains") is not { } domains || domains.Any(domain => !domain.IsString())) throw new AiException("invalid_conversation", "Invalid saved version.");
            var source = Required(row, "source");
            var id = Required(row, "id", 36);
            var number = (int)Integer(row, "number", int.MaxValue);
            if (!Guid.TryParseExact(id, "D", out _) || Encoding.UTF8.GetByteCount(source) > 512 * 1024 || number < 1) throw new AiException("invalid_conversation", "Invalid saved version.");
            var hosts = domains.Select(domain => domain!.AsText()!).ToList();
            AiNetworkDeclaration.ValidateHosts(hosts);
            conversation.Versions.Add(new AiVersion(id, number, source, OptionalId(row, "parentId"), Integer(row, "createdAt"), hosts));
        }
        foreach (var value in turns)
        {
            if (value is not JsonObject row || row.Count != 15 || !Enum.TryParse<AiTurnStatus>(Required(row, "status", 20), true, out var status) || !Enum.IsDefined(status)) throw new AiException("invalid_conversation", "Invalid saved turn.");
            var id = Required(row, "id", 36);
            if (!Guid.TryParseExact(id, "D", out _) || row["isAbandoned"] is not JsonValue abandoned || !abandoned.TryGetValue<bool>(out _) ||
                row["isManualEdit"] is not JsonValue manual || !manual.TryGetValue<bool>(out _)) throw new AiException("invalid_conversation", "Invalid saved turn.");
            conversation.Turns.Add(new AiTurn
            {
                Id = id, Request = Required(row, "request", MaximumRequestCharacters), BaseVersionId = OptionalId(row, "baseVersionId"),
                Status = status == AiTurnStatus.Running ? AiTurnStatus.Interrupted : status,
                Note = OptionalText(row, "note", 600), ErrorSummary = OptionalText(row, "errorSummary", 600), Repairs = (int)Integer(row, "repairs", 4),
                VersionId = OptionalId(row, "versionId"), FailedSource = OptionalText(row, "failedSource", 512 * 1024),
                Usage = new(Integer(row, "promptTokens"), Integer(row, "completionTokens"), Integer(row, "totalTokens")),
                CreatedAt = Integer(row, "createdAt"), IsAbandoned = row.OptBoolean("isAbandoned"), IsManualEdit = row.OptBoolean("isManualEdit"),
            });
        }
        if (conversation.Versions.Select(version => version.Id).Distinct(StringComparer.Ordinal).Count() != conversation.Versions.Count ||
            conversation.Versions.Select(version => version.Number).Distinct().Count() != conversation.Versions.Count ||
            conversation.Turns.Select(turn => turn.Id).Distinct(StringComparer.Ordinal).Count() != conversation.Turns.Count ||
            conversation.CurrentVersionId is not null && conversation.CurrentVersion is null || conversation.Versions.Any(version => version.Number > conversation.VersionCounter ||
                conversation.Version(version.ParentId) is { } parent && parent.Number >= version.Number)) throw new AiException("invalid_conversation", "Saved version identities are inconsistent.");
        if (json.Has("skillIds"))
        {
            if (json.OptArray("skillIds") is not { Count: <= 64 } ids || ids.Any(id => !id.IsString() || id!.AsText()!.Length is 0 or > 128)) throw new AiException("invalid_conversation", "Invalid saved Skill selection.");
            conversation.SkillIds = ids.Select(id => id!.AsText()!).Distinct(StringComparer.Ordinal).Order(StringComparer.Ordinal).ToList();
        }
        return conversation;
    }
}

public sealed class AiConversationStore(string directory)
{
    private readonly string root = Path.GetFullPath(directory);
    private readonly object gate = new();
    private string PathOf(string id)
    {
        if (!Guid.TryParseExact(id, "D", out _)) throw new AiException("invalid_conversation", "Invalid conversation identifier.");
        return Path.Combine(root, id + ".json");
    }
    public AiConversation? Load(string id)
    {
        lock (gate)
        {
            try
            {
                var text = new SafeJsonFile(PathOf(id), AiConversation.MaximumFileBytes).Read();
                var conversation = text is null ? null : AiConversation.FromJson(text);
                return conversation?.Id == id ? conversation : null;
            }
            catch (Exception error) when (error is AiException or PrivateFile.Unreadable or StrictJson.JsonException or System.Text.Json.JsonException) { return null; }
        }
    }
    public IReadOnlyList<AiConversation> List()
    {
        lock (gate)
        {
            if (PluginFiles.RealDirectory(root) is null) return [];
            return (PluginFiles.Names(root) ?? []).Where(name => name.EndsWith(".json", StringComparison.Ordinal)).Select(name => Load(name[..^5])).OfType<AiConversation>().OrderByDescending(conversation => conversation.UpdatedAt).Take(AiConversation.MaximumConversations).ToList();
        }
    }
    public void Save(AiConversation conversation)
    {
        lock (gate)
        {
            var text = Json.Stringify(conversation.ToJson());
            if (Encoding.UTF8.GetByteCount(text) > AiConversation.MaximumFileBytes) throw new AiException("conversation_too_large", "This conversation is too large. Continue in a new conversation.");
            var validated = AiConversation.FromJson(text);
            if (validated.Id != conversation.Id) throw new AiException("invalid_conversation", "The conversation cannot be saved.");
            if (!new SafeJsonFile(PathOf(conversation.Id), AiConversation.MaximumFileBytes).Write(text)) throw new AiException("storage_unavailable", "The conversation could not be saved.");
            var all = (PluginFiles.Names(root) ?? []).Where(name => name.EndsWith(".json", StringComparison.Ordinal)).Select(name => Load(name[..^5])).OfType<AiConversation>().OrderByDescending(value => value.UpdatedAt).ToList();
            foreach (var old in all.Where(value => value.Id != conversation.Id).Skip(AiConversation.MaximumConversations - 1)) File.Delete(PathOf(old.Id));
        }
    }
}
