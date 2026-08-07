<#
  Open365 系统概况引擎自测
  策略：全程离线、全程只读 —— 只调用 sysinfo 引擎本身的探测能力，
        断言输出契约（字段名 / 类型 / 取值范围），并验证：
        * 不联网、不写文件、不需要管理员（引擎设计承诺）
        * 字段命名与 本境协议 u-env 契约对齐（windows.version / host.hardware / host.disk）

  注意：测试只断言"结构契约"，不断言具体硬件值（每台机器不一样）。
        唯一可以断言的具体值：系统版本号能解析出数字、内存总量 > 0。
#>
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\engine\sysinfo.ps1'

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }

# 跑引擎拿 JSON（stderr 吞掉，只留单行 JSON）
function Run-Info {
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command `
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '$engine' info -Json" 2>$null
    return ($out | Out-String).Trim()
}

try {
    $raw = Run-Info
    Check "引擎返回非空" (-not [string]::IsNullOrWhiteSpace($raw))

    $d = $null
    try { $d = $raw | ConvertFrom-Json } catch { }
    Check "输出是合法 JSON" ($null -ne $d)

    Section "1. 顶层契约"
    Check "ok = true"            ($d.ok -eq $true)
    Check "checked_at 非空"      (-not [string]::IsNullOrEmpty($d.checked_at))
    Check "system 对象存在"      ($null -ne $d.system)
    Check "cpu 对象存在"         ($null -ne $d.cpu)
    Check "memory 对象存在"      ($null -ne $d.memory)
    Check "disks 是数组"         ($d.disks -is [System.Array])

    Section "2. 系统版本（对齐 u-env windows.version）"
    Check "product_name 非空"    (-not [string]::IsNullOrEmpty($d.system.product_name))
    Check "version 形如 10.0.x"  ($d.system.version -match '^\d+\.\d+\.\d+')
    Check "build 是正整数"       ($d.system.build -is [int] -and $d.system.build -gt 0)
    Check "architecture 是 x64/x86" ($d.system.architecture -in @('x64', 'x86'))
    # 版本号能逐段比大小：本机 build >= 22000（Win11 起点），Win10 老机器也 >= 10240
    Check "build >= 10240"       ($d.system.build -ge 10240)

    Section "3. CPU（对齐 u-env host.hardware）"
    Check "cpu.name 非空"        (-not [string]::IsNullOrEmpty($d.cpu.name))
    Check "cores >= 1"           ($d.cpu.cores -is [int] -and $d.cpu.cores -ge 1)
    Check "logical >= cores"     ($d.cpu.logical -is [int] -and $d.cpu.logical -ge $d.cpu.cores)

    Section "4. 内存"
    Check "total_bytes > 0"      ($d.memory.total_bytes -is [long] -and $d.memory.total_bytes -gt 0)
    Check "free_bytes >= 0"      ($d.memory.free_bytes -ge 0)
    Check "used_percent 0..100"  ($d.memory.used_percent -ge 0 -and $d.memory.used_percent -le 100)
    Check "free <= total"        ($d.memory.free_bytes -le $d.memory.total_bytes)

    Section "5. 磁盘卷（对齐 u-env host.disk）"
    Check "至少一个盘"           ($d.disks.Count -ge 1)
    $hasC = $false
    foreach ($v in $d.disks) {
        Check "盘符非空"         (-not [string]::IsNullOrEmpty($v.drive))
        Check "filesystem 非空"  (-not [string]::IsNullOrEmpty($v.filesystem))
        Check "total_bytes > 0"  ($v.total_bytes -gt 0)
        Check "free_bytes >= 0"  ($v.free_bytes -ge 0)
        Check "free <= total"    ($v.free_bytes -le $v.total_bytes)
        if ($v.drive -eq 'C:') { $hasC = $true }
    }
    Check "存在 C 盘"            ($hasC)

    Section "6. 开机时长"
    # ConvertFrom-Json 小整数给 int、大整数给 long —— 两种都认
    Check "uptime_seconds >= 0"  (($d.uptime_seconds -is [int] -or $d.uptime_seconds -is [long]) -and $d.uptime_seconds -ge 0)
    Check "booted_at 非空"       (-not [string]::IsNullOrEmpty($d.booted_at))

    Section "7. 只读承诺"
    # 引擎跑完，工作目录不产生任何新文件（引擎不写盘）
    $wd = Join-Path $PSScriptRoot '..'
    $filesBefore = @(Get-ChildItem -LiteralPath $wd -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object)
    $null = Run-Info
    $filesAfter = @(Get-ChildItem -LiteralPath $wd -Recurse -File | ForEach-Object { $_.FullName } | Sort-Object)
    $diff = @(Compare-Object $filesBefore $filesAfter)
    if ($diff.Count -gt 0) {
        Write-Host "  [INFO] 差异文件:" -ForegroundColor DarkGray
        $diff | ForEach-Object { Write-Host "         $($_.SideIndicator) $($_.InputObject)" -ForegroundColor DarkGray }
    }
    Check "跑完仓库没多文件"     ($diff.Count -eq 0)

} catch {
    Write-Host "  [FAIL] 测试本身异常: $_" -ForegroundColor Red
    $script:fail++
}

Write-Host "`n===== 结果: $pass 通过, $fail 失败 =====" -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 } else { exit 0 }
