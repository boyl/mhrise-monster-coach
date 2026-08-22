#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [int]$TimeoutSeconds = 900,
    [switch]$RequireCombatArea,
    [switch]$MonsterRespawn,
    [int[]]$ForcedActions = @(),
    [string]$TrainingScenarioId = '',
    [ValidateRange(1, 20)][int]$TrainingRepeatCount = 3,
    [switch]$BehaviorSurvey,
    [switch]$BehaviorDistanceSweep,
    [switch]$ConditionBranch,
    [switch]$NativeThinkBranch,
    [ValidateRange(300, 7200)][int]$BehaviorSurveyFrames = 3600,
    [switch]$ResumeExisting,
    [switch]$FullReport,
    [ValidateRange(10, 120)][int]$NavigationTimeoutSeconds = 45,
    [ValidateRange(5, 30)][int]$SurveyTimeoutSeconds = 12,
    [ValidateRange(5, 60)][int]$TransferTimeoutSeconds = 15
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'ArenaNavigation.psm1') -Force
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
$effectiveBehaviorSurvey = [bool]($BehaviorSurvey -or $BehaviorDistanceSweep)
$effectiveRequireCombatArea = [bool]($RequireCombatArea -or $effectiveBehaviorSurvey -or
    $ConditionBranch -or $NativeThinkBranch)

function Write-AtomicJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path, [int]$Depth = 6)
    $temporaryPath = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

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
$sessionId = $null
$request = $null
if ($ResumeExisting) {
    if (-not $game) { throw '-ResumeExisting requires a running game process.' }
    try { $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json } catch {
        throw '-ResumeExisting could not read the active probe request.'
    }
    try { $existingReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } catch {
        throw '-ResumeExisting could not read the active probe report.'
    }
    if (-not $request.session_id -or $existingReport.session_id -ne $request.session_id -or
        $existingReport.status -notin @('pending', 'running')) {
        throw '-ResumeExisting found no matching pending or running probe session.'
    }
    $sessionId = [string]$request.session_id
} else {
    $sessionId = [Guid]::NewGuid().ToString('N')
    $request = [ordered]@{
        schema_version = 1
        session_id = $sessionId
        kind = if ($TrainingScenarioId) { 'training_scenario_acceptance' }
            elseif ($ForcedActions.Count -gt 0) { 'forced_action_sequence' }
            elseif ($effectiveBehaviorSurvey) { 'behavior_path_survey' }
            elseif ($ConditionBranch) { 'condition_induced_branch' }
            elseif ($NativeThinkBranch) { 'native_think_branch' }
            elseif ($MonsterRespawn) { 'monster_respawn_lifecycle' }
            else { 'environment_creature_lifecycle' }
        requested_at = [DateTimeOffset]::Now.ToString('o')
        source_version = $sourceVersion
        auto_load_save = $true
        require_combat_area = $effectiveRequireCombatArea
        auto_native_arena_transfer = $false
        forced_actions = @($ForcedActions)
        training_scenario_id = $TrainingScenarioId
        training_repeat_count = $TrainingRepeatCount
        behavior_survey_frames = $BehaviorSurveyFrames
        target_root = if ($ConditionBranch) { 5000 } else { $null }
        target_distance = if ($ConditionBranch) { 7 } else { $null }
        condition_timeout_frames = if ($ConditionBranch) { 7200 } else { $null }
        think_reference = if ($NativeThinkBranch) { 'em032_combo_001.user' } else { $null }
        expected_successor = if ($NativeThinkBranch -or $ConditionBranch) { 5001 } else { $null }
        continue_on_action_failure = $ForcedActions.Count -gt 1
    }
    Write-AtomicJson -Value $request -Path $requestPath
    Write-AtomicJson -Value ([ordered]@{
        schema_version = 1
        session_id = $sessionId
        kind = $request.kind
        status = 'pending'
    }) -Path $reportPath
    Write-AtomicJson -Value ([ordered]@{
        schema_version = 1
        session_id = $sessionId
        action_id = ''
    }) -Path $bootstrapAckPath
}
if (-not $game) {
    Start-Process -FilePath 'steam://run/1446780'
    $launchedGame = $true
    Write-Host 'Game launched. The probe will wait for the offline hub, then enter the training quest automatically.'
} else {
    Write-Host $(if ($ResumeExisting) { 'Attached to the existing probe session.' }
        else { 'Probe request delivered to the running game.' })
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
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    public static bool PressKey(IntPtr gameWindow, byte virtualKey) {
        if (gameWindow == IntPtr.Zero || !SetForegroundWindow(gameWindow)) return false;
        System.Threading.Thread.Sleep(300);
        if (GetForegroundWindow() != gameWindow) return false;
        byte scanCode = (byte)MapVirtualKey(virtualKey, 0);
        if (scanCode == 0) return false;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        keybd_event(0, scanCode, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        System.Threading.Thread.Sleep(150);
        keybd_event(0, scanCode, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        return true;
    }
    public static bool IsForeground(IntPtr gameWindow) {
        return gameWindow != IntPtr.Zero && GetForegroundWindow() == gameWindow;
    }
    public static bool HoldKey(IntPtr gameWindow, byte virtualKey, int milliseconds) {
        if (gameWindow == IntPtr.Zero || !SetForegroundWindow(gameWindow)) return false;
        System.Threading.Thread.Sleep(300);
        if (GetForegroundWindow() != gameWindow) return false;
        byte scanCode = (byte)MapVirtualKey(virtualKey, 0);
        if (scanCode == 0) return false;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        keybd_event(0, scanCode, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        System.Threading.Thread.Sleep(Math.Max(100, milliseconds));
        keybd_event(0, scanCode, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        return true;
    }
    public static bool HoldKeys(IntPtr gameWindow, byte firstKey, byte secondKey, int milliseconds) {
        if (gameWindow == IntPtr.Zero || !SetForegroundWindow(gameWindow)) return false;
        System.Threading.Thread.Sleep(300);
        if (GetForegroundWindow() != gameWindow) return false;
        byte firstScan = (byte)MapVirtualKey(firstKey, 0);
        byte secondScan = (byte)MapVirtualKey(secondKey, 0);
        if (firstScan == 0 || secondScan == 0) return false;
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        keybd_event(0, secondScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        keybd_event(0, firstScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        System.Threading.Thread.Sleep(Math.Max(100, milliseconds));
        keybd_event(0, firstScan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        keybd_event(0, secondScan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        return true;
    }
    public static bool BeginHoldKeys(IntPtr gameWindow, byte firstKey, byte secondKey) {
        if (gameWindow == IntPtr.Zero || !SetForegroundWindow(gameWindow)) return false;
        System.Threading.Thread.Sleep(300);
        if (GetForegroundWindow() != gameWindow) return false;
        byte firstScan = (byte)MapVirtualKey(firstKey, 0);
        byte secondScan = (byte)MapVirtualKey(secondKey, 0);
        if (firstScan == 0 || secondScan == 0) return false;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        keybd_event(0, secondScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        keybd_event(0, firstScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        return true;
    }
    public static bool BeginHoldMovement(IntPtr gameWindow, byte primaryKey, byte secondaryKey) {
        if (gameWindow == IntPtr.Zero || !SetForegroundWindow(gameWindow)) return false;
        System.Threading.Thread.Sleep(300);
        if (GetForegroundWindow() != gameWindow) return false;
        byte sprintScan = (byte)MapVirtualKey(0x10, 0);
        byte primaryScan = (byte)MapVirtualKey(primaryKey, 0);
        byte secondaryScan = secondaryKey == 0 ? (byte)0 : (byte)MapVirtualKey(secondaryKey, 0);
        if (sprintScan == 0 || primaryScan == 0 || (secondaryKey != 0 && secondaryScan == 0)) return false;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        keybd_event(0, sprintScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        keybd_event(0, primaryScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        if (secondaryScan != 0 && secondaryScan != primaryScan) {
            keybd_event(0, secondaryScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        }
        return true;
    }
    public static void ReleaseMovement() {
        byte[] keys = new byte[] { 0x57, 0x41, 0x53, 0x44, 0x10 };
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        foreach (byte key in keys) {
            byte scan = (byte)MapVirtualKey(key, 0);
            if (scan != 0) keybd_event(0, scan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        }
    }
    public static void ReleaseKeys(byte firstKey, byte secondKey) {
        byte firstScan = (byte)MapVirtualKey(firstKey, 0);
        byte secondScan = (byte)MapVirtualKey(secondKey, 0);
        const uint KEYEVENTF_KEYUP = 0x0002;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        if (firstScan != 0) keybd_event(0, firstScan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
        if (secondScan != 0) keybd_event(0, secondScan, KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP, UIntPtr.Zero);
    }
}
'@
}

$sentBootstrapActions = [Collections.Generic.HashSet[string]]::new()
$uiCloseRequestedForActions = [Collections.Generic.HashSet[string]]::new()
$navigationGateStates = @('wait_stable', 'verify_restart', 'forced_recovery_verify', 'monster_respawn_recovery_verify')
$arenaNavigation = $null
$lastProbeState = $null
$combatRunHeld = $false
$combatRunKeys = $null
$lastDistanceSweepBand = $null

$virtualKeys = @{ W = [byte]0x57; A = [byte]0x41; S = [byte]0x53; D = [byte]0x44 }

function Stop-ArenaMovement {
    if ($script:combatRunHeld) {
        [MonsterCoachInput]::ReleaseMovement()
        $script:combatRunHeld = $false
        $script:combatRunKeys = $null
    }
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
try {
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
                    $inputDelay = [Math]::Max(0, [int]$bootstrap.action.delay_ms)
                    if ($inputDelay -gt 0) {
                        Start-Sleep -Milliseconds $inputDelay
                    }
                    if ([MonsterCoachInput]::PressKey($game.MainWindowHandle, [byte]$bootstrap.action.virtual_key)) {
                        [void]$sentBootstrapActions.Add([string]$bootstrap.action.id)
                        Write-AtomicJson -Value ([ordered]@{
                            schema_version = 1
                            session_id = $sessionId
                            action_id = [string]$bootstrap.action.id
                            sent_at = [DateTimeOffset]::Now.ToString('o')
                        }) -Path $bootstrapAckPath
                        Write-Host "Automatic startup input: $($bootstrap.action.id)"
                    }
                }
            }
        }
    }
    if (Test-Path -LiteralPath $reportPath) {
        try { $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } catch { $report = $null }
        $isNavigationReport = $effectiveRequireCombatArea -and $report -and
            $report.session_id -eq $sessionId -and $report.status -eq 'running' -and
            $report.state -in $navigationGateStates
        $isDistanceSweepReport = $BehaviorDistanceSweep -and $report -and
            $report.session_id -eq $sessionId -and $report.status -eq 'running' -and
            $report.state -eq 'behavior_survey'
        $isConditionBranchReport = $ConditionBranch -and $report -and
            $report.session_id -eq $sessionId -and $report.status -eq 'running' -and
            $report.state -eq 'condition_branch_seek'
        if (-not $isNavigationReport -and -not $isDistanceSweepReport -and
            -not $isConditionBranchReport) {
            Stop-ArenaMovement
            $arenaNavigation = $null
        } elseif ($isNavigationReport) {
            $stateKey = [string]$report.state
            if ($lastProbeState -ne $stateKey -or $null -eq $arenaNavigation) {
                Stop-ArenaMovement
                $arenaNavigation = [pscustomobject]@{
                    state = $stateKey
                    phase = 'navigate'
                    started_at = [datetimeoffset]::Now
                    interaction_sent_at = $null
                    initial_access_count = [int]($report.areas.arena_navigation.access_count ?? 0)
                    interaction_count = 0
                    last_distance = $null
                    best_distance = [double]::PositiveInfinity
                    last_progress_at = [datetimeoffset]::Now
                    replans = 0
                }
                Write-Host "Coordinate navigation started during $stateKey"
            }
            $game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $game) { throw 'Game process disappeared during arena navigation.' }
            $game.Refresh()
            if ($combatRunHeld -and -not [MonsterCoachInput]::IsForeground($game.MainWindowHandle)) {
                Stop-ArenaMovement
            }
            $command = Get-ArenaNavigationCommand -Areas $report.areas `
                -Phase $arenaNavigation.phase -InteractionSentAt $arenaNavigation.interaction_sent_at `
                -TransferTimeoutSeconds $TransferTimeoutSeconds
            switch ($command.Action) {
                'complete' {
                    Stop-ArenaMovement
                }
                'interact' {
                    Stop-ArenaMovement
                    if ($arenaNavigation.interaction_count -ne 0) {
                        throw "Arena navigation invariant failed: F was already sent during $stateKey"
                    }
                    if (-not [MonsterCoachInput]::PressKey($game.MainWindowHandle, 0x46)) {
                        throw "Could not focus the game and send the single native F interaction during $stateKey"
                    }
                    $arenaNavigation.phase = 'transfer_pending'
                    $arenaNavigation.interaction_sent_at = [datetimeoffset]::Now
                    $arenaNavigation.interaction_count = 1
                    Write-Host "Single native F interaction sent during $stateKey; movement locked pending transfer"
                }
                'hold' {
                    $elapsed = ([datetimeoffset]::Now - $arenaNavigation.started_at).TotalSeconds
                    if ($elapsed -ge $NavigationTimeoutSeconds) {
                        Stop-ArenaMovement
                        throw "Coordinate navigation did not reach the transfer marker within $NavigationTimeoutSeconds seconds"
                    }
                    if ($command.Distance -lt $arenaNavigation.best_distance - 0.25) {
                        $arenaNavigation.best_distance = $command.Distance
                        $arenaNavigation.last_progress_at = [datetimeoffset]::Now
                    } elseif (([datetimeoffset]::Now - $arenaNavigation.last_progress_at).TotalSeconds -ge 4) {
                        if ($arenaNavigation.replans -lt 1) {
                            Stop-ArenaMovement
                            $arenaNavigation.replans++
                            $arenaNavigation.best_distance = [double]::PositiveInfinity
                            $arenaNavigation.last_progress_at = [datetimeoffset]::Now
                            Write-Host "Arena navigation: bounded replan after stalled movement at $([Math]::Round($command.Distance, 2)) m"
                            Start-Sleep -Milliseconds 750
                            continue
                        }
                        Stop-ArenaMovement
                        throw "Coordinate navigation made no progress after one bounded replan (distance $([Math]::Round($command.Distance, 2)))"
                    }
                    $desiredKeys = "$($command.Primary)+$($command.Secondary)"
                    if (-not $combatRunHeld -or $combatRunKeys -ne $desiredKeys) {
                        Stop-ArenaMovement
                        $primaryKey = $virtualKeys[[string]$command.Primary]
                        $secondaryKey = if ($command.Secondary) {
                            $virtualKeys[[string]$command.Secondary]
                        } else { [byte]0 }
                        if (-not [MonsterCoachInput]::BeginHoldMovement(
                            $game.MainWindowHandle, $primaryKey, $secondaryKey)) {
                            throw "Could not focus the game and hold coordinate navigation input $desiredKeys"
                        }
                        $combatRunHeld = $true
                        $combatRunKeys = $desiredKeys
                        Write-Host "Arena navigation: $desiredKeys at $([Math]::Round($command.Distance, 2)) m"
                    }
                    $arenaNavigation.last_distance = $command.Distance
                }
                'survey' {
                    $elapsed = ([datetimeoffset]::Now - $arenaNavigation.started_at).TotalSeconds
                    if ($elapsed -ge $SurveyTimeoutSeconds) {
                        Stop-ArenaMovement
                        throw "No native area-move marker was discovered within the bounded $SurveyTimeoutSeconds-second map survey"
                    }
                    $desiredKeys = 'W+'
                    if (-not $combatRunHeld -or $combatRunKeys -ne $desiredKeys) {
                        Stop-ArenaMovement
                        if (-not [MonsterCoachInput]::BeginHoldMovement(
                            $game.MainWindowHandle, $virtualKeys.W, [byte]0)) {
                            throw 'Could not focus the game and start the bounded map survey'
                        }
                        $combatRunHeld = $true
                        $combatRunKeys = $desiredKeys
                        Write-Host 'Arena map survey: W along the measured camera-forward ray'
                    }
                }
                'wait' {
                    Stop-ArenaMovement
                }
                'fail' {
                    Stop-ArenaMovement
                    throw "Arena navigation failed: $($command.Reason)"
                }
                default {
                    Stop-ArenaMovement
                    throw "Unknown arena navigation action '$($command.Action)'"
                }
            }
            $lastProbeState = $stateKey
        }
        if ($isDistanceSweepReport) {
            $sample = [int]($report.behavior_survey.samples ?? 0)
            $band = if ($sample -lt [Math]::Floor($BehaviorSurveyFrames / 3)) { 'near-1' }
                elseif ($sample -lt [Math]::Floor(2 * $BehaviorSurveyFrames / 3)) { 'far' }
                else { 'near-2' }
            $targetDistance = if ($band -eq 'far') { 28.0 } else { 7.0 }
            if ($lastDistanceSweepBand -ne $band) {
                $lastDistanceSweepBand = $band
                Write-Host "Behavior distance sweep: $band target=$targetDistance m"
            }
            $player = $report.areas.player_position
            $enemy = $report.areas.enemy_position
            if ($null -ne $player -and $null -ne $enemy) {
                $dx = [double]$enemy.x - [double]$player.x
                $dz = [double]$enemy.z - [double]$player.z
                $distance = [Math]::Sqrt($dx * $dx + $dz * $dz)
                $moveToward = $distance -gt $targetDistance + 2.0
                $moveAway = $distance -lt $targetDistance - 2.0
                if ($moveToward -or $moveAway) {
                    if ($moveAway) { $dx = -$dx; $dz = -$dz }
                    $command = Get-WorldVectorMovementCommand -Areas $report.areas -DeltaX $dx -DeltaZ $dz
                    $desiredKeys = "$($command.Primary)+$($command.Secondary)"
                    if ($command.Action -eq 'hold' -and
                        (-not $combatRunHeld -or $combatRunKeys -ne $desiredKeys)) {
                        Stop-ArenaMovement
                        $secondaryKey = if ($command.Secondary) {
                            $virtualKeys[[string]$command.Secondary]
                        } else { [byte]0 }
                        if (-not [MonsterCoachInput]::BeginHoldMovement(
                            $game.MainWindowHandle, $virtualKeys[[string]$command.Primary], $secondaryKey)) {
                            throw "Could not apply behavior distance sweep input $desiredKeys"
                        }
                        $combatRunHeld = $true
                        $combatRunKeys = $desiredKeys
                        Write-Host "Behavior distance sweep: $desiredKeys distance=$([Math]::Round($distance, 2)) m"
                    }
                } else {
                    Stop-ArenaMovement
                }
            }
        }
        if ($isConditionBranchReport) {
            $player = $report.areas.player_position
            $enemy = $report.areas.enemy_position
            $targetDistance = [double]$report.condition_branch.target_distance
            $tolerance = [double]$report.condition_branch.tolerance
            if ($null -ne $player -and $null -ne $enemy) {
                $dx = [double]$enemy.x - [double]$player.x
                $dz = [double]$enemy.z - [double]$player.z
                $distance = [Math]::Sqrt($dx * $dx + $dz * $dz)
                $moveToward = $distance -gt $targetDistance + $tolerance
                $moveAway = $distance -lt $targetDistance - $tolerance
                if ($moveToward -or $moveAway) {
                    if ($moveAway) { $dx = -$dx; $dz = -$dz }
                    $command = Get-WorldVectorMovementCommand -Areas $report.areas -DeltaX $dx -DeltaZ $dz
                    $desiredKeys = "$($command.Primary)+$($command.Secondary)"
                    if ($command.Action -eq 'hold' -and
                        (-not $combatRunHeld -or $combatRunKeys -ne $desiredKeys)) {
                        Stop-ArenaMovement
                        $secondaryKey = if ($command.Secondary) {
                            $virtualKeys[[string]$command.Secondary]
                        } else { [byte]0 }
                        if (-not [MonsterCoachInput]::BeginHoldMovement(
                            $game.MainWindowHandle, $virtualKeys[[string]$command.Primary], $secondaryKey)) {
                            throw "Could not apply condition-induction movement $desiredKeys"
                        }
                        $combatRunHeld = $true
                        $combatRunKeys = $desiredKeys
                        Write-Host "Condition induction: $desiredKeys distance=$([Math]::Round($distance, 2)) m"
                    }
                } else {
                    Stop-ArenaMovement
                }
            }
        }
        if ($report -and ($report.session_id -eq $sessionId) -and
            ($report.status -in @('completed', 'failed'))) {
            Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
            if ($FullReport) {
                $report | ConvertTo-Json -Depth 12
            } else {
                [ordered]@{
                    session_id = $report.session_id
                    kind = $report.kind
                    status = $report.status
                    reason = $report.reason
                    frames = $report.frames
                    condition_branch = $report.condition_branch
                    behavior_survey = if ($report.behavior_survey) { [ordered]@{
                        samples = $report.behavior_survey.samples
                        events = @($report.behavior_survey.events).Count
                        nodes = @($report.behavior_survey.nodes).Count
                        edges = @($report.behavior_survey.edges).Count
                    } } else { $null }
                } | ConvertTo-Json -Depth 8
            }
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
}
finally {
    Stop-ArenaMovement
}
