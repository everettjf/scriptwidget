using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Text.Json.Nodes;
using ScriptWidget.App.Interop;
using ScriptWidget.App.Windowing;
using ScriptWidget.Core;
using ScriptWidget.Core.Api;
using ScriptWidget.Core.Hosting;
using ScriptWidget.Core.Render;
using ScriptWidget.Core.Surfaces;

namespace ScriptWidget.App;

/// <summary>What a click asked for. Replayed against the package on the refresh thread.</summary>
internal sealed record WidgetAction(string Type, string? ActionID, string? Function, string? StateKey, bool? Value);

/// <summary>One widget on the desktop. Used on the UI thread only.</summary>
internal sealed class WidgetController(WidgetPlacement placement, WidgetWindow window)
{
    public WidgetPlacement Placement { get; } = placement;
    public WidgetWindow Window { get; } = window;
    public IReadOnlyList<HitRegion> HitRegions { get; set; } = [];
    /// <summary>Pixels per point of the bitmap on screen.</summary>
    public double RenderedScale { get; set; } = 1;
    public RunRequest? LastRequest { get; set; }
    public RunResult? LastResult { get; set; }
    /// <summary>When to run the script again (Environment.TickCount64).</summary>
    public long NextRun { get; set; } = long.MaxValue;
    /// <summary>When to redraw the same tree because a date in it changed; long.MaxValue when it has none.</summary>
    public long NextRedraw { get; set; } = long.MaxValue;
    public bool Busy { get; set; }
    public bool Placed { get; set; }
    /// <summary>Requests that arrived while a refresh was running.</summary>
    public bool RunAgain { get; set; }
    public WidgetAction? PendingAction { get; set; }
}

/// <summary>
/// The always-running desktop host: owns the widget windows, runs packages on
/// a schedule, handles clicks and the tray menu, and answers the management
/// window over the local pipe. Windows and menus live on the UI thread;
/// scripts and rendering run on one background thread, one widget at a time.
/// </summary>
internal sealed unsafe class AppHost : NativeWindow
{
    private const nuint ScheduleTimer = 1;
    private const uint WM_WTSSESSION_CHANGE = 0x02B1;
    private const int WTS_SESSION_LOCK = 7, WTS_SESSION_UNLOCK = 8;

    [DllImport("wtsapi32.dll")] private static extern int WTSRegisterSessionNotification(nint window, uint flags);
    [DllImport("wtsapi32.dll")] private static extern int WTSUnRegisterSessionNotification(nint window);

    private readonly DataPaths paths;
    private readonly HostSettings settings;
    private readonly WidgetPlacements placements;
    private readonly Library library;
    private readonly Lazy<WidgetRuntime> runtime;
    private readonly UiDispatcher ui;
    private readonly DesktopLayer layer;
    private readonly TrayIcon tray;
    private readonly Dictionary<string, WidgetController> widgets = new();
    private readonly BlockingCollection<Action> work = new();
    private readonly CancellationTokenSource stopping = new();
    private bool sessionLocked;
    private bool quitting;

    private AppHost(DataPaths paths)
    {
        this.paths = paths;
        settings = new HostSettings(paths.Settings);
        placements = new WidgetPlacements(paths.Widgets);
        library = new Library(paths);
        runtime = new Lazy<WidgetRuntime>(() => new WidgetRuntime(paths));
        ui = new UiDispatcher();
        layer = new DesktopLayer();
        // A hidden top-level window: message-only windows do not receive the system broadcasts used below.
        Create("ScriptWidgetHost", Win32.WS_EX_TOOLWINDOW, Win32.WS_POPUP);
        WTSRegisterSessionNotification(Handle, 0);
        tray = new TrayIcon(Strings.TrayTip, Path.Combine(AppContext.BaseDirectory, "ScriptWidget.ico")) { Menu = TrayMenu };
        tray.Activated += () => Studio.Open();
        layer.TaskbarCreated += tray.Add;
        var worker = new Thread(() => { foreach (var job in work.GetConsumingEnumerable()) { try { job(); } catch (Exception error) { Log.Write($"refresh job failed: {error}"); } } })
        { Name = "scriptwidget-refresh", IsBackground = true };
        worker.Start();
    }

    /// <summary>Runs the host until the user quits. Returns the process exit code.</summary>
    public static int Run(string[] arguments)
    {
        using var single = new Mutex(true, @"Local\ScriptWidget.Host", out var first);
        if (!first)
        {
            // Another instance owns the desktop: ask it to show the management window instead.
            if (!arguments.Contains("--startup")) HostPipe.Send(new JsonObject { ["command"] = "show-studio" });
            return 0;
        }
        var paths = new DataPaths();
        Log.File = paths.Log;
        Log.Write($"host started, version {typeof(AppHost).Assembly.GetName().Version}, packaged {Startup.IsPackaged}");
        using var host = new AppHost(paths);
        host.Start(arguments);
        Win32.MSG message;
        while (Win32.GetMessageW(&message, 0, 0, 0) > 0)
        {
            Win32.TranslateMessage(&message);
            Win32.DispatchMessageW(&message);
        }
        Log.Write("host stopped");
        return 0;
    }

    private void Start(string[] arguments)
    {
        foreach (var placement in placements.All()) AddController(placement);
        _ = Task.Run(() => HostPipe.ServeAsync(HandleRequest, stopping.Token));
        // Loading the runtime reads a few megabytes of script; do it off the UI thread.
        work.Add(() => _ = runtime.Value);
        foreach (var controller in widgets.Values) QueueRefresh(controller);
        if (!settings.Welcomed)
        {
            settings.Welcomed = true;
            work.Add(FirstRun);
            if (!arguments.Contains("--startup")) Studio.Open();
        }
        ArmTimer();
    }

    /// <summary>Puts a first widget on the desktop so a new user sees what the app does.</summary>
    private void FirstRun()
    {
        try
        {
            if (library.List().Count > 0 || placements.All().Count > 0) return;
            var bundled = library.Bundled();
            var starter = bundled.FirstOrDefault(item => item.Name == "Datetime Current") ?? bundled.FirstOrDefault();
            if (starter is null) return;
            var installed = library.InstallBundled(starter);
            if (placements.Add(installed.Installation, "medium") is { } placement) ui.Post(() => { var controller = AddController(placement); QueueRefresh(controller); });
        }
        catch (Exception error) { Log.Write($"first run: {error.Message}"); }
    }

    // MARK: - Widgets

    private WidgetController AddController(WidgetPlacement placement)
    {
        var window = new WidgetWindow { Locked = settings.Locked };
        var controller = new WidgetController(placement, window);
        widgets[placement.ID] = controller;
        window.Clicked += (x, y) => OnClick(controller, x, y);
        window.Moved += () => OnMoved(controller);
        window.MenuRequested += (x, y) => PopupMenu.Show(window.Handle, x, y, WidgetMenu(controller));
        window.ScaleChanged += () => QueueRefresh(controller, redrawOnly: true);
        window.IsInteractive = (x, y) => HitTest(controller, x, y) is not null;
        Position(controller);
        layer.Add(window);
        return controller;
    }

    private void RemoveController(string id)
    {
        if (!widgets.Remove(id, out var controller)) return;
        layer.Remove(controller.Window);
        controller.Window.Dispose();
        placements.Remove(id);
    }

    /// <summary>Moves the window to its saved place, or to a free spot on the primary display for a new widget.</summary>
    private void Position(WidgetController controller)
    {
        var placement = controller.Placement;
        var monitors = Monitors.All();
        var (pointWidth, pointHeight) = WidgetFamilies.Size(placement.Family);
        if (placement.Monitor.Length == 0)
        {
            // A new widget: cascade from the top-right corner of the primary work area.
            var primary = monitors.FirstOrDefault(item => item.Primary) ?? Monitors.Primary();
            var margin = (int)Math.Round(24 * primary.Scale);
            var step = (int)Math.Round(28 * primary.Scale) * (widgets.Count - 1);
            var width = (int)Math.Round(pointWidth * primary.Scale);
            placement.Monitor = primary.Device;
            placement.Scale = primary.Scale;
            placement.OffsetX = primary.Work.Right - primary.Bounds.Left - width - margin - step;
            placement.OffsetY = primary.Work.Top - primary.Bounds.Top + margin + step;
            placements.Update(placement);
        }
        // A display that was unplugged keeps its name in the placement, so the widget returns when it is back.
        var monitor = monitors.FirstOrDefault(item => item.Device == placement.Monitor) ?? monitors.FirstOrDefault(item => item.Primary) ?? Monitors.Primary();
        var ratio = monitor.Scale / (placement.Scale <= 0 ? 1 : placement.Scale);
        var x = monitor.Bounds.Left + (int)Math.Round(placement.OffsetX * ratio);
        var y = monitor.Bounds.Top + (int)Math.Round(placement.OffsetY * ratio);
        var pixelWidth = (int)Math.Round(pointWidth * monitor.Scale);
        var pixelHeight = (int)Math.Round(pointHeight * monitor.Scale);
        // Keep at least a grabbable part of the widget on the display.
        var keep = (int)Math.Round(48 * monitor.Scale);
        x = Math.Clamp(x, monitor.Bounds.Left - pixelWidth + keep, monitor.Bounds.Right - keep);
        y = Math.Clamp(y, monitor.Bounds.Top, monitor.Bounds.Bottom - keep);
        controller.Window.MoveTo(x, y);
        _ = pixelHeight;
    }

    private void OnMoved(WidgetController controller)
    {
        var window = controller.Window;
        var monitor = Monitors.Containing(window.X + window.Width / 2, window.Y + window.Height / 2);
        var placement = controller.Placement;
        placement.Monitor = monitor.Device;
        placement.Scale = monitor.Scale;
        placement.OffsetX = window.X - monitor.Bounds.Left;
        placement.OffsetY = window.Y - monitor.Bounds.Top;
        placements.Update(placement);
        if (Math.Abs(monitor.Scale - controller.RenderedScale) > 0.01) QueueRefresh(controller, redrawOnly: true);
    }

    // MARK: - Refresh

    /// <summary>Queues a run of the widget's script (or only a redraw of its last tree). Call on the UI thread.</summary>
    private void QueueRefresh(WidgetController controller, WidgetAction? action = null, bool redrawOnly = false)
    {
        if (controller.Busy)
        {
            if (action is not null) controller.PendingAction = action;
            if (!redrawOnly || action is not null) controller.RunAgain = true;
            return;
        }
        controller.Busy = true;
        var placement = controller.Placement;
        var family = placement.Family;
        var parameter = placement.Parameter;
        var package = placement.Package;
        var scale = controller.Window.Scale;
        var dark = DeviceInfo.IsDarkMode();
        var previousRequest = redrawOnly ? controller.LastRequest : null;
        var previousResult = redrawOnly ? controller.LastResult : null;
        work.Add(() =>
        {
            RenderOutput? output = null;
            RunRequest? request = previousRequest;
            RunResult? result = previousResult;
            try
            {
                var (width, height) = WidgetFamilies.Size(family);
                var engine = runtime.Value;
                if (request is null || result is null || request.Family != family || request.DarkMode != dark)
                {
                    var installed = library.FindByInstallation(package);
                    if (installed is null)
                    {
                        request = null;
                        result = null;
                        output = engine.RenderTree(WidgetRuntime.NoticeTree(Strings.MissingTitle, Strings.MissingDetail), family, (float)width, (float)height, (float)scale, dark);
                    }
                    else
                    {
                        if (action is not null) Perform(engine, installed, family, parameter, dark, action);
                        request = new RunRequest { Files = installed.Files, PackageID = installed.Installation, Family = family, Parameter = parameter, DarkMode = dark, BuildDirectory = installed.BuildDirectory };
                        result = engine.Run(request);
                        if (result.Execution.Error is { } error) Log.Write($"widget {installed.Name}: {error.Kind}");
                    }
                }
                if (output is null && request is not null && result is not null) output = engine.Render(request, result, (float)width, (float)height, (float)scale);
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            {
                Log.Write($"refresh failed: {error.GetType().Name}: {error.Message}");
            }
            var finishedRequest = request;
            var finishedResult = result;
            ui.Post(() => Apply(controller, output, finishedRequest, finishedResult, scale));
        });
    }

    /// <summary>Shows a finished render and schedules the next one. Runs on the UI thread.</summary>
    private void Apply(WidgetController controller, RenderOutput? output, RunRequest? request, RunResult? result, double scale)
    {
        controller.Busy = false;
        if (!widgets.ContainsKey(controller.Placement.ID)) return;
        if (output is not null)
        {
            controller.Window.SetBitmap(output.Pixels, output.PixelWidth, output.PixelHeight);
            controller.HitRegions = output.HitRegions;
            controller.RenderedScale = output.Scale;
            if (!controller.Placed) { controller.Placed = true; layer.Reassert(); }
        }
        controller.LastRequest = request;
        controller.LastResult = result;
        var now = Environment.TickCount64;
        var next = now + settings.RefreshMinutes * 60_000L;
        if (result?.NextTimelineTransition is { } transition)
        {
            var wait = transition - DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            next = Math.Min(next, now + Math.Max(wait, 1000));
        }
        controller.NextRun = next;
        controller.NextRedraw = NextRedraw(result?.Execution.Tree, now);
        if (controller.RunAgain || controller.PendingAction is not null)
        {
            var action = controller.PendingAction;
            controller.RunAgain = false;
            controller.PendingAction = null;
            QueueRefresh(controller, action);
        }
        ArmTimer();
    }

    /// <summary>
    /// When a tree with dates must be drawn again: a running timer every
    /// second, a clock time at the next minute, anything else when the script
    /// runs again.
    /// </summary>
    private static long NextRedraw(string? tree, long now)
    {
        if (tree is null || !tree.Contains("\"date\"", StringComparison.Ordinal)) return long.MaxValue;
        var interval = long.MaxValue;
        void Visit(JsonNode? node)
        {
            switch (node)
            {
                case JsonObject item:
                    if (item.OptString("$element") == "date")
                    {
                        var style = item.OptObject("props").OptString("style", "date");
                        if (style is "timer" or "relative" or "offset") interval = Math.Min(interval, 1000);
                        else if (style == "time") interval = Math.Min(interval, 60_000);
                    }
                    Visit(item.OptArray("children"));
                    break;
                case JsonArray array:
                    foreach (var child in array) Visit(child);
                    break;
            }
        }
        try { Visit(Json.Parse(tree)); } catch (JsonException) { return long.MaxValue; }
        if (interval == long.MaxValue) return long.MaxValue;
        if (interval == 1000) return now + 1000;
        // Align to the start of the next minute, when the displayed time changes.
        var clock = DateTimeOffset.UtcNow;
        return now + (60_000 - (clock.Second * 1000 + clock.Millisecond)) + 50;
    }

    /// <summary>Runs the tapped action before the widget is redrawn. Runs on the refresh thread.</summary>
    private static void Perform(WidgetRuntime engine, InstalledPackage installed, string family, string parameter, bool dark, WidgetAction action)
    {
        // A manifest that is present but unreadable fails closed: nothing is stored and nothing runs.
        if (installed.ManifestPresent && installed.Manifest is null) return;
        var environments = new Dictionary<string, string> { ["action-source"] = ActionPlanner.SourceWidget };
        if (action.Type == "toggle" && action.Value is { } value)
        {
            // The toggle's new state is saved first, then offered to the action as action-value.
            if (SurfaceManifest.IsValidStateKey(action.StateKey) && installed.Permissions.Contains("storage"))
                engine.Storage.SetString(installed.Installation, action.StateKey!, value ? "true" : "false");
            environments["action-value"] = value ? "true" : "false";
            environments["control-value"] = environments["action-value"];
        }
        if (!string.IsNullOrEmpty(action.ActionID))
        {
            // Only an action the manifest declares can be selected by a click.
            PackageSurfaces surfaces;
            try { surfaces = SurfaceManifest.Parse(installed.Manifest); } catch (SurfaceManifestException) { return; }
            if (surfaces.Action(action.ActionID) is not { } declared) return;
            environments["action-id"] = declared.ID;
            engine.Run(new RunRequest { Files = installed.Files, PackageID = installed.Installation, Family = family, Parameter = parameter, DarkMode = dark, ActionID = declared.ID, ExtraEnvironments = environments, BuildDirectory = installed.BuildDirectory });
        }
        else if (SurfaceManifest.IsValidFunction(action.Function))
        {
            engine.Run(new RunRequest { Files = installed.Files, PackageID = installed.Installation, Family = family, Parameter = parameter, DarkMode = dark, CallFunction = action.Function, ExtraEnvironments = environments, BuildDirectory = installed.BuildDirectory });
        }
    }

    private void RefreshAll()
    {
        foreach (var controller in widgets.Values) QueueRefresh(controller);
    }

    private void RefreshPackage(string installation)
    {
        foreach (var controller in widgets.Values.Where(item => item.Placement.Package == installation)) QueueRefresh(controller);
    }

    // MARK: - Schedule

    private void ArmTimer()
    {
        if (Handle == 0) return;
        var earliest = long.MaxValue;
        foreach (var controller in widgets.Values) earliest = Math.Min(earliest, Math.Min(controller.NextRun, controller.NextRedraw));
        if (earliest == long.MaxValue || sessionLocked) { Win32.KillTimer(Handle, ScheduleTimer); return; }
        var delay = Math.Clamp(earliest - Environment.TickCount64, 50, 60_000);
        Win32.SetTimer(Handle, ScheduleTimer, (uint)delay, 0);
    }

    private void OnTimer()
    {
        if (sessionLocked) return;
        var now = Environment.TickCount64;
        // A full-screen program or game is in front: leave the processor to it.
        if (settings.PauseWhenBusy && IsUserBusy())
        {
            Win32.SetTimer(Handle, ScheduleTimer, 30_000, 0);
            return;
        }
        foreach (var controller in widgets.Values.ToList())
        {
            if (now >= controller.NextRun) { controller.NextRun = long.MaxValue; controller.NextRedraw = long.MaxValue; QueueRefresh(controller); }
            else if (now >= controller.NextRedraw) { controller.NextRedraw = long.MaxValue; QueueRefresh(controller, redrawOnly: true); }
        }
        ArmTimer();
    }

    private static bool IsUserBusy()
    {
        int state;
        if (Win32.SHQueryUserNotificationState(&state) != 0) return false;
        return state is 2 /* QUNS_BUSY */ or 3 /* QUNS_RUNNING_D3D_FULL_SCREEN */ or 4 /* QUNS_PRESENTATION_MODE */;
    }

    // MARK: - Clicks and menus

    private static HitRegion? HitTest(WidgetController controller, int pixelX, int pixelY)
    {
        var scale = controller.RenderedScale <= 0 ? 1 : controller.RenderedScale;
        var x = (float)(pixelX / scale);
        var y = (float)(pixelY / scale);
        // The last region drawn is on top.
        for (var index = controller.HitRegions.Count - 1; index >= 0; index--)
        {
            var bounds = controller.HitRegions[index].Bounds;
            if (x >= bounds.Left && x < bounds.Right && y >= bounds.Top && y < bounds.Bottom) return controller.HitRegions[index];
        }
        return null;
    }

    private void OnClick(WidgetController controller, int pixelX, int pixelY)
    {
        if (HitTest(controller, pixelX, pixelY) is not { } region) return;
        var interaction = region.Interaction;
        string? Text(string name) => interaction.IsNull(name) ? null : interaction.OptString(name) is { Length: > 0 } value ? value : null;
        switch (interaction.OptString("type"))
        {
            case "link":
                Links.Open(Text("url"), _ => Studio.Open());
                break;
            case "button" when "reload".Equals(Text("action"), StringComparison.OrdinalIgnoreCase):
                QueueRefresh(controller);
                break;
            case "button":
                QueueRefresh(controller, new WidgetAction("button", Text("actionID"), Text("handler"), null, null));
                break;
            case "toggle":
                QueueRefresh(controller, new WidgetAction("toggle", Text("actionID"), Text("handler"), Text("stateKey"), !interaction.OptBoolean("on")));
                break;
        }
    }

    private IReadOnlyList<MenuItem> WidgetMenu(WidgetController controller)
    {
        var placement = controller.Placement;
        var installed = library.FindByInstallation(placement.Package);
        var families = installed?.Families ?? WidgetFamilies.All;
        var sizes = families.Select(family => new MenuItem(Strings.Family(family), () => SetFamily(controller, family), Checked: family == placement.Family)).ToList();
        return
        [
            new MenuItem(Strings.Refresh, () => QueueRefresh(controller)),
            new MenuItem(Strings.Size, Children: sizes),
            new MenuItem(Strings.Edit, () => Studio.Open(installed?.Name), Enabled: installed is not null),
            MenuItem.Separator,
            new MenuItem(Strings.LockPositions, ToggleLocked, Checked: settings.Locked),
            MenuItem.Separator,
            new MenuItem(Strings.Remove, () => RemoveController(placement.ID)),
        ];
    }

    private IReadOnlyList<MenuItem> TrayMenu()
    {
        var packages = library.List();
        var add = packages.Take(24).Select(item => new MenuItem(item.DisplayName, () => AddWidget(item.Installation, item.Families.Contains("medium") ? "medium" : item.Families[0], ""))).ToList();
        if (packages.Count == 0) add.Add(new MenuItem(Strings.NoPackages, Enabled: false));
        if (packages.Count > 24) add.Add(new MenuItem(Strings.MorePackages, () => Studio.Open()));
        return
        [
            new MenuItem(Strings.OpenStudio, () => Studio.Open()),
            new MenuItem(Strings.AddWidget, Children: add),
            MenuItem.Separator,
            new MenuItem(Strings.RefreshAll, RefreshAll),
            new MenuItem(Strings.LockPositions, ToggleLocked, Checked: settings.Locked),
            new MenuItem(Strings.StartAtLogin, () => Startup.SetEnabled(!Startup.IsEnabled()), Checked: Startup.IsEnabled()),
            MenuItem.Separator,
            new MenuItem(Strings.Quit, Quit),
        ];
    }

    private void ToggleLocked()
    {
        settings.Locked = !settings.Locked;
        foreach (var controller in widgets.Values) controller.Window.Locked = settings.Locked;
    }

    private void SetFamily(WidgetController controller, string family)
    {
        if (!WidgetFamilies.IsKnown(family) || controller.Placement.Family == family) return;
        controller.Placement.Family = family;
        placements.Update(controller.Placement);
        controller.LastRequest = null;
        controller.LastResult = null;
        QueueRefresh(controller);
    }

    private string? AddWidget(string installation, string family, string parameter)
    {
        if (placements.Add(installation, family, parameter) is not { } placement) return null;
        var controller = AddController(placement);
        QueueRefresh(controller);
        return placement.ID;
    }

    private void Quit()
    {
        if (quitting) return;
        quitting = true;
        stopping.Cancel();
        Win32.PostQuitMessage(0);
    }

    // MARK: - System messages

    protected override nint? OnMessage(uint message, nuint wParam, nint lParam)
    {
        switch (message)
        {
            case Win32.WM_TIMER when wParam == ScheduleTimer:
                OnTimer();
                return 0;
            case Win32.WM_DISPLAYCHANGE:
                // Displays were added, removed or rescaled: put every widget back where it belongs.
                foreach (var controller in widgets.Values) { Position(controller); QueueRefresh(controller, redrawOnly: true); }
                layer.Reassert();
                return null;
            case Win32.WM_SETTINGCHANGE:
                // The light/dark theme or the regional format changed.
                if (lParam != 0 && Marshal.PtrToStringUni(lParam) is "ImmersiveColorSet" or "intl") RefreshAll();
                return null;
            case Win32.WM_TIMECHANGE:
                RefreshAll();
                return null;
            case Win32.WM_POWERBROADCAST when (int)wParam == Win32.PBT_APMRESUMEAUTOMATIC:
                // Timers do not run while the machine sleeps: everything may be stale.
                RefreshAll();
                return 1;
            case WM_WTSSESSION_CHANGE:
                if ((int)wParam == WTS_SESSION_LOCK) { sessionLocked = true; ArmTimer(); }
                else if ((int)wParam == WTS_SESSION_UNLOCK) { sessionLocked = false; RefreshAll(); ArmTimer(); layer.Reassert(); }
                return 0;
            case Win32.WM_ENDSESSION when wParam != 0:
                Quit();
                return 0;
        }
        return null;
    }

    // MARK: - Requests from the management window

    /// <summary>Handles one pipe request. Runs on a thread-pool thread; work that touches windows hops to the UI thread.</summary>
    private JsonObject HandleRequest(JsonObject request)
    {
        var command = request.OptString("command");
        if (command == "ping") return new JsonObject { ["ok"] = true, ["version"] = typeof(AppHost).Assembly.GetName().Version?.ToString() };
        var completion = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
        ui.Post(() =>
        {
            try { completion.SetResult(HandleOnUiThread(command, request)); }
            catch (Exception error) { completion.SetResult(Failure(error.Message)); }
        });
        return completion.Task.Wait(10_000) ? completion.Task.Result : Failure("The host did not answer in time");
    }

    private static JsonObject Failure(string message) => new() { ["ok"] = false, ["error"] = message };

    private JsonObject HandleOnUiThread(string command, JsonObject request)
    {
        switch (command)
        {
            case "list":
            {
                var items = new JsonArray();
                foreach (var controller in widgets.Values) items.Append(controller.Placement.ToJson());
                return new JsonObject { ["ok"] = true, ["widgets"] = items };
            }
            case "add":
            {
                var installation = request.OptString("package");
                if (library.FindByInstallation(installation) is null) return Failure("Package not found");
                var family = request.OptString("family", "medium");
                var id = AddWidget(installation, WidgetFamilies.IsKnown(family) ? family : "medium", request.OptString("parameter"));
                return id is null ? Failure(Strings.TooManyWidgets) : new JsonObject { ["ok"] = true, ["id"] = id };
            }
            case "remove":
                RemoveController(request.OptString("id"));
                return new JsonObject { ["ok"] = true };
            case "update":
            {
                if (!widgets.TryGetValue(request.OptString("id"), out var controller)) return Failure("Widget not found");
                if (request.Has("parameter"))
                {
                    var parameter = request.OptString("parameter");
                    controller.Placement.Parameter = parameter.Length > 2048 ? parameter[..2048] : parameter;
                    placements.Update(controller.Placement);
                    controller.LastRequest = null;
                    QueueRefresh(controller);
                }
                if (request.Has("family")) SetFamily(controller, request.OptString("family"));
                return new JsonObject { ["ok"] = true };
            }
            case "refresh":
                if (request.OptString("package") is { Length: > 0 } package) RefreshPackage(package); else RefreshAll();
                return new JsonObject { ["ok"] = true };
            case "library-changed":
            {
                // Packages were edited, renamed or deleted in the management window.
                foreach (var controller in widgets.Values) { controller.LastRequest = null; controller.LastResult = null; }
                RefreshAll();
                return new JsonObject { ["ok"] = true };
            }
            case "settings-changed":
                settings.Reload();
                foreach (var controller in widgets.Values) controller.Window.Locked = settings.Locked;
                ArmTimer();
                return new JsonObject { ["ok"] = true };
            case "show-studio":
                Studio.Open();
                return new JsonObject { ["ok"] = true };
            case "quit":
                Quit();
                return new JsonObject { ["ok"] = true };
            default:
                return Failure($"Unknown command {command}");
        }
    }

    public override void Dispose()
    {
        stopping.Cancel();
        work.CompleteAdding();
        if (Handle != 0) WTSUnRegisterSessionNotification(Handle);
        foreach (var controller in widgets.Values) controller.Window.Dispose();
        widgets.Clear();
        tray.Dispose();
        layer.Dispose();
        ui.Dispose();
        if (runtime.IsValueCreated) runtime.Value.Dispose();
        base.Dispose();
    }
}
