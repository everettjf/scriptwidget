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
#   - the actions of the tray menu and of a widget's right-click menu work,
#   - "show desktop" raises the widgets and puts them back, using a stand-in
#     for the desktop window.
# Pictures of the widget windows are saved in the output folder.
#
# Pointer input is posted to the windows as messages; it is not a real mouse.
# What this cannot check is listed in docs/windows/TODO.md (the real Win+D,
# the tray menu, how the widgets look against the wallpaper).
param(
    [string] $HostPath,
    [string] $Output = (Join-Path $env:TEMP 'scriptwidget-desktop-check'),
    [ValidateRange(0, 1800)] [int] $AnimationStressSeconds = 0,
    [ValidateRange(1, 12)] [int] $AnimationStressCopies = 1
)
$ErrorActionPreference = 'Stop'
$windows = Resolve-Path (Join-Path $PSScriptRoot '..')
# The newest build that has the runtime assets next to it (an intermediate native AOT output has none).
if (-not $HostPath) { $HostPath = Get-ChildItem (Join-Path $windows 'src\ScriptWidget.App\bin') -Recurse -Filter ScriptWidget.exe | Where-Object { Test-Path (Join-Path $_.DirectoryName 'assets\scriptwidget\kernel.js') } | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
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
New-Item -ItemType Directory -Force $data | Out-Null
# A foreground full-screen app on the development machine must not make animation tests idle.
[IO.File]::WriteAllText((Join-Path $data 'settings.json'), '{"pauseWhenBusy":false,"refreshMinutes":1440}', (New-Object Text.UTF8Encoding $false))
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
function Wait-WidgetCapture([IntPtr[]] $previous, [string] $picture) {
    $until = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $until) {
        foreach ($candidate in [SwCheck]::Find('ScriptWidgetWidget')) {
            if ($previous -notcontains $candidate -and [SwCheck]::Capture($candidate, $picture) -gt 0.05) { return $candidate }
        }
        Start-Sleep -Milliseconds 100
    }
    throw 'The new widget did not produce a nonempty native window capture within 15 seconds.'
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
    # Windows refuses the tray icon when no taskbar is running (a build agent, for example).
    $tray = (LogLines) -match 'tray icon added: True'
    if ($tray) { Check 'the tray icon is added' $true } else { Write-Host 'SKIP  the tray icon was not accepted: no taskbar in this session' }

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
    # Menus: every action of the tray menu and of a widget's right-click menu, run through the
    # host's debugging requests (the popup itself needs a pointer and is not shown).
    function Send-Host($request) {
        $file = Join-Path $Output 'request.json'
        # The request goes through a file name-safe argument: quotes inside JSON do not survive a command line.
        $json = ($request | ConvertTo-Json -Compress -Depth 6) -replace '"', '\"'
        (& $cli host $json | Out-String) | ConvertFrom-Json
    }
    function Widget-List { (& $cli widgets | Out-String | ConvertFrom-Json).widgets }
    $tray = Send-Host @{ command = 'debug-menu'; target = 'tray' }
    Check 'the tray menu has its entries' ($tray.ok -and $tray.items.Count -eq 8 -and $tray.items[1].children.Count -ge 2) "($(($tray.items | Where-Object { $_.text } | ForEach-Object { $_.text }) -join ' | '))"
    $list = Widget-List
    $target = $list | Select-Object -First 1
    $menu = Send-Host @{ command = 'debug-menu'; target = $target.id }
    Check 'a widget menu has its entries' ($menu.ok -and $menu.items.Count -eq 7 -and $menu.items[1].children.Count -ge 1)
    # Size: pick a size that is not the current one and watch the window change.
    $sizes = $menu.items[1].children
    $other = 0..($sizes.Count - 1) | Where-Object { -not $sizes[$_].checked } | Select-Object -First 1
    $countBefore = (LogLines).Count
    $widthsBefore = ([SwCheck]::Find('ScriptWidgetWidget') | ForEach-Object { (Rect $_).R - (Rect $_).L } | Sort-Object) -join ','
    $answer = Send-Host @{ command = 'debug-invoke'; target = $target.id; path = @(1, $other) }
    $drawn = Wait-Log 'drawn ' $countBefore
    Start-Sleep -Milliseconds 500
    $widthsAfter = ([SwCheck]::Find('ScriptWidgetWidget') | ForEach-Object { (Rect $_).R - (Rect $_).L } | Sort-Object) -join ','
    Check 'the size menu changes the widget size' ($answer.ok -and $drawn -and $widthsAfter -ne $widthsBefore) "($widthsBefore -> $widthsAfter pixels wide)"
    # Lock positions: a drag must not move a locked widget.
    $answer = Send-Host @{ command = 'debug-invoke'; target = 'tray'; path = @(4) }
    $locked = (Send-Host @{ command = 'debug-menu'; target = 'tray' }).items[4].checked
    $h2 = [SwCheck]::Find('ScriptWidgetWidget') | Select-Object -First 1
    $place = Rect $h2
    [SwCheck]::PostMessage($h2, 0x201, [IntPtr]1, (LParam 60 60)) | Out-Null
    [SwCheck]::PostMessage($h2, 0x200, [IntPtr]1, (LParam 160 160)) | Out-Null
    Start-Sleep -Milliseconds 200
    [SwCheck]::PostMessage($h2, 0x202, [IntPtr]0, (LParam 160 160)) | Out-Null
    Start-Sleep -Milliseconds 500
    $still = Rect $h2
    Check 'lock positions stops a drag' ($answer.ok -and $locked -and $still.L -eq $place.L -and $still.T -eq $place.T)
    Send-Host @{ command = 'debug-invoke'; target = 'tray'; path = @(4) } | Out-Null
    Check 'lock positions turns off again' (-not (Send-Host @{ command = 'debug-menu'; target = 'tray' }).items[4].checked)
    # Add widget from the tray, refresh all, remove from the widget menu.
    $before = @(Widget-List).Count
    $answer = Send-Host @{ command = 'debug-invoke'; target = 'tray'; path = @(1, 0) }
    Start-Sleep -Seconds 2
    Check 'the tray menu adds a widget' ($answer.ok -and @(Widget-List).Count -eq $before + 1)
    $countBefore = (LogLines).Count
    $answer = Send-Host @{ command = 'debug-invoke'; target = 'tray'; path = @(3) }
    Check 'refresh all redraws the widgets' ($answer.ok -and (Wait-Log 'drawn ' $countBefore))
    $newest = Widget-List | Select-Object -Last 1
    $answer = Send-Host @{ command = 'debug-invoke'; target = $newest.id; path = @(6) }
    Start-Sleep -Seconds 1
    Check 'the widget menu removes the widget' ($answer.ok -and @(Widget-List).Count -eq $before -and @([SwCheck]::Find('ScriptWidgetWidget')).Count -eq $before)

    # Animation plays from the saved layout. Repainting must not re-run package code.
    [byte[]] $gifBytes = @(
        0x47,0x49,0x46,0x38,0x39,0x61,0x01,0x00,0x01,0x00,0x80,0x00,0x00,0xFF,0x00,0x00,0x00,0x00,0xFF,
        0x21,0xF9,0x04,0x00,0x14,0x00,0x00,0x00,0x2C,0x00,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x02,0x02,0x44,0x01,0x00,
        0x21,0xF9,0x04,0x00,0x14,0x00,0x00,0x00,0x2C,0x00,0x00,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0x02,0x02,0x4C,0x01,0x00,0x3B
    )
    $animatedSource = Join-Path $Output 'animation-source'
    New-Item -ItemType Directory -Force (Join-Path $animatedSource 'image') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $animatedSource 'image/test.gif'), $gifBytes)
    $animationCode = @'
$storage.setString("animationRuns", String(Number($storage.getString("animationRuns") || 0) + 1));
$render(<zstack frame="max" background="#111827"><gif file="test.gif" frame="100,100" /><rect frame="24,70" color="#fb7185" animation="swing" /><circle frame="12,12" color="white" /></zstack>);
'@
    [IO.File]::WriteAllText((Join-Path $animatedSource 'main.jsx'), $animationCode, (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $animatedSource 'widget.json'), '{"formatVersion":2,"id":"com.example.animation-check","name":"animation-source","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":["storage"],"networkDomains":[],"plugins":[]}', (New-Object Text.UTF8Encoding $false))
    $windowsBeforeAnimation = @([SwCheck]::Find('ScriptWidgetWidget'))
    & $cli pack $animatedSource (Join-Path $Output 'animation.swt') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Animation fixture could not be packed.' }
    & $cli install (Join-Path $Output 'animation.swt') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Animation fixture could not be installed.' }
    $beforeAnimation = (LogLines).Count
    $addedAnimation = (& $cli add 'animation-source' --family small | Out-String | ConvertFrom-Json)
    Check 'an animated widget is added and drawn' ($addedAnimation.ok -and (Wait-Log 'drawn ' $beforeAnimation))
    $animatedWindow = Wait-WidgetCapture $windowsBeforeAnimation (Join-Path $Output 'animation-ready.png')
    $animationHashes = @()
    for ($frame = 0; $frame -lt 6; $frame++) {
        Start-Sleep -Milliseconds 150
        $picture = Join-Path $Output "animation-$frame.png"
        [void][SwCheck]::Capture($animatedWindow, $picture)
        $animationHashes += (Get-FileHash -LiteralPath $picture -Algorithm SHA256).Hash
    }
    Check 'animation changes the actual widget pixels' (@($animationHashes | Select-Object -Unique).Count -ge 3)
    $animationIds = @($addedAnimation.id)
    for ($copy = 1; $copy -lt $AnimationStressCopies; $copy++) {
        $beforeCopy = (LogLines).Count
        $addedCopy = (& $cli add 'animation-source' --family small | Out-String | ConvertFrom-Json)
        Check "animation stress copy $($copy + 1) is drawn" ($addedCopy.ok -and (Wait-Log 'drawn ' $beforeCopy))
        $animationIds += $addedCopy.id
    }
    if ($AnimationStressSeconds -gt 0) {
        $samples = @()
        $csv = Join-Path $Output 'animation-samples.csv'
        $process.Refresh()
        $cpuStart = $process.TotalProcessorTime.TotalSeconds
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.Elapsed.TotalSeconds -lt $AnimationStressSeconds) {
            Start-Sleep -Milliseconds 500
            $process.Refresh()
            $sample = [pscustomobject]@{ seconds = $watch.Elapsed.TotalSeconds; privateBytes = $process.PrivateMemorySize64; workingSet = $process.WorkingSet64; handles = $process.HandleCount; cpuSeconds = $process.TotalProcessorTime.TotalSeconds - $cpuStart }
            $samples += $sample
            $sample | Export-Csv -LiteralPath $csv -NoTypeInformation -Append
        }
        $cpuSeconds = $process.TotalProcessorTime.TotalSeconds - $cpuStart
        $report = [ordered]@{
            durationSeconds = $watch.Elapsed.TotalSeconds
            cpuSeconds = $cpuSeconds
            oneCorePercent = 100 * $cpuSeconds / $watch.Elapsed.TotalSeconds
            animatedWidgetCount = $AnimationStressCopies
            hostSha256 = (Get-FileHash -LiteralPath $HostPath -Algorithm SHA256).Hash.ToLowerInvariant()
            samples = $samples
        }
        $report | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Output 'animation-performance.json') -Encoding UTF8
        $warm = $samples | Where-Object { $_.seconds -ge [Math]::Min(10, $AnimationStressSeconds / 3) } | Select-Object -First 1
        Check 'animation remains running through the stress interval' (-not $process.HasExited)
        Check 'animation private memory stays within 64 MiB of its warm sample' (($samples[-1].privateBytes - $warm.privateBytes) -lt 64MB)
        Check 'animation handles stay within 64 of the warm sample' (($samples[-1].handles - $warm.handles) -lt 64)
        Check 'all stress widget windows remain' (@([SwCheck]::Find('ScriptWidgetWidget')).Count -eq $windowsBeforeAnimation.Count + $AnimationStressCopies)
    }
    $animationRuns = Get-ChildItem "$data\Storage" -Recurse -Filter '*.json' | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json).animationRuns.v } | Where-Object { $_ }
    Check 'animation ticks do not run the script again' ($animationRuns -eq [string]$AnimationStressCopies)
    [SwCheck]::PostMessage($hostWindow, 0x02B1, [IntPtr]7, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 300
    [void][SwCheck]::Capture($animatedWindow, (Join-Path $Output 'animation-locked-0.png'))
    Start-Sleep -Milliseconds 500
    [void][SwCheck]::Capture($animatedWindow, (Join-Path $Output 'animation-locked-1.png'))
    Check 'animation pauses while the session is locked' ((Get-FileHash (Join-Path $Output 'animation-locked-0.png')).Hash -eq (Get-FileHash (Join-Path $Output 'animation-locked-1.png')).Hash)
    [SwCheck]::PostMessage($hostWindow, 0x02B1, [IntPtr]8, [IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 600
    [void][SwCheck]::Capture($animatedWindow, (Join-Path $Output 'animation-resumed.png'))
    Check 'animation resumes after unlocking' ((Get-FileHash (Join-Path $Output 'animation-resumed.png')).Hash -ne (Get-FileHash (Join-Path $Output 'animation-locked-1.png')).Hash)
    foreach ($animationId in $animationIds) { Send-Host @{ command = 'remove'; id = $animationId } | Out-Null }
    Check 'removing an animated widget removes its window' (@([SwCheck]::Find('ScriptWidgetWidget')).Count -eq $windowsBeforeAnimation.Count)

    # A GIF-only widget must change too; the swing above cannot hide a decoder/AOT failure.
    $gifSource = Join-Path $Output 'gif-source'
    New-Item -ItemType Directory -Force (Join-Path $gifSource 'image') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $gifSource 'image/test.gif'), $gifBytes)
    [IO.File]::WriteAllText((Join-Path $gifSource 'main.jsx'), '$render(<zstack frame="max" background="#111827"><gif file="test.gif" frame="100,100" /></zstack>);', (New-Object Text.UTF8Encoding $false))
    [IO.File]::WriteAllText((Join-Path $gifSource 'widget.json'), '{"formatVersion":2,"id":"com.example.gif-check","name":"gif-source","version":"1.0.0","runtimeVersion":"1.0","entry":"main.jsx","supportedFamilies":["systemSmall"],"permissions":[],"networkDomains":[],"plugins":[]}', (New-Object Text.UTF8Encoding $false))
    & $cli pack $gifSource (Join-Path $Output 'gif.swt') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GIF fixture could not be packed.' }
    & $cli install (Join-Path $Output 'gif.swt') | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'GIF fixture could not be installed.' }
    $beforeGif = (LogLines).Count
    $windowsBeforeGif = @([SwCheck]::Find('ScriptWidgetWidget'))
    $addedGif = (& $cli add 'gif-source' --family small | Out-String | ConvertFrom-Json)
    Check 'a GIF widget is added and drawn' ($addedGif.ok -and (Wait-Log 'drawn ' $beforeGif))
    $gifWindow = Wait-WidgetCapture $windowsBeforeGif (Join-Path $Output 'gif-ready.png')
    $gifHashes = @()
    for ($frame = 0; $frame -lt 6; $frame++) {
        Start-Sleep -Milliseconds 150
        $picture = Join-Path $Output "gif-$frame.png"
        [void][SwCheck]::Capture($gifWindow, $picture)
        $gifHashes += (Get-FileHash -LiteralPath $picture -Algorithm SHA256).Hash
    }
    Check 'GIF playback changes the actual widget pixels' (@($gifHashes | Select-Object -Unique).Count -ge 2)
    Send-Host @{ command = 'remove'; id = $addedGif.id } | Out-Null
    Check 'removing a GIF widget removes its window' (@([SwCheck]::Find('ScriptWidgetWidget')).Count -eq $windowsBeforeAnimation.Count)

    Check 'the host is still running at the end' (-not $process.HasExited)
    # Quit from the tray menu ends the program by itself.
    $errorsBeforeQuit = LogLines | Where-Object { $_ -match 'failed|crashed|refused' }
    Send-Host @{ command = 'debug-invoke'; target = 'tray'; path = @(7) } | Out-Null
    $quit = $process.WaitForExit(8000)
    Check 'quit from the tray menu ends the host' ($quit -and $process.ExitCode -eq 0)
    Check 'the place survives a restart' ([bool]((Get-Content "$data\widgets.json" -Raw | ConvertFrom-Json).widgets | Where-Object { $_.y -eq 0 }))
    $errors = LogLines | Where-Object { $_ -match 'failed|crashed|refused' }
    Check 'the log holds no failures' (-not $errors) ($errors | Select-Object -First 2 | Out-String)
}
finally {
    if (-not $process.HasExited) { $process | Stop-Process -Force }
}
Write-Host "pictures and log -> $Output"
if ($script:failures -gt 0) { Write-Host "$($script:failures) check(s) failed"; exit 1 }
Write-Host 'all checks passed'
