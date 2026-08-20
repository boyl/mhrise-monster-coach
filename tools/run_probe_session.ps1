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
$bootstrapStatusPath = Join-Path $dataRoot 'startup_bootstrap_status.json'
$bootstrapAckPath = Join-Path $dataRoot 'startup_bootstrap_ack.json'
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
    auto_load_save = $true
}
$request | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $requestPath -Encoding utf8
[ordered]@{
    schema_version = 1
    session_id = $sessionId
    kind = 'environment_creature_lifecycle'
    status = 'pending'
} | ConvertTo-Json | Set-Content -LiteralPath $reportPath -Encoding utf8
[ordered]@{
    schema_version = 1
    session_id = $sessionId
    action_id = ''
} | ConvertTo-Json | Set-Content -LiteralPath $bootstrapAckPath -Encoding utf8

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

if (-not ('MonsterCoachInput' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MonsterCoachInput {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static bool PressKey(IntPtr gameWindow, byte virtualKey) {
        if (gameWindow == IntPtr.Zero || !SetForegroundWindow(gameWindow)) return false;
        if (GetForegroundWindow() != gameWindow) return false;
        keybd_event(virtualKey, 0, 0, UIntPtr.Zero);
        System.Threading.Thread.Sleep(120);
        keybd_event(virtualKey, 0, 2, UIntPtr.Zero);
        return true;
    }
}
'@
}

$sentBootstrapActions = [Collections.Generic.HashSet[string]]::new()
$uiCloseRequestedForActions = [Collections.Generic.HashSet[string]]::new()

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
do {
    if (Test-Path -LiteralPath $bootstrapStatusPath) {
        try { $bootstrap = Get-Content -LiteralPath $bootstrapStatusPath -Raw | ConvertFrom-Json } catch { $bootstrap = $null }
        if ($bootstrap -and $bootstrap.session_id -eq $sessionId) {
            if ($bootstrap.status -eq 'failed') {
                throw "Automatic Continue/save bootstrap failed: $($bootstrap.reason)"
            }
            if ($bootstrap.status -eq 'input_required' -and $bootstrap.action.kind -eq 'press_key' -and
                -not $sentBootstrapActions.Contains([string]$bootstrap.action.id)) {
                $game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($game) {
                    $game.Refresh()
                    if ($bootstrap.diagnostics.reframework_ui_open -eq $true) {
                        if (-not $uiCloseRequestedForActions.Contains([string]$bootstrap.action.id) -and
                            [MonsterCoachInput]::PressKey($game.MainWindowHandle, 0x2D)) {
                            [void]$uiCloseRequestedForActions.Add([string]$bootstrap.action.id)
                            Write-Host 'Automatic startup input: closing REFramework UI'
                        }
                        Start-Sleep -Milliseconds 250
                        continue
                    }
                    if ([MonsterCoachInput]::PressKey($game.MainWindowHandle, [byte]$bootstrap.action.virtual_key)) {
                        [void]$sentBootstrapActions.Add([string]$bootstrap.action.id)
                        [ordered]@{
                            schema_version = 1
                            session_id = $sessionId
                            action_id = [string]$bootstrap.action.id
                            sent_at = [DateTimeOffset]::Now.ToString('o')
                        } | ConvertTo-Json | Set-Content -LiteralPath $bootstrapAckPath -Encoding utf8
                        Write-Host "Automatic startup input: $($bootstrap.action.id)"
                    }
                }
            }
        }
    }
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
    Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)

throw "Probe session timed out after $TimeoutSeconds seconds. Request retained at $requestPath"
