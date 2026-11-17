using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json.Nodes;
using ScriptWidget.Core.Runtime;

namespace ScriptWidget.Core.Api;

/// <summary>
/// Snapshots behind <c>$device</c> and <c>$system</c>. Values are captured
/// once per execution, like the native iOS runtime. None of them needs a
/// permission.
/// </summary>
public static unsafe class DeviceInfo
{
    public static JsonObject Device()
    {
        var scale = PrimaryScale();
        var width = GetSystemMetrics(0) / scale;
        var height = GetSystemMetrics(1) / scale;
        var level = -1.0;
        var state = "unknown";
        if (GetSystemPowerStatus(out var power) != 0)
        {
            if (power.BatteryLifePercent <= 100) level = power.BatteryLifePercent / 100.0;
            var noBattery = (power.BatteryFlag & 128) != 0 || power.BatteryFlag == 255;
            state = noBattery ? "full"
                : (power.BatteryFlag & 8) != 0 ? "charging"
                : power.ACLineStatus == 1 ? (power.BatteryLifePercent >= 100 ? "full" : "charging")
                : power.ACLineStatus == 0 ? "unplugged"
                : "unknown";
            if (noBattery) level = 1.0;
        }
        long total = 0, free = 0;
        try
        {
            var drive = new DriveInfo(Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)) ?? "C:\\");
            total = drive.TotalSize;
            free = drive.AvailableFreeSpace;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or ArgumentException) { }
        return new JsonObject
        {
            ["screen"] = new JsonObject { ["width"] = width, ["height"] = height, ["scale"] = scale },
            ["language"] = CultureInfo.CurrentUICulture.TwoLetterISOLanguageName,
            ["model"] = "PC",
            ["name"] = Environment.MachineName,
            ["battery"] = new JsonObject { ["level"] = level, ["state"] = state },
            ["systemVersion"] = Environment.OSVersion.Version.ToString(),
            ["totalDiskSpace"] = total,
            ["freeDiskSpace"] = free,
        };
    }

    public static JsonObject System()
    {
        var culture = CultureInfo.CurrentCulture;
        var zone = TimeZoneInfo.Local;
        var now = DateTimeOffset.Now;
        var memory = new MemoryStatus { Length = (uint)sizeof(MemoryStatus) };
        GlobalMemoryStatusEx(ref memory);
        var saver = GetSystemPowerStatus(out var power) != 0 && power.SystemStatusFlag == 1;
        int animations = 1;
        SystemParametersInfoW(0x1042 /* SPI_GETCLIENTAREAANIMATION */, 0, &animations, 0);
        var languages = new JsonArray();
        foreach (var language in PreferredLanguages()) languages.Append(language);
        var version = typeof(DeviceInfo).Assembly.GetName().Version;
        var build = Environment.OSVersion.Version.Build;
        return new JsonObject
        {
            ["appInfo"] = new JsonObject
            {
                ["name"] = "ScriptWidget",
                ["bundleId"] = "com.atomsprout.scriptwidget",
                ["version"] = version is null ? "" : $"{version.Major}.{version.Minor}.{version.Build}",
                ["build"] = version?.Revision.ToString(CultureInfo.InvariantCulture) ?? "",
            },
            ["locale"] = culture.Name.Replace('-', '_'),
            ["preferredLanguages"] = languages,
            ["timeZone"] = new JsonObject
            {
                ["identifier"] = IntlBridge.DefaultTimeZone(),
                ["abbreviation"] = Abbreviation(zone, now),
                ["offsetSeconds"] = (int)zone.GetUtcOffset(now).TotalSeconds,
            },
            ["is24HourClock"] = culture.DateTimeFormat.ShortTimePattern.Contains('H'),
            ["calendarInfo"] = new JsonObject
            {
                ["identifier"] = culture.Calendar is GregorianCalendar ? "gregorian" : culture.Calendar.GetType().Name.Replace("Calendar", "").ToLowerInvariant(),
                // Like Calendar.firstWeekday on iOS: Sunday is 1.
                ["firstWeekday"] = (int)culture.DateTimeFormat.FirstDayOfWeek + 1,
                ["minimumDaysInFirstWeek"] = culture.DateTimeFormat.CalendarWeekRule switch { CalendarWeekRule.FirstFourDayWeek => 4, CalendarWeekRule.FirstFullWeek => 7, _ => 1 },
            },
            ["systemUptime"] = Environment.TickCount64 / 1000.0,
            ["memory"] = new JsonObject { ["physical"] = (long)memory.TotalPhysical },
            ["thermalState"] = "nominal",
            ["lowPowerMode"] = saver,
            ["brightness"] = 1.0,
            ["reduceMotionEnabled"] = animations == 0,
            ["platform"] = "windows",
            ["hostName"] = Environment.MachineName,
            ["processName"] = "ScriptWidget",
            ["osVersionString"] = $"Windows {(build >= 22000 ? "11" : "10")} (build {build})",
            ["processorCount"] = Environment.ProcessorCount,
            ["activeProcessorCount"] = Environment.ProcessorCount,
        };
    }

    /// <summary>True when Windows is set to the dark app theme.</summary>
    public static bool IsDarkMode()
    {
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or global::System.Security.SecurityException) { return false; }
    }

    private static string Abbreviation(TimeZoneInfo zone, DateTimeOffset now)
    {
        var offset = zone.GetUtcOffset(now);
        var sign = offset < TimeSpan.Zero ? "-" : "+";
        var minutes = Math.Abs(offset.Minutes);
        return "GMT" + sign + Math.Abs(offset.Hours).ToString(CultureInfo.InvariantCulture) + (minutes == 0 ? "" : ":" + minutes.ToString("00", CultureInfo.InvariantCulture));
    }

    private static IEnumerable<string> PreferredLanguages()
    {
        uint count = 0, length = 0;
        if (GetUserPreferredUILanguages(8 /* MUI_LANGUAGE_NAME */, &count, null, &length) != 0 && length > 1)
        {
            var buffer = new char[length];
            fixed (char* chars = buffer)
            {
                if (GetUserPreferredUILanguages(8, &count, chars, &length) != 0)
                {
                    var names = new string(buffer).Split('\0', StringSplitOptions.RemoveEmptyEntries);
                    if (names.Length > 0) return names;
                }
            }
        }
        return [CultureInfo.CurrentUICulture.Name];
    }

    private static double PrimaryScale()
    {
        var dpi = GetDpiForSystem();
        return dpi == 0 ? 1.0 : dpi / 96.0;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PowerStatus
    {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public uint BatteryLifeTime;
        public uint BatteryFullLifeTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length;
        public uint MemoryLoad;
        public ulong TotalPhysical;
        public ulong AvailablePhysical;
        public ulong TotalPageFile;
        public ulong AvailablePageFile;
        public ulong TotalVirtual;
        public ulong AvailableVirtual;
        public ulong AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll")] private static extern int GetSystemPowerStatus(out PowerStatus status);
    [DllImport("kernel32.dll")] private static extern int GlobalMemoryStatusEx(ref MemoryStatus status);
    [DllImport("kernel32.dll")] private static extern int GetUserPreferredUILanguages(uint flags, uint* count, char* buffer, uint* length);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] private static extern int SystemParametersInfoW(uint action, uint parameter, void* value, uint flags);
}
