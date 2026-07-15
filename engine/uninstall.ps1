<#
.SYNOPSIS
    Open365 强力卸载引擎 (uninstall engine)
    开源的"软件管家 / 强力卸载"工具。

.DESCRIPTION
    list      列出已安装软件（注册表 Uninstall 键，HKLM 64/32 + HKCU）
    search    按关键词找软件（如 search 某软件）
    uninstall 调用软件自己的卸载程序卸载
    residue   扫描某软件卸载后的残留（目录 + 注册表）

    安全：卸载不可逆，默认需要交互确认或 -Yes。残留清理也单独确认。
    可用来卸载顽固/捆绑软件全家桶。

.NOTES
    卸 HKLM 装的软件通常需要管理员。-Json 输出结构化结果。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'search', 'uninstall', 'residue', 'residue-clean', 'help')]
    [string]$Action = 'help',

    [Parameter(Position = 1)]
    [string]$Query,         # search 的关键词 / uninstall 的 id / residue 的名字

    [switch]$Json,
    [switch]$Yes            # 跳过卸载确认 / 残留清理确认
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
                size_kb       = $_.EstimatedSize
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

# 本地判定残留把握度（不联网）：名称==关键词 或 以关键词开头 => high(基本确定是它的)；
# 只是「包含」关键词 => low(可能是别的软件/共享目录，清理前请确认)。保守：拿不准算 low。
function Get-ResidueConfidence([string]$leaf, [string]$keyword) {
    $l = "$leaf".ToLower(); $k = "$keyword".ToLower()
    if ($l -eq $k -or $l.StartsWith($k)) {
        return @{ level = 'high'; reason = '名称与软件名高度吻合，基本确定是它的残留' }
    }
    return @{ level = 'low'; reason = '仅包含关键词，可能属于别的软件/共享目录，清理前请确认' }
}

function Find-Residue([string]$keyword) {
    # dirs/reg 保留纯路径数组（清理逻辑与旧行为不变）；*_detail 附带把握度用于展示。
    $hits = @{ dirs=@(); reg=@(); dirs_detail=@(); reg_detail=@() }
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
            ForEach-Object {
                $hits.dirs += $_.FullName
                $c = Get-ResidueConfidence $_.Name $keyword
                $hits.dirs_detail += [ordered]@{ path=$_.FullName; level=$c.level; reason=$c.reason }
            }
    }
    # 注册表残留（软件常见根键）
    $regRoots = @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\SOFTWARE')
    foreach ($rr in $regRoots) {
        Get-ChildItem -Path $rr -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "*$keyword*" } |
            ForEach-Object {
                $hits.reg += $_.Name
                $c = Get-ResidueConfidence $_.PSChildName $keyword
                $hits.reg_detail += [ordered]@{ path=$_.Name; level=$c.level; reason=$c.reason }
            }
    }
    return $hits
}

# ---------- 残留一键清理（留底 + 可回滚，绝不硬删） ----------
# 安全设计：
#   - 关键词必须 >=2 字符，且不在危险黑名单（防手滑匹配到系统目录/根键）。
#   - 目录不是删除，而是【移动】到备份区（%LOCALAPPDATA%\Open365\residue-backup\...）。
#   - 注册表先 reg export 导出 .reg 再删；备份区里放着，随时能双击导回。
#   - 返回 backup_dir，让用户知道东西挪哪了、怎么还原。
$script:ResidueBlocklist = @(
    'windows','microsoft','common','system','system32','program','programs',
    'program files','appdata','users','intel','amd','nvidia','realtek','office'
)

function Invoke-ResidueClean([string]$keyword) {
    $kw = ($keyword | ForEach-Object { $_.Trim() })
    if (-not $kw -or $kw.Length -lt 2) {
        throw "关键词太短（至少 2 个字符），为安全起见拒绝执行（避免误匹配大量系统目录）。"
    }
    if ($script:ResidueBlocklist -contains $kw.ToLower()) {
        throw "关键词 '$kw' 太宽泛/危险，可能匹配到系统关键目录，已拒绝。请用更具体的软件名。"
    }

    $hits = Find-Residue $kw
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $safeKw = ($kw -replace '[\\/:*?"<>|]', '_')
    $backup = Join-Path $env:LOCALAPPDATA "Open365\residue-backup\$safeKw-$stamp"
    New-Item -ItemType Directory -Force -Path $backup | Out-Null

    $movedDirs = @()
    $failedDirs = @()
    $exportedRegs = @()
    $failedRegs = @()

    # 1) 注册表：先导出 .reg 备份，再删
    $ri = 0
    foreach ($k in $hits.reg) {
        $ri++
        $safe = ($k -replace '[\\:]', '_')
        $regFile = Join-Path $backup ("reg_{0:D2}_{1}.reg" -f $ri, $safe)
        & reg.exe export "$k" "$regFile" /y 2>&1 | Out-Null
        if (Test-Path $regFile) {
            $ps = $k -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_CLASSES_ROOT', 'HKCR:'
            try {
                Remove-Item -Path $ps -Recurse -Force -ErrorAction Stop
                $exportedRegs += $k
            } catch {
                $failedRegs += $k
            }
        } else {
            $failedRegs += $k
        }
    }

    # 2) 目录：移动到备份区（不删除，可整目录搬回）
    $dirBackupRoot = Join-Path $backup 'dirs'
    foreach ($d in $hits.dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        try {
            if (-not (Test-Path $dirBackupRoot)) { New-Item -ItemType Directory -Force -Path $dirBackupRoot | Out-Null }
            $leaf = Split-Path $d -Leaf
            $dest = Join-Path $dirBackupRoot $leaf
            # 目标重名则加序号，避免覆盖
            $n = 1
            while (Test-Path -LiteralPath $dest) { $dest = Join-Path $dirBackupRoot ("{0}_{1}" -f $leaf, $n); $n++ }
            Move-Item -LiteralPath $d -Destination $dest -Force -ErrorAction Stop
            $movedDirs += $d
        } catch {
            $failedDirs += $d
        }
    }

    # 写一份还原说明到备份目录
    $readme = @"
Open365 残留清理备份 —— $kw ($stamp)

【如何还原】
- 目录：把 dirs\ 里的文件夹剪切回它原来的位置即可。
- 注册表：双击本目录下对应的 reg_*.reg 文件，确认导入即可。

本次清理：
  移动目录 $($movedDirs.Count) 个，删除注册表项 $($exportedRegs.Count) 个。
  （失败：目录 $($failedDirs.Count)，注册表 $($failedRegs.Count)，多为正在占用/权限不足）
"@
    $readme | Set-Content -Path (Join-Path $backup '还原说明.txt') -Encoding UTF8

    return [ordered]@{
        ok            = $true
        keyword       = $kw
        backup_dir    = $backup
        moved_dirs    = $movedDirs
        exported_regs = $exportedRegs
        failed_dirs   = $failedDirs
        failed_regs   = $failedRegs
        moved_count   = $movedDirs.Count
        reg_count     = $exportedRegs.Count
    }
}

function Show-Residue($hits, [string]$kw) {
    Write-Host ""
    Write-Host "  ========== '$kw' 残留扫描 ==========" -ForegroundColor White
    Write-Host ""
    Write-Host "  残留目录:" -ForegroundColor Yellow
    if ($hits.dirs.Count -eq 0) { Write-Host "    (无)" -ForegroundColor DarkGray }
    else {
        foreach ($d in $hits.dirs_detail) {
            $tag = if ($d.level -eq 'high') { '[确定]' } else { '[可能]' }
            $col = if ($d.level -eq 'high') { 'Gray' } else { 'DarkYellow' }
            Write-Host "    $tag $($d.path)" -ForegroundColor $col
        }
    }
    Write-Host ""
    Write-Host "  残留注册表项:" -ForegroundColor Yellow
    if ($hits.reg.Count -eq 0) { Write-Host "    (无)" -ForegroundColor DarkGray }
    else {
        foreach ($rg in $hits.reg_detail) {
            $tag = if ($rg.level -eq 'high') { '[确定]' } else { '[可能]' }
            $col = if ($rg.level -eq 'high') { 'Gray' } else { 'DarkYellow' }
            Write-Host "    $tag $($rg.path)" -ForegroundColor $col
        }
    }
    Write-Host ""
    Write-Host "  [确定]=名称与软件名高度吻合   [可能]=仅含关键词，清理前请确认" -ForegroundColor DarkGray
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
        if (-not $Query) { throw '请提供关键词，如: open365 uninstall search 某软件' }
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
    'residue-clean' {
        if (-not $Query) { throw '请提供软件名关键词' }
        if (-not $Yes -and -not $Json) {
            $h = Find-Residue $Query
            Show-Residue $h $Query
            $ans = Read-Host "  将把以上残留【目录移到备份区、注册表导出后删除】(可还原)。确认？(yes/N)"
            if ($ans -ne 'yes') { Write-Host "  已取消"; return }
        }
        $output = Invoke-ResidueClean $Query
        if (-not $Json) {
            Write-Host ""
            Write-Host "  [OK] 残留清理完成：移动目录 $($output.moved_count) 个，删除注册表项 $($output.reg_count) 个。" -ForegroundColor Green
            Write-Host "  备份/还原位置: $($output.backup_dir)" -ForegroundColor Cyan
            Write-Host ""
        }
    }
    'help' {
        Write-Host @"
Open365 强力卸载引擎

用法: uninstall.ps1 <action> [query] [-Json] [-Yes]

  list                  列出所有已安装软件
  search <关键词>       搜索软件（如 search 影音）
  uninstall <id>        卸载软件（不可逆，需确认或 -Yes）
  residue <关键词>      扫描卸载残留（目录+注册表，只报告不删）
  residue-clean <关键词> 一键清理残留：目录移到备份区、注册表导出后删（可还原，需确认或 -Yes）

卸载示例:
  open365 uninstall search <关键词>       # 按名字找到各组件的 id
  open365 uninstall uninstall <id>       # 逐个卸载
  open365 uninstall residue <关键词>      # 扫残留（只看）
  open365 uninstall residue-clean <关键词> # 清残留（留底可回滚）

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
