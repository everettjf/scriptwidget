using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Api;

// The shared pieces of the Runtime 1.6 system services that $weather needs. The other
// services (grants, mutation receipts, permission prompts) are added with the APIs that use them.

/// <summary>A rejection whose message is delivered to the script verbatim. It never contains user data.</summary>
public sealed class SystemReject(string message) : Exception(message);

/// <summary>
/// Error codes shared by the Runtime 1.6 system services. The message is the same sentence the
/// Apple runtime uses, so scripts that match on the bracketed code behave the same on Windows.
/// </summary>
public enum SystemServiceError { InvalidOptions, PermissionDenied, Unavailable, QueryLimit, ReadOnly, ScopeChanged, LimitExceeded, OutcomeUnknown, RequestConflict }

public static class SystemServiceErrors
{
    /// <summary>Message for a failure that is not one of the known codes.</summary>
    public const string Failed = "[system_failed] System operation failed; review the result before retrying a write.";

    public static string Code(this SystemServiceError error) => error switch
    {
        SystemServiceError.InvalidOptions => "invalid_options",
        SystemServiceError.PermissionDenied => "permission_denied",
        SystemServiceError.Unavailable => "unavailable",
        SystemServiceError.QueryLimit => "query_limit",
        SystemServiceError.ReadOnly => "read_only",
        SystemServiceError.ScopeChanged => "scope_changed",
        SystemServiceError.LimitExceeded => "limit_exceeded",
        SystemServiceError.OutcomeUnknown => "outcome_unknown",
        _ => "request_conflict",
    };

    public static string Message(this SystemServiceError error) => $"[{error.Code()}] System operation could not complete. Existing user data is preserved.";

    public static SystemReject Reject(this SystemServiceError error) => new(error.Message());
}

/// <summary>One line per native call. Callers pass operation names and error codes only, never user data.</summary>
public static partial class SystemLog
{
    /// <summary>Receives each line. The host sets it to its log; tests capture lines. Nothing is written by default.</summary>
    public static volatile Action<string> Sink = _ => { };

    public static void Call(string operation, string outcome) => Sink($"{operation} -> {outcome}");

    [GeneratedRegex(@"\A\[([a-z_:A-Z]{1,40})]", RegexOptions.CultureInvariant)]
    private static partial Regex Bracketed();

    /// <summary>The bracketed code of a rejection message, or <c>error</c> when it has none. The free text is never logged.</summary>
    public static string Code(string message) => Bracketed().Match(message) is { Success: true } match ? match.Groups[1].Value : "error";
}

/// <summary>Background workers for system queries, so the JavaScript thread never blocks on a provider or disk.</summary>
internal static class SystemExecutor
{
    public static readonly BoundedExecutor Pool = new(4);

    /// <summary>Runs <paramref name="block"/> off the JavaScript thread, logs one line, and completes <paramref name="done"/> exactly once with JSON or a rejection message.</summary>
    public static void Run(string operation, NativeCompletion done, Func<string> block)
    {
        void Finish(bool ok, string value)
        {
            SystemLog.Call(operation, ok ? "ok" : SystemLog.Code(value));
            done(ok, ok ? value : Json.Quote(value));
        }
        Pool.Execute(() =>
        {
            string result;
            try { result = block(); }
            catch (SystemReject error) { Finish(false, string.IsNullOrEmpty(error.Message) ? SystemServiceErrors.Failed : error.Message); return; }
            catch (Exception) { Finish(false, SystemServiceErrors.Failed); return; }
            Finish(true, result);
        });
    }
}

/// <summary>
/// The facts about one execution that policy decisions need. Built from the
/// <see cref="ExecutionRequest"/> in production and directly in tests, so every rule can
/// be exercised without the JavaScript engine.
/// </summary>
public sealed partial class CallContext(
    string installation,
    bool hasManifest,
    IReadOnlySet<string> permissions,
    IReadOnlyList<string> networkDomains,
    string? minimumRuntimeVersion,
    bool isAction,
    bool isTimelineProjection,
    bool isLiveActivity,
    Func<bool>? dataQuery = null,
    Func<bool>? networkRequest = null,
    Func<bool>? active = null,
    CancellationToken cancellation = default)
{
    public const int MaximumDataQueries = 8;
    public const int MaximumNetworkRequests = 32;

    /// <summary>Installation identity; namespaces grants, receipts and caches.</summary>
    public string Installation { get; } = installation;
    public bool HasManifest { get; } = hasManifest;
    public IReadOnlySet<string> Permissions { get; } = permissions;
    public IReadOnlyList<string> NetworkDomains { get; } = networkDomains;
    public string? MinimumRuntimeVersion { get; } = minimumRuntimeVersion;
    public bool IsAction { get; } = isAction;
    public bool IsTimelineProjection { get; } = isTimelineProjection;
    public bool IsLiveActivity { get; } = isLiveActivity;
    /// <summary>Cancelled when the execution ends; in-flight work should stop.</summary>
    public CancellationToken Cancellation { get; } = cancellation;

    /// <summary>An installed owner is a canonical lowercase UUID; previews and unmanaged packages are not owners.</summary>
    public bool IsInstalled => IsOwner(Installation);

    /// <summary>True while the execution is still running; results for a finished execution are dropped.</summary>
    public bool IsActive => active?.Invoke() ?? true;

    /// <summary>Takes one of the eight system-data queries of this execution. False when the budget is spent.</summary>
    public bool ConsumeDataQuery() => dataQuery?.Invoke() ?? true;

    /// <summary>Takes one of the 32 network requests of this execution.</summary>
    public bool ConsumeNetworkRequest() => networkRequest?.Invoke() ?? true;

    /// <summary>Package 2.0 permission check: a missing manifest never declares anything.</summary>
    public bool Declares(string permission) => HasManifest && Permissions.Contains(permission);

    /// <summary><c>network</c> plus a matching <c>networkDomains</c> entry, the rule <c>fetch</c> applies.</summary>
    public bool AllowsHost(string host) => Declares("network") && RuntimePolicy.HostMatches(host, NetworkDomains);

    [GeneratedRegex(@"\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z", RegexOptions.CultureInvariant)]
    private static partial Regex Owner();

    public static bool IsOwner(string value) => Owner().IsMatch(value);

    public static CallContext From(ExecutionRequest request)
    {
        var manifest = request.Prepared.Manifest;
        List<string> Strings(string key) => manifest.OptArray(key)?.Select(item => item?.AsText() ?? "").ToList() ?? [];
        var runtime = manifest.OptString("minimumRuntimeVersion");
        return new CallContext(
            installation: request.PackageID,
            // A present manifest that could not be read still counts as present: it declares nothing and is never treated as legacy.
            hasManifest: request.Prepared.HasManifest,
            permissions: Strings("permissions").ToHashSet(StringComparer.Ordinal),
            networkDomains: Strings("networkDomains"),
            minimumRuntimeVersion: runtime.Length > 0 ? runtime : null,
            isAction: RuntimePolicy.IsAction(request),
            isTimelineProjection: RuntimePolicy.IsTimelineProjection(request),
            isLiveActivity: RuntimePolicy.IsLiveActivity(request),
            dataQuery: () => request.Session.AddDataQuery() <= MaximumDataQueries,
            networkRequest: () => request.Session.AddNetworkRequest() <= MaximumNetworkRequests,
            active: () => !request.Session.Finished,
            cancellation: request.Session.Cancellation.Token);
    }
}

/// <summary>ISO-8601 instants in the forms the Apple runtime accepts and produces.</summary>
public static partial class IsoDates
{
    [GeneratedRegex(@"\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?(?:Z|([+-])([0-9]{2}):([0-9]{2}))\z", RegexOptions.CultureInvariant)]
    private static partial Regex Pattern();

    /// <summary>Epoch milliseconds of a full date-time with a time zone, or null. Dates without a zone or with impossible fields are rejected.</summary>
    public static long? Parse(string text)
    {
        if (Encoding.UTF8.GetByteCount(text) > 64 || Pattern().Match(text) is not { Success: true } match) return null;
        int Field(int group) => int.Parse(match.Groups[group].Value, NumberStyles.None, CultureInfo.InvariantCulture);
        int year = Field(1), month = Field(2), day = Field(3), hour = Field(4), minute = Field(5), second = Field(6);
        if (year < 1 || month is < 1 or > 12 || day < 1 || day > DateTime.DaysInMonth(year, month) || hour > 23 || minute > 59 || second > 59) return null;
        long offsetMinutes = 0;
        if (match.Groups[8].Success)
        {
            int offsetHours = Field(9), offsetRest = Field(10);
            if (offsetHours > 18 || offsetRest > 59 || (offsetHours == 18 && offsetRest != 0)) return null;
            offsetMinutes = (match.Groups[8].Value == "-" ? -1 : 1) * (offsetHours * 60L + offsetRest);
        }
        var fraction = match.Groups[7].Success ? int.Parse(match.Groups[7].Value.PadRight(3, '0')[..3], NumberStyles.None, CultureInfo.InvariantCulture) : 0;
        var local = new DateTime(year, month, day, hour, minute, second, DateTimeKind.Utc);
        return (local.Ticks - DateTime.UnixEpoch.Ticks) / TimeSpan.TicksPerMillisecond - offsetMinutes * 60_000L + fraction;
    }

    /// <summary><c>2026-11-01T12:00:00Z</c>: whole seconds, UTC.</summary>
    public static string Format(long milliseconds)
    {
        var seconds = milliseconds >= 0 ? milliseconds / 1000 : -((-milliseconds + 999) / 1000);
        return DateTime.UnixEpoch.AddSeconds(seconds).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
    }
}

/// <summary>Strict, bounded option parsing shared by the system services. Every failure is <c>invalid_options</c>.</summary>
public static class SystemOptions
{
    public const int MaximumOptionBytes = 16384;

    private static SystemReject Invalid() => SystemServiceError.InvalidOptions.Reject();

    /// <summary>Rejects unknown fields and option objects above 16 KiB.</summary>
    public static void Fields(JsonObject options, IReadOnlySet<string> allowed)
    {
        if (options.Any(member => !allowed.Contains(member.Key)) || Encoding.UTF8.GetByteCount(Json.Stringify(options)) > MaximumOptionBytes) throw Invalid();
    }

    public static bool HasControlCharacters(string text)
    {
        for (var index = 0; index < text.Length; index++)
        {
            // An unpaired surrogate is neither a control nor a format character.
            if (!Rune.TryGetRuneAt(text, index, out var rune)) continue;
            if (Rune.GetUnicodeCategory(rune) is UnicodeCategory.Control or UnicodeCategory.Format) return true;
            index += rune.Utf16SequenceLength - 1;
        }
        return false;
    }

    /// <summary>A finite JSON number inside the range; Booleans and strings are not numbers.</summary>
    public static double Number(JsonNode? value, double minimum, double maximum)
    {
        if (JsonNumber(value) is not { } number) throw Invalid();
        if (!double.IsFinite(number) || number < minimum || number > maximum) throw Invalid();
        return number;
    }

    /// <summary>The value of a JSON number, however the node was made; null for everything else.</summary>
    public static double? JsonNumber(JsonNode? value)
    {
        if (value is null || !value.IsNumber()) return null;
        if (value.AsDouble() is { } number) return number;
        return double.TryParse(value.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var parsed) ? parsed : null;
    }

    public static int Integer(JsonNode? value, int minimum, int maximum)
    {
        var number = Number(value, minimum, maximum);
        if (Math.Round(number, MidpointRounding.ToEven) != number) throw Invalid();
        return (int)number;
    }
}

/// <summary>Digests for cache identities.</summary>
public static class Canonical
{
    public static string Sha256(string text) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(text)));

    /// <summary>File names for per-installation records: a digest, so an identity can never become a path.</summary>
    public static string OwnerFileName(string installation, string suffix) => Sha256(installation)[..40] + suffix;
}

/// <summary>
/// A small private JSON file. Reads are bounded and refuse links and
/// non-regular files; writes replace the file atomically. A present file that
/// cannot be read is reported as <see cref="Unreadable"/> so callers fail closed instead
/// of treating it as missing.
/// </summary>
public sealed class PrivateFile(string path, int maximumBytes)
{
    public sealed class Unreadable() : Exception("private file is unreadable");

    private static readonly ConcurrentDictionary<string, object> Locks = new(StringComparer.OrdinalIgnoreCase);

    public string Path { get; } = path;

    /// <summary>Lock shared by every reader and writer of this path in the process.</summary>
    public object Lock => Locks.GetOrAdd(System.IO.Path.GetFullPath(Path), _ => new object());

    public bool Exists() => Attributes() is not null;

    /// <summary>File text, or null when the file does not exist.</summary>
    public string? Read()
    {
        if (Attributes() is not { } attributes) return null;
        if (attributes.HasFlag(FileAttributes.Directory) || attributes.HasFlag(FileAttributes.ReparsePoint)) throw new Unreadable();
        try
        {
            using var stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length > maximumBytes) throw new Unreadable();
            var bytes = new byte[maximumBytes + 1];
            var total = 0;
            while (total < bytes.Length)
            {
                var count = stream.Read(bytes, total, bytes.Length - total);
                if (count <= 0) break;
                total += count;
            }
            if (total > maximumBytes) throw new Unreadable();
            return Encoding.UTF8.GetString(bytes, 0, total);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new Unreadable();
        }
    }

    /// <summary>Writes the text through a temporary file and an atomic rename. False when it exceeds the bound or the disk refuses it.</summary>
    public bool Write(string text)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        if (bytes.Length > maximumBytes) return false;
        var temporary = Path + ".tmp";
        try
        {
            if (System.IO.Path.GetDirectoryName(Path) is { Length: > 0 } parent) Directory.CreateDirectory(parent);
            File.WriteAllBytes(temporary, bytes);
            File.Move(temporary, Path, overwrite: true);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); } catch (Exception inner) when (inner is IOException or UnauthorizedAccessException) { }
            return false;
        }
    }

    public void Delete()
    {
        try { File.Delete(Path); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
    }

    /// <summary>Attributes of the entry itself (never of a link target), or null when nothing is there.</summary>
    private FileAttributes? Attributes()
    {
        try { return File.GetAttributes(Path); }
        catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException) { return null; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { throw new Unreadable(); }
    }
}

/// <summary>
/// The shared gate of the Runtime 1.6 system services. The order is the Apple
/// runtime's and decides which code a script sees:
/// 1. <c>permission_denied</c>: not an installed owner, no manifest, the permission
///    is not declared, or <c>minimumRuntimeVersion</c> is below 1.6;
/// 2. <c>read_only</c>: a future timeline entry, a Live Activity presentation, or
///    a write outside a user-initiated action;
/// 3. <c>query_limit</c>: the eight-query budget of the execution is spent.
/// Services with a per-widget native grant check it between steps 2 and 3; <c>$weather</c> has none.
/// </summary>
public static partial class SystemGate
{
    public static void Check(CallContext context, string permission, bool writing)
    {
        Validate(context, permission, writing);
        if (!context.ConsumeDataQuery()) throw SystemServiceError.QueryLimit.Reject();
    }

    /// <summary>Steps 1 and 2 only; repeated before a result is delivered so a changed state stops an in-flight call.</summary>
    public static void Validate(CallContext context, string permission, bool writing)
    {
        if (!context.IsInstalled || !context.Declares(permission) || !SupportsRuntime("1.6", context.MinimumRuntimeVersion)) throw SystemServiceError.PermissionDenied.Reject();
        if (context.IsTimelineProjection || context.IsLiveActivity || (writing && !context.IsAction)) throw SystemServiceError.ReadOnly.Reject();
    }

    [GeneratedRegex(@"\A([0-9]{1,4})\.([0-9]{1,4})\z", RegexOptions.CultureInvariant)]
    private static partial Regex Version();

    /// <summary>True when <paramref name="declared"/> (<c>major.minor</c>) is at least <paramref name="required"/>. A missing or malformed version is 0.0.</summary>
    public static bool SupportsRuntime(string required, string? declared)
    {
        static (int Major, int Minor)? Parts(string? text) =>
            Version().Match(text ?? "") is { Success: true } match ? (int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture), int.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture)) : null;
        if (Parts(required) is not { } need) return false;
        var have = Parts(declared) ?? (0, 0);
        return have.Major > need.Major || (have.Major == need.Major && have.Minor >= need.Minor);
    }
}
