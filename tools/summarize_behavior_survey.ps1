#Requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ReportPath,
    [string]$NodePattern = 'BiteHookHalfTurn',
    [int[]]$ActionNumbers = @(5000, 5001, 5002)
)

$ErrorActionPreference = 'Stop'
$resolved = [IO.Path]::GetFullPath($ReportPath)
$report = Get-Content -LiteralPath $resolved -Raw | ConvertFrom-Json -Depth 100
if ($report.status -ne 'completed' -or $null -eq $report.behavior_survey) {
    throw "Behavior survey is not complete: $resolved"
}

$events = @($report.behavior_survey.events | Where-Object {
    $_.node.name -match $NodePattern -or [int]$_.action.action -in $ActionNumbers
})
$actions = foreach ($actionNo in $ActionNumbers) {
    $matching = @($events | Where-Object { [int]$_.action.action -eq $actionNo })
    $distances = @($matching | ForEach-Object { [double]$_.geometry.horizontal_distance })
    [ordered]@{
        action = $actionNo
        observations = $matching.Count
        distance = if ($distances.Count -gt 0) { [ordered]@{
            min = ($distances | Measure-Object -Minimum).Minimum
            max = ($distances | Measure-Object -Maximum).Maximum
            mean = ($distances | Measure-Object -Average).Average
        } } else { $null }
    }
}

[ordered]@{
    schema_version = 1
    source_session = $report.session_id
    survey_samples = $report.behavior_survey.samples
    policy = 'observed_runtime_evidence_not_universal_thresholds'
    actions = @($actions)
    sequence = @($events | ForEach-Object { [ordered]@{
        frame = $_.frame
        node = $_.node.name
        category = $_.action.category
        action = $_.action.action
        horizontal_distance = $_.geometry.horizontal_distance
        vertical_gap = $_.geometry.vertical_gap
    } })
} | ConvertTo-Json -Depth 8
