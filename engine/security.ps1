<#
.SYNOPSIS
    Open365 安全护盾引擎 (security engine)
    专注守住电脑安全 —— 不自研杀毒，
    而是确保 Windows 自带的三道防线全部开启。

.DESCRIPTION
    电脑安全真正不可缺的就三样，且全是 Windows 自带的：
      1) 实时病毒防护  -> Windows Defender (Microsoft Defender Antivirus)
      2) 防火墙        -> Windows 防火墙 (三套配置: 域/专用/公用)
      3) 系统补丁      -> Windows Update 服务
    某些第三方安全软件会偷偷关掉 Defender、接管防火墙、拦截系统更新。
    卸载它们后没人自动帮你重新打开，本引擎负责"自检 + 一键复位"。

    全部基于 Windows 自带 cmdlet (Get-MpComputerStatus / Get-NetFirewallProfile /
    Get-Service)，无后台、无捆绑、无联网上传。

.NOTES
    设计为"CLI 即本地 API"：每个动作都可 -Json 输出结构化结果。
    自检(check)只读不改；复位(enable-*/scan/update-sig)需要管理员权限。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'enable-all', 'enable-defender', 'enable-firewall',
                 'enable-update', 'scan', 'update-sig', 'help')]
    [string]$Action = 'check',

    [switch]$Json,          # 以 JSON 输出结果（给 GUI / 自动化用）
    [switch]$Force          # 跳过交互确认
)

$ErrorActionPreference = 'Stop'

# ---------- 工具函数 ----------

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Require-Admin {
    if (-not (Test-Admin)) {
        throw "此操作需要管理员权限。请右键 PowerShell -> 以管理员身份运行，或用 open365.bat（会自动提权）。"
    }
}

function Write-Step([string]$msg) {
    if (-not $Json) { Write-Host "  $msg" -ForegroundColor Cyan }
}

function Write-Ok([string]$msg) {
    if (-not $Json) { Write-Host "  [OK] $msg" -ForegroundColor Green }
}

function Write-Warn2([string]$msg) {
    if (-not $Json) { Write-Host "  [!] $msg" -ForegroundColor Yellow }
}

# ---------- 自检（只读，不改任何设置） ----------

function Invoke-Check {
    $result = [ordered]@{
        timestamp = (Get-Date).ToString('s')
        defender  = [ordered]@{}
        firewall  = [ordered]@{}
        update    = [ordered]@{}
        verdict   = $null      # 整体判断
        problems  = @()        # 发现的问题清单
        suggestion = $null     # 建议执行的复位动作
    }

    # 1) Windows Defender 实时防护状态
    #    某些第三方杀软装上后最常见的"坏事"就是把这个关掉。
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $result.defender = [ordered]@{
            available           = $true
            antivirus_enabled   = [bool]$mp.AntivirusEnabled        # 杀毒引擎是否启用
            realtime_enabled     = [bool]$mp.RealTimeProtectionEnabled # 实时防护是否开
            antispyware_enabled = [bool]$mp.AntispywareEnabled
            tamper_protected    = [bool]$mp.IsTamperProtected
            signature_age_days  = [int]$mp.AntivirusSignatureAge      # 病毒库多少天没更新
            last_quick_scan     = if ($mp.QuickScanEndTime) { $mp.QuickScanEndTime.ToString('s') } else { $null }
        }
        if (-not $mp.RealTimeProtectionEnabled) {
            $result.problems += '实时病毒防护已【关闭】(常被第三方杀软偷偷关掉，裸奔风险)'
        }
        if (-not $mp.AntivirusEnabled) {
            $result.problems += '杀毒引擎未启用'
        }
        if ($mp.AntivirusSignatureAge -gt 7) {
            $result.problems += "病毒库已 $($mp.AntivirusSignatureAge) 天没更新"
        }
    } catch {
        # 没有 Defender cmdlet：通常是被某些第三方杀软接管，或服务被停。
        $result.defender = [ordered]@{
            available = $false
            note      = "无法读取 Defender 状态（多半被第三方安全软件接管，或服务被停）：$($_.Exception.Message)"
        }
        $result.problems += '读不到 Windows Defender —— 卸载第三方杀软后请重跑本自检，确认 Defender 已接管'
    }

    # 2) 防火墙三套配置 (域/专用/公用)
    try {
        $profiles = Get-NetFirewallProfile -ErrorAction Stop
        $fwState = @{}
        $fwAllOn = $true
        foreach ($p in $profiles) {
            $fwState[$p.Name] = [bool]$p.Enabled
            if (-not $p.Enabled) { $fwAllOn = $false }
        }
        $result.firewall = [ordered]@{
            available = $true
            domain    = [bool]$fwState['Domain']
            private   = [bool]$fwState['Private']
            public    = [bool]$fwState['Public']
            all_on    = $fwAllOn
        }
        if (-not $fwAllOn) {
            $offs = ($fwState.GetEnumerator() | Where-Object { -not $_.Value } | ForEach-Object { $_.Key }) -join ', '
            $result.problems += "防火墙有配置未开启: $offs"
        }
    } catch {
        $result.firewall = [ordered]@{ available = $false; note = $_.Exception.Message }
        $result.problems += '无法读取防火墙状态'
    }

    # 3) Windows Update 服务 (wuauserv)
    #    某些第三方杀软常把它停掉/禁用，改用自己的"漏洞修复"。
    try {
        $svc = Get-Service -Name 'wuauserv' -ErrorAction Stop
        $startMode = (Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue).StartMode
        $result.update = [ordered]@{
            available  = $true
            status     = "$($svc.Status)"        # Running / Stopped
            start_mode = "$startMode"            # Auto / Manual / Disabled
        }
        if ($startMode -eq 'Disabled') {
            $result.problems += 'Windows Update 服务被【禁用】(系统补丁拿不到了)'
        }
    } catch {
        $result.update = [ordered]@{ available = $false; note = $_.Exception.Message }
        $result.problems += '无法读取 Windows Update 服务状态'
    }

    # 4) 整体判断 + 建议
    if ($result.problems.Count -eq 0) {
        $result.verdict = '三道防线(实时防护 / 防火墙 / 系统更新)全部正常。系统自带防护已全部就位。'
        $result.suggestion = 'none'
    } else {
        $result.verdict = "发现 $($result.problems.Count) 个安全隐患 —— 多半是第三方安全软件接管系统留下的。建议一键复位。"
        $result.suggestion = 'enable-all'
    }

    return $result
}

function Show-Check($r) {
    Write-Host ""
    Write-Host "  ========== 安全护盾自检报告 ==========" -ForegroundColor White
    Write-Host ""
    function mark($b) { if ($b) { "开  ✓" } else { "关  ✗" } }

    # Defender
    Write-Host "  [1] Windows Defender (实时杀毒)" -ForegroundColor White
    if ($r.defender.available) {
        Write-Host "      实时防护   : $(mark $r.defender.realtime_enabled)"
        Write-Host "      杀毒引擎   : $(mark $r.defender.antivirus_enabled)"
        Write-Host "      病毒库     : $($r.defender.signature_age_days) 天前更新"
        if ($r.defender.last_quick_scan) { Write-Host "      上次快扫   : $($r.defender.last_quick_scan)" }
    } else {
        Write-Host "      读不到状态(可能被第三方杀软接管) " -ForegroundColor Yellow
    }
    Write-Host ""

    # 防火墙
    Write-Host "  [2] Windows 防火墙" -ForegroundColor White
    if ($r.firewall.available) {
        Write-Host "      域网络     : $(mark $r.firewall.domain)"
        Write-Host "      专用网络   : $(mark $r.firewall.private)"
        Write-Host "      公用网络   : $(mark $r.firewall.public)"
    } else {
        Write-Host "      读不到状态" -ForegroundColor Yellow
    }
    Write-Host ""

    # 更新
    Write-Host "  [3] Windows Update (系统补丁)" -ForegroundColor White
    if ($r.update.available) {
        Write-Host "      服务状态   : $($r.update.status)  (启动类型: $($r.update.start_mode))"
    } else {
        Write-Host "      读不到状态" -ForegroundColor Yellow
    }
    Write-Host ""

    if ($r.problems.Count -gt 0) {
        Write-Host "  发现的隐患:" -ForegroundColor Yellow
        foreach ($p in $r.problems) { Write-Host "    - $p" -ForegroundColor Yellow }
        Write-Host ""
    }
    Write-Host "  结论:" -ForegroundColor White
    Write-Host "    $($r.verdict)" -ForegroundColor $(if ($r.problems.Count -eq 0) { 'Green' } else { 'Yellow' })
    if ($r.suggestion -ne 'none') {
        Write-Host ""
        Write-Host "  建议执行: open365 security $($r.suggestion)   (需要管理员)" -ForegroundColor Cyan
    }
    Write-Host ""
}

# ---------- 复位动作（需要管理员） ----------

function Enable-Defender {
    Require-Admin
    Write-Step "重新开启 Windows Defender 实时防护..."
    try {
        # 启用实时监控（DisableRealtimeMonitoring=$false 即开启）
        Set-MpPreference -DisableRealtimeMonitoring $false -ErrorAction Stop
        Write-Ok "实时防护已开启"
    } catch {
        Write-Warn2 "开启实时防护失败：$($_.Exception.Message)"
        Write-Warn2 "若仍有第三方杀软在运行，需先卸载它，Defender 才会自动接管。"
    }
    # 确保 Defender 服务在运行
    try {
        $d = Get-Service -Name 'WinDefend' -ErrorAction Stop
        if ($d.Status -ne 'Running') {
            Start-Service -Name 'WinDefend' -ErrorAction Stop
            Write-Ok "Defender 服务(WinDefend)已启动"
        }
    } catch {
        Write-Warn2 "Defender 服务暂不可用（可能仍被第三方接管）。"
    }
}

function Enable-Firewall {
    Require-Admin
    Write-Step "开启全部三套防火墙配置(域/专用/公用)..."
    Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True
    Write-Ok "防火墙已全部开启"
}

function Enable-Update {
    Require-Admin
    Write-Step "恢复 Windows Update 服务(启动类型->自动，并启动)..."
    # 先恢复启动类型，再启动
    Set-Service -Name 'wuauserv' -StartupType Manual -ErrorAction SilentlyContinue
    try {
        $svc = Get-Service -Name 'wuauserv' -ErrorAction Stop
        if ($svc.Status -ne 'Running') { Start-Service -Name 'wuauserv' -ErrorAction Stop }
        Write-Ok "Windows Update 服务已恢复并启动"
    } catch {
        Write-Warn2 "启动 Windows Update 服务失败：$($_.Exception.Message)"
    }
}

function Enable-All {
    Require-Admin
    if (-not $Json) {
        Write-Host ""
        Write-Host "  ========== 安全护盾一键复位 ==========" -ForegroundColor White
        Write-Host ""
    }
    Enable-Defender
    Enable-Firewall
    Enable-Update
    if (-not $Json) {
        Write-Host ""
        Write-Host "  完成！建议再跑一次 open365 security check 确认全绿。" -ForegroundColor Green
        Write-Host ""
    }
}

function Invoke-Scan {
    Require-Admin
    Write-Step "用 Windows Defender 执行快速扫描(QuickScan)..."
    try {
        Start-MpScan -ScanType QuickScan -ErrorAction Stop
        Write-Ok "快速扫描已完成"
    } catch {
        Write-Warn2 "扫描失败：$($_.Exception.Message)"
        Write-Warn2 "若 Defender 仍被第三方接管，请先卸载占用它的第三方杀软。"
    }
}

function Update-Sig {
    Require-Admin
    Write-Step "更新 Windows Defender 病毒库..."
    try {
        Update-MpSignature -ErrorAction Stop
        Write-Ok "病毒库已更新"
    } catch {
        Write-Warn2 "更新病毒库失败：$($_.Exception.Message)"
    }
}

# ---------- 入口分发 ----------

$output = $null
switch ($Action) {
    'check' {
        $r = Invoke-Check
        if ($Json) { $output = $r } else { Show-Check $r }
    }
    'enable-all'      { Enable-All;      $output = @{ ok = $true; action = 'enable-all' } }
    'enable-defender' { Enable-Defender; $output = @{ ok = $true; action = 'enable-defender' } }
    'enable-firewall' { Enable-Firewall; $output = @{ ok = $true; action = 'enable-firewall' } }
    'enable-update'   { Enable-Update;   $output = @{ ok = $true; action = 'enable-update' } }
    'scan'            { Invoke-Scan;     $output = @{ ok = $true; action = 'scan' } }
    'update-sig'      { Update-Sig;      $output = @{ ok = $true; action = 'update-sig' } }
    'help' {
        Write-Host @"
Open365 安全护盾引擎 —— 确保 Windows 自带三道防线全开（换/卸第三方杀软前后必跑）

用法: security.ps1 <action> [-Json] [-Force]

自检 (只读，不改设置):
  check           安全护盾自检：实时防护 / 防火墙 / 系统更新 三项状态 + 隐患清单

复位 (需要管理员):
  enable-all      一键复位三道防线(Defender 实时防护 + 防火墙 + Update 服务)
  enable-defender 只重新开启 Defender 实时防护
  enable-firewall 只开启全部防火墙配置
  enable-update   只恢复 Windows Update 服务
  scan            用 Defender 跑一次快速扫描
  update-sig      更新 Defender 病毒库

加 -Json 可输出结构化结果，供 GUI / 自动化调用。
"@
    }
}

if ($Json -and $output) {
    $output | ConvertTo-Json -Depth 6 -Compress
}
