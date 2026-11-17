using System.Globalization;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace ScriptWidget.Core.Surfaces;

/// <summary>One entry of a package's <c>actions</c>: a JavaScript function the system may run by its <see cref="ID"/>.</summary>
public sealed record DeclaredAction(string ID, string Title, string? Description, string SystemImage, string Function);

/// <summary>
/// One entry of a package's <c>controls</c>. Exactly one of <see cref="ActionID"/>
/// (a declared action) and <see cref="Function"/> (the legacy direct
/// <c>action</c> field) is set. A toggle always has a <see cref="StateKey"/>;
/// a button never has one.
/// </summary>
public sealed record DeclaredControl(string ID, string Type, string Title, string? Subtitle, string SystemImage, string? Function, string? ActionID, string? StateKey)
{
    public const string TypeButton = "button";
    public const string TypeToggle = "toggle";
    public bool IsToggle => Type == TypeToggle;
}

/// <summary>The validated <c>actions</c> and <c>controls</c> of one package manifest.</summary>
public sealed class PackageSurfaces(IReadOnlyList<DeclaredAction> actions, IReadOnlyList<DeclaredControl> controls, bool hasStoragePermission)
{
    public IReadOnlyList<DeclaredAction> Actions { get; } = actions;
    public IReadOnlyList<DeclaredControl> Controls { get; } = controls;
    public bool HasStoragePermission { get; } = hasStoragePermission;

    /// <summary>The declared action with this identifier (compared without case, as on iOS), or null.</summary>
    public DeclaredAction? Action(string? id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        var matches = Actions.Where(item => item.ID.Equals(id, StringComparison.OrdinalIgnoreCase)).ToList();
        return matches.Count == 1 ? matches[0] : null;
    }

    /// <summary>The declared control with this identifier, or null.</summary>
    public DeclaredControl? Control(string? id)
    {
        if (string.IsNullOrEmpty(id)) return null;
        var matches = Controls.Where(item => item.ID.Equals(id, StringComparison.OrdinalIgnoreCase)).ToList();
        return matches.Count == 1 ? matches[0] : null;
    }

    /// <summary>What a package without a manifest declares: nothing.</summary>
    public static readonly PackageSurfaces Empty = new([], [], false);
}

/// <summary>A manifest whose <c>actions</c> or <c>controls</c> break the Package 2.0 contract. <see cref="Code"/> matches the shared validator's issue codes.</summary>
public sealed class SurfaceManifestException(string code, string message) : Exception(message)
{
    public string Code { get; } = code;
}

/// <summary>
/// Reads <c>actions</c> and <c>controls</c> from a decoded <c>widget.json</c>
/// with the same limits as the shared manifest validator. Anything malformed
/// throws: a system surface never runs code from a manifest it does not fully
/// accept.
/// </summary>
public static partial class SurfaceManifest
{
    public const int MaximumActions = 16;
    public const int MaximumControls = 8;

    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9.-]{0,63}\z")] private static partial Regex ShortID();
    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9.-]{0,79}\z")] private static partial Regex Symbol();
    [GeneratedRegex(@"^[A-Za-z_$][A-Za-z0-9_$]{0,63}\z")] private static partial Regex Function();
    [GeneratedRegex(@"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z")] private static partial Regex StateKey();

    private static readonly HashSet<string> ActionKeys = ["id", "title", "description", "systemImage", "function"];
    private static readonly HashSet<string> ControlKeys = ["id", "type", "title", "subtitle", "systemImage", "action", "actionID", "stateKey"];

    /// <summary>True when <paramref name="key"/> may hold a toggle's state in package storage.</summary>
    public static bool IsValidStateKey(string? key) => key is not null && StateKey().IsMatch(key);

    /// <summary>True when <paramref name="name"/> is a JavaScript function identifier a manifest may name.</summary>
    public static bool IsValidFunction(string? name) => name is not null && Function().IsMatch(name);

    /// <summary>
    /// Validates and returns the declared surfaces. A null manifest (a legacy
    /// package) declares none.
    /// </summary>
    /// <exception cref="SurfaceManifestException">A declaration is malformed or over a limit.</exception>
    public static PackageSurfaces Parse(JsonObject? manifest)
    {
        if (manifest is null) return PackageSurfaces.Empty;
        var storage = manifest.OptArray("permissions")?.Any(item => item.IsString() && item!.AsText() == "storage") ?? false;
        var actions = Actions(manifest);
        return new PackageSurfaces(actions, Controls(manifest, actions, storage), storage);
    }

    private static List<DeclaredAction> Actions(JsonObject manifest)
    {
        var items = Objects(manifest, "actions", ActionKeys);
        if (items.Count > MaximumActions) throw Fail("too_many_actions", "A package may declare at most 16 actions.");
        var result = items.Select(item =>
        {
            var id = Required(item, "id", "actions");
            if (!ShortID().IsMatch(id)) throw Fail("invalid_action_id", "Invalid action identifier.");
            var title = Required(item, "title", "actions");
            if (string.IsNullOrWhiteSpace(title) || Characters(title) > 40) throw Fail("invalid_action_title", "Action titles must contain 1–40 characters.");
            var description = Optional(item, "description", "actions");
            if (description is not null && Characters(description) > 160) throw Fail("invalid_action_description", "Action descriptions may contain at most 160 characters.");
            var image = Required(item, "systemImage", "actions");
            if (!Symbol().IsMatch(image)) throw Fail("invalid_action_image", "Action systemImage must be an SF Symbols name.");
            var name = Required(item, "function", "actions");
            if (!Function().IsMatch(name)) throw Fail("invalid_action_function", "Action function must be a JavaScript function identifier.");
            return new DeclaredAction(id, title, description, image, name);
        }).ToList();
        if (result.Select(item => item.ID.ToLowerInvariant()).Distinct().Count() != result.Count) throw Fail("duplicate_actions", "Action identifiers must be unique.");
        return result;
    }

    private static List<DeclaredControl> Controls(JsonObject manifest, List<DeclaredAction> actions, bool storage)
    {
        var items = Objects(manifest, "controls", ControlKeys);
        if (items.Count > MaximumControls) throw Fail("too_many_controls", "A package may declare at most 8 controls.");
        var result = items.Select(item =>
        {
            var id = Required(item, "id", "controls");
            if (!ShortID().IsMatch(id)) throw Fail("invalid_control_id", "Invalid control identifier.");
            var type = Required(item, "type", "controls");
            if (type != DeclaredControl.TypeButton && type != DeclaredControl.TypeToggle) throw Fail("malformed_controls", "controls are malformed.");
            var title = Required(item, "title", "controls");
            if (string.IsNullOrWhiteSpace(title) || Characters(title) > 40) throw Fail("invalid_control_title", "Control titles must contain 1–40 characters.");
            var subtitle = Optional(item, "subtitle", "controls");
            if (subtitle is not null && Characters(subtitle) > 80) throw Fail("invalid_control_subtitle", "Control subtitles may contain at most 80 characters.");
            var image = Required(item, "systemImage", "controls");
            if (!Symbol().IsMatch(image)) throw Fail("invalid_control_image", "Control systemImage must be an SF Symbols name.");
            var legacy = Optional(item, "action", "controls");
            var actionID = Optional(item, "actionID", "controls");
            if (legacy is not null && actionID is not null) throw Fail("ambiguous_control_action", "Controls must declare either action or actionID, not both.");
            if (legacy is not null) { if (!Function().IsMatch(legacy)) throw Fail("invalid_control_action", "Control action must be a JavaScript function identifier."); }
            else if (actionID is not null) { if (!actions.Any(action => action.ID.Equals(actionID, StringComparison.OrdinalIgnoreCase))) throw Fail("missing_control_action", "A control references an unknown action."); }
            else throw Fail("missing_control_action", "Controls must declare actionID or the legacy action field.");
            var key = Optional(item, "stateKey", "controls");
            if (type == DeclaredControl.TypeToggle)
            {
                if (!IsValidStateKey(key)) throw Fail("invalid_control_state", "Toggle controls require a valid stateKey.");
                if (!storage) throw Fail("control_storage", "Toggle controls require the storage permission.");
            }
            else if (key is not null) throw Fail("button_control_state", "Button controls must not declare stateKey.");
            return new DeclaredControl(id, type, title, subtitle, image, legacy, actionID, key);
        }).ToList();
        if (result.Select(item => item.ID.ToLowerInvariant()).Distinct().Count() != result.Count) throw Fail("duplicate_controls", "Control identifiers must be unique.");
        return result;
    }

    /// <summary>The objects of an optional array field; unknown keys and other shapes are rejected.</summary>
    private static List<JsonObject> Objects(JsonObject manifest, string field, HashSet<string> allowed)
    {
        if (!manifest.TryGetPropertyValue(field, out var value) || value is null) return [];
        if (value is not JsonArray array) throw Fail($"malformed_{field}", $"{field} are malformed.");
        return array.Select(node =>
        {
            if (node is not JsonObject item) throw Fail($"malformed_{field}", $"{field} are malformed.");
            if (item.Any(member => !allowed.Contains(member.Key))) throw Fail($"unknown_{field}_fields", $"{field} have unknown fields.");
            return item;
        }).ToList();
    }

    private static string Required(JsonObject item, string key, string field) =>
        item.TryGetPropertyValue(key, out var value) && value.IsString() ? value!.AsText()! : throw Fail($"malformed_{field}", $"{field} are malformed.");

    private static string? Optional(JsonObject item, string key, string field)
    {
        if (!item.TryGetPropertyValue(key, out var value) || value is null) return null;
        return value.IsString() ? value.AsText() : throw Fail($"malformed_{field}", $"{field} are malformed.");
    }

    /// <summary>User-perceived characters, the unit Swift's <c>String.count</c> uses.</summary>
    internal static int Characters(string text) => new StringInfo(text).LengthInTextElements;

    private static SurfaceManifestException Fail(string code, string message) => new(code, message);
}
