#Requires -Version 7.0
[CmdletBinding()]
param(
    [string]$GameRoot = 'C:\Program Files (x86)\Steam\steamapps\common\MonsterHunterRise',
    [string]$PlanPath = '',
    [string]$ArchiveRoot = '',
    [ValidateRange(60, 1800)][int]$ScenarioTimeoutSeconds = 900,
    [ValidateRange(10, 120)][int]$NavigationTimeoutSeconds = 60,
    [switch]$SkipDeployment,
    [switch]$PlanOnly,
    [Parameter(DontShow = $true)][string]$WorkerPath = ''
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedPlanPath = if ([string]::IsNullOrWhiteSpace($PlanPath)) {
    Join-Path $PSScriptRoot 'tigrex_core_acceptance_plan.json'
} else {
    [IO.Path]::GetFullPath($PlanPath)
}
$staticPackPath = Join-Path $repositoryRoot `
    'reframework\data\MHRiseMonsterCoach\tigrex_static_ai.json'
$sourceVersion = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()

function Read-CoreAcceptancePlan {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Core acceptance plan was not found: $Path"
    }
    $plan = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($plan.schema_version -ne 1 -or [string]::IsNullOrWhiteSpace([string]$plan.plan_id)) {
        throw 'Core acceptance plan requires schema_version=1 and a stable plan_id.'
    }
    $scenarios = @($plan.scenarios)
    if ($scenarios.Count -lt 3 -or $scenarios.Count -gt 12) {
        throw 'Core acceptance plan must contain 3-12 scenarios.'
    }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($scenario in $scenarios) {
        $id = [string]$scenario.id
        if ([string]::IsNullOrWhiteSpace($id) -or -not $seen.Add($id)) {
            throw "Core acceptance plan contains an empty or duplicate scenario ID: '$id'"
        }
        if ([string]$scenario.category -notin @(
                'independent', 'fixed_branch', 'conditional_branch',
                'random_branch', 'observed_branch')) {
            throw "Core acceptance scenario '$id' has an unsupported category."
        }
        $repeatCount = [int]$scenario.repeat_count
        if ($repeatCount -lt 1 -or $repeatCount -gt 20) {
            throw "Core acceptance scenario '$id' requires 1-20 repeats."
        }
    }
    $required = @($plan.required_categories | ForEach-Object { [string]$_ })
    foreach ($category in $required) {
        if ($category -notin @($scenarios | ForEach-Object { [string]$_.category })) {
            throw "Core acceptance plan is missing required category '$category'."
        }
    }

    $pack = Get-Content -LiteralPath $staticPackPath -Raw | ConvertFrom-Json
    $catalog = @{}
    foreach ($scenario in @($pack.training_scenarios)) {
        $catalog[[string]$scenario.id] = $scenario
    }
    foreach ($scenario in $scenarios) {
        $id = [string]$scenario.id
        $source = $catalog[$id]
        if ($null -eq $source -or $source.verification.status -ne 'verified') {
            throw "Core acceptance scenario '$id' is absent or not verified in the monster pack."
        }
        if ([string]$source.training_category -ne [string]$scenario.category) {
            throw "Core acceptance scenario '$id' category differs from the monster pack."
        }
        if ([int]$scenario.repeat_count -gt [int]$source.max_verified_repeats) {
            throw "Core acceptance scenario '$id' exceeds its verified repeat limit."
        }
    }
    return $plan
}

function Write-AtomicJson {
    param([Parameter(Mandatory)]$Value, [Parameter(Mandatory)][string]$Path)
    $temporaryPath = "$Path.$PID.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $Value | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $temporaryPath -Encoding utf8
        [IO.File]::Move($temporaryPath, $Path, $true)
    } finally {
        Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
    }
}

$plan = Read-CoreAcceptancePlan -Path $resolvedPlanPath
if ($PlanOnly) {
    [ordered]@{
        schema_version = 1
        plan_id = [string]$plan.plan_id
        source_version = $sourceVersion
        scenario_count = @($plan.scenarios).Count
        required_categories = @($plan.required_categories)
        scenarios = @($plan.scenarios)
        weapon_response_required = $false
    } | ConvertTo-Json -Depth 8
    exit 0
}

$batchId = [Guid]::NewGuid().ToString('N')
$resolvedArchiveRoot = if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
    Join-Path $repositoryRoot 'artifacts\core_acceptance'
} else {
    [IO.Path]::GetFullPath($ArchiveRoot)
}
$batchDirectory = Join-Path $resolvedArchiveRoot $batchId
New-Item -ItemType Directory -Path $batchDirectory -Force | Out-Null
$runner = if ([string]::IsNullOrWhiteSpace($WorkerPath)) {
    Join-Path $PSScriptRoot 'run_probe_session.ps1'
} else {
    [IO.Path]::GetFullPath($WorkerPath)
}
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) {
    throw "Core acceptance worker was not found: $runner"
}
$pwsh = Join-Path $PSHOME 'pwsh.exe'
if (-not (Test-Path -LiteralPath $pwsh -PathType Leaf)) {
    throw "PowerShell 7 executable was not found in PSHOME: $pwsh"
}

$results = [Collections.Generic.List[object]]::new()
$index = 0
foreach ($scenario in @($plan.scenarios)) {
    $index += 1
    $scenarioId = [string]$scenario.id
    Write-Host "Core acceptance $index/$(@($plan.scenarios).Count): $scenarioId"
    $arguments = @(
        '-NoProfile', '-File', $runner,
        '-GameRoot', [IO.Path]::GetFullPath($GameRoot),
        '-TimeoutSeconds', [string]$ScenarioTimeoutSeconds,
        '-NavigationTimeoutSeconds', [string]$NavigationTimeoutSeconds,
        '-TrainingScenarioId', $scenarioId,
        '-TrainingRepeatCount', [string][int]$scenario.repeat_count,
        '-RequireCombatArea',
        '-ProbeArchiveRoot', $batchDirectory
    )
    if ($SkipDeployment -or $index -gt 1) { $arguments += '-SkipDeployment' }

    & $pwsh @arguments
    $processExitCode = $LASTEXITCODE
    $reportFile = Get-ChildItem -LiteralPath $batchDirectory -File |
        Where-Object {
            $_.Name -match '\.training_scenario_acceptance\.(completed|failed)\.json$'
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Where-Object {
            try {
                $candidate = Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
                [string]$candidate.training_acceptance.scenario_id -eq $scenarioId
            } catch { $false }
        } |
        Select-Object -First 1

    $report = $null
    $analysis = $null
    $analysisPath = $null
    if ($reportFile) {
        $report = Get-Content -LiteralPath $reportFile.FullName -Raw | ConvertFrom-Json
        $analysisPath = [IO.Path]::ChangeExtension($reportFile.FullName, '.analysis.json')
        if (Test-Path -LiteralPath $analysisPath -PathType Leaf) {
            $analysis = Get-Content -LiteralPath $analysisPath -Raw | ConvertFrom-Json
        }
    }
    [void]$results.Add([ordered]@{
        id = $scenarioId
        category = [string]$scenario.category
        repeat_count = [int]$scenario.repeat_count
        process_exit_code = $processExitCode
        probe_status = if ($report) { [string]$report.status } else { 'missing' }
        probe_session_id = if ($report) { [string]$report.session_id } else { $null }
        report_path = if ($reportFile) { $reportFile.FullName } else { $null }
        analysis_path = $analysisPath
        analysis = $analysis
    })
    $scenarioFailed = (
        $processExitCode -ne 0 -or
        $null -eq $report -or
        $report.status -ne 'completed' -or
        $null -eq $analysis -or
        $analysis.contract_valid -ne $true
    )
    if ($scenarioFailed) {
        Write-Warning "Core acceptance stopped after '$scenarioId'; previous evidence is preserved."
        break
    }
}

$failedResults = @($results | Where-Object {
    $_.process_exit_code -ne 0 -or
    $_.probe_status -ne 'completed' -or
    $null -eq $_.analysis -or
    $_.analysis.contract_valid -ne $true
})
$allCompleted = (
    $results.Count -eq @($plan.scenarios).Count -and
    $failedResults.Count -eq 0
)
$summaryPath = Join-Path $batchDirectory "$batchId.core_acceptance.json"
$summary = [ordered]@{
    schema_version = 1
    kind = 'mvp_core_acceptance_batch'
    batch_id = $batchId
    source_version = $sourceVersion
    status = if ($allCompleted) { 'completed' } else { 'failed' }
    started_scenario_count = $results.Count
    weapon_response_required = $false
    plan = [ordered]@{
        plan_id = [string]$plan.plan_id
        monster = [string]$plan.monster
        required_categories = @($plan.required_categories)
        scenarios = @($plan.scenarios)
    }
    scenarios = @($results)
}
Write-AtomicJson -Value $summary -Path $summaryPath

$python = Join-Path $repositoryRoot '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) {
    throw "Verified repository Python was not found: $python"
}
$analysisOutputPath = [IO.Path]::ChangeExtension($summaryPath, '.analysis.json')
& $python (Join-Path $PSScriptRoot 'analyze_core_acceptance.py') `
    $summaryPath '--output' $analysisOutputPath
if ($LASTEXITCODE -ne 0) { throw 'Core acceptance analysis process failed.' }
$batchAnalysis = Get-Content -LiteralPath $analysisOutputPath -Raw | ConvertFrom-Json

[ordered]@{
    batch_id = $batchId
    status = [string]$batchAnalysis.status
    scenario_count = [int]$batchAnalysis.scenario_count
    ready_for_release_gate = [bool]$batchAnalysis.ready_for_release_gate
    coverage_gaps = @($batchAnalysis.coverage_gaps)
    summary = $summaryPath
    analysis = $analysisOutputPath
} | ConvertTo-Json -Depth 8

if ($batchAnalysis.ready_for_release_gate -ne $true) { exit 2 }
exit 0
