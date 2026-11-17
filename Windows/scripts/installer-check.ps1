# Installs, updates and removes ScriptWidget with the NSIS installer and checks each step.
#
#   powershell -File Windows/scripts/installer-check.ps1 -Installer <setup.exe> [-Output <folder>]
#
# It installs into the real per-user location (%LOCALAPPDATA%\Programs\ScriptWidget) and removes
# it again, so it refuses to run when ScriptWidget is already installed there. The program is
# started with a scratch data folder; %LOCALAPPDATA%\ScriptWidget is not touched.
# A host that is already running (for example the copy from the Microsoft Store) must be quit
# first: there is one host per user.
param(
    [Parameter(Mandatory)] [string] $Installer,
    [string] $Output = (Join-Path $env:TEMP "scriptwidget-installer-check")
)
$ErrorActionPreference = 'Stop'
$Installer = (Resolve-Path $Installer).Path
$target = Join-Path $env:LOCALAPPDATA 'Programs\ScriptWidget'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\ScriptWidget'
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'ScriptWidget.lnk'
$classKey = 'HKCU:\Software\Classes\ScriptWidget.Package'
if (Test-Path $target) { throw "$target exists: ScriptWidget is installed. This check installs and removes it, so it will not run here." }
if (Get-Process ScriptWidget -ErrorAction SilentlyContinue) { throw 'A ScriptWidget host is running. Quit it first.' }

if (Test-Path $Output) { Remove-Item $Output -Recurse -Force }
New-Item -ItemType Directory -Force $Output | Out-Null
$data = Join-Path $Output 'data'
$env:SCRIPTWIDGET_DATA = $data
$log = Join-Path $data 'host.log'
$failures = New-Object System.Collections.Generic.List[string]
function Check([string] $name, [bool] $passed, [string] $detail = '') {
    $line = if ($passed) { "ok    $name" } else { "FAIL  $name $detail" }
    Write-Host $line
    Add-Content (Join-Path $Output 'installer-check.log') $line
    if (-not $passed) { $failures.Add($name) }
}
function Mine([string] $name) { Get-Process $name -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($target, [StringComparison]::OrdinalIgnoreCase) } }
function Wait([scriptblock] $condition, [int] $seconds) {
    $until = (Get-Date).AddSeconds($seconds)
    while ((Get-Date) -lt $until) { if (& $condition) { return $true }; Start-Sleep -Milliseconds 250 }
    return [bool](& $condition)
}
function Install() { return (Start-Process $Installer -ArgumentList '/S' -Wait -PassThru).ExitCode }

try {
    # 1. A first installation.
    Check 'silent install exits with 0' ((Install) -eq 0)
    Check 'the host and the management window are installed' ((Test-Path "$target\ScriptWidget.exe") -and (Test-Path "$target\ScriptWidgetStudio.exe") -and (Test-Path "$target\resources.pri"))
    Check 'the package manifest is not installed' (-not (Test-Path "$target\AppxManifest.xml"))
    Check 'the uninstaller is installed' (Test-Path "$target\uninstall.exe")
    Check 'the Start menu shortcut exists' (Test-Path $shortcut)
    $entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
    Check 'the entry in Installed apps names the version and the folder' ($entry -and $entry.DisplayVersion -match '^\d+\.\d+\.\d+$' -and $entry.InstallLocation -eq $target) "$($entry.DisplayVersion) $($entry.InstallLocation)"
    $command = (Get-ItemProperty "$classKey\shell\open\command" -ErrorAction SilentlyContinue).'(default)'
    Check '.swt files open in the management window' ((Get-ItemProperty 'HKCU:\Software\Classes\.swt' -ErrorAction SilentlyContinue).'(default)' -eq 'ScriptWidget.Package' -and $command -eq "`"$target\ScriptWidgetStudio.exe`" `"%1`"") "$command"

    # 2. The installed program runs without a package identity.
    Start-Process "$target\ScriptWidget.exe" -ArgumentList '--startup'
    Check 'the installed host starts' (Wait { (Test-Path $log) -and (Select-String -Path $log -Pattern 'host started' -Quiet) } 20)
    Check 'the host runs without a package identity' ([bool](Select-String -Path $log -Pattern 'packaged False' -Quiet))
    Check 'the first start puts a widget on the desktop' (Wait { (Test-Path "$data\widgets.json") -and ((Get-Content "$data\widgets.json" -Raw) -match '"package"') } 30)
    $picture = Join-Path $Output 'studio.png'
    Start-Process "$target\ScriptWidgetStudio.exe" -ArgumentList '--page', 'templates', '--screenshot', $picture
    Check 'the installed management window opens and draws' (Wait { (Test-Path $picture) -and (Get-Item $picture).Length -gt 20000 } 60)
    [void](Wait { -not (Mine ScriptWidgetStudio) } 15)

    # 3. "Start when I sign in" is the Run key of this user; set the way the app sets it.
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $previous = (Get-ItemProperty $run -ErrorAction SilentlyContinue).ScriptWidget
    if ($previous) { throw "The Run key already has a ScriptWidget value: $previous" }
    Set-ItemProperty $run -Name ScriptWidget -Value "`"$target\ScriptWidget.exe`" --startup"

    # 4. Installing again over a running copy (an update).
    Check 'the host is running before the update' ([bool](Mine ScriptWidget))
    $before = (Mine ScriptWidget | Select-Object -First 1).Id
    Check 'the update exits with 0' ((Install) -eq 0)
    Check 'the update stopped the running host' (-not (Get-Process -Id $before -ErrorAction SilentlyContinue))
    Check 'the host was asked to quit, not ended' ([bool](Select-String -Path $log -Pattern 'host stopped' -Quiet))
    Check 'the files are there after the update' ((Test-Path "$target\ScriptWidget.exe") -and (Test-Path "$target\uninstall.exe"))
    Check 'the widgets are kept by the update' ((Get-Content "$data\widgets.json" -Raw) -match '"package"')

    # 5. Removing it while it runs.
    Start-Process "$target\ScriptWidget.exe" -ArgumentList '--startup'
    Check 'the host starts again after the update' (Wait { [bool](Mine ScriptWidget) } 20)
    Start-Sleep 2
    Set-Content "$target\the-users-own-file.txt" 'x'
    Start-Process "$target\uninstall.exe" -ArgumentList '/S' -Wait
    Check 'the uninstaller stops the host' (Wait { -not (Mine ScriptWidget) } 30)
    Check 'the program files are removed' (Wait { -not (Test-Path "$target\ScriptWidget.exe") -and -not (Test-Path "$target\uninstall.exe") -and -not (Test-Path "$target\Microsoft.UI.Xaml") } 60)
    Check 'a file the installer did not put there is left alone' (Test-Path "$target\the-users-own-file.txt")
    Check 'the Start menu shortcut is removed' (-not (Test-Path $shortcut))
    Check 'the entry in Installed apps is removed' (-not (Test-Path $uninstallKey))
    Check 'the file type is removed' (-not (Test-Path $classKey))
    Check 'start at sign-in is removed' (-not (Get-ItemProperty $run -ErrorAction SilentlyContinue).ScriptWidget)
    Check 'a silent uninstall keeps the widgets' (Test-Path "$data\widgets.json")
}
finally {
    Mine ScriptWidget | Stop-Process -Force -ErrorAction SilentlyContinue
    Mine ScriptWidgetStudio | Stop-Process -Force -ErrorAction SilentlyContinue
    if (Test-Path $log) { Copy-Item $log (Join-Path $Output 'host.log') -Force }
    Remove-Item "$target\the-users-own-file.txt" -Force -ErrorAction SilentlyContinue
    if ((Test-Path $target) -and -not (Get-ChildItem $target -Force)) { Remove-Item $target -Force }
}
if ($failures.Count -gt 0) { Write-Host "$($failures.Count) check(s) failed: $($failures -join '; ')"; exit 1 }
Write-Host 'installer check passed'
