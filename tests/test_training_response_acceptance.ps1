#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\tools\TrainingResponseAcceptance.psm1') -Force

$contract = Get-MonsterCoachTrainingResponseContract `
    -ScenarioId 'tigrex_rotate_attack_right_single' -ResponseStep 'dodge' -RepeatCount 1
if ($contract.expected_action -ne '26' -or $contract.max_repeats -ne 1 `
    -or $contract.expected_event_flag -ne 'escape') {
    throw 'The first response contract must remain the bounded right-spin dodge sample.'
}

foreach ($invalid in @(
    @{ scenario = 'tigrex_roar_single'; response = 'dodge'; repeats = 1 },
    @{ scenario = 'tigrex_rotate_attack_right_single'; response = 'foresight'; repeats = 1 },
    @{ scenario = 'tigrex_rotate_attack_right_single'; response = 'dodge'; repeats = 2 }
)) {
    $failed = $false
    try {
        Get-MonsterCoachTrainingResponseContract -ScenarioId $invalid.scenario `
            -ResponseStep $invalid.response -RepeatCount $invalid.repeats | Out-Null
    } catch { $failed = $true }
    if (-not $failed) { throw "Invalid response contract was accepted: $($invalid | ConvertTo-Json -Compress)" }
}

function New-TestReport {
    param([string]$Action = '26', [bool]$Active = $true, [string]$State = 'training_acceptance_wait')
    return [pscustomobject]@{
        kind = 'training_scenario_acceptance'
        status = 'running'
        state = $State
        training_acceptance = [pscustomobject]@{ scenario_id = 'tigrex_rotate_attack_right_single' }
        training_timeline = [pscustomobject]@{
            active = $Active
            round_id = 7
            events = @([pscustomobject]@{
                sequence = 1; kind = 'action_start'; data = [pscustomobject]@{ action = $Action }
            })
        }
    }
}

$decision = Get-MonsterCoachTrainingResponseDecision -Report (New-TestReport) -Contract $contract
if ($decision.action -ne 'send' -or $decision.round_id -ne '7') {
    throw 'A verified active Action 26 round must request one response send.'
}
$decision = Get-MonsterCoachTrainingResponseDecision -Report (New-TestReport) `
    -Contract $contract -AttemptedRoundIds @('7')
if ($decision.action -ne 'wait' -or $decision.reason -ne 'round_already_attempted') {
    throw 'The same training round must never receive a second response input.'
}
$decision = Get-MonsterCoachTrainingResponseDecision -Report (New-TestReport -Action '19') `
    -Contract $contract
if ($decision.action -ne 'fail' -or $decision.reason -ne 'unexpected_training_action') {
    throw 'An unexpected action must fail closed rather than receive input.'
}
$decision = Get-MonsterCoachTrainingResponseDecision -Report (New-TestReport -Active $false) `
    -Contract $contract
if ($decision.action -ne 'wait' -or $decision.reason -ne 'round_not_active') {
    throw 'The response must wait until the training timeline is active.'
}

Write-Host 'test_training_response_acceptance.ps1: PASS'
