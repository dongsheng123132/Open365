<#
.SYNOPSIS
    注销顽固安全软件卸载后残留的内核驱动 / 服务（含自我保护驱动）。

.DESCRIPTION
    有些第三方安全软件卸载后，仍会留下已加载的内核驱动或服务在后台跑
    （典型是"自我保护"驱动，普通卸载删不掉）。本工具按名字 sc stop + sc delete 注销它们。
    已加载的驱动在 delete 后需【重启】才彻底卸下。逐项记日志到临时目录。

    默认名单为空 —— 必须由使用者显式传入要注销的驱动 / 服务名（避免误伤系统组件）。
    先用「软件卸载」的残留扫描 / 或任务管理器确认名字，再传进来。

.PARAMETER Drivers
    要注销的内核驱动名（可多个）。

.PARAMETER Services
    要注销的服务名（可多个）。

.EXAMPLE
    # 注销某软件残留的自我保护驱动与服务（名字自行确认后传入）
    powershell -ExecutionPolicy Bypass -File tools\remove-stubborn-drivers.ps1 `
        -Drivers SomeDrvA,SomeDrvB -Services SomeSvc

.NOTES
    需要管理员权限。删的是你显式点名的项，绝不猜测。重启后驱动彻底卸下。
#>
param(
    [string[]]$Drivers = @(),
    [string[]]$Services = @()
)

$ErrorActionPreference = 'Continue'
$log = Join-Path $env:TEMP ("open365-remove-drivers-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
"=== 注销顽固驱动/服务 ===" | Set-Content -Path $log -Encoding UTF8
function Log($m) { $m | Add-Content -Path $log -Encoding UTF8; Write-Host $m }

$targets = @($Drivers + $Services | Where-Object { $_ })
if ($targets.Count -eq 0) {
    Write-Host "未指定要注销的驱动 / 服务。用法示例：" -ForegroundColor Yellow
    Write-Host "  tools\remove-stubborn-drivers.ps1 -Drivers DrvA,DrvB -Services SvcA" -ForegroundColor Cyan
    Write-Host "（先用『软件卸载』残留扫描确认名字，再传入。）" -ForegroundColor DarkGray
    exit 0
}

foreach ($n in $targets) {
    $stop = (& sc.exe stop "$n" 2>&1) -join ' '
    $del  = (& sc.exe delete "$n" 2>&1) -join ' '
    Log ("[{0}] stop: {1} | delete: {2}" -f $n, $stop.Trim(), $del.Trim())
}
Log "=== 完成（重启后驱动彻底卸下）。日志: $log ==="
