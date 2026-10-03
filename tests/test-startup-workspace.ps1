# 启动项回归：只操作唯一测试注册表键和临时文件夹，绝不写真实 Run / Startup。
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine/startup.ps1') help 6>$null | Out-Null
$Json = $true
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('open365-startup-' + [guid]::NewGuid().ToString('N'))
$testKey = 'Software\Open365.Tests\' + [guid]::NewGuid().ToString('N')
$RunKeys = @(@{id='hkcu-run'; hive='HKCU'; path=$testKey; scope='测试'; admin=$false})
function Get-StartupFolders { @(@{id='startup-user'; path=$testRoot; scope='测试'; admin=$false}) }
$keyPath = 'HKCU:\' + $testKey
$passed = 0
function Check([string]$name, [bool]$condition) {
    if (-not $condition) { throw "FAIL: $name" }
    $script:passed++; Write-Host "[PASS] $name"
}
function MustReject([scriptblock]$operation) {
    try { & $operation | Out-Null; return $false } catch { return $true }
}
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    New-Item -Path $keyPath -Force | Out-Null
    $program = Join-Path $testRoot "测试 app's.cmd"
    [IO.File]::WriteAllText($program, '@echo off')
    $argsText = '--profile "含 空格" --literal "$x; & test"'
    $added = Add-StartupItem '测试 程序' $program $argsText
    Check '新增当前用户快捷方式' ($added.ok -and $added.state -eq 'enabled')
    $item = @(Get-StartupItems | Where-Object { $_.id -eq $added.id })[0]
    Check '列表解析快捷方式目标和参数' ($item.target_path -eq $program -and $item.arguments -eq $argsText)
    $before = (Get-FileHash -LiteralPath $item.command).Hash
    Check '同名新增被拒且原项不变' ((MustReject { Add-StartupItem '测试 程序' $program '' }) -and (Get-FileHash -LiteralPath $item.command).Hash -eq $before)
    $disabled = Set-ItemState $added.id 'disabled'
    Check '禁用移走快捷方式' ($disabled.changed -and -not (Test-Path -LiteralPath $item.command))
    Check '已禁用名称也不能覆盖' (MustReject { Add-StartupItem '测试 程序' $program '' })
    Check '重复禁用保持幂等' (-not (Set-ItemState $added.id 'disabled').changed)
    $restored = Set-ItemState $added.id 'enabled'
    Check '恢复后字节完全一致' ($restored.changed -and (Get-FileHash -LiteralPath $item.command).Hash -eq $before)
    Check '拒绝目录穿越' (MustReject { Add-StartupItem '..\outside' $program '' })
    Check '拒绝不存在的程序' (MustReject { Add-StartupItem 'missing' (Join-Path $testRoot 'missing.exe') '' })
    Check '拒绝系统保留名称' (MustReject { Add-StartupItem 'CON' $program '' })
    $dataPath = Join-Path $testRoot 'data.txt'; [IO.File]::WriteAllText($dataPath, 'do not launch')
    Check '拒绝非程序文件' (MustReject { Add-StartupItem 'data' $dataPath '' })

    New-ItemProperty -LiteralPath $keyPath -Name 'TestApp' -Value '%TEMP%\测试 app.exe --flag "a b"' -PropertyType ExpandString | Out-Null
    $regId = 'reg:hkcu-run:TestApp'
    [void](Set-ItemState $regId 'disabled')
    [void](Set-ItemState $regId 'enabled')
    $reg = Get-Item -LiteralPath $keyPath
    Check '注册表恢复保留 ExpandString 类型和原始值' ($reg.GetValueKind('TestApp') -eq 'ExpandString' -and $reg.GetValue('TestApp', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -eq '%TEMP%\测试 app.exe --flag "a b"')
    $reg.Close()
    $backupKey = $keyPath + '\Open365-Disabled'
    Set-ItemProperty -LiteralPath $backupKey -Name TestApp -Value 'existing backup'
    Check '注册表同名备份拒绝覆盖' (MustReject { Move-RegValue $keyPath $backupKey 'TestApp' })
    Check '冲突后两边值均存在' ((Get-ItemProperty -LiteralPath $backupKey).TestApp -eq 'existing backup' -and $null -ne (Get-ItemProperty -LiteralPath $keyPath).TestApp)
    New-ItemProperty -LiteralPath $keyPath -Name 'PSHelper' -Value 'C:\Test.exe' -PropertyType String | Out-Null
    Check 'PS 前缀的真实程序名不会被过滤' (@(Get-StartupItems | Where-Object { $_.name -eq 'PSHelper' }).Count -eq 1)

    $core = Join-Path $root 'core/action-core.ps1'
    $inputPath = Join-Path $testRoot 'input.json'
    [IO.File]::WriteAllText($inputPath, (@{name='gate'; target_path=$program; arguments=$argsText} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $gate = & powershell -NoProfile -ExecutionPolicy Bypass -File $core run startup.add -InputFile $inputPath -Json | ConvertFrom-Json
    Check '新增动作默认由确认闸门拒绝' ($LASTEXITCODE -eq 3 -and $gate.error.code -eq 'confirmation_required')
    $oldSandbox = $env:OPEN365_SANDBOX
    try {
        $env:OPEN365_SANDBOX = '1'
        $gate = & powershell -NoProfile -ExecutionPolicy Bypass -File $core run startup.add -InputFile $inputPath -Confirm -Json | ConvertFrom-Json
        Check '沙箱拒绝已确认的新增动作' ($LASTEXITCODE -eq 3 -and $gate.error.code -eq 'sandbox_read_only')
    } finally { $env:OPEN365_SANDBOX = $oldSandbox }

    # 传到引擎的 ID 保留双引号和单引号；随机不存在的 ID 在任何写入前就会失败。
    $probeId = 'reg:hkcu-run:missing-' + [guid]::NewGuid().ToString('N') + '-"双 引号"-it''s-$literal'
    [IO.File]::WriteAllText($inputPath, (@{id=$probeId} | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $quoted = & powershell -NoProfile -ExecutionPolicy Bypass -File $core run startup.enable -InputFile $inputPath -Confirm -Json | ConvertFrom-Json
    Check '核心传参完整保留引号与美元符号' ($LASTEXITCODE -eq 1 -and $quoted.error.message.Contains($probeId))
    $list = & powershell -NoProfile -ExecutionPolicy Bypass -File $core run startup.list -Json | ConvertFrom-Json
    Check '真实机器只读列表契约通过' ($LASTEXITCODE -eq 0 -and $list.ok -and $list.output.items -is [array])
    Write-Host "[OK] $passed checks passed"
} finally {
    # 两个路径都由本次 GUID 创建，且清理前重新验证根边界。
    $full = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'open365-startup-*') {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($keyPath -match '^HKCU:\\Software\\Open365\.Tests\\[a-f0-9]{32}$') { Remove-Item -LiteralPath $keyPath -Recurse -Force -ErrorAction SilentlyContinue }
}
