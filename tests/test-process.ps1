<#
  Open365 进程引擎自测
  策略：起一个一次性的"睡眠"测试进程（无窗口、名字不在保护白名单）
        -> list 能发现且 protected=false
        -> 验证关键系统进程(PID 4 System)被拒绝结束
        -> kill 测试进程 -> 验证它真的没了
  全程只碰这个自建测试进程，绝不动任何真实进程。
#>
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\engine\process.ps1'

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }
function Run-Engine([string[]]$a) {
    # 子进程结束系统进程时会向 stderr 写拒绝信息；PS5.1 在 Stop 下会把它当终止错误，
    # 这里降为 Continue 以便把 stderr 当普通文本捕获（用于"应被拒绝"的断言）。
    $ErrorActionPreference = 'Continue'
    & powershell -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '$engine' $($a -join ' ')" 2>&1 | Out-String
}

$testPid = $null
try {
    Section "0. 起一个一次性测试进程（cmd ping 自身，无窗口）"
    $proc = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', 'ping -n 120 127.0.0.1' -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 600
    $testPid = $proc.Id
    Check "测试进程已启动 (PID $testPid)" ($null -ne (Get-Process -Id $testPid -ErrorAction SilentlyContinue))

    Section "1. list 能否发现它，且未被保护"
    $json = Run-Engine @('list', '-Json')
    $data = $json | ConvertFrom-Json
    $found = $data.processes | Where-Object { $_.id -eq $testPid }
    Check "list 发现测试进程"        ($null -ne $found)
    Check "测试进程 protected=false" ($found.protected -eq $false)
    Check "count 字段存在且>0"       ($data.count -gt 0)

    Section "2. 关键系统进程必须拒绝结束 (PID 4 = System)"
    $sysOut = Run-Engine @('kill', '-Id', '4')
    Check "拒绝结束系统进程"         ($sysOut -match '禁止结束|关键系统进程')
    Check "System(PID 4) 仍存活"     ($null -ne (Get-Process -Id 4 -ErrorAction SilentlyContinue))

    Section "3. kill 结束测试进程"
    $killOut = Run-Engine @('kill', '-Id', "$testPid", '-Json')
    Write-Host "    引擎返回: $($killOut.Trim())" -ForegroundColor DarkGray
    Start-Sleep -Milliseconds 600
    Check "测试进程已被结束"         ($null -eq (Get-Process -Id $testPid -ErrorAction SilentlyContinue))
}
finally {
    Section "4. 清理（兜底结束残留测试进程）"
    if ($testPid) { Stop-Process -Id $testPid -Force -ErrorAction SilentlyContinue }
    Write-Host "  清理完成"
}

Section "测试结果"
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
