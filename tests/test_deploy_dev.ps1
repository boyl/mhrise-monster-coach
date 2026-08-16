#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$script = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\tools\deploy_dev.ps1') -Raw

$required = @(
    "'autorun\MHRiseMonsterCoach\font.lua'",
    "'autorun\MHRiseMonsterCoach\player_state_reader.lua'",
    "'autorun\MHRiseMonsterCoach\long_sword_switch_skills.lua'",
    "'autorun\MHRiseMonsterCoach\input_adapter.lua'",
    "'autorun\MHRiseMonsterCoach\response_long_sword.lua'",
    "'data\MHRiseMonsterCoach\long_sword_knowledge.json'",
    "'data\MHRiseMonsterCoach\tigrex_static_ai.json'",
    "'quests\q200032001.json'"
)
foreach ($entry in $required) {
    if (-not $script.Contains($entry)) { throw "Deploy allowlist is missing $entry" }
}
foreach ($preserved in @('config.json', 'tigrex_calibration.json', 'runtime_action_state.json')) {
    if ($script -match "(?m)^\s*'$([regex]::Escape($preserved))',?\s*$") {
        throw "Deploy allowlist must preserve $preserved"
    }
}
if (-not $script.Contains('Get-FileHash')) { throw 'Deploy script must verify installed hashes' }

Write-Host 'test_deploy_dev.ps1: PASS'
