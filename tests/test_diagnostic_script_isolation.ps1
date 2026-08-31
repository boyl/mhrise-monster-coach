#Requires -Version 7.0
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\tools\DiagnosticScriptIsolation.psm1') -Force

$root = Join-Path ([IO.Path]::GetTempPath()) ('monster-coach-isolation-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $intercept = Join-Path $root 'LihuoSnSVfxInterceptPoc.lua'
    $preflight = Join-Path $root 'LihuoSnSVfxYunPreflight.lua'
    $unrelated = Join-Path $root 'UserMod.lua'
    Set-Content -LiteralPath $intercept -Value 'intercept' -Encoding utf8
    Set-Content -LiteralPath $preflight -Value 'preflight' -Encoding utf8
    Set-Content -LiteralPath $unrelated -Value 'untouched' -Encoding utf8

    $entries = @(Suspend-MonsterCoachKnownDiagnosticScripts -AutorunRoot $root -SessionId 'abc123')
    if ($entries.Count -ne 2) { throw 'Expected exactly two allowlisted diagnostic scripts.' }
    if ((Test-Path -LiteralPath $intercept) -or (Test-Path -LiteralPath $preflight)) {
        throw 'Allowlisted diagnostic loaders were not suspended.'
    }
    if (-not (Test-Path -LiteralPath $unrelated)) {
        throw 'Unrelated autorun script was changed.'
    }
    foreach ($entry in $entries) {
        if (-not (Test-Path -LiteralPath $entry.suspended) -or
            (Get-FileHash -LiteralPath $entry.suspended -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw 'Suspended diagnostic script hash contract failed.'
        }
    }

    $restored = @(Restore-MonsterCoachKnownDiagnosticScripts -Suspended $entries)
    if ($restored.Count -ne 2 -or -not (Test-Path -LiteralPath $intercept) -or
        -not (Test-Path -LiteralPath $preflight)) {
        throw 'Diagnostic scripts were not restored.'
    }
    if (Get-ChildItem -LiteralPath $root -Filter '*.disabled' -File) {
        throw 'Disabled diagnostic files remained after restoration.'
    }

    $empty = @(Suspend-MonsterCoachKnownDiagnosticScripts -AutorunRoot (Join-Path $root 'missing') `
        -SessionId 'empty')
    if ($empty.Count -ne 0) { throw 'Missing autorun roots must be a no-op.' }

    $conflict = "$preflight.monster-coach-rollback.disabled"
    Set-Content -LiteralPath $conflict -Value 'existing conflict' -Encoding utf8
    $failed = $false
    try {
        Suspend-MonsterCoachKnownDiagnosticScripts -AutorunRoot $root -SessionId 'rollback'
    } catch {
        $failed = $true
    }
    if (-not $failed) { throw 'Existing isolation destinations must fail closed.' }
    if (-not (Test-Path -LiteralPath $intercept) -or -not (Test-Path -LiteralPath $preflight)) {
        throw 'Partial isolation failure did not roll back earlier moves.'
    }
    if (Test-Path -LiteralPath "$intercept.monster-coach-rollback.disabled") {
        throw 'Partial isolation rollback left the first loader disabled.'
    }

    $probeSessionSource = Get-Content -LiteralPath `
        (Join-Path $PSScriptRoot '..\tools\run_probe_session.ps1') -Raw
    $suspendOffset = $probeSessionSource.IndexOf('Suspend-MonsterCoachKnownDiagnosticScripts')
    $launchOffset = $probeSessionSource.IndexOf("Start-Process -FilePath 'steam://run/1446780'")
    $restoreOffset = $probeSessionSource.LastIndexOf('Restore-MonsterCoachKnownDiagnosticScripts')
    if ($suspendOffset -lt 0 -or $launchOffset -lt 0 -or $restoreOffset -lt 0 -or
        $suspendOffset -ge $launchOffset -or $restoreOffset -le $launchOffset) {
        throw 'Probe integration must suspend before launch and restore after the run.'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'test_diagnostic_script_isolation.ps1: PASS'
