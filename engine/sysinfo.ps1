<#
.SYNOPSIS
    Open365 系统概况引擎 (sysinfo engine)
    只读探测本机系统信息：系统版本 / CPU / 内存 / 磁盘卷 / 开机时长。

.DESCRIPTION
    info : 汇总输出一份系统概况 JSON（字段命名与 本境协议 u-env 的
           windows.version / host.hardware / host.disk 契约对齐）。
    help : 用法。

    与"零第三方依赖"承诺一致：纯 PowerShell + WMI/注册表，不调用任何
    外部工具，不联网、不写任何文件、不需要管理员权限。

.NOTES
    全程只读。任何一项探测失败只降级该字段（置 null + reason），绝不中断整体输出。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('info', 'help')]
    [string]$Action = 'help',

    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# -Json 输出要能被 UTF-8 解析：脚本自己钉住输出编码，别依赖调用方的控制台代码页。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Out-Data($obj) {
    if ($Json) {
        $obj | ConvertTo-Json -Depth 6
    } else {
        Write-Host ""
        Write-Host "  系统版本 : $($obj.system.product_name)  $($obj.system.display_version) (build $($obj.system.build))"
        Write-Host "  处理器   : $($obj.cpu.name)  ($($obj.cpu.cores) 核 / $($obj.cpu.logical) 线程)"
        $mt = [Math]::Round($obj.memory.total_bytes / 1GB, 1)
        $mu = [Math]::Round(($obj.memory.total_bytes - $obj.memory.free_bytes) / 1GB, 1)
        Write-Host "  内存     : $mu / $mt GB (已用 $($obj.memory.used_percent)%)"
        foreach ($d in $obj.disks) {
            $dt = [Math]::Round($d.total_bytes / 1GB, 0)
            $df = [Math]::Round($d.free_bytes / 1GB, 0)
            $dp = if ($d.total_bytes -gt 0) { [Math]::Round($d.free_bytes / $d.total_bytes * 100) } else { 0 }
            Write-Host ("  磁盘 {0}  : {1} / {2} GB 可用 ({3}%)  [{4}]" -f $d.drive, $df, $dt, $dp, $d.filesystem)
        }
        if ($obj.uptime_seconds -ne $null) {
            $up = [TimeSpan]::FromSeconds($obj.uptime_seconds)
            Write-Host "  开机时长 : $($up.Days) 天 $($up.Hours) 小时 $($up.Minutes) 分"
        }
        Write-Host ""
    }
}

function Get-SysInfo {
    $r = [ordered]@{
        ok             = $true
        checked_at     = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        system         = [ordered]@{}
        cpu            = [ordered]@{}
        memory         = [ordered]@{}
        disks          = @()
        uptime_seconds = $null
        booted_at      = $null
    }

    # ---------- 系统版本（对齐 u-env windows.version） ----------
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $nv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
        $r.system.product_name    = ($os.Caption -replace '^Microsoft ', '')
        $r.system.display_version = $nv.DisplayVersion
        $r.system.version         = $os.Version
        $r.system.build           = [int]$os.BuildNumber
        $r.system.edition         = $nv.EditionID
        # 架构统一成 x64/x86（u-env 同款），不吐本地化的"64 位"
        $r.system.architecture    = if ($os.OSArchitecture -match '64') { 'x64' } else { 'x86' }
    } catch {
        $r.system.reason = '读取系统版本失败: ' + $_.Exception.Message
    }

    # ---------- CPU（对齐 u-env host.hardware） ----------
    try {
        $cpu = Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1
        $r.cpu.name    = $cpu.Name.Trim()
        $r.cpu.cores   = [int]$cpu.NumberOfCores
        $r.cpu.logical = [int]$cpu.NumberOfLogicalProcessors
    } catch {
        $r.cpu.reason = '读取 CPU 失败: ' + $_.Exception.Message
    }

    # ---------- 内存 ----------
    try {
        $os2 = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $total = [int64]$os2.TotalVisibleMemorySize * 1KB
        $free  = [int64]$os2.FreePhysicalMemory * 1KB
        $r.memory.total_bytes = $total
        $r.memory.free_bytes  = $free
        $r.memory.used_percent = if ($total -gt 0) { [Math]::Round(($total - $free) / $total * 100, 1) } else { 0 }
    } catch {
        $r.memory.reason = '读取内存失败: ' + $_.Exception.Message
    }

    # ---------- 磁盘卷（对齐 u-env host.disk，只列固定盘/可移动盘，跳过光驱） ----------
    try {
        $vols = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3 or DriveType=2' -ErrorAction Stop
        $list = @()
        foreach ($v in $vols) {
            $list += [ordered]@{
                drive        = $v.DeviceID
                filesystem   = $v.FileSystem
                total_bytes  = [int64]$v.Size
                free_bytes   = [int64]$v.FreeSpace
                used_percent = if ($v.Size -gt 0) { [Math]::Round(($v.Size - $v.FreeSpace) / $v.Size * 100, 1) } else { 0 }
            }
        }
        $r.disks = $list
    } catch {
        $r.disks_reason = '读取磁盘失败: ' + $_.Exception.Message
    }

    # ---------- 开机时长 ----------
    try {
        $os3 = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        if ($os3.LastBootUpTime) {
            $r.booted_at      = $os3.LastBootUpTime.ToString('yyyy-MM-ddTHH:mm:ssK')
            $r.uptime_seconds = [int64]((Get-Date) - $os3.LastBootUpTime).TotalSeconds
        }
    } catch {
        $r.uptime_reason = '读取开机时长失败: ' + $_.Exception.Message
    }

    return $r
}

switch ($Action) {
    'info' {
        $r = Get-SysInfo
        Out-Data $r
        exit 0
    }
    default {
        Get-Content -LiteralPath $PSCommandPath | Select-Object -First 1 | Out-Null
        Write-Host "Open365 系统概况引擎"
        Write-Host ""
        Write-Host "用法: sysinfo.ps1 <action> [-Json]"
        Write-Host ""
        Write-Host "  info    汇总输出系统概况（只读）：系统版本/CPU/内存/磁盘卷/开机时长"
        Write-Host ""
        Write-Host "加 -Json 输出结构化结果。"
        exit 0
    }
}
