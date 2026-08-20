#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [int]$TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedGameRoot = [IO.Path]::GetFullPath($GameRoot)
$dataRoot = Join-Path $resolvedGameRoot 'reframework\data\MHRiseMonsterCoach'
$requestPath = Join-Path $dataRoot 'dev_probe_request.json'
$reportPath = Join-Path $dataRoot 'dev_probe_report.json'
$receiptPath = Join-Path $dataRoot 'dev_install_receipt.json'
$sourceVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
$game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
$launchedGame = $false

if ($game) {
    $installedVersion = if (Test-Path -LiteralPath $receiptPath) {
        (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).version
    }
    if ($installedVersion -ne $sourceVersion) {
        throw "The game is running version '$installedVersion' but the probe requires '$sourceVersion'. Close the game once for deployment."
    }
} else {
    & (Join-Path $PSScriptRoot 'deploy_dev.ps1') -GameRoot $resolvedGameRoot
    if (-not $?) { throw 'Probe deployment failed.' }
}

if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
}
$sessionId = [Guid]::NewGuid().ToString('N')
$request = [ordered]@{
    schema_version = 1
    session_id = $sessionId
    kind = 'environment_creature_lifecycle'
    requested_at = [DateTimeOffset]::Now.ToString('o')
    source_version = $sourceVersion
}
$request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $requestPath -Encoding utf8

if (-not $game) {
    Start-Process -FilePath 'steam://run/1446780'
    $launchedGame = $true
    Write-Host 'Game launched. The probe will wait for the offline hub, then enter the training quest automatically.'
} else {
    Write-Host 'Probe request delivered to the running game.'
}
Write-Host "Session: $sessionId"

if ($launchedGame) {
    $startupDeadline = (Get-Date).AddSeconds(90)
    do {
        $game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($game) { break }
        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $startupDeadline)
    if (-not $game) { throw 'Steam accepted the launch request, but the game process did not start within 90 seconds.' }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    if (Test-Path -LiteralPath $reportPath) {
        try { $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } catch { $report = $null }
        if ($report -and ($report.session_id -eq $sessionId) -and
            ($report.status -in @('completed', 'failed'))) {
            Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
            $report | ConvertTo-Json -Depth 12
            if ($report.status -eq 'failed') { exit 2 }
            exit 0
        }
    }
    if (-not (Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue)) {
        throw 'The game exited before the probe report was completed.'
    }
    Start-Sleep -Seconds 2
} while ((Get-Date) -lt $deadline)

throw "Probe session timed out after $TimeoutSeconds seconds. Request retained at $requestPath"
