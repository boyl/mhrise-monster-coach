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
$sacredScrollPlan = @(Get-LongSwordDefaultInputPlan `
    -ActiveSwitchSkill @('sacred_sheathe_combo', 'soaring_kick'))
$sacredApplicable = @($sacredScrollPlan | Where-Object applicable)
$sacredExcluded = @($sacredScrollPlan | Where-Object { -not $_.applicable })
if (($sacredApplicable.id -join ',') -ne 'basic_overhead,thrust,dodge,foresight_attempt' `
    -or ($sacredExcluded.id -join ',') -ne 'special_sheathe,iai_slash_attempt,iai_spirit_attempt') {
    throw 'Sacred Sheathe loadouts must exclude the Special Sheathe/Iai calibration family.'
}
if (@($sacredExcluded | Where-Object required_switch_skill -ne 'special_sheathe_combo').Count -ne 0) {
    throw 'Every excluded Iai-family step must declare its switch-skill prerequisite.'
}
$specialScrollPlan = @(Get-LongSwordDefaultInputPlan `
    -ActiveSwitchSkill @('special_sheathe_combo', 'soaring_kick'))
if (@($specialScrollPlan | Where-Object { -not $_.applicable }).Count -ne 0) {
    throw 'Special Sheathe loadouts must retain the complete seven-step plan.'
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
if (@($operations | Where-Object {
    $_.kind -in @('mouse_click', 'key_click') -and $null -eq $_.PSObject.Properties['role']
}).Count -ne 0 -or @($operations | Where-Object {
    $_.kind -in @('mouse_chord', 'mouse_key_chord') -and $null -eq $_.PSObject.Properties['roles']
}).Count -ne 0) {
    throw 'Every physical default operation must declare its stable semantic input role.'
}

function New-TestBindingContract {
    param([string]$WeaponSpecialMain = 'MOUSE_EX1')
    [pscustomobject]@{
        policy = 'read_only_exact_dictionary_lookup'
        call_failures = 0
        value_failures = 0
        truncated = $false
        targets = @(
            [pscustomobject]@{
                role = 'evade'
                main = [pscustomobject]@{ status = 'resolved'; name = 'Space' }
                sub = [pscustomobject]@{ status = 'resolved'; name = 'None' }
                pad = [pscustomobject]@{ status = 'resolved'; name = 'RD' }
            }
            [pscustomobject]@{
                role = 'primary_attack'
                main = [pscustomobject]@{ status = 'resolved'; name = 'MOUSE_L' }
                sub = [pscustomobject]@{ status = 'resolved'; name = 'None' }
                pad = [pscustomobject]@{ status = 'resolved'; name = 'RU' }
            }
            [pscustomobject]@{
                role = 'secondary_attack'
                main = [pscustomobject]@{ status = 'resolved'; name = 'MOUSE_R' }
                sub = [pscustomobject]@{ status = 'resolved'; name = 'None' }
                pad = [pscustomobject]@{ status = 'resolved'; name = 'RR' }
            }
            [pscustomobject]@{
                role = 'weapon_special'
                main = [pscustomobject]@{ status = 'resolved'; name = $WeaponSpecialMain }
                sub = [pscustomobject]@{ status = 'resolved'; name = 'None' }
                pad = [pscustomobject]@{ status = 'key_unavailable'; name = $null }
            }
        )
    }
}

$runtimeBindings = New-TestBindingContract
$runtimePlan = @(Get-LongSwordCurrentInputPlan -BindingContract $runtimeBindings `
    -ActiveSwitchSkill @('special_sheathe_combo', 'soaring_kick'))
if (@($runtimePlan | Where-Object source -ne 'runtime_stm_input_config').Count -ne 0 `
    -or @($runtimePlan | Where-Object source_policy -ne 'read_only_exact_dictionary_lookup').Count -ne 0) {
    throw 'Resolved plans must expose their runtime binding provenance and policy.'
}
$runtimeForesight = @($runtimePlan | Where-Object id -eq 'foresight_attempt')[0]
if ($runtimeForesight.operations[-1].kind -ne 'mouse_chord' `
    -or ($runtimeForesight.operations[-1].binding_names -join ',') -ne 'MOUSE_EX1,MOUSE_R') {
    throw 'Foresight must resolve its current special/secondary bindings at the adapter boundary.'
}
$runtimeSheathe = @($runtimePlan | Where-Object id -eq 'special_sheathe')[0]
if ($runtimeSheathe.operations[-1].kind -ne 'mouse_key_chord' `
    -or ($runtimeSheathe.operations[-1].binding_names -join ',') -ne 'MOUSE_EX1,Space') {
    throw 'Special Sheathe must resolve its current special/evade bindings at the adapter boundary.'
}

$fallbackBindings = New-TestBindingContract
$fallbackBindings.targets[-1].main.name = 'None'
$fallbackBindings.targets[-1].sub.name = 'MOUSE_EX2'
$fallbackPlan = Get-LongSwordCurrentInputPlan -Step 'foresight_attempt' `
    -BindingContract $fallbackBindings
if (($fallbackPlan.operations[-1].binding_names -join ',') -ne 'MOUSE_EX2,MOUSE_R') {
    throw 'A missing main binding must fall back to the verified keyboard/mouse sub binding.'
}

foreach ($badContract in @(
    (New-TestBindingContract -WeaponSpecialMain 'KeyQ'),
    [pscustomobject]@{
        policy = 'read_only_exact_dictionary_lookup'; call_failures = 1
        value_failures = 0; truncated = $false; targets = $runtimeBindings.targets
    },
    [pscustomobject]@{
        policy = 'read_only_exact_dictionary_lookup'; call_failures = 0
        value_failures = 0; truncated = $true; targets = $runtimeBindings.targets
    },
    [pscustomobject]@{
        policy = 'read_only_exact_dictionary_lookup'; call_failures = 0
        value_failures = 0; truncated = $false; targets = @($runtimeBindings.targets | Select-Object -First 3)
    }
)) {
    $failed = $false
    try { Get-LongSwordCurrentInputPlan -BindingContract $badContract | Out-Null } catch { $failed = $true }
    if (-not $failed) { throw 'Incomplete, failed, or unsupported current bindings must fail closed.' }
}
$padOnlyBindings = New-TestBindingContract
$padOnlyBindings.targets[-1].main.name = 'None'
$padOnlyBindings.targets[-1].sub.name = 'None'
$padOnlyBindings.targets[-1].pad = [pscustomobject]@{ status = 'resolved'; name = 'RT' }
$failed = $false
try { Get-LongSwordCurrentInputPlan -BindingContract $padOnlyBindings | Out-Null } catch { $failed = $true }
if (-not $failed) {
    throw 'The Windows input bridge must not guess a snow.Pad.Button to Win32 input mapping.'
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
if ($inputModuleSource -notmatch 'SendInput' `
    -or $inputModuleSource -match 'static extern void mouse_event' `
    -or $inputModuleSource -match 'static extern void keybd_event' `
    -or $inputModuleSource -notmatch 'Send\(MouseInput\(firstDown, firstData\), MouseInput\(secondDown, secondData\)\)') {
    throw 'The bridge must use batched SendInput events instead of superseded mouse/key event APIs.'
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
$probeSessionSource = Get-Content -LiteralPath `
    (Join-Path $PSScriptRoot '..\tools\run_probe_session.ps1') -Raw
if ($probeSessionSource -match '(?m)^\s*Move-Item -LiteralPath \$temporaryPath' `
    -or $probeSessionSource -notmatch '\[IO\.File\]::Move\(\$temporaryPath, \$Path, \$true\)') {
    throw 'Probe request replacement must use the overwrite-capable atomic file move.'
}
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
if ($inputProbeSource -notmatch 'active_switch_skill_and_runtime_binding_aware' `
    -or $inputProbeSource -notmatch 'expected_step_ids' `
    -or $inputProbeSource -notmatch 'inapplicable_reason' `
    -or $inputProbeSource -notmatch 'Get-LongSwordCurrentInputPlan' `
    -or $inputProbeSource -notmatch 'runtime_stm_input_config' `
    -or $inputProbeSource -notmatch 'binding_policy' `
    -or $inputProbeSource -notmatch '-Definition \$definition') {
    throw 'The runtime plan must be loadout/binding-aware and explain excluded steps.'
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
