#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [int]$TimeoutSeconds = 900,
    [switch]$RequireCombatArea,
    [switch]$MonsterRespawn,
    [string[]]$ForcedActions = @(),
    [string]$TrainingScenarioId = '',
    [ValidateRange(1, 20)][int]$TrainingRepeatCount = 3,
    [ValidateRange(0, 60)][double]$TrainingPrePositionDistance = 0,
    [ValidateRange(0.5, 10)][double]$TrainingPrePositionTolerance = 2,
    [ValidateSet('none', 'dodge')][string]$TrainingResponseStep = 'none',
    [switch]$BehaviorSurvey,
    [switch]$BehaviorDistanceSweep,
    [ValidateRange(1, 60)][double]$BehaviorSweepNearDistance = 7.0,
    [ValidateRange(1, 60)][double]$BehaviorSweepFarDistance = 28.0,
    [ValidateRange(1, 20)][int]$BehaviorSweepCycles = 1,
    [switch]$ConditionBranch,
    [switch]$InputMotionMetadata,
    [switch]$SemanticInputTrigger,
    [switch]$PlayerActionEvidence,
    [switch]$InputMotionAxisWrite,
    [switch]$UiContract,
    [switch]$NativeThinkBranch,
    [ValidateRange(300, 7200)][int]$BehaviorSurveyFrames = 3600,
    [switch]$ResumeExisting,
    [switch]$SkipDeployment,
    [switch]$FullReport,
    [ValidateRange(10, 120)][int]$NavigationTimeoutSeconds = 45,
    [ValidateRange(5, 30)][int]$SurveyTimeoutSeconds = 12,
    [ValidateRange(5, 60)][int]$TransferTimeoutSeconds = 15,
    [string]$ProbeArchiveRoot = ''
)

$ErrorActionPreference = 'Stop'
$normalizedForcedActions = @()
foreach ($rawForcedAction in $ForcedActions) {
    foreach ($token in ([string]$rawForcedAction -split ',')) {
        $parsedAction = 0
        if (-not [int]::TryParse($token.Trim(), [ref]$parsedAction)) {
            throw "ForcedActions contains an invalid Action ID: '$token'"
        }
        $normalizedForcedActions += $parsedAction
    }
}
$ForcedActions = @($normalizedForcedActions)
if ($TrainingPrePositionDistance -gt 0 -and [string]::IsNullOrWhiteSpace($TrainingScenarioId)) {
    throw '-TrainingPrePositionDistance requires -TrainingScenarioId.'
}
if ($SemanticInputTrigger -and ($UiContract -or $MonsterRespawn -or
        $ForcedActions.Count -gt 0 -or -not [string]::IsNullOrWhiteSpace($TrainingScenarioId) -or
        $BehaviorSurvey -or $BehaviorDistanceSweep -or $ConditionBranch -or
        $InputMotionMetadata -or $PlayerActionEvidence -or $InputMotionAxisWrite -or
        $NativeThinkBranch)) {
    throw '-SemanticInputTrigger is an isolated probe mode and cannot be combined with another probe kind.'
}
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedArchiveRoot = if ([string]::IsNullOrWhiteSpace($ProbeArchiveRoot)) {
    Join-Path $repositoryRoot 'artifacts\probe_reports'
} else {
    [IO.Path]::GetFullPath($ProbeArchiveRoot)
}
Import-Module (Join-Path $PSScriptRoot 'ArenaNavigation.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'DiagnosticScriptIsolation.psm1') -Force
$responseEnabled = $TrainingResponseStep -ne 'none'
$responseContract = $null
if ($responseEnabled) {
    if ([string]::IsNullOrWhiteSpace($TrainingScenarioId)) {
        throw '-TrainingResponseStep requires -TrainingScenarioId.'
    }
    if ($ResumeExisting) {
        throw '-TrainingResponseStep cannot resume a historical session because at-most-once input state is process-local.'
    }
    Import-Module (Join-Path $PSScriptRoot 'TrainingResponseAcceptance.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'PlayerActionInput.psm1') -Force
    $responseContract = Get-MonsterCoachTrainingResponseContract `
        -ScenarioId $TrainingScenarioId -ResponseStep $TrainingResponseStep `
        -RepeatCount $TrainingRepeatCount
}
$resolvedGameRoot = [IO.Path]::GetFullPath($GameRoot)
$dataRoot = Join-Path $resolvedGameRoot 'reframework\data\MHRiseMonsterCoach'
$requestPath = Join-Path $dataRoot 'dev_probe_request.json'
$reportPath = Join-Path $dataRoot 'dev_probe_report.json'
$lifecyclePath = Join-Path $dataRoot 'dev_probe_lifecycle_status.json'
$bootstrapStatusPath = Join-Path $dataRoot 'startup_bootstrap_status.json'
$bootstrapAckPath = Join-Path $dataRoot 'startup_bootstrap_ack.json'
$receiptPath = Join-Path $dataRoot 'dev_install_receipt.json'
$sourceVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
$game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
$launchedGame = $false
$effectiveBehaviorSurvey = [bool]($BehaviorSurvey -or $BehaviorDistanceSweep)
$effectiveRequireCombatArea = [bool]($RequireCombatArea -or $effectiveBehaviorSurvey -or
    $ConditionBranch -or $NativeThinkBranch -or $PlayerActionEvidence -or
    $SemanticInputTrigger -or
    $ForcedActions.Count -gt 0 -or $MonsterRespawn -or
    -not [string]::IsNullOrWhiteSpace($TrainingScenarioId))

function Write-AtomicJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path, [int]$Depth = 6)
    $temporaryPath = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth $Depth | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        # Move-Item -Force still refuses to replace an existing destination on
        # some Windows/PowerShell combinations. .NET 6+ maps this overload to
        # an overwrite-capable same-volume move while keeping the temp-file
        # boundary used by the game-side JSON reader.
        [IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
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

function Invoke-ProbeAnalysis {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$ArchivePath,
        [string]$ResponseEvidencePath = '',
        [switch]$Recovered
    )
    $analysis = switch ([string]$Report.kind) {
        'input_motion_metadata' { [ordered]@{
            Script = 'analyze_semantic_input_contract.py'
            Label = 'Semantic input'
        }; break }
        'semantic_input_trigger' { [ordered]@{
            Script = 'analyze_semantic_trigger.py'
            Label = 'Semantic trigger'
        }; break }
        'training_scenario_acceptance' { [ordered]@{
            Script = 'analyze_training_timeline_acceptance.py'
            Label = 'Training timeline'
        }; break }
        default { $null }
    }
    if ($null -eq $analysis) { return $null }

    $analysisPath = [IO.Path]::ChangeExtension($ArchivePath, '.analysis.json')
    $python = Resolve-VerifiedPython
    $analysisArguments = @($ArchivePath, '--output', $analysisPath)
    if ($Report.kind -eq 'training_scenario_acceptance' -and
        -not [string]::IsNullOrWhiteSpace($ResponseEvidencePath)) {
        $analysisArguments += @('--response-evidence', $ResponseEvidencePath)
    }
    & $python (Join-Path $PSScriptRoot $analysis.Script) @analysisArguments
    if ($LASTEXITCODE -ne 0) {
        throw "$($analysis.Label) analysis failed with exit code $LASTEXITCODE."
    }
    $suffix = if ($Recovered) { ' recovered' } else { '' }
    Write-Host "$($analysis.Label) analysis$suffix`: $analysisPath"
    if ($Report.kind -eq 'training_scenario_acceptance') {
        $overlayAnalysisPath = [IO.Path]::ChangeExtension(
            $ArchivePath, '.overlay.analysis.json')
        $null = & $python (Join-Path $PSScriptRoot 'analyze_overlay_acceptance.py') `
            $ArchivePath '--output' $overlayAnalysisPath
        $overlayExitCode = $LASTEXITCODE
        if ($overlayExitCode -ne 0) {
            throw "Measured overlay analysis failed with exit code $overlayExitCode."
        }
        Write-Host "Measured overlay analysis$suffix`: $overlayAnalysisPath"
    }
    return $analysisPath
}

function Test-ProbeTerminal {
    try {
        $latest = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        return $latest.session_id -eq $sessionId -and $latest.status -in @('completed', 'failed')
    } catch {
        return $false
    }
}

$diagnosticIsolation = @()
try {
if ($game) {
    $installedVersion = if (Test-Path -LiteralPath $receiptPath) {
        (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).version
    }
    if ($installedVersion -ne $sourceVersion) {
        throw "The game is running version '$installedVersion' but the probe requires '$sourceVersion'. Close the game once for deployment."
    }
} else {
    if ($SkipDeployment) {
        if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
            throw '-SkipDeployment requires an existing verified development receipt.'
        }
        $installedVersion = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).version
        if ($installedVersion -ne $sourceVersion) {
            throw "-SkipDeployment refused source '$sourceVersion' over installed '$installedVersion'."
        }
    } else {
        & (Join-Path $PSScriptRoot 'deploy_dev.ps1') -GameRoot $resolvedGameRoot
        if (-not $?) { throw 'Probe deployment failed.' }
    }
}

if (-not (Test-Path -LiteralPath $dataRoot -PathType Container)) {
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
}
$sessionId = $null
$request = $null
$resumedTerminalReport = $null
if ($ResumeExisting) {
    if (-not $game) { throw '-ResumeExisting requires a running game process.' }
    try { $request = Get-Content -LiteralPath $requestPath -Raw | ConvertFrom-Json } catch {
        throw '-ResumeExisting could not read the active probe request.'
    }
    try { $existingReport = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json } catch {
        throw '-ResumeExisting could not read the active probe report.'
    }
    if (-not $request.session_id -or $existingReport.session_id -ne $request.session_id -or
        $existingReport.status -notin @('pending', 'running', 'completed', 'failed')) {
        throw '-ResumeExisting found no matching active or terminal probe session.'
    }
    $sessionId = [string]$request.session_id
    if ($existingReport.status -in @('completed', 'failed')) {
        $resumedTerminalReport = $existingReport
    }
} else {
    $sessionId = [Guid]::NewGuid().ToString('N')
    $request = [ordered]@{
        schema_version = 1
        session_id = $sessionId
        kind = if ($UiContract) { 'ui_contract_snapshot' }
            elseif ($TrainingScenarioId) { 'training_scenario_acceptance' }
            elseif ($ForcedActions.Count -gt 0) { 'forced_action_sequence' }
            elseif ($effectiveBehaviorSurvey) { 'behavior_path_survey' }
            elseif ($ConditionBranch) { 'condition_induced_branch' }
            elseif ($InputMotionMetadata) { 'input_motion_metadata' }
            elseif ($SemanticInputTrigger) { 'semantic_input_trigger' }
            elseif ($PlayerActionEvidence) { 'player_action_evidence' }
            elseif ($InputMotionAxisWrite) { 'input_motion_axis_write' }
            elseif ($NativeThinkBranch) { 'native_think_branch' }
            elseif ($MonsterRespawn) { 'monster_respawn_lifecycle' }
            else { 'environment_creature_lifecycle' }
        target_quest_id = if ($PlayerActionEvidence) { 200032002 } else { 200032001 }
        requested_at = [DateTimeOffset]::Now.ToString('o')
        source_version = $sourceVersion
        auto_load_save = -not $UiContract
        require_combat_area = $effectiveRequireCombatArea
        auto_native_arena_transfer = $false
        forced_actions = @($ForcedActions)
        training_scenario_id = $TrainingScenarioId
        training_repeat_count = $TrainingRepeatCount
        training_preposition_distance = if ($TrainingPrePositionDistance -gt 0) {
            $TrainingPrePositionDistance
        } else { $null }
        training_preposition_tolerance = if ($TrainingPrePositionDistance -gt 0) {
            $TrainingPrePositionTolerance
        } else { $null }
        training_response_step = $TrainingResponseStep
        behavior_survey_frames = $BehaviorSurveyFrames
        target_root = if ($ConditionBranch) { 5000 } else { $null }
        target_distance = if ($ConditionBranch) { 7 } else { $null }
        condition_timeout_frames = if ($ConditionBranch) { 7200 } else { $null }
        axis_x = if ($InputMotionAxisWrite) { 0 } else { $null }
        axis_y = if ($InputMotionAxisWrite) { 1 } else { $null }
        axis_frames = if ($InputMotionAxisWrite) { 60 } else { $null }
        semantic_command = if ($SemanticInputTrigger) { 'Escape' } else { $null }
        think_reference = if ($NativeThinkBranch) { 'em032_combo_001.user' } else { $null }
        expected_successor = if ($NativeThinkBranch -or $ConditionBranch) { 5001 } else { $null }
        continue_on_action_failure = $ForcedActions.Count -gt 1
        ui_requested_repeats = if ($UiContract) { 5 } else { $null }
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
    $diagnosticIsolation = @(Suspend-MonsterCoachKnownDiagnosticScripts `
        -AutorunRoot (Join-Path $resolvedGameRoot 'reframework\autorun') `
        -SessionId $sessionId)
    if ($diagnosticIsolation.Count -gt 0) {
        Write-Host "Temporarily isolated $($diagnosticIsolation.Count) known diagnostic autorun loader(s)."
    }
    Start-Process -FilePath 'steam://run/1446780'
    $launchedGame = $true
    Write-Host $(if ($UiContract) { 'Game launched. The UI contract probe will complete before loading a save.' }
        else { 'Game launched. The probe will wait for the offline hub, then enter the training quest automatically.' })
} else {
    Write-Host $(if ($ResumeExisting) { 'Attached to the existing probe session.' }
        else { 'Probe request delivered to the running game.' })
}
Write-Host "Session: $sessionId"

if ($resumedTerminalReport) {
    New-Item -ItemType Directory -Path $resolvedArchiveRoot -Force | Out-Null
    $safeKind = ([string]$resumedTerminalReport.kind) -replace '[^A-Za-z0-9_.-]', '_'
    $archivePath = Join-Path $resolvedArchiveRoot `
        "$($resumedTerminalReport.session_id).$safeKind.$($resumedTerminalReport.status).json"
    Copy-Item -LiteralPath $reportPath -Destination $archivePath -Force
    Write-Host "Terminal probe report recovered: $archivePath"
    Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
    $analysisPath = Invoke-ProbeAnalysis -Report $resumedTerminalReport `
        -ArchivePath $archivePath -Recovered
    if ($FullReport) {
        $resumedTerminalReport | ConvertTo-Json -Depth 12
    } else {
        [ordered]@{
            session_id = $resumedTerminalReport.session_id
            kind = $resumedTerminalReport.kind
            status = $resumedTerminalReport.status
            reason = $resumedTerminalReport.reason
            recovered_terminal = $true
            analysis = $analysisPath
        } | ConvertTo-Json
    }
    if ($resumedTerminalReport.status -eq 'failed') { exit 2 }
    exit 0
}

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
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr SetFocus(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindowAsync(IntPtr hWnd, int command);
    [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint mapType);
    [DllImport("user32.dll")] static extern void keybd_event(byte key, byte scan, uint flags, UIntPtr extra);
    static bool FocusWindow(IntPtr gameWindow) {
        if (gameWindow == IntPtr.Zero) return false;
        IntPtr foreground = GetForegroundWindow();
        if (foreground != gameWindow) {
            uint processId;
            uint foregroundThread = GetWindowThreadProcessId(foreground, out processId);
            uint currentThread = GetCurrentThreadId();
            bool attached = foregroundThread != 0 && AttachThreadInput(currentThread, foregroundThread, true);
            try {
                ShowWindowAsync(gameWindow, 9);
                BringWindowToTop(gameWindow);
                SetForegroundWindow(gameWindow);
                SetFocus(gameWindow);
            } finally {
                if (attached) AttachThreadInput(currentThread, foregroundThread, false);
            }
        }
        System.Threading.Thread.Sleep(300);
        return GetForegroundWindow() == gameWindow;
    }
    public static bool PressKey(IntPtr gameWindow, byte virtualKey) {
        if (!FocusWindow(gameWindow)) return false;
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
        if (!FocusWindow(gameWindow)) return false;
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
        if (!FocusWindow(gameWindow)) return false;
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
        if (!FocusWindow(gameWindow)) return false;
        byte firstScan = (byte)MapVirtualKey(firstKey, 0);
        byte secondScan = (byte)MapVirtualKey(secondKey, 0);
        if (firstScan == 0 || secondScan == 0) return false;
        const uint KEYEVENTF_SCANCODE = 0x0008;
        keybd_event(0, secondScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        keybd_event(0, firstScan, KEYEVENTF_SCANCODE, UIntPtr.Zero);
        return true;
    }
    public static bool BeginHoldMovement(IntPtr gameWindow, byte primaryKey, byte secondaryKey) {
        if (!FocusWindow(gameWindow)) return false;
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
$startupUiClosedProactively = $false
$startupTitleZeroFallbackSent = $false
$startupUiClosedAt = $null
$navigationGateStates = @('wait_stable', 'verify_restart', 'forced_recovery_verify',
    'monster_respawn_recovery_verify', 'behavior_survey_reenter',
    'training_acceptance_reenter')
$arenaNavigation = $null
$lastProbeState = $null
$combatRunHeld = $false
$combatRunKeys = $null
$lastDistanceSweepBand = $null
$distanceSweepPlan = $null
$responseAttemptedRounds = [Collections.Generic.HashSet[string]]::new()
$responseAttempts = [Collections.Generic.List[object]]::new()
$responseDefinition = $null
$responseFailure = $null

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
            if (-not $startupUiClosedProactively -and
                $bootstrap.status -in @('running', 'input_required') -and
                $bootstrap.diagnostics.reframework_ui_open -eq $true) {
                $game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($game -and [MonsterCoachInput]::PressKey($game.MainWindowHandle, 0x2D)) {
                    $startupUiClosedProactively = $true
                    $startupUiClosedAt = [datetimeoffset]::Now
                    Write-Host 'Automatic startup input: proactively closing REFramework UI'
                    Start-Sleep -Milliseconds 250
                    continue
                }
            }
            if (-not $startupUiClosedProactively -and
                $bootstrap.status -eq 'running' -and
                $bootstrap.diagnostics.reframework_ui_open -eq $false) {
                $startupUiClosedProactively = $true
                $startupUiClosedAt = [datetimeoffset]::Now
            }
            if ($startupUiClosedProactively -and -not $startupTitleZeroFallbackSent -and
                $bootstrap.status -eq 'running' -and
                [int]$bootstrap.diagnostics.title_state -eq 0 -and
                $bootstrap.diagnostics.autosave_notice_seen -ne $true -and
                $null -ne $startupUiClosedAt -and
                ([datetimeoffset]::Now - $startupUiClosedAt).TotalSeconds -ge 2) {
                $game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($game -and [MonsterCoachInput]::PressKey($game.MainWindowHandle, 0x46)) {
                    $startupTitleZeroFallbackSent = $true
                    Write-Host 'Automatic startup input: one bounded title-state-0 F fallback'
                    Start-Sleep -Milliseconds 250
                    continue
                }
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
        $isConditionTrainingReport = $TrainingScenarioId -and $report -and
            $report.session_id -eq $sessionId -and $report.status -eq 'running' -and
            $report.state -eq 'training_acceptance_wait' -and
            $report.training_acceptance.execution_mode -eq 'natural_condition' -and
            $report.training_acceptance.state -eq 'positioning'
        $isAcceptancePrePositionReport = $TrainingScenarioId -and $report -and
            $report.session_id -eq $sessionId -and $report.status -eq 'running' -and
            $report.state -eq 'training_acceptance_preposition' -and
            $report.training_acceptance.execution_mode -eq 'acceptance_preposition' -and
            $report.training_acceptance.state -eq 'positioning'
        $isResponseReport = $responseEnabled -and $report -and
            $report.session_id -eq $sessionId -and $report.status -eq 'running' -and
            $report.state -eq 'training_acceptance_wait'
        if ($isResponseReport -and $null -eq $responseFailure) {
            if ($null -eq $responseDefinition -and $report.input_motion -and $report.player_action) {
                try {
                    if ([string]$report.player_action.weapon_type -ne
                        [string]$responseContract.supported_weapon) {
                        throw "Training response requires weapon '$($responseContract.supported_weapon)', observed '$([string]$report.player_action.weapon_type)'."
                    }
                    $responseDefinition = @(Get-LongSwordCurrentInputPlan `
                        -Step $TrainingResponseStep -ActiveSwitchSkill @() `
                        -BindingContract $report.input_motion.current_bindings)[0]
                    if ($null -eq $responseDefinition) {
                        throw "No current input definition was resolved for '$TrainingResponseStep'."
                    }
                    Initialize-MonsterCoachInputBridge
                    Write-Host "Training response armed: $TrainingResponseStep via $($responseDefinition.operations[0].binding_name)"
                } catch {
                    $responseFailure = "response_preflight_failed:$($_.Exception.Message)"
                    [void]$responseAttempts.Add([pscustomobject][ordered]@{
                        round_id = $null; status = 'failed'; reason = $responseFailure
                        failed_at = [DateTimeOffset]::Now.ToString('o')
                    })
                    Write-Warning $responseFailure
                }
            }
            if ($responseDefinition -and $null -eq $responseFailure) {
                $decision = Get-MonsterCoachTrainingResponseDecision -Report $report `
                    -Contract $responseContract `
                    -AttemptedRoundIds @($responseAttemptedRounds)
                if ($decision.action -eq 'fail') {
                    $responseFailure = "response_decision_failed:$($decision.reason)"
                    [void]$responseAttempts.Add([pscustomobject][ordered]@{
                        round_id = $decision.round_id; status = 'failed'; reason = $responseFailure
                        observed_action = $decision.observed_action
                        failed_at = [DateTimeOffset]::Now.ToString('o')
                    })
                    Write-Warning $responseFailure
                } elseif ($decision.action -eq 'send') {
                    $roundId = [string]$decision.round_id
                    [void]$responseAttemptedRounds.Add($roundId)
                    Stop-ArenaMovement
                    $game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    try {
                        if (-not $game) { throw 'Game process disappeared before response input.' }
                        $game.Refresh()
                        if (-not [MonsterCoachPlayerInputBridge]::OwnsForeground($game.MainWindowHandle)) {
                            throw [System.OperationCanceledException]::new(
                                'Player took over game focus before the training response.')
                        }
                        Invoke-LongSwordInputStep -GameWindow $game.MainWindowHandle `
                            -Definition $responseDefinition
                        [void]$responseAttempts.Add([pscustomobject][ordered]@{
                            round_id = [int]$roundId
                            action = [string]$decision.observed_action
                            action_sequence = [int]$decision.action_sequence
                            status = 'sent'
                            sent_at = [DateTimeOffset]::Now.ToString('o')
                            binding_name = [string]$responseDefinition.operations[0].binding_name
                            report_frame = [int]($report.frames ?? 0)
                        })
                        Write-Host "Training response sent once: $TrainingResponseStep during Action $($decision.observed_action), round $roundId"
                    } catch {
                        $responseFailure = "response_input_failed:$($_.Exception.GetType().Name):$($_.Exception.Message)"
                        [void]$responseAttempts.Add([pscustomobject][ordered]@{
                            round_id = [int]$roundId
                            action = [string]$decision.observed_action
                            action_sequence = [int]$decision.action_sequence
                            status = 'failed'; reason = $responseFailure
                            failed_at = [DateTimeOffset]::Now.ToString('o')
                        })
                        Write-Warning $responseFailure
                    }
                }
            }
        }
        if (-not $isNavigationReport -and -not $isDistanceSweepReport -and
            -not $isConditionBranchReport -and -not $isConditionTrainingReport -and
            -not $isAcceptancePrePositionReport) {
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
                            if (Test-ProbeTerminal) { continue }
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
                            if (Test-ProbeTerminal) { continue }
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
            $verticalGap = [Math]::Abs([double]($report.areas.player_enemy_vertical_gap ?? 9999))
            if ($report.areas.combat_layer -ne $true -or $verticalGap -gt 10.0) {
                Stop-ArenaMovement
                throw "Distance sweep received a non-combat sample instead of entering recovery (vertical gap $([Math]::Round($verticalGap, 2)) m)"
            }
            $sample = [int]($report.behavior_survey.samples ?? 0)
            $segmentCount = 2 * $BehaviorSweepCycles + 1
            $segment = [Math]::Min($segmentCount - 1,
                [Math]::Floor($sample * $segmentCount / $BehaviorSurveyFrames))
            $targetDistance = if (($segment % 2) -eq 1) {
                $BehaviorSweepFarDistance
            } else {
                $BehaviorSweepNearDistance
            }
            $band = "segment-$($segment + 1)-of-$segmentCount"
            if ($lastDistanceSweepBand -ne $band) {
                $lastDistanceSweepBand = $band
                $distanceSweepPlan = [pscustomobject]@{
                    candidate = 0
                    best_remaining = [double]::PositiveInfinity
                    last_progress_at = [datetimeoffset]::Now
                }
                Write-Host "Behavior distance sweep: $band target=$targetDistance m"
            }
            $player = $report.areas.player_position
            $enemy = $report.areas.enemy_position
            if ($null -ne $player -and $null -ne $enemy) {
                $command = Get-ArenaDistanceBandCommand -Areas $report.areas `
                    -TargetDistance $targetDistance -Tolerance 2.0 `
                    -CandidateIndex ([int]$distanceSweepPlan.candidate)
                if ($command.Action -eq 'hold') {
                    if ($command.Mode -eq 'flee' -and $null -ne $command.RemainingDistance) {
                        $remaining = [double]$command.RemainingDistance
                        if ($remaining -lt $distanceSweepPlan.best_remaining - 0.5) {
                            $distanceSweepPlan.best_remaining = $remaining
                            $distanceSweepPlan.last_progress_at = [datetimeoffset]::Now
                        } elseif (([datetimeoffset]::Now - $distanceSweepPlan.last_progress_at).TotalSeconds -ge 1.5) {
                            Stop-ArenaMovement
                            $distanceSweepPlan.candidate = ([int]$distanceSweepPlan.candidate + 1) % 6
                            $distanceSweepPlan.best_remaining = [double]::PositiveInfinity
                            $distanceSweepPlan.last_progress_at = [datetimeoffset]::Now
                            Write-Host "Behavior distance sweep: blocked route, replanning candidate $($distanceSweepPlan.candidate)"
                            continue
                        }
                    }
                    $desiredKeys = "$($command.Primary)+$($command.Secondary)"
                    if ($command.Action -eq 'hold' -and
                        (-not $combatRunHeld -or $combatRunKeys -ne $desiredKeys)) {
                        Stop-ArenaMovement
                        $secondaryKey = if ($command.Secondary) {
                            $virtualKeys[[string]$command.Secondary]
                        } else { [byte]0 }
                        if (-not [MonsterCoachInput]::BeginHoldMovement(
                            $game.MainWindowHandle, $virtualKeys[[string]$command.Primary], $secondaryKey)) {
                            if (Test-ProbeTerminal) { continue }
                            throw "Could not apply behavior distance sweep input $desiredKeys"
                        }
                        $combatRunHeld = $true
                        $combatRunKeys = $desiredKeys
                        Write-Host "Behavior distance sweep: $desiredKeys distance=$([Math]::Round($command.CurrentDistance, 2)) m candidate=$($command.CandidateIndex)"
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
                            if (Test-ProbeTerminal) { continue }
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
        if ($isConditionTrainingReport -or $isAcceptancePrePositionReport) {
            $player = $report.areas.player_position
            $enemy = $report.areas.enemy_position
            $targetDistance = [double]$report.training_acceptance.positioning.target
            $tolerance = [double]$report.training_acceptance.positioning.tolerance
            if ($null -ne $player -and $null -ne $enemy) {
                $verticalGap = [Math]::Abs([double]$player.y - [double]$enemy.y)
                if ($verticalGap -gt 10.0) {
                    Stop-ArenaMovement
                    continue
                }
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
                            if (Test-ProbeTerminal) { continue }
                            throw "Could not apply training positioning movement $desiredKeys"
                        }
                        $combatRunHeld = $true
                        $combatRunKeys = $desiredKeys
                        $positioningKind = if ($isAcceptancePrePositionReport) {
                            'Acceptance pre-position'
                        } else { 'Product condition training' }
                        Write-Host "$positioningKind`: $desiredKeys distance=$([Math]::Round($distance, 2)) m"
                    }
                } else {
                    Stop-ArenaMovement
                }
            }
        }
        if ($report -and ($report.session_id -eq $sessionId) -and
            ($report.status -in @('completed', 'failed'))) {
            New-Item -ItemType Directory -Path $resolvedArchiveRoot -Force | Out-Null
            $safeKind = ([string]$report.kind) -replace '[^A-Za-z0-9_.-]', '_'
            $archivePath = Join-Path $resolvedArchiveRoot `
                "$($report.session_id).$safeKind.$($report.status).json"
            Copy-Item -LiteralPath $reportPath -Destination $archivePath -Force
            Write-Host "Probe report archived: $archivePath"
            Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
            $responseEvidencePath = ''
            if ($responseEnabled) {
                $sentAttempts = @($responseAttempts | Where-Object status -eq 'sent')
                $responseEvidencePath = [IO.Path]::ChangeExtension(
                    $archivePath, '.response.json')
                $bindingPolicy = [string]$report.input_motion.current_bindings.policy
                $bindingName = if ($responseDefinition) {
                    [string]$responseDefinition.operations[0].binding_name
                } else { $null }
                $responseEvidence = [ordered]@{
                    schema_version = 1
                    session_id = $sessionId
                    scenario_id = $TrainingScenarioId
                    response_step = $TrainingResponseStep
                    status = if ($null -eq $responseFailure -and $sentAttempts.Count -eq 1) {
                        'sent'
                    } else { 'failed' }
                    failure_reason = $responseFailure
                    policy = 'external_allowlisted_player_input_with_runtime_binding'
                    focus_policy = 'reuse_automation_focus_abort_on_player_takeover'
                    binding = [ordered]@{
                        policy = $bindingPolicy
                        source_name = $bindingName
                    }
                    expected_timeline_event = [ordered]@{
                        kind = [string]$responseContract.expected_event_kind
                        flag = [string]$responseContract.expected_event_flag
                    }
                    attempts = @($responseAttempts)
                    equipment_writes = $false
                    save_writes = $false
                }
                Write-AtomicJson -Value $responseEvidence -Path $responseEvidencePath -Depth 12
                Write-Host "Training response evidence archived: $responseEvidencePath"
            }
            $analysisPath = Invoke-ProbeAnalysis -Report $report -ArchivePath $archivePath `
                -ResponseEvidencePath $responseEvidencePath
            $responseAnalysisInvalid = $false
            if ($responseEnabled) {
                $analysisResult = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
                $responseAnalysisInvalid = $analysisResult.contract_valid -ne $true -or
                    $analysisResult.response.status -ne 'verified' -or
                    $analysisResult.ready_for_product_acceptance -ne $true
            }
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
                    training_acceptance = $report.training_acceptance
                    ui_contract = $report.ui_contract
                    input_motion = $report.input_motion
                    player_action = $report.player_action
                    analysis = $analysisPath
                    response_evidence = $responseEvidencePath
                    behavior_survey = if ($report.behavior_survey) { [ordered]@{
                        samples = $report.behavior_survey.samples
                        events = @($report.behavior_survey.events).Count
                        nodes = @($report.behavior_survey.nodes).Count
                        edges = @($report.behavior_survey.edges).Count
                    } } else { $null }
                } | ConvertTo-Json -Depth 8
            }
            if ($report.status -eq 'failed') { exit 2 }
            if ($responseAnalysisInvalid) { exit 2 }
            exit 0
        }
    }
    if (-not (Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue)) {
        New-Item -ItemType Directory -Path $resolvedArchiveRoot -Force | Out-Null
        $lifecycleArchive = $null
        $lifecycleState = 'unavailable'
        if (Test-Path -LiteralPath $lifecyclePath -PathType Leaf) {
            try {
                $lifecycle = Get-Content -LiteralPath $lifecyclePath -Raw | ConvertFrom-Json
                if ($lifecycle.session_id -eq $sessionId) {
                    $lifecycleArchive = Join-Path $resolvedArchiveRoot `
                        "$sessionId.$($request.kind).game_exit.lifecycle.json"
                    Copy-Item -LiteralPath $lifecyclePath -Destination $lifecycleArchive -Force
                    $lifecycleState = "$($lifecycle.controller_state)/$($lifecycle.quest_flow.state)"
                }
            } catch {
                $lifecycleState = 'unreadable'
            }
        }
        Remove-Item -LiteralPath $requestPath -Force -ErrorAction SilentlyContinue
        throw "The game exited before the probe report was completed; last lifecycle=$lifecycleState; archive=$lifecycleArchive"
    }
    Start-Sleep -Milliseconds 250
} while ((Get-Date) -lt $deadline)

throw "Probe session timed out after $TimeoutSeconds seconds. Request retained at $requestPath"
}
finally {
    Stop-ArenaMovement
    if ('MonsterCoachPlayerInputBridge' -as [type]) {
        [MonsterCoachPlayerInputBridge]::ReleaseAllowlistedInputs()
    }
}
}
finally {
    if ($diagnosticIsolation.Count -gt 0) {
        $restoredDiagnostics = @(Restore-MonsterCoachKnownDiagnosticScripts `
            -Suspended $diagnosticIsolation)
        Write-Host "Restored $($restoredDiagnostics.Count) diagnostic autorun loader(s)."
    }
}
