<#
.SYNOPSIS
    Open365 守夜模式引擎 (focus / stay-awake engine)
    面向 AI 时代的小功能：让 Claude Code 等 AI 通宵干活时，
    电脑【不熄屏、不睡眠、不锁屏】，干完自动还原。

.DESCRIPTION
    用 Windows 系统级 API SetThreadExecutionState 声明"我在忙，别睡"。
    关键优点：只在本进程运行期间生效，按键退出/关窗口就【自动还原】，
    不会像 powercfg 那样永久改你的电源计划。无后台、无捆绑、无联网。

    典型场景：晚上让 AI 跑长任务（编译/训练/批处理/通宵编程），
    既不想屏幕灭、电脑睡，又不想永久关掉省电设置。

.NOTES
    设计为"CLI 即本地 API"。status 只读；on 是前台保持，按任意键退出并还原。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('on', 'status', 'help')]
    [string]$Action = 'on',

    [switch]$Json,
    [int]$Hours = 0,            # 0 = 一直保持到按键；>0 = N 小时后自动退出
    [switch]$AllowScreenOff,    # 只防睡眠，允许屏幕熄灭（省电，适合纯下载/编译）
    [switch]$AllowUpdateReboot  # 默认会临时挡掉 Windows Update 自动重启；加此开关则不挡
)

$ErrorActionPreference = 'Stop'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- SetThreadExecutionState 声明 ----------
# ES_CONTINUOUS=0x80000000 持续生效  ES_SYSTEM_REQUIRED=0x1 防睡眠  ES_DISPLAY_REQUIRED=0x2 防熄屏
if (-not ('Open365.Sleeper' -as [type])) {
    Add-Type @"
using System;
using System.Runtime.InteropServices;
namespace Open365 {
  public static class Sleeper {
    [DllImport("kernel32.dll", SetLastError=true)]
    public static extern uint SetThreadExecutionState(uint esFlags);
  }
}
"@
}
$ES_CONTINUOUS        = [uint32]'0x80000000'
$ES_SYSTEM_REQUIRED   = [uint32]'0x00000001'
$ES_DISPLAY_REQUIRED  = [uint32]'0x00000002'

function Set-StayAwake([bool]$keepDisplay) {
    $flags = $ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED
    if ($keepDisplay) { $flags = $flags -bor $ES_DISPLAY_REQUIRED }
    [Open365.Sleeper]::SetThreadExecutionState($flags) | Out-Null
}

function Clear-StayAwake {
    # 只留 ES_CONTINUOUS 即清除所有"别睡"声明，恢复系统默认行为。
    [Open365.Sleeper]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
}

# ---------- 临时挡掉 Windows Update 自动重启（可还原） ----------
# 用策略值 NoAutoRebootWithLoggedOnUsers=1：有用户登录时，更新装完也不自动重启。
# 进守夜时设上、退出时精确还原（之前没有就删掉、之前有就写回原值），不留痕。
# 需要管理员；没有管理员就跳过（防熄屏照常生效），不让这个可选项拖垮主功能。
$script:WU_AU_KEY = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:WU_VAL    = 'NoAutoRebootWithLoggedOnUsers'
$script:wuApplied   = $false      # 这次有没有真的改过，决定 finally 要不要还原
$script:wuKeyCreated = $false     # 键是我们建的吗？是则还原时整键删掉
$script:wuHadValue   = $false     # 原本有没有这个值
$script:wuOldValue   = $null      # 原值（用于写回）

function Block-UpdateReboot {
    if (-not (Test-Admin)) {
        return @{ ok = $false; reason = 'no-admin' }
    }
    try {
        if (-not (Test-Path $script:WU_AU_KEY)) {
            New-Item -Path $script:WU_AU_KEY -Force | Out-Null
            $script:wuKeyCreated = $true
        } else {
            $cur = Get-ItemProperty -Path $script:WU_AU_KEY -Name $script:WU_VAL -ErrorAction SilentlyContinue
            if ($null -ne $cur -and $cur.PSObject.Properties.Name -contains $script:WU_VAL) {
                $script:wuHadValue = $true
                $script:wuOldValue = $cur.$($script:WU_VAL)
            }
        }
        Set-ItemProperty -Path $script:WU_AU_KEY -Name $script:WU_VAL -Value 1 -Type DWord
        $script:wuApplied = $true
        return @{ ok = $true }
    } catch {
        return @{ ok = $false; reason = $_.Exception.Message }
    }
}

function Restore-UpdateReboot {
    if (-not $script:wuApplied) { return }   # 没改过就不动
    try {
        if ($script:wuKeyCreated) {
            # 整个键是我们建的 -> 删掉，干干净净
            Remove-Item -Path $script:WU_AU_KEY -Recurse -Force -ErrorAction SilentlyContinue
        } elseif ($script:wuHadValue) {
            # 原本有值 -> 写回原值
            Set-ItemProperty -Path $script:WU_AU_KEY -Name $script:WU_VAL -Value $script:wuOldValue -Type DWord
        } else {
            # 键本来就在、但没这个值 -> 只删我们加的值
            Remove-ItemProperty -Path $script:WU_AU_KEY -Name $script:WU_VAL -ErrorAction SilentlyContinue
        }
    } catch { }
}

# ---------- status：看当前电源超时（只读） ----------

function Invoke-Status {
    # 读当前电源计划的"显示器关闭/睡眠"超时（分钟），让用户知道默认多久会熄/睡。
    function Get-Timeout([string]$flag) {
        try {
            $line = (powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null | Out-String)
        } catch {}
        return $null
    }
    $ac = $null; $dc = $null
    try {
        $q = powercfg /query SCHEME_CURRENT SUB_VIDEO VIDEOIDLE 2>$null | Out-String
        if ($q -match '当前交流电源设置索引[:：]\s*0x([0-9a-fA-F]+)' -or $q -match 'Current AC Power Setting Index[:：]\s*0x([0-9a-fA-F]+)') {
            $ac = [Convert]::ToInt32($Matches[1], 16) / 60
        }
        if ($q -match '当前直流电源设置索引[:：]\s*0x([0-9a-fA-F]+)' -or $q -match 'Current DC Power Setting Index[:：]\s*0x([0-9a-fA-F]+)') {
            $dc = [Convert]::ToInt32($Matches[1], 16) / 60
        }
    } catch {}
    $r = [ordered]@{
        display_off_ac_min = $ac    # 接电时多少分钟熄屏（0=从不）
        display_off_dc_min = $dc    # 用电池时多少分钟熄屏
        note = '守夜模式开启后，以上超时被临时忽略；退出即恢复。'
    }
    if (-not $Json) {
        Write-Host ""
        Write-Host "  ========== 当前熄屏/睡眠设置（只读） ==========" -ForegroundColor White
        Write-Host "    接电时熄屏  : $(if ($ac -eq $null) {'未知'} elseif ($ac -eq 0) {'从不'} else {"$ac 分钟"})"
        Write-Host "    电池时熄屏  : $(if ($dc -eq $null) {'未知'} elseif ($dc -eq 0) {'从不'} else {"$dc 分钟"})"
        Write-Host "    $($r.note)" -ForegroundColor DarkGray
        Write-Host ""
    }
    return $r
}

# ---------- on：进入守夜模式 ----------

function Invoke-On {
    $keepDisplay = -not $AllowScreenOff
    $endText = if ($Hours -gt 0) { "$Hours 小时后自动退出" } else { "一直保持" }
    $dispText = if ($keepDisplay) { "屏幕常亮 + 不睡眠 + 不锁屏" } else { "不睡眠（允许屏幕熄灭省电）" }

    # 临时挡掉 Windows Update 自动重启（除非 -AllowUpdateReboot；需要管理员）
    $wuText = '保留系统默认（更新可能自动重启）'
    if (-not $AllowUpdateReboot) {
        $wu = Block-UpdateReboot
        if ($wu.ok) {
            $wuText = '已临时挡掉（更新装完不自动重启，退出还原）'
        } elseif ($wu.reason -eq 'no-admin') {
            $wuText = '需管理员才能挡，已跳过（防熄屏照常生效）'
        } else {
            $wuText = "尝试失败：$($wu.reason)"
        }
    }

    if (-not $Json) {
        Write-Host ""
        Write-Host "  ========== 守夜模式 已开启 ==========" -ForegroundColor White
        Write-Host ""
        Write-Host "    防睡眠 : $dispText" -ForegroundColor Green
        Write-Host "    防重启 : $wuText" -ForegroundColor Green
        Write-Host "    时长   : $endText" -ForegroundColor Green
        Write-Host ""
        Write-Host "    现在可以让 AI 安心通宵干活了。" -ForegroundColor Cyan
        Write-Host "    >>> 按任意键退出守夜模式（自动还原所有设置） <<<" -ForegroundColor Yellow
        Write-Host ""
    }

    Set-StayAwake $keepDisplay
    $startedAt = Get-Date
    $deadline = if ($Hours -gt 0) { $startedAt.AddHours($Hours) } else { $null }

    try {
        while ($true) {
            # 每隔几秒重新声明一次，确保系统始终知道"有人在忙"。
            Set-StayAwake $keepDisplay

            if ($deadline -and (Get-Date) -ge $deadline) {
                if (-not $Json) { Write-Host "  到点了，自动退出守夜模式。" -ForegroundColor Cyan }
                break
            }
            # 控制台正常时可按键退出；若 stdin 被重定向(无控制台)则跳过按键检测，
            # 靠 -Hours 到点或 Ctrl+C 退出，避免崩溃。
            try {
                if ([Console]::KeyAvailable) {
                    [Console]::ReadKey($true) | Out-Null
                    if (-not $Json) { Write-Host "  收到按键，退出守夜模式。" -ForegroundColor Cyan }
                    break
                }
            } catch { }
            Start-Sleep -Seconds 20
        }
    } finally {
        # 无论正常退出、超时、还是 Ctrl+C，都还原：睡眠行为 + 更新重启策略。
        Clear-StayAwake
        Restore-UpdateReboot
        if (-not $Json) {
            $elapsed = [int]((Get-Date) - $startedAt).TotalMinutes
            Write-Host ""
            Write-Host "  [OK] 守夜模式已退出，所有设置已还原（共守了约 $elapsed 分钟）。" -ForegroundColor Green
            Write-Host ""
        }
    }
    return [ordered]@{ ok = $true; action = 'on'; kept_display = $keepDisplay; hours = $Hours; blocked_update_reboot = $script:wuApplied }
}

# ---------- 入口分发 ----------

$output = $null
switch ($Action) {
    'on'     { $output = Invoke-On }
    'status' { $output = Invoke-Status }
    'help' {
        Write-Host @"
Open365 守夜模式 —— 让 AI 通宵干活，电脑不熄屏/不睡眠/不锁屏（退出自动还原）

用法: focus.ps1 <action> [-Hours N] [-AllowScreenOff] [-Json]

  on                   进入守夜模式，一直保持到【按任意键】退出（默认）
  on -Hours 8          守 8 小时后自动退出
  on -AllowScreenOff   只防睡眠，允许屏幕熄灭（省电，适合纯编译/下载）
  on -AllowUpdateReboot 不挡 Windows Update 自动重启（默认会临时挡掉）
  status               查看当前熄屏/睡眠超时设置（只读）

进守夜会做两件事，退出全部自动还原：
  1) SetThreadExecutionState 声明"我在忙" -> 不熄屏/不睡眠（无需管理员）
  2) 临时设 NoAutoRebootWithLoggedOnUsers -> 更新装完不自动重启（需管理员，
     没权限就自动跳过，不影响防熄屏）
只在本程序运行期间生效，退出即精确还原（之前没有就删、之前有就写回原值）。
"@
    }
}

if ($Json -and $output) {
    $output | ConvertTo-Json -Depth 6 -Compress
}
