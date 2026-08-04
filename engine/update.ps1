<#
.SYNOPSIS
    Open365 更新检查引擎 (update engine)
    只查"有没有新版本"，绝不自己下载、绝不自己安装。

.DESCRIPTION
    check : 读本机 VERSION，向更新源发一个 GET，比对版本号，给出结论。
    help  : 用法。

    与"不联网上传"的承诺一致：
      * 只发 GET，请求体是空的，不带机器码 / 不带任何本机信息；
        除标准 User-Agent 外不附加任何标识。
      * 只在用户主动点「检查更新」或主动敲命令时才跑，没有开机自动联网。
      * 查到新版只告诉你去哪下，不后台下载、不静默替换文件。

    更新源：
      * 默认查 https://api.github.com/repos/<repo>/releases/latest。
        Release 的 tag 就是版本号本身，仓库里不再另存一份 version.json ——
        同一个事实存两份，迟早漂移成两个版本号。
      * 指定了 -Url 或环境变量 OPEN365_UPDATE_URL —— 就只查这一个，
        不会再回落到 github（内网/自建部署不该被偷偷发外网请求）。

    自建源的清单格式（GFW 后面想架个镜像就照这个写）：
      { "version": "1.4.0", "channel": "stable", "published_at": "2026-08-10",
        "notes": "改了啥", "download_url": "https://..." }

.NOTES
    全程只读，不需要管理员。网络不通不算失败，返回 status=unreachable + error 说明。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'sources', 'help')]
    [string]$Action = 'help',

    [string]$Url,              # 覆盖更新源（自建 CDN / 内网 / 测试）
    [int]$TimeoutSec = 8,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# -Json 输出要能被 UTF-8 解析：脚本自己钉住输出编码，别依赖调用方的控制台代码页。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Repo = 'dongsheng123132/Open365'
$ReleasePage = "https://github.com/$Repo/releases/latest"

# ---------- 本机版本（唯一真相源 = 程序目录下的 VERSION 文件） ----------
function Get-LocalVersion {
    $root = Split-Path $PSScriptRoot -Parent
    $p = Join-Path $root 'VERSION'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $s = (Get-Content -LiteralPath $p -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $s) { return '' }
    return $s.Trim()
}

# ---------- 版本号比较 ----------
# 逐段数字比，短的补 0；"v1.3" 与 "1.3.0" 等价。比不出来（含字母等）返回 $null，
# 由调用方判定为"无法比较"，绝不瞎猜成"有新版"骗用户去下载。
function Compare-Ver([string]$a, [string]$b) {
    $na = Normalize-Ver $a
    $nb = Normalize-Ver $b
    if ($null -eq $na -or $null -eq $nb) { return $null }
    $len = [Math]::Max($na.Count, $nb.Count)
    for ($i = 0; $i -lt $len; $i++) {
        $x = if ($i -lt $na.Count) { $na[$i] } else { 0 }
        $y = if ($i -lt $nb.Count) { $nb[$i] } else { 0 }
        if ($x -gt $y) { return 1 }
        if ($x -lt $y) { return -1 }
    }
    return 0
}

function Normalize-Ver([string]$v) {
    if (-not $v) { return $null }
    $s = $v.Trim()
    if ($s -match '^[vV]') { $s = $s.Substring(1) }
    $s = ($s -split '[-+]')[0]          # 丢掉 1.4.0-beta.1 的预发布后缀
    $parts = $s -split '\.'
    $nums = @()
    foreach ($p in $parts) {
        if ($p -notmatch '^\d+$') { return $null }
        $nums += [int]$p
    }
    if ($nums.Count -eq 0) { return $null }
    return , $nums
}

# ---------- 更新源 ----------
function Get-Sources {
    # 显式指定了源就"只用这一个"：内网/自建部署指了自己的地址，
    # 再偷偷回落到 github.com 属于用户没同意的外网请求，不干。
    if ($Url) { return @([ordered]@{ url = $Url; kind = 'manifest'; label = '命令行 -Url' }) }
    if ($env:OPEN365_UPDATE_URL) {
        return @([ordered]@{ url = $env:OPEN365_UPDATE_URL; kind = 'manifest'; label = '环境变量 OPEN365_UPDATE_URL' })
    }

    # 两个源都指向同一个事实（最新 Release），所以不会漂移；
    # 仓库里不另存 version.json —— 同一个版本号存两份，迟早对不上。
    #   1. API：还能带上更新说明和发布时间，但匿名调用有 60 次/小时/IP 的限流。
    #   2. 302 跳转：不走 API、不限流，被限流或 API 不通时兜底（只拿得到版本号）。
    return @(
        [ordered]@{ url = "https://api.github.com/repos/$Repo/releases/latest"; kind = 'github'; label = 'GitHub Release API' },
        [ordered]@{ url = "https://github.com/$Repo/releases/latest"; kind = 'github-redirect'; label = 'GitHub Release 跳转' }
    )
}

function Invoke-Http([string]$u) {
    # PowerShell 5.x 默认可能还在 TLS1.0，GitHub 早就只收 1.2+
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch { }

    $p = @{
        Uri             = $u
        TimeoutSec      = $TimeoutSec
        UseBasicParsing = $true
        Headers         = @{ 'User-Agent' = 'Open365-UpdateCheck'; 'Accept' = 'application/json' }
        ErrorAction     = 'Stop'
    }
    # 有代理就走代理（不少用户的 GitHub 只有挂代理才通）
    $proxy = $env:HTTPS_PROXY; if (-not $proxy) { $proxy = $env:HTTP_PROXY }
    if ($proxy) { $p['Proxy'] = $proxy }

    return Invoke-WebRequest @p
}

function Invoke-Fetch([string]$u) {
    # 本地文件路径 / file:// 直接读，方便离线测试和内网部署
    if ($u -match '^file://') { return [System.IO.File]::ReadAllText(([uri]$u).LocalPath, [System.Text.Encoding]::UTF8) }
    if ($u -notmatch '^https?://') { return [System.IO.File]::ReadAllText($u, [System.Text.Encoding]::UTF8) }
    return (Invoke-Http $u).Content
}

# github.com/<repo>/releases/latest 会 302 到 .../releases/tag/vX.Y.Z ——
# 从跳转后的地址上把 tag 读下来。好处是不走 API，没有匿名 60 次/小时的限流，
# 而且真相源仍然是同一个「最新 Release」，不会跟 tag 漂移。
function Get-RedirectFeed([string]$u) {
    $r = Invoke-Http $u
    $final = ''
    try { $final = [string]$r.BaseResponse.ResponseUri.AbsoluteUri } catch { }
    if (-not $final) { throw '拿不到跳转后的地址' }
    if ($final -notmatch '/releases/tag/([^/?#]+)') { throw "跳转地址里没有版本 tag：$final" }
    return [ordered]@{
        version      = Clean-Ver $Matches[1]
        channel      = 'stable'
        notes        = ''
        published_at = ''
        download_url = $final
    }
}

# 版本号统一去掉前缀 v：GitHub tag 是 "v1.3.0"，VERSION 文件是 "1.3.0"，
# 不归一的话界面上会印出 "vv1.3.0"。
function Clean-Ver([string]$v) {
    if (-not $v) { return '' }
    $s = $v.Trim()
    if ($s -match '^[vV]\d') { $s = $s.Substring(1) }
    return $s
}

# 把两种源的原始 JSON 归一成同一份结构
function Read-Feed([string]$body, [string]$kind) {
    $d = $body | ConvertFrom-Json
    if ($kind -eq 'github') {
        if ($d.draft -eq $true) { throw '最新 Release 还是草稿' }
        return [ordered]@{
            version      = Clean-Ver ([string]$d.tag_name)
            channel      = if ($d.prerelease -eq $true) { 'prerelease' } else { 'stable' }
            notes        = [string]$d.name
            published_at = [string]$d.published_at
            download_url = if ($d.html_url) { [string]$d.html_url } else { $ReleasePage }
        }
    }
    return [ordered]@{
        version      = Clean-Ver ([string]$d.version)
        channel      = if ($d.channel) { [string]$d.channel } else { 'stable' }
        notes        = [string]$d.notes
        published_at = [string]$d.published_at
        download_url = if ($d.download_url) { [string]$d.download_url } else { $ReleasePage }
    }
}

function Invoke-Check {
    $current = Get-LocalVersion
    $result = [ordered]@{
        current      = $current
        latest       = $null
        has_update   = $false
        status       = 'unreachable'
        channel      = $null
        notes        = ''
        published_at = ''
        download_url = $ReleasePage
        source       = ''
        checked_at   = (Get-Date).ToString('s')
        error        = $null
    }

    $errs = @()
    foreach ($src in (Get-Sources)) {
        try {
            $feed = if ($src.kind -eq 'github-redirect') { Get-RedirectFeed $src.url }
                    else { Read-Feed (Invoke-Fetch $src.url) $src.kind }
            if (-not $feed.version) { throw '返回内容里没有版本号' }

            $result.latest = $feed.version
            $result.channel = $feed.channel
            $result.notes = $feed.notes
            $result.published_at = $feed.published_at
            $result.download_url = $feed.download_url
            $result.source = $src.url

            $cmp = Compare-Ver $feed.version $current
            if ($null -eq $cmp) {
                $result.status = 'unknown'
                $result.error = "版本号比不了：本机 '$current'，远端 '$($feed.version)'"
            }
            elseif ($cmp -gt 0) {
                $result.status = 'update-available'
                $result.has_update = $true
            }
            elseif ($cmp -lt 0) {
                # 本机比线上还新 —— 开发版 / 预发布 / 还没打 tag。
                # 这时候说"已经是最新版 v<线上版本>"是错的，会让人以为自己装的是那个版本。
                $result.status = 'ahead'
            }
            else {
                $result.status = 'up-to-date'
            }
            return $result
        }
        catch {
            $msg = $_.Exception.Message
            # 403 基本都是匿名 API 的 60 次/小时限流，别再报成"网络不通"误导用户
            if ($msg -match '\(403\)') { $msg += '（GitHub 匿名接口每小时 60 次上限，等一会儿再试）' }
            $errs += "$($src.label): $msg"
        }
    }

    $result.error = '所有更新源都没查通 —— ' + ($errs -join '；')
    return $result
}

function Show-Check($r) {
    Write-Host ""
    Write-Host "  ========== Open365 检查更新 ==========" -ForegroundColor White
    Write-Host ""
    Write-Host ("  本机版本: v{0}" -f $(if ($r.current) { $r.current } else { '未知' }))
    switch ($r.status) {
        'update-available' {
            Write-Host ("  最新版本: v{0}   <-- 有新版" -f $r.latest) -ForegroundColor Yellow
            if ($r.notes) { Write-Host ("  更新说明: {0}" -f $r.notes) -ForegroundColor DarkGray }
            Write-Host ""
            Write-Host ("  下载地址: {0}" -f $r.download_url) -ForegroundColor Cyan
            Write-Host "  Open365 不会自己下载/自己替换文件，请你自己决定要不要更新。" -ForegroundColor DarkGray
        }
        'up-to-date' {
            Write-Host ("  最新版本: v{0}" -f $r.latest) -ForegroundColor Green
            Write-Host "  已经是最新版。" -ForegroundColor Green
        }
        'ahead' {
            Write-Host ("  已发布版本: v{0}" -f $r.latest) -ForegroundColor DarkGray
            Write-Host ("  你这台装的 v{0} 比已发布的还新（开发版），不用更新。" -f $r.current) -ForegroundColor Green
        }
        'unknown' {
            Write-Host ("  最新版本: v{0}" -f $r.latest) -ForegroundColor Yellow
            Write-Host ("  [!] {0}" -f $r.error) -ForegroundColor Yellow
        }
        default {
            Write-Host "  最新版本: 查不到" -ForegroundColor Red
            Write-Host ("  [X] {0}" -f $r.error) -ForegroundColor DarkGray
            Write-Host ""
            Write-Host ("  手动看这里: {0}" -f $ReleasePage) -ForegroundColor Cyan
        }
    }
    Write-Host ""
}

function Show-Sources {
    Write-Host ""
    Write-Host "  更新源（按顺序试，第一个通的算数）:" -ForegroundColor White
    $i = 1
    foreach ($s in (Get-Sources)) {
        Write-Host ("   {0}. [{1}] {2}" -f $i, $s.label, $s.url)
        $i++
    }
    Write-Host ""
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'check' {
        $r = Invoke-Check
        if ($Json) { $output = $r } else { Show-Check $r }
    }
    'sources' {
        $list = @(Get-Sources)
        if ($Json) { $output = @{ sources = $list; count = $list.Count } } else { Show-Sources }
    }
    'help' {
        Write-Host @"
Open365 更新检查引擎

用法: update.ps1 <action> [-Url <更新源>] [-TimeoutSec <秒>] [-Json]

  check               查有没有新版本（只读、只发 GET、不下载不安装）
  sources             列出当前会去查哪些更新源

隐私：只发一个空请求体的 GET，不带机器码、不带任何本机信息；
      只在你主动触发时才跑，没有开机自动联网。
      查到新版也只告诉你去哪下，绝不后台下载、绝不静默替换文件。

自建更新源：-Url https://你的域名/version.json
            或设环境变量 OPEN365_UPDATE_URL
清单格式：{ "version":"1.4.0", "channel":"stable",
            "published_at":"2026-08-10", "notes":"改了啥",
            "download_url":"https://..." }

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
