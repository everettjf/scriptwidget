using System.Globalization;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Js;

namespace ScriptWidget.Core.Runtime;

/// <summary>The current timeline entry of a package and when the next one starts.</summary>
public sealed record TimelineState(IReadOnlyDictionary<string, string> Environments, long? NextTransitionMilliseconds);

/// <summary>
/// Evaluates a package's <c>timeline.dailyTimes</c> schedule with the planner
/// shared with iOS and the web preview (Web/preview-engine/src/timeline.js),
/// so slots, time zones and daylight-saving rules agree on every platform.
///
/// iOS hands WidgetKit pre-rendered future entries. Windows, like Android,
/// wakes at the next transition and runs the script again as the current entry.
/// </summary>
public sealed class TimelinePlanner(SharedScripts scripts)
{
    private sealed record Cached(TimelineState State, long From, long Until);
    private readonly Dictionary<string, Cached> cache = new();

    /// <summary>Returns null when the manifest declares no schedule or the schedule is invalid.</summary>
    public TimelineState? State(JsonObject? manifest, long? nowMilliseconds = null)
    {
        if (manifest.OptObject("timeline") is not { } schedule) return null;
        var now = nowMilliseconds ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        // A plan stays correct until its next transition, so widgets that refresh often reuse it.
        var key = Json.Stringify(schedule) + "|" + IntlBridge.DefaultTimeZone();
        lock (cache)
        {
            if (cache.TryGetValue(key, out var hit) && now >= hit.From && now < hit.Until) return hit.State;
        }
        if (Evaluate(schedule, now) is not { } state) return null;
        var until = Math.Min(state.NextTransitionMilliseconds ?? long.MaxValue, now + 3_600_000);
        lock (cache)
        {
            if (cache.Count >= 32) cache.Clear();
            cache[key] = new Cached(state, now, until);
        }
        return state;
    }

    private TimelineState? Evaluate(JsonObject schedule, long nowMilliseconds)
    {
        JsonObject plan;
        try
        {
            plan = JsThread.Run(() =>
            {
                // A small context: the planner needs Intl and the prepare bundle, not Babel.
                using var engine = new QuickJs((operation, payload) => IntlBridge.Call(operation, payload), memoryLimitBytes: 32L * 1024 * 1024);
                engine.SetDeadline(6000);
                engine.Evaluate(scripts.Text("host.js"), "host.js");
                engine.Evaluate("globalThis.TextEncoder = class { encode(text) { return new Uint8Array(unescape(encodeURIComponent(String(text))).split('').map(function (c) { return c.charCodeAt(0); })); } };", "prelude.js");
                engine.Evaluate(scripts.Text("prepare.js"), "prepare.js");
                engine.Evaluate(
                    "globalThis.__swPlan = function (schedule, now, zone) { var time = Number(now);" +
                    " return JSON.stringify(__swPrepareBundle.buildTimelinePlan(JSON.parse(schedule), new Date(time), new Date(time + 3600000), zone)); };",
                    "timeline-driver.js");
                return Json.ParseObject(engine.Call("__swPlan", Json.Stringify(schedule), nowMilliseconds.ToString(CultureInfo.InvariantCulture), IntlBridge.DefaultTimeZone())!);
            }, "scriptwidget-timeline");
        }
        catch (Exception error) when (error is JsException or System.Text.Json.JsonException or NullReferenceException)
        {
            System.Diagnostics.Trace.WriteLine($"Timeline schedule could not be evaluated: {error.Message[..Math.Min(300, error.Message.Length)]}");
            return null;
        }
        if (plan.OptArray("entries") is not { } entries || entries.Count == 0) return null;
        if ((entries[0] as JsonObject).OptObject("environments") is not { } current) return null;
        var environments = new Dictionary<string, string>();
        foreach (var (key, value) in current) environments[key] = value?.AsText() ?? "";
        long? next = null;
        if (entries.Count > 1 && (entries[1] as JsonObject).OptString("date") is { Length: > 0 } date
            && DateTimeOffset.TryParse(date, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out var parsed)) next = parsed.ToUnixTimeMilliseconds();
        return new TimelineState(environments, next);
    }
}
