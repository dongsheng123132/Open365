<#
  Open365 C 盘空间治理引擎自测。
  所有规则路径与审计目录都重定向到仓库 tests 下的自建沙盒；不访问真实临时目录、
  回收站、浏览器缓存或 C:\Windows\Temp。apply 一律通过真实 powershell 子进程执行。
#>
$ErrorActionPreference = 'Stop'

$cleaner = Join-Path $PSScriptRoot '..\engine\cleaner.ps1'
$pass = 0
$fail = 0

function Check($name, $condition, $detail) {
    if ($condition) {
        Write-Host "  [PASS] $name" -ForegroundColor Green
        $script:pass++
    } else {
        if ($detail) { Write-Host "  [FAIL] $name -- $detail" -ForegroundColor Red }
        else { Write-Host "  [FAIL] $name" -ForegroundColor Red }
        $script:fail++
    }
}

function Section($title) {
    Write-Host "`n===== $title =====" -ForegroundColor Magenta
}

function Invoke-CleanerJson([string[]]$ArgumentList) {
    $lines = @(& powershell -NoProfile -ExecutionPolicy Bypass -File $cleaner @ArgumentList -Json 2>&1)
    $code = $LASTEXITCODE
    $text = ($lines | ForEach-Object { [string]$_ }) -join "`n"
    $parsed = $null
    foreach ($line in @($lines | Select-Object -Last 5)) {
        $candidate = ([string]$line).Trim()
        if (-not $candidate.StartsWith('{')) { continue }
        try { $parsed = $candidate | ConvertFrom-Json -ErrorAction Stop } catch { }
    }
    return [ordered]@{ code=$code; json=$parsed; text=$text }
}

function New-TestFile([string]$path, [int]$bytes, [int]$ageDays) {
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [System.IO.File]::WriteAllBytes($path, (New-Object byte[] $bytes))
    if ($ageDays -gt 0) {
        (Get-Item -LiteralPath $path).LastWriteTime = (Get-Date).AddDays(-$ageDays)
    }
    return $path
}

function Reset-Key([string]$key) {
    $target = Join-Path $script:ruleRoot $key
    $resolvedRoot = [System.IO.Path]::GetFullPath($script:ruleRoot).TrimEnd('\') + '\'
    $resolvedTarget = [System.IO.Path]::GetFullPath($target)
    if (-not $resolvedTarget.StartsWith($resolvedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "拒绝清理沙盒外路径：$resolvedTarget"
    }
    if (Test-Path -LiteralPath $resolvedTarget) {
        Remove-Item -LiteralPath $resolvedTarget -Recurse -Force -ErrorAction Stop
    }
    New-Item -ItemType Directory -Path $resolvedTarget -Force | Out-Null
    return $resolvedTarget
}

function Get-Plan([string]$keys) {
    if ([string]::IsNullOrWhiteSpace($keys)) {
        return Invoke-CleanerJson @('plan', '-RequestedBy', 'test-cleaner')
    }
    return Invoke-CleanerJson @('plan', '-Keys', $keys, '-RequestedBy', 'test-cleaner')
}

function Invoke-ApplyProcess([string]$keys, [string]$planId, [string]$requestId) {
    return Invoke-CleanerJson @(
        'apply', '-Keys', $keys, '-PlanId', $planId,
        '-RequestId', $requestId, '-RequestedBy', 'test-cleaner'
    )
}

$sandbox = Join-Path $PSScriptRoot ('.cleaner-sandbox-' + [guid]::NewGuid().ToString('N'))
$script:ruleRoot = Join-Path $sandbox 'rules'
$spaceHome = Join-Path $sandbox 'space-home'
$unitRoot = Join-Path $sandbox 'unit'
$oldCleanerRoot = $env:OPEN365_CLEANER_ROOT
$oldSpaceHome = $env:OPEN365_SPACE_HOME
$oldSandboxMode = $env:OPEN365_SANDBOX

Section '0. 建隔离沙盒 + 启用双重定向钩子'
New-Item -ItemType Directory -Path $script:ruleRoot -Force | Out-Null
New-Item -ItemType Directory -Path $unitRoot -Force | Out-Null
$env:OPEN365_CLEANER_ROOT = $script:ruleRoot
$env:OPEN365_SPACE_HOME = $spaceHome
Remove-Item Env:\OPEN365_SANDBOX -ErrorAction SilentlyContinue
Write-Host "  规则沙盒: $script:ruleRoot"
Write-Host "  收据沙盒: $spaceHome"

try {
    # 保留原有 6 组基础测试：函数加载、体积、清理、目录保留、filter、Firefox 数据保护。
    Section '1. 加载 cleaner 引擎函数'
    . $cleaner help -Json | Out-Null
    Check 'Get-DirSize 函数已加载' ($null -ne (Get-Command Get-DirSize -ErrorAction SilentlyContinue)) ''
    Check 'Clear-Dir 函数已加载' ($null -ne (Get-Command Clear-Dir -ErrorAction SilentlyContinue)) ''

    Section '2. 验证体积扫描算得准'
    [long]$expectedBytes = 0
    1..5 | ForEach-Object {
        New-TestFile (Join-Path $unitRoot "junk$_.tmp") 1MB 0 | Out-Null
        $expectedBytes += 1MB
    }
    New-TestFile (Join-Path $unitRoot 'subdir\nested.tmp') 512KB 0 | Out-Null
    $expectedBytes += 512KB
    $size = Get-DirSize $unitRoot $null 0
    Check '文件数正确 (应=6)' ($size.files -eq 6) "实际 $($size.files)"
    Check '字节数正确' ($size.bytes -eq $expectedBytes) "实际 $($size.bytes)"

    Section '3. 执行 Clear-Dir 清理沙盒'
    $unitFailures = @()
    $reported = Clear-Dir $unitRoot $null 0 ([ref]$unitFailures)
    Check '释放量正确' ($reported -eq $expectedBytes) "实际 $reported"
    Check '基础清理没有失败项' ($unitFailures.Count -eq 0) "失败 $($unitFailures.Count)"

    Section '4. 验证沙盒已清空但根目录保留'
    $remaining = @(Get-ChildItem -LiteralPath $unitRoot -Recurse -Force -ErrorAction SilentlyContinue)
    Check '沙盒内文件已全部删除' ($remaining.Count -eq 0) "剩余 $($remaining.Count)"
    Check '沙盒目录本身保留' (Test-Path -LiteralPath $unitRoot -PathType Container) ''

    Section '5. 验证 filter 只删匹配文件'
    New-TestFile (Join-Path $unitRoot 'a.log') 1KB 0 | Out-Null
    New-TestFile (Join-Path $unitRoot 'b.txt') 1KB 0 | Out-Null
    $filterFailures = @()
    $freedLog = Clear-Dir $unitRoot '*.log' 0 ([ref]$filterFailures)
    Check '只删了 .log (释放=1KB)' ($freedLog -eq 1KB) "实际 $freedLog"
    Check '.txt 被保留' (Test-Path -LiteralPath (Join-Path $unitRoot 'b.txt') -PathType Leaf) ''

    Section '6. Firefox 基础函数只碰缓存子目录'
    $ffUnit = Join-Path $unitRoot 'ff'
    $ffProfile = Join-Path $ffUnit 'Profiles\abcd.default-release'
    New-TestFile (Join-Path $ffProfile 'cache2\entry1') 256KB 0 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ffProfile 'places.sqlite'), 'bookmarks')
    [System.IO.File]::WriteAllText((Join-Path $ffProfile 'logins.json'), 'passwords')
    [System.IO.File]::WriteAllText((Join-Path $ffProfile 'prefs.js'), 'prefs')
    $ffSize = Get-FirefoxCacheSize $ffUnit 0
    $ffFailures = @()
    $ffFreed = Clear-FirefoxCache $ffUnit 0 ([ref]$ffFailures)
    Check 'Firefox 缓存体积算得到 (>=256KB)' ($ffSize.bytes -ge 256KB) "实际 $($ffSize.bytes)"
    Check 'Firefox 基础清理释放 >=256KB' ($ffFreed -ge 256KB) "实际 $ffFreed"
    Check 'Firefox 基础清理保留书签' (Test-Path -LiteralPath (Join-Path $ffProfile 'places.sqlite')) ''
    Check 'Firefox 基础清理保留密码' (Test-Path -LiteralPath (Join-Path $ffProfile 'logins.json')) ''
    Check 'Firefox 基础清理保留偏好' (Test-Path -LiteralPath (Join-Path $ffProfile 'prefs.js')) ''

    Section '7. 新 scan/plan 契约与确定性 ID'
    $contractDir = Reset-Key 'edge-cache'
    New-TestFile (Join-Path $contractDir 'contract.bin') 1234 0 | Out-Null
    $scanContract = Invoke-CleanerJson @('scan', '-Only', 'edge-cache')
    $contractItem = @($scanContract.json.items)[0]
    Check 'scan 是新 observation 契约' ($scanContract.code -eq 0 -and $scanContract.json.spec -eq 'open365.space-governance/0.1' -and $scanContract.json.kind -eq 'space.observation') $scanContract.text
    Check 'scan 同时保留旧兼容字段' ($null -ne $contractItem.bytes -and $null -ne $contractItem.files -and $null -ne $contractItem.human -and $null -ne $contractItem.path) $scanContract.text
    Check 'scan 分离 observation 与 policy' ($null -ne $contractItem.observation -and $null -ne $contractItem.policy -and $contractItem.policy.owner -eq 'Microsoft Edge') $scanContract.text
    Check 'scan 不输出裁决字段' ($null -eq $scanContract.json.ok -and $null -eq $scanContract.json.pass -and $null -eq $scanContract.json.verdict) $scanContract.text
    $planA = Get-Plan 'chrome-cache,edge-cache'
    $planB = Get-Plan ' edge-cache , CHROME-CACHE '
    Check 'plan_id 对 key 顺序/大小写/边缘空白稳定' ($planA.code -eq 0 -and $planA.json.plan_id -eq $planB.json.plan_id) "$($planA.text) / $($planB.text)"
    Check 'policy_revision 格式正确' ([string]$planA.json.policy_revision -match '^pol:[0-9a-f]{16}$') $planA.text
    Check 'plan_id 格式正确' ([string]$planA.json.plan_id -match '^plan:[0-9a-f]{32}$') $planA.text
    Check 'plan 恒需人工确认' ($planA.json.requires_human_confirmation -eq $true) $planA.text

    Section '8. 反向判据 1：Firefox profile 数据端到端不动'
    $ffRule = Reset-Key 'firefox-cache'
    $profile = Join-Path $ffRule 'Profiles\safe.default-release'
    New-TestFile (Join-Path $profile 'cache2\entry.bin') 4096 0 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $profile 'places.sqlite'), 'bookmarks-original')
    [System.IO.File]::WriteAllText((Join-Path $profile 'logins.json'), 'passwords-original')
    [System.IO.File]::WriteAllText((Join-Path $profile 'prefs.js'), 'prefs-original')
    $ffPlan = Get-Plan 'firefox-cache'
    $ffApply = Invoke-ApplyProcess 'firefox-cache' $ffPlan.json.plan_id ('req-ff-' + [guid]::NewGuid().ToString('N'))
    Check '[判据 1] Firefox apply 成功' ($ffApply.code -eq 0 -and $ffApply.json.status -eq 'done') $ffApply.text
    Check '[判据 1] cache2 内容被治理' (-not (Test-Path -LiteralPath (Join-Path $profile 'cache2\entry.bin'))) ''
    Check '[判据 1] places.sqlite 原样保留' ([System.IO.File]::ReadAllText((Join-Path $profile 'places.sqlite')) -eq 'bookmarks-original') ''
    Check '[判据 1] logins.json 原样保留' ([System.IO.File]::ReadAllText((Join-Path $profile 'logins.json')) -eq 'passwords-original') ''
    Check '[判据 1] prefs.js 原样保留' ([System.IO.File]::ReadAllText((Join-Path $profile 'prefs.js')) -eq 'prefs-original') ''

    Section '9. 反向判据 2：扫描与执行共用保留期'
    $userTemp = Reset-Key 'user-temp'
    $newFile = New-TestFile (Join-Path $userTemp 'new.tmp') 2000 0
    $oldFile = New-TestFile (Join-Path $userTemp 'old.tmp') 3000 3
    $retentionScan = Invoke-CleanerJson @('scan', '-Only', 'user-temp')
    $retentionItem = @($retentionScan.json.items)[0]
    Check '[判据 2] scan 只统计超过保留期的旧文件' ($retentionItem.bytes -eq 3000 -and $retentionItem.files -eq 1) $retentionScan.text
    $retentionPlan = Get-Plan 'user-temp'
    $retentionApply = Invoke-ApplyProcess 'user-temp' $retentionPlan.json.plan_id ('req-retention-' + [guid]::NewGuid().ToString('N'))
    Check '[判据 2] apply 只删除旧文件' (-not (Test-Path -LiteralPath $oldFile) -and (Test-Path -LiteralPath $newFile)) $retentionApply.text
    Check '[判据 2] 前后观察差值等于实际释放量' ($retentionApply.json.total_freed_bytes -eq 3000 -and @($retentionApply.json.items)[0].reported_bytes -eq 3000) $retentionApply.text

    Section '10. 反向判据 3：非默认风险项不进入默认 plan'
    New-TestFile (Join-Path (Reset-Key 'prefetch') 'old.pf') 100 40 | Out-Null
    New-TestFile (Join-Path (Reset-Key 'win-update') 'update.bin') 100 40 | Out-Null
    New-TestFile (Join-Path (Reset-Key 'cbs-logs') 'old.log') 100 40 | Out-Null
    New-TestFile (Join-Path (Reset-Key 'crashdumps') 'old.dmp') 100 20 | Out-Null
    New-TestFile (Join-Path (Reset-Key 'wer') 'old.wer') 100 20 | Out-Null
    New-TestFile (Join-Path (Reset-Key 'recyclebin') 'deleted.txt') 100 0 | Out-Null
    $defaultPlan = Get-Plan ''
    $defaultKeys = @($defaultPlan.json.items | ForEach-Object { $_.key })
    $forbidden = @('prefetch','win-update','cbs-logs','crashdumps','wer','recyclebin')
    $unexpected = @($forbidden | Where-Object { $defaultKeys -contains $_ })
    Check '[判据 3] 六类 default_selected=false 项均未被默认选择' ($defaultPlan.code -eq 0 -and $unexpected.Count -eq 0) ("误选: " + ($unexpected -join ','))

    Section '11. 反向判据 4：错误 PlanId 世界零改动'
    $d3d = Reset-Key 'd3dcache'
    $mismatchFile = New-TestFile (Join-Path $d3d 'mismatch.bin') 2048 0
    $d3dPlan = Get-Plan 'd3dcache'
    $mismatchRequest = 'req-mismatch-' + [guid]::NewGuid().ToString('N')
    $mismatch = Invoke-ApplyProcess 'd3dcache' 'plan:00000000000000000000000000000000' $mismatchRequest
    $mismatchReceipt = Join-Path $spaceHome "receipts\$mismatchRequest.json"
    Check '[判据 4] 错误 PlanId 返回 plan_mismatch' ($mismatch.code -eq 1 -and $mismatch.json.error.code -eq 'plan_mismatch') $mismatch.text
    Check '[判据 4] 错误 PlanId 未删除测试文件' (Test-Path -LiteralPath $mismatchFile -PathType Leaf) ''
    Check '[判据 4] 错误 PlanId 未产生完成收据' (-not (Test-Path -LiteralPath $mismatchReceipt)) ''

    Section '12. 反向判据 5/6：幂等重放与冲突'
    $chrome = Reset-Key 'chrome-cache'
    New-TestFile (Join-Path $chrome 'first.bin') 4096 0 | Out-Null
    $chromePlan = Get-Plan 'chrome-cache'
    $replayRequest = 'req-replay-' + [guid]::NewGuid().ToString('N')
    $firstApply = Invoke-ApplyProcess 'chrome-cache' $chromePlan.json.plan_id $replayRequest
    $afterReceiptFile = New-TestFile (Join-Path $chrome 'created-after-receipt.bin') 1024 0
    $secondApply = Invoke-ApplyProcess 'chrome-cache' $chromePlan.json.plan_id $replayRequest
    Check '[判据 5] 首次 apply 完成并写收据' ($firstApply.code -eq 0 -and $firstApply.json.status -eq 'done' -and $firstApply.json.receipt_written) $firstApply.text
    Check '[判据 5] 第二次返回 replayed' ($secondApply.code -eq 0 -and $secondApply.json.status -eq 'replayed' -and $secondApply.json.replayed) $secondApply.text
    Check '[判据 5] 重放没有删除后来新建的文件' (Test-Path -LiteralPath $afterReceiptFile -PathType Leaf) ''

    $edge = Reset-Key 'edge-cache'
    $edgeFile = New-TestFile (Join-Path $edge 'conflict.bin') 2048 0
    $edgePlan = Get-Plan 'edge-cache'
    $conflict = Invoke-ApplyProcess 'edge-cache' $edgePlan.json.plan_id $replayRequest
    Check '[判据 6] 同 RequestId 换 key 返回 idempotency_conflict' ($conflict.code -eq 1 -and $conflict.json.error.code -eq 'idempotency_conflict') $conflict.text
    Check '[判据 6] 幂等冲突未删除测试文件' (Test-Path -LiteralPath $edgeFile -PathType Leaf) ''

    Section '13. 反向判据 7：intent 不可写时 fail-closed'
    $thumbs = Reset-Key 'thumbs'
    $thumbFile = New-TestFile (Join-Path $thumbs 'thumbcache_test.db') 3072 0
    $thumbPlan = Get-Plan 'thumbs'
    $blockedHome = Join-Path $sandbox 'space-home-blocked-by-file'
    [System.IO.File]::WriteAllText($blockedHome, 'this file blocks directory creation')
    $env:OPEN365_SPACE_HOME = $blockedHome
    try {
        $blockedRequest = 'req-blocked-' + [guid]::NewGuid().ToString('N')
        $blocked = Invoke-ApplyProcess 'thumbs' $thumbPlan.json.plan_id $blockedRequest
        Check '[判据 7] intent 写失败返回 audit_write_failed' ($blocked.code -eq 1 -and $blocked.json.error.code -eq 'audit_write_failed') $blocked.text
        Check '[判据 7] fail-closed 保证测试文件一字节不动' ((Test-Path -LiteralPath $thumbFile) -and (Get-Item -LiteralPath $thumbFile).Length -eq 3072) ''
    } finally {
        $env:OPEN365_SPACE_HOME = $spaceHome
    }

    Section '14. 反向判据 8：占用文件产生 partial 与可见失败'
    $lockedDir = Reset-Key 'd3dcache'
    $freeFile = New-TestFile (Join-Path $lockedDir 'free.bin') 1024 0
    $lockedFile = New-TestFile (Join-Path $lockedDir 'locked.bin') 2048 0
    $lockedPlan = Get-Plan 'd3dcache'
    $handle = $null
    try {
        $handle = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $lockedApply = Invoke-ApplyProcess 'd3dcache' $lockedPlan.json.plan_id ('req-locked-' + [guid]::NewGuid().ToString('N'))
        $lockedItem = @($lockedApply.json.items)[0]
        Check '[判据 8] 占用文件令整体状态为 partial' ($lockedApply.code -eq 0 -and $lockedApply.json.status -eq 'partial' -and $lockedItem.status -eq 'partial') $lockedApply.text
        Check '[判据 8] 失败路径与原因可见' (@($lockedApply.json.failures).Count -ge 1 -and @($lockedItem.failures).Count -ge 1) $lockedApply.text
        Check '[判据 8] 可删文件已删、占用文件保留' (-not (Test-Path -LiteralPath $freeFile) -and (Test-Path -LiteralPath $lockedFile)) ''
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }

    Section '15. 反向判据 9：历史当时证据与当前观察分离'
    $historyNow = Invoke-CleanerJson @('history', '-Limit', '100')
    $historicalReplay = @($historyNow.json.receipts | Where-Object { $_.request_id -eq $replayRequest }) | Select-Object -First 1
    $currentChrome = Invoke-CleanerJson @('scan', '-Only', 'chrome-cache')
    $currentChromeItem = @($currentChrome.json.items)[0]
    Check '[判据 9] history 保留当时已释放的收据摘要' ($null -ne $historicalReplay -and $historicalReplay.total_freed_bytes -eq 4096) $historyNow.text
    Check '[判据 9] 当前 scan 独立显示后来新建的缓存' ($currentChromeItem.bytes -eq 1024 -and $currentChromeItem.files -eq 1) $currentChrome.text

    Section '16. 反向判据 10：损坏收据显式报告 orphan/warning'
    $receiptDir = Join-Path $spaceHome 'receipts'
    New-Item -ItemType Directory -Path $receiptDir -Force | Out-Null
    $brokenReceipt = Join-Path $receiptDir 'broken-receipt.json'
    [System.IO.File]::WriteAllText($brokenReceipt, '{ definitely-not-json')
    (Get-Item -LiteralPath $brokenReceipt).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddDays(-30)
    $historyBroken = Invoke-CleanerJson @('history', '-Limit', '1')
    $brokenOrphan = @($historyBroken.json.orphans | Where-Object { $_.file -eq 'broken-receipt.json' })
    Check '[判据 10] 即使有效摘要达到 Limit，旧损坏 JSON 仍出现在 orphans' ($brokenOrphan.Count -eq 1 -and @($historyBroken.json.receipts).Count -eq 1) $historyBroken.text
    Check '[判据 10] 损坏 JSON 同时产生 warning' (@($historyBroken.json.warnings).Count -ge 1) $historyBroken.text

    Section '17. win-update v1 只观察不执行'
    $updatePlan = Get-Plan 'win-update'
    $updateItem = @($updatePlan.json.items)[0]
    Check 'win-update plan 标注 execution_blocked' ($null -ne $updateItem.execution_blocked -and $updateItem.policy.executable -eq $false) $updatePlan.text
    $updateFile = Join-Path $script:ruleRoot 'win-update\update.bin'
    $updateApply = Invoke-ApplyProcess 'win-update' $updatePlan.json.plan_id ('req-update-' + [guid]::NewGuid().ToString('N'))
    Check 'win-update apply 记录 skipped_not_executable' ($updateApply.code -eq 0 -and @($updateApply.json.items)[0].status -eq 'skipped_not_executable') $updateApply.text
    Check 'win-update 测试文件未被删除' (Test-Path -LiteralPath $updateFile -PathType Leaf) ''

    Section '18. 反向判据 11：引擎沙箱兜底拒绝'
    $inet = Reset-Key 'inetcache'
    $sandboxFile = New-TestFile (Join-Path $inet 'sandbox.bin') 2048 0
    $sandboxPlan = Get-Plan 'inetcache'
    $sandboxRequest = 'req-sandbox-' + [guid]::NewGuid().ToString('N')
    $env:OPEN365_SANDBOX = '1'
    try {
        $sandboxApply = Invoke-ApplyProcess 'inetcache' $sandboxPlan.json.plan_id $sandboxRequest
        Check '[判据 11] OPEN365_SANDBOX=1 时引擎 apply 返回 sandbox_read_only' ($sandboxApply.code -eq 1 -and $sandboxApply.json.error.code -eq 'sandbox_read_only') $sandboxApply.text
        Check '[判据 11] 沙箱拒绝后测试文件不动' (Test-Path -LiteralPath $sandboxFile -PathType Leaf) ''
    } finally {
        Remove-Item Env:\OPEN365_SANDBOX -ErrorAction SilentlyContinue
    }
    # TODO 阶段2：注册 cleaner.apply 后，通过 action-core -Confirm 验证核心层仍拒绝 OPEN365_SANDBOX=1。

    # TODO 阶段3（判据 12）：GUI 静态绑定检查 cleaner.scan / cleaner.apply 均走 Action Core。
}
finally {
    Section '19. 清理自建沙盒并恢复环境变量'
    if ($null -eq $oldCleanerRoot) { Remove-Item Env:\OPEN365_CLEANER_ROOT -ErrorAction SilentlyContinue }
    else { $env:OPEN365_CLEANER_ROOT = $oldCleanerRoot }
    if ($null -eq $oldSpaceHome) { Remove-Item Env:\OPEN365_SPACE_HOME -ErrorAction SilentlyContinue }
    else { $env:OPEN365_SPACE_HOME = $oldSpaceHome }
    if ($null -eq $oldSandboxMode) { Remove-Item Env:\OPEN365_SANDBOX -ErrorAction SilentlyContinue }
    else { $env:OPEN365_SANDBOX = $oldSandboxMode }

    $resolvedTests = [System.IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
    $resolvedSandbox = [System.IO.Path]::GetFullPath($sandbox)
    if ($resolvedSandbox.StartsWith($resolvedTests, [System.StringComparison]::OrdinalIgnoreCase) -and
        (Test-Path -LiteralPath $resolvedSandbox)) {
        Remove-Item -LiteralPath $resolvedSandbox -Recurse -Force -ErrorAction SilentlyContinue
    }
    Write-Host '  自建沙盒已删除'
}

Section '测试结果'
Write-Host "  通过: $pass   失败: $fail" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
