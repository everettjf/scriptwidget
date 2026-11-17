# Builds the ScriptWidget MSIX package.
#
#   powershell -File Windows/scripts/package.ps1 [-Arch x64|arm64] [-Version 0.1.0.0]
#       [-IdentityName <name>] [-Publisher <CN=...>] [-PublisherDisplayName <name>]
#       [-FrameworkDependent] [-SkipBuild]
#
# -IdentityName, -Publisher and -PublisherDisplayName must be the values
# Partner Center shows under "Product identity" for a Store submission. The
# defaults only produce a package for local testing.
#
# By default the package carries the Windows App SDK inside it, so it installs
# on a clean machine. -FrameworkDependent declares the Windows App Runtime
# framework package instead, which the Microsoft Store installs by itself and
# which makes the package much smaller.
#
# Output: Windows/artifacts/ScriptWidget_<version>_<arch>.msix (not signed; the
# Store signs submissions) and the folder it was packed from.
param(
    [ValidateSet('x64', 'arm64')] [string] $Arch = 'x64',
    [string] $Version = '0.1.0.0',
    [string] $IdentityName = 'AtomSprout.ScriptWidget',
    [string] $Publisher = 'CN=ScriptWidget Local Test',
    [string] $PublisherDisplayName = 'AtomSprout',
    [switch] $FrameworkDependent,
    [switch] $SkipBuild
)
$ErrorActionPreference = 'Stop'
$windows = Resolve-Path (Join-Path $PSScriptRoot '..')
$repository = Resolve-Path (Join-Path $windows '..')
$platform = if ($Arch -eq 'arm64') { 'ARM64' } else { 'x64' }
$rid = "win-$Arch"
$artifacts = Join-Path $windows 'artifacts'
$layout = Join-Path $artifacts "layout-$Arch"

function Invoke-Checked([scriptblock] $command, [string] $what) {
    & $command
    if ($LASTEXITCODE -ne 0) { throw "$what failed with exit code $LASTEXITCODE" }
}

if (-not $SkipBuild) {
    # vswhere must be on PATH for the native AOT link step.
    $installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
    if (Test-Path $installer) { $env:PATH = "$installer;$env:PATH" }
    Invoke-Checked { node (Join-Path $windows 'scripts\build-shared-js.mjs') } 'shared JavaScript'
    & (Join-Path $windows 'scripts\build-native.ps1') -Arch $Arch
    if (Test-Path $layout) { Remove-Item $layout -Recurse -Force }
    $dependencyMode = if ($FrameworkDependent) { 'true' } else { 'false' }
    $common = @('-c', 'Release', '-r', $rid, "-p:Platform=$platform", "-p:Version=$($Version -replace '\.\d+$', '')", "-p:SwFrameworkDependent=$dependencyMode", '--nologo', '-v', 'q', '-o', $layout)
    # The always-running host is compiled ahead of time: no .NET runtime to load, less memory.
    Invoke-Checked { dotnet publish (Join-Path $windows 'src\ScriptWidget.App') @common '-p:PublishAot=true' } 'host publish'
    Invoke-Checked { dotnet publish (Join-Path $windows 'src\ScriptWidget.Studio') @common '--self-contained' 'true' } 'management window publish'
}
if (-not (Test-Path (Join-Path $layout 'ScriptWidget.exe'))) { throw "No build in $layout. Run without -SkipBuild." }

# Debug symbols and build leftovers do not belong in the package.
Get-ChildItem $layout -Recurse -Include '*.pdb', '*.lib', '*.exp' | Remove-Item -Force

# Tile images. The management window publishes its own resources.pri (its XAML resources), which
# must stay as it is, so the images are not indexed by scale: the 200% versions are used at every scale.
$assets = Join-Path $layout 'Assets'
New-Item -ItemType Directory -Force $assets | Out-Null
foreach ($name in 'Square44x44Logo', 'Square150x150Logo', 'Wide310x150Logo', 'StoreLogo') {
    Copy-Item (Join-Path $windows "package\Assets\$name.scale-200.png") (Join-Path $assets "$name.png") -Force
}
if (-not (Test-Path (Join-Path $layout 'resources.pri'))) { throw 'resources.pri is missing: the management window was not published into the layout.' }

$dependencies = ''
if ($FrameworkDependent) {
    # Matches the Windows App SDK 1.6 the projects reference.
    $dependencies = "    <PackageDependency Name=`"Microsoft.WindowsAppRuntime.1.6`" MinVersion=`"6000.318.2304.0`" Publisher=`"CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, S=Washington, C=US`" />`r`n"
}
$manifest = Get-Content (Join-Path $windows 'package\AppxManifest.xml') -Raw
$manifest = $manifest.Replace('{{IdentityName}}', $IdentityName).Replace('{{Publisher}}', $Publisher).Replace('{{PublisherDisplayName}}', $PublisherDisplayName)
$manifest = $manifest.Replace('{{Version}}', $Version).Replace('{{Architecture}}', $Arch).Replace('{{FrameworkDependencies}}', $dependencies)
[System.IO.File]::WriteAllText((Join-Path $layout 'AppxManifest.xml'), $manifest, (New-Object System.Text.UTF8Encoding $false))

$kits = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
$makeappx = Get-ChildItem $kits -Recurse -Filter makeappx.exe | Where-Object { $_.FullName -match '\\x64\\' } | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $makeappx) { throw 'makeappx.exe was not found. Install the Windows SDK.' }
$package = Join-Path $artifacts "ScriptWidget_${Version}_$Arch.msix"
if (Test-Path $package) { Remove-Item $package -Force }
Invoke-Checked { & $makeappx.FullName pack /d $layout /p $package /o | Out-Null } 'makeappx pack'
$size = (Get-Item $package).Length / 1MB
Write-Host ("package -> {0} ({1:N1} MB)" -f $package, $size)
