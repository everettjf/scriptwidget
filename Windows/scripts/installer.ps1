# Builds the ScriptWidget installer (NSIS) that is published on GitHub Releases.
#
#   powershell -File Windows/scripts/installer.ps1 [-Arch x64|arm64] [-Version 0.1.0] [-SkipBuild]
#
# It packs the same published program folder as the self-contained MSIX package
# (Windows/artifacts/layout-<arch>, built by package.ps1), without the package manifest. The
# installed program has no package identity: it keeps its data in %LOCALAPPDATA%\ScriptWidget and
# starts at sign-in through the Run key. -SkipBuild uses the folder that is already there.
#
# Needs NSIS 3 (makensis.exe on PATH or in its default folder).
# Output: Windows/artifacts/ScriptWidget-<version>-<arch>-setup.exe. It is not signed, so
# Windows SmartScreen warns about it.
param(
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [ValidatePattern('^\d+\.\d+\.\d+$')] [string] $Version = '0.1.0',
    [switch] $SkipBuild
)
$ErrorActionPreference = 'Stop'
$windows = Resolve-Path (Join-Path $PSScriptRoot '..')
$artifacts = Join-Path $windows 'artifacts'
$layout = Join-Path $artifacts "layout-$Arch"

if (-not $SkipBuild) {
    & (Join-Path $PSScriptRoot 'package.ps1') -Arch $Arch -Version "$Version.0"
}
foreach ($required in 'ScriptWidget.exe', 'ScriptWidgetStudio.exe', 'resources.pri') {
    if (-not (Test-Path (Join-Path $layout $required))) { throw "No $required in $layout. Run without -SkipBuild." }
}
if (Test-Path (Join-Path $layout 'ScriptWidgetStudio.exe.WebView2')) { throw "$layout has been run from: it holds a browser profile. Build it again." }

$makensis = (Get-Command makensis.exe -ErrorAction SilentlyContinue).Source
if (-not $makensis) {
    $makensis = Join-Path ${env:ProgramFiles(x86)} 'NSIS\makensis.exe'
    if (-not (Test-Path $makensis)) { throw 'makensis.exe was not found. Install NSIS 3 (https://nsis.sourceforge.io).' }
}

# The uninstaller removes exactly what the installer put there, by name, so a folder the user
# chose with /D= is never emptied of anything else.
$entries = Get-ChildItem $layout -Force | Where-Object { $_.Name -ne 'AppxManifest.xml' }
$lines = foreach ($entry in $entries) {
    if ($entry.Name -match '[\$"]') { throw "Unexpected name in the layout: $($entry.Name)" }
    if ($entry.PSIsContainer) { "  RMDir /r `"`$INSTDIR\$($entry.Name)`"" } else { "  Delete `"`$INSTDIR\$($entry.Name)`"" }
}
$fileList = Join-Path $artifacts "installer-files-$Arch.nsh"
[System.IO.File]::WriteAllLines($fileList, $lines, (New-Object System.Text.UTF8Encoding $true))
$sizeKb = [int](($entries | ForEach-Object { if ($_.PSIsContainer) { Get-ChildItem $_.FullName -Recurse -File -Force } else { $_ } } | Measure-Object Length -Sum).Sum / 1KB)

$output = Join-Path $artifacts "ScriptWidget-$Version-$Arch-setup.exe"
if (Test-Path $output) { Remove-Item $output -Force }
$icon = Join-Path $windows 'package\Assets\ScriptWidget.ico'
& $makensis /V2 /INPUTCHARSET UTF8 "/DVERSION=$Version" "/DARCH=$Arch" "/DLAYOUT=$layout" "/DOUTPUT=$output" "/DICON=$icon" "/DFILELIST=$fileList" "/DSIZE_KB=$sizeKb" (Join-Path $windows 'installer\ScriptWidget.nsi')
if ($LASTEXITCODE -ne 0) { throw "makensis failed with exit code $LASTEXITCODE" }
$hash = (Get-FileHash $output -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Host ("installer -> {0} ({1:N1} MB)" -f $output, ((Get-Item $output).Length / 1MB))
Write-Host "sha256 $hash"
