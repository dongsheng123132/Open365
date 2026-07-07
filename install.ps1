<#
.SYNOPSIS
    Open365 一键安装 / 卸载脚本（面向 AI 代理与人类都友好）。

.DESCRIPTION
    从克隆下来的仓库目录里一条命令完成安装：
      1) 用 Windows 自带的 .NET Framework csc 编译 GUI -> Open365.exe（零第三方依赖）
      2) 在桌面创建「Open365」快捷方式（以管理员身份运行）
      3) 可选：登录时自启（计划任务，-Autostart）
      4) 启动托盘程序（除非 -NoLaunch）

    全程不联网、不装任何 SDK、不写你没授权的地方。可用 -Uninstall 干净卸载。

.PARAMETER Autostart
    额外注册"登录时自启"（计划任务 Open365Tray，最高权限）。

.PARAMETER NoLaunch
    安装完不自动启动（只编译 + 建快捷方式）。

.PARAMETER Uninstall
    卸载：停进程、删快捷方式、删自启计划任务（不删源码，不碰你的数据）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File install.ps1
    powershell -ExecutionPolicy Bypass -File install.ps1 -Autostart
    powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall

.NOTES
    退出码：0=成功，1=失败（AI 代理可据此判断）。所有关键步骤打印 [OK]/[FAIL]。
#>
[CmdletBinding()]
param(
    [switch]$Autostart,
    [switch]$NoLaunch,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$root    = $PSScriptRoot
$exePath = Join-Path $root 'Open365.exe'
$taskName = 'Open365Tray'
$lnkPath = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Open365.lnk'

function Ok($m)   { Write-Host "[OK]   $m" -ForegroundColor Green }
function Info($m) { Write-Host "[..]   $m" -ForegroundColor Cyan }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }

# ---------------- 卸载 ----------------
if ($Uninstall) {
    Info '卸载 Open365（不删源码 / 不碰你的数据）...'
    try { Get-Process -Name 'Open365' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Ok '已停止运行中的 Open365' } catch {}
    try { schtasks /Delete /TN $taskName /F 2>$null | Out-Null; Ok "已移除自启计划任务 $taskName" } catch {}
    if (Test-Path $lnkPath) { Remove-Item $lnkPath -Force; Ok '已删除桌面快捷方式' }
    Ok '卸载完成。源码仍在，可随时重装。'
    exit 0
}

# ---------------- 1) 编译 ----------------
Info '定位 .NET Framework 编译器 (csc)...'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) {
    Fail '找不到 csc.exe。需要 .NET Framework 4.x（Win10/11 默认自带）。'
    exit 1
}
Ok "找到 csc: $csc"

# 若旧版正在运行，用改名法让路（运行中的 exe 不可覆盖但可改名）
if (Test-Path $exePath) {
    try { Get-Process -Name 'Open365' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue } catch {}
    Start-Sleep -Milliseconds 400
    try { Remove-Item $exePath -Force -ErrorAction Stop }
    catch { try { Move-Item $exePath (Join-Path $root ('Open365-old-' + (Get-Random) + '.exe')) -Force } catch {} }
}

Info '编译 GUI -> Open365.exe（用系统 csc，无需任何 SDK）...'
$gui = Join-Path $root 'gui'
$src = @(Get-ChildItem -Path $gui -Filter '*.cs' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
if ($src.Count -eq 0) { Fail "gui/ 下没有源文件，仓库不完整？"; exit 1 }

$cscArgs = @(
    '/nologo', '/target:winexe', '/optimize+',
    ('/out:' + $exePath),
    ('/win32manifest:' + (Join-Path $gui 'app.manifest')),
    '/reference:System.dll', '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll', '/reference:System.Web.Extensions.dll'
) + $src

& $csc @cscArgs
if ($LASTEXITCODE -ne 0 -or -not (Test-Path $exePath)) { Fail "编译失败 (exit $LASTEXITCODE)"; exit 1 }
$kb = [math]::Round((Get-Item $exePath).Length / 1KB, 1)
Ok "编译成功 -> Open365.exe ($kb KB)"

# ---------------- 2) 桌面快捷方式 ----------------
Info '创建桌面快捷方式「Open365」...'
try {
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath = $exePath
    $lnk.WorkingDirectory = $root
    $lnk.Description = 'Open365 开源电脑助手'
    $lnk.Save()
    Ok "已创建: $lnkPath"
} catch { Fail "创建快捷方式失败: $($_.Exception.Message)（不影响使用，可直接双击 Open365.exe）" }

# ---------------- 3) 可选自启 ----------------
if ($Autostart) {
    Info '注册登录时自启（计划任务，最高权限）...'
    try {
        schtasks /Create /TN $taskName /TR "`"$exePath`"" /SC ONLOGON /RL HIGHEST /F 2>$null | Out-Null
        Ok "已注册自启: $taskName（下次登录自动常驻托盘）"
    } catch { Fail "注册自启失败（需要管理员）: $($_.Exception.Message)" }
}

# ---------------- 4) 启动 ----------------
if (-not $NoLaunch) {
    Info '启动 Open365（右下角托盘盾牌图标）...'
    try { Start-Process -FilePath $exePath -WorkingDirectory $root; Ok '已启动，看右下角托盘。' }
    catch { Fail "启动失败（可手动双击 Open365.exe）: $($_.Exception.Message)" }
}

Write-Host ''
Ok '安装完成。托盘盾牌图标 -> 打开管理中心 -> 「一键体检」。'
Write-Host '   卸载：powershell -ExecutionPolicy Bypass -File install.ps1 -Uninstall' -ForegroundColor DarkGray
exit 0
