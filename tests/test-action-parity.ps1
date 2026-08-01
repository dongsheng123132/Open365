<#
  动作同源自测（ActionParity 0.5.0 / 影核协议）

  这套测试专门解决一个老问题：GUI 没法稳定自动化测试。
  做法是把"软件有没有做对事情"和"人能不能点到"拆开——
  本文件只测前者，全程无界面、无鼠标、无截图，AI 可以自己跑。

  覆盖：
    1. action-parity.json 与注册表没有漂移
    2. 各界面绑定都指向同一个 Action ID（静态检查，不用开窗口）
    3. 每个只读动作都能无界面跑通，且输出符合 output_schema
    4. 非法输入在进引擎之前就被拒绝
    5. 改系统的动作默认被拒绝，必须显式 -Confirm
    6. 沙箱模式（OPEN365_SANDBOX=1）下写动作一律拒绝
    7. 通用动作 CLI 与旧引擎命令返回同一份语义
#>

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$root = Split-Path $PSScriptRoot -Parent
$core = Join-Path $root 'core\action-core.ps1'

$script:pass = 0
$script:fail = 0

function Check([string]$name, [bool]$ok, [string]$detail) {
    if ($ok) {
        $script:pass++
        Write-Host "  [OK]   $name" -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host "  [FAIL] $name — $detail" -ForegroundColor Red
    }
}

# 必须用 -File 调用：powershell -Command "& '<script>'" 会把脚本退出码压成 1，
# 语义化退出码(2=用法错误 / 3=被闸门拒绝)只有 -File 才透传。AI 调用同理。
function Invoke-Core([string[]]$argv) {
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $core @argv 2>$null
    return @{ text = (($out | Out-String).Trim()); code = $LASTEXITCODE }
}

# 输入统一走临时文件：PowerShell 之间传含引号的 JSON 参数会被重新解析拆坏，
# 这也正是 GUI 调用动作核心时使用的那条路径。
function New-InputFile([string]$json) {
    $f = Join-Path $env:TEMP ("open365-test-" + [guid]::NewGuid().ToString('N') + ".json")
    [System.IO.File]::WriteAllText($f, $json, (New-Object System.Text.UTF8Encoding($false)))
    return $f
}

function Invoke-CoreJson([string[]]$argv) {
    $r = Invoke-Core $argv
    $obj = $null
    if ($r.text) { try { $obj = $r.text | ConvertFrom-Json } catch { } }
    return @{ json = $obj; code = $r.code; text = $r.text }
}

Write-Host ""
Write-Host "  ===== Open365 动作同源自测 =====" -ForegroundColor White
Write-Host ""

# --- 1~3 & 5：动作核心自带的完整校验回路 ---
$verify = Invoke-CoreJson @('verify', '-Json')
$vok = ($verify.code -eq 0 -and $verify.json -and $verify.json.ok)
$vdetail = if ($verify.json) { "$($verify.json.checks_failed) 项失败" } else { "无法解析 verify 输出: $($verify.text)" }
Check "verify：清单/绑定/只读执行/默认拒绝 全通过" $vok $vdetail
if ($verify.json) {
    foreach ($c in $verify.json.checks) {
        if (-not $c.ok) { Write-Host "         · $($c.check) $($c.action_id): $($c.detail)" -ForegroundColor DarkRed }
    }
}

# --- 清单本身必须是合法 JSON，且声明的应用身份稳定 ---
$manifestPath = Join-Path $root 'action-parity.json'
$manifest = $null
try { $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
Check "action-parity.json 可解析且应用 ID 稳定" ($manifest -and $manifest.application.id -eq 'org.open365.maintenance') '清单缺失或应用 ID 变了'
Check "清单使用 0.5.0 且声明生成来源" ($manifest -and $manifest.spec_version -eq '0.5.0' -and $manifest.generated_from.revision -eq 'core/registry.ps1') '协议版本或 generated_from 不正确'
Check "清单里每个动作都可无界面执行" ($manifest -and -not (@($manifest.actions | Where-Object { -not $_.execution.headless }).Count)) '存在 headless=false 的动作'

# --- execution_id：界面产生的请求 ID 必须原样进入动作核心 ---
$requestId = 'open365-test-' + [guid]::NewGuid().ToString('N')
$correlated = Invoke-CoreJson @('run', 'focus.status', '-ExecutionId', $requestId, '-Json')
Check "调用方 execution_id 原样到达动作核心" ($correlated.code -eq 0 -and $correlated.json.execution_id -eq $requestId) "request=$requestId core=$($correlated.json.execution_id)"

# --- 4：非法输入必须在进引擎之前被拒绝 ---
$badFile = New-InputFile '{"nope":1}'
$bad = Invoke-CoreJson @('run', 'software.search', '-InputFile', $badFile, '-Json')
$badOk = ($bad.code -eq 1 -and $bad.json -and $bad.json.error.code -eq 'invalid_input')
Check "未声明字段被 input_schema 拒绝" $badOk "退出码 $($bad.code) / $($bad.text)"

$missing = Invoke-CoreJson @('run', 'software.search', '-Json')
$missingOk = ($missing.code -eq 1 -and $missing.json -and $missing.json.error.code -eq 'invalid_input')
Check "缺少必填字段被拒绝" $missingOk "退出码 $($missing.code)"

$unknown = Invoke-CoreJson @('run', 'no.such_action', '-Json')
$unknownOk = ($unknown.code -eq 2 -and $unknown.json -and $unknown.json.error.code -eq 'unknown_action')
Check "未注册的 Action ID 报用法错误(退出码 2)" $unknownOk "退出码 $($unknown.code)"

# --- 5：写动作默认拒绝 ---
$denyFile = New-InputFile '{"id":"reg:hklm-run:NoSuchItem"}'
$deny = Invoke-CoreJson @('run', 'startup.disable', '-InputFile', $denyFile, '-Json')
$denyOk = ($deny.code -eq 3 -and $deny.json -and $deny.json.error.code -eq 'confirmation_required')
Check "写动作未确认时被拒绝(退出码 3)" $denyOk "退出码 $($deny.code) / $($deny.json.error.code) $($deny.json.error.message)"

# --- 6：沙箱模式下写动作一律拒绝，哪怕带了 -Confirm ---
$old = $env:OPEN365_SANDBOX
$env:OPEN365_SANDBOX = '1'
$sandbox = Invoke-CoreJson @('run', 'startup.disable', '-InputFile', $denyFile, '-Confirm', '-Json')
$sandboxOk = ($sandbox.code -eq 3 -and $sandbox.json -and $sandbox.json.error.code -eq 'sandbox_read_only')
Check "OPEN365_SANDBOX=1 时写动作被拒绝(即使 -Confirm)" $sandboxOk "退出码 $($sandbox.code) / $($sandbox.json.error.code)"
$sandboxRead = Invoke-CoreJson @('run', 'focus.status', '-Json')
Check "沙箱模式下只读动作仍可执行" ($sandboxRead.code -eq 0) "退出码 $($sandboxRead.code)"
if ($null -eq $old) { Remove-Item Env:\OPEN365_SANDBOX -ErrorAction SilentlyContinue } else { $env:OPEN365_SANDBOX = $old }

# --- 7：通用动作 CLI 与旧引擎命令必须给出同一份语义 ---
$viaCore = Invoke-CoreJson @('run', 'focus.status', '-Json')
$legacyText = & powershell -NoProfile -ExecutionPolicy Bypass -Command "[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & '$root\engine\focus.ps1' status -Json" 2>$null
$viaLegacy = $null
try { $viaLegacy = ($legacyText | Out-String).Trim() | ConvertFrom-Json } catch { }
$sameKeys = $false
if ($viaCore.json -and $viaCore.json.ok -and $viaLegacy) {
    $a = @($viaCore.json.output.PSObject.Properties.Name | Sort-Object)
    $b = @($viaLegacy.PSObject.Properties.Name | Sort-Object)
    $sameKeys = (($a -join ',') -eq ($b -join ','))
}
Check "动作核心与旧引擎命令返回同一组字段" $sameKeys '两条路径的输出字段不一致（出现了第二份实现）'

# --- 描述性接口：AI 靠 describe 就能拿到契约 ---
$desc = Invoke-CoreJson @('describe', 'security.check', '-Json')
$descOk = ($desc.code -eq 0 -and $desc.json -and $desc.json.action.id -eq 'security.check' -and $desc.json.action.input_schema)
Check "describe 返回可机读契约" $descOk "退出码 $($desc.code)"

Remove-Item -LiteralPath $badFile, $denyFile -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("  通过 {0} / {1}" -f $script:pass, ($script:pass + $script:fail)) -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ""
if ($script:fail -gt 0) { exit 1 }
exit 0
