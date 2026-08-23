#Requires -Version 7.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\tools\ArenaNavigation.psm1') -Force

function Observation {
    param([double]$TargetX, [double]$TargetZ, [bool]$Ready = $false, [bool]$CombatLayer = $false)
    return [pscustomobject]@{
        same_area = $false
        combat_layer = $CombatLayer
        player_enemy_vertical_gap = if ($CombatLayer) { 1.2 } else { 569.0 }
        arena_transfer_ready = $Ready
        player_position = [pscustomobject]@{ x = 0.0; y = 0.0; z = 0.0 }
        enemy_position = [pscustomobject]@{ x = 10.0; y = -569.0; z = -10.0 }
        arena_navigation = [pscustomobject]@{
            target = [pscustomobject]@{ position = [pscustomobject]@{ x = $TargetX; y = 0.0; z = $TargetZ } }
            camera_forward = [pscustomobject]@{ x = 0.0; z = -1.0 }
            camera_right = [pscustomobject]@{ x = 1.0; z = 0.0 }
        }
    }
}

$forward = Get-ArenaNavigationCommand -Areas (Observation 0 -10)
if ($forward.Action -ne 'hold' -or $forward.Primary -ne 'W' -or $forward.Secondary) {
    throw 'forward world target must map to W'
}
$right = Get-ArenaNavigationCommand -Areas (Observation 10 0)
if ($right.Primary -ne 'D' -or $right.Secondary) { throw 'right world target must map to D' }
$diagonal = Get-ArenaNavigationCommand -Areas (Observation 10 -10)
if ($diagonal.Primary -ne 'W' -or $diagonal.Secondary -ne 'D') {
    throw 'front-right world target must map to W+D'
}
$behind = Get-ArenaNavigationCommand -Areas (Observation 0 10)
if ($behind.Primary -ne 'S') { throw 'rear world target must map to S' }
$interaction = Get-ArenaNavigationCommand -Areas (Observation 0 -10 -Ready $true)
if ($interaction.Action -ne 'interact') { throw 'accessible marker must request one interaction' }
$complete = Get-ArenaNavigationCommand -Areas (Observation 0 -10 -CombatLayer $true)
if ($complete.Action -ne 'complete') { throw 'same combat scene layer must complete navigation' }
$observedTransfer = Observation 0 -10
$observedTransfer.same_area = $false
$observedTransfer.combat_layer = $true
$observedTransfer.player_position = [pscustomobject]@{ x = 3.44058; y = 0.46435; z = -107.37330 }
$observedTransfer.enemy_position = [pscustomobject]@{ x = 5.0; y = -0.7; z = -90.0 }
$observedTransfer.player_enemy_vertical_gap = 1.16435
if ((Get-ArenaNavigationCommand -Areas $observedTransfer).Action -ne 'complete') {
    throw 'real post-transfer evidence must complete even when native area numbers disagree'
}
$sent = [datetimeoffset]::Now
$pending = Get-ArenaNavigationCommand -Areas (Observation 0 -10) -Phase transfer_pending `
    -InteractionSentAt $sent -Now $sent.AddSeconds(5)
if ($pending.Action -ne 'wait') { throw 'pending transfer must lock movement and interaction' }
$timeout = Get-ArenaNavigationCommand -Areas (Observation 0 -10) -Phase transfer_pending `
    -InteractionSentAt $sent -Now $sent.AddSeconds(16)
if ($timeout.Action -ne 'fail') { throw 'expired transfer must fail instead of pressing F again' }
$loading = Observation 0 -10
$loading.player_position.y = 568.0
if ((Get-ArenaNavigationCommand -Areas $loading).Action -ne 'wait') {
    throw 'scene-loading elevation must not produce movement input'
}
$survey = Observation 0 -10
$survey.arena_navigation.PSObject.Properties.Remove('target')
$surveyCommand = Get-ArenaNavigationCommand -Areas $survey
if ($surveyCommand.Action -ne 'survey' -or $surveyCommand.Primary -ne 'W') {
    throw 'unknown map must use a bounded forward survey instead of an unbounded blind run'
}
$away = Get-WorldVectorMovementCommand -Areas (Observation 0 -10) -DeltaX 0 -DeltaZ 10
if ($away.Action -ne 'hold' -or $away.Primary -ne 'S') {
    throw 'world-space away vector must map to S'
}
$bandAreas = Observation 0 -10 -CombatLayer $true
$bandAreas.player_position = [pscustomobject]@{ x = 0.0; y = 0.0; z = -95.0 }
$bandAreas.enemy_position = [pscustomobject]@{ x = 0.0; y = 0.0; z = -100.0 }
$directFlee = Get-ArenaDistanceBandCommand -Areas $bandAreas -TargetDistance 28 -CandidateIndex 0
if ($directFlee.Action -ne 'hold' -or [Math]::Abs($directFlee.TargetPoint.z - -72.0) -gt 0.01) {
    throw 'distance planner must target the radial away point first'
}
$leftDetour = Get-ArenaDistanceBandCommand -Areas $bandAreas -TargetDistance 28 -CandidateIndex 1
$rightDetour = Get-ArenaDistanceBandCommand -Areas $bandAreas -TargetDistance 28 -CandidateIndex 2
if ($leftDetour.TargetPoint.x -ge 0 -or $rightDetour.TargetPoint.x -le 0) {
    throw 'blocked radial flee must expose opposite tangent candidates'
}
$bandAreas.player_position.z = -128.5
if ((Get-ArenaDistanceBandCommand -Areas $bandAreas -TargetDistance 28).Action -ne 'wait') {
    throw 'distance planner must stop inside the requested band'
}

'test_arena_navigation.ps1: PASS'
