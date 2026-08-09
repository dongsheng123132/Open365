<#
.SYNOPSIS
    Open365 动作核心 (Action Core) —— ActionParity 0.5.0 / 影核协议实现。

.DESCRIPTION
    一个动作，多个界面：GUI、CLI、AI 调用的都是这里注册的同一个动作身份。
    本文件不实现业务逻辑，业务永远在 engine/*.ps1 里；动作核心负责

      1) 发现     —— list / describe / manifest
      2) 校验     —— 按 input_schema 拒绝非法输入（0 毫秒拒绝，不进引擎）
      3) 闸门     —— 非只读动作默认拒绝执行，必须显式 -Confirm
      4) 执行     —— 调用唯一规范实现，返回稳定 JSON 信封
      5) 自证     —— verify：无界面跑通全部只读动作 + 检查各界面绑定

    依赖方向只有一个：core -> engine。引擎之间依旧零引用。

.NOTES
    退出码：0 成功 / 1 动作或校验失败 / 2 用法错误 / 3 被权限闸门拒绝。
    stdout 只放结果数据，stderr 放进度与诊断（-Json 时 stdout 必是单行 JSON）。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'describe', 'manifest', 'export', 'run', 'verify', 'bindings', 'help')]
    [string]$Command = 'help',

    [Parameter(Position = 1)]
    [string]$Target,

    [switch]$Json,
    [string]$InputJson,        # 动作输入（JSON 字符串）
    [string]$InputFile,        # 动作输入（JSON 文件）
    [ValidatePattern('^[A-Za-z0-9._:-]{1,128}$')]
    [string]$ExecutionId,      # 调用方生成的执行 ID；核心原样保留，供跨界面证据关联
    [switch]$Confirm,          # 执行非只读动作的显式确认
    [switch]$WriteManifest,    # manifest：直接写回根目录 action-parity.json
    [switch]$Check             # manifest：只检查生成结果是否漂移
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

# 输出编码必须由脚本自己钉死：否则被 -File 直接调用时 stdout 走系统代码页（中文 Windows 是 GBK），
# 调用方按 UTF-8 解析 JSON 会直接报错。AI 是主要调用方，这一行不能省。
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8
} catch { }

$script:Root = Split-Path $PSScriptRoot -Parent
$script:EngineDir = Join-Path $script:Root 'engine'
$script:Protocol = 'action-parity/core@0.5'
$script:SpecVersion = '0.5.0'
$script:RequestExecutionId = if ($ExecutionId) { $ExecutionId } else { [guid]::NewGuid().ToString() }

. (Join-Path $PSScriptRoot 'registry.ps1')

# ---------- 输出小工具 ----------

function Write-Note([string]$msg) {
    # 诊断一律走 stderr，保证 -Json 时 stdout 干净可解析
    if (-not $Json) { [Console]::Error.WriteLine("  $msg") }
}

function Out-Json($obj) {
    $obj | ConvertTo-Json -Depth 24 -Compress
}

function New-Envelope {
    param([string]$ActionId, [bool]$Ok, $Output, $ErrorObj, [int]$DurationMs, $Effects)
    $env = [ordered]@{
        protocol     = $script:Protocol
        spec_version = $script:SpecVersion
        ok           = $Ok
        action_id    = $ActionId
        execution_id = $script:RequestExecutionId
        started_at   = (Get-Date).ToString('s')
        duration_ms  = $DurationMs
    }
    if ($Effects) { $env['effects'] = $Effects }
    if ($Ok) { $env['output'] = $Output } else { $env['error'] = $ErrorObj }
    return $env
}

function New-ActionError([string]$Code, [string]$Message, $Details) {
    $e = [ordered]@{ code = $Code; message = $Message }
    if ($null -ne $Details) { $e['details'] = $Details }
    return $e
}

function Exit-WithEnvelope($envelope, [int]$Code) {
    if ($Json) {
        Out-Json $envelope
    } else {
        if ($envelope.ok) {
            Write-Host "  [OK] $($envelope.action_id)  ($($envelope.duration_ms) ms)" -ForegroundColor Green
            if ($envelope.Contains('output')) { $envelope.output | ConvertTo-Json -Depth 12 }
        } else {
            Write-Host "  [FAIL] $($envelope.action_id): $($envelope.error.code) — $($envelope.error.message)" -ForegroundColor Red
        }
    }
    exit $Code
}

# ---------- 注册表访问 ----------

function Get-Registry { Get-Open365ActionRegistry }

function Get-ActionOrFail([string]$id) {
    if (-not $id) {
        Exit-WithEnvelope (New-Envelope -ActionId '' -Ok $false -ErrorObj (New-ActionError 'usage_error' '缺少 Action ID。用法: action-core.ps1 run <action-id>' $null) -DurationMs 0) 2
    }
    $a = Get-Registry | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $a) {
        $known = (Get-Registry | ForEach-Object { $_.id }) -join ', '
        Exit-WithEnvelope (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'unknown_action' "未注册的 Action ID: $id" @{ known = $known }) -DurationMs 0) 2
    }
    return $a
}

# ---------- 公开清单（由注册表生成，绝不手写） ----------

function Strip-InternalFields($action) {
    $public = [ordered]@{
        id          = $action.id
        title       = $action.title
        description = $action.description
    }
    if ($action.Contains('tags')) { $public['tags'] = $action.tags }
    $public['input_schema'] = $action.input_schema
    $public['output_schema'] = $action.output_schema
    $public['effects'] = $action.effects
    $public['execution'] = $action.execution
    $public['bindings'] = $action.bindings
    if ($action.Contains('parity_exceptions')) { $public['parity_exceptions'] = $action.parity_exceptions }
    return $public
}

function New-Manifest {
    [ordered]@{
        '$schema'           = 'https://raw.githubusercontent.com/dongsheng123132/action-parity/v0.5.0/schema/action-parity.schema.json'
        spec_version        = $script:SpecVersion
        application         = (Get-Open365Application)
        conformance_targets = @('AP-1', 'AP-2')
        surfaces            = (Get-Open365Surfaces)
        actions             = @(Get-Registry | ForEach-Object { Strip-InternalFields $_ })
        state               = (Get-Open365StateContract)
        generated_from      = [ordered]@{
            generator = 'Open365/core/action-core.ps1'
            revision  = 'core/registry.ps1'
        }
    }
}

function New-RegistryBundle {
    $manifest = New-Manifest
    $cliActions = @($manifest.actions | ForEach-Object {
        [ordered]@{
            id            = $_.id
            title         = $_.title
            description   = $_.description
            input_schema  = $_.input_schema
            output_schema = $_.output_schema
            effects       = $_.effects
        }
    })
    [ordered]@{
        format   = 'action-parity.registry-bundle/v1'
        manifest = $manifest
        cli_help = [ordered]@{
            format      = 'action-parity.cli-help/v1'
            application = $manifest.application
            invocation  = 'powershell -File core/action-core.ps1 run <action-id> -InputFile <json-file> -Json'
            actions     = $cliActions
        }
        # Open365 目前没有 MCP Surface。空数组是事实，不生成不存在的工具。
        mcp_tools = [ordered]@{ tools = @() }
    }
}

function Get-ManifestPath { Join-Path $script:Root 'action-parity.json' }

function Format-ManifestJson($manifest) {
    # 固定缩进 + 末尾换行，保证"生成结果 == 仓库文件"可以按字节比较
    ($manifest | ConvertTo-Json -Depth 24) -replace "`r`n", "`n"
}

# ---------- 最小 JSON Schema 校验（够用即可，不引入依赖） ----------

function Test-Type($value, $type) {
    $types = @($type)
    foreach ($t in $types) {
        switch ($t) {
            # 注意：不能用 -is [psobject] 判断对象——PS 5.1 里几乎所有值都能匹配它
            'object'  { if ($value -is [hashtable] -or $value -is [System.Collections.Specialized.OrderedDictionary] -or $value -is [System.Management.Automation.PSCustomObject]) { return $true } }
            'array'   { if ($value -is [array]) { return $true } }
            'string'  { if ($value -is [string]) { return $true } }
            'integer' { if ($value -is [int] -or $value -is [long]) { return $true } }
            'number'  { if ($value -is [int] -or $value -is [long] -or $value -is [double] -or $value -is [decimal]) { return $true } }
            'boolean' { if ($value -is [bool]) { return $true } }
            'null'    { if ($null -eq $value) { return $true } }
        }
    }
    return $false
}

# 注意：PowerShell 每经过一次 return 就把数组展开一层，空数组因此退化成 $null——
# 那会让 "problems": [] 这类合法输出被误判成类型错误。逗号运算符只能包一层，
# 所以下面两个函数必须自己在 return 处包，不能再套一层辅助函数。
function Get-PropertyNames($obj) {
    if ($null -eq $obj) { return ,@() }
    if ($obj -is [hashtable] -or $obj -is [System.Collections.Specialized.OrderedDictionary]) { return ,@($obj.Keys) }
    return ,@($obj.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-PropertyValue($obj, [string]$name) {
    if ($null -eq $obj) { return $null }
    $val = $null
    if ($obj -is [hashtable] -or $obj -is [System.Collections.Specialized.OrderedDictionary]) {
        $val = $obj[$name]
    } else {
        $p = $obj.PSObject.Properties | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($p) { $val = $p.Value }
    }
    if ($val -is [array]) { return ,$val }
    return $val
}

function Test-AgainstSchema($value, $schema, [string]$path) {
    $errors = @()
    if (-not $schema) { return $errors }

    if ($schema.Contains('type')) {
        if (-not (Test-Type $value $schema['type'])) {
            $errors += "$path 类型应为 $(@($schema['type']) -join '|')"
            return $errors     # 类型不对就没必要继续挖
        }
    }
    if ($schema.Contains('minLength') -and $value -is [string]) {
        if ($value.Length -lt [int]$schema['minLength']) { $errors += "$path 长度小于 $($schema['minLength'])" }
    }
    if ($schema.Contains('required')) {
        $names = Get-PropertyNames $value
        foreach ($r in @($schema['required'])) {
            if ($names -notcontains $r) { $errors += "$path 缺少必需字段 '$r'" }
        }
    }
    if ($schema.Contains('properties')) {
        foreach ($k in @($schema['properties'].Keys)) {
            $names = Get-PropertyNames $value
            if ($names -contains $k) {
                $errors += Test-AgainstSchema (Get-PropertyValue $value $k) $schema['properties'][$k] "$path.$k"
            }
        }
    }
    if ($schema.Contains('additionalProperties') -and $schema['additionalProperties'] -eq $false) {
        $allowed = @()
        if ($schema.Contains('properties')) { $allowed = @($schema['properties'].Keys) }
        foreach ($n in (Get-PropertyNames $value)) {
            if ($allowed -notcontains $n) { $errors += "$path 出现未声明字段 '$n'" }
        }
    }
    return $errors
}

# ---------- 输入解析 ----------

function Resolve-Input {
    $raw = $null
    if ($InputFile) {
        if (-not (Test-Path -LiteralPath $InputFile)) {
            Exit-WithEnvelope (New-Envelope -ActionId $Target -Ok $false -ErrorObj (New-ActionError 'usage_error' "输入文件不存在: $InputFile" $null) -DurationMs 0) 2
        }
        $raw = Get-Content -LiteralPath $InputFile -Raw -Encoding UTF8
    } elseif ($InputJson) {
        $raw = $InputJson
    }
    if (-not $raw -or $raw.Trim().Length -eq 0) { return @{} }
    try {
        $obj = $raw | ConvertFrom-Json
    } catch {
        Exit-WithEnvelope (New-Envelope -ActionId $Target -Ok $false -ErrorObj (New-ActionError 'invalid_input' "输入不是合法 JSON: $($_.Exception.Message)" $null) -DurationMs 0) 1
    }
    return $obj
}

# ---------- 执行 ----------

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-PsLiteral([string]$v) {
    # PowerShell 单引号字面量：内部 ' 翻倍；顺手掐掉双引号，防止拆掉外层 -Command
    return "'" + ($v -replace "'", "''").Replace('"', '') + "'"
}

function Invoke-EngineAction($action, $inputObj) {
    $enginePath = Join-Path $script:EngineDir $action.invoke.engine
    if (-not (Test-Path -LiteralPath $enginePath)) {
        throw "规范实现缺失: $enginePath"
    }

    # 强制子进程用 UTF-8 输出，否则中文 JSON 在 GBK 控制台上会变成乱码
    $inner = '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; & ' + (Quote-PsLiteral $enginePath) + ' ' + $action.invoke.action
    foreach ($p in @($action.params)) {
        $v = Get-PropertyValue $inputObj $p.name
        if ($null -ne $v -and "$v".Length -gt 0) { $inner += ' ' + $p.arg + ' ' + (Quote-PsLiteral "$v") }
    }
    $inner += ' -Json'

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -Command "' + $inner + '"'
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8

    $proc = [System.Diagnostics.Process]::Start($psi)
    # 两个流都必须异步抽干：只读一个会把另一个的管道缓冲写满，父子进程互相等死
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timeout = [int]$action.execution.timeout_ms
    if (-not $proc.WaitForExit($timeout)) {
        try { $proc.Kill() } catch { }
        throw "引擎超时（超过 $timeout ms），已终止子进程"
    }
    $text = ($outTask.Result).Trim()
    $err = ($errTask.Result).Trim()
    if ($proc.ExitCode -ne 0) {
        $why = if ($err) { $err } elseif ($text) { $text } else { '无输出' }
        throw "引擎退出码 $($proc.ExitCode): $why"
    }
    if (-not $text) { throw '引擎没有输出 JSON（可能该动作未实现 -Json）' }
    try {
        return ($text | ConvertFrom-Json)
    } catch {
        throw "引擎输出不是合法 JSON: $text"
    }
}

function Invoke-ActionById([string]$id, $inputObj, [bool]$Confirmed) {
    $action = Get-ActionOrFail $id
    $sw = [Diagnostics.Stopwatch]::StartNew()

    # 1) 输入校验（不合法就 0 毫秒拒绝，不进引擎）
    $errs = @(Test-AgainstSchema $inputObj $action.input_schema 'input')
    if ($errs.Count -gt 0) {
        return @{ code = 1; envelope = (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'invalid_input' '输入不符合 input_schema' $errs) -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
    }

    # 2) 权限闸门：非只读动作默认拒绝
    if ($action.effects.class -ne 'read') {
        if ($env:OPEN365_SANDBOX -eq '1') {
            return @{ code = 3; envelope = (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'sandbox_read_only' 'OPEN365_SANDBOX=1 时只允许只读动作' $null) -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
        }
        if (-not $Confirmed) {
            return @{ code = 3; envelope = (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'confirmation_required' "动作 $id 会改动系统（class=$($action.effects.class)），必须显式 -Confirm" $null) -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
        }
        if ($action.Contains('requires_admin') -and $action.requires_admin -and -not (Test-IsAdmin)) {
            return @{ code = 3; envelope = (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'admin_required' "动作 $id 需要管理员权限" $null) -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
        }
    }

    # 3) 调用唯一规范实现
    try {
        $out = Invoke-EngineAction $action $inputObj
    } catch {
        return @{ code = 1; envelope = (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'execution_failed' $_.Exception.Message $null) -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
    }

    # 4) 输出契约校验：引擎漂移必须当场暴露，而不是让界面自己猜
    $oerrs = @(Test-AgainstSchema $out $action.output_schema 'output')
    if ($oerrs.Count -gt 0) {
        return @{ code = 1; envelope = (New-Envelope -ActionId $id -Ok $false -ErrorObj (New-ActionError 'output_contract_violation' '引擎输出不符合 output_schema' $oerrs) -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
    }

    return @{ code = 0; envelope = (New-Envelope -ActionId $id -Ok $true -Output $out -DurationMs $sw.ElapsedMilliseconds -Effects $action.effects) }
}

# ---------- 绑定检查（不需要窗口） ----------

function Test-Bindings {
    $guiSource = ''
    Get-ChildItem -LiteralPath (Join-Path $script:Root 'gui') -Filter '*.cs' -ErrorAction SilentlyContinue |
        ForEach-Object { $guiSource += (Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8) }

    $results = @()
    foreach ($a in Get-Registry) {
        foreach ($b in @($a.bindings)) {
            $ok = $true
            $detail = ''
            if ($b.target -like 'gui:*') {
                $name = $b.target.Substring(4)
                $ok = $guiSource.Contains($name)
                $detail = if ($ok) { "gui/*.cs 中存在自动化标识 $name" } else { "gui/*.cs 中找不到自动化标识 $name" }
            } elseif ($b.target -like 'cli:always-json/*') {
                $file = ($b.target -replace '^cli:always-json/engine/', '') -replace ' .*$', ''
                $ok = Test-Path -LiteralPath (Join-Path $script:EngineDir $file)
                $detail = if ($ok) { "兼容命令 engine/$file 存在" } else { "兼容命令 engine/$file 不存在" }
            } elseif ($b.target -like 'cli:engine/*') {
                $file = ($b.target -replace '^cli:engine/', '') -replace ' .*$', ''
                $ok = Test-Path -LiteralPath (Join-Path $script:EngineDir $file)
                $detail = if ($ok) { "兼容命令 engine/$file 存在" } else { "兼容命令 engine/$file 不存在" }
            } elseif ($b.target -like 'cli:open365.ps1 action run *') {
                $ok = ($b.target -match ('action run ' + [regex]::Escape($a.id) + '(\s|$)'))
                $detail = if ($ok) { '通用动作 CLI 指向同一 Action ID' } else { '通用动作 CLI 目标与 Action ID 不一致' }
            } else {
                $ok = $false
                $detail = "无法识别的绑定目标: $($b.target)"
            }
            $results += [ordered]@{ action_id = $a.id; surface = $b.surface; target = $b.target; ok = $ok; detail = $detail }
        }
    }
    return $results
}

# ---------- verify：AI 的无头自测入口 ----------

function Invoke-Verify {
    $checks = @()
    $registry = Get-Registry

    # 1) 清单没有漂移
    $manifestPath = Get-ManifestPath
    $generated = Format-ManifestJson (New-Manifest)
    $onDisk = if (Test-Path -LiteralPath $manifestPath) { ((Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd() } else { '' }
    $manifestOk = ($onDisk -eq $generated.TrimEnd())
    $checks += [ordered]@{ check = 'manifest.in_sync'; action_id = ''; ok = $manifestOk; detail = $(if ($manifestOk) { 'action-parity.json 与注册表一致' } else { 'action-parity.json 已漂移，请重新生成: action manifest -WriteManifest' }) }

    # 2) 每个界面绑定都能静态验证
    foreach ($b in (Test-Bindings)) {
        $checks += [ordered]@{ check = 'binding'; action_id = $b.action_id; ok = $b.ok; detail = "$($b.surface): $($b.detail)" }
    }

    # 3) 只读动作真的能无界面跑通，且输出符合契约
    foreach ($a in $registry) {
        if ($a.effects.class -ne 'read') { continue }
        $inputObj = @{}
        if (@($a.params).Count -gt 0) {
            # 只读动作的必填参数用固定探针值，保证 verify 可重复
            $probe = @{}
            foreach ($p in @($a.params)) { $probe[$p.name] = 'open365' }
            $inputObj = $probe
        }
        $r = Invoke-ActionById $a.id $inputObj $false
        $ok = ($r.code -eq 0)
        $detail = if ($ok) { "无界面执行通过 ($($r.envelope.duration_ms) ms)" } else { "$($r.envelope.error.code): $($r.envelope.error.message)" }
        $checks += [ordered]@{ check = 'headless_run'; action_id = $a.id; ok = $ok; detail = $detail }
    }

    # 4) 写动作默认必须被拒绝（deny-by-default）
    foreach ($a in $registry) {
        if ($a.effects.class -eq 'read') { continue }
        $probe = @{}
        foreach ($p in @($a.params)) { $probe[$p.name] = 'open365-verify-probe' }
        $r = Invoke-ActionById $a.id $probe $false
        $denied = ($r.code -eq 3)
        $detail = if ($denied) { "未确认时被拒绝: $($r.envelope.error.code)" } else { '危险：未确认竟然被放行' }
        $checks += [ordered]@{ check = 'deny_by_default'; action_id = $a.id; ok = $denied; detail = $detail }
    }

    $failed = @($checks | Where-Object { -not $_.ok })
    return [ordered]@{
        protocol     = $script:Protocol
        ok           = ($failed.Count -eq 0)
        application  = (Get-Open365Application).id
        actions      = @($registry).Count
        checks_total = @($checks).Count
        checks_failed = $failed.Count
        checks       = $checks
    }
}

# ---------- 入口 ----------

switch ($Command) {

    'list' {
        $rows = @(Get-Registry | ForEach-Object {
            [ordered]@{
                id      = $_.id
                title   = $_.title
                class   = $_.effects.class
                risk    = $_.effects.risk
                confirm = $_.effects.confirmation
                surfaces = @(@($_.bindings) | ForEach-Object { $_.surface })
            }
        })
        if ($Json) {
            Out-Json ([ordered]@{ protocol = $script:Protocol; ok = $true; count = $rows.Count; actions = $rows })
        } else {
            Write-Host ""
            Write-Host ("  {0,-20} {1,-8} {2,-7} {3}" -f 'ACTION ID', 'CLASS', 'RISK', 'TITLE')
            Write-Host "  ---------------------------------------------------------------"
            foreach ($r in $rows) { Write-Host ("  {0,-20} {1,-8} {2,-7} {3}" -f $r.id, $r.class, $r.risk, $r.title) }
            Write-Host ""
        }
        exit 0
    }

    'describe' {
        $a = Get-ActionOrFail $Target
        $public = Strip-InternalFields $a
        if ($Json) {
            Out-Json ([ordered]@{ protocol = $script:Protocol; ok = $true; action = $public })
        } else {
            $public | ConvertTo-Json -Depth 24
        }
        exit 0
    }

    'manifest' {
        $m = New-Manifest
        $text = Format-ManifestJson $m
        if ($Check) {
            $path = Get-ManifestPath
            $onDisk = if (Test-Path -LiteralPath $path) { ((Get-Content -LiteralPath $path -Raw -Encoding UTF8) -replace "`r`n", "`n").TrimEnd() } else { '' }
            $current = ($onDisk -eq $text.TrimEnd())
            if ($Json) { Out-Json ([ordered]@{ protocol = $script:Protocol; ok = $current; current = $current; path = $path }) }
            elseif ($current) { Write-Output "current`t$path" } else { Write-Output "drifted`t$path" }
            exit $(if ($current) { 0 } else { 1 })
        }
        if ($WriteManifest) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText((Get-ManifestPath), $text + "`n", $utf8NoBom)
            Write-Note "已写入 $(Get-ManifestPath)"
            if ($Json) { Out-Json ([ordered]@{ protocol = $script:Protocol; ok = $true; written = (Get-ManifestPath) }) }
            exit 0
        }
        Write-Output $text
        exit 0
    }

    'export' {
        Out-Json (New-RegistryBundle)
        exit 0
    }

    'run' {
        $inputObj = Resolve-Input
        $r = Invoke-ActionById $Target $inputObj ([bool]$Confirm)
        Exit-WithEnvelope $r.envelope $r.code
    }

    'bindings' {
        $rows = Test-Bindings
        $bad = @($rows | Where-Object { -not $_.ok })
        if ($Json) {
            Out-Json ([ordered]@{ protocol = $script:Protocol; ok = ($bad.Count -eq 0); total = @($rows).Count; failed = $bad.Count; bindings = $rows })
        } else {
            foreach ($r in $rows) {
                $mark = if ($r.ok) { '[OK]  ' } else { '[FAIL]' }
                Write-Host "  $mark $($r.action_id) @ $($r.surface) -> $($r.detail)"
            }
        }
        exit $(if ($bad.Count -eq 0) { 0 } else { 1 })
    }

    'verify' {
        $rep = Invoke-Verify
        if ($Json) {
            Out-Json $rep
        } else {
            Write-Host ""
            foreach ($c in $rep.checks) {
                $mark = if ($c.ok) { '[OK]  ' } else { '[FAIL]' }
                Write-Host "  $mark $($c.check) $($c.action_id) — $($c.detail)"
            }
            Write-Host ""
            Write-Host ("  {0} / {1} 项通过" -f ($rep.checks_total - $rep.checks_failed), $rep.checks_total) -ForegroundColor $(if ($rep.ok) { 'Green' } else { 'Red' })
            Write-Host ""
        }
        exit $(if ($rep.ok) { 0 } else { 1 })
    }

    default {
        Write-Output @"
Open365 动作核心 (ActionParity 0.5.0 / 影核协议)

  action list                         列出全部动作
  action describe <id>                看某个动作的契约（输入/输出/风险/绑定）
  action manifest [-WriteManifest]    输出（或写回）action-parity.json
  action manifest -Check              检查生成清单是否漂移
  action export -Json                 导出 Registry Bundle，供上游生成器/verify 使用
  action run <id> [-InputJson '{}']   执行动作；改系统的动作必须加 -Confirm
  action bindings                     检查各界面绑定是否都指向同一动作（不用开窗口）
  action verify                       无头自测：清单+绑定+只读动作+默认拒绝

  公共开关: -Json（stdout 输出单行 JSON 信封）

  退出码: 0 成功 / 1 失败 / 2 用法错误 / 3 被权限闸门拒绝
  环境变量: OPEN365_SANDBOX=1 时拒绝一切非只读动作（给 AI 自动化用）
"@
        exit 0
    }
}
