# 跑所有 Open365 自测，汇总结果。
$ErrorActionPreference = 'Continue'
$tests = @('test-network.ps1', 'test-cleaner.ps1', 'test-startup.ps1')
$results = @()
foreach ($t in $tests) {
    $path = Join-Path $PSScriptRoot $t
    Write-Host "`n############### $t ###############" -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '$path'"
    $results += [pscustomobject]@{ test=$t; exit=$LASTEXITCODE }
}
Write-Host "`n############### 汇总 ###############" -ForegroundColor White
$allOk = $true
foreach ($r in $results) {
    $ok = $r.exit -eq 0
    if (-not $ok) { $allOk = $false }
    Write-Host ("  {0,-22} {1}" -f $r.test, $(if ($ok) { 'PASS' } else { 'FAIL' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
}
Write-Host ""
if ($allOk) { Write-Host "  全部通过 ✓" -ForegroundColor Green } else { Write-Host "  有失败项 ✗" -ForegroundColor Red; exit 1 }
