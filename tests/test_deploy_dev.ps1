#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$deployScript = Join-Path $repositoryRoot 'tools\deploy_dev.ps1'
$script = Get-Content -LiteralPath $deployScript -Raw
$sourceRoot = Join-Path $repositoryRoot 'reframework'

$allowlistBlock = [regex]::Match($script, '(?s)\$files\s*=\s*@\((.*?)\)')
if (-not $allowlistBlock.Success) { throw 'Deploy allowlist could not be parsed' }
$allowlist = @([regex]::Matches($allowlistBlock.Groups[1].Value, "'([^']+)'") |
    ForEach-Object { $_.Groups[1].Value })
$allowlistSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $allowlist) { [void]$allowlistSet.Add($entry) }

$required = [Collections.Generic.List[string]]::new()
Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'autorun') -Filter '*.lua' -Recurse |
    ForEach-Object { $required.Add([IO.Path]::GetRelativePath($sourceRoot, $_.FullName)) }
Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'data\MHRiseMonsterCoach') -Filter '*.json' |
    Where-Object { $_.Name -notin @('config.json', 'tigrex_calibration.json') -and
        -not $_.Name.StartsWith('runtime_', [StringComparison]::OrdinalIgnoreCase) } |
    ForEach-Object { $required.Add([IO.Path]::GetRelativePath($sourceRoot, $_.FullName)) }
Get-ChildItem -LiteralPath (Join-Path $sourceRoot 'quests') -Filter '*.json' -Recurse |
    ForEach-Object { $required.Add([IO.Path]::GetRelativePath($sourceRoot, $_.FullName)) }

$missing = @($required | Where-Object { -not $allowlistSet.Contains($_) } | Sort-Object -Unique)
if ($missing.Count -gt 0) {
    throw "Deploy allowlist is missing production files: $($missing -join ', ')"
}

$preservedNames = @('config.json', 'tigrex_calibration.json', 'runtime_action_state.json')
foreach ($preserved in $preservedNames) {
    if ($allowlist | Where-Object { [IO.Path]::GetFileName($_) -ieq $preserved }) {
        throw "Deploy allowlist must preserve $preserved"
    }
}
if (-not $script.Contains('Get-FileHash')) { throw 'Deploy script must verify installed hashes' }

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('monster-coach-deploy-' + [Guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe temporary deployment target: $resolvedTestRoot"
}

try {
    $dataRoot = Join-Path $resolvedTestRoot 'reframework\data\MHRiseMonsterCoach'
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $resolvedTestRoot 'MonsterHunterRise.exe') -Force | Out-Null
    $markers = @{}
    foreach ($preserved in $preservedNames) {
        $markers[$preserved] = "preserve-$preserved"
        Set-Content -LiteralPath (Join-Path $dataRoot $preserved) -Value $markers[$preserved] -NoNewline
    }

    & $deployScript -GameRoot $resolvedTestRoot
    $receiptPath = Join-Path $dataRoot 'dev_install_receipt.json'
    if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
        throw 'Verified deployment did not create a receipt'
    }
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.version -ne (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()) {
        throw 'Deployment receipt version does not match source VERSION'
    }
    if (@($receipt.files).Count -ne $allowlist.Count) {
        throw 'Deployment receipt does not cover the complete allowlist'
    }
    foreach ($entry in $receipt.files) {
        $source = Join-Path $sourceRoot $entry.path
        $installed = Join-Path (Join-Path $resolvedTestRoot 'reframework') $entry.path
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $installedHash = (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash
        if ($entry.sha256 -ne $sourceHash -or $installedHash -ne $sourceHash) {
            throw "Installed hash mismatch: $($entry.path)"
        }
    }
    foreach ($preserved in $preservedNames) {
        $actual = Get-Content -LiteralPath (Join-Path $dataRoot $preserved) -Raw
        if ($actual -ne $markers[$preserved]) { throw "Deployment overwrote $preserved" }
    }
}
finally {
    if (Test-Path -LiteralPath $resolvedTestRoot) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host 'test_deploy_dev.ps1: PASS'
