#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runner = Join-Path $repositoryRoot 'tools\run_core_acceptance.ps1'
$planPath = Join-Path $repositoryRoot 'tools\tigrex_core_acceptance_plan.json'
$pwsh = Join-Path $PSHOME 'pwsh.exe'

$output = & $pwsh -NoProfile -File $runner -PlanOnly | Out-String
if ($LASTEXITCODE -ne 0) { throw 'The checked-in core acceptance plan was rejected.' }
$contract = $output | ConvertFrom-Json
if ($contract.scenario_count -ne 8) { throw 'The MVP batch must contain all eight scenarios.' }
if ($contract.weapon_response_required -ne $false) {
    throw 'Weapon-specific Response must remain optional for core acceptance.'
}
if (@($contract.required_categories).Count -ne 3) {
    throw 'The core batch must cover independent, fixed and conditional branches.'
}
if ($contract.scenarios[0].id -ne 'tigrex_roar_single' -or
    $contract.scenarios[-1].id -ne 'tigrex_straight_rush_branches') {
    throw 'The stable core acceptance execution order changed unexpectedly.'
}
if (@($contract.scenarios | Where-Object { $_.repeat_count -ne 1 }).Count -ne 0) {
    throw 'Core acceptance must remain a single-pass batch to minimize game time.'
}

$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) `
    "monster-coach-core-plan-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $temporaryRoot -Force | Out-Null
try {
    $invalidPlanPath = Join-Path $temporaryRoot 'duplicate-plan.json'
    $invalidPlan = Get-Content -LiteralPath $planPath -Raw | ConvertFrom-Json
    $invalidPlan.scenarios[1].id = $invalidPlan.scenarios[0].id
    $invalidPlan | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $invalidPlanPath -Encoding utf8
    $null = & $pwsh -NoProfile -File $runner -PlanPath $invalidPlanPath -PlanOnly 2>&1
    if ($LASTEXITCODE -eq 0) { throw 'A duplicate scenario plan was accepted.' }

    $mockWorkerPath = Join-Path $temporaryRoot 'mock-probe-worker.ps1'
    [IO.File]::WriteAllText($mockWorkerPath, @'
param(
    [string]$GameRoot,
    [int]$TimeoutSeconds,
    [int]$NavigationTimeoutSeconds,
    [string]$TrainingScenarioId,
    [int]$TrainingRepeatCount,
    [switch]$RequireCombatArea,
    [string]$ProbeArchiveRoot,
    [switch]$SkipDeployment
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Path $ProbeArchiveRoot -Force | Out-Null
$call = [ordered]@{
    scenario_id = $TrainingScenarioId
    repeat_count = $TrainingRepeatCount
    skip_deployment = [bool]$SkipDeployment
}
[IO.File]::AppendAllText(
    (Join-Path $ProbeArchiveRoot 'worker_calls.ndjson'),
    (($call | ConvertTo-Json -Compress) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
)
$session = [Guid]::NewGuid().ToString('N')
$reportPath = Join-Path $ProbeArchiveRoot `
    "$session.training_scenario_acceptance.completed.json"
$analysisPath = [IO.Path]::ChangeExtension($reportPath, '.analysis.json')
[ordered]@{
    kind = 'training_scenario_acceptance'
    status = 'completed'
    session_id = $session
    training_acceptance = [ordered]@{
        scenario_id = $TrainingScenarioId
        completed_rounds = $TrainingRepeatCount
        target_rounds = $TrainingRepeatCount
    }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $reportPath -Encoding utf8
[ordered]@{
    status = 'verified_complete_training_timeline'
    contract_valid = $true
    training = [ordered]@{
        scenario_id = $TrainingScenarioId
        completed_rounds = $TrainingRepeatCount
        target_rounds = $TrainingRepeatCount
    }
    timeline = [ordered]@{
        hitbox_windows = @([ordered]@{ start_frame = 10; end_frame = 20 })
        completion_basis = 'behavior_tree_attack_exit'
    }
    outcome = [ordered]@{
        value = 'observed_hit'
        evidence_level = 'observed_failure'
    }
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $analysisPath -Encoding utf8
exit 0
'@, [Text.UTF8Encoding]::new($false))

    $batchRoot = Join-Path $temporaryRoot 'batch'
    $null = & $pwsh -NoProfile -File $runner -ArchiveRoot $batchRoot `
        -WorkerPath $mockWorkerPath 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'The offline end-to-end core batch failed.' }
    $batchDirectory = Get-ChildItem -LiteralPath $batchRoot -Directory | Select-Object -First 1
    if ($null -eq $batchDirectory) { throw 'The core batch did not create an artifact directory.' }
    $calls = @(Get-Content -LiteralPath (Join-Path $batchDirectory.FullName 'worker_calls.ndjson') |
        ForEach-Object { $_ | ConvertFrom-Json })
    if ($calls.Count -ne 8) { throw 'The core batch did not invoke all eight workers.' }
    if ($calls[0].skip_deployment -ne $false -or
        @($calls | Select-Object -Skip 1 | Where-Object { $_.skip_deployment -ne $true }).Count -ne 0) {
        throw 'Only the first core worker may perform deployment/startup setup.'
    }
    $batchAnalysisPath = Get-ChildItem -LiteralPath $batchDirectory.FullName -File |
        Where-Object Name -Match '\.core_acceptance\.analysis\.json$' |
        Select-Object -First 1 -ExpandProperty FullName
    $batchAnalysis = Get-Content -LiteralPath $batchAnalysisPath -Raw | ConvertFrom-Json
    if ($batchAnalysis.ready_for_release_gate -ne $true -or
        $batchAnalysis.scenario_count -ne 8) {
        throw 'The offline end-to-end batch did not reach the release gate.'
    }
} finally {
    Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'test_core_acceptance.ps1: PASS'
