#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [string[]]$Step = @(),
    [ValidateRange(1000, 5000)][int]$SampleWindowMilliseconds = 2200,
    [ValidateRange(4, 20)][int]$IdleTimeoutSeconds = 12,
    [ValidateRange(4, 20)][int]$ActionObservationTimeoutSeconds = 12,
    [ValidateRange(5, 20)][int]$InitialSettleSeconds = 12,
    [switch]$SkipPreflight,
    [switch]$SkipDeployment,
    [switch]$DryRun,
    [string]$OutputPath = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
Import-Module (Join-Path $PSScriptRoot 'PlayerActionInput.psm1') -Force

if ($DryRun) {
    Get-LongSwordDefaultInputPlan -Step $Step | ConvertTo-Json -Depth 8
    exit 0
}

$resolvedGameRoot = [IO.Path]::GetFullPath($GameRoot)
$dataRoot = Join-Path $resolvedGameRoot 'reframework\data\MHRiseMonsterCoach'
$evidencePath = Join-Path $dataRoot 'runtime_player_action_evidence.json'
$actionSignalPath = Join-Path $dataRoot 'runtime_player_action_signal.json'
$combatStatePath = Join-Path $dataRoot 'runtime_player_combat_state.json'
$probeReportPath = Join-Path $dataRoot 'dev_probe_report.json'
$probeRequestPath = Join-Path $dataRoot 'dev_probe_request.json'
$receiptPath = Join-Path $dataRoot 'dev_install_receipt.json'
$sourceVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()

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

if (-not (Test-Path -LiteralPath $receiptPath)) {
    throw 'Installed development receipt is missing; deploy the current source first.'
}
$installedVersion = (Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json).version
if ($installedVersion -ne $sourceVersion) {
    throw "Installed version '$installedVersion' does not match source '$sourceVersion'."
}

$game = Get-Process -Name MonsterHunterRise -ErrorAction SilentlyContinue | Select-Object -First 1
$preflightCompleted = $false
if (-not $game) {
    if ($SkipPreflight) { throw '-SkipPreflight requires a running game.' }
    & (Join-Path $PSScriptRoot 'run_probe_session.ps1') -PlayerActionEvidence `
        -TimeoutSeconds 300 -SkipDeployment:$SkipDeployment
    $preflightSucceeded = $?
    Clear-TerminalProbeRequest
    if (-not $preflightSucceeded) { throw 'Automatic game launch/player-action preflight failed.' }
    $game = Get-Process -Name MonsterHunterRise -ErrorAction Stop | Select-Object -First 1
    $preflightCompleted = $true
}

if (-not $SkipPreflight -and -not $preflightCompleted) {
    # Reuse the established quest/combat-area bootstrap. It verifies the supported
    # offline training quest and never changes equipment or switch skills.
    & (Join-Path $PSScriptRoot 'run_probe_session.ps1') -PlayerActionEvidence `
        -RequireCombatArea -TimeoutSeconds 240 -NavigationTimeoutSeconds 45 `
        -SkipDeployment:$SkipDeployment
    $preflightSucceeded = $?
    Clear-TerminalProbeRequest
    if (-not $preflightSucceeded) { throw 'Player-action preflight failed.' }
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)
    try { return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json } catch { return $null }
}

function Get-MaxEvidenceSample {
    param($Evidence)
    $samples = @($Evidence.events | ForEach-Object { [int]($_.sample ?? 0) })
    if ($samples.Count -eq 0) { return 0 }
    return [int](($samples | Measure-Object -Maximum).Maximum)
}

function Test-IdleEvidence {
    param($Current)
    if ($null -eq $Current -or $Current.player_type -ne 'snow.player.LongSword') { return $false }
    if ($Current.tags.damage -eq $true -or $Current.tags.attack -eq $true `
        -or $Current.tags.escape -eq $true) { return $false }
    if ([string]$Current.node_name -in @(
        'wait.main',
        'wait.wait_pre_mot_end',
        'atk.atk_wait.atk_wait_main.atk_wait_main'
    )) {
        return $true
    }
    # On the monsterless calibration quest the polled player FSM can retain the
    # Forlorn Arena arrival node until the first combat input.  The dedicated
    # quest/layer report is the safety boundary; unlike the Tigrex task there is
    # no enemy that can make this stale neutral node unsafe.
    if (([string]$Current.node_name).StartsWith('fast_travel.')) {
        $probe = Read-JsonFile -Path $probeReportPath
        return $probe -and $probe.kind -eq 'player_action_evidence' `
            -and $probe.status -eq 'completed' `
            -and $probe.areas.player_combat_layer -eq $true `
            -and $probe.areas.combat_layer -ne $true
    }
    return $false
}

function Wait-ForIdleEvidence {
    $deadline = (Get-Date).AddSeconds($IdleTimeoutSeconds)
    do {
        $evidence = Read-JsonFile -Path $evidencePath
        if ($evidence -and (Test-IdleEvidence $evidence.current)) {
            # One extra observer flush interval prevents a late pre-step event from
            # being attributed to the next input window.
            Start-Sleep -Milliseconds 1100
            $evidence = Read-JsonFile -Path $evidencePath
            if ($evidence -and (Test-IdleEvidence $evidence.current)) { return $evidence }
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Get-StepObservation {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][int]$BaselineSample
    )
    $after = Read-JsonFile -Path $evidencePath
    $events = if ($after) { @($after.events | Where-Object {
        [int]($_.sample ?? 0) -gt $BaselineSample `
            -and $_.player_type -eq 'snow.player.LongSword'
    } | ForEach-Object {
        [pscustomobject]@{
            sample = $_.sample
            node_id = $_.node_id
            node_name = $_.node_name
            tags = $_.tags
        }
    }) } else { @() }
    $meaningful = @($events | Where-Object {
        $_.node_name -notin @(
            'wait.main',
            'wait.wait_pre_mot_end',
            'atk.atk_wait.atk_wait_main.atk_wait_main'
        ) -and
        -not ([string]$_.node_name).StartsWith('damage.') -and
        -not ([string]$_.node_name).StartsWith('fast_travel.')
    })
    $observedTags = @($events | ForEach-Object {
        foreach ($name in @('attack', 'escape', 'guard', 'damage')) {
            if ($_.tags.$name -eq $true) { $name }
        }
    } | Sort-Object -Unique)
    $expectedSatisfied = $Definition.expected_tags.Count -eq 0 -or
        @($Definition.expected_tags | Where-Object { $_ -in $observedTags }).Count -gt 0
    $expectedNodePrefixes = @($Definition.expected_node_prefixes)
    $semanticMatches = @($meaningful | Where-Object {
        $name = [string]$_.node_name
        @($expectedNodePrefixes | Where-Object { $name.StartsWith([string]$_) }).Count -gt 0
    })
    $semanticSatisfied = $expectedNodePrefixes.Count -eq 0 -or $semanticMatches.Count -gt 0
    return [pscustomobject]@{
        evidence = $after
        events = $events
        meaningful = $meaningful
        observed_tags = $observedTags
        semantic_matches = $semanticMatches
        semantic_satisfied = $semanticSatisfied
        expected_satisfied = $expectedSatisfied
        complete = $meaningful.Count -gt 0 -and $expectedSatisfied `
            -and $after -and (Test-IdleEvidence $after.current)
    }
}

function Wait-ForStepObservation {
    param(
        [Parameter(Mandatory)]$Definition,
        [Parameter(Mandatory)][int]$BaselineSample
    )
    $minimumDeadline = (Get-Date).AddMilliseconds($SampleWindowMilliseconds)
    $deadline = (Get-Date).AddSeconds($ActionObservationTimeoutSeconds)
    $observation = $null
    do {
        $observation = Get-StepObservation -Definition $Definition `
            -BaselineSample $BaselineSample
        if ($observation.complete -and (Get-Date) -ge $minimumDeadline) {
            # Require one stable reread so the observer's bounded disk flush cannot
            # move the action tail into the next semantic step.
            Start-Sleep -Milliseconds 1100
            $stable = Get-StepObservation -Definition $Definition `
                -BaselineSample $BaselineSample
            if ($stable.complete) { return $stable }
            $observation = $stable
        }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    return $observation
}

$combat = Read-JsonFile -Path $combatStatePath
if ($combat.weapon_type -ne 'long_sword' -or $combat.weapon_controller_type -ne 'snow.player.PlayerWeaponCtrlLS_Sword') {
    throw 'Current player is not using Long Sword; the probe will not change equipment.'
}
$activeScroll = [string]$combat.active_scroll
$activeSwitchSkills = if ($activeScroll -in @('red', 'blue') -and $combat.switch_skills) {
    @($combat.switch_skills.$activeScroll | Where-Object { $_ })
} else { @() }
$catalog = @(Get-LongSwordDefaultInputPlan -Step $Step `
    -ActiveSwitchSkill $activeSwitchSkills)
$inapplicable = @($catalog | Where-Object { -not $_.applicable })
if ($Step.Count -gt 0 -and $inapplicable.Count -gt 0) {
    $details = @($inapplicable | ForEach-Object {
        "$($_.id): $($_.inapplicable_reason)"
    }) -join '; '
    throw "Requested action calibration is not applicable to the active '$activeScroll' scroll: $details"
}
$plan = @($catalog | Where-Object applicable)
if ($plan.Count -eq 0) {
    throw "No Long Sword calibration step applies to the active '$activeScroll' scroll."
}

Initialize-MonsterCoachInputBridge
$game.Refresh()
if (-not [MonsterCoachPlayerInputBridge]::AcquireFocus($game.MainWindowHandle)) {
    throw 'Could not acquire game focus for the bounded calibration session.'
}

# The Forlorn Arena arrival FSM remains visible before combat input is accepted.
# This one-time bounded settle replaces several ignored inputs and is still far
# cheaper than asking a user to repeat manual calibration runs.
Start-Sleep -Seconds $InitialSettleSeconds

# The first left click in the arena can only draw the weapon. Keep that setup
# outside the formal calibration rows so basic_overhead always means an attack.
$initialIdle = Wait-ForIdleEvidence
if ($null -eq $initialIdle) {
    throw 'Long Sword did not reach a stable initial state before draw preparation.'
}
if ([string]$initialIdle.current.node_name -ne 'atk.atk_wait.atk_wait_main.atk_wait_main') {
    $game.Refresh()
    Invoke-LongSwordInputStep -GameWindow $game.MainWindowHandle -Step 'basic_overhead'
    $initialIdle = Wait-ForIdleEvidence
    if ($null -eq $initialIdle `
        -or [string]$initialIdle.current.node_name -ne 'atk.atk_wait.atk_wait_main.atk_wait_main') {
        throw 'Long Sword draw preparation did not reach the drawn idle node.'
    }
}

$sessionId = [Guid]::NewGuid().ToString('N')
$results = [Collections.Generic.List[object]]::new()
$takeoverDetected = $false
try {
    foreach ($definition in $plan) {
        $idle = Wait-ForIdleEvidence
        if ($null -eq $idle) {
            $results.Add([pscustomobject]@{
                id = $definition.id
                label = $definition.label
                status = 'precondition_failed'
                reason = 'Long Sword did not reach a stable idle node before the bounded timeout.'
                events = @()
            })
            break
        }
        $baselineSample = Get-MaxEvidenceSample $idle
        $baselineRevision = [int]($idle.revision ?? 0)
        $game.Refresh()
        $inputFailure = $null
        try {
            Invoke-LongSwordInputStep -GameWindow $game.MainWindowHandle -Step $definition.id `
                -ActionSignalPath $actionSignalPath
        } catch {
            $inputFailure = $_
        }
        if ($inputFailure) {
            $observation = Get-StepObservation -Definition $definition `
                -BaselineSample $baselineSample
            $after = $observation.evidence
            $exception = $inputFailure.Exception
            $inputErrorKind = if ($exception -is [System.OperationCanceledException]) {
                'player_takeover'
            } elseif ($exception -is [System.TimeoutException]) {
                'action_signal_timeout'
            } else {
                'input_send_failure'
            }
            $results.Add([pscustomobject]@{
                id = $definition.id
                label = $definition.label
                status = 'input_failed'
                reason = $exception.Message
                input_error_kind = $inputErrorKind
                baseline_sample = $baselineSample
                baseline_revision = $baselineRevision
                observed_revision = [int]($after.revision ?? 0)
                observation_complete = $false
                expected_tags = @($definition.expected_tags)
                expected_node_prefixes = @($definition.expected_node_prefixes)
                observed_tags = @($observation.observed_tags)
                semantic_status = if ($observation.semantic_satisfied) { 'observed' } else { 'not_observed' }
                semantic_matches = @($observation.semantic_matches)
                events = @($observation.events)
            })
            if ($inputErrorKind -eq 'player_takeover') {
                $takeoverDetected = $true
                break
            }
            continue
        }
        $observation = Wait-ForStepObservation -Definition $definition `
            -BaselineSample $baselineSample
        $after = $observation.evidence
        $events = @($observation.events)
        $observedTags = @($observation.observed_tags)
        $status = if ($observation.complete) { 'observed' } else { 'not_observed' }
        $results.Add([pscustomobject]@{
            id = $definition.id
            label = $definition.label
            status = $status
            baseline_sample = $baselineSample
            baseline_revision = $baselineRevision
            observed_revision = [int]($after.revision ?? 0)
            observation_complete = [bool]$observation.complete
            expected_tags = @($definition.expected_tags)
            expected_node_prefixes = @($definition.expected_node_prefixes)
            observed_tags = $observedTags
            semantic_status = if ($observation.semantic_satisfied) { 'observed' } else { 'not_observed' }
            semantic_matches = @($observation.semantic_matches)
            events = $events
        })
    }
} finally {
    if ('MonsterCoachPlayerInputBridge' -as [type]) {
        [MonsterCoachPlayerInputBridge]::ReleaseAllowlistedInputs()
    }
}

$report = [ordered]@{
    schema_version = 1
    session_id = $sessionId
    captured_at = [DateTimeOffset]::Now.ToString('o')
    source_version = $sourceVersion
    policy = 'external_allowlisted_player_input_with_read_only_runtime_evidence'
    focus_policy = 'acquire_once_abort_on_player_takeover'
    official_default_control_source = 'https://game.capcom.com/manual/Multi-Platform/zh-hans/windows/page/3/6'
    equipment_writes = $false
    save_writes = $false
    player_type = $combat.action_state.evidence.player_type
    weapon_type = $combat.weapon_type
    active_scroll = $combat.active_scroll
    switch_skills = $combat.switch_skills
    expected_step_ids = @($plan.id)
    plan = [ordered]@{
        strategy = 'active_switch_skill_aware'
        active_switch_skills = @($activeSwitchSkills)
        excluded_steps = @($inapplicable | ForEach-Object {
            [ordered]@{
                id = $_.id
                required_switch_skill = $_.required_switch_skill
                reason = $_.inapplicable_reason
            }
        })
    }
    results = @($results)
    summary = [ordered]@{
        requested = $plan.Count
        observed = @($results | Where-Object status -eq 'observed').Count
        not_observed = @($results | Where-Object status -eq 'not_observed').Count
        precondition_failed = @($results | Where-Object status -eq 'precondition_failed').Count
        input_failed = @($results | Where-Object status -eq 'input_failed').Count
        player_takeover = $takeoverDetected
        semantic_observed = @($results | Where-Object semantic_status -eq 'observed').Count
        semantic_not_observed = @($results | Where-Object semantic_status -eq 'not_observed').Count
    }
}

$resolvedOutput = if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    Join-Path $repositoryRoot "artifacts\player_action_input_probe\$sessionId.json"
} else { [IO.Path]::GetFullPath($OutputPath) }
New-Item -ItemType Directory -Path (Split-Path -Parent $resolvedOutput) -Force | Out-Null
$report | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $resolvedOutput -Encoding utf8
$report | ConvertTo-Json -Depth 12
Write-Host "Player action input report: $resolvedOutput"

if ($report.summary.player_takeover) { exit 4 }
if ($report.summary.precondition_failed -gt 0) { exit 3 }
if ($report.summary.input_failed -gt 0) { exit 2 }
if ($report.summary.observed -ne $report.summary.requested `
    -or $report.summary.not_observed -gt 0 `
    -or $report.summary.semantic_observed -ne $report.summary.requested) { exit 2 }
