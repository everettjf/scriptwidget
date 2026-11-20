using System.Text.Json.Nodes;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Plugins;
using ScriptWidget.Core.Hosting;
using Windows.Security.Credentials;

namespace ScriptWidget.Core.AI;

public enum AiProvider { Anthropic, OpenAi, Compatible, Ollama, LmStudio }

/// <summary>Provider metadata only. There is deliberately no key field.</summary>
public sealed record AiProfile(string Id, string Name, AiProvider Provider, string BaseUrl, string Model, double Temperature = .7)
{
    public static AiProfile Create(AiProvider provider) => new(Guid.NewGuid().ToString("D"), provider switch { AiProvider.Anthropic => "Anthropic", AiProvider.OpenAi => "OpenAI", AiProvider.Ollama => "Ollama", AiProvider.LmStudio => "LM Studio", _ => "OpenAI-compatible" }, provider,
        provider switch { AiProvider.Anthropic => "https://api.anthropic.com", AiProvider.OpenAi => "https://api.openai.com", AiProvider.Ollama => "http://localhost:11434", AiProvider.LmStudio => "http://localhost:1234", _ => "" },
        provider switch { AiProvider.Anthropic => "claude-fable-5-2", AiProvider.OpenAi => "gpt-4o-mini", _ => "" });
    public bool IsLocalPreset => Provider is AiProvider.Ollama or AiProvider.LmStudio;
    public bool IsLoopback => Uri.TryCreate(NormalizedBaseUrl, UriKind.Absolute, out var uri) && IsLoopbackHost(uri.IdnHost);
    internal static bool IsLoopbackHost(string host) => host.Equals("localhost", StringComparison.OrdinalIgnoreCase) || host is "127.0.0.1" or "::1" or "[::1]";

    public AiApiKey? ReadKey(IAiCredentials credentials)
    {
        if (ValidationError(requireModel: false) is { } error) throw new AiException("invalid_profile", error);
        var key = credentials.Get(Id);
        if (key is null && !IsLoopback) throw new AiException("missing_api_key", "Configure this provider's API key first.");
        return key;
    }
    public string NormalizedBaseUrl
    {
        get
        {
            var value = BaseUrl.Trim().TrimEnd('/');
            if (value.EndsWith("/v1", StringComparison.Ordinal)) value = value[..^3].TrimEnd('/');
            return value;
        }
    }
    public string? ValidationError(bool requireModel = true)
    {
        if (!Guid.TryParseExact(Id, "D", out _) || string.IsNullOrWhiteSpace(Name) || Name.Length > 80 || Name.Any(char.IsControl) || !Enum.IsDefined(Provider)) return "The provider profile is invalid.";
        var value = NormalizedBaseUrl;
        if (value.Length is 0 or > 2048 || value.Any(character => char.IsWhiteSpace(character) || char.IsControl(character) || character is '\\' or '%') ||
            !Uri.TryCreate(value, UriKind.Absolute, out var uri) || string.IsNullOrEmpty(uri.Host) ||
            !(uri.Scheme == "https" || uri.Scheme == "http" && IsLoopback)) return "Use HTTPS, or HTTP on localhost, 127.0.0.1 or [::1].";
        if (IsLocalPreset && !IsLoopback) return "Ollama and LM Studio presets connect to this computer. Use OpenAI-compatible for a remote HTTPS server.";
        if (uri.UserInfo.Length > 0 || uri.Query.Length > 0 || uri.Fragment.Length > 0) return "The API base URL must not contain credentials, a query or a fragment.";
        var pathStart = value.IndexOf('/', value.IndexOf("://", StringComparison.Ordinal) + 3);
        if (pathStart >= 0 && value[pathStart..].Split('/').Any(part => part is "." or "..")) return "The API base URL contains an invalid path.";
        if (value.EndsWith("/chat/completions", StringComparison.Ordinal) || value.EndsWith("/messages", StringComparison.Ordinal)) return "Enter the base URL only, without the endpoint path.";
        if (requireModel && string.IsNullOrWhiteSpace(Model) || Model.Trim().Length > 200 || Model.Any(char.IsControl)) return "Choose a valid model before generating a widget.";
        if (!double.IsFinite(Temperature) || Temperature is < 0 or > 2) return "Temperature must be between 0 and 2.";
        return null;
    }
}

/// <summary>A key is handed directly to the client, never serialized or printed.</summary>
public sealed class AiApiKey
{
    internal string Secret { get; }
    public AiApiKey(string value)
    {
        var key = value.Trim();
        if (key.Length is 0 or > 4096 || key.Any(character => char.IsControl(character) || character > 0x7e))
            throw new AiException("missing_api_key", "Enter an API key without control characters (at most 4096 characters).");
        Secret = key;
    }
    public override string ToString() => "[redacted API key]";
    internal string Redact(string text) => text.Replace(Secret, "[redacted]", StringComparison.Ordinal);
}

public interface IAiCredentials
{
    AiApiKey? Get(string profileId);
    void Set(string profileId, AiApiKey key);
    void Remove(string profileId);
}

/// <summary>Windows Credential Locker. No key bytes are written to the app's data directory.</summary>
public sealed class WindowsAiCredentials(string resource = "ScriptWidget.AI") : IAiCredentials
{
    private const int NotFound = unchecked((int)0x80070490);
    private static void RequireId(string id)
    {
        if (!Guid.TryParseExact(id, "D", out _)) throw new AiException("invalid_profile", "The provider profile is invalid.");
    }
    public AiApiKey? Get(string profileId)
    {
        RequireId(profileId);
        try
        {
            var credential = new PasswordVault().Retrieve(resource, profileId);
            credential.RetrievePassword();
            return new AiApiKey(credential.Password);
        }
        catch (Exception error) when (error.HResult == NotFound) { return null; }
        catch (Exception error) when (error is not OutOfMemoryException) { throw new AiException("credentials_unavailable", "Windows Credential Locker could not read this provider's key."); }
    }
    public void Set(string profileId, AiApiKey key)
    {
        RequireId(profileId);
        try { new PasswordVault().Add(new PasswordCredential(resource, profileId, key.Secret)); }
        catch (Exception error) when (error is not OutOfMemoryException) { throw new AiException("credentials_unavailable", "Windows Credential Locker could not save this provider's key."); }
    }
    public void Remove(string profileId)
    {
        RequireId(profileId);
        try { var vault = new PasswordVault(); vault.Remove(vault.Retrieve(resource, profileId)); }
        catch (Exception error) when (error.HResult == NotFound) { }
        catch (Exception error) when (error is not OutOfMemoryException) { throw new AiException("credentials_unavailable", "Windows Credential Locker could not remove this provider's key."); }
    }
}

public sealed record AiProfileSettings(IReadOnlyList<AiProfile> Profiles, string? ActiveId)
{
    public AiProfile? Active => Profiles.FirstOrDefault(profile => profile.Id == ActiveId);
}

public interface IAiProfileSettingsStore
{
    AiProfileSettings Load();
    void Save(AiProfileSettings settings);
}

public sealed class AiProfileStore(string path) : IAiProfileSettingsStore
{
    private readonly SafeJsonFile file = new(path, 64 * 1024);
    public AiProfileSettings Load()
    {
        try
        {
            var text = file.Read();
            if (text is null) return new([], null);
            StrictJson.Parse(text);
            var json = Json.ParseObject(text);
            if (json.Count != 3 || !json.Has("activeId") || json["formatVersion"] is not JsonValue rootVersion || !rootVersion.TryGetValue<int>(out var schema) || schema != 1 || json.OptArray("profiles") is not { Count: <= 20 } rows ||
                !(json["activeId"] is null || json["activeId"].IsString())) return new([], null);
            var profiles = new List<AiProfile>();
            foreach (var row in rows)
            {
                if (row is not JsonObject value || value.Count != 7 || new[] { "id", "name", "provider", "baseUrl", "model" }.Any(key => !value[key].IsString()) ||
                    !Enum.TryParse<AiProvider>(value.OptString("provider"), out var provider) || !Enum.GetNames<AiProvider>().Contains(value.OptString("provider"), StringComparer.Ordinal) ||
                    value["formatVersion"] is not JsonValue rowVersion || !rowVersion.TryGetValue<int>(out var format) || format != 1 ||
                    value["temperature"] is not JsonValue temperature || !temperature.TryGetValue<double>(out _)) return new([], null);
                var profile = new AiProfile(value.OptString("id"), value.OptString("name"), provider, value.OptString("baseUrl"), value.OptString("model"), value.OptDouble("temperature"));
                if (profile.ValidationError(requireModel: false) is not null) return new([], null);
                profiles.Add(profile);
            }
            var active = json.OptStringOrNull("activeId");
            if (profiles.Select(profile => profile.Id).Distinct(StringComparer.Ordinal).Count() != profiles.Count || active is not null && !profiles.Any(profile => profile.Id == active)) return new([], null);
            return new(profiles, active);
        }
        catch (Exception error) when (error is PrivateFile.Unreadable or StrictJson.JsonException or System.Text.Json.JsonException) { return new([], null); }
    }

    public void Save(AiProfileSettings settings)
    {
        if (settings.Profiles.Count > 20 || settings.Profiles.Any(profile => profile.ValidationError(requireModel: false) is not null) ||
            settings.Profiles.Select(profile => profile.Id).Distinct(StringComparer.Ordinal).Count() != settings.Profiles.Count ||
            settings.ActiveId is not null && !settings.Profiles.Any(profile => profile.Id == settings.ActiveId)) throw new AiException("invalid_profile", "The provider settings are invalid.");
        var profiles = new JsonArray();
        foreach (var profile in settings.Profiles) profiles.Append(new JsonObject
        {
            ["formatVersion"] = 1, ["id"] = profile.Id, ["name"] = profile.Name, ["provider"] = profile.Provider.ToString(),
            ["baseUrl"] = profile.NormalizedBaseUrl, ["model"] = profile.Model.Trim(), ["temperature"] = profile.Temperature,
        });
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        if (!file.Write(Json.Stringify(new JsonObject { ["formatVersion"] = 1, ["activeId"] = settings.ActiveId, ["profiles"] = profiles }))) throw new AiException("storage_unavailable", "AI provider settings could not be saved.");
    }
}
