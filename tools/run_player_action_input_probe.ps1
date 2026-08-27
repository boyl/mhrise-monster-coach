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
$plan = @(Get-LongSwordDefaultInputPlan -Step $Step)

if ($DryRun) {
    $plan | ConvertTo-Json -Depth 8
    exit 0
}

$resolvedGameRoot = [IO.Path]::GetFullPath($GameRoot)
$dataRoot = Join-Path $resolvedGameRoot 'reframework\data\MHRiseMonsterCoach'
$evidencePath = Join-Path $dataRoot 'runtime_player_action_evidence.json'
$actionSignalPath = Join-Path $dataRoot 'runtime_player_action_signal.json'
$combatStatePath = Join-Path $dataRoot 'runtime_player_combat_state.json'
$probeReportPath = Join-Path $dataRoot 'dev_probe_report.json'
$receiptPath = Join-Path $dataRoot 'dev_install_receipt.json'
$sourceVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()

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
    if (-not $?) { throw 'Automatic game launch/player-action preflight failed.' }
    $game = Get-Process -Name MonsterHunterRise -ErrorAction Stop | Select-Object -First 1
    $preflightCompleted = $true
}

if (-not $SkipPreflight -and -not $preflightCompleted) {
    # Reuse the established quest/combat-area bootstrap. It verifies the supported
    # offline training quest and never changes equipment or switch skills.
    & (Join-Path $PSScriptRoot 'run_probe_session.ps1') -PlayerActionEvidence `
        -RequireCombatArea -TimeoutSeconds 240 -NavigationTimeoutSeconds 45 `
        -SkipDeployment:$SkipDeployment
    if (-not $?) { throw 'Player-action preflight failed.' }
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
        Invoke-LongSwordInputStep -GameWindow $game.MainWindowHandle -Step $definition.id `
            -ActionSignalPath $actionSignalPath
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
    official_default_control_source = 'https://game.capcom.com/manual/Multi-Platform/zh-hans/windows/page/3/6'
    equipment_writes = $false
    save_writes = $false
    player_type = $combat.action_state.evidence.player_type
    weapon_type = $combat.weapon_type
    active_scroll = $combat.active_scroll
    switch_skills = $combat.switch_skills
    results = @($results)
    summary = [ordered]@{
        requested = $plan.Count
        observed = @($results | Where-Object status -eq 'observed').Count
        not_observed = @($results | Where-Object status -eq 'not_observed').Count
        precondition_failed = @($results | Where-Object status -eq 'precondition_failed').Count
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

if ($report.summary.precondition_failed -gt 0) { exit 3 }
if ($report.summary.observed -ne $report.summary.requested `
    -or $report.summary.not_observed -gt 0 `
    -or $report.summary.semantic_observed -ne $report.summary.requested) { exit 2 }
