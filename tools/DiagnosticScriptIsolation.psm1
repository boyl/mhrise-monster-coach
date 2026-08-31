Set-StrictMode -Version Latest

$script:KnownDiagnosticStartupScripts = @(
    'LihuoSnSVfxInterceptPoc.lua',
    'LihuoSnSVfxYunPreflight.lua'
)

function Suspend-MonsterCoachKnownDiagnosticScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$AutorunRoot,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_-]+$')][string]$SessionId
    )

    $resolvedRoot = [IO.Path]::GetFullPath($AutorunRoot)
    if (-not (Test-Path -LiteralPath $resolvedRoot -PathType Container)) {
        return @()
    }

    $suspended = [Collections.Generic.List[object]]::new()
    try {
        foreach ($name in $script:KnownDiagnosticStartupScripts) {
            $source = Join-Path $resolvedRoot $name
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }

            $destination = "$source.monster-coach-$SessionId.disabled"
            if (Test-Path -LiteralPath $destination) {
                throw "Diagnostic isolation destination already exists: $destination"
            }
            $hash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
            Move-Item -LiteralPath $source -Destination $destination
            [void]$suspended.Add([pscustomobject][ordered]@{
                name = $name
                source = $source
                suspended = $destination
                sha256 = $hash
            })
        }
    } catch {
        $suspensionError = $_
        if ($suspended.Count -gt 0) {
            try {
                Restore-MonsterCoachKnownDiagnosticScripts -Suspended @($suspended) | Out-Null
            } catch {
                throw "Diagnostic isolation failed and rollback also failed: $($suspensionError.Exception.Message); rollback: $($_.Exception.Message)"
            }
        }
        throw $suspensionError
    }
    return @($suspended)
}

function Restore-MonsterCoachKnownDiagnosticScripts {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$Suspended = @())

    $restored = [Collections.Generic.List[object]]::new()
    foreach ($entry in @($Suspended)) {
        if ($null -eq $entry) { continue }
        $source = [IO.Path]::GetFullPath([string]$entry.source)
        $disabled = [IO.Path]::GetFullPath([string]$entry.suspended)
        if (-not (Test-Path -LiteralPath $disabled -PathType Leaf)) {
            throw "Suspended diagnostic script is missing: $disabled"
        }
        if (Test-Path -LiteralPath $source) {
            throw "Refusing to overwrite a restored diagnostic script: $source"
        }
        $actualHash = (Get-FileHash -LiteralPath $disabled -Algorithm SHA256).Hash
        if ($actualHash -ne [string]$entry.sha256) {
            throw "Suspended diagnostic script changed during acceptance: $disabled"
        }
        Move-Item -LiteralPath $disabled -Destination $source
        [void]$restored.Add([pscustomobject][ordered]@{
            name = [string]$entry.name
            source = $source
            sha256 = $actualHash
        })
    }
    return @($restored)
}

Export-ModuleMember -Function Suspend-MonsterCoachKnownDiagnosticScripts,
    Restore-MonsterCoachKnownDiagnosticScripts
