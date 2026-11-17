# Checks the desktop host on a real Windows desktop without needing to look at
# the screen: it also works while the session is locked.
#
#   powershell -File Windows/scripts/desktop-check.ps1 [-HostPath <ScriptWidget.exe>] [-Output <folder>]
#
# It starts the host with a scratch data folder, then checks that
#   - the first start places a widget and its window shows a picture,
#   - widget windows sit directly above the desktop and below every other window,
#   - a drag moves the widget, snaps it to the screen edge and saves the place,
#   - a button click runs the declared action,
#   - display, clock, sleep, lock and theme events redraw the widgets,
#   - "show desktop" raises the widgets and puts them back, using a stand-in
#     for the desktop window.
# Pictures of the widget windows are saved in the output folder.
#
# Pointer input is posted to the windows as messages; it is not a real mouse.
# What this cannot check is listed in docs/windows/TODO.md (the real Win+D,
# the tray menu, how the widgets look against the wallpaper).
param(
    [string] $HostPath,
    [string] $Output = (Join-Path $env:TEMP 'scriptwidget-desktop-check')
)
$ErrorActionPreference = 'Stop'
$windows = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $HostPath) { $HostPath = Get-ChildItem (Join-Path $windows 'src\ScriptWidget.App\bin') -Recurse -Filter ScriptWidget.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
if (-not $HostPath -or -not (Test-Path $HostPath)) { throw 'ScriptWidget.exe was not found. Build src/ScriptWidget.App or pass -HostPath.' }
$cli = Get-ChildItem (Join-Path $windows 'src\ScriptWidget.Cli\bin') -Recurse -Filter swcli.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $cli) { throw 'swcli.exe was not found. Build src/ScriptWidget.Cli.' }
if (Get-Process ScriptWidget -ErrorAction SilentlyContinue) { throw 'ScriptWidget is already running. Quit it first: this check uses its own data folder.' }

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text; using System.Collections.Generic; using System.Drawing; using System.Drawing.Imaging;
public static class SwCheck {
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern IntPtr GetTopWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr SendMessageTimeout(IntPtr h, uint m, IntPtr w, string l, uint flags, uint timeout, out IntPtr result);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr c);
  public struct RECT { public int L, T, R, B; }
  public static string Class(IntPtr h) { var s = new StringBuilder(128); GetClassName(h, s, 128); return s.ToString(); }
  public static List<IntPtr> Find(string cls) { var r = new List<IntPtr>(); EnumWindows((h, l) => { if (Class(h) == cls) r.Add(h); return true; }, IntPtr.Zero); return r; }
  // Classes of the visible top-level windows, front to back.
  public static List<string> VisibleOrder() { var r = new List<string>(); var h = GetTopWindow(IntPtr.Zero); while (h != IntPtr.Zero) { if (IsWindowVisible(h)) r.Add(Class(h)); h = GetWindow(h, 2); } return r; }
  // Saves what the window itself shows and returns the share of pixels that are not transparent or black.
  public static double Capture(IntPtr h, string file) {
    RECT r; GetWindowRect(h, out r); int w = r.R - r.L, ht = r.B - r.T; if (w <= 0 || ht <= 0) return 0;
    using (var bmp = new Bitmap(w, ht, PixelFormat.Format32bppArgb)) {
      using (var g = Graphics.FromImage(bmp)) { var dc = g.GetHdc(); PrintWindow(h, dc, 2); g.ReleaseHdc(dc); }
      bmp.Save(file, ImageFormat.Png);
      int drawn = 0, total = 0; for (int y = 0; y < ht; y += 4) for (int x = 0; x < w; x += 4) { total++; var c = bmp.GetPixel(x, y); if (c.R + c.G + c.B > 24) drawn++; }
      return total == 0 ? 0 : (double)drawn / total; } }
}
"@ -ReferencedAssemblies System.Drawing
[SwCheck]::SetThreadDpiAwarenessContext([IntPtr](-4)) | Out-Null

$data = Join-Path $Output 'data'
if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
New-Item -ItemType Directory -Force $Output | Out-Null
$env:SCRIPTWIDGET_DATA = $data
$env:SCRIPTWIDGET_VERBOSE = '1'
$script:failures = 0
function Check([string] $what, [bool] $ok, [string] $detail = '') {
    if ($ok) { Write-Host "PASS  $what $detail" } else { Write-Host "FAIL  $what $detail"; $script:failures++ }
}
function LParam([int] $x, [int] $y) { [IntPtr]((($y -band 0xFFFF) -shl 16) -bor ($x -band 0xFFFF)) }
function Rect($h) { $r = New-Object SwCheck+RECT; [SwCheck]::GetWindowRect($h, [ref] $r) | Out-Null; $r }
function LogLines { if (Test-Path "$data\host.log") { Get-Content "$data\host.log" } else { @() } }
function Wait-Log([string] $pattern, [int] $from, [int] $seconds = 8) {
    for ($i = 0; $i -lt $seconds * 4; $i++) { if ((LogLines | Select-Object -Skip $from) -match $pattern) { return $true }; Start-Sleep -Milliseconds 250 }
    return $false
}

# "Show desktop", acted out with a stand-in for the desktop window (the real one is not touched).
$showDesktopLog = Join-Path $Output 'showdesktop.log'
$selfTest = Start-Process $HostPath -ArgumentList '--selftest-showdesktop', "`"$showDesktopLog`"" -PassThru -Wait
if (Test-Path $showDesktopLog) { Get-Content $showDesktopLog | Where-Object { $_ -match '^(PASS|FAIL)' } | ForEach-Object { Write-Host ($_ -replace '^(PASS|FAIL)  ', '$1  show desktop stand-in: ') } }
Check 'show desktop is handled (stand-in desktop window)' ($selfTest.ExitCode -eq 0)

$process = Start-Process $HostPath -ArgumentList '--startup' -PassThru
try {
    # First start
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and -not ((LogLines) -match 'drawn ')) { Start-Sleep -Milliseconds 500 }
    $widgets = [SwCheck]::Find('ScriptWidgetWidget')
    Check 'first start places one widget' ($widgets.Count -eq 1) "($($widgets.Count) widget windows)"
    Check 'the host is still running' (-not $process.HasExited)

    # A second widget with a button
    $template = Join-Path $windows '..\Shared\ScriptWidgetRuntime\Resource\Script.bundle\template\Habit Heatmap'
    & $cli pack $template (Join-Path $Output 'habit.swt') | Out-Null
    & $cli install (Join-Path $Output 'habit.swt') | Out-Null
    $before = (LogLines).Count
    & $cli add 'Habit Heatmap' --family medium | Out-Null
    Check 'a second widget is added and drawn' (Wait-Log 'drawn ' $before)
    # The second window exists before its first picture is drawn; wait until both are shown.
    for ($i = 0; $i -lt 40; $i++) {
        $widgets = [SwCheck]::Find('ScriptWidgetWidget')
        $shown = @($widgets | Where-Object { $r = Rect $_; [SwCheck]::IsWindowVisible($_) -and ($r.R - $r.L) -gt 0 })
        if ($shown.Count -eq 2) { break }
        Start-Sleep -Milliseconds 250
    }
    Check 'two widget windows exist' ($widgets.Count -eq 2)

    # Pictures of what the windows show
    $index = 0
    foreach ($h in $widgets) {
        $index++
        $share = [SwCheck]::Capture($h, (Join-Path $Output "widget$index.png"))
        $r = Rect $h
        Check "widget $index shows a picture" ($share -gt 0.2) ("({0}x{1} pixels, {2:P0} drawn)" -f ($r.R - $r.L), ($r.B - $r.T), $share)
    }

    # Window order: widgets directly above the desktop, below everything else
    $order = [SwCheck]::VisibleOrder()
    $desktop = [Array]::LastIndexOf([string[]] $order, 'Progman')
    $positions = 0..($order.Count - 1) | Where-Object { $order[$_] -eq 'ScriptWidgetWidget' }
    Check 'the desktop window is the last visible window' ($desktop -eq $order.Count - 1)
    Check 'the widgets are directly above the desktop window' (($positions | Measure-Object -Maximum).Maximum -eq $desktop - 1 -and ($positions | Measure-Object -Minimum).Minimum -eq $desktop - $widgets.Count)

    # Drag: 240 pixels left and up to 3 pixels below the top of its display
    $h = $widgets | Where-Object { (Rect $_).T -gt 20 } | Select-Object -First 1
    if (-not $h) { $h = $widgets[0] }
    $start = Rect $h
    [SwCheck]::PostMessage($h, 0x201, [IntPtr]1, (LParam 200 100)) | Out-Null
    [SwCheck]::PostMessage($h, 0x200, [IntPtr]1, (LParam (200 - 240) (100 - $start.T + 3))) | Out-Null
    Start-Sleep -Milliseconds 300
    [SwCheck]::PostMessage($h, 0x202, [IntPtr]0, (LParam 200 100)) | Out-Null
    Start-Sleep -Seconds 1
    $moved = Rect $h
    Check 'a drag moves the widget' ($moved.L -eq $start.L - 240) "($($start.L),$($start.T) -> $($moved.L),$($moved.T))"
    Check 'the widget snaps to the top edge' ($moved.T -eq 0)
    $saved = (Get-Content "$data\widgets.json" -Raw | ConvertFrom-Json).widgets
    Check 'the new place is saved' ([bool]($saved | Where-Object { $_.y -eq 0 }))

    # Click the "Check in" button of the Habit Heatmap widget (12..80 x 133..147 points)
    $scale = ((Rect $widgets[0]).R - (Rect $widgets[0]).L) / 329.0
    $before = (LogLines).Count
    foreach ($w in $widgets) {
        $point = LParam ([int](40 * $scale)) ([int](140 * $scale))
        [SwCheck]::PostMessage($w, 0x201, [IntPtr]1, $point) | Out-Null
        [SwCheck]::PostMessage($w, 0x202, [IntPtr]0, $point) | Out-Null
    }
    Check 'a click on a button runs the declared action' (Wait-Log 'action Habit Heatmap: ok' $before)
    $storage = Get-ChildItem "$data\Storage" -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw }
    Check 'the action wrote to the package storage' ("$storage" -match 'habitHeatmap')

    # System events
    $hostWindow = [SwCheck]::Find('ScriptWidgetHost') | Select-Object -First 1
    $events = @(
        @('display change', 0x7E, 32, 'display change'),
        @('clock change', 0x1E, 0, 'time change'),
        @('resume from sleep', 0x218, 0x12, 'resume from sleep'),
        @('session lock', 0x2B1, 7, 'session locked'),
        @('session unlock', 0x2B1, 8, 'session unlocked')
    )
    foreach ($event in $events) {
        $before = (LogLines).Count
        [SwCheck]::PostMessage($hostWindow, $event[1], [IntPtr]$event[2], [IntPtr]0) | Out-Null
        $seen = Wait-Log $event[3] $before 5
        $redrawn = if ($event[0] -eq 'session lock') { $true } else { Wait-Log 'drawn ' $before 8 }
        Check "$($event[0]) is handled" ($seen -and $redrawn)
    }
    $before = (LogLines).Count
    $result = [IntPtr]::Zero
    [SwCheck]::SendMessageTimeout($hostWindow, 0x1A, [IntPtr]0, 'ImmersiveColorSet', 2, 2000, [ref] $result) | Out-Null
    Check 'a theme change redraws the widgets' ((Wait-Log 'theme or format change' $before 5) -and (Wait-Log 'drawn ' $before 8))
    $after = Rect $h
    Check 'the widget keeps its place through the events' ($after.L -eq $moved.L -and $after.T -eq $moved.T)
    Check 'the host is still running at the end' (-not $process.HasExited)
    $errors = LogLines | Where-Object { $_ -match 'failed|crashed|refused' }
    Check 'the log holds no failures' (-not $errors) ($errors | Select-Object -First 2 | Out-String)
}
finally {
    if (-not $process.HasExited) { $process | Stop-Process -Force }
}
Write-Host "pictures and log -> $Output"
if ($script:failures -gt 0) { Write-Host "$($script:failures) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
