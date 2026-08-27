#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$inputModule = Import-Module `
    (Join-Path $PSScriptRoot '..\tools\PlayerActionInput.psm1') -Force -PassThru
Initialize-MonsterCoachInputBridge
if (-not ('MonsterCoachPlayerInputBridge' -as [type])) {
    throw 'The allowlisted Windows input bridge did not compile.'
}
if ([MonsterCoachPlayerInputBridge]::OwnsForeground([IntPtr]::Zero) `
    -or [MonsterCoachPlayerInputBridge]::MouseClick([IntPtr]::Zero, 'left')) {
    throw 'The input bridge must fail closed when it does not own a valid foreground window.'
}

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
if (@($plan | Where-Object win32_xbutton_source_url -ne 'https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-mouse_event').Count -ne 0) {
    throw 'Win32 X-button mapping source URL drifted.'
}
$allowedKinds = @(
    'mouse_click', 'key_click', 'delay', 'mouse_chord', 'mouse_key_chord',
    'wait_for_action_signal'
)
$operations = @($plan.operations)
if (@($operations | Where-Object kind -notin $allowedKinds).Count -ne 0) {
    throw 'The plan contains a non-allowlisted raw input operation.'
}
if ((Get-LongSwordDefaultInputPlan -Step 'foresight_attempt').operations[-1].kind -ne 'mouse_chord') {
    throw 'Foresight must remain a simultaneous input chord.'
}
$foresight = Get-LongSwordDefaultInputPlan -Step 'foresight_attempt'
if ($foresight.operations[1].kind -ne 'wait_for_action_signal' `
    -or $foresight.expected_node_prefixes -notcontains 'atk.atk_147.atk_147') {
    throw 'Foresight must wait for the attack window and require its semantic node.'
}
$iaiSpirit = Get-LongSwordDefaultInputPlan -Step 'iai_spirit_attempt'
if (@($iaiSpirit.operations | Where-Object kind -eq 'wait_for_action_signal').Count -ne 2 `
    -or $iaiSpirit.expected_node_prefixes -notcontains 'atk.atk151.atk_155') {
    throw 'Iai Spirit Slash must wait for both attack and sheathe states.'
}
if (@($operations | Where-Object kind -eq 'delay').Count -ne 0) {
    throw 'Compound actions must not depend on fixed timing delays.'
}
$sideButtons = @($operations | ForEach-Object {
    if ($_.button -in @('x1', 'x2')) { $_.button }
    if ($_.first -in @('x1', 'x2')) { $_.first }
    if ($_.second -in @('x1', 'x2')) { $_.second }
})
if ($sideButtons.Count -ne 5 -or @($sideButtons | Where-Object { $_ -ne 'x1' }).Count -ne 0) {
    throw 'Capcom Mouse Button 4 must map to Win32 XBUTTON1 in every Long Sword chord.'
}
$inputModuleSource = Get-Content -LiteralPath `
    (Join-Path $PSScriptRoot '..\tools\PlayerActionInput.psm1') -Raw
if ($inputModuleSource -notmatch 'Read-MonsterCoachActionSignal' `
    -or $inputModuleSource -notmatch 'RevisionCursor') {
    throw 'The input adapter must own its live-signal cursor and retry boundary.'
}
if ($inputModuleSource -notmatch 'AcquireFocus' `
    -or $inputModuleSource -notmatch 'OwnsForeground' `
    -or $inputModuleSource -match 'if \(!Focus\(window\)\)') {
    throw 'The input bridge must acquire focus once and abort instead of repeatedly stealing it.'
}
if ($inputModuleSource -notmatch 'System\.TimeoutException' `
    -or $inputModuleSource -notmatch 'System\.OperationCanceledException') {
    throw 'Action-signal timeout and player focus takeover must remain distinct errors.'
}
$signalFixture = Join-Path $env:TEMP "monster-coach-action-signal-$([Guid]::NewGuid().ToString('N')).json"
try {
    [ordered]@{
        revision = 2
        current = [ordered]@{ node_name = 'atk.atk_101.test' }
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $signalFixture -Encoding utf8
    $cursor = 1
    $operation = [pscustomobject]@{
        node_prefixes = @('atk.atk_101.')
        timeout_milliseconds = 50
    }
    $matched = Wait-MonsterCoachActionSignal -Path $signalFixture `
        -Operation $operation -RevisionCursor ([ref]$cursor)
    if (-not $matched -or $cursor -ne 2) {
        throw 'The live-signal adapter did not match and advance the revision cursor.'
    }
} finally {
    Remove-Item -LiteralPath $signalFixture -Force -ErrorAction SilentlyContinue
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
if ($inputProbeSource -notmatch 'observed -ne \$report\.summary\.requested') {
    throw 'A partial action batch must not pass the complete calibration gate.'
}
if ($inputProbeSource -notmatch 'Wait-ForStepObservation' `
    -or $inputProbeSource -notmatch 'Test-IdleEvidence \$after\.current') {
    throw 'Each input step must wait for persisted evidence and a stable action tail.'
}
if ($inputProbeSource -notmatch 'runtime_player_action_signal\.json' `
    -or $inputProbeSource -notmatch 'semantic_observed' `
    -or $inputProbeSource -notmatch 'draw preparation') {
    throw 'Calibration must use live transitions, semantic gates, and a separate draw setup.'
}
if ($inputProbeSource -notmatch 'acquire_once_abort_on_player_takeover' `
    -or $inputProbeSource -notmatch 'Clear-TerminalProbeRequest') {
    throw 'Calibration must expose its focus policy and clear terminal probe requests.'
}
if ($inputProbeSource -notmatch "status = 'input_failed'" `
    -or $inputProbeSource -notmatch "'action_signal_timeout'" `
    -or $inputProbeSource -notmatch 'player_takeover = \$takeoverDetected') {
    throw 'The batch must preserve partial evidence and classify expected input failures.'
}
$runtimeSource = Get-Content -LiteralPath `
    (Join-Path $PSScriptRoot '..\reframework\autorun\MHRiseMonsterCoach\runtime.lua') -Raw
if ($runtimeSource -notmatch 'set_action_live_signal_enabled\(player_calibration\)') {
    throw 'Live action signals must remain scoped to the temporary calibration quest.'
}

$calibrationSource = Get-Content -LiteralPath `
    (Join-Path $PSScriptRoot '..\tools\run_player_action_calibration.ps1') -Raw
if ($calibrationSource -notmatch '-SkipDeployment') {
    throw 'The calibration wrapper must not redeploy after staging its temporary quest.'
}
if ($calibrationSource -notmatch 'analyze_player_action_input_probe\.py') {
    throw 'The calibration wrapper must automatically generate an auditable candidate analysis.'
}
if ($calibrationSource -notmatch 'Resolve-VerifiedPython' `
    -or $calibrationSource -notmatch 'WindowsApps') {
    throw 'Calibration must reject the WindowsApps Python alias and resolve a real interpreter.'
}
if ($calibrationSource -notmatch 'Calibration refused because Monster Hunter Rise is already running' `
    -or $calibrationSource -notmatch '\[switch\]\$CloseGameAfterCalibration' `
    -or $calibrationSource -notmatch 'Clear-TerminalProbeRequest') {
    throw 'The wrapper must refuse a live game, leave the launched game open by default, and clean terminal requests.'
}

Write-Host 'test_player_action_input_plan.ps1: PASS'
