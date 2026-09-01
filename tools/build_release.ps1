#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\releases')
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $repositoryRoot 'reframework'
$sourceManifestPath = Join-Path $PSScriptRoot 'release_manifest.json'
$version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
$manifest = Get-Content -LiteralPath $sourceManifestPath -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or @($manifest.files).Count -eq 0) {
    throw 'Release manifest is invalid or empty.'
}
$fileSet = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($relative in @($manifest.files)) {
    if (-not $fileSet.Add(([string]$relative).Replace('\', '/'))) {
        throw "Release manifest contains a duplicate path: $relative"
    }
}
foreach ($preserved in @($manifest.preserved_files)) {
    if ($fileSet.Contains(([string]$preserved).Replace('\', '/'))) {
        throw "Release manifest attempts to overwrite preserved data: $preserved"
    }
}

$resolvedOutput = [IO.Path]::GetFullPath($OutputDirectory)
New-Item -ItemType Directory -Path $resolvedOutput -Force | Out-Null
$packageName = 'MHRiseMonsterCoach-' + $version
$stagingRoot = Join-Path $resolvedOutput ('.' + $packageName + '-staging-' + [Guid]::NewGuid().ToString('N'))
$resolvedStaging = [IO.Path]::GetFullPath($stagingRoot)
if (-not $resolvedStaging.StartsWith($resolvedOutput.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing unsafe staging path: $resolvedStaging"
}
$zipPath = Join-Path $resolvedOutput ($packageName + '.zip')

try {
    $payloadRoot = Join-Path $resolvedStaging 'Payload\reframework'
    New-Item -ItemType Directory -Path $payloadRoot -Force | Out-Null
    $packageFiles = @()
    foreach ($relativeSource in @($manifest.files)) {
        $relative = ([string]$relativeSource).Replace('/', [IO.Path]::DirectorySeparatorChar)
        $source = [IO.Path]::GetFullPath((Join-Path $sourceRoot $relative))
        $sourcePrefix = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
        if (-not $source.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase) -or
            -not (Test-Path -LiteralPath $source -PathType Leaf)) {
            throw "Release source is missing or outside reframework: $relativeSource"
        }
        $destination = Join-Path $payloadRoot $relative
        New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force | Out-Null
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $hash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        $packageFiles += [ordered]@{ path = ([string]$relativeSource).Replace('\', '/'); sha256 = $hash }
    }

    foreach ($name in @('INSTALL.cmd', 'UNINSTALL.cmd', 'install.ps1', 'uninstall.ps1', 'PACKAGE_README.txt')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot (Join-Path 'installer' $name)) `
            -Destination (Join-Path $resolvedStaging $name) -Force
    }
    foreach ($name in @('LICENSE', 'THIRD_PARTY_NOTICES.md')) {
        Copy-Item -LiteralPath (Join-Path $repositoryRoot $name) -Destination (Join-Path $resolvedStaging $name) -Force
    }
    Set-Content -LiteralPath (Join-Path $resolvedStaging 'VERSION') -Value $version -Encoding utf8 -NoNewline
    [ordered]@{
        schema_version = 1
        product = $manifest.product
        steam_app_id = $manifest.steam_app_id
        game_executable = $manifest.game_executable
        required_dependency_files = @($manifest.required_dependency_files)
        preserved_files = @($manifest.preserved_files)
        files = $packageFiles
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $resolvedStaging 'manifest.json') -Encoding utf8

    if (Test-Path -LiteralPath $zipPath -PathType Leaf) { Remove-Item -LiteralPath $zipPath -Force }
    Compress-Archive -Path (Join-Path $resolvedStaging '*') -DestinationPath $zipPath -CompressionLevel Optimal
    if (-not (Test-Path -LiteralPath $zipPath -PathType Leaf)) { throw 'Release ZIP was not created.' }
    Write-Host "Release package built: $zipPath" -ForegroundColor Green
    Write-Output $zipPath
} finally {
    if (Test-Path -LiteralPath $resolvedStaging -PathType Container) {
        Remove-Item -LiteralPath $resolvedStaging -Recurse -Force
    }
}
