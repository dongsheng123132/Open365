<#
  Open365 垃圾清理引擎自测
  策略：在隔离的临时目录造一批假垃圾 -> 用 cleaner 的内部函数清 -> 验证删净+算对。
  全程只碰自建的 sandbox 目录，绝不碰真实的回收站/浏览器缓存/系统临时文件。
#>
$ErrorActionPreference = 'Stop'

# 引入 cleaner 引擎里的函数（dot-source），但不触发它的入口分发
# —— 用 -Action help 之外的方式：直接读函数定义。这里改为单独定义被测函数的轻量副本不可取，
#    所以我们 dot-source 整个脚本但传 help，让它只打印帮助、不执行清理。
$cleaner = Join-Path $PSScriptRoot '..\engine\cleaner.ps1'

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }

# --- 造 sandbox ---
Section "0. 建隔离沙盒 + 造假垃圾"
$sandbox = Join-Path $env:TEMP ("open365-clean-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $sandbox -Force | Out-Null
# 造 5 个文件，每个 1MB，加一个子目录
$expectedBytes = 0
1..5 | ForEach-Object {
    $f = Join-Path $sandbox "junk$_.tmp"
    $bytes = New-Object byte[] (1MB)
    [System.IO.File]::WriteAllBytes($f, $bytes)
    $expectedBytes += 1MB
}
$sub = Join-Path $sandbox 'subdir'
New-Item -ItemType Directory -Path $sub -Force | Out-Null
$f6 = Join-Path $sub 'nested.tmp'
[System.IO.File]::WriteAllBytes($f6, (New-Object byte[] (512KB)))
$expectedBytes += 512KB
Write-Host "  沙盒: $sandbox"
Write-Host "  造了 5×1MB + 1×512KB = 预期 $([math]::Round($expectedBytes/1MB,2)) MB"

try {
    # --- dot-source cleaner 的函数（用 help 入口，避免执行清理） ---
    Section "1. 加载 cleaner 引擎函数"
    # 通过给参数 help，脚本走 help 分支，但函数都已定义到当前作用域
    . $cleaner help | Out-Null
    Check "Get-DirSize 函数已加载" (Get-Command Get-DirSize -ErrorAction SilentlyContinue)
    Check "Clear-Dir 函数已加载"   (Get-Command Clear-Dir -ErrorAction SilentlyContinue)

    # --- 测体积计算 ---
    Section "2. 验证体积扫描算得准"
    $size = Get-DirSize $sandbox $null
    Write-Host "  扫描结果: $($size.files) 个文件, $([math]::Round($size.bytes/1MB,2)) MB"
    Check "文件数正确 (应=6)"      ($size.files -eq 6)
    Check "字节数正确"             ($size.bytes -eq $expectedBytes)

    # --- 测清理 ---
    Section "3. 执行 Clear-Dir 清理沙盒"
    $freed = Clear-Dir $sandbox $null
    Write-Host "  报告释放: $([math]::Round($freed/1MB,2)) MB"
    Check "释放量正确"             ($freed -eq $expectedBytes)

    # --- 验证真的删干净 ---
    Section "4. 验证沙盒已清空"
    $remain = Get-ChildItem -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Check "沙盒内文件已全部删除"   ($null -eq $remain -or $remain.Count -eq 0)
    Check "沙盒目录本身保留"       (Test-Path -LiteralPath $sandbox)

    # --- 测 filter 过滤 ---
    Section "5. 验证 filter 只删匹配的文件"
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'a.log'), (New-Object byte[] (1KB)))
    [System.IO.File]::WriteAllBytes((Join-Path $sandbox 'b.txt'), (New-Object byte[] (1KB)))
    $freedLog = Clear-Dir $sandbox '*.log'
    Check "只删了 .log (释放=1KB)" ($freedLog -eq 1KB)
    Check ".txt 被保留"            (Test-Path -LiteralPath (Join-Path $sandbox 'b.txt'))
}
finally {
    Section "6. 清理沙盒"
    Remove-Item -LiteralPath $sandbox -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  沙盒已删除"
}

Section "测试结果"
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
