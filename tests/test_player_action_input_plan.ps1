#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\tools\PlayerActionInput.psm1') -Force

$plan = @(Get-LongSwordDefaultInputPlan)
$expectedIds = @(
    'basic_overhead', 'thrust', 'dodge', 'foresight_attempt',
    'special_sheathe', 'iai_slash_attempt', 'iai_spirit_attempt'
)
if (($plan.id -join ',') -ne ($expectedIds -join ',')) {
    throw "Unexpected plan order: $($plan.id -join ',')"
}
if (@($plan | Where-Object source -ne 'capcom_official_windows_default_controls').Count -ne 0) {
    throw 'Every step must retain the official default-control provenance.'
}
if (@($plan | Where-Object source_url -ne 'https://game.capcom.com/manual/Multi-Platform/zh-hans/windows/page/3/6').Count -ne 0) {
    throw 'Official control source URL drifted.'
}
$allowedKinds = @('mouse_click', 'key_click', 'delay', 'mouse_chord', 'mouse_key_chord')
$operations = @($plan.operations)
if (@($operations | Where-Object kind -notin $allowedKinds).Count -ne 0) {
    throw 'The plan contains a non-allowlisted raw input operation.'
}
if ((Get-LongSwordDefaultInputPlan -Step 'foresight_attempt').operations[-1].kind -ne 'mouse_chord') {
    throw 'Foresight must remain a simultaneous input chord.'
}
$failed = $false
try { Get-LongSwordDefaultInputPlan -Step 'unknown' | Out-Null } catch { $failed = $true }
if (-not $failed) { throw 'Unknown steps must fail closed.' }

$inputProbeSource = Get-Content -LiteralPath `
    (Join-Path $PSScriptRoot '..\tools\run_player_action_input_probe.ps1') -Raw
if ($inputProbeSource -notmatch '\[int\]\$InitialSettleSeconds = 12') {
    throw 'The automated calibration must retain the bounded arena-arrival settle.'
}
if ($inputProbeSource -notmatch [regex]::Escape('atk.atk_wait.atk_wait_main.atk_wait_main')) {
    throw 'Drawn Long Sword neutral must remain an accepted inter-step state.'
}
if ($inputProbeSource -notmatch '-SkipDeployment:\$SkipDeployment') {
    throw 'The nested player-action preflight must be able to reuse a verified deployment.'
}

$calibrationSource = Get-Content -LiteralPath `
    (Join-Path $PSScriptRoot '..\tools\run_player_action_calibration.ps1') -Raw
if ($calibrationSource -notmatch '-SkipDeployment') {
    throw 'The calibration wrapper must not redeploy after staging its temporary quest.'
}

Write-Host 'test_player_action_input_plan.ps1: PASS'
