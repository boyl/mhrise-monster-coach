Set-StrictMode -Version Latest

function Get-PlanarLength {
    param([double]$X, [double]$Z)
    return [Math]::Sqrt($X * $X + $Z * $Z)
}

function Get-WorldVectorMovementCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Areas,
        [Parameter(Mandatory)][double]$DeltaX,
        [Parameter(Mandatory)][double]$DeltaZ
    )
    $navigation = $Areas.arena_navigation
    $forward = $navigation.camera_forward
    $right = $navigation.camera_right
    if ($null -eq $forward -or $null -eq $right) {
        return [pscustomobject]@{ Action = 'wait'; Reason = 'camera navigation basis is unavailable' }
    }
    $distance = Get-PlanarLength -X $DeltaX -Z $DeltaZ
    $forwardLength = Get-PlanarLength -X ([double]$forward.x) -Z ([double]$forward.z)
    $rightLength = Get-PlanarLength -X ([double]$right.x) -Z ([double]$right.z)
    if ($distance -lt 0.001 -or $forwardLength -lt 0.001 -or $rightLength -lt 0.001) {
        return [pscustomobject]@{ Action = 'wait'; Reason = 'navigation basis is degenerate'; Distance = $distance }
    }
    $directionX = $DeltaX / $distance
    $directionZ = $DeltaZ / $distance
    $forwardDot = $directionX * ([double]$forward.x / $forwardLength) +
        $directionZ * ([double]$forward.z / $forwardLength)
    $rightDot = $directionX * ([double]$right.x / $rightLength) +
        $directionZ * ([double]$right.z / $rightLength)
    $primary = if ($forwardDot -ge 0) { 'W' } else { 'S' }
    $secondary = if ($rightDot -ge 0) { 'D' } else { 'A' }
    if ([Math]::Abs($forwardDot) -lt 0.32) { $primary = $null }
    if ([Math]::Abs($rightDot) -lt 0.32) { $secondary = $null }
    if ($null -eq $primary -and $null -eq $secondary) {
        $primary = if ([Math]::Abs($forwardDot) -ge [Math]::Abs($rightDot)) {
            if ($forwardDot -ge 0) { 'W' } else { 'S' }
        } else {
            if ($rightDot -ge 0) { 'D' } else { 'A' }
        }
    }
    if ($null -eq $primary) { $primary = $secondary; $secondary = $null }
    return [pscustomobject]@{
        Action = 'hold'; Primary = $primary; Secondary = $secondary; Sprint = $true
        Distance = $distance; ForwardDot = $forwardDot; RightDot = $rightDot
        Reason = 'move along measured world-space direction'
    }
}

function Get-ArenaNavigationCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Areas,
        [ValidateSet('navigate', 'transfer_pending')][string]$Phase = 'navigate',
        [datetimeoffset]$Now = [datetimeoffset]::Now,
        $InteractionSentAt,
        [int]$TransferTimeoutSeconds = 15
    )

    $combatLayerProperty = $Areas.PSObject.Properties['combat_layer']
    if ($combatLayerProperty -and $combatLayerProperty.Value -eq $true) {
        return [pscustomobject]@{
            Action = 'complete'
            Reason = 'player and target occupy the same combat scene layer'
        }
    }
    if ($Phase -eq 'transfer_pending') {
        if ($null -eq $InteractionSentAt) {
            return [pscustomobject]@{ Action = 'fail'; Reason = 'transfer_pending has no interaction timestamp' }
        }
        $elapsed = ($Now - [datetimeoffset]$InteractionSentAt).TotalSeconds
        if ($elapsed -ge $TransferTimeoutSeconds) {
            return [pscustomobject]@{
                Action = 'fail'
                Reason = "native arena transfer did not complete within $TransferTimeoutSeconds seconds"
                ElapsedSeconds = $elapsed
            }
        }
        return [pscustomobject]@{
            Action = 'wait'
            Reason = 'native arena transfer is pending; movement and repeated interaction are locked'
            ElapsedSeconds = $elapsed
        }
    }
    if ($Areas.arena_transfer_ready -eq $true) {
        return [pscustomobject]@{ Action = 'interact'; Reason = 'native area-move marker is accessible' }
    }

    $navigationProperty = $Areas.PSObject.Properties['arena_navigation']
    $playerProperty = $Areas.PSObject.Properties['player_position']
    $navigation = if ($navigationProperty) { $navigationProperty.Value } else { $null }
    $player = if ($playerProperty) { $playerProperty.Value } else { $null }
    $targetProperty = if ($null -ne $navigation) {
        $navigation.PSObject.Properties['target']
    } else { $null }
    $target = if ($targetProperty -and $null -ne $targetProperty.Value) {
        $positionProperty = $targetProperty.Value.PSObject.Properties['position']
        if ($positionProperty) { $positionProperty.Value } else { $null }
    } else { $null }
    $forwardProperty = if ($null -ne $navigation) {
        $navigation.PSObject.Properties['camera_forward']
    } else { $null }
    $rightProperty = if ($null -ne $navigation) {
        $navigation.PSObject.Properties['camera_right']
    } else { $null }
    $forward = if ($forwardProperty) { $forwardProperty.Value } else { $null }
    $right = if ($rightProperty) { $rightProperty.Value } else { $null }
    if ($null -eq $player -or $null -eq $forward -or $null -eq $right) {
        return [pscustomobject]@{ Action = 'wait'; Reason = 'navigation geometry is not available yet' }
    }
    if ($null -eq $target) {
        return [pscustomobject]@{
            Action = 'survey'
            Primary = 'W'
            Secondary = $null
            Sprint = $true
            Reason = 'bounded first-map survey along the camera forward ray'
        }
    }
    if ($player.PSObject.Properties['y'] -and $target.PSObject.Properties['y'] -and
        [Math]::Abs([double]$player.y - [double]$target.y) -gt 50.0) {
        return [pscustomobject]@{
            Action = 'wait'
            Reason = 'player is still outside the marker elevation band during scene loading'
        }
    }

    $deltaX = [double]$target.x - [double]$player.x
    $deltaZ = [double]$target.z - [double]$player.z
    return Get-WorldVectorMovementCommand -Areas $Areas -DeltaX $deltaX -DeltaZ $deltaZ
}

Export-ModuleMember -Function Get-ArenaNavigationCommand, Get-WorldVectorMovementCommand
