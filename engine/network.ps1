<#
.SYNOPSIS
    Open365 网络修复引擎 (network engine)
    开源的"断网修复 / LSP修复 / DNS优选"工具。

.DESCRIPTION
    专治 "微信/QQ 能用，浏览器打不开网页" —— 多为 LSP/Winsock 损坏、
    DNS 故障、或被流氓软件偷设代理。

    全部基于 Windows 自带能力 (Get-DnsClient* / netsh / Test-Connection)，
    无后台、无捆绑、无联网上传。

.NOTES
    设计为"CLI 即本地 API"：每个动作都可 -Json 输出结构化结果，
    既供命令行用，也供未来 GUI 调用。
    诊断(Diagnose)只读不改；修复(Repair*)需要管理员权限。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('diagnose', 'repair-all', 'repair-winsock', 'repair-tcpip',
                 'flush-dns', 'renew-ip', 'clear-proxy', 'set-dns', 'help')]
    [string]$Action = 'help',

    [switch]$Json,           # 以 JSON 输出结果（给 GUI / 自动化用）
    [switch]$Force,          # 跳过交互确认
    [string]$Dns = '223.5.5.5,114.114.114.114'  # set-dns 用的 DNS（逗号分隔）
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

# ---------- 诊断（只读，不改任何设置） ----------

# hosts 文件只读体检：数「自定义映射」条数，挑出对主流网站的指向（流氓软件常见劫持面：
# 屏蔽 Windows 更新、劫持首页/激活）。只读、绝不改 hosts；路径作参数便于自测。
function Get-HostsFindings([string]$path) {
    $r = [ordered]@{ entries = 0; suspicious = $false; hits = @() }
    if (-not (Test-Path -LiteralPath $path)) { return $r }
    $major = @('microsoft', 'windowsupdate', 'apple', 'icloud', 'google', 'baidu',
               'qq.com', 'tencent', 'taobao', 'alipay', 'weixin')
    foreach ($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)) {
        $t = "$line".Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        $parts = $t -split '\s+'
        if ($parts.Count -lt 2) { continue }
        $r.entries++
        $ip = $parts[0]
        $hn = ($parts[1..($parts.Count - 1)] -join ' ').ToLower()
        foreach ($m in $major) {
            if ($hn.Contains($m)) { $r.suspicious = $true; $r.hits += "$ip -> $hn"; break }
        }
    }
    return $r
}

function Invoke-Diagnose {
    $result = [ordered]@{
        timestamp   = (Get-Date).ToString('s')
        adapters    = @()
        gateway     = $null
        dns_servers = @()
        proxy       = $null
        tests       = [ordered]@{}
        verdict     = $null      # 给出"病因"判断
        suggestion  = $null      # 建议执行哪个修复
    }

    # 1) 活动网卡 + IP + 网关
    $adapters = Get-NetIPConfiguration | Where-Object { $_.IPv4Address -and $_.NetAdapter.Status -eq 'Up' }
    foreach ($a in $adapters) {
        $result.adapters += [ordered]@{
            name    = $a.InterfaceAlias
            ipv4    = ($a.IPv4Address.IPAddress -join ', ')
            gateway = $a.IPv4DefaultGateway.NextHop
            dns     = ($a.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses } ) -join ', '
        }
    }
    $primary = $adapters | Select-Object -First 1
    $gw = $primary.IPv4DefaultGateway.NextHop
    $result.gateway = $gw
    $result.dns_servers = @($primary.DNSServer | Where-Object { $_.AddressFamily -eq 2 } | ForEach-Object { $_.ServerAddresses })

    # 2) 系统代理状态（流氓软件常在这里下黑手）
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $proxyEnable = (Get-ItemProperty -Path $reg -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    $proxyServer = (Get-ItemProperty -Path $reg -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
    $result.proxy = [ordered]@{
        enabled = [bool]$proxyEnable
        server  = $proxyServer
    }

    # 3) 三级连通性测试：网关 -> 公共IP -> 域名解析
    function Test-Ping([string]$target) {
        try { return [bool](Test-Connection -ComputerName $target -Count 2 -Quiet -ErrorAction Stop) }
        catch { return $false }
    }
    $t_gateway = if ($gw) { Test-Ping $gw } else { $false }

    # 真实"能否打开网页"测试：用 HTTP 抓微软官方网络探测端点。
    # 比 ping 可靠得多 —— 很多环境/代理拦 ICMP，ping 不通≠没网。
    #
    # 关键：测两次 —— 一次直连(绕过代理)、一次走系统代理。
    # 两者对比才能区分"底层链路坏"和"代理坏"：
    #   直连通 + 走代理不通  => 代理坏了（流氓软件偷设/梯子挂了）
    #   直连不通             => 底层(Winsock/TCPIP/DNS)坏了
    function Test-Web([string]$url, [bool]$useSystemProxy) {
        try {
            $req = [System.Net.HttpWebRequest]::Create($url)
            if ($useSystemProxy) {
                # 用系统默认代理（即注册表里那个）
                $req.Proxy = [System.Net.WebRequest]::GetSystemWebProxy()
            } else {
                $req.Proxy = $null        # 绕过代理，测裸连通
            }
            $req.Timeout = 4000
            $req.Method = 'GET'
            $resp = $req.GetResponse()
            $code = [int]$resp.StatusCode
            $resp.Close()
            return ($code -ge 200 -and $code -lt 400)
        } catch { return $false }
    }
    # DNS 解析单独测（即使 HTTP 失败也能区分是不是 DNS 问题）
    $t_dns = $false
    try {
        $rr = Resolve-DnsName -Name 'www.msftconnecttest.com' -Type A -ErrorAction Stop -QuickTimeout
        $t_dns = [bool]($rr | Where-Object { $_.IPAddress })
    } catch { $t_dns = $false }

    # IP 层：直接连一个公网 IP 的 80 端口（绕过 DNS）
    $t_internet = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect('114.114.114.114', 53, $null, $null)
        $t_internet = $iar.AsyncWaitHandle.WaitOne(3000) -and $tcp.Connected
        $tcp.Close()
    } catch { $t_internet = $false }

    # 整条链路测两次：直连 vs 走系统代理
    $url = 'http://www.msftconnecttest.com/connecttest.txt'
    $t_web_direct = Test-Web $url $false           # 绕过代理，测底层链路
    # 只有系统代理开着时才需要测"走代理"；没开代理时两者等价
    if ($result.proxy.enabled -and $result.proxy.server) {
        $t_web_proxy = Test-Web $url $true         # 走系统代理
    } else {
        $t_web_proxy = $t_web_direct
    }
    # "用户实际能否上网" = 系统当前生效路径的结果
    $t_web = if ($result.proxy.enabled -and $result.proxy.server) { $t_web_proxy } else { $t_web_direct }

    $result.tests.gateway_reachable  = $t_gateway
    $result.tests.internet_reachable = $t_internet      # IP 层(TCP)通不通
    $result.tests.dns_works          = $t_dns            # DNS 解析行不行
    $result.tests.web_direct         = $t_web_direct     # 直连能否打开网页
    $result.tests.web_via_proxy      = $t_web_proxy      # 走系统代理能否打开
    $result.tests.web_works          = $t_web            # 用户当前实际能否上网

    # 判断代理是否"可疑"：本地回环代理(127.x)是 Clash/V2Ray 等正常梯子。
    $proxyIsLocal = $result.proxy.server -match '^(127\.|localhost|::1)'

    # 4) 病因判断 + 建议（核心：直连 vs 走代理 的对比）
    if ($t_web) {
        if ($result.proxy.enabled -and $proxyIsLocal) {
            $result.verdict = '网络正常（检测到本地代理 ' + $result.proxy.server + '，是 Clash/V2Ray 这类梯子，属正常，不用动）。如果某浏览器仍打不开，多半是它自己的插件/代理设置。'
        } else {
            $result.verdict = '网络正常。如果某个浏览器仍打不开网页，多半是该浏览器自身代理/插件问题。'
        }
        $result.suggestion = 'none'
    }
    elseif ($result.proxy.enabled -and $t_web_direct -and -not $t_web_proxy) {
        # 决定性证据：绕过代理能上网、走代理上不了 => 就是代理的锅
        $result.verdict = "网页打不开，但绕过代理后能正常上网 —— 确诊是系统代理 ($($result.proxy.server)) 的问题（流氓软件偷设、或梯子已失效）。这正是'能上微信打不开网页'的头号元凶。建议清除代理。"
        $result.suggestion = 'clear-proxy'
    }
    elseif ($t_internet -and -not $t_dns) {
        $result.verdict = 'IP 能通但域名解析失败 —— DNS 故障。建议切换公共 DNS。'
        $result.suggestion = 'set-dns'
    }
    elseif ($t_internet -and $t_dns -and -not $t_web_direct) {
        $result.verdict = 'IP 和 DNS 都正常，但 HTTP 出不去 —— 典型 Winsock/LSP 损坏（微信走自己的协议所以还能用，浏览器走标准 socket 就废了）。建议一键全修复。'
        $result.suggestion = 'repair-all'
    }
    elseif ($t_gateway -and -not $t_internet) {
        $result.verdict = '能到路由器但出不了网 —— 可能 Winsock/TCPIP 损坏，或路由器本身没网。先一键全修复，无效则查路由器。'
        $result.suggestion = 'repair-all'
    }
    elseif (-not $t_gateway) {
        $result.verdict = '连路由器都连不上，但若微信仍能用，则强烈指向 Winsock/LSP 损坏。建议一键全修复。'
        $result.suggestion = 'repair-all'
    }
    else {
        $result.verdict = '网络异常，原因不明确，建议执行一键全修复。'
        $result.suggestion = 'repair-all'
    }

    # 附加只读体检：hosts 是否被改（不改变上面的病因判断，只在结论后追加提醒）
    $result.hosts = Get-HostsFindings "$env:WINDIR\System32\drivers\etc\hosts"
    if ($result.hosts.suspicious) {
        $result.verdict += "  ⚠ 另外：系统 hosts 文件里有对主流网站的自定义指向（$($result.hosts.hits.Count) 条）——若相关网站打不开/更新失败，可能是被流氓软件改了 hosts，建议检查。"
    }

    return $result
}

function Show-Diagnose($r) {
    Write-Host ""
    Write-Host "  ========== 网络体检报告 ==========" -ForegroundColor White
    Write-Host ""
    foreach ($a in $r.adapters) {
        Write-Host "  网卡: $($a.name)"
        Write-Host "    IPv4   : $($a.ipv4)"
        Write-Host "    网关   : $($a.gateway)"
        Write-Host "    DNS    : $($a.dns)"
    }
    Write-Host ""
    Write-Host "  系统代理: " -NoNewline
    if ($r.proxy.enabled) { Write-Host "已开启 -> $($r.proxy.server)" -ForegroundColor Yellow }
    else { Write-Host "未开启 (正常)" -ForegroundColor Green }
    Write-Host ""
    Write-Host "  连通性测试:"
    function mark($b) { if ($b) { "通  ✓" } else { "不通 ✗" } }
    Write-Host "    [1] 网关可达      : $(mark $r.tests.gateway_reachable)"
    Write-Host "    [2] 外网 IP 可达  : $(mark $r.tests.internet_reachable)"
    Write-Host "    [3] DNS 域名解析  : $(mark $r.tests.dns_works)"
    Write-Host "    [4] 网页能否打开  : $(mark $r.tests.web_works)"
    Write-Host ""
    Write-Host "  诊断结论:" -ForegroundColor White
    Write-Host "    $($r.verdict)" -ForegroundColor Yellow
    if ($r.suggestion -ne 'none') {
        Write-Host ""
        Write-Host "  建议执行: open365 network $($r.suggestion)" -ForegroundColor Cyan
    }
    Write-Host ""
}

# ---------- 修复动作（需要管理员） ----------

function Repair-Winsock {
    Require-Admin
    Write-Step "重置 Winsock (LSP)..."
    netsh winsock reset | Out-Null
    Write-Ok "Winsock 已重置（重启后生效）"
}

function Repair-TcpIp {
    Require-Admin
    Write-Step "重置 TCP/IP 协议栈..."
    netsh int ip reset | Out-Null
    Write-Ok "TCP/IP 已重置（重启后生效）"
}

function Flush-Dns {
    Write-Step "清空 DNS 缓存..."
    Clear-DnsClientCache
    Write-Ok "DNS 缓存已清空"
}

function Renew-Ip {
    Require-Admin
    Write-Step "释放并重新获取 IP..."
    ipconfig /release | Out-Null
    ipconfig /renew | Out-Null
    Write-Ok "IP 已重新获取"
}

function Clear-Proxy {
    # 关闭用户代理(改 HKCU)不需要管理员；只有 WinHTTP 那步需要。
    Write-Step "关闭 IE/系统局域网代理（流氓软件最爱在这下手）..."
    $reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 0 -Type DWord
    Set-ItemProperty -Path $reg -Name ProxyServer -Value '' -Type String -ErrorAction SilentlyContinue
    Write-Ok "用户代理已关闭"

    Write-Step "清除 WinHTTP 系统代理..."
    if (Test-Admin) {
        netsh winhttp reset proxy | Out-Null
        Write-Ok "WinHTTP 代理已清除"
    } else {
        Write-Warn2 "WinHTTP 代理需要管理员权限才能清除（已跳过）。如仍有问题，请以管理员身份重跑。"
    }
}

function Set-Dns {
    Require-Admin
    $servers = $Dns -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    Write-Step "把活动网卡 DNS 设为: $($servers -join ', ')"
    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    foreach ($a in $adapters) {
        try {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $servers
            Write-Ok "已设置网卡: $($a.Name)"
        } catch {
            Write-Warn2 "网卡 $($a.Name) 设置失败: $($_.Exception.Message)"
        }
    }
    Clear-DnsClientCache
    Write-Ok "DNS 已切换并清空缓存"
}

function Repair-All {
    Require-Admin
    if (-not $Json) {
        Write-Host ""
        Write-Host "  ========== 一键全修复 ==========" -ForegroundColor White
        Write-Host ""
    }
    Repair-Winsock
    Repair-TcpIp
    Flush-Dns
    Renew-Ip
    Clear-Proxy
    if (-not $Json) {
        Write-Host ""
        Write-Host "  全部完成！请【重启电脑】后再试浏览器。" -ForegroundColor Green
        Write-Host "  （Winsock/TCP-IP 重置必须重启才生效）" -ForegroundColor Yellow
        Write-Host ""
    }
}

# ---------- 入口分发 ----------

$output = $null
switch ($Action) {
    'diagnose' {
        $r = Invoke-Diagnose
        if ($Json) { $output = $r } else { Show-Diagnose $r }
    }
    'repair-all'     { Repair-All;     $output = @{ ok = $true; action = 'repair-all'; reboot_required = $true } }
    'repair-winsock' { Repair-Winsock; $output = @{ ok = $true; action = 'repair-winsock'; reboot_required = $true } }
    'repair-tcpip'   { Repair-TcpIp;   $output = @{ ok = $true; action = 'repair-tcpip'; reboot_required = $true } }
    'flush-dns'      { Flush-Dns;      $output = @{ ok = $true; action = 'flush-dns' } }
    'renew-ip'       { Renew-Ip;       $output = @{ ok = $true; action = 'renew-ip' } }
    'clear-proxy'    { Clear-Proxy;    $output = @{ ok = $true; action = 'clear-proxy' } }
    'set-dns'        { Set-Dns;        $output = @{ ok = $true; action = 'set-dns'; dns = $Dns } }
    'help' {
        Write-Host @"
Open365 网络修复引擎

用法: network.ps1 <action> [-Json] [-Force] [-Dns "1.1.1.1,8.8.8.8"]

诊断 (只读，不改设置):
  diagnose        网络体检 + 自动判断病因 + 给出建议

修复 (需要管理员):
  repair-all      一键全修复 (winsock+tcpip+dns+ip+proxy)
  repair-winsock  只重置 Winsock/LSP
  repair-tcpip    只重置 TCP/IP
  flush-dns       只清 DNS 缓存
  renew-ip        重新获取 IP
  clear-proxy     清除被流氓软件设的代理
  set-dns         切换为公共 DNS (默认 223.5.5.5,114.114.114.114)

加 -Json 可输出结构化结果，供 GUI / 自动化调用。
"@
    }
}

if ($Json -and $output) {
    $output | ConvertTo-Json -Depth 6 -Compress
}
