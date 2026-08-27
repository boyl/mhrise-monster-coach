#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [string[]]$Step = @(),
    [ValidateRange(5, 20)][int]$InitialSettleSeconds = 12,
    [ValidateRange(10, 45)][int]$GracefulExitTimeoutSeconds = 25,
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

Stop-MonsterHunterRiseGracefully -TimeoutSeconds $GracefulExitTimeoutSeconds
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
    }
    $receipt | ConvertTo-Json -Depth 4 | Set-Content `
        -LiteralPath (Join-Path $artifactsRoot "$sessionId.staging.json") -Encoding utf8

    & (Join-Path $PSScriptRoot 'run_player_action_input_probe.ps1') `
        -GameRoot $resolvedGameRoot -Step $Step -InitialSettleSeconds $InitialSettleSeconds `
        -OutputPath $resolvedOutput -SkipDeployment
    $probeExitCode = $LASTEXITCODE
} finally {
    try {
        Stop-MonsterHunterRiseGracefully -TimeoutSeconds $GracefulExitTimeoutSeconds
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
Write-Host "Evidence: $resolvedOutput"
