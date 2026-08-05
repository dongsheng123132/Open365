<#
.SYNOPSIS
    Open365 软件搬家引擎 (relocate engine)
    把微信 / QQ / 钉钉 / 企业微信 的数据目录从 C 盘搬到别的盘，原位留一个链接，可一键还原。

.DESCRIPTION
    list      只读探测本机常见软件的数据目录，报位置、大小与当前状态
    status    查看历史搬家记录，以及每条记录现在的链接是否还健康
    move      搬家：数据目录整体移动到目标盘，原位置建目录联接(junction)，软件无感
    restore   还原：拆掉联接，把数据整体搬回原位置（"可撤销"的撤销）

    原理与 WindowsCleaner 的「软件搬家」一致：
      * 数据不是"复制"，是【移动】到目标盘（robocopy /MOVE，可续传、保留时间戳）。
      * 原位置留一个 NTFS 目录联接（junction）——软件不知道搬家了，照常读写。
      * 目录联接不需要管理员权限（symlink 才需要），所以本引擎不要求提权。
      * 每次搬家都写记录（默认 %LOCALAPPDATA%\Open365\relocate\records\*.json），
        restore 按记录精确还原，不会搬错目录。

    安全：
      * 默认动作是只读的 list。
      * 搬家 / 还原前检查对应软件没有在运行（在跑就拒绝，绝不硬来）。
      * robocopy 先复制成功再删源；源没清干净就绝不建联接——
        不会出现"看着搬走了、其实数据还在 C 盘"的假搬家。
      * 目标盘不能和源目录同一个盘（搬了等于没搬）。
      * -Root / -RecordsDir 是测试与便携场景的覆盖开关；显式给 -Root 时不做跨盘校验。

.NOTES
    只动用户自己的数据目录，全程离线，不需要管理员。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'status', 'move', 'restore', 'help')]
    [string]$Action = 'help',

    [string]$App,                # move/restore 的应用 id：wechat / qq / dingtalk / wxwork
    [string]$Target,             # move 的目标盘基础目录，如 D:\Open365搬家
    [string]$Root,               # 数据根目录覆盖（默认真实 Documents；测试/便携用）
    [string]$RecordsDir,         # 记录目录覆盖（默认 %LOCALAPPDATA%\Open365\relocate\records；测试用）
    [switch]$Yes,                # 跳过交互确认
    [switch]$SkipRunningCheck,   # 跳过"软件在运行中"检查（测试/CI 用）
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# -Json 输出要能被 UTF-8 解析：脚本自己钉住输出编码，别依赖调用方的控制台代码页。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# ---------- 已知"数据大头"应用清单 ----------
# 每个条目：id / 显示名 / 相关进程（搬家前必须全部退出）/ 可能的数据目录（相对 Documents）
# 新应用往这里加一行即可，list / move / restore 全部自动生效。
$script:Apps = @(
    @{ id = 'wechat';   name = '微信';     processes = @('WeChat', 'Weixin');              dirs = @('WeChat Files', 'xwechat_files') }
    @{ id = 'qq';       name = 'QQ';       processes = @('QQ', 'QQExternal');             dirs = @('Tencent Files') }
    @{ id = 'dingtalk'; name = '钉钉';     processes = @('DingTalk', 'DingTalkApp');      dirs = @('DingTalk') }
    @{ id = 'wxwork';   name = '企业微信'; processes = @('WXWork');                       dirs = @('WXWork') }
)

# ---------- 小工具 ----------

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DocumentsRoot {
    if ($Root) { return $Root.TrimEnd('\') }
    $d = [Environment]::GetFolderPath('MyDocuments')
    if (-not $d) { $d = Join-Path $env:USERPROFILE 'Documents' }
    return $d
}

function Get-RecordsDir {
    if ($RecordsDir) { return $RecordsDir }
    return Join-Path $env:LOCALAPPDATA 'Open365\relocate\records'
}

function Format-Human([long]$bytes) {
    if ($bytes -lt 1KB) { return "$bytes B" }
    if ($bytes -lt 1MB) { return ('{0:N0} KB' -f ($bytes / 1KB)) }
    if ($bytes -lt 1GB) { return ('{0:N1} MB' -f ($bytes / 1MB)) }
    if ($bytes -lt 1TB) { return ('{0:N2} GB' -f ($bytes / 1GB)) }
    return ('{0:N2} TB' -f ($bytes / 1TB))
}

# 递归统计目录大小（碰到读不了的文件跳过，不因个别文件失败）
function Get-DirSize([string]$p) {
    $total = 0L
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($p, '*', [System.IO.SearchOption]::AllDirectories)) {
            try { $total += (Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length } catch { }
        }
    } catch { }
    return $total
}

function Test-Junction([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return $false }
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    return ($null -ne $i -and $i.LinkType -eq 'Junction')
}

function Get-JunctionTarget([string]$p) {
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $i -or $null -eq $i.Target) { return '' }
    return ([string[]]@($i.Target) -join ';')
}

# 目录状态：missing 不存在 / normal 正常目录 / moved 已搬家(链接健康) / moved-broken 链接断了
function Get-DirState([string]$p) {
    if (-not (Test-Path -LiteralPath $p)) { return 'missing' }
    $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
    if ($null -eq $i) { return 'missing' }
    if ($i.LinkType -eq 'Junction') {
        $t = Get-JunctionTarget $p
        if ($t -and (Test-Path -LiteralPath $t)) { return 'moved' }
        return 'moved-broken'
    }
    return 'normal'
}

function Get-AppById([string]$id) {
    $app = $script:Apps | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $app) {
        $known = ($script:Apps | ForEach-Object { $_.id }) -join ' / '
        throw "未知应用 id: $id（已知: $known）"
    }
    return $app
}

# 该应用目前在跑的相关进程（空数组 = 都退干净了）
function Find-RunningProcesses($app) {
    $found = @()
    foreach ($n in $app.processes) {
        if (Get-Process -Name $n -ErrorAction SilentlyContinue) { $found += $n }
    }
    return $found
}

# 源与目标是否同一个盘（"C:" vs "D:"）—— 搬去同一个盘等于没搬
function Test-SameDrive([string]$a, [string]$b) {
    $qa = Split-Path -Qualifier $a; $qb = Split-Path -Qualifier $b
    if (-not $qa -or -not $qb) { return $false }
    return ($qa.TrimEnd('\', ':') -eq $qb.TrimEnd('\', ':'))
}

function Assert-AppExited($app) {
    if ($SkipRunningCheck) { return }
    $running = @(Find-RunningProcesses $app)
    if ($running.Count -gt 0) {
        throw "请先完全退出「$($app.name)」（检测到进程: $($running -join ', ')）再操作。数据目录被占用时移动会损坏数据。"
    }
}

# ---------- list：只读探测 ----------

function Invoke-List {
    $root = Get-DocumentsRoot
    $items = @()
    foreach ($app in $script:Apps) {
        foreach ($rel in $app.dirs) {
            $p = Join-Path $root $rel
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $state = Get-DirState $p
            $size = $null
            $sizeHuman = ''
            $linkTarget = ''
            if ($state -eq 'normal') {
                $size = Get-DirSize $p
                $sizeHuman = Format-Human $size
            } elseif ($state -eq 'moved') {
                $linkTarget = Get-JunctionTarget $p
            } elseif ($state -eq 'moved-broken') {
                $linkTarget = Get-JunctionTarget $p
            }
            $items += [ordered]@{
                id          = $app.id
                name        = $app.name
                dir         = $p
                exists      = $true
                state       = $state
                size_bytes  = $size
                size_human  = $sizeHuman
                link_target = $linkTarget
            }
        }
    }
    return [ordered]@{ root = $root; checked_at = (Get-Date).ToString('s'); items = $items }
}

function Show-List($r) {
    Write-Host ""
    Write-Host "  ========== 软件搬家：可搬的数据目录 ==========" -ForegroundColor White
    Write-Host ("  数据根目录: {0}" -f $r.root) -ForegroundColor DarkGray
    Write-Host ""
    if ($r.items.Count -eq 0) { Write-Host "  (没找到常见软件的数据目录——它们可能本来就设置在别的盘)" -ForegroundColor DarkGray }
    foreach ($it in $r.items) {
        switch ($it.state) {
            'normal' {
                Write-Host ("  {0}  {1}  ({2})" -f $it.name, $it.dir, $it.size_human) -ForegroundColor White
                Write-Host ("       状态: 未搬家   搬家: open365 relocate move -App {0} -Target D:\你的数据盘" -f $it.id) -ForegroundColor Cyan
            }
            'moved' {
                Write-Host ("  {0}  {1}" -f $it.name, $it.dir) -ForegroundColor Green
                Write-Host ("       状态: 已搬到 {0}   还原: open365 relocate restore -App {1}" -f $it.link_target, $it.id) -ForegroundColor Cyan
            }
            'moved-broken' {
                Write-Host ("  {0}  {1}" -f $it.name, $it.dir) -ForegroundColor Red
                Write-Host ("       状态: 链接异常！目标 {0} 不存在，数据可能被手动移动过" -f $it.link_target) -ForegroundColor Red
            }
        }
        Write-Host ""
    }
    Write-Host "  搬家前请先退出对应软件。move/restore 加 -Json 输出结构化结果。" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------- move：搬家 ----------

function Invoke-MoveOne([string]$src, [string]$targetBase) {
    $leaf = Split-Path $src -Leaf
    $dst = Join-Path $targetBase $leaf

    if (Test-Path -LiteralPath $dst) {
        $child = Get-ChildItem -LiteralPath $dst -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($child) { throw "目标位置已存在且非空: $dst（换一个目标盘目录，或先手动处理它）" }
    }
    New-Item -ItemType Directory -Force -Path $targetBase | Out-Null

    # 先复制再删源：robocopy /MOVE 全部成功（退出码 < 8）才会动源目录
    & robocopy.exe $src $dst /E /MOVE /R:1 /W:1 /NFL /NDL /NP /NJH | Out-Null
    $rc = $LASTEXITCODE
    if ($rc -ge 8) { throw "数据复制失败（robocopy 退出码 $rc），源目录未动，可重试" }

    # /MOVE 成功后源目录应该已经没了；万一剩个空壳就清掉
    if (Test-Path -LiteralPath $src) {
        $left = @(Get-ChildItem -LiteralPath $src -Force -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0) {
            throw "搬家不完整：源目录还有 $($left.Count) 项没移走。已中止建立链接——绝不出现'看着搬走了、数据其实还在 C 盘'的假搬家。"
        }
        Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
    }

    # 原位置建目录联接（mklink /J 不需要管理员）
    & cmd.exe /c ('mklink /J "' + $src.Replace('"', '') + '" "' + $dst.Replace('"', '') + '"') 2>&1 | Out-Null
    if (-not (Test-Junction $src)) { throw "原位置建链接失败: $src（数据已在 $dst，可手动把目录移回）" }

    return [ordered]@{ source = $src; target = $dst }
}

function Write-Record($rec, [string]$fileName) {
    $dir = Get-RecordsDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $f = Join-Path $dir $fileName
    [System.IO.File]::WriteAllText($f, ($rec | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($true)))
    return $f
}

function Invoke-Move([string]$appId) {
    $app = Get-AppById $appId
    $root = Get-DocumentsRoot

    # 收集该应用在本机上实际存在的数据目录（可能多个，如微信新旧两代目录并存）
    $dirs = @()
    foreach ($rel in $app.dirs) {
        $p = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $st = Get-DirState $p
        if ($st -eq 'moved' -or $st -eq 'moved-broken') {
            throw "「$($app.name)」的 $rel 已经在搬家状态（想换个位置就先 restore 再搬）"
        }
        $dirs += $p
    }
    if ($dirs.Count -eq 0) { throw "没找到「$($app.name)」的数据目录（它可能本来就设置在别的盘/位置）" }

    if (-not $Target) { throw "请用 -Target 指定目标盘目录，如 -Target 'D:\Open365搬家'" }
    if (-not [System.IO.Path]::IsPathRooted($Target)) { throw "目标必须是绝对路径: $Target" }
    $targetBase = $Target.TrimEnd('\')

    # 生产路径（未显式 -Root）才做跨盘校验；-Root 是测试/便携覆盖，信任调用方
    if (-not $Root) {
        foreach ($src in $dirs) {
            if (Test-SameDrive $src $targetBase) {
                throw "目标 $targetBase 和源目录 $src 在同一个盘——搬了等于没搬。请选一个不同的盘。"
            }
        }
    }

    if (-not $Yes -and -not $Json) {
        Write-Host ""
        foreach ($src in $dirs) {
            $sz = Format-Human (Get-DirSize $src)
            Write-Host ("  搬家: {0}  ({1})" -f $src, $sz) -ForegroundColor Yellow
            Write-Host ("  到  : {0}" -f (Join-Path $targetBase (Split-Path $src -Leaf))) -ForegroundColor Yellow
        }
        Write-Host "  原理：数据整体移动，原位置留一个目录链接，软件无感知；可随时还原。" -ForegroundColor DarkGray
        $ans = Read-Host "  确认搬家？(yes/N)"
        if ($ans -ne 'yes') { Write-Host "  已取消"; return @{ ok = $false; cancelled = $true } }
    }

    Assert-AppExited $app

    $moved = @()
    foreach ($src in $dirs) {
        $moved += Invoke-MoveOne $src $targetBase
    }

    $records = @()
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $i = 1
    foreach ($m in $moved) {
        $rec = [ordered]@{
            id        = [guid]::NewGuid().ToString('N')
            app_id    = $app.id
            app_name  = $app.name
            source    = $m.source
            target    = $m.target
            moved_at  = (Get-Date).ToString('s')
            status    = 'active'
        }
        $records += Write-Record $rec ("{0}-{1}-{2}.json" -f $app.id, $stamp, $i)
        $i++
    }

    return [ordered]@{
        ok          = $true
        app_id      = $app.id
        app_name    = $app.name
        target_base = $targetBase
        moved       = $moved
        records     = $records
    }
}

function Show-Move($r) {
    Write-Host ""
    Write-Host ("  [OK] 「{0}」搬家完成：{1} 个目录已移到 {2}" -f $r.app_name, $r.moved.Count, $r.target_base) -ForegroundColor Green
    foreach ($m in $r.moved) {
        Write-Host ("      {0}  ->  {1}" -f $m.source, $m.target) -ForegroundColor DarkGray
    }
    Write-Host "  原位置已建目录链接，软件照常使用，无感知。" -ForegroundColor DarkGray
    Write-Host ("  还原: open365 relocate restore -App {0}" -f $r.app_id) -ForegroundColor Cyan
    Write-Host ""
}

# ---------- restore：还原 ----------

function Get-Records([string]$appId) {
    $dir = Get-RecordsDir
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $list = @()
    Get-ChildItem -LiteralPath $dir -Filter "$appId-*.json" -ErrorAction SilentlyContinue | ForEach-Object {
        try { $list += (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
    }
    return @($list | Sort-Object { $_.moved_at } -Descending)
}

function Find-RecordFile([string]$appId, [string]$recId) {
    $dir = Get-RecordsDir
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    foreach ($f in (Get-ChildItem -LiteralPath $dir -Filter "$appId-*.json" -ErrorAction SilentlyContinue)) {
        try {
            if ((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json).id -eq $recId) { return $f.FullName }
        } catch { }
    }
    return $null
}

function Invoke-Restore([string]$appId) {
    $app = Get-AppById $appId
    # 一次 move 可能写多条记录（如微信新旧两代目录并存），restore 必须全部还原，
    # 不能只挑一条——否则会出现"搬了两处、只还原一处"的半还原状态。
    $recs = @(Get-Records $appId | Where-Object { $_.status -eq 'active' })
    if ($recs.Count -eq 0) { throw "没有找到「$($app.name)」的搬家记录（没搬过，或已经还原过了）" }

    if (-not $Yes -and -not $Json) {
        Write-Host ""
        foreach ($rec in $recs) {
            Write-Host ("  还原: {0}  <-  {1}  (搬家时间 {2})" -f $rec.source, $rec.target, $rec.moved_at) -ForegroundColor Yellow
        }
        $ans = Read-Host "  确认把数据全部搬回原位置？(yes/N)"
        if ($ans -ne 'yes') { Write-Host "  已取消"; return @{ ok = $false; cancelled = $true } }
    }

    Assert-AppExited $app

    $restored = @()
    $recFile = $null
    foreach ($rec in $recs) {
        if (-not (Test-Junction $rec.source)) {
            throw "原始位置已不是链接: $($rec.source)（可能被手动处理过）。还原中止——请把 $($rec.target) 里的数据手动搬回 $($rec.source)。"
        }
        if (-not (Test-Path -LiteralPath $rec.target)) { throw "搬家后的数据目录不见了: $($rec.target)（无法还原）" }

        # 拆链接：rmdir 只删链接本身，绝不碰目标里的数据
        & cmd.exe /c ('rmdir "' + $rec.source.Replace('"', '') + '"') 2>&1 | Out-Null
        if (Test-Path -LiteralPath $rec.source) { throw "拆除链接失败: $($rec.source)" }

        & robocopy.exe $rec.target $rec.source /E /MOVE /R:1 /W:1 /NFL /NDL /NP /NJH | Out-Null
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { throw "数据搬回失败（robocopy 退出码 $rc）——数据仍在 $($rec.target)，可重试" }
        if (-not (Test-Path -LiteralPath $rec.source)) { throw "还原失败：数据没有回到 $($rec.source)" }

        # 记录标记为已还原（保留历史，不删除）
        $f = Find-RecordFile $appId $rec.id
        if ($f) {
            $rec | Add-Member -NotePropertyName status -NotePropertyValue 'restored' -Force
            $rec | Add-Member -NotePropertyName restored_at -NotePropertyValue (Get-Date).ToString('s') -Force
            [System.IO.File]::WriteAllText($f, ($rec | ConvertTo-Json -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($true)))
            $recFile = $f
        }
        $restored += [ordered]@{ source = $rec.source; target = $rec.target }
    }

    return [ordered]@{
        ok       = $true
        app_id   = $app.id
        app_name = $app.name
        restored = $restored
        record   = $recFile
    }
}

function Show-Restore($r) {
    Write-Host ""
    Write-Host ("  [OK] 「{0}」已还原：数据搬回原位置，链接已拆除。" -f $r.app_name) -ForegroundColor Green
    foreach ($m in $r.restored) {
        Write-Host ("      {0}  <-  {1}" -f $m.source, $m.target) -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ---------- status：搬家记录 ----------

function Invoke-Status {
    $rows = @()
    $dir = Get-RecordsDir
    if (Test-Path -LiteralPath $dir) {
        Get-ChildItem -LiteralPath $dir -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            try { $rows += (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { }
        }
    }
    $out = @()
    foreach ($r in $rows) {
        $state = 'restored'
        if ($r.status -eq 'active') {
            if (-not (Test-Junction $r.source)) { $state = 'broken' }
            elseif (-not (Test-Path -LiteralPath $r.target)) { $state = 'broken' }
            else { $state = 'moved' }
        }
        $out += [ordered]@{
            id        = $r.id
            app_id    = $r.app_id
            app_name  = $r.app_name
            source    = $r.source
            target    = $r.target
            moved_at  = $r.moved_at
            status    = $r.status
            state     = $state
        }
    }
    return [ordered]@{
        records_dir = $dir
        active      = @($out | Where-Object { $_.status -eq 'active' }).Count
        records     = $out
    }
}

function Show-Status($r) {
    Write-Host ""
    Write-Host "  ========== 软件搬家：历史记录 ==========" -ForegroundColor White
    Write-Host ("  记录位置: {0}" -f $r.records_dir) -ForegroundColor DarkGray
    Write-Host ""
    if ($r.records.Count -eq 0) { Write-Host "  (还没有搬家记录)" -ForegroundColor DarkGray }
    foreach ($rec in $r.records) {
        $tag = switch ($rec.state) {
            'moved'   { '[已搬家]' }
            'broken'  { '[链接异常]' }
            default   { '[已还原]' }
        }
        $col = switch ($rec.state) {
            'moved'   { 'Green' }
            'broken'  { 'Red' }
            default   { 'DarkGray' }
        }
        Write-Host ("  {0} {1}  {2} -> {3}" -f $tag, $rec.app_name, $rec.source, $rec.target) -ForegroundColor $col
        Write-Host ("        搬家时间: {0}" -f $rec.moved_at) -ForegroundColor DarkGray
        if ($rec.state -eq 'broken') {
            Write-Host "        链接或目标目录已不存在——数据可能被手动动过，请人工确认。" -ForegroundColor Red
        }
        Write-Host ""
    }
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'list' {
        $r = Invoke-List
        if ($Json) { $output = $r } else { Show-List $r }
    }
    'status' {
        $r = Invoke-Status
        if ($Json) { $output = $r } else { Show-Status $r }
    }
    'move' {
        $r = Invoke-Move $App
        if ($Json) { $output = $r } else { Show-Move $r }
    }
    'restore' {
        $r = Invoke-Restore $App
        if ($Json) { $output = $r } else { Show-Restore $r }
    }
    'help' {
        Write-Host @"
Open365 软件搬家引擎

用法: relocate.ps1 <action> [-App <id>] [-Target <目标盘目录>] [-Json] [-Yes]

  list                        只读列出常见软件的数据目录（位置 / 大小 / 是否已搬家）
  status                      查看搬家记录 + 每条记录现在的链接是否健康
  move  -App <id> -Target <目录>  搬家到别的盘（原位置留链接，软件无感，可还原）
  restore -App <id>           还原：数据搬回原位置，拆掉链接

应用 id: wechat(微信) / qq(QQ) / dingtalk(钉钉) / wxwork(企业微信)

示例:
  open365 relocate list                              # 先看有哪些能搬
  open365 relocate move -App wechat -Target D:\Open365搬家   # 微信搬去 D 盘
  open365 relocate restore -App wechat               # 撤销，搬回 C 盘
  open365 relocate status -Json                      # 结构化看记录

安全：
  * 数据是【移动】不是复制；原位置是 NTFS 目录联接(junction)，不需要管理员。
  * 搬家/还原前要求对应软件已完全退出（检测到进程会拒绝）。
  * robocopy 复制成功才会删源；源没清干净绝不建链接（防假搬家）。
  * 每次搬家写记录到 %LOCALAPPDATA%\Open365\relocate\records，按记录精确还原。
  * 目标盘不能和源目录同盘。全程离线。

测试/便携覆盖: -Root <数据根目录>  -RecordsDir <记录目录>  -SkipRunningCheck
加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
