<#
.SYNOPSIS
    Open365 C 盘空间治理引擎。

.DESCRIPTION
    用白名单规则观察空间对象，生成稳定计划，并以 intent/receipt 审计执行结果。
    scan、plan、history 只读；apply 写入前必须通过计划、幂等与审计闸门。
    保留旧 scan/clean CLI 入口，供尚未迁移的 GUI 与命令行继续使用。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('scan','plan','apply','history','clean','help')]
    [string]$Action = 'help',

    [switch]$Json,
    [switch]$Force,
    [string[]]$Only,
    [string]$Keys,
    [string]$PlanId,
    [string]$RequestId,
    [string]$RequestedBy,
    [int]$Limit = 20
)

$ErrorActionPreference = 'Stop'
$script:EngineFailed = $false
$script:CleanerRoot = $env:OPEN365_CLEANER_ROOT

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Get-CleanRules {
    $local = $env:LOCALAPPDATA
    $root = $script:CleanerRoot
    $windows = $env:WINDIR
    if ([string]::IsNullOrWhiteSpace($windows)) { $windows = $env:SystemRoot }
    if ([string]::IsNullOrWhiteSpace($windows) -and -not [string]::IsNullOrWhiteSpace([System.Environment]::SystemDirectory)) {
        $windows = [System.IO.Path]::GetDirectoryName([System.Environment]::SystemDirectory)
    }
    if ([string]::IsNullOrWhiteSpace($windows)) { $windows = 'C:\Windows' }

    $rules = @(
        [ordered]@{ key='win-temp'; name='Windows 临时文件'; kind='dir'; path="$windows\Temp"; owner='Windows'; lifecycle='expired-temp'; retention_days=1; risk='low'; default_selected=$true; recovery_mode='none'; why_safe='仅处理超过 1 天的 Windows 临时项。'; recovery_note='删除后无法还原原字节，请重新运行产生它的任务。'; executable=$true }
        [ordered]@{ key='user-temp'; name='用户临时文件'; kind='dir'; path=$env:TEMP; owner='当前用户/应用'; lifecycle='expired-temp'; retention_days=1; risk='low'; default_selected=$true; recovery_mode='none'; why_safe='仅处理超过 1 天的用户和应用临时项。'; recovery_note='删除后无法还原原字节，应用需要时会重新产生。'; executable=$true }
        [ordered]@{ key='prefetch'; name='预读取文件 (Prefetch)'; kind='dir'; path="$windows\Prefetch"; owner='Windows 性能子系统'; lifecycle='performance-state'; retention_days=30; risk='medium'; default_selected=$false; recovery_mode='regenerate'; why_safe='仅处理超过 30 天的预读取状态。'; recovery_note='Windows 会按需重新生成，短期启动可能略慢。'; executable=$true }
        [ordered]@{ key='thumbs'; name='缩略图缓存'; kind='dir'; path="$local\Microsoft\Windows\Explorer"; filter='thumbcache_*.db'; owner='Windows Explorer'; lifecycle='rebuildable-cache'; retention_days=0; risk='low'; default_selected=$true; recovery_mode='regenerate'; why_safe='缩略图是可重建的派生缓存。'; recovery_note='资源管理器会自动重建，首次浏览图片可能略慢。'; executable=$true }
        [ordered]@{ key='win-update'; name='Windows Update 下载残留'; kind='dir'; path="$windows\SoftwareDistribution\Download"; owner='Windows Update'; lifecycle='update-staging'; retention_days=$null; risk='high'; default_selected=$false; recovery_mode='re-download'; why_safe='v1 只观察并提示 Windows Update 暂存空间。'; recovery_note='需要时可重新下载，但这不等于系统回滚。'; executable=$false }
        [ordered]@{ key='cbs-logs'; name='系统组件日志 (CBS)'; kind='dir'; path="$windows\Logs\CBS"; filter='*.log'; owner='Windows Servicing'; lifecycle='diagnostic-evidence'; retention_days=30; risk='medium'; default_selected=$false; recovery_mode='none'; why_safe='仅处理超过 30 天的系统组件诊断日志。'; recovery_note='删除后会永久失去对应的诊断证据。'; executable=$true }
        [ordered]@{ key='inetcache'; name='网络临时文件缓存'; kind='dir'; path="$local\Microsoft\Windows\INetCache"; owner='Windows/当前用户'; lifecycle='rebuildable-cache'; retention_days=0; risk='low'; default_selected=$true; recovery_mode='regenerate'; why_safe='网络临时文件是可重建的派生缓存。'; recovery_note='系统或应用会按需重新下载和重建。'; executable=$true }
        [ordered]@{ key='crashdumps'; name='程序崩溃转储'; kind='dir'; path="$local\CrashDumps"; owner='崩溃应用/用户'; lifecycle='diagnostic-evidence'; retention_days=14; risk='medium'; default_selected=$false; recovery_mode='none'; why_safe='仅处理超过 14 天的程序崩溃转储。'; recovery_note='删除后会永久失去对应的调试证据。'; executable=$true }
        [ordered]@{ key='wer'; name='Windows 错误报告'; kind='dir'; path="$local\Microsoft\Windows\WER"; owner='Windows Error Reporting'; lifecycle='diagnostic-evidence'; retention_days=14; risk='medium'; default_selected=$false; recovery_mode='none'; why_safe='仅处理超过 14 天的 Windows 错误报告。'; recovery_note='删除后会永久失去对应的诊断证据。'; executable=$true }
        [ordered]@{ key='d3dcache'; name='DirectX 着色器缓存'; kind='dir'; path="$local\D3DSCache"; owner='GPU/应用'; lifecycle='rebuildable-cache'; retention_days=0; risk='low'; default_selected=$true; recovery_mode='regenerate'; why_safe='着色器缓存是可重建的派生数据。'; recovery_note='着色器会自动重建，首次运行游戏可能略慢。'; executable=$true }
        [ordered]@{ key='edge-cache'; name='Edge 浏览器缓存'; kind='dir'; path="$local\Microsoft\Edge\User Data\Default\Cache"; owner='Microsoft Edge'; lifecycle='rebuildable-cache'; retention_days=0; risk='low'; default_selected=$true; recovery_mode='regenerate'; why_safe='只处理 Edge 的缓存目录，不碰浏览数据。'; recovery_note='浏览器会按需重新下载和重建缓存。'; executable=$true }
        [ordered]@{ key='chrome-cache'; name='Chrome 浏览器缓存'; kind='dir'; path="$local\Google\Chrome\User Data\Default\Cache"; owner='Google Chrome'; lifecycle='rebuildable-cache'; retention_days=0; risk='low'; default_selected=$true; recovery_mode='regenerate'; why_safe='只处理 Chrome 的缓存目录，不碰浏览数据。'; recovery_note='浏览器会按需重新下载和重建缓存。'; executable=$true }
        [ordered]@{ key='firefox-cache'; name='Firefox 浏览器缓存'; kind='firefox'; path="$local\Mozilla\Firefox\Profiles"; owner='Mozilla Firefox'; lifecycle='rebuildable-cache'; retention_days=0; risk='low'; default_selected=$true; recovery_mode='regenerate'; why_safe='只处理 profile 下的缓存子目录，不碰书签、密码或偏好。'; recovery_note='浏览器会按需重新下载和重建缓存。'; executable=$true }
        [ordered]@{ key='recyclebin'; name='回收站'; kind='recyclebin'; path='shell:RecycleBinFolder'; owner='当前用户'; lifecycle='user-recovery-buffer'; retention_days=$null; risk='high'; default_selected=$false; recovery_mode='none'; why_safe='仅在用户明确选择时处理回收站。'; recovery_note='清空后文件不可恢复。'; executable=$true }
    )

    if (-not [string]::IsNullOrWhiteSpace($root)) {
        foreach ($rule in $rules) {
            $rule.path = Join-Path $root $rule.key
        }
    }
    return $rules
}

function Test-ItemExpired($item, $retentionDays) {
    if ($null -eq $retentionDays) { return $false }
    if ($retentionDays -le 0)     { return $true }
    return $item.LastWriteTime -lt (Get-Date).AddDays(-$retentionDays)
}

function Get-DirSize([string]$path, [string]$filter, $retentionDays) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) {
        return @{ bytes=[long]0; files=0; exists=$false }
    }

    [long]$bytes = 0
    $files = 0
    try {
        $items = if ($filter) {
            @(Get-ChildItem -LiteralPath $path -Filter $filter -Recurse -Force -File -ErrorAction SilentlyContinue)
        } else {
            @(Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue)
        }
        foreach ($item in $items) {
            if (Test-ItemExpired $item $retentionDays) {
                $bytes += [long]$item.Length
                $files++
            }
        }
    } catch { }
    return @{ bytes=$bytes; files=$files; exists=$true }
}

function Get-RecycleBinSize {
    [long]$bytes = 0
    $files = 0
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.NameSpace(10)
        foreach ($item in $bin.Items()) {
            $bytes += [long]$item.Size
            $files++
        }
    } catch { }
    return @{ bytes=$bytes; files=$files; exists=$true }
}

function Get-FirefoxProfilesRoot([string]$base) {
    $nested = Join-Path $base 'Profiles'
    if (Test-Path -LiteralPath $nested -PathType Container) { return $nested }
    return $base
}

function Get-FirefoxCacheDirs([string]$base) {
    $dirs = @()
    $profilesRoot = Get-FirefoxProfilesRoot $base
    if (-not (Test-Path -LiteralPath $profilesRoot -PathType Container)) { return $dirs }
    foreach ($profile in @(Get-ChildItem -LiteralPath $profilesRoot -Directory -Force -ErrorAction SilentlyContinue)) {
        foreach ($sub in @('cache2', 'startupCache', 'OfflineCache')) {
            $candidate = Join-Path $profile.FullName $sub
            if (Test-Path -LiteralPath $candidate -PathType Container) { $dirs += $candidate }
        }
    }
    return $dirs
}

function Get-FirefoxCacheSize([string]$base, $retentionDays) {
    [long]$bytes = 0
    $files = 0
    $exists = Test-Path -LiteralPath $base -PathType Container
    foreach ($dir in @(Get-FirefoxCacheDirs $base)) {
        $size = Get-DirSize $dir $null $retentionDays
        $bytes += [long]$size.bytes
        $files += [int]$size.files
    }
    return @{ bytes=$bytes; files=$files; exists=[bool]$exists }
}

function Clear-Dir([string]$path, [string]$filter, $retentionDays, [ref]$FailureSink) {
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return [long]0 }
    [long]$reported = 0
    $files = if ($filter) {
        @(Get-ChildItem -LiteralPath $path -Filter $filter -Recurse -Force -File -ErrorAction SilentlyContinue)
    } else {
        @(Get-ChildItem -LiteralPath $path -Recurse -Force -File -ErrorAction SilentlyContinue)
    }

    foreach ($file in $files) {
        if (-not (Test-ItemExpired $file $retentionDays)) { continue }
        try {
            $length = [long]$file.Length
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $reported += $length
        } catch {
            if ($null -ne $FailureSink) {
                $FailureSink.Value += [ordered]@{ path=$file.FullName; reason=$_.Exception.Message }
            }
        }
    }

    # 只清理由逐文件删除后已经为空的目录；含未过期文件的目录绝不会整棵删除。
    $dirs = @(Get-ChildItem -LiteralPath $path -Recurse -Force -Directory -ErrorAction SilentlyContinue |
        Sort-Object { $_.FullName.Length } -Descending)
    foreach ($dir in $dirs) {
        try {
            $children = @(Get-ChildItem -LiteralPath $dir.FullName -Force -ErrorAction Stop)
            if ($children.Count -eq 0) { Remove-Item -LiteralPath $dir.FullName -Force -ErrorAction Stop }
        } catch { }
    }
    return $reported
}

function Clear-FirefoxCache([string]$base, $retentionDays, [ref]$FailureSink) {
    [long]$reported = 0
    foreach ($dir in @(Get-FirefoxCacheDirs $base)) {
        $reported += Clear-Dir $dir $null $retentionDays $FailureSink
    }
    return $reported
}

function Clear-RecycleBin2([ref]$FailureSink) {
    $before = Get-RecycleBinSize
    try {
        Clear-RecycleBin -Force -ErrorAction Stop
    } catch {
        if ($null -ne $FailureSink) {
            $FailureSink.Value += [ordered]@{ path='shell:RecycleBinFolder'; reason=$_.Exception.Message }
        }
    }
    return [long]$before.bytes
}

function Format-Size([long]$bytes) {
    if ($bytes -ge 1GB) { return '{0:N2} GB' -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return '{0:N2} MB' -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return '{0:N2} KB' -f ($bytes / 1KB) }
    return "$bytes B"
}

function Get-PolicyObject($rule) {
    return [ordered]@{
        owner = $rule.owner
        lifecycle = $rule.lifecycle
        retention_days = $rule.retention_days
        risk = $rule.risk
        default_selected = [bool]$rule.default_selected
        recovery_mode = $rule.recovery_mode
        why_safe = $rule.why_safe
        recovery_note = $rule.recovery_note
        executable = [bool]$rule.executable
    }
}

function Get-Sha256Hex([string]$text) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
        $hash = $sha.ComputeHash($bytes)
        return (-join ($hash | ForEach-Object { $_.ToString('x2') }))
    } finally {
        $sha.Dispose()
    }
}

function Get-PolicyRevision($rules) {
    $normalized = @()
    foreach ($rule in @($rules | Sort-Object key)) {
        $policy = Get-PolicyObject $rule
        $normalized += [ordered]@{
            key = $rule.key
            owner = $policy.owner
            lifecycle = $policy.lifecycle
            retention_days = $policy.retention_days
            risk = $policy.risk
            default_selected = $policy.default_selected
            recovery_mode = $policy.recovery_mode
            why_safe = $policy.why_safe
            recovery_note = $policy.recovery_note
            executable = $policy.executable
        }
    }
    $serialized = $normalized | ConvertTo-Json -Depth 10 -Compress
    return 'pol:' + (Get-Sha256Hex $serialized).Substring(0, 16)
}

function Get-KeySelection($inputValue, $rules) {
    $parts = @()
    foreach ($value in @($inputValue)) {
        if ($null -eq $value) { continue }
        $parts += @(([string]$value).Split(','))
    }

    $clean = @()
    $hasBlank = $false
    foreach ($part in $parts) {
        $key = ([string]$part).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($key)) { $hasBlank = $true; continue }
        $clean += $key
    }

    $seen = @{}
    $duplicates = @()
    foreach ($key in $clean) {
        if ($seen.ContainsKey($key)) { $duplicates += $key } else { $seen[$key] = $true }
    }
    $known = @{}
    foreach ($rule in $rules) { $known[$rule.key] = $true }
    $unknown = @($clean | Where-Object { -not $known.ContainsKey($_) } | Select-Object -Unique)

    $unique = New-Object 'System.Collections.Generic.List[string]'
    foreach ($key in $seen.Keys) { $unique.Add([string]$key) }
    $unique.Sort([System.StringComparer]::Ordinal)
    $normalizedKeys = @($unique.ToArray())

    return [ordered]@{
        valid = (-not $hasBlank -and $clean.Count -gt 0 -and $duplicates.Count -eq 0 -and $unknown.Count -eq 0)
        keys = $normalizedKeys
        normalized = ($normalizedKeys -join ',')
        duplicates = @($duplicates)
        unknown = @($unknown)
        has_blank = $hasBlank
    }
}

function Get-PlanId([string]$policyRevision, [string]$normalizedKeys) {
    return 'plan:' + (Get-Sha256Hex ($policyRevision + '|' + $normalizedKeys)).Substring(0, 32)
}

function Get-RequestHash([string]$planId, [string]$normalizedKeys) {
    return (Get-Sha256Hex ($planId + '|' + $normalizedKeys)).Substring(0, 32)
}

function Get-RuleSize($rule) {
    if ($rule.kind -eq 'firefox') {
        return Get-FirefoxCacheSize $rule.path $rule.retention_days
    }
    if ($rule.kind -eq 'recyclebin') {
        if (-not [string]::IsNullOrWhiteSpace($script:CleanerRoot)) {
            return Get-DirSize $rule.path $null 0
        }
        return Get-RecycleBinSize
    }
    return Get-DirSize $rule.path $rule.filter $rule.retention_days
}

function Get-RuleObservation($rule) {
    $at = (Get-Date).ToUniversalTime().ToString('o')
    $size = Get-RuleSize $rule
    return [ordered]@{
        path = $rule.path
        exists = [bool]$size.exists
        bytes = [long]$size.bytes
        files = [int]$size.files
        observed_at = $at
    }
}

function Get-ObservationItem($rule) {
    $observation = Get-RuleObservation $rule
    return [ordered]@{
        key = $rule.key
        name = $rule.name
        bytes = [long]$observation.bytes
        files = [int]$observation.files
        human = Format-Size ([long]$observation.bytes)
        path = $observation.path
        observation = $observation
        policy = Get-PolicyObject $rule
    }
}

function Invoke-Scan([object[]]$SelectedRules) {
    $rules = if ($null -ne $SelectedRules) { @($SelectedRules) } else { @(Get-CleanRules) }
    $allRules = @(Get-CleanRules)
    $policyRevision = Get-PolicyRevision $allRules
    $observedAt = (Get-Date).ToUniversalTime().ToString('o')
    $items = @()
    [long]$total = 0
    foreach ($rule in $rules) {
        $item = Get-ObservationItem $rule
        $items += $item
        $total += [long]$item.bytes
    }
    return [ordered]@{
        spec = 'open365.space-governance/0.1'
        kind = 'space.observation'
        observation_id = 'obs:' + [guid]::NewGuid().ToString('N')
        observed_at = $observedAt
        policy_revision = $policyRevision
        items = $items
        total_bytes = $total
        total_human = Format-Size $total
    }
}

function Show-Scan($scan) {
    Write-Host ''
    Write-Host '  ========== C 盘空间观察结果 ==========' -ForegroundColor White
    Write-Host ''
    Write-Host ('  {0,-26} {1,12} {2,8}' -f '类别', '可治理', '文件数')
    Write-Host '  ---------------------------------------------------'
    foreach ($item in $scan.items) {
        $color = if ($item.bytes -gt 0) { 'Gray' } else { 'DarkGray' }
        Write-Host ('  {0,-24} {1,12} {2,8}' -f $item.name, $item.human, $item.files) -ForegroundColor $color
    }
    Write-Host '  ---------------------------------------------------'
    Write-Host ('  {0,-24} {1,12}' -f '合计可治理', $scan.total_human) -ForegroundColor Green
    Write-Host ''
}

function New-EngineError([string]$code, [string]$message) {
    $script:EngineFailed = $true
    return [ordered]@{ ok=$false; error=[ordered]@{ code=$code; message=$message } }
}

function Get-RulesForKeys($rules, [string[]]$selectedKeys) {
    $selected = @()
    foreach ($key in $selectedKeys) {
        $selected += @($rules | Where-Object { $_.key -eq $key })
    }
    return $selected
}

function Invoke-Plan {
    $rules = @(Get-CleanRules)
    $policyRevision = Get-PolicyRevision $rules
    $selectedRules = @()
    $normalizedKeys = ''

    if (-not [string]::IsNullOrWhiteSpace($Keys)) {
        $selection = Get-KeySelection $Keys $rules
        if (-not $selection.valid) {
            return New-EngineError 'invalid_keys' 'Keys 必须是非空、已知且不重复的 key 集合。'
        }
        $normalizedKeys = $selection.normalized
        $selectedRules = @(Get-RulesForKeys $rules $selection.keys)
    } else {
        foreach ($rule in $rules) {
            if (-not $rule.default_selected) { continue }
            $observation = Get-RuleObservation $rule
            if ($observation.bytes -gt 0) { $selectedRules += $rule }
        }
        $selection = Get-KeySelection (($selectedRules | ForEach-Object { $_.key }) -join ',') $rules
        if ($selectedRules.Count -gt 0) { $normalizedKeys = $selection.normalized }
    }

    $items = @()
    [long]$estimated = 0
    $risk = [ordered]@{ low=0; medium=0; high=0 }
    $containsIrreversible = $false
    foreach ($rule in $selectedRules) {
        $item = Get-ObservationItem $rule
        if (-not $rule.executable) {
            $item.execution_blocked = 'v1 未实现安全的 Windows Update 服务状态与系统 API 处理，因此只观察不执行。'
        }
        $items += $item
        $estimated += [long]$item.bytes
        $risk[$rule.risk] = [int]$risk[$rule.risk] + 1
        if ($rule.recovery_mode -eq 'none' -or $rule.recovery_mode -eq 're-download') {
            $containsIrreversible = $true
        }
    }

    return [ordered]@{
        spec = 'open365.space-governance/0.1'
        kind = 'space.governance.plan'
        plan_id = Get-PlanId $policyRevision $normalizedKeys
        policy_revision = $policyRevision
        created_at = (Get-Date).ToUniversalTime().ToString('o')
        requested_by = $RequestedBy
        keys = $normalizedKeys
        items = $items
        estimated_bytes = $estimated
        estimated_human = Format-Size $estimated
        risk_summary = $risk
        contains_irreversible = $containsIrreversible
        requires_human_confirmation = $true
    }
}

function Get-SpaceHome {
    if (-not [string]::IsNullOrWhiteSpace($env:OPEN365_SPACE_HOME)) { return $env:OPEN365_SPACE_HOME }
    return Join-Path $env:LOCALAPPDATA 'Open365\space-governance'
}

function Write-AuditJson([string]$path, $value) {
    $tempPath = $null
    try {
        $parent = Split-Path -Parent $path
        if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        $tempPath = Join-Path $parent ('.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $text = $value | ConvertTo-Json -Depth 10 -Compress
        [System.IO.File]::WriteAllText($tempPath, $text)
        Move-Item -LiteralPath $tempPath -Destination $path -Force -ErrorAction Stop
        return $true
    } catch {
        if ($tempPath -and (Test-Path -LiteralPath $tempPath)) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
        return $false
    }
}

function Read-Receipt([string]$path) {
    $raw = [System.IO.File]::ReadAllText($path)
    return $raw | ConvertFrom-Json -ErrorAction Stop
}

function Invoke-RuleClear($rule, [ref]$FailureSink) {
    if ($rule.kind -eq 'firefox') {
        return Clear-FirefoxCache $rule.path $rule.retention_days $FailureSink
    }
    if ($rule.kind -eq 'recyclebin') {
        if (-not [string]::IsNullOrWhiteSpace($script:CleanerRoot)) {
            return Clear-Dir $rule.path $null 0 $FailureSink
        }
        return Clear-RecycleBin2 $FailureSink
    }
    return Clear-Dir $rule.path $rule.filter $rule.retention_days $FailureSink
}

function Invoke-Apply {
    if ($env:OPEN365_SANDBOX -eq '1') {
        return New-EngineError 'sandbox_read_only' 'OPEN365_SANDBOX=1，写动作已拒绝。'
    }

    $rules = @(Get-CleanRules)
    $selection = Get-KeySelection $Keys $rules
    if (-not $selection.valid -or [string]::IsNullOrWhiteSpace($RequestId) -or
        $RequestId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$') {
        return New-EngineError 'invalid_keys' 'Keys 必须非空、已知且不重复；RequestId 必须是安全的非空标识。'
    }

    $policyRevision = Get-PolicyRevision $rules
    $expectedPlanId = Get-PlanId $policyRevision $selection.normalized
    if ($PlanId -ne $expectedPlanId) {
        return New-EngineError 'plan_mismatch' 'PlanId 与当前策略版本或 key 集合不一致。'
    }

    $requestHash = Get-RequestHash $expectedPlanId $selection.normalized
    $spaceHome = Get-SpaceHome
    $receiptPath = Join-Path (Join-Path $spaceHome 'receipts') ($RequestId + '.json')
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) {
        try {
            $existing = Read-Receipt $receiptPath
        } catch {
            return New-EngineError 'audit_write_failed' '已有收据无法读取，拒绝重复执行。'
        }
        if ($existing.request_hash -ne $requestHash) {
            return New-EngineError 'idempotency_conflict' '同一 RequestId 已用于不同请求。'
        }
        $existing.status = 'replayed'
        if ($existing.PSObject.Properties['replayed']) { $existing.replayed = $true }
        else { $existing | Add-Member -NotePropertyName replayed -NotePropertyValue $true }
        return $existing
    }

    $selectedRules = @(Get-RulesForKeys $rules $selection.keys)
    $intentPath = Join-Path (Join-Path $spaceHome 'intents') ($RequestId + '.json')
    $intent = [ordered]@{
        spec = 'open365.space-governance/0.1'
        kind = 'space.governance.intent'
        request_id = $RequestId
        request_hash = $requestHash
        plan_id = $expectedPlanId
        policy_revision = $policyRevision
        requested_by = $RequestedBy
        keys = $selection.normalized
        created_at = (Get-Date).ToUniversalTime().ToString('o')
    }
    if (-not (Write-AuditJson $intentPath $intent)) {
        return New-EngineError 'audit_write_failed' '无法写入执行意图，未删除任何内容。'
    }

    $startedAt = (Get-Date).ToUniversalTime().ToString('o')
    $itemResults = @()
    $allFailures = @()
    [long]$totalFreed = 0
    foreach ($rule in $selectedRules) {
        $before = Get-RuleObservation $rule
        if (-not $rule.executable) {
            $itemResults += [ordered]@{
                key=$rule.key; name=$rule.name; status='skipped_not_executable'
                execution_blocked='v1 未实现安全的 Windows Update 服务状态与系统 API 处理。'
                before=$before; after=$before; reported_bytes=[long]0; freed_bytes=[long]0
                failures=@(); policy=(Get-PolicyObject $rule)
            }
            continue
        }

        $failures = @()
        [long]$reported = Invoke-RuleClear $rule ([ref]$failures)
        $after = Get-RuleObservation $rule
        [long]$freed = [long]$before.bytes - [long]$after.bytes
        if ($freed -lt 0) { $freed = 0 }
        $totalFreed += $freed

        if ($after.bytes -gt 0 -and $failures.Count -eq 0) {
            $failures += [ordered]@{ path=$rule.path; reason='post_observation_remaining' }
        }
        $status = 'done'
        if ($failures.Count -gt 0) {
            if ($freed -gt 0) { $status = 'partial' } else { $status = 'failed' }
        }
        foreach ($failure in $failures) {
            $allFailures += [ordered]@{ key=$rule.key; path=$failure.path; reason=$failure.reason }
        }
        $itemResults += [ordered]@{
            key=$rule.key; name=$rule.name; status=$status
            before=$before; after=$after; reported_bytes=$reported; freed_bytes=$freed
            failures=@($failures); policy=(Get-PolicyObject $rule)
        }
    }

    $statuses = @($itemResults | ForEach-Object { $_.status })
    $overall = 'done'
    if (@($statuses | Where-Object { $_ -eq 'partial' -or $_ -eq 'skipped_not_executable' }).Count -gt 0) {
        $overall = 'partial'
    }
    $failedCount = @($statuses | Where-Object { $_ -eq 'failed' }).Count
    if ($failedCount -gt 0) {
        if ($failedCount -eq $statuses.Count) { $overall = 'failed' } else { $overall = 'partial' }
    }

    $receipt = [ordered]@{
        spec = 'open365.space-governance/0.1'
        kind = 'space.governance.receipt'
        request_id = $RequestId
        request_hash = $requestHash
        plan_id = $expectedPlanId
        policy_revision = $policyRevision
        requested_by = $RequestedBy
        keys = $selection.normalized
        started_at = $startedAt
        completed_at = (Get-Date).ToUniversalTime().ToString('o')
        status = $overall
        replayed = $false
        items = $itemResults
        failures = $allFailures
        total_freed_bytes = $totalFreed
        total_freed_human = Format-Size $totalFreed
        intent_path = $intentPath
        receipt_path = $receiptPath
        receipt_written = $true
        warnings = @()
    }
    if (-not (Write-AuditJson $receiptPath $receipt)) {
        $receipt.receipt_written = $false
        $receipt.warnings += '最终收据写入失败；执行结果仅存在于本次返回值中。'
    }
    return $receipt
}

function Invoke-History {
    $effectiveLimit = $Limit
    if ($effectiveLimit -lt 1) { $effectiveLimit = 1 }
    if ($effectiveLimit -gt 100) { $effectiveLimit = 100 }
    $receiptDir = Join-Path (Get-SpaceHome) 'receipts'
    $summaries = @()
    $orphans = @()
    $warnings = @()
    if (Test-Path -LiteralPath $receiptDir -PathType Container) {
        $files = @(Get-ChildItem -LiteralPath $receiptDir -Filter '*.json' -File -Force -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending)
        foreach ($file in $files) {
            try {
                $receipt = Read-Receipt $file.FullName
                if ([string]::IsNullOrWhiteSpace([string]$receipt.request_id) -or
                    [string]::IsNullOrWhiteSpace([string]$receipt.completed_at)) {
                    throw '收据缺少 request_id 或 completed_at。'
                }
                if ($summaries.Count -lt $effectiveLimit) {
                    $summaries += [ordered]@{
                        request_id=$receipt.request_id; plan_id=$receipt.plan_id
                        policy_revision=$receipt.policy_revision; requested_by=$receipt.requested_by
                        keys=$receipt.keys; completed_at=$receipt.completed_at; status=$receipt.status
                        total_freed_bytes=[long]$receipt.total_freed_bytes
                        total_freed_human=$receipt.total_freed_human
                        receipt_path=$file.FullName
                    }
                }
            } catch {
                $orphans += [ordered]@{ file=$file.Name; path=$file.FullName; reason=$_.Exception.Message }
                $warnings += "损坏或不完整的收据未计入历史：$($file.Name)"
            }
        }
    }
    return [ordered]@{
        spec='open365.space-governance/0.1'
        kind='space.governance.history'
        generated_at=(Get-Date).ToUniversalTime().ToString('o')
        limit=$effectiveLimit
        receipts=$summaries
        orphans=$orphans
        warnings=$warnings
    }
}

function Invoke-LegacyClean {
    $rules = @(Get-CleanRules)
    if ($Only) {
        $legacySelection = Get-KeySelection $Only $rules
        $rules = @(Get-RulesForKeys $rules $legacySelection.keys)
    }
    $scan = Invoke-Scan $rules
    $cleaned = @()
    [long]$totalFreed = 0
    foreach ($rule in $rules) {
        $info = @($scan.items | Where-Object { $_.key -eq $rule.key }) | Select-Object -First 1
        if ($null -eq $info -or $info.bytes -eq 0 -or -not $rule.executable) { continue }
        if (-not $Force -and -not $Json) {
            $answer = Read-Host "  清理 [$($rule.name)] 可释放 $($info.human)？(Y/n)"
            if ($answer -and $answer -notmatch '^[Yy]') { continue }
        }
        $failures = @()
        [long]$reported = Invoke-RuleClear $rule ([ref]$failures)
        $after = Get-RuleObservation $rule
        [long]$freed = [long]$info.bytes - [long]$after.bytes
        if ($freed -lt 0) { $freed = 0 }
        $totalFreed += $freed
        $cleaned += [ordered]@{ key=$rule.key; name=$rule.name; freed_bytes=$freed; freed_human=(Format-Size $freed); reported_bytes=$reported; failures=@($failures) }
        if (-not $Json) { Write-Host "    [OK] $($rule.name) 已清理 $(Format-Size $freed)" -ForegroundColor Green }
    }
    return [ordered]@{ cleaned=$cleaned; total_freed_bytes=$totalFreed; total_freed_human=(Format-Size $totalFreed) }
}

function Get-HelpObject {
    return [ordered]@{
        name='Open365 C 盘空间治理引擎'
        actions=@('scan','plan','apply','history','clean','help')
        usage='cleaner.ps1 <action> [-Json] [-Keys key1,key2] [-PlanId id] [-RequestId id]'
        test_hooks=[ordered]@{
            OPEN365_CLEANER_ROOT='测试专用：把全部 14 条规则重定向到自建根目录。'
            OPEN365_SPACE_HOME='测试专用：覆盖 intents/receipts 的本境目录。'
        }
    }
}

$output = $null
switch ($Action) {
    'scan' {
        $scanRules = $null
        if ($Only) {
            $all = @(Get-CleanRules)
            $selected = Get-KeySelection $Only $all
            $scanRules = @(Get-RulesForKeys $all $selected.keys)
        }
        $output = Invoke-Scan $scanRules
        if (-not $Json) { Show-Scan $output }
    }
    'plan' { $output = Invoke-Plan }
    'apply' { $output = Invoke-Apply }
    'history' { $output = Invoke-History }
    'clean' { $output = Invoke-LegacyClean }
    'help' {
        $output = Get-HelpObject
        if (-not $Json) {
            Write-Host @"
Open365 C 盘空间治理引擎

用法: cleaner.ps1 <scan|plan|apply|history|clean|help> [-Json]
  scan       只读观察；保留旧 items[].bytes/files/human/path 字段
  plan       只读生成计划：-Keys key1,key2 -RequestedBy source
  apply      执行计划：-Keys ... -PlanId ... -RequestId ...
  history    只读查看最近收据：-Limit 20（最大 100）
  clean      旧兼容入口：-Force -Only key1,key2

测试专用环境变量：
  OPEN365_CLEANER_ROOT  将全部规则重定向到自建测试根目录
  OPEN365_SPACE_HOME    覆盖 intents/receipts 测试目录
"@
        }
    }
}

if ($Json -and $null -ne $output) {
    $output | ConvertTo-Json -Depth 10 -Compress
}

if ($script:EngineFailed) { exit 1 }
