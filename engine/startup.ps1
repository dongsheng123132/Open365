<#
.SYNOPSIS
    Open365 启动项管理引擎 (startup engine)
    开源的"优化加速 / 开机加速 / 启动项管理"工具。

.DESCRIPTION
    列出所有开机自启来源并支持启用/禁用：
      - 注册表 Run 键：HKLM/HKCU 的 Run 和 Run (WOW6432Node)
      - 启动文件夹：用户的 和 公共的
      - 计划任务中标记为开机/登录触发的项

    禁用是可还原的：注册表项移到 Open365 的 -disabled 备份键，
    启动文件夹快捷方式移到 disabled 备份目录，不直接删除。

.NOTES
    list 只读。disable/enable 改 HKCU 不需管理员；改 HKLM 需要管理员。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'disable', 'enable', 'help')]
    [string]$Action = 'help',

    [string]$Id,            # disable/enable 的目标项 id（来自 list 输出）
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# 注册表启动位置定义
$RunKeys = @(
    @{ id='hklm-run';    hive='HKLM'; path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 scope='所有用户'; admin=$true }
    @{ id='hklm-run32';  hive='HKLM'; path='SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     scope='所有用户(32位)'; admin=$true }
    @{ id='hkcu-run';    hive='HKCU'; path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 scope='当前用户'; admin=$false }
)
$DisabledSuffix = '\Open365-Disabled'   # 禁用项移到 ...\Run\Open365-Disabled

function Get-HivePath($k, [bool]$disabled) {
    $base = "$($k.hive):\$($k.path)"
    if ($disabled) { return "$base$DisabledSuffix" }
    return $base
}

# ---------- 列出 ----------

function Get-StartupItems {
    $items = @()

    # 1) 注册表 Run 键（含已禁用的备份键）
    foreach ($k in $RunKeys) {
        foreach ($state in @('enabled','disabled')) {
            $p = Get-HivePath $k ($state -eq 'disabled')
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $props = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -like 'PS*') { continue }
                $items += [ordered]@{
                    id      = "reg:$($k.id):$($prop.Name)"
                    name    = $prop.Name
                    command = $prop.Value
                    source  = "注册表 ($($k.scope))"
                    type    = 'registry'
                    regkey  = $k.id
                    state   = $state
                    admin   = $k.admin
                }
            }
        }
    }

    # 2) 启动文件夹
    $folders = @(
        @{ id='startup-user';   path=[Environment]::GetFolderPath('Startup');       scope='当前用户'; admin=$false }
        @{ id='startup-common'; path=[Environment]::GetFolderPath('CommonStartup'); scope='所有用户'; admin=$true }
    )
    foreach ($fo in $folders) {
        foreach ($state in @('enabled','disabled')) {
            $dir = if ($state -eq 'disabled') { Join-Path $fo.path 'Open365-Disabled' } else { $fo.path }
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.lnk','.exe','.bat','.cmd','.vbs' } |
                ForEach-Object {
                    $items += [ordered]@{
                        id      = "folder:$($fo.id):$($_.Name)"
                        name    = $_.BaseName
                        command = $_.FullName
                        source  = "启动文件夹 ($($fo.scope))"
                        type    = 'folder'
                        folder  = $fo.id
                        state   = $state
                        admin   = $fo.admin
                    }
                }
        }
    }

    return $items
}

function Show-List($items) {
    Write-Host ""
    Write-Host "  ========== 开机启动项 ==========" -ForegroundColor White
    Write-Host ""
    if ($items.Count -eq 0) { Write-Host "  (没有发现启动项)"; return }
    $i = 0
    foreach ($it in $items) {
        $i++
        $flag = if ($it.state -eq 'disabled') { '[已禁用]' } else { '[启用中]' }
        $color = if ($it.state -eq 'disabled') { 'DarkGray' } else { 'White' }
        Write-Host ("  {0} {1}" -f $flag, $it.name) -ForegroundColor $color
        Write-Host ("       来源: {0}" -f $it.source) -ForegroundColor DarkGray
        Write-Host ("       命令: {0}" -f $it.command) -ForegroundColor DarkGray
        Write-Host ("       id  : {0}" -f $it.id) -ForegroundColor DarkCyan
        Write-Host ""
    }
    Write-Host "  禁用某项: open365 startup disable -Id <上面的id>" -ForegroundColor Cyan
    Write-Host "  恢复某项: open365 startup enable  -Id <上面的id>" -ForegroundColor Cyan
    Write-Host ""
}

# ---------- 禁用 / 启用（可还原） ----------

function Move-RegValue($fromKey, $toKey, $name) {
    if (-not (Test-Path -LiteralPath $toKey)) { New-Item -Path $toKey -Force | Out-Null }
    $val = (Get-ItemProperty -LiteralPath $fromKey -Name $name).$name
    Set-ItemProperty -LiteralPath $toKey -Name $name -Value $val
    Remove-ItemProperty -LiteralPath $fromKey -Name $name
}

function Set-ItemState([string]$targetId, [string]$toState) {
    $items = Get-StartupItems
    $item = $items | Where-Object { $_.id -eq $targetId } | Select-Object -First 1
    if (-not $item) { throw "找不到启动项: $targetId（先运行 list 查看正确 id）" }
    if ($item.state -eq $toState) {
        Write-Host "  该项已经是 $toState 状态，无需操作。" -ForegroundColor Yellow
        return @{ ok=$true; id=$targetId; state=$toState; changed=$false }
    }
    if ($item.admin -and -not (Test-Admin)) {
        throw "该项属于'所有用户'，禁用/启用需要管理员权限。请用 open365.bat（自动提权）。"
    }

    if ($item.type -eq 'registry') {
        $k = $RunKeys | Where-Object { $_.id -eq $item.regkey }
        $enabledKey  = Get-HivePath $k $false
        $disabledKey = Get-HivePath $k $true
        if ($toState -eq 'disabled') { Move-RegValue $enabledKey $disabledKey $item.name }
        else                          { Move-RegValue $disabledKey $enabledKey $item.name }
    }
    elseif ($item.type -eq 'folder') {
        $fo = if ($item.folder -eq 'startup-user') { [Environment]::GetFolderPath('Startup') } else { [Environment]::GetFolderPath('CommonStartup') }
        $disabledDir = Join-Path $fo 'Open365-Disabled'
        if (-not (Test-Path $disabledDir)) { New-Item -ItemType Directory -Path $disabledDir -Force | Out-Null }
        $fileName = Split-Path $item.command -Leaf
        if ($toState -eq 'disabled') {
            Move-Item -LiteralPath $item.command -Destination (Join-Path $disabledDir $fileName) -Force
        } else {
            Move-Item -LiteralPath $item.command -Destination (Join-Path $fo $fileName) -Force
        }
    }
    Write-Host "  [OK] '$($item.name)' 已$(if($toState -eq 'disabled'){'禁用'}else{'恢复'})" -ForegroundColor Green
    return @{ ok=$true; id=$targetId; state=$toState; changed=$true }
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'list'    { $it = Get-StartupItems; if ($Json) { $output = @{ items=$it } } else { Show-List $it } }
    'disable' { if (-not $Id) { throw '请用 -Id 指定要禁用的项' }; $output = Set-ItemState $Id 'disabled' }
    'enable'  { if (-not $Id) { throw '请用 -Id 指定要恢复的项' }; $output = Set-ItemState $Id 'enabled' }
    'help'    {
        Write-Host @"
Open365 启动项管理引擎

用法: startup.ps1 <action> [-Id <id>] [-Json]

  list                列出所有开机启动项（只读）
  disable -Id <id>    禁用某项（可还原，移到备份键/目录）
  enable  -Id <id>    恢复某项

禁用是可逆的：注册表项移到 ...\Run\Open365-Disabled，
启动文件夹快捷方式移到 Open365-Disabled 子目录。

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
