<#
.SYNOPSIS
    Open365 进程管理引擎 (process engine)
    开源的"任务管理器 / 进程查看 / 一键结束"工具。

.DESCRIPTION
    list  : 列出当前运行的进程（名称 / PID / 内存 / 窗口标题），按内存从大到小。
    kill  : 按 PID 结束一个进程（-Force）。

    安全护栏：关键系统进程一律标记为 protected 且禁止结束——
      - 系统会话(SessionId=0)里的服务进程
      - 自己(Open365 / 本 PowerShell)
      - 关键进程名白名单(System / wininit / lsass / csrss / explorer ...)
    GUI 会把这些行置灰、不给结束按钮；命令行结束它们也会被拒。

.NOTES
    list 只读，不需管理员。kill 结束别的用户/已提权进程时需要管理员
    （Open365.exe 走 requireAdministrator，托盘里点是有权限的）。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'kill', 'help')]
    [string]$Action = 'help',

    [int]$Id,            # kill 的目标进程 PID（来自 list 输出）
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# -Json 输出要能被 UTF-8 解析：脚本自己钉住输出编码，别依赖调用方的控制台代码页。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Test-Admin {
    $wi = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($wi)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N0} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return "$b B"
}

# 关键系统进程名白名单（小写、无 .exe）——禁止结束，避免把电脑搞死机/蓝屏。
$ProtectedNames = @(
    'system', 'registry', 'idle', 'memcompression', 'secure system',
    'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass', 'lsaiso',
    'svchost', 'fontdrvhost', 'dwm', 'sihost', 'taskhostw', 'spoolsv',
    'ctfmon', 'runtimebroker', 'searchhost', 'searchindexer', 'searchapp',
    'startmenuexperiencehost', 'shellexperiencehost', 'audiodg', 'conhost',
    'dllhost', 'wmiprvse', 'wudfhost', 'securityhealthservice', 'securityhealthsystray',
    'msmpeng', 'nissrv', 'explorer', 'powershell', 'pwsh', 'open365', 'wininet'
)

function Get-ProcList {
    $self = $PID
    $items = @()
    foreach ($p in (Get-Process -ErrorAction SilentlyContinue)) {
        if ($null -eq $p -or $p.Id -eq 0) { continue }
        $name = $p.ProcessName
        $sid = -1
        try { $sid = [int]$p.SessionId } catch { $sid = -1 }
        $isProtected = ($ProtectedNames -contains $name.ToLower()) -or ($p.Id -eq $self) -or ($sid -eq 0)
        $title = ''
        try { $title = $p.MainWindowTitle } catch { $title = '' }
        $mem = 0
        try { $mem = [long]$p.WorkingSet64 } catch { $mem = 0 }
        $items += [ordered]@{
            id        = $p.Id
            name      = $name
            mem_bytes = $mem
            mem_human = (Format-Size $mem)
            title     = $title
            session   = $sid
            protected = [bool]$isProtected
        }
    }
    # 内存从大到小，最占资源的排最前
    return @($items | Sort-Object { -1 * $_.mem_bytes })
}

function Show-List($items) {
    Write-Host ""
    Write-Host "  ========== 运行中的进程（按内存排序） ==========" -ForegroundColor White
    Write-Host ""
    if ($items.Count -eq 0) { Write-Host "  (没有可显示的进程)"; return }
    Write-Host ("  {0,-26} {1,8} {2,10}  {3}" -f '名称', 'PID', '内存', '说明') -ForegroundColor DarkGray
    foreach ($it in $items) {
        $tag = if ($it.protected) { '🔒' } else { '  ' }
        $color = if ($it.protected) { 'DarkGray' } else { 'White' }
        $hint = if ($it.title) { $it.title } elseif ($it.protected) { '系统/受保护进程' } else { '' }
        if ($hint.Length -gt 40) { $hint = $hint.Substring(0, 39) + '…' }
        Write-Host ("{0}{1,-26} {2,8} {3,10}  {4}" -f $tag, $it.name, $it.id, $it.mem_human, $hint) -ForegroundColor $color
    }
    Write-Host ""
    Write-Host "  🔒 = 关键系统进程，禁止结束。" -ForegroundColor DarkGray
    Write-Host "  结束某进程: open365 process kill -Id <上面的PID>" -ForegroundColor Cyan
    Write-Host ""
}

function Stop-Proc([int]$targetPid) {
    if ($targetPid -le 0) { throw '请用 -Id 指定要结束的进程 PID' }
    $p = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
    if (-not $p) { throw "找不到进程 PID=$targetPid（可能已退出，先运行 list 查看）" }

    $name = $p.ProcessName
    $sid = -1; try { $sid = [int]$p.SessionId } catch { $sid = -1 }
    $isProtected = ($ProtectedNames -contains $name.ToLower()) -or ($p.Id -eq $PID) -or ($sid -eq 0)
    if ($isProtected) {
        throw "'$name' (PID $targetPid) 是关键系统进程，禁止结束（结束它可能导致系统不稳定/死机）。"
    }

    try {
        Stop-Process -Id $targetPid -Force -ErrorAction Stop
    }
    catch {
        if (-not (Test-Admin)) {
            throw "结束 '$name' 失败：可能是已提权/其他用户的进程，需要管理员权限。请用 Open365.exe（自动提权）后再试。"
        }
        throw "结束 '$name' (PID $targetPid) 失败：$($_.Exception.Message)"
    }
    Write-Host "  [OK] 已结束 '$name' (PID $targetPid)" -ForegroundColor Green
    return @{ ok = $true; id = $targetPid; name = $name; action = 'kill' }
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'list' { $it = Get-ProcList; if ($Json) { $output = @{ processes = $it; count = $it.Count } } else { Show-List $it } }
    'kill' { $output = Stop-Proc $Id }
    'help' {
        Write-Host @"
Open365 进程管理引擎

用法: process.ps1 <action> [-Id <pid>] [-Json]

  list                列出运行中的进程（只读，按内存排序）
  kill  -Id <pid>     结束某个进程（-Force）

安全护栏：关键系统进程(系统会话/白名单/自己)一律禁止结束，
避免把电脑搞死机。GUI 会把这些行置灰。

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
