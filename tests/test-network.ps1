<#
  Open365 网络引擎自测
  策略：注入一个"假流氓代理"模拟断网故障 -> 验证诊断能识别 -> 验证修复能清除。
  只动 HKCU 代理键，测试前先备份，结束/出错都还原，绝不破坏真实环境。

  注意：测试中间几秒，本机网页会真的打不开（因为代理被指向死地址）。
#>
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\engine\network.ps1'
$reg = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }

# --- 0. 备份当前真实代理设置 ---
Section "0. 备份当前代理设置"
$bakEnable = (Get-ItemProperty -Path $reg -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
$bakServer = (Get-ItemProperty -Path $reg -Name ProxyServer -ErrorAction SilentlyContinue).ProxyServer
Write-Host "  原 ProxyEnable = $bakEnable"
Write-Host "  原 ProxyServer = $bakServer"

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}

try {
    # --- 1. 注入假流氓代理（指向一个不存在的外部地址 -> 网页会打不开） ---
    Section "1. 模拟故障：注入假流氓代理 10.255.255.1:9999"
    Set-ItemProperty -Path $reg -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -Path $reg -Name ProxyServer -Value '10.255.255.1:9999' -Type String
    Write-Host "  已注入。现在系统层面网页应当打不开。"

    # --- 2. 跑诊断，拿 JSON 结果 ---
    Section "2. 跑 Open365 诊断 (diagnose -Json)"
    $jsonText = & powershell -NoProfile -ExecutionPolicy Bypass -File $engine diagnose -Json 2>&1 | Out-String
    $diag = $jsonText | ConvertFrom-Json
    Write-Host "  代理识别: enabled=$($diag.proxy.enabled) server=$($diag.proxy.server)"
    Write-Host "  web_direct(直连)   = $($diag.tests.web_direct)"
    Write-Host "  web_via_proxy(走代理) = $($diag.tests.web_via_proxy)"
    Write-Host "  web_works(实际)    = $($diag.tests.web_works)"
    Write-Host "  结论: $($diag.verdict)"
    Write-Host "  建议: $($diag.suggestion)"

    Check "诊断检测到代理已开启"                 ($diag.proxy.enabled -eq $true)
    Check "诊断认出坏代理地址"                   ($diag.proxy.server -eq '10.255.255.1:9999')
    Check "直连仍可上网 (web_direct=true)"        ($diag.tests.web_direct -eq $true)
    Check "走坏代理上不了网 (web_via_proxy=false)" ($diag.tests.web_via_proxy -eq $false)
    Check "诊断建议 clear-proxy"                  ($diag.suggestion -eq 'clear-proxy')

    # --- 3. 执行修复 ---
    Section "3. 执行修复 (clear-proxy)"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $engine clear-proxy 2>&1 | Out-String | Write-Host

    # --- 4. 验证修复结果 ---
    Section "4. 验证修复后状态"
    $afterEnable = (Get-ItemProperty -Path $reg -Name ProxyEnable -ErrorAction SilentlyContinue).ProxyEnable
    Write-Host "  修复后 ProxyEnable = $afterEnable"
    Check "修复后系统代理已关闭 (ProxyEnable=0)" ($afterEnable -eq 0)

    # 再跑一次诊断确认恢复
    $jsonText2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $engine diagnose -Json 2>&1 | Out-String
    $diag2 = $jsonText2 | ConvertFrom-Json
    Write-Host "  修复后 web_works = $($diag2.tests.web_works)"
    Check "修复后网页恢复可访问 (web_works=true)" ($diag2.tests.web_works -eq $true)
}
finally {
    # --- 还原真实代理设置（无论成败都执行） ---
    Section "5. 还原你原本的代理设置"
    if ($null -ne $bakEnable) { Set-ItemProperty -Path $reg -Name ProxyEnable -Value $bakEnable -Type DWord }
    else { Remove-ItemProperty -Path $reg -Name ProxyEnable -ErrorAction SilentlyContinue }
    if ($null -ne $bakServer) { Set-ItemProperty -Path $reg -Name ProxyServer -Value $bakServer -Type String }
    else { Remove-ItemProperty -Path $reg -Name ProxyServer -ErrorAction SilentlyContinue }
    Write-Host "  已还原: ProxyEnable=$bakEnable ProxyServer=$bakServer" -ForegroundColor Green
}

Section "6. hosts 文件只读体检（本地判断，不改 hosts）"
. $engine help *>$null
$tmpDir = Join-Path $env:TEMP ("o365-hosts-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
$clean = Join-Path $tmpDir 'hosts-clean'
"# comment`n127.0.0.1 localhost`n::1 localhost" | Set-Content -LiteralPath $clean -Encoding ASCII
$bad = Join-Path $tmpDir 'hosts-bad'
"# comment`n0.0.0.0 windowsupdate.microsoft.com`n127.0.0.1 localhost" | Set-Content -LiteralPath $bad -Encoding ASCII
Check "Get-HostsFindings 已加载"     ($null -ne (Get-Command Get-HostsFindings -ErrorAction SilentlyContinue))
Check "干净 hosts 不报可疑"          ((Get-HostsFindings $clean).suspicious -eq $false)
$rb = Get-HostsFindings $bad
Check "劫持 windowsupdate 被识别"    ($rb.suspicious -eq $true -and $rb.hits.Count -ge 1)
Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

Section "测试结果"
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
