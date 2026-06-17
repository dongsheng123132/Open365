<#
.SYNOPSIS
    Open365 强力卸载引擎 (uninstall engine)
    开源替代 360 的"软件管家/强力卸载"。

.DESCRIPTION
    list      列出已安装软件（注册表 Uninstall 键，HKLM 64/32 + HKCU）
    search    按关键词找软件（如 search 360）
    uninstall 调用软件自己的卸载程序卸载
    residue   扫描某软件卸载后的残留（目录 + 注册表）

    安全：卸载不可逆，默认需要交互确认或 -Yes。残留清理也单独确认。
    可用来卸载 360 全家桶。

.NOTES
    卸 HKLM 装的软件通常需要管理员。-Json 输出结构化结果。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'search', 'uninstall', 'residue', 'help')]
    [string]$Action = 'help',

    [Parameter(Position = 1)]
    [string]$Query,         # search 的关键词 / uninstall 的 id / residue 的名字

    [switch]$Json,
    [switch]$Yes            # 跳过卸载确认
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 读已安装软件 ----------

$UninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

function Get-InstalledApps {
    $apps = @()
    foreach ($k in $UninstallKeys) {
        Get-ItemProperty -Path $k -ErrorAction SilentlyContinue | ForEach-Object {
            $name = $_.DisplayName
            if (-not $name) { return }
            # 跳过系统补丁/更新
            if ($_.SystemComponent -eq 1) { return }
            if ($_.ParentKeyName) { return }
            $apps += [ordered]@{
                id            = $_.PSChildName
                name          = $name
                version       = $_.DisplayVersion
                publisher     = $_.Publisher
                install_loc   = $_.InstallLocation
                uninstall_cmd = $_.UninstallString
                quiet_cmd     = $_.QuietUninstallString
                size_kb       = $_.EstimateSize
            }
        }
    }
    # 按名字去重
    $apps | Sort-Object { $_.name } -Unique
}

function Show-Apps($apps, [string]$title) {
    Write-Host ""
    Write-Host "  ========== $title ==========" -ForegroundColor White
    Write-Host ""
    if ($apps.Count -eq 0) { Write-Host "  (没有匹配的软件)"; return }
    foreach ($a in $apps) {
        Write-Host ("  {0}  {1}" -f $a.name, $a.version) -ForegroundColor White
        if ($a.publisher) { Write-Host ("       发行: {0}" -f $a.publisher) -ForegroundColor DarkGray }
        Write-Host ("       id  : {0}" -f $a.id) -ForegroundColor DarkCyan
        Write-Host ""
    }
    Write-Host "  卸载: open365 uninstall uninstall <id>" -ForegroundColor Cyan
    Write-Host "  查残留: open365 uninstall residue <名字关键词>" -ForegroundColor Cyan
    Write-Host ""
}

# ---------- 卸载 ----------

function Invoke-Uninstall([string]$targetId) {
    $app = Get-InstalledApps | Where-Object { $_.id -eq $targetId } | Select-Object -First 1
    if (-not $app) { throw "找不到软件 id: $targetId（先 search/list 查看）" }

    Write-Host ""
    Write-Host "  即将卸载: $($app.name) $($app.version)" -ForegroundColor Yellow
    if (-not $Yes -and -not $Json) {
        $ans = Read-Host "  确认卸载？此操作不可逆 (yes/N)"
        if ($ans -ne 'yes') { Write-Host "  已取消"; return @{ ok=$false; cancelled=$true } }
    }

    $cmd = if ($app.quiet_cmd) { $app.quiet_cmd } else { $app.uninstall_cmd }
    if (-not $cmd) { throw "该软件没有提供卸载命令，可能需要手动卸载。" }

    Write-Host "  执行: $cmd" -ForegroundColor DarkGray
    # 解析卸载命令（可能带参数，可能是 msiexec）
    try {
        if ($cmd -match '^"([^"]+)"\s*(.*)$') {
            $exe = $matches[1]; $args = $matches[2]
            Start-Process -FilePath $exe -ArgumentList $args -Wait
        } elseif ($cmd -match '^(\S+)\s+(.*)$' -and $cmd -match 'msiexec') {
            Start-Process -FilePath 'msiexec.exe' -ArgumentList ($cmd -replace '^\S*msiexec\S*\s*','') -Wait
        } else {
            Start-Process -FilePath $cmd -Wait
        }
        Write-Host "  [OK] 卸载程序已结束。建议接着扫残留：open365 uninstall residue `"$($app.name)`"" -ForegroundColor Green
        return @{ ok=$true; name=$app.name }
    } catch {
        throw "卸载失败: $($_.Exception.Message)"
    }
}

# ---------- 残留扫描 ----------

function Find-Residue([string]$keyword) {
    $hits = @{ dirs=@(); reg=@() }
    $roots = @(
        "$env:ProgramFiles",
        "${env:ProgramFiles(x86)}",
        "$env:LOCALAPPDATA",
        "$env:APPDATA",
        "$env:ProgramData"
    ) | Where-Object { $_ -and (Test-Path $_) }

    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -like "*$keyword*" } |
            ForEach-Object { $hits.dirs += $_.FullName }
    }
    # 注册表残留（软件常见根键）
    $regRoots = @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\SOFTWARE')
    foreach ($rr in $regRoots) {
        Get-ChildItem -Path $rr -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "*$keyword*" } |
            ForEach-Object { $hits.reg += $_.Name }
    }
    return $hits
}

function Show-Residue($hits, [string]$kw) {
    Write-Host ""
    Write-Host "  ========== '$kw' 残留扫描 ==========" -ForegroundColor White
    Write-Host ""
    Write-Host "  残留目录:" -ForegroundColor Yellow
    if ($hits.dirs.Count -eq 0) { Write-Host "    (无)" -ForegroundColor DarkGray }
    else { $hits.dirs | ForEach-Object { Write-Host "    $_" } }
    Write-Host ""
    Write-Host "  残留注册表项:" -ForegroundColor Yellow
    if ($hits.reg.Count -eq 0) { Write-Host "    (无)" -ForegroundColor DarkGray }
    else { $hits.reg | ForEach-Object { Write-Host "    $_" } }
    Write-Host ""
    Write-Host "  注：本版本只'扫描报告'残留，删除请人工确认后操作（安全起见）。" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'list' {
        $apps = Get-InstalledApps
        if ($Json) { $output = @{ apps=$apps } } else { Show-Apps $apps "已安装软件 ($($apps.Count) 个)" }
    }
    'search' {
        if (-not $Query) { throw '请提供关键词，如: open365 uninstall search 360' }
        $apps = Get-InstalledApps | Where-Object { $_.name -like "*$Query*" }
        if ($Json) { $output = @{ apps=$apps } } else { Show-Apps $apps "搜索 '$Query' 的结果" }
    }
    'uninstall' {
        if (-not $Query) { throw '请提供软件 id' }
        $output = Invoke-Uninstall $Query
    }
    'residue' {
        if (-not $Query) { throw '请提供软件名关键词' }
        $h = Find-Residue $Query
        if ($Json) { $output = $h } else { Show-Residue $h $Query }
    }
    'help' {
        Write-Host @"
Open365 强力卸载引擎

用法: uninstall.ps1 <action> [query] [-Json] [-Yes]

  list                列出所有已安装软件
  search <关键词>     搜索软件（如 search 360）
  uninstall <id>      卸载软件（不可逆，需确认或 -Yes）
  residue <关键词>    扫描卸载残留（目录+注册表，只报告不删）

卸 360 示例:
  open365 uninstall search 360         # 找到 360 全家桶各组件的 id
  open365 uninstall uninstall <id>     # 逐个卸载
  open365 uninstall residue 360        # 扫残留

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
