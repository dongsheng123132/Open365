<#
  Open365 启动项引擎自测
  策略：在 HKCU Run 键造一个 Open365 自己的测试项 -> disable -> 验证移到备份键且原位消失
        -> enable -> 验证移回原位。全程只碰这个自建测试项，不动任何真实启动项。
#>
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\engine\startup.ps1'
$runKey      = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$disabledKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run\Open365-Disabled'
$testName = '__open365_selftest__'
$testCmd  = 'C:\Windows\System32\notepad.exe'
$testId   = "reg:hkcu-run:$testName"

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }
function Has-Value($key, $name) {
    if (-not (Test-Path -LiteralPath $key)) { return $false }
    $null -ne (Get-ItemProperty -LiteralPath $key -Name $name -ErrorAction SilentlyContinue)
}

try {
    Section "0. 造测试启动项"
    Set-ItemProperty -LiteralPath $runKey -Name $testName -Value $testCmd
    Check "测试项已写入 Run 键" (Has-Value $runKey $testName)

    Section "1. list 能否发现它"
    $json = & powershell -NoProfile -ExecutionPolicy Bypass -File $engine list -Json 2>&1 | Out-String
    $data = $json | ConvertFrom-Json
    $found = $data.items | Where-Object { $_.id -eq $testId }
    Check "list 发现测试项"     ($null -ne $found)
    Check "状态为 enabled"      ($found.state -eq 'enabled')

    Section "2. disable 禁用它"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $engine disable -Id $testId 2>&1 | Out-String | Write-Host
    Check "原位置已移除"        (-not (Has-Value $runKey $testName))
    Check "已移到 Disabled 备份键" (Has-Value $disabledKey $testName)
    # 值是否完整保留
    $bakVal = (Get-ItemProperty -LiteralPath $disabledKey -Name $testName -ErrorAction SilentlyContinue).$testName
    Check "禁用后命令值完整保留" ($bakVal -eq $testCmd)

    Section "3. list 应显示为已禁用"
    $json2 = & powershell -NoProfile -ExecutionPolicy Bypass -File $engine list -Json 2>&1 | Out-String
    $found2 = ($json2 | ConvertFrom-Json).items | Where-Object { $_.id -eq $testId }
    Check "list 显示 disabled"  ($found2.state -eq 'disabled')

    Section "4. enable 恢复它"
    & powershell -NoProfile -ExecutionPolicy Bypass -File $engine enable -Id $testId 2>&1 | Out-String | Write-Host
    Check "已移回原位置"        (Has-Value $runKey $testName)
    Check "Disabled 键中已移除" (-not (Has-Value $disabledKey $testName))
    $restored = (Get-ItemProperty -LiteralPath $runKey -Name $testName).$testName
    Check "恢复后命令值完整"    ($restored -eq $testCmd)
}
finally {
    Section "5. 清理测试项"
    Remove-ItemProperty -LiteralPath $runKey -Name $testName -ErrorAction SilentlyContinue
    Remove-ItemProperty -LiteralPath $disabledKey -Name $testName -ErrorAction SilentlyContinue
    # 若备份键空了就删掉
    if (Test-Path -LiteralPath $disabledKey) {
        $remain = (Get-ItemProperty -LiteralPath $disabledKey -ErrorAction SilentlyContinue).PSObject.Properties |
                  Where-Object { $_.Name -notlike 'PS*' }
        if (-not $remain) { Remove-Item -LiteralPath $disabledKey -Force -ErrorAction SilentlyContinue }
    }
    Write-Host "  测试项已清理"
}

Section "测试结果"
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
