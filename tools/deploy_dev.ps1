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

$processes = @(Get-Process -Name 'MonsterHunterRise' -ErrorAction SilentlyContinue)
if ($processes.Count -gt 0) {
    if (-not $WaitForExit) {
        throw 'MonsterHunterRise is running. Use -WaitForExit or exit the game first.'
    }
    Write-Host 'Waiting for Monster Hunter Rise to exit safely...'
    $processes | Wait-Process
}

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$resolvedGameRoot = Resolve-GameRoot $GameRoot
$sourceRoot = Join-Path $repositoryRoot 'reframework'
$destinationRoot = Join-Path $resolvedGameRoot 'reframework'
if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
    throw "Source directory was not found: $sourceRoot"
}
if (-not (Test-Path -LiteralPath $destinationRoot -PathType Container)) {
    throw "REFramework directory was not found: $destinationRoot"
}

# Deliberately excludes config.json, calibration, runtime evidence, logs and dumps.
$files = @(
    'autorun\MHRiseMonsterCoach.lua',
    'autorun\MHRiseMonsterCoach\action_reader.lua',
    'autorun\MHRiseMonsterCoach\app.lua',
    'autorun\MHRiseMonsterCoach\config.lua',
    'autorun\MHRiseMonsterCoach\controller.lua',
    'autorun\MHRiseMonsterCoach\dev_probe_controller.lua',
    'autorun\MHRiseMonsterCoach\environment_creature_recorder.lua',
    'autorun\MHRiseMonsterCoach\font.lua',
    'autorun\MHRiseMonsterCoach\hitbox_provider.lua',
    'autorun\MHRiseMonsterCoach\hitbox_provider_hitboxviewer.lua',
    'autorun\MHRiseMonsterCoach\hitbox_provider_native.lua',
    'autorun\MHRiseMonsterCoach\input_adapter.lua',
    'autorun\MHRiseMonsterCoach\model.lua',
    'autorun\MHRiseMonsterCoach\monster_respawn.lua',
    'autorun\MHRiseMonsterCoach\monster_phase.lua',
    'autorun\MHRiseMonsterCoach\long_sword_switch_skills.lua',
    'autorun\MHRiseMonsterCoach\player_state_reader.lua',
    'autorun\MHRiseMonsterCoach\response_long_sword.lua',
    'autorun\MHRiseMonsterCoach\startup_bootstrap_controller.lua',
    'autorun\MHRiseMonsterCoach\profile_tigrex.lua',
    'autorun\MHRiseMonsterCoach\quest_list_order.lua',
    'autorun\MHRiseMonsterCoach\quest_restart.lua',
    'autorun\MHRiseMonsterCoach\runtime.lua',
    'autorun\MHRiseMonsterCoach\view.lua',
    'data\MHRiseMonsterCoach\tigrex_static_ai.json',
    'data\MHRiseMonsterCoach\long_sword_knowledge.json',
    'quests\q200032001.json'
)

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
