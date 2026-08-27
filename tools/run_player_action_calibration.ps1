#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [string[]]$Step = @(),
    [ValidateRange(5, 20)][int]$InitialSettleSeconds = 12,
    [ValidateRange(10, 45)][int]$GracefulExitTimeoutSeconds = 25,
    [switch]$CloseGameAfterCalibration,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedGameRoot = [IO.Path]::GetFullPath($GameRoot)
$gameExecutable = Join-Path $resolvedGameRoot 'MonsterHunterRise.exe'
$normalSource = Join-Path $repositoryRoot 'reframework\quests\q200032001.json'
$normalInstalled = Join-Path $resolvedGameRoot 'reframework\quests\q200032001.json'
$calibrationSource = Join-Path $repositoryRoot 'tools\fixtures\q200032002.player-calibration.json'
$calibrationInstalled = Join-Path $resolvedGameRoot 'reframework\quests\q200032002.json'
$artifactsRoot = Join-Path $repositoryRoot 'artifacts\player_action_calibration'
$probeRequestPath = Join-Path $resolvedGameRoot 'reframework\data\MHRiseMonsterCoach\dev_probe_request.json'
$probeReportPath = Join-Path $resolvedGameRoot 'reframework\data\MHRiseMonsterCoach\dev_probe_report.json'

foreach ($required in @($gameExecutable, $normalSource, $calibrationSource)) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Required file was not found: $required"
    }
}

function Stop-MonsterHunterRiseGracefully {
    param([Parameter(Mandatory)][int]$TimeoutSeconds)

    $processes = @(Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) { return }
    foreach ($process in $processes) {
        $process.Refresh()
        if (-not $process.CloseMainWindow()) {
            throw 'The game did not accept a graceful window-close request; no files were changed.'
        }
    }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (@(Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue).Count -eq 0) {
            return
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)
    throw "The game did not exit within $TimeoutSeconds seconds. It was not force-terminated."
}

function Assert-SameHash {
    param(
        [Parameter(Mandatory)][string]$Expected,
        [Parameter(Mandatory)][string]$Actual,
        [Parameter(Mandatory)][string]$Message
    )
    $expectedHash = (Get-FileHash -LiteralPath $Expected -Algorithm SHA256).Hash
    $actualHash = (Get-FileHash -LiteralPath $Actual -Algorithm SHA256).Hash
    if ($expectedHash -ne $actualHash) { throw $Message }
    return $actualHash
}

function Clear-TerminalProbeRequest {
    if (-not (Test-Path -LiteralPath $probeRequestPath -PathType Leaf)) { return }
    try {
        $request = Get-Content -LiteralPath $probeRequestPath -Raw | ConvertFrom-Json
        $report = Get-Content -LiteralPath $probeReportPath -Raw | ConvertFrom-Json
        $terminal = [string]$report.status -in @('completed', 'failed', 'timeout', 'aborted')
        if ($terminal -and [string]$request.session_id -eq [string]$report.session_id) {
            Remove-Item -LiteralPath $probeRequestPath
        }
    } catch {
        Write-Warning "Could not clear the terminal development request: $($_.Exception.Message)"
    }
}

function Resolve-VerifiedPython {
    $candidates = @(
        (Join-Path $repositoryRoot '.venv\Scripts\python.exe'),
        (Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe')
    )
    $command = Get-Command python -ErrorAction SilentlyContinue
    if ($command -and $command.Source -notmatch '[\\/]WindowsApps[\\/]') {
        $candidates += $command.Source
    }
    foreach ($candidate in $candidates | Select-Object -Unique) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        & $candidate --version *> $null
        if ($LASTEXITCODE -eq 0) { return [IO.Path]::GetFullPath($candidate) }
    }
    throw 'No real Python interpreter was found. Create .venv from requirements-dev.txt; the WindowsApps alias is not accepted.'
}

if (@(Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'Calibration refused because Monster Hunter Rise is already running. Close the game before starting developer automation.'
}
& (Join-Path $PSScriptRoot 'deploy_dev.ps1') -GameRoot $resolvedGameRoot
if (-not $?) { throw 'Normal development deployment failed.' }
$normalHashBefore = Assert-SameHash -Expected $normalSource -Actual $normalInstalled `
    -Message 'The installed normal Tigrex quest does not match the repository source.'

$calibrationHash = (Get-FileHash -LiteralPath $calibrationSource -Algorithm SHA256).Hash
if (Test-Path -LiteralPath $calibrationInstalled) {
    $existingHash = (Get-FileHash -LiteralPath $calibrationInstalled -Algorithm SHA256).Hash
    if ($existingHash -ne $calibrationHash) {
        throw "Quest ID 200032002 is already occupied by another file; calibration refused: $calibrationInstalled"
    }
}

$sessionId = [Guid]::NewGuid().ToString('N')
$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $artifactsRoot "$sessionId.json"
} else { [IO.Path]::GetFullPath($OutputPath) }
New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null

$staged = $false
$probeExitCode = 1
$cleanupError = $null
try {
    Copy-Item -LiteralPath $calibrationSource -Destination $calibrationInstalled -Force
    [void](Assert-SameHash -Expected $calibrationSource -Actual $calibrationInstalled `
        -Message 'Calibration quest staging hash verification failed.')
    $staged = $true

    $receipt = [ordered]@{
        schema_version = 1
        session_id = $sessionId
        staged_at = [DateTimeOffset]::Now.ToString('o')
        normal_quest_id = 200032001
        normal_quest_sha256 = $normalHashBefore
        calibration_quest_id = 200032002
        calibration_quest_sha256 = $calibrationHash
        equipment_writes = $false
        save_writes = $false
        focus_policy = 'acquire_once_abort_on_player_takeover'
        game_close_policy = if ($CloseGameAfterCalibration) { 'explicit_opt_in' } else { 'leave_running' }
    }
    $receipt | ConvertTo-Json -Depth 4 | Set-Content `
        -LiteralPath (Join-Path $artifactsRoot "$sessionId.staging.json") -Encoding utf8

    & (Join-Path $PSScriptRoot 'run_player_action_input_probe.ps1') `
        -GameRoot $resolvedGameRoot -Step $Step -InitialSettleSeconds $InitialSettleSeconds `
        -OutputPath $resolvedOutput -SkipDeployment
    $probeExitCode = $LASTEXITCODE
    if (Test-Path -LiteralPath $resolvedOutput -PathType Leaf) {
        $analysisOutput = [IO.Path]::ChangeExtension($resolvedOutput, '.analysis.json')
        $python = Resolve-VerifiedPython
        & $python (Join-Path $PSScriptRoot 'analyze_player_action_input_probe.py') `
            $resolvedOutput --output $analysisOutput | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Player action report analysis failed.' }
        Write-Host "Candidate analysis: $analysisOutput"
    }
} finally {
    try {
        if ($CloseGameAfterCalibration) {
            Stop-MonsterHunterRiseGracefully -TimeoutSeconds $GracefulExitTimeoutSeconds
        }
        Clear-TerminalProbeRequest
        if ($staged -and (Test-Path -LiteralPath $calibrationInstalled)) {
            $installedCalibrationHash = (Get-FileHash -LiteralPath $calibrationInstalled -Algorithm SHA256).Hash
            if ($installedCalibrationHash -ne $calibrationHash) {
                throw 'The staged calibration quest changed unexpectedly; it was preserved for investigation.'
            }
            Remove-Item -LiteralPath $calibrationInstalled -Force
        }
        $normalHashAfter = Assert-SameHash -Expected $normalSource -Actual $normalInstalled `
            -Message 'The normal Tigrex quest changed during calibration.'
        if ($normalHashAfter -ne $normalHashBefore) {
            throw 'The normal Tigrex quest hash changed during calibration.'
        }
    } catch {
        $cleanupError = $_
    }
}

if ($cleanupError) { throw $cleanupError }
if ($probeExitCode -ne 0) {
    throw "Player action calibration did not satisfy its evidence gate (exit code $probeExitCode). Report: $resolvedOutput"
}
Write-Host "Player action calibration completed; temporary Quest ID 200032002 was removed." -ForegroundColor Green
if (-not $CloseGameAfterCalibration) {
    Write-Host 'Monster Hunter Rise was left running; return to a normal quest through the game UI.' -ForegroundColor Green
}
Write-Host "Evidence: $resolvedOutput"
