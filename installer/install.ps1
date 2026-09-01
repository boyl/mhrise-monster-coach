#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot,
    [switch]$NoElevation,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Resolve-GameRoot {
    param([string]$RequestedRoot, [string]$Executable)
    $candidates = [Collections.Generic.List[string]]::new()
    if ($RequestedRoot) { $candidates.Add($RequestedRoot) }
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
        if (Test-Path -LiteralPath (Join-Path $resolved $Executable) -PathType Leaf) {
            return $resolved
        }
    }
    throw '未找到《怪物猎人崛起》安装目录。请使用 -GameRoot 指定游戏根目录。'
}

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolved = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
    if (-not $resolved.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) {
        throw "安装清单路径越界：$RelativePath"
    }
    return $resolved
}

function Test-DirectoryWritable {
    param([string]$Path)
    $probe = Join-Path $Path ('.monster-coach-write-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($probe, 'probe')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

$packageRoot = [IO.Path]::GetFullPath($PSScriptRoot)
$manifestPath = Join-Path $packageRoot 'manifest.json'
$versionPath = Join-Path $packageRoot 'VERSION'
$payloadRoot = Join-Path $packageRoot 'Payload\reframework'
foreach ($required in @($manifestPath, $versionPath, $payloadRoot)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "安装包不完整：$required" }
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.schema_version -ne 1 -or @($manifest.files).Count -eq 0) {
    throw '安装清单无效或为空。'
}
$version = (Get-Content -LiteralPath $versionPath -Raw).Trim()
$resolvedGameRoot = Resolve-GameRoot $GameRoot $manifest.game_executable
$reframeworkRoot = Join-Path $resolvedGameRoot 'reframework'
if (-not (Test-Path -LiteralPath $reframeworkRoot -PathType Container)) {
    throw '未检测到 REFramework。请先按官方说明安装并启动游戏验证一次。'
}
foreach ($relativeDependency in @($manifest.required_dependency_files)) {
    if (-not (Test-Path -LiteralPath (Resolve-ContainedPath $resolvedGameRoot $relativeDependency) -PathType Leaf)) {
        throw "缺少必需依赖：$relativeDependency。请先安装 RiseQuestLoader。"
    }
}
$running = @(Get-Process -Name 'MonsterHunterRise' -ErrorAction SilentlyContinue | Where-Object {
    -not $_.Path -or ([IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($_.Path))).Equals(
        $resolvedGameRoot, [StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) { throw '游戏正在运行。请正常退出游戏后重新安装。' }

if (-not (Test-DirectoryWritable $resolvedGameRoot)) {
    if ($NoElevation) { throw "游戏目录不可写：$resolvedGameRoot" }
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    if ($PSVersionTable.PSVersion.Major -lt 7) { throw '安装程序要求 PowerShell 7 或更高版本。' }
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        ('"{0}"' -f $PSCommandPath), '-GameRoot', ('"{0}"' -f $resolvedGameRoot))
    if ($NoPause) { $arguments += '-NoPause' }
    $child = Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Normal -ArgumentList $arguments -Wait -PassThru
    exit $child.ExitCode
}

$preflight = @()
$manifestPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($item in @($manifest.files)) {
    $relative = ([string]$item.path).Replace('/', [IO.Path]::DirectorySeparatorChar)
    if (-not $manifestPaths.Add($relative)) { throw "安装清单包含重复路径：$relative" }
    $source = Resolve-ContainedPath $payloadRoot $relative
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "缺少安装文件：$relative" }
    $actualHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ($actualHash -ne [string]$item.sha256) { throw "安装包哈希不匹配：$relative" }
    $preflight += [pscustomobject]@{ relative = $relative; source = $source; sha256 = $actualHash }
}

$dataRoot = Join-Path $reframeworkRoot 'data\MHRiseMonsterCoach'
New-Item -ItemType Directory -Path $dataRoot -Force | Out-Null
$transactionId = [DateTimeOffset]::Now.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$backupRoot = Join-Path $dataRoot (Join-Path 'install_backups' $transactionId)
$receiptPath = Join-Path $dataRoot 'install_receipt.json'
$previousReceipt = Join-Path $backupRoot 'previous_install_receipt.json'
$applied = [Collections.Generic.List[object]]::new()

try {
    New-Item -ItemType Directory -Path $backupRoot -Force | Out-Null
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        Copy-Item -LiteralPath $receiptPath -Destination $previousReceipt -Force
    }
    foreach ($entry in $preflight) {
        $destination = Resolve-ContainedPath $reframeworkRoot $entry.relative
        $existed = Test-Path -LiteralPath $destination -PathType Leaf
        $backup = Resolve-ContainedPath $backupRoot $entry.relative
        $backupHash = $null
        if ($existed) {
            $backupDirectory = [IO.Path]::GetDirectoryName($backup)
            New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
            $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
        }
        $applied.Add([pscustomobject]@{
            path = $entry.relative.Replace([IO.Path]::DirectorySeparatorChar, '/')
            sha256 = $entry.sha256
            existed_before = $existed
            backup_sha256 = $backupHash
        })
        $destinationDirectory = [IO.Path]::GetDirectoryName($destination)
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $entry.source -Destination $destination -Force
        $installedHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if ($installedHash -ne $entry.sha256) { throw "安装后校验失败：$($entry.relative)" }
    }
    $receipt = [ordered]@{
        schema_version = 1
        product = $manifest.product
        version = $version
        installed_at = [DateTimeOffset]::Now.ToString('o')
        game_root = $resolvedGameRoot
        backup_root = [IO.Path]::GetRelativePath($reframeworkRoot, $backupRoot).Replace('\', '/')
        previous_receipt = Test-Path -LiteralPath $previousReceipt -PathType Leaf
        files = @($applied)
    }
    $temporaryReceipt = $receiptPath + '.tmp'
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $temporaryReceipt -Encoding utf8
    Move-Item -LiteralPath $temporaryReceipt -Destination $receiptPath -Force
} catch {
    $installError = $_.Exception.Message
    $rollbackErrors = [Collections.Generic.List[string]]::new()
    for ($index = $applied.Count - 1; $index -ge 0; $index--) {
        $entry = $applied[$index]
        $destination = Resolve-ContainedPath $reframeworkRoot $entry.path
        $backup = Resolve-ContainedPath $backupRoot $entry.path
        try {
            if ($entry.existed_before -and (Test-Path -LiteralPath $backup -PathType Leaf)) {
                Copy-Item -LiteralPath $backup -Destination $destination -Force
            } elseif (-not $entry.existed_before -and (Test-Path -LiteralPath $destination -PathType Leaf)) {
                Remove-Item -LiteralPath $destination -Force
            }
        } catch {
            $rollbackErrors.Add("$($entry.path): $($_.Exception.Message)")
        }
    }
    if ($rollbackErrors.Count -gt 0) {
        throw "安装失败且回滚不完整：$installError；$($rollbackErrors -join '；')"
    }
    throw "安装失败，已恢复原文件：$installError"
}

Write-Host "安装并校验完成：$($manifest.product) $version（$($applied.Count) 个文件）" -ForegroundColor Green
Write-Host "安装收据：$receiptPath"
if (-not $NoPause) { Read-Host '按 Enter 关闭' | Out-Null }
