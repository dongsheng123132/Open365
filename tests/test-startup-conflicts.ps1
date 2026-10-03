# 同名旧备份回归。仅使用本次创建的随机 HKCU 测试键与临时文件，不碰真实自启。
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'engine/startup.ps1') help 6>$null | Out-Null
$Json = $true
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('open365-startup-conflicts-' + [guid]::NewGuid().ToString('N'))
$testKey = 'HKCU:\Software\Open365.Tests\' + [guid]::NewGuid().ToString('N')
$backupKey = $testKey + '\Open365-Disabled'
$RunKeys = @(@{id='hkcu-run'; hive='HKCU'; path=$testKey.Substring(6); scope='测试'; admin=$false})
function Get-StartupFolders { @(@{id='startup-user'; path=$testRoot; scope='测试'; admin=$false}) }
$passed = 0
function Check([string]$name, [bool]$ok) {
    if (-not $ok) { throw "FAIL: $name" }
    $script:passed++; Write-Host "[PASS] $name"
}
function Put($path, $name, $value, $kind = 'String') {
    New-ItemProperty -LiteralPath $path -Name $name -Value $value -PropertyType $kind -Force | Out-Null
}
function Read-Raw($path, $name) {
    $key = Get-Item -LiteralPath $path
    try { return $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Close() }
}
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    New-Item -Path $backupKey -Force | Out-Null
    $id = 'reg:hkcu-run:AweSun'
    $command = '"C:\Program Files\Oray\AweSun\AweSun.exe" --cmd=autorun'
    Put $testKey 'AweSun' $command
    Put $backupKey 'AweSun' $command
    $before = @(Get-StartupItems | Where-Object { $_.id -eq $id })
    Check '同名当前项和旧备份只显示一项，按当前启用状态展示' ($before.Count -eq 1 -and $before[0].state -eq 'enabled')
    $result = Set-ItemState $id 'disabled'
    Check '完全相同的旧备份不阻止禁用' ($result.ok -and $result.changed -and $null -eq (Read-Raw $testKey 'AweSun'))
    Check '复用的备份内容不变' ((Read-Raw $backupKey 'AweSun') -ceq $command)
    Check '再次禁用不报错且不重复写入' (-not (Set-ItemState $id 'disabled').changed)
    $after = @(Get-StartupItems | Where-Object { $_.id -eq $id })
    Check '禁用后列表只显示一条已禁用' ($after.Count -eq 1 -and $after[0].state -eq 'disabled')
    [void](Set-ItemState $id 'enabled')
    Check '相同备份禁用后仍能恢复' ((Read-Raw $testKey 'AweSun') -ceq $command -and $null -eq (Read-Raw $backupKey 'AweSun'))

    $old = '%TEMP%\old app.exe --Profile WORK'
    $current = '%TEMP%\new app.exe --Profile work'
    Put $testKey 'AweSun' $current 'ExpandString'
    Put $backupKey 'AweSun' $old 'ExpandString'
    [void](Set-ItemState $id 'disabled')
    Check '不同旧备份存在时也能禁用，最新命令成为恢复目标' ($null -eq (Read-Raw $testKey 'AweSun') -and (Read-Raw $backupKey 'AweSun') -ceq $current)
    $archives = @(Get-ChildItem -LiteralPath ($backupKey + '\History'))
    Check '旧备份完整归档且保留原类型' ($archives.Count -eq 1 -and $archives[0].GetValueKind('AweSun') -eq 'ExpandString' -and (Read-Raw $archives[0].PSPath 'AweSun') -ceq $old)
    $after = @(Get-StartupItems | Where-Object { $_.id -eq $id })
    Check '历史备份不混入启动项列表' ($after.Count -eq 1)
    [void](Set-ItemState $id 'enabled')
    Check '恢复使用最新命令，不复活过时备份' ((Read-Raw $testKey 'AweSun') -ceq $current)

    # 大小写不同的参数、不同注册表类型不能被当作相同备份丢掉。
    Put $testKey 'CaseApp' 'app.exe --profile work'
    Put $backupKey 'CaseApp' 'app.exe --profile WORK'
    [void](Set-ItemState 'reg:hkcu-run:CaseApp' 'disabled')
    $caseHistory = @(Get-ChildItem -LiteralPath ($backupKey + '\History') | Where-Object { $_.GetValueNames() -contains 'CaseApp' })
    Check '参数大小写不同也保留历史' ($caseHistory.Count -eq 1)
    Put $testKey 'TypeApp' 'app.exe' 'ExpandString'
    Put $backupKey 'TypeApp' 'app.exe' 'String'
    [void](Set-ItemState 'reg:hkcu-run:TypeApp' 'disabled')
    $typeHistory = @(Get-ChildItem -LiteralPath ($backupKey + '\History') | Where-Object { $_.GetValueNames() -contains 'TypeApp' })
    Check '值相同但类型不同也保留历史' ($typeHistory.Count -eq 1 -and $typeHistory[0].GetValueKind('TypeApp') -eq 'String')

    # 模拟源删除失败：已更换的备份必须还原，当前项不能丢。
    Put $testKey 'FailApp' 'current.exe'
    Put $backupKey 'FailApp' 'previous.exe'
    function Remove-ItemProperty {
        [CmdletBinding()] param([string]$LiteralPath, [string]$Name)
        if ($LiteralPath -eq $testKey -and $Name -eq 'FailApp') { throw '模拟权限拒绝' }
        Microsoft.PowerShell.Management\Remove-ItemProperty -LiteralPath $LiteralPath -Name $Name -ErrorAction Stop
    }
    $rejected = $false
    try { [void](Set-ItemState 'reg:hkcu-run:FailApp' 'disabled') } catch { $rejected = $true }
    finally { Remove-Item Function:\Remove-ItemProperty }
    Check '禁用失败后保留原当前项与旧备份' ($rejected -and (Read-Raw $testKey 'FailApp') -ceq 'current.exe' -and (Read-Raw $backupKey 'FailApp') -ceq 'previous.exe')

    Put $testKey 'RespawnApp' 'original.exe'
    function Remove-ItemProperty {
        [CmdletBinding()] param([string]$LiteralPath, [string]$Name)
        Microsoft.PowerShell.Management\Remove-ItemProperty -LiteralPath $LiteralPath -Name $Name -ErrorAction Stop
        if ($LiteralPath -eq $testKey -and $Name -eq 'RespawnApp') { Put $LiteralPath $Name 'recreated.exe' }
    }
    $rejected = $false
    try { [void](Set-ItemState 'reg:hkcu-run:RespawnApp' 'disabled') } catch { $rejected = $_.Exception.Message -like '*未保持预期状态*' }
    finally { Remove-Item Function:\Remove-ItemProperty }
    Check '软件立即重新注册时不谎报禁用成功' ($rejected -and (Read-Raw $testKey 'RespawnApp') -ceq 'recreated.exe' -and (Read-Raw $backupKey 'RespawnApp') -ceq 'original.exe')

    # 快捷方式 / 文件夹也会出现软件重建自启后的同名备份。
    $folderBackup = Join-Path $testRoot 'Open365-Disabled'
    [void][IO.Directory]::CreateDirectory($folderBackup)
    $liveFile = Join-Path $testRoot 'sample.cmd'
    $backupFile = Join-Path $folderBackup 'sample.cmd'
    [IO.File]::WriteAllText($liveFile, 'current')
    [IO.File]::WriteAllText($backupFile, 'current')
    $fileId = 'folder:startup-user:sample.cmd'
    Check '文件夹同名启动项去重' (@(Get-StartupItems | Where-Object { $_.id -eq $fileId }).Count -eq 1)
    [void](Set-ItemState $fileId 'disabled')
    Check '文件相同的旧备份可复用' (-not (Test-Path -LiteralPath $liveFile) -and [IO.File]::ReadAllText($backupFile) -ceq 'current')
    [void](Set-ItemState $fileId 'enabled')
    Check '文件复用后可以恢复' ([IO.File]::ReadAllText($liveFile) -ceq 'current')
    [IO.File]::WriteAllText($backupFile, 'previous')
    [void](Set-ItemState $fileId 'disabled')
    $historyFiles = @(Get-ChildItem -LiteralPath (Join-Path $folderBackup 'History') -Recurse -File)
    Check '不同文件先归档旧备份再禁用当前项' (-not (Test-Path -LiteralPath $liveFile) -and [IO.File]::ReadAllText($backupFile) -ceq 'current' -and $historyFiles.Count -eq 1 -and [IO.File]::ReadAllText($historyFiles[0].FullName) -ceq 'previous')
    [void](Set-ItemState $fileId 'enabled')
    Check '不同文件恢复的是当前版本' ([IO.File]::ReadAllText($liveFile) -ceq 'current')
    [IO.File]::WriteAllText($backupFile, 'previous')
    $locked = [IO.File]::Open($liveFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $rejected = $false
    try { [void](Set-ItemState $fileId 'disabled') } catch { $rejected = $true }
    finally { $locked.Dispose() }
    Check '启动文件被占用时还原旧备份，保留原文件' ($rejected -and [IO.File]::ReadAllText($liveFile) -ceq 'current' -and [IO.File]::ReadAllText($backupFile) -ceq 'previous')
    Write-Host "[OK] $passed conflict checks passed"
} finally {
    $full = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if ($full.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and (Split-Path $full -Leaf) -like 'open365-startup-conflicts-*') {
        Remove-Item -LiteralPath $full -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($testKey -match '^HKCU:\\Software\\Open365\.Tests\\[a-f0-9]{32}$') {
        Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}
