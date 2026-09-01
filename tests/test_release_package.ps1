#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('怪物陪练-release-' + [Guid]::NewGuid().ToString('N'))
$resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
if (-not $resolvedTestRoot.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe test root: $resolvedTestRoot"
}

try {
    $output = Join-Path $resolvedTestRoot '输出'
    $zipOutput = & (Join-Path $repositoryRoot 'tools\build_release.ps1') -OutputDirectory $output
    $zipPath = @($zipOutput)[-1]
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw 'Release ZIP missing' }

    $packageRoot = Join-Path $resolvedTestRoot '解压安装包'
    Expand-Archive -LiteralPath $zipPath -DestinationPath $packageRoot
    foreach ($required in @('INSTALL.cmd', 'UNINSTALL.cmd', 'install.ps1', 'uninstall.ps1',
        'PACKAGE_README.txt', 'manifest.json', 'VERSION', 'LICENSE', 'THIRD_PARTY_NOTICES.md')) {
        if (-not (Test-Path -LiteralPath (Join-Path $packageRoot $required) -PathType Leaf)) {
            throw "Release package is missing $required"
        }
    }

    $manifest = Get-Content -LiteralPath (Join-Path $packageRoot 'manifest.json') -Raw | ConvertFrom-Json
    $gameRoot = Join-Path $resolvedTestRoot '游戏目录'
    $reframeworkRoot = Join-Path $gameRoot 'reframework'
    $dataRoot = Join-Path $reframeworkRoot 'data\MHRiseMonsterCoach'
    New-Item -ItemType Directory -Path (Join-Path $reframeworkRoot 'plugins') -Force | Out-Null
    New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $gameRoot 'MonsterHunterRise.exe') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $reframeworkRoot 'plugins\RiseQuestLoader.dll') -Force | Out-Null

    $preserved = @{
        'config.json' = '保留-用户配置'
        'tigrex_calibration.json' = '保留-校准数据'
        'runtime_action_state.json' = '保留-运行证据'
    }
    foreach ($name in $preserved.Keys) {
        Set-Content -LiteralPath (Join-Path $dataRoot $name) -Value $preserved[$name] -NoNewline
    }
    $existingRelative = 'autorun\MHRiseMonsterCoach.lua'
    $existingPath = Join-Path $reframeworkRoot $existingRelative
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($existingPath)) -Force | Out-Null
    Set-Content -LiteralPath $existingPath -Value 'previous-version' -NoNewline

    & (Join-Path $packageRoot 'install.ps1') -GameRoot $gameRoot -NoElevation -NoPause
    $receiptPath = Join-Path $dataRoot 'install_receipt.json'
    $receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if ($receipt.version -ne (Get-Content -LiteralPath (Join-Path $packageRoot 'VERSION') -Raw).Trim()) {
        throw 'Public install receipt version mismatch'
    }
    if (@($receipt.files).Count -ne @($manifest.files).Count) { throw 'Public receipt file count mismatch' }
    foreach ($entry in @($manifest.files)) {
        $source = Join-Path (Join-Path $packageRoot 'Payload\reframework') ([string]$entry.path)
        $installed = Join-Path $reframeworkRoot ([string]$entry.path)
        if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne [string]$entry.sha256 -or
            (Get-FileHash -LiteralPath $installed -Algorithm SHA256).Hash -ne [string]$entry.sha256) {
            throw "Public package hash mismatch: $($entry.path)"
        }
    }
    foreach ($name in $preserved.Keys) {
        if ((Get-Content -LiteralPath (Join-Path $dataRoot $name) -Raw) -ne $preserved[$name]) {
            throw "Public installer overwrote $name"
        }
    }

    & (Join-Path $packageRoot 'uninstall.ps1') -GameRoot $gameRoot -NoElevation -NoPause
    if ((Get-Content -LiteralPath $existingPath -Raw) -ne 'previous-version') {
        throw 'Uninstall did not restore the pre-existing entry point'
    }
    $newFile = Join-Path $reframeworkRoot 'autorun\MHRiseMonsterCoach\app.lua'
    if (Test-Path -LiteralPath $newFile -PathType Leaf) { throw 'Uninstall did not remove a newly installed file' }
    foreach ($name in $preserved.Keys) {
        if ((Get-Content -LiteralPath (Join-Path $dataRoot $name) -Raw) -ne $preserved[$name]) {
            throw "Public uninstaller changed $name"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $dataRoot 'last_uninstall_receipt.json') -PathType Leaf)) {
        throw 'Public uninstaller did not write an audit receipt'
    }

    $missingDependencyRoot = Join-Path $resolvedTestRoot '缺少依赖的游戏'
    New-Item -ItemType Directory -Path (Join-Path $missingDependencyRoot 'reframework') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $missingDependencyRoot 'MonsterHunterRise.exe') -Force | Out-Null
    $dependencyRejected = $false
    try {
        & (Join-Path $packageRoot 'install.ps1') -GameRoot $missingDependencyRoot -NoElevation -NoPause
    } catch {
        $dependencyRejected = $_.Exception.Message -match 'RiseQuestLoader'
    }
    if (-not $dependencyRejected) { throw 'Missing RiseQuestLoader was not rejected before installation' }
    if (Test-Path -LiteralPath (Join-Path $missingDependencyRoot 'reframework\autorun\MHRiseMonsterCoach.lua')) {
        throw 'Dependency preflight wrote a production file before rejecting the package'
    }

    $rollbackRoot = Join-Path $resolvedTestRoot '中途失败回滚游戏'
    $rollbackFramework = Join-Path $rollbackRoot 'reframework'
    New-Item -ItemType Directory -Path (Join-Path $rollbackFramework 'plugins') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $rollbackFramework 'autorun') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $rollbackRoot 'MonsterHunterRise.exe') -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $rollbackFramework 'plugins\RiseQuestLoader.dll') -Force | Out-Null
    $rollbackEntry = Join-Path $rollbackFramework 'autorun\MHRiseMonsterCoach.lua'
    Set-Content -LiteralPath $rollbackEntry -Value 'rollback-original' -NoNewline
    Set-Content -LiteralPath (Join-Path $rollbackFramework 'autorun\MHRiseMonsterCoach') `
        -Value 'blocks-required-directory' -NoNewline
    $rollbackTriggered = $false
    try {
        & (Join-Path $packageRoot 'install.ps1') -GameRoot $rollbackRoot -NoElevation -NoPause
    } catch {
        $rollbackTriggered = $true
    }
    if (-not $rollbackTriggered) { throw 'The intentional mid-copy obstruction did not fail installation' }
    if ((Get-Content -LiteralPath $rollbackEntry -Raw) -ne 'rollback-original') {
        throw 'Transactional failure did not restore the pre-existing entry point'
    }
    if (Test-Path -LiteralPath (Join-Path $rollbackFramework 'data\MHRiseMonsterCoach\install_receipt.json')) {
        throw 'Failed transaction left a successful install receipt'
    }
} finally {
    if (Test-Path -LiteralPath $resolvedTestRoot -PathType Container) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Host 'test_release_package.ps1: PASS'
