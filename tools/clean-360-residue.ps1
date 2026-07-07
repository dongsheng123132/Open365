<#
  一次性清理 360 残留（目录 + 注册表），删前先导出注册表备份。
  只针对 360 命名空间，逐项记日志。
#>
$ErrorActionPreference = 'Continue'
$stamp   = '20260619'
$backup  = "C:\Users\ZhuanZ\Desktop\Open365\360-backup-$stamp"
$log     = "C:\Users\ZhuanZ\Desktop\Open365\.tmp-clean-360.log"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
"=== 360 残留清理 $stamp ===" | Set-Content -Path $log -Encoding UTF8

function Log($m) { $m | Add-Content -Path $log -Encoding UTF8 }

# ---- 收集残留目录 ----
$dirRoots = @($env:ProgramFiles, "${env:ProgramFiles(x86)}", $env:LOCALAPPDATA, $env:APPDATA, $env:ProgramData) |
    Where-Object { $_ -and (Test-Path $_) }
$dirs = @()
foreach ($r in $dirRoots) {
    Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*360*' } | ForEach-Object { $dirs += $_.FullName }
}

# ---- 收集残留注册表项 ----
$regRoots = @('HKLM:\SOFTWARE', 'HKLM:\SOFTWARE\WOW6432Node', 'HKCU:\SOFTWARE')
$regs = @()
foreach ($rr in $regRoots) {
    Get-ChildItem -Path $rr -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '*360*' } | ForEach-Object { $regs += $_.Name }
}

Log ""
Log "[备份注册表] -> $backup"
$i = 0
foreach ($k in $regs) {
    $i++
    $safe = ($k -replace '[\\:]', '_')
    $file = Join-Path $backup ("{0:D2}_{1}.reg" -f $i, $safe)
    & reg.exe export "$k" "$file" /y 2>&1 | Out-Null
    if (Test-Path $file) { Log "  备份OK: $k" } else { Log "  备份失败: $k" }
}

Log ""
Log "[删除注册表项]"
foreach ($k in $regs) {
    $ps = $k -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:' -replace '^HKEY_CLASSES_ROOT', 'HKCR:'
    try { Remove-Item -Path $ps -Recurse -Force -ErrorAction Stop; Log "  已删: $k" }
    catch { Log "  删除失败: $k -> $($_.Exception.Message)" }
}

Log ""
Log "[删除残留目录]"
foreach ($d in $dirs) {
    try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction Stop; Log "  已删: $d" }
    catch { Log "  删除失败(可能占用): $d -> $($_.Exception.Message)" }
}

Log ""
Log "=== 完成 ==="
