<#
  Open365 软件搬家引擎自测
  策略：全程离线 —— 在临时目录造一个"假 Documents"（WeChat Files / xwechat_files /
        Tencent Files / DingTalk），用 -Root 指过去；-RecordsDir 指向另一个临时目录
        当"假记录库"；-Target 指向第三个临时目录当"假 D 盘"。

  覆盖（模拟故障 → 验证 → 自动还原）：
    1. list 只读探测：报位置 / 大小 / 状态
    2. 只读性：list 不写记录库、不碰数据
    3. move 双目录应用（微信新旧两代目录并存）：数据真的到了目标盘、
       原位成了目录联接(junction)、写了记录
    4. list 再查：状态变为已搬家
    5. status：记录健康
    6. 重复 move 被拒（已在搬家状态）
    7. restore：数据搬回、链接拆除、记录标记已还原
    8. 重复 restore 被拒（没有搬家记录）
    9. 未知应用 id / 缺 -Target 的用法错误
    10. 输出契约字段

  说明：-Root 是测试/便携覆盖开关（显式给 -Root 时引擎不做跨盘校验），
        生产路径的"同盘拒绝"校验因此无法在这里构造，属有意为之。
#>
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$engine = Join-Path $PSScriptRoot '..\engine\relocate.ps1'

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }

# 子进程跑引擎，stdout+stderr 一起抓（成功时 text 就是单行 JSON；失败时是错误信息）
# 注意：参数名不能用 $args（那是自动变量，会拿不到值），用 $argv
# 注意：'-Json' 这类加引号会被当成位置字符串而不是开关（PS 5.1 老坑），
#       所以参数名/开关裸写，只有参数值用单引号包。
function Run-Engine([string[]]$argv) {
    $inner = '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & ' + "'" + $engine.Replace("'", "''") + "'"
    foreach ($a in $argv) {
        if ($a -match '^-') { $inner += ' ' + $a }
        else                { $inner += ' ' + "'" + $a.Replace("'", "''") + "'" }
    }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'   # 引擎拒绝时会往 stderr 写原因，2>&1 会转成 ErrorRecord；
                                          # 保持 Stop 的话会被当成终止错误直接打断测试
    try {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $inner 2>&1
    } finally {
        $ErrorActionPreference = $prev
    }
    return @{ text = (($out | Out-String).Trim()); code = $LASTEXITCODE }
}

function Test-IsJunction([string]$p) {
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    return ($null -ne $i -and $i.LinkType -eq 'Junction')
}

function New-File([string]$p, [int]$bytes) {
    $d = Split-Path $p -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllBytes($p, (New-Object byte[] $bytes))
}

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("open365-relocate-test-" + [Guid]::NewGuid().ToString('N'))
$fakeDocs   = Join-Path $tmp 'docs'      # 假 Documents
$fakeTarget = Join-Path $tmp 'data'      # 假"别的盘"
$fakeRecords = Join-Path $tmp 'records'  # 假记录库（初始不存在，用来验证只读性）

# 假数据：
#   微信：WeChat Files(3000 B) + xwechat_files(500 B) —— 双目录应用
#   QQ：  Tencent Files(4000 B)
#   钉钉：DingTalk(700 B)
New-File (Join-Path $fakeDocs 'WeChat Files\a.txt') 1000
New-File (Join-Path $fakeDocs 'WeChat Files\sub\b.txt') 2000
New-File (Join-Path $fakeDocs 'xwechat_files\c.txt') 500
New-File (Join-Path $fakeDocs 'Tencent Files\q.bin') 4000
New-File (Join-Path $fakeDocs 'DingTalk\d.log') 700

try {
    Section "1. list 只读探测（-Root 指向假 Documents）"
    $r = Run-Engine @('list', '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "list 退出码 0"                    ($r.code -eq 0)
    Check "list 输出可解析 JSON"             ($null -ne $d)
    Check "找到 4 个数据目录"                ($d.items.Count -eq 4)
    $wc = @($d.items | Where-Object { $_.id -eq 'wechat' })
    Check "微信两个目录都识别"               ($wc.Count -eq 2)
    Check "微信 WeChat Files 大小 3000B"     (@($wc | Where-Object { $_.dir -like '*WeChat Files' } | Select-Object -First 1).size_bytes -eq 3000)
    Check "微信 xwechat_files 大小 500B"     (@($wc | Where-Object { $_.dir -like '*xwechat_files' } | Select-Object -First 1).size_bytes -eq 500)
    Check "QQ 大小 4000B"                    (@($d.items | Where-Object { $_.id -eq 'qq' } | Select-Object -First 1).size_bytes -eq 4000)
    Check "所有目录 state=normal"            (@($d.items | Where-Object { $_.state -ne 'normal' }).Count -eq 0)
    Check "root 透传为假 Documents"          ($d.root -eq $fakeDocs)

    Section "2. 只读性：list 不写记录库、不碰数据"
    Check "records 目录没有被创建"           (-not (Test-Path -LiteralPath $fakeRecords))
    Check "数据文件还在"                     (Test-Path -LiteralPath (Join-Path $fakeDocs 'WeChat Files\a.txt'))

    Section "3. move：微信双目录搬家到假 D 盘"
    $r = Run-Engine @('move', '-App', 'wechat', '-Target', $fakeTarget, '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Yes', '-SkipRunningCheck', '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "move 退出码 0"                    ($r.code -eq 0)
    Check "move ok=true"                     ($d.ok -eq $true)
    Check "move 搬了 2 个目录"               ($d.moved.Count -eq 2)
    Check "数据真的到了目标盘"               ((Test-Path -LiteralPath (Join-Path $fakeTarget 'WeChat Files\sub\b.txt')) -and (Test-Path -LiteralPath (Join-Path $fakeTarget 'xwechat_files\c.txt')))
    Check "原位成了目录联接(junction)"       ((Test-IsJunction (Join-Path $fakeDocs 'WeChat Files')) -and (Test-IsJunction (Join-Path $fakeDocs 'xwechat_files')))
    Check "写了两条记录"                     (@(Get-ChildItem -LiteralPath $fakeRecords -Filter 'wechat-*.json').Count -eq 2)

    Section "4. list 再查：微信变成已搬家"
    $r = Run-Engine @('list', '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Json')
    $d = $r.text | ConvertFrom-Json
    $wc = @($d.items | Where-Object { $_.id -eq 'wechat' })
    Check "微信两个目录 state=moved"         (@($wc | Where-Object { $_.state -ne 'moved' }).Count -eq 0)
    Check "link_target 指向假 D 盘"          (@($wc | Where-Object { $_.link_target -notlike "$fakeTarget*" }).Count -eq 0)
    Check "搬家的目录不再统计大小"           (@($wc | Where-Object { $_.size_human -ne '' }).Count -eq 0)

    Section "5. status：记录健康"
    $r = Run-Engine @('status', '-RecordsDir', $fakeRecords, '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "status 退出码 0"                  ($r.code -eq 0)
    Check "active 记录 = 2"                  ($d.active -eq 2)
    Check "记录 state=moved（链接健康）"     (@($d.records | Where-Object { $_.state -ne 'moved' }).Count -eq 0)

    Section "6. 重复 move 被拒（已在搬家状态）"
    $r = Run-Engine @('move', '-App', 'wechat', '-Target', $fakeTarget, '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Yes', '-SkipRunningCheck', '-Json')
    Check "退出码非 0"                       ($r.code -ne 0)
    Check "报'已经在搬家状态'"               ($r.text -match '搬家状态')

    Section "7. restore：微信还原回假 Documents"
    $r = Run-Engine @('restore', '-App', 'wechat', '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Yes', '-SkipRunningCheck', '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "restore 退出码 0"                 ($r.code -eq 0)
    Check "restore ok=true"                  ($d.ok -eq $true)
    Check "链接已拆除（不再是 junction）"    (-not (Test-IsJunction (Join-Path $fakeDocs 'WeChat Files')))
    Check "数据回到原位"                     ((Test-Path -LiteralPath (Join-Path $fakeDocs 'WeChat Files\sub\b.txt')) -and (Test-Path -LiteralPath (Join-Path $fakeDocs 'xwechat_files\c.txt')))
    Check "记录标记为已还原"                 (@(Get-ChildItem -LiteralPath $fakeRecords -Filter 'wechat-*.json' | ForEach-Object { (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).status } | Where-Object { $_ -ne 'restored' }).Count -eq 0)

    Section "8. 重复 restore 被拒（没有搬家记录）"
    $r = Run-Engine @('restore', '-App', 'wechat', '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Yes', '-SkipRunningCheck', '-Json')
    Check "退出码非 0"                       ($r.code -ne 0)
    Check "报'没有找到搬家记录'"             ($r.text -match '没有找到')

    Section "9. 单目录应用全流程：QQ 搬家 -> status -> 还原"
    $r = Run-Engine @('move', '-App', 'qq', '-Target', $fakeTarget, '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Yes', '-SkipRunningCheck', '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "QQ move ok"                       ($r.code -eq 0 -and $d.ok -eq $true)
    Check "QQ 数据到目标盘"                  (Test-Path -LiteralPath (Join-Path $fakeTarget 'Tencent Files\q.bin'))
    Check "QQ 原位是联接"                    (Test-IsJunction (Join-Path $fakeDocs 'Tencent Files'))
    $r = Run-Engine @('status', '-RecordsDir', $fakeRecords, '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "status active=1（微信已还原、QQ 还搬着）" ($d.active -eq 1)
    $r = Run-Engine @('restore', '-App', 'qq', '-Root', $fakeDocs, '-RecordsDir', $fakeRecords, '-Yes', '-SkipRunningCheck', '-Json')
    $d = $r.text | ConvertFrom-Json
    Check "QQ restore ok"                    ($r.code -eq 0 -and $d.ok -eq $true)
    Check "QQ 数据回原位"                    (Test-Path -LiteralPath (Join-Path $fakeDocs 'Tencent Files\q.bin'))
    Check "QQ 不再有 active 记录"            (((Run-Engine @('status', '-RecordsDir', $fakeRecords, '-Json')).text | ConvertFrom-Json).active -eq 0)

    Section "10. 用法错误被拦"
    $r = Run-Engine @('move', '-App', 'nope', '-Target', $fakeTarget, '-Root', $fakeDocs, '-Json')
    Check "未知应用 id 报错"                 ($r.code -ne 0 -and $r.text -match '未知应用')
    $r = Run-Engine @('move', '-App', 'qq', '-Root', $fakeDocs, '-Json')
    Check "缺 -Target 报错"                  ($r.code -ne 0 -and $r.text -match '-Target')

    Section "11. 输出契约字段"
    $r = Run-Engine @('list', '-Root', $fakeDocs, '-Json')
    $d = $r.text | ConvertFrom-Json
    $names = $d.PSObject.Properties.Name
    foreach ($f in @('root', 'checked_at', 'items')) { Check "list 含字段 $f" ($names -contains $f) }
    $r = Run-Engine @('status', '-RecordsDir', $fakeRecords, '-Json')
    $d = $r.text | ConvertFrom-Json
    foreach ($f in @('records_dir', 'active', 'records')) { Check "status 含字段 $f" ($d.PSObject.Properties.Name -contains $f) }
}
finally {
    Section "12. 清理临时目录"
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  清理完成"
}

Section "测试结果"
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
