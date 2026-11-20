# End-to-end CLI acceptance using exclusively synthetic packages and a new data folder.
# powershell -File Windows/scripts/creation-check.ps1 [-CliPath <swcli.exe>] [-Output <new folder>]
# Add -OnlineGallery to test the real trusted catalog. -LiveAi uses the active profile's existing
# Credential Locker key (read-only); -ProfileData selects its metadata folder. No key argument is accepted.
[CmdletBinding()]
param(
    [string] $CliPath,
    [string] $Output,
    [switch] $OnlineGallery,
    [switch] $LiveAi,
    [string] $ProfileData = (Join-Path $env:LOCALAPPDATA 'ScriptWidget')
)
$ErrorActionPreference = 'Stop'
$windows = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if (-not $CliPath) { $CliPath = Get-ChildItem (Join-Path $windows 'src/ScriptWidget.Cli/bin') -Recurse -Filter swcli.exe | Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName }
$CliPath = (Resolve-Path $CliPath).Path
if (-not $Output) { $Output = Join-Path $windows ('artifacts/creation-check-' + [guid]::NewGuid().ToString('N')) }
$Output = [IO.Path]::GetFullPath($Output)
if (Test-Path -LiteralPath $Output) { throw 'Output must be a new directory; existing files are never deleted by this check.' }
[void][IO.Directory]::CreateDirectory($Output)
$data = Join-Path $Output 'data'
[void][IO.Directory]::CreateDirectory((Join-Path $data 'AiConversations'))
$steps = New-Object 'System.Collections.Generic.List[object]'
$sequence = 0
$completed = $false
function Check([string] $name, [bool] $passed) {
    $steps.Add([pscustomobject]@{ name = $name; passed = $passed })
    if (-not $passed) { throw "Acceptance failed: $name" }
    Write-Host "PASS  $name"
}
function Invoke-Cli([string] $name, [string[]] $arguments, [int] $expected = 0, [switch] $Raw) {
    $script:sequence++
    $prefix = Join-Path $Output ('{0:D2}-{1}' -f $script:sequence, $name)
    $previous = $ErrorActionPreference
    try { $ErrorActionPreference = 'Continue'; $lines = & $CliPath @arguments 2> ($prefix + '.stderr.txt'); $code = $LASTEXITCODE }
    finally { $ErrorActionPreference = $previous }
    $text = $lines -join "`n"
    $suffix = if ($Raw) { '.stdout.txt' } else { '.json' }
    [IO.File]::WriteAllText($prefix + $suffix, $text)
    Check "$name exits with $expected" ($code -eq $expected)
    if ($Raw) { return $text }
    if ($text.Trim().Length -gt 0) { return $text | ConvertFrom-Json }
}
function Write-Json([string] $path, $value) { [IO.File]::WriteAllText($path, ($value | ConvertTo-Json -Depth 30)) }
try {
    # A public conversation-file fixture, not a model response. Separate CLI processes test recovery.
    $id = [guid]::NewGuid().ToString('D')
    $first = [guid]::NewGuid().ToString('D'); $second = [guid]::NewGuid().ToString('D')
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $source = '$render(<vstack frame="max" padding="12" background="#111827"><text color="white">Acceptance v1</text></vstack>);'
    $fixture = [ordered]@{ formatVersion = 1; id = $id; title = 'CLI acceptance'; size = 'medium'; packageId = $null; currentVersionId = $second; versionCounter = 2; createdAt = $now; updatedAt = $now
        versions = @(
            @{ id = $first; number = 1; source = $source; parentId = $null; createdAt = $now; networkDomains = @() },
            @{ id = $second; number = 2; source = $source.Replace('v1', 'v2'); parentId = $first; createdAt = $now; networkDomains = @() })
        turns = @() }
    $conversationFile = Join-Path $data "AiConversations/$id.json"
    Write-Json $conversationFile $fixture
    $listed = Invoke-Cli 'conversations' @('ai', 'list', '--data', $data)
    Check 'fixture is read through the CLI' (@($listed.conversations | Where-Object id -eq $id).Count -eq 1)
    try {
        [IO.File]::SetAttributes($conversationFile, [IO.FileAttributes]::ReadOnly)
        $partial = Invoke-Cli 'apply-with-readonly-conversation' @('ai', 'apply', $id, '--name', 'Recovered publication', '--data', $data)
        Check 'a failed conversation write reports the published widget accurately' ($partial.ok -and -not $partial.conversationSaved -and
            [IO.File]::ReadAllText((Join-Path $data 'Packages/Recovered publication/main.jsx')) -eq $source.Replace('v1', 'v2'))
    }
    finally { [IO.File]::SetAttributes($conversationFile, [IO.FileAttributes]::Normal) }
    $applied = Invoke-Cli 'apply-draft' @('ai', 'apply', $id, '--name', 'Acceptance', '--data', $data)
    Check 'publication and conversation persistence succeed' ($applied.ok -and $applied.conversationSaved)
    $package = Join-Path $data 'Packages/Acceptance'
    [void][IO.Directory]::CreateDirectory((Join-Path $package 'lib'))
    [IO.File]::WriteAllText((Join-Path $package 'lib/helper.js'), 'const preserved = true;')
    [IO.File]::WriteAllBytes((Join-Path $package 'payload.bin'), [byte[]]@(1, 2, 3, 255))
    $null = Invoke-Cli 'select-version' @('ai', 'select', $id, $first, '--data', $data)
    $again = Invoke-Cli 'apply-old-version' @('ai', 'apply', $id, '--data', $data)
    Check 'version switching preserves installation identity and nested assets' ($again.installation -eq $applied.installation -and
        [IO.File]::ReadAllText((Join-Path $package 'lib/helper.js')) -eq 'const preserved = true;' -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $package 'payload.bin'))) -eq 'AQID/w==')
    $fork = Invoke-Cli 'fork' @('ai', 'fork', $id, '--data', $data)
    $forkState = Invoke-Cli 'fork-state' @('ai', 'show', $fork.id, '--data', $data)
    Check 'fork survives a separate process and carries its applied fingerprint' ($forkState.versions.Count -eq 1 -and $forkState.appliedSourceHash.Length -eq 64)
    $entry = Join-Path $package 'main.jsx'
    $manual = $source.Replace('v1', 'manual')
    [IO.File]::WriteAllText($entry, $manual)
    $null = Invoke-Cli 'refuse-stale-apply' @('ai', 'apply', $fork.id, '--data', $data) 1
    Check 'stale application preserves manually edited source' ([IO.File]::ReadAllText($entry) -eq $manual)
    [IO.File]::WriteAllText($entry, $source)

    # Require explicit network approval even when the selected fixture itself makes no request.
    $networkId = [guid]::NewGuid().ToString('D')
    $fixture.id = $networkId; $fixture.currentVersionId = $first; $fixture.versionCounter = 1
    $fixture.versions = @(@{ id = $first; number = 1; source = $source; parentId = $null; createdAt = $now; networkDomains = @('api.example.com') })
    Write-Json (Join-Path $data "AiConversations/$networkId.json") $fixture
    $null = Invoke-Cli 'refuse-unapproved-network' @('ai', 'apply', $networkId, '--name', 'Network approval', '--data', $data) 1
    Check 'refused network publication creates no package' (-not (Test-Path (Join-Path $data 'Packages/Network approval')))
    $null = Invoke-Cli 'approve-network' @('ai', 'apply', $networkId, '--name', 'Network approval', '--allow-network', '--data', $data)
    $manifest = Get-Content (Join-Path $data 'Packages/Network approval/widget.json') -Raw | ConvertFrom-Json
    Check 'approval persists only the declared host' ($manifest.permissions -contains 'network' -and @($manifest.networkDomains).Count -eq 1 -and $manifest.networkDomains[0] -eq 'api.example.com')

    $library = Invoke-Cli 'library' @('list', '--data', $data)
    Check 'library reads isolated data only' ($library.packages.Count -eq 3)
    foreach ($family in @('small', 'medium', 'large')) {
        $render = Invoke-Cli "render-$family" @('render', $package, '--family', $family, '--output', (Join-Path $Output "$family.png"), '--data', (Join-Path $Output 'runtime'))
        Check "$family draws native pixels" ($render.ok -and $render.pixelWidth -gt 0 -and $render.pixelHeight -gt 0)
    }
    $archive = Join-Path $Output 'Acceptance.swt'
    $null = Invoke-Cli 'export-package' @('pack', $package, $archive) -Raw
    $importData = Join-Path $Output 'imported'
    $imported = Invoke-Cli 'import-package' @('install', $archive, '--data', $importData)
    Check 'archive import creates a fresh installation' ($imported.installation -ne $applied.installation)
    $importRun = Invoke-Cli 'run-import' @('run', (Join-Path $importData ('Packages/' + $imported.name)), '--data', (Join-Path $Output 'runtime'))
    Check 'imported widget executes' $importRun.ok

    $skillSource = Join-Path $Output 'skill-source'; [void][IO.Directory]::CreateDirectory($skillSource)
    $skillId = 'test.scriptwidget.acceptance'
    Write-Json (Join-Path $skillSource 'skill.json') @{ formatVersion = 1; id = $skillId; name = 'Acceptance Skill'; version = '1.0.0'; summary = 'Synthetic CLI test'; symbol = 'checkmark'; promptFile = 'SKILL.md'; minimumRuntimeVersion = '1.0'; tags = @('test') }
    [IO.File]::WriteAllText((Join-Path $skillSource 'SKILL.md'), 'Use readable text and an offline fallback.')
    $skillArchive = Join-Path $Output 'acceptance.swskill'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($skillSource, $skillArchive)
    $null = Invoke-Cli 'import-skill' @('skills', 'import', $skillArchive, '--data', $data)
    $null = Invoke-Cli 'enable-skill' @('skills', 'enable', $skillId, '--data', $data)
    $skill = Invoke-Cli 'show-skill' @('skills', 'show', $skillId, '--data', $data)
    Check 'enabled Skill retains its prompt' ($skill.enabled -and $skill.instruction.Contains('readable text'))
    $exportedSkill = Join-Path $Output 'exported.swskill'
    $null = Invoke-Cli 'export-skill' @('skills', 'export', $skillId, $exportedSkill, '--data', $data)
    $null = Invoke-Cli 'disable-skill' @('skills', 'disable', $skillId, '--data', $data)
    $null = Invoke-Cli 'remove-skill' @('skills', 'remove', $skillId, '--data', $data)
    $null = Invoke-Cli 'restore-skill' @('skills', 'import', $exportedSkill, '--data', $data)
    $restored = Invoke-Cli 'restored-skill' @('skills', 'show', $skillId, '--data', $data)
    Check 'Skill archive round trip preserves instructions' ($restored.instruction -eq $skill.instruction)

    if ($OnlineGallery) {
        $catalog = Invoke-Cli 'gallery' @('gallery', 'list', '--data', $data)
        $hello = $catalog.items | Where-Object { $_.kind -eq 'widget' -and $_.name -eq 'Gallery Hello Card' } | Select-Object -First 1
        Check 'trusted Gallery includes the offline reference card' ([bool]$hello)
        $installed = Invoke-Cli 'gallery-install' @('gallery', 'install', $hello.id, '--data', $data)
        $run = Invoke-Cli 'gallery-run' @('run', (Join-Path $data ('Packages/' + $installed.localName)), '--data', (Join-Path $Output 'runtime'))
        Check 'verified Gallery widget executes' $run.ok
    }
    if ($LiveAi) {
        $profiles = Invoke-Cli 'profile-metadata' @('ai', 'profiles', '--data', $ProfileData)
        $active = $profiles.profiles | Where-Object active | Select-Object -First 1
        Check 'an existing active provider is available' ([bool]$active)
        Write-Json (Join-Path $data 'ai-profiles.json') @{ formatVersion = 1; activeId = $active.id; profiles = @(@{ formatVersion = 1; id = $active.id; name = $active.name; provider = $active.provider; baseUrl = $active.baseUrl; model = $active.model; temperature = $active.temperature }) }
        $created = Invoke-Cli 'live-new' @('ai', 'new', 'Create an offline navy card with white text exactly LIVE CARD and a fixed value 7. No network, storage, images or icons. Use only vstack and text. Reply with an English summary.', '--data', $data)
        Check 'real AI produces a locally validated version' $created.ok
        $liveSaved = Invoke-Cli 'live-apply' @('ai', 'apply', $created.id, '--name', 'Live acceptance', '--data', $data)
        $liveEntry = Join-Path $data 'Packages/Live acceptance/main.jsx'
        [IO.File]::WriteAllText($liveEntry, 'throw new Error("synthetic acceptance failure");')
        $null = Invoke-Cli 'live-refuse-conflict' @('ai', 'apply', $created.id, '--data', $data) 1
        $fixed = Invoke-Cli 'live-repair' @('ai', 'continue', $created.id, 'Fix the current synthetic acceptance failure. Render an offline navy vstack with white text exactly LIVE FIXED and value 7. No network or storage. Reply with an English summary.', '--data', $data)
        Check 'real AI repairs the external failing source' $fixed.ok
        $null = Invoke-Cli 'live-apply-repair' @('ai', 'apply', $created.id, '--data', $data)
        $run = Invoke-Cli 'live-run' @('run', (Split-Path $liveEntry), '--data', (Join-Path $Output 'runtime'))
        Check 'repaired real-model widget runs' $run.ok

        # Kill only this returned test process after its durable running turn appears.
        # This tests crash recovery, not graceful cancellation (covered by Core tests).
        $known = @(Get-ChildItem (Join-Path $data 'AiConversations') -Filter '*.json' | Select-Object -ExpandProperty Name)
        $probe = Start-Process $CliPath -ArgumentList ('ai new "Create an offline four-row typography widget with navy background and white labels. No network or storage." --data "' + $data + '"') -PassThru -WindowStyle Hidden -RedirectStandardOutput (Join-Path $Output 'crash.stdout.json') -RedirectStandardError (Join-Path $Output 'crash.stderr.txt')
        $interruptedId = $null; $deadline = (Get-Date).AddSeconds(15)
        try {
            while (-not $probe.HasExited -and (Get-Date) -lt $deadline) {
                foreach ($file in Get-ChildItem (Join-Path $data 'AiConversations') -Filter '*.json' | Where-Object { $known -notcontains $_.Name }) {
                    $running = Get-Content $file.FullName -Raw | ConvertFrom-Json
                    if ($running.turns.status -contains 'running') { $interruptedId = $running.id; Stop-Process -Id $probe.Id -Force; break }
                }
                if ($interruptedId) { break }; Start-Sleep -Milliseconds 25
            }
        }
        finally { if (-not $probe.HasExited) { Stop-Process -Id $probe.Id -Force }; [void]$probe.WaitForExit(3000) }
        Check 'crash probe observes a durable running turn' ([bool]$interruptedId)
        $reopened = Invoke-Cli 'crash-reopen' @('ai', 'show', $interruptedId, '--data', $data)
        Check 'another CLI process reads the crashed turn as interrupted' ($reopened.turns[-1].status -eq 'interrupted')
    }
    $completed = $true
}
finally {
    Write-Json (Join-Path $Output 'acceptance.json') @{ ok = $completed; cli = $CliPath; cliSha256 = (Get-FileHash $CliPath -Algorithm SHA256).Hash.ToLowerInvariant(); onlineGallery = [bool]$OnlineGallery; liveAi = [bool]$LiveAi; completedAt = [DateTimeOffset]::UtcNow.ToString('o'); checks = @($steps.ToArray()) }
    Write-Host "Evidence -> $Output"
}
Write-Host 'creation acceptance passed'
