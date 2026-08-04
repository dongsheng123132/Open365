<#
  Open365 更新检查引擎自测
  策略：全程离线 —— 用 -Url 指向临时目录里自己造的假清单，
        造出「有新版 / 已最新 / 远端更旧 / 版本号看不懂 / 源不可达」五种情况，
        断言引擎的结论。绝不依赖 GitHub，绝不真的联网，绝不动任何本机状态。

  最重要的一条断言：版本号比不出来时必须报 unknown，
  绝不能把看不懂的东西当成"有新版"，骗用户去下载来路不明的文件。
#>
$ErrorActionPreference = 'Stop'
$engine = Join-Path $PSScriptRoot '..\engine\update.ps1'
$verFile = Join-Path $PSScriptRoot '..\VERSION'

$pass = 0; $fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else       { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}
function Section($t) { Write-Host "`n===== $t =====" -ForegroundColor Magenta }

function Run-Check([string]$url) {
    $ErrorActionPreference = 'Continue'
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command `
        "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '$engine' check -Url '$url' -TimeoutSec 3 -Json" 2>$null
    return ($out | Out-String).Trim()
}

# 造一份假清单，返回文件路径
function New-Feed([string]$name, [string]$version) {
    $p = Join-Path $tmpDir "$name.json"
    $o = [ordered]@{
        version      = $version
        channel      = 'stable'
        published_at = '2026-01-01'
        notes        = "自测用假清单 $name"
        download_url = 'https://example.invalid/open365'
    }
    ($o | ConvertTo-Json -Compress) | Set-Content -LiteralPath $p -Encoding UTF8
    return $p
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("open365-update-test-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

# 记录 VERSION 的内容与写入时间，最后断言只读动作没碰过它
$verBefore = (Get-Content -LiteralPath $verFile -Raw)
$verStampBefore = (Get-Item -LiteralPath $verFile).LastWriteTimeUtc
$current = $verBefore.Trim()

try {
    Write-Host "  本机 VERSION = $current" -ForegroundColor DarkGray

    Section "1. 远端更新 -> 应报 update-available"
    $d = (Run-Check (New-Feed 'newer' '9999.0.0')) | ConvertFrom-Json
    Check "has_update = true"            ($d.has_update -eq $true)
    Check "status = update-available"    ($d.status -eq 'update-available')
    Check "latest = 9999.0.0"            ($d.latest -eq '9999.0.0')
    Check "download_url 透传自清单"      ($d.download_url -eq 'https://example.invalid/open365')
    Check "error 为空"                   ([string]::IsNullOrEmpty($d.error))

    Section "2. 远端与本机同版 -> 应报 up-to-date"
    $d = (Run-Check (New-Feed 'same' $current)) | ConvertFrom-Json
    Check "has_update = false"           ($d.has_update -eq $false)
    Check "status = up-to-date"          ($d.status -eq 'up-to-date')

    Section "3. 远端带 v 前缀且同版 -> 仍是 up-to-date（不能被 'v' 骗到）"
    $d = (Run-Check (New-Feed 'vprefix' ("v" + $current))) | ConvertFrom-Json
    Check "status = up-to-date"          ($d.status -eq 'up-to-date')
    Check "latest 已去掉 v 前缀"         ($d.latest -eq $current)

    Section "4. 远端比本机旧 -> ahead（不是 up-to-date，别把线上版本号说成用户装的那个）"
    $d = (Run-Check (New-Feed 'older' '0.0.1')) | ConvertFrom-Json
    Check "has_update = false"           ($d.has_update -eq $false)
    Check "status = ahead"               ($d.status -eq 'ahead')
    Check "latest 仍是线上那个 0.0.1"    ($d.latest -eq '0.0.1')
    Check "current 仍是本机版本"         ($d.current -eq $current)

    Section "5. 版本号看不懂 -> unknown，绝不谎报有新版"
    $d = (Run-Check (New-Feed 'garbage' 'latest-build')) | ConvertFrom-Json
    Check "has_update = false"           ($d.has_update -eq $false)
    Check "status = unknown"             ($d.status -eq 'unknown')
    Check "error 说明了原因"             (-not [string]::IsNullOrEmpty($d.error))

    Section "6. 源不可达 -> unreachable + 兜底下载页"
    $d = (Run-Check (Join-Path $tmpDir 'does-not-exist.json')) | ConvertFrom-Json
    Check "has_update = false"           ($d.has_update -eq $false)
    Check "status = unreachable"         ($d.status -eq 'unreachable')
    Check "error 非空"                   (-not [string]::IsNullOrEmpty($d.error))
    Check "download_url 仍给得出兜底地址" ($d.download_url -match '^https://github\.com/')

    Section "7. 指定了 -Url 就只查它，绝不偷偷回落 github"
    $feed = New-Feed 'exclusive' '9999.0.0'
    $d = (Run-Check $feed) | ConvertFrom-Json
    Check "source 就是我们给的地址"      ($d.source -eq $feed)
    Check "source 不含 github"           ($d.source -notmatch 'github')

    Section "8. 输出契约：必需字段一个都不能少"
    $d = (Run-Check (New-Feed 'contract' '9999.0.0')) | ConvertFrom-Json
    $names = $d.PSObject.Properties.Name
    foreach ($f in @('current', 'latest', 'has_update', 'status', 'download_url', 'source', 'checked_at', 'error')) {
        Check "输出含字段 $f"            ($names -contains $f)
    }
    Check "current 等于本机 VERSION"     ($d.current -eq $current)

    Section "9. 只读性：跑完不许碰 VERSION 文件"
    Check "VERSION 内容未变"             ((Get-Content -LiteralPath $verFile -Raw) -eq $verBefore)
    Check "VERSION 修改时间未变"         ((Get-Item -LiteralPath $verFile).LastWriteTimeUtc -eq $verStampBefore)
}
finally {
    Section "10. 清理临时清单"
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  清理完成"
}

Section "测试结果"
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
