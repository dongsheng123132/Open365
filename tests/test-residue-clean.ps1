# 自测：软件卸载引擎的"残留一键清理"（留底 + 可回滚 + 安全护栏）
# 模拟真实残留 -> 清理 -> 验证清干净且备份齐全 -> 还原 -> 清场，全程不碰真实软件。
$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'engine\uninstall.ps1'
$kw = 'Open365ResidueTest'
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}

# 先清掉上一轮可能的残留（幂等）
$fakeDir = Join-Path $env:APPDATA "${kw}Company"
$fakeReg = "HKCU:\SOFTWARE\${kw}Corp"
Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $fakeReg -Recurse -Force -ErrorAction SilentlyContinue

# ---- 造假残留：APPDATA 下一个目录 + HKCU 一个注册表键 ----
New-Item -ItemType Directory -Force -Path $fakeDir | Out-Null
Set-Content -Path (Join-Path $fakeDir 'junk.txt') -Value 'leftover' -Encoding UTF8
New-Item -Path $fakeReg -Force | Out-Null
Set-ItemProperty -Path $fakeReg -Name 'Marker' -Value '1'

Write-Host "===== 1. 残留就位 ====="
Check "假目录存在" (Test-Path $fakeDir)
Check "假注册表键存在" (Test-Path $fakeReg)

# ---- 清理 ----
Write-Host "===== 2. residue-clean 执行 ====="
$out = & $engine residue-clean $kw -Yes -Json | ConvertFrom-Json
Check "返回 ok" ($out.ok -eq $true)
Check "移动目录 >=1" ($out.moved_count -ge 1)
Check "删除注册表 >=1" ($out.reg_count -ge 1)

Write-Host "===== 3. 清理 + 留底效果 ====="
Check "原目录已移走" (-not (Test-Path $fakeDir))
Check "原注册表键已删" (-not (Test-Path $fakeReg))
Check "备份目录存在" (Test-Path $out.backup_dir)
$backedDir = Join-Path $out.backup_dir "dirs\${kw}Company"
Check "目录已进备份区" (Test-Path $backedDir)
$regBak = @(Get-ChildItem -Path $out.backup_dir -Filter 'reg_*.reg' -ErrorAction SilentlyContinue)
Check "注册表已导出 .reg" ($regBak.Count -ge 1)
Check "有还原说明.txt" (Test-Path (Join-Path $out.backup_dir '还原说明.txt'))

# ---- 还原验证 ----
Write-Host "===== 4. 可还原 ====="
Move-Item -LiteralPath $backedDir -Destination $fakeDir -Force
Check "目录可搬回原位" (Test-Path $fakeDir)
# reg import 会把"操作成功"写到 stderr；用 Start-Process 避免被 -ErrorActionPreference Stop 误当错误
Start-Process -FilePath 'reg.exe' -ArgumentList @('import', $regBak[0].FullName) -Wait -WindowStyle Hidden
Check "注册表可导回" (Test-Path $fakeReg)

# ---- 安全护栏 ----
Write-Host "===== 5. 安全护栏（危险/过短关键词必须被拒） ====="
$b1 = $false; try { & $engine residue-clean 'windows' -Yes -Json | Out-Null } catch { $b1 = $true }
Check "危险关键词 windows 被拒" $b1
$b2 = $false; try { & $engine residue-clean 'a' -Yes -Json | Out-Null } catch { $b2 = $true }
Check "过短关键词 a 被拒" $b2

# ---- 清场 ----
Remove-Item -LiteralPath $fakeDir -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path $fakeReg -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath $out.backup_dir -Recurse -Force -ErrorAction SilentlyContinue

# ---- 残留把握度分级（本地判断，不联网）----
Write-Host "===== 6. 残留把握度分级 ====="
. $engine help *>$null
Check "Get-ResidueConfidence 已加载" ($null -ne (Get-Command Get-ResidueConfidence -ErrorAction SilentlyContinue))
Check "前缀匹配 → high(确定)" ((Get-ResidueConfidence 'FooCorp' 'Foo').level -eq 'high')
Check "完全相等 → high(确定)" ((Get-ResidueConfidence 'Foo' 'Foo').level -eq 'high')
Check "仅包含 → low(可能)"    ((Get-ResidueConfidence 'MyFooThing' 'Foo').level -eq 'low')

Write-Host ""
Write-Host "  结果: $pass 通过, $fail 失败" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
