#Requires -Version 7.0

[CmdletBinding()]
param(
    [string]$GameRoot,
    [switch]$Force,
    [switch]$NoElevation,
    [switch]$NoPause
)

$ErrorActionPreference = 'Stop'

function Resolve-GameRoot {
    param([string]$RequestedRoot)
    if ($RequestedRoot) {
        $resolved = [IO.Path]::GetFullPath($RequestedRoot)
        if (Test-Path -LiteralPath (Join-Path $resolved 'MonsterHunterRise.exe') -PathType Leaf) { return $resolved }
    }
    $steam = Get-ItemProperty -LiteralPath 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    foreach ($candidate in @(
        $(if ($steam.SteamPath) { Join-Path $steam.SteamPath 'steamapps\common\MonsterHunterRise' }),
        $(if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} 'Steam\steamapps\common\MonsterHunterRise' })
    )) {
        if ($candidate -and (Test-Path -LiteralPath (Join-Path $candidate 'MonsterHunterRise.exe') -PathType Leaf)) {
            return [IO.Path]::GetFullPath($candidate)
        }
    }
    throw '未找到《怪物猎人崛起》安装目录。请使用 -GameRoot 指定游戏根目录。'
}

function Resolve-ContainedPath {
    param([string]$Root, [string]$RelativePath)
    $resolvedRoot = [IO.Path]::GetFullPath($Root).TrimEnd('\', '/')
    $resolved = [IO.Path]::GetFullPath((Join-Path $resolvedRoot $RelativePath))
    if (-not $resolved.StartsWith($resolvedRoot + [IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase)) { throw "卸载收据路径越界：$RelativePath" }
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

$resolvedGameRoot = Resolve-GameRoot $GameRoot
$reframeworkRoot = Join-Path $resolvedGameRoot 'reframework'
$dataRoot = Join-Path $reframeworkRoot 'data\MHRiseMonsterCoach'
$receiptPath = Join-Path $dataRoot 'install_receipt.json'
if (-not (Test-Path -LiteralPath $receiptPath -PathType Leaf)) {
    throw '未找到可验证安装收据，拒绝猜测要删除的文件。'
}
$receipt = Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
if ($receipt.schema_version -ne 1 -or @($receipt.files).Count -eq 0) { throw '安装收据无效。' }
$backupRoot = Resolve-ContainedPath $reframeworkRoot ([string]$receipt.backup_root)
$running = @(Get-Process -Name 'MonsterHunterRise' -ErrorAction SilentlyContinue | Where-Object {
    -not $_.Path -or ([IO.Path]::GetFullPath([IO.Path]::GetDirectoryName($_.Path))).Equals(
        $resolvedGameRoot, [StringComparison]::OrdinalIgnoreCase)
})
if ($running.Count -gt 0) { throw '游戏正在运行。请正常退出游戏后重新卸载。' }

if (-not (Test-DirectoryWritable $resolvedGameRoot)) {
    if ($NoElevation) { throw "游戏目录不可写：$resolvedGameRoot" }
    $pwsh = (Get-Command pwsh.exe -ErrorAction Stop).Source
    $arguments = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
        ('"{0}"' -f $PSCommandPath), '-GameRoot', ('"{0}"' -f $resolvedGameRoot))
    if ($Force) { $arguments += '-Force' }
    if ($NoPause) { $arguments += '-NoPause' }
    $child = Start-Process -FilePath $pwsh -Verb RunAs -WindowStyle Normal -ArgumentList $arguments -Wait -PassThru
    exit $child.ExitCode
}

foreach ($entry in @($receipt.files)) {
    $destination = Resolve-ContainedPath $reframeworkRoot ([string]$entry.path)
    if (Test-Path -LiteralPath $destination -PathType Leaf) {
        $currentHash = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash
        if (-not $Force -and $currentHash -ne [string]$entry.sha256) {
            throw "文件在安装后被修改，拒绝覆盖或删除：$($entry.path)。确认后可使用 -Force。"
        }
    }
    if ($entry.existed_before -eq $true) {
        $backup = Resolve-ContainedPath $backupRoot ([string]$entry.path)
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "缺少回滚备份：$($entry.path)" }
        if ($entry.backup_sha256 -and
            (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash -ne [string]$entry.backup_sha256) {
            throw "回滚备份哈希不匹配：$($entry.path)"
        }
    }
}

for ($index = @($receipt.files).Count - 1; $index -ge 0; $index--) {
    $entry = @($receipt.files)[$index]
    $destination = Resolve-ContainedPath $reframeworkRoot ([string]$entry.path)
    $backup = Resolve-ContainedPath $backupRoot ([string]$entry.path)
    if ($entry.existed_before -eq $true) {
        $destinationDirectory = [IO.Path]::GetDirectoryName($destination)
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $backup -Destination $destination -Force
    } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
        Remove-Item -LiteralPath $destination -Force
    }
}

$previousReceipt = Join-Path $backupRoot 'previous_install_receipt.json'
if ($receipt.previous_receipt -eq $true -and (Test-Path -LiteralPath $previousReceipt -PathType Leaf)) {
    Copy-Item -LiteralPath $previousReceipt -Destination $receiptPath -Force
} else {
    Remove-Item -LiteralPath $receiptPath -Force
}
$uninstallReceipt = Join-Path $dataRoot 'last_uninstall_receipt.json'
[ordered]@{
    schema_version = 1
    product = $receipt.product
    version = $receipt.version
    uninstalled_at = [DateTimeOffset]::Now.ToString('o')
    restored_files = @($receipt.files | Where-Object existed_before).Count
    removed_files = @($receipt.files | Where-Object { -not $_.existed_before }).Count
} | ConvertTo-Json | Set-Content -LiteralPath $uninstallReceipt -Encoding utf8

Write-Host "卸载并校验完成：$($receipt.product) $($receipt.version)" -ForegroundColor Green
Write-Host '用户配置、校准、运行证据和其他 Mod 均已保留。'
if (-not $NoPause) { Read-Host '按 Enter 关闭' | Out-Null }
