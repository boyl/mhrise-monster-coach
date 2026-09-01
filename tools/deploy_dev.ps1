#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot,
    [switch]$WaitForExit,
    [switch]$Relaunch
)

$ErrorActionPreference = 'Stop'

function Resolve-GameRoot {
    param([string]$RequestedRoot)

    $candidates = [Collections.Generic.List[string]]::new()
    if ($RequestedRoot) { $candidates.Add($RequestedRoot) }

    $runningGame = Get-Process -Name 'MonsterHunterRise' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($runningGame -and $runningGame.Path) {
        $candidates.Add([IO.Path]::GetDirectoryName($runningGame.Path))
    }

    $steam = Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($steam.SteamPath) {
        $candidates.Add((Join-Path $steam.SteamPath 'steamapps\common\MonsterHunterRise'))
    }
    if (${env:ProgramFiles(x86)}) {
        $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\MonsterHunterRise'))
    }

    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        $resolved = [IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath (Join-Path $resolved 'MonsterHunterRise.exe') -PathType Leaf) {
            return $resolved
        }
    }
    throw 'Monster Hunter Rise installation was not found. Pass -GameRoot explicitly.'
}

$resolvedGameRoot = Resolve-GameRoot $GameRoot
$processes = @(Get-Process -Name 'MonsterHunterRise' -ErrorAction SilentlyContinue | Where-Object {
    if (-not $_.Path) { return $true }
    $processRoot = [IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($_.Path))
    return $processRoot.Equals($resolvedGameRoot, [StringComparison]::OrdinalIgnoreCase)
})
if ($processes.Count -gt 0) {
    if (-not $WaitForExit) {
        throw 'MonsterHunterRise is running. Use -WaitForExit or exit the game first.'
    }
    Write-Host 'Waiting for Monster Hunter Rise to exit safely...'
    $processes | Wait-Process
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$sourceRoot = Join-Path $repositoryRoot 'reframework'
$destinationRoot = Join-Path $resolvedGameRoot 'reframework'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Source directory was not found: $sourceRoot"
}
if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) {
    throw "REFramework directory was not found: $destinationRoot"
}

# The same manifest drives development deployment and public release packaging.
# It deliberately excludes config, calibration, runtime evidence, logs and dumps.
$manifestPath = Join-Path $PSScriptRoot 'release_manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw "Release manifest was not found: $manifestPath"
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
$files = @($manifest.files | ForEach-Object { ([string]$_).Replace('/', [IO.Path]::DirectorySeparatorChar) })
if ($manifest.schema_version -ne 1 -or $files.Count -eq 0) {
    throw 'Release manifest is invalid or empty.'
}

$installed = @()
foreach ($relativePath in $files) {
    $sourceFile = Join-Path $sourceRoot $relativePath
    $destinationFile = Join-Path $destinationRoot $relativePath
    if (-not (Test-Path -LiteralPath $sourceFile -PathType Leaf)) {
        throw "Required source file was not found: $sourceFile"
    }
    $destinationDirectory = [IO.Path]::GetDirectoryName($destinationFile)
    if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    Copy-Item -LiteralPath $sourceFile -Destination $destinationFile -Force
    $sourceHash = (Get-FileHash -LiteralPath $sourceFile -Algorithm SHA256).Hash
    $destinationHash = (Get-FileHash -LiteralPath $destinationFile -Algorithm SHA256).Hash
    if ($sourceHash -ne $destinationHash) {
        throw "Post-copy verification failed: $relativePath"
    }
    $installed += [ordered]@{ path = $relativePath; sha256 = $destinationHash }
}

$receipt = [ordered]@{
    version = (Get-Content -LiteralPath (Join-Path $repositoryRoot 'VERSION') -Raw).Trim()
    installed_at = [DateTimeOffset]::Now.ToString('o')
    game_root = $resolvedGameRoot
    files = $installed
}
$receiptPath = Join-Path $destinationRoot 'data\MHRiseMonsterCoach\dev_install_receipt.json'
$receipt | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $receiptPath -Encoding utf8

Write-Host "Installed and verified $($files.Count) files: $($receipt.version)" -ForegroundColor Green
Write-Host "Receipt: $receiptPath"

if ($Relaunch) {
    Start-Process -FilePath 'steam://run/1446780'
    Write-Host 'Relaunch requested through Steam.'
}
