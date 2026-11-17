using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ScriptWidget.Core.Hosting;

/// <summary>One widget on the desktop: which package it shows, at what size, and where.</summary>
public sealed class WidgetPlacement
{
    public required string ID { get; init; }
    /// <summary>Identity of the installed package (its folder name).</summary>
    public required string Package { get; set; }
    public string Family { get; set; } = "medium";
    /// <summary>The value of <c>$getenv("widget-param")</c>.</summary>
    public string Parameter { get; set; } = "";
    /// <summary>Device name of the display the widget is on, such as <c>\\.\DISPLAY1</c>.</summary>
    public string Monitor { get; set; } = "";
    /// <summary>Offset from the display's top-left corner, in pixels at <see cref="Scale"/>.</summary>
    public int OffsetX { get; set; }
    public int OffsetY { get; set; }
    /// <summary>Display scale when the offset was saved.</summary>
    public double Scale { get; set; } = 1.0;

    public JsonObject ToJson() => new()
    {
        ["id"] = ID, ["package"] = Package, ["family"] = Family, ["parameter"] = Parameter,
        ["monitor"] = Monitor, ["x"] = OffsetX, ["y"] = OffsetY, ["scale"] = Scale,
    };

    public static WidgetPlacement? FromJson(JsonObject json)
    {
        var id = json.OptString("id");
        var package = json.OptString("package");
        if (id.Length == 0 || id.Length > 64 || package.Length == 0 || package.Length > 255) return null;
        var family = json.OptString("family", "medium");
        var scale = json.OptDouble("scale", 1.0);
        return new WidgetPlacement
        {
            ID = id,
            Package = package,
            Family = WidgetFamilies.IsKnown(family) ? family : "medium",
            Parameter = Clip(json.OptString("parameter"), 2048),
            Monitor = Clip(json.OptString("monitor"), 64),
            OffsetX = Math.Clamp(json.OptInt("x"), -100_000, 100_000),
            OffsetY = Math.Clamp(json.OptInt("y"), -100_000, 100_000),
            Scale = scale is >= 0.5 and <= 8 ? scale : 1.0,
        };
    }

    private static string Clip(string text, int length) => text.Length <= length ? text : text[..length];
}

/// <summary>Widget sizes on Windows, in points. They follow the macOS desktop widget sizes of the preview engine.</summary>
public static class WidgetFamilies
{
    public static readonly IReadOnlyList<string> All = ["small", "medium", "large", "extraLarge"];

    public static bool IsKnown(string family) => All.Contains(family);

    /// <summary>The size for a <c>supportedFamilies</c> entry of widget.json, or null for one Windows does not have (Lock Screen sizes).</summary>
    public static string? FromManifest(string name) => name switch
    {
        "systemSmall" or "small" => "small",
        "systemMedium" or "medium" => "medium",
        "systemLarge" or "large" => "large",
        "systemExtraLarge" or "extraLarge" => "extraLarge",
        _ => null,
    };

    public static (double Width, double Height) Size(string family) => family switch
    {
        "small" => (170, 170),
        "large" => (329, 345),
        "extraLarge" => (639, 345),
        _ => (329, 170),
    };
}

/// <summary>The saved list of desktop widgets. Safe to use from any thread.</summary>
public sealed class WidgetPlacements(string file)
{
    public const int MaximumWidgets = 64;
    private readonly object gate = new();
    private List<WidgetPlacement>? items;

    public IReadOnlyList<WidgetPlacement> All()
    {
        lock (gate) return Load().ToList();
    }

    public WidgetPlacement? Find(string id)
    {
        lock (gate) return Load().FirstOrDefault(item => item.ID == id);
    }

    /// <summary>Adds a widget. Returns null when the limit is reached.</summary>
    public WidgetPlacement? Add(string package, string family, string parameter = "")
    {
        lock (gate)
        {
            var list = Load();
            if (list.Count >= MaximumWidgets) return null;
            var placement = new WidgetPlacement { ID = Guid.NewGuid().ToString("N"), Package = package, Family = WidgetFamilies.IsKnown(family) ? family : "medium", Parameter = parameter };
            list.Add(placement);
            Save(list);
            return placement;
        }
    }

    public void Remove(string id)
    {
        lock (gate)
        {
            var list = Load();
            if (list.RemoveAll(item => item.ID == id) > 0) Save(list);
        }
    }

    /// <summary>Saves a change made to a placement returned by this store.</summary>
    public void Update(WidgetPlacement placement)
    {
        lock (gate)
        {
            var list = Load();
            var index = list.FindIndex(item => item.ID == placement.ID);
            if (index < 0) return;
            list[index] = placement;
            Save(list);
        }
    }

    private List<WidgetPlacement> Load()
    {
        if (items is not null) return items;
        var loaded = new List<WidgetPlacement>();
        try
        {
            if (File.Exists(file) && Json.Parse(File.ReadAllText(file, Encoding.UTF8)) is JsonObject root && root.OptArray("widgets") is { } array)
            {
                foreach (var node in array)
                {
                    if (loaded.Count >= MaximumWidgets) break;
                    if (node is JsonObject item && WidgetPlacement.FromJson(item) is { } placement && loaded.All(existing => existing.ID != placement.ID)) loaded.Add(placement);
                }
            }
        }
        catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { }
        return items = loaded;
    }

    private void Save(List<WidgetPlacement> list)
    {
        var array = new JsonArray();
        foreach (var item in list) array.Append(item.ToJson());
        var text = Json.Stringify(new JsonObject { ["version"] = 1, ["widgets"] = array }, indented: true);
        var temporary = file + ".tmp";
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(file)!);
            File.WriteAllText(temporary, text, new UTF8Encoding(false));
            File.Move(temporary, file, overwrite: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }
    }
}

/// <summary>User settings of the desktop host.</summary>
public sealed class HostSettings(string file)
{
    private readonly object gate = new();
    private JsonObject? values;

    /// <summary>How often widgets without a schedule of their own are refreshed.</summary>
    public int RefreshMinutes
    {
        get => Math.Clamp(Read().OptInt("refreshMinutes", 15), 5, 24 * 60);
        set => Write("refreshMinutes", Math.Clamp(value, 5, 24 * 60));
    }

    /// <summary>When true, widgets cannot be dragged.</summary>
    public bool Locked
    {
        get => Read().OptBoolean("locked");
        set => Write("locked", value);
    }

    /// <summary>Hold refreshes while a full-screen program or game is in front.</summary>
    public bool PauseWhenBusy
    {
        get => Read().OptBoolean("pauseWhenBusy", true);
        set => Write("pauseWhenBusy", value);
    }

    /// <summary>Set after the first-run welcome was shown.</summary>
    public bool Welcomed
    {
        get => Read().OptBoolean("welcomed");
        set => Write("welcomed", value);
    }

    private JsonObject Read()
    {
        lock (gate)
        {
            if (values is not null) return values;
            try { values = File.Exists(file) ? Json.Parse(File.ReadAllText(file, Encoding.UTF8)) as JsonObject : null; }
            catch (Exception error) when (error is JsonException or IOException or UnauthorizedAccessException) { values = null; }
            return values ??= new JsonObject();
        }
    }

    private void Write(string name, JsonNode value)
    {
        lock (gate)
        {
            var current = Read();
            current[name] = value;
            var temporary = file + ".tmp";
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(file)!);
                File.WriteAllText(temporary, Json.Stringify(current, indented: true), new UTF8Encoding(false));
                File.Move(temporary, file, overwrite: true);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }

    /// <summary>Drops the cached values so the next read sees what another process wrote.</summary>
    public void Reload()
    {
        lock (gate) values = null;
    }
}
