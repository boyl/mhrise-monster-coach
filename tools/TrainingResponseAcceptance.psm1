#Requires -Version 7.0

Set-StrictMode -Version Latest

$script:Contracts = [ordered]@{
    dodge = [ordered]@{
        scenario_id = 'tigrex_rotate_attack_right_single'
        expected_action = '26'
        supported_weapon = 'long_sword'
        max_repeats = 1
        trigger = 'first_active_round_action_start'
        expected_event_kind = 'player_status'
        expected_event_flag = 'escape'
    }
}

function Get-MonsterCoachTrainingResponseContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScenarioId,
        [Parameter(Mandatory)][string]$ResponseStep,
        [Parameter(Mandatory)][int]$RepeatCount
    )

    if (-not $script:Contracts.Contains($ResponseStep)) {
        throw "Unsupported training response '$ResponseStep'. Supported: $($script:Contracts.Keys -join ', ')"
    }
    $source = $script:Contracts[$ResponseStep]
    if ($ScenarioId -ne $source.scenario_id) {
        throw "Training response '$ResponseStep' is only verified for scenario '$($source.scenario_id)'."
    }
    if ($RepeatCount -lt 1 -or $RepeatCount -gt [int]$source.max_repeats) {
        throw "Training response '$ResponseStep' allows 1-$($source.max_repeats) repeat(s)."
    }
    return [pscustomobject][ordered]@{
        response_step = $ResponseStep
        scenario_id = $source.scenario_id
        expected_action = $source.expected_action
        supported_weapon = $source.supported_weapon
        max_repeats = [int]$source.max_repeats
        trigger = $source.trigger
        expected_event_kind = $source.expected_event_kind
        expected_event_flag = $source.expected_event_flag
        policy = 'single_allowlisted_response_after_live_action_start'
    }
}

function Get-MonsterCoachTrainingResponseDecision {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)]$Contract,
        [string[]]$AttemptedRoundIds = @()
    )

    if ([string]$Report.kind -ne 'training_scenario_acceptance' `
        -or [string]$Report.status -ne 'running' `
        -or [string]$Report.state -ne 'training_acceptance_wait') {
        return [pscustomobject]@{ action = 'wait'; reason = 'training_not_running' }
    }
    if ([string]$Report.training_acceptance.scenario_id -ne [string]$Contract.scenario_id) {
        return [pscustomobject]@{ action = 'fail'; reason = 'scenario_mismatch' }
    }
    $timeline = $Report.training_timeline
    if ($null -eq $timeline -or $timeline.active -ne $true) {
        return [pscustomobject]@{ action = 'wait'; reason = 'round_not_active' }
    }
    $roundId = [string]($timeline.round_id ?? '')
    if ([string]::IsNullOrWhiteSpace($roundId)) {
        return [pscustomobject]@{ action = 'fail'; reason = 'active_round_id_missing' }
    }
    if ($roundId -in $AttemptedRoundIds) {
        return [pscustomobject]@{ action = 'wait'; reason = 'round_already_attempted'; round_id = $roundId }
    }
    $starts = @($timeline.events | Where-Object kind -eq 'action_start')
    if ($starts.Count -ne 1) {
        return [pscustomobject]@{ action = 'wait'; reason = 'single_action_start_not_observed'; round_id = $roundId }
    }
    $observedAction = [string]$starts[0].data.action
    if ($observedAction -ne [string]$Contract.expected_action) {
        return [pscustomobject]@{
            action = 'fail'; reason = 'unexpected_training_action'; round_id = $roundId
            observed_action = $observedAction
        }
    }
    return [pscustomobject]@{
        action = 'send'; reason = 'verified_action_start_observed'; round_id = $roundId
        observed_action = $observedAction; action_sequence = $starts[0].sequence
    }
}

Export-ModuleMember -Function Get-MonsterCoachTrainingResponseContract, `
    Get-MonsterCoachTrainingResponseDecision
