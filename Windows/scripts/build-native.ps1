# Builds swcore.dll (QuickJS-NG plus the host binding) with MSVC.
#
#   pwsh Windows/scripts/build-native.ps1 [-Arch x64|arm64] [-Asan]
#
# Output: Windows/native/out/<arch>[-asan]/swcore.dll
param(
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [switch] $Asan
)
$ErrorActionPreference = 'Stop'
$native = Join-Path $PSScriptRoot '..\native' | Resolve-Path
$name = if ($Asan) { "$Arch-asan" } else { $Arch }
$build = Join-Path $native "build\$name"
$out = Join-Path $native "out\$name"

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) { throw 'Visual Studio with the C++ workload is required (vswhere.exe not found).' }
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'No Visual Studio installation with the MSVC tools was found.' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvarsall.bat'
$target = if ($Arch -eq 'arm64') { if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64_arm64' } } else { if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64_x64' } else { 'x64' } }

# Import the MSVC environment for the target into this process.
$lines = & cmd /c "`"$vcvars`" $target >nul 2>&1 && set"
if ($LASTEXITCODE -ne 0) { throw "vcvarsall $target failed" }
foreach ($line in $lines) { if ($line -match '^([^=]+)=(.*)$') { Set-Item -Path "env:$($Matches[1])" -Value $Matches[2] } }

if (-not (Test-Path (Join-Path $env:VCToolsInstallDir "bin\Host$($env:VSCMD_ARG_HOST_ARCH)\$Arch\cl.exe"))) {
    throw "The MSVC $Arch build tools are not installed. Add them in the Visual Studio Installer (MSVC $Arch build tools)."
}

$asanFlag = if ($Asan) { 'ON' } else { 'OFF' }
& cmake -S $native -B $build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl "-DSW_ASAN=$asanFlag" | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'cmake configure failed' }
& cmake --build $build | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'cmake build failed' }

New-Item -ItemType Directory -Force $out | Out-Null
Copy-Item (Join-Path $build 'swcore.dll') $out -Force
if ($Asan) {
    # The sanitizer runtime must sit next to the DLL that uses it.
    $runtime = Get-ChildItem (Join-Path $env:VCToolsInstallDir "bin\Host$($env:VSCMD_ARG_HOST_ARCH)\$Arch") -Filter 'clang_rt.asan_dynamic-*.dll' | Select-Object -First 1
    if ($runtime) { Copy-Item $runtime.FullName $out -Force }
}
Write-Host "swcore -> $out"
