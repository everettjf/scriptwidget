namespace ScriptWidget.Core.Surfaces;

/// <summary>Why an action request was refused. The messages match the iOS action errors.</summary>
public enum ActionFailure
{
    InvalidRequest,
    ActionNotFound,
    StorageDenied,
    InvalidStateKey,
    StorageUnavailable,
}

public static class ActionFailureMessages
{
    public static string Message(this ActionFailure failure) => failure switch
    {
        ActionFailure.InvalidRequest => "This widget action is invalid or exceeds its limits. Reload the widget and try again.",
        ActionFailure.ActionNotFound => "The ScriptWidget action is no longer available.",
        ActionFailure.StorageDenied => "This action did not declare the storage permission.",
        ActionFailure.InvalidStateKey => "The action uses an invalid storage key.",
        _ => "Widget storage is busy or unavailable. Please try again.",
    };
}

/// <summary>Thrown by <see cref="ActionPlanner.Plan"/>; nothing has run or been stored when it is thrown.</summary>
public sealed class ActionRejected(ActionFailure failure) : Exception(failure.Message())
{
    public ActionFailure Failure { get; } = failure;
}

/// <summary>
/// What to run for one accepted request. Exactly one of <see cref="ActionID"/>
/// (a declared action) and <see cref="CallFunction"/> (a control's legacy
/// function) is set.
/// </summary>
/// <param name="Environments">Values the script reads with <c>$getenv</c>.</param>
/// <param name="StateKey">Package storage key to write <paramref name="StateValue"/> to before the action runs, or null.</param>
public sealed record ActionPlan(string? ActionID, string? CallFunction, IReadOnlyDictionary<string, string> Environments, string? StateKey, bool? StateValue);

/// <summary>
/// Decides what a system surface may run. Only actions and controls the
/// manifest declares are accepted; a serialized request can select one of them
/// but can never name an arbitrary function.
/// </summary>
public static class ActionPlanner
{
    public const string SourceWidget = "widget";
    public const string SourceControl = "control";
    public const string SourceShortcut = "shortcut";
    private static readonly HashSet<string> Sources = [SourceWidget, SourceControl, SourceShortcut];

    /// <param name="actionID">The declared action; for <see cref="SourceControl"/> it may be null and is then taken from the control.</param>
    /// <param name="value">A toggle's new value, or null for a button.</param>
    /// <param name="controlID">The declared control; required for, and only allowed with, <see cref="SourceControl"/>.</param>
    /// <param name="stateKey">Storage key of a widget <c>&lt;toggle&gt;</c>; a control's own <c>stateKey</c> always wins.</param>
    /// <exception cref="ActionRejected">The request does not match the manifest.</exception>
    public static ActionPlan Plan(PackageSurfaces surfaces, string? actionID, string source, bool? value, string? controlID, string? stateKey = null)
    {
        if (!Sources.Contains(source)) throw new ActionRejected(ActionFailure.InvalidRequest);
        var environments = new Dictionary<string, string>
        {
            ["widget-size"] = "action",
            ["widget-param"] = "",
            ["action-source"] = source,
        };

        if (source == SourceControl)
        {
            var control = surfaces.Control(controlID) ?? throw new ActionRejected(ActionFailure.ActionNotFound);
            var declaredAction = control.ActionID is null ? null : surfaces.Action(control.ActionID) ?? throw new ActionRejected(ActionFailure.ActionNotFound);
            // A caller that names an action must name the one this control is declared with.
            if (!string.IsNullOrEmpty(actionID) && !actionID.Equals(declaredAction?.ID ?? control.ID, StringComparison.OrdinalIgnoreCase)) throw new ActionRejected(ActionFailure.ActionNotFound);
            if (control.IsToggle != (value is not null)) throw new ActionRejected(ActionFailure.InvalidRequest);
            string? controlKey = null;
            if (control.IsToggle)
            {
                if (!surfaces.HasStoragePermission) throw new ActionRejected(ActionFailure.StorageDenied);
                if (!SurfaceManifest.IsValidStateKey(control.StateKey)) throw new ActionRejected(ActionFailure.InvalidStateKey);
                controlKey = control.StateKey;
            }
            // A legacy control behaves like an action named after the control.
            environments["action-id"] = declaredAction?.ID ?? control.ID;
            environments["control-id"] = control.ID;
            Value(environments, value);
            return new ActionPlan(declaredAction?.ID, declaredAction is null ? control.Function : null, environments, controlKey, value);
        }

        if (controlID is not null) throw new ActionRejected(ActionFailure.InvalidRequest);
        var declared = surfaces.Action(actionID) ?? throw new ActionRejected(ActionFailure.ActionNotFound);
        string? key = null;
        if (stateKey is not null)
        {
            if (value is null) throw new ActionRejected(ActionFailure.InvalidRequest);
            if (!surfaces.HasStoragePermission) throw new ActionRejected(ActionFailure.StorageDenied);
            if (!SurfaceManifest.IsValidStateKey(stateKey)) throw new ActionRejected(ActionFailure.InvalidStateKey);
            key = stateKey;
        }
        environments["action-id"] = declared.ID;
        Value(environments, value);
        return new ActionPlan(declared.ID, null, environments, key, value);
    }

    /// <summary>A stored toggle state: <c>true</c> and <c>1</c> are on, everything else (including a missing value) is off.</summary>
    public static bool IsOn(string? stored) => stored is "true" or "1";

    private static void Value(Dictionary<string, string> environments, bool? value)
    {
        if (value is null) return;
        environments["action-value"] = value.Value ? "true" : "false";
        // Compatibility name from the first Control Widget release.
        environments["control-value"] = environments["action-value"];
    }
}
