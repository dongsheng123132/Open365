<#
.SYNOPSIS
    Open365 垃圾清理引擎 (cleaner engine)
    开源的"电脑清理 / 垃圾清理"工具。

.DESCRIPTION
    扫描并清理：系统/用户临时文件、各浏览器缓存、回收站、缩略图缓存、
    Windows Update 下载残留、各种日志。

    安全第一：
      - scan 只读，先算出每类能释放多少空间，绝不静默删。
      - clean 默认对每一类逐项确认（除非 -Force）。
      - 规则白名单驱动，只碰公认安全的缓存/临时目录，不碰文档/桌面/下载。

.NOTES
    规则参考开源 BleachBit。设计为 CLI 即本地 API，-Json 输出结构化结果。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('scan', 'clean', 'help')]
    [string]$Action = 'help',

    [switch]$Json,
    [switch]$Force,                 # 跳过逐项确认
    [string[]]$Only                 # 只处理指定类别 key，如 -Only temp,recyclebin
)

$ErrorActionPreference = 'Stop'

# ---------- 清理规则表（白名单驱动，新增一类只要在这里加一行） ----------
# kind=dir   : 清空目录下的内容（保留目录本身）
# kind=recyclebin : 特殊处理回收站
# kind=cmd   : 执行命令式清理

function Get-CleanRules {
    $local = $env:LOCALAPPDATA
    $roam  = $env:APPDATA
    $rules = @(
        @{ key='win-temp';     name='Windows 临时文件';        kind='dir'; path="$env:WINDIR\Temp" }
        @{ key='user-temp';    name='用户临时文件';            kind='dir'; path=$env:TEMP }
        @{ key='prefetch';     name='预读取文件 (Prefetch)';   kind='dir'; path="$env:WINDIR\Prefetch" }
        @{ key='thumbs';       name='缩略图缓存';              kind='dir'; path="$local\Microsoft\Windows\Explorer"; filter='thumbcache_*.db' }
        @{ key='win-update';   name='Windows Update 下载残留'; kind='dir'; path="$env:WINDIR\SoftwareDistribution\Download" }
        @{ key='cbs-logs';     name='系统组件日志 (CBS)';      kind='dir'; path="$env:WINDIR\Logs\CBS"; filter='*.log' }
        # 以下都是公认可清的缓存/报告（系统会按需重建，不碰任何用户数据）
        @{ key='inetcache';    name='网络临时文件缓存';        kind='dir'; path="$local\Microsoft\Windows\INetCache" }
        @{ key='crashdumps';   name='程序崩溃转储';            kind='dir'; path="$local\CrashDumps" }
        @{ key='wer';          name='Windows 错误报告';        kind='dir'; path="$local\Microsoft\Windows\WER" }
        @{ key='d3dcache';     name='DirectX 着色器缓存';      kind='dir'; path="$local\D3DSCache" }
        # 浏览器缓存
        @{ key='edge-cache';   name='Edge 浏览器缓存';         kind='dir'; path="$local\Microsoft\Edge\User Data\Default\Cache" }
        @{ key='chrome-cache'; name='Chrome 浏览器缓存';       kind='dir'; path="$local\Google\Chrome\User Data\Default\Cache" }
        # firefox: 只清各 profile 下的缓存子目录，绝不整目录删（否则会连书签/密码/历史一起删）
        @{ key='firefox-cache';name='Firefox 浏览器缓存';      kind='firefox'; path="$local\Mozilla\Firefox\Profiles" }
        # 回收站
        @{ key='recyclebin';   name='回收站';                  kind='recyclebin' }
    )
    return $rules
}

# ---------- 体积计算 ----------

function Get-DirSize([string]$path, [string]$filter) {
    if (-not (Test-Path -LiteralPath $path)) { return @{ bytes=0; files=0; exists=$false } }
    $bytes = 0; $files = 0
    try {
        $items = if ($filter) {
            Get-ChildItem -LiteralPath $path -Filter $filter -Recurse -Force -File -ErrorAction SilentlyContinue
        } else {
            Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue
        }
        foreach ($f in $items) { $bytes += $f.Length; $files++ }
    } catch {}
    return @{ bytes=$bytes; files=$files; exists=$true }
}

function Get-RecycleBinSize {
    $bytes = 0; $files = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(10)   # 10 = Recycle Bin
        foreach ($item in $bin.Items()) {
            $bytes += $item.Size
            $files++
        }
    } catch {}
    return @{ bytes=$bytes; files=$files; exists=$true }
}

# ---------- Firefox 缓存（只碰缓存子目录，绝不碰 profile 本体） ----------
# Firefox 把缓存放在  Profiles\<随机>.default*\cache2 (以及 startupCache / OfflineCache)。
# 书签/密码/历史/偏好 (places.sqlite / logins.json / prefs.js) 就在 profile 根目录，
# 所以【只能】清 profile 下的这几个缓存子目录，绝不能整个 Profiles 目录删。
function Get-FirefoxCacheDirs([string]$base) {
    $dirs = @()
    if (-not (Test-Path -LiteralPath $base)) { return $dirs }
    Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        foreach ($sub in @('cache2', 'startupCache', 'OfflineCache')) {
            $p = Join-Path $_.FullName $sub
            if (Test-Path -LiteralPath $p) { $dirs += $p }
        }
    }
    return $dirs
}

function Get-FirefoxCacheSize([string]$base) {
    $bytes = 0; $files = 0
    foreach ($d in (Get-FirefoxCacheDirs $base)) {
        $s = Get-DirSize $d $null
        $bytes += $s.bytes; $files += $s.files
    }
    return @{ bytes=$bytes; files=$files; exists=$true }
}

function Clear-FirefoxCache([string]$base) {
    $freed = 0
    foreach ($d in (Get-FirefoxCacheDirs $base)) {
        $freed += (Clear-Dir $d $null)
    }
    return $freed
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return "{0:N2} GB" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:N2} MB" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:N2} KB" -f ($bytes / 1KB) }
    return "$bytes B"
}

# ---------- 扫描（只读） ----------

function Invoke-Scan {
    $rules = Get-CleanRules
    if ($Only) { $rules = $rules | Where-Object { $Only -contains $_.key } }
    $report = @()
    $total = 0
    foreach ($r in $rules) {
        $size = switch ($r.kind) {
            'recyclebin' { Get-RecycleBinSize }
            'firefox'    { Get-FirefoxCacheSize $r.path }
            default      { Get-DirSize $r.path $r.filter }
        }
        $report += [ordered]@{
            key   = $r.key
            name  = $r.name
            path  = $r.path
            bytes = $size.bytes
            files = $size.files
            human = (Format-Size $size.bytes)
        }
        $total += $size.bytes
    }
    return [ordered]@{
        items        = $report
        total_bytes  = $total
        total_human  = (Format-Size $total)
    }
}

function Show-Scan($s) {
    Write-Host ""
    Write-Host "  ========== 垃圾扫描结果 ==========" -ForegroundColor White
    Write-Host ""
    Write-Host ("  {0,-26} {1,12} {2,8}" -f '类别', '可释放', '文件数')
    Write-Host "  ---------------------------------------------------"
    foreach ($i in $s.items) {
        $color = if ($i.bytes -gt 0) { 'Gray' } else { 'DarkGray' }
        Write-Host ("  {0,-24} {1,12} {2,8}" -f $i.name, $i.human, $i.files) -ForegroundColor $color
    }
    Write-Host "  ---------------------------------------------------"
    Write-Host ("  {0,-24} {1,12}" -f '合计可释放', $s.total_human) -ForegroundColor Green
    Write-Host ""
    Write-Host "  执行清理: open365 clean        （会逐项确认）" -ForegroundColor Cyan
    Write-Host "  直接清理: open365 clean -Force  （不确认，谨慎）" -ForegroundColor DarkGray
    Write-Host ""
}

# ---------- 清理 ----------

function Clear-Dir([string]$path, [string]$filter) {
    if (-not (Test-Path -LiteralPath $path)) { return 0 }
    $freed = 0
    $items = if ($filter) {
        Get-ChildItem -LiteralPath $path -Filter $filter -Force -ErrorAction SilentlyContinue
    } else {
        Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
    foreach ($it in $items) {
        try {
            $sz = if ($it.PSIsContainer) { (Get-DirSize $it.FullName $null).bytes } else { $it.Length }
            Remove-Item -LiteralPath $it.FullName -Recurse -Force -ErrorAction Stop
            $freed += $sz
        } catch {
            # 正在被占用的文件跳过，这是正常的（不报错刷屏）
        }
    }
    return $freed
}

function Clear-RecycleBin2 {
    $before = (Get-RecycleBinSize).bytes
    try { Clear-RecycleBin -Force -ErrorAction Stop } catch {}
    return $before
}

function Invoke-Clean {
    $scan = Invoke-Scan
    if (-not $Json) {
        Write-Host ""
        Write-Host "  ========== 开始清理 ==========" -ForegroundColor White
        Write-Host ""
    }
    $rules = Get-CleanRules
    if ($Only) { $rules = $rules | Where-Object { $Only -contains $_.key } }

    $totalFreed = 0
    $cleaned = @()
    foreach ($r in $rules) {
        $info = $scan.items | Where-Object { $_.key -eq $r.key }
        if (-not $info -or $info.bytes -eq 0) { continue }

        if (-not $Force -and -not $Json) {
            $ans = Read-Host "  清理 [$($r.name)] 可释放 $($info.human)？(Y/n)"
            if ($ans -and $ans -notmatch '^[Yy]') {
                Write-Host "    已跳过" -ForegroundColor DarkGray
                continue
            }
        }

        $freed = switch ($r.kind) {
            'recyclebin' { Clear-RecycleBin2 }
            'firefox'    { Clear-FirefoxCache $r.path }
            default      { Clear-Dir $r.path $r.filter }
        }
        $totalFreed += $freed
        $cleaned += [ordered]@{ key=$r.key; name=$r.name; freed_bytes=$freed; freed_human=(Format-Size $freed) }
        if (-not $Json) { Write-Host "    [OK] $($r.name) 已清理 $(Format-Size $freed)" -ForegroundColor Green }
    }

    if (-not $Json) {
        Write-Host ""
        Write-Host "  共释放: $(Format-Size $totalFreed)" -ForegroundColor Green
        Write-Host ""
    }
    return [ordered]@{ cleaned=$cleaned; total_freed_bytes=$totalFreed; total_freed_human=(Format-Size $totalFreed) }
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'scan'  { $s = Invoke-Scan;  if ($Json) { $output = $s } else { Show-Scan $s } }
    'clean' { $c = Invoke-Clean; if ($Json) { $output = $c } }
    'help'  {
        Write-Host @"
Open365 垃圾清理引擎

用法: cleaner.ps1 <action> [-Json] [-Force] [-Only key1,key2]

  scan    扫描可清理的垃圾（只读，给出每类可释放空间）
  clean   清理（默认逐项确认；-Force 不确认）

  -Only   只处理指定类别，如 -Only win-temp,recyclebin

类别 key: win-temp user-temp prefetch thumbs win-update cbs-logs
          inetcache crashdumps wer d3dcache
          edge-cache chrome-cache firefox-cache recyclebin

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) {
    $output | ConvertTo-Json -Depth 6 -Compress
}
