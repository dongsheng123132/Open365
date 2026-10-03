<#
.SYNOPSIS
    Open365 启动项管理引擎 (startup engine)
    开源的"优化加速 / 开机加速 / 启动项管理"工具。

.DESCRIPTION
    列出所有开机自启来源并支持启用/禁用：
      - 注册表 Run 键：HKLM/HKCU 的 Run 和 Run (WOW6432Node)
      - 启动文件夹：用户的 和 公共的
    当前覆盖注册表 Run 和启动文件夹，不包含计划任务、服务和商店应用。

    禁用是可还原的：注册表项移到 Open365 的 -disabled 备份键，
    启动文件夹快捷方式移到 disabled 备份目录，不直接删除。

.NOTES
    list 只读。disable/enable 改 HKCU 不需管理员；改 HKLM 需要管理员。
#>

param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'disable', 'enable', 'add', 'help')]
    [string]$Action = 'list',

    [string]$Id,            # disable/enable 的目标项 id（来自 list 输出）
    [string]$Name,
    [string]$TargetPath,
    [string]$Arguments,
    [switch]$Json
)

$ErrorActionPreference = 'Stop'

# -Json 输出要能被 UTF-8 解析：脚本自己钉住输出编码，别依赖调用方的控制台代码页。
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 本地「会思考」的开机项建议（纯本地名录，不联网、不上传） ----------
# 只按名字/路径做本地关键词匹配给建议，保守优先：拿不准一律 unknown 交给用户，
# 绝不建议禁用要害项（安全/驱动/输入法）。level: keep(保留) / optional(可关) / unknown(自定)。
function Get-StartupAdvice([string]$name, [string]$command) {
    # 在「名字 + 完整命令」里匹配，但先剔除 Windows 通用路径噪声词——否则
    # C:\ProgramData\… 会让 'amd' 误命中「progr[amd]ata」，把一堆项误判「建议保留」。
    # 剔除后厂商目录名（Realtek / AMD / NVIDIA / Tencent…）仍在，真信号不丢。
    $hay = ("$name $command").ToLower()
    foreach ($noise in @('programdata', 'program files', 'programfiles', 'appdata', 'system32',
                         'microsoft', 'start menu', 'startup', 'driverstore', 'filerepository',
                         'wow6432node', 'common files', 'roaming')) {
        $hay = $hay.Replace($noise, ' ')
    }

    # 1) 建议保留：安全 / 声卡 / 显卡 / 触摸板 等要害，关了可能出问题
    $keep = @('defender', 'security', 'antivir', 'realtek', 'nvidia', 'nvcontainer', 'nvtray',
              'radeon', 'amd', 'igfx', 'intel(r)', 'synaptics', 'touchpad', 'elan', 'dolby',
              'waves', 'hotkey', 'wireless', 'bluetooth')
    foreach ($k in $keep) { if ($hay.Contains($k)) { return @{ level = 'keep'; reason = '系统/驱动/安全相关，建议保留' } } }

    # 2) 明显可关：更新器 / 大厂常驻软件（关了只是开机不自启，要用点一下就行）
    $optional = @(
        @{ k = 'update';     r = '更新检查程序，开机不必自启' },
        @{ k = 'updater';    r = '更新检查程序，开机不必自启' },
        @{ k = 'helper';     r = '辅助进程，通常无需开机自启' },
        @{ k = 'qq';         r = 'QQ，可改成用时再开，省开机时间' },
        @{ k = 'wechat';     r = '微信，可改成用时再开，省开机时间' },
        @{ k = 'dingtalk';   r = '钉钉，可改成用时再开' },
        @{ k = 'steam';      r = '游戏平台，可改成用时再开' },
        @{ k = 'epic';       r = 'Epic 游戏平台，可改成用时再开' },
        @{ k = 'spotify';    r = '音乐播放器，可改成用时再开' },
        @{ k = 'cloudmusic'; r = '网易云音乐，可改成用时再开' },
        @{ k = 'itunes';     r = '苹果助手，通常无需开机自启' },
        @{ k = 'adobe';      r = 'Adobe 更新/云，通常无需开机自启' },
        @{ k = 'thunder';    r = '迅雷，可改成用时再开' },
        @{ k = 'baidu';      r = '百度网盘/助手，通常无需开机自启' },
        @{ k = 'sogou';      r = '搜狗（更新器可关；输入法本体不受影响）' },
        @{ k = 'wps';        r = 'WPS，可改成用时再开' },
        @{ k = 'office';     r = 'Office 预加载，可关（首次打开略慢一点）' },
        @{ k = 'skype';      r = 'Skype，可改成用时再开' },
        @{ k = 'zoom';       r = 'Zoom，可改成用时再开' },
        @{ k = 'onedrive';   r = 'OneDrive 云同步，不用云盘可关' }
    )
    foreach ($o in $optional) { if ($hay.Contains($o.k)) { return @{ level = 'optional'; reason = $o.r } } }

    # 3) 其它：拿不准，交给用户（禁用可一键还原，放心试）
    return @{ level = 'unknown'; reason = '未知项，可自行决定（禁用可一键还原）' }
}

# 注册表启动位置定义
$RunKeys = @(
    @{ id='hklm-run';    hive='HKLM'; path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 scope='所有用户'; admin=$true }
    @{ id='hklm-run32';  hive='HKLM'; path='SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run';     scope='所有用户(32位)'; admin=$true }
    @{ id='hkcu-run';    hive='HKCU'; path='SOFTWARE\Microsoft\Windows\CurrentVersion\Run';                 scope='当前用户'; admin=$false }
)
$DisabledSuffix = '\Open365-Disabled'   # 禁用项移到 ...\Run\Open365-Disabled

function Get-HivePath($k, [bool]$disabled) {
    $base = "$($k.hive):\$($k.path)"
    if ($disabled) { return "$base$DisabledSuffix" }
    return $base
}

function Get-StartupFolders {
    @(
        @{ id='startup-user'; path=[Environment]::GetFolderPath('Startup'); scope='当前用户'; admin=$false }
        @{ id='startup-common'; path=[Environment]::GetFolderPath('CommonStartup'); scope='所有用户'; admin=$true }
    )
}

# ---------- 列出 ----------

function Get-StartupItems {
    $items = @()
    # 软件可能在禁用后重新注册同名项。当前位置优先，旧备份不是第二个启动项。
    $seen = @{}

    # 1) 注册表 Run 键（含已禁用的备份键）
    foreach ($k in $RunKeys) {
        foreach ($state in @('enabled','disabled')) {
            $p = Get-HivePath $k ($state -eq 'disabled')
            if (-not (Test-Path -LiteralPath $p)) { continue }
            $props = Get-ItemProperty -LiteralPath $p -ErrorAction SilentlyContinue
            if (-not $props) { continue }
            foreach ($prop in $props.PSObject.Properties) {
                if ($prop.Name -in @('PSPath', 'PSParentPath', 'PSChildName', 'PSDrive', 'PSProvider')) { continue }
                $itemId = "reg:$($k.id):$($prop.Name)"
                if ($seen.ContainsKey($itemId)) { continue }
                $seen[$itemId] = $true
                $adv = Get-StartupAdvice $prop.Name "$($prop.Value)"
                $items += [ordered]@{
                    id      = $itemId
                    name    = $prop.Name
                    command = $prop.Value
                    source  = "注册表 ($($k.scope))"
                    type    = 'registry'
                    regkey  = $k.id
                    state   = $state
                    admin   = $k.admin
                    advice        = $adv.level
                    advice_reason = $adv.reason
                }
            }
        }
    }

    # 2) 启动文件夹
    $folders = @(Get-StartupFolders)
    foreach ($fo in $folders) {
        foreach ($state in @('enabled','disabled')) {
            $dir = if ($state -eq 'disabled') { Join-Path $fo.path 'Open365-Disabled' } else { $fo.path }
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.lnk','.exe','.bat','.cmd','.vbs' } |
                ForEach-Object {
                    $itemId = "folder:$($fo.id):$($_.Name)"
                    if ($seen.ContainsKey($itemId)) { return }
                    $seen[$itemId] = $true
                    $target = $_.FullName
                    $arguments = ''
                    if ($_.Extension -eq '.lnk') {
                        $ws = $null; $link = $null
                        try {
                            $ws = New-Object -ComObject WScript.Shell
                            $link = $ws.CreateShortcut($_.FullName)
                            $target = $link.TargetPath
                            $arguments = $link.Arguments
                        } catch { } finally {
                            if ($link) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
                            if ($ws) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ws) }
                        }
                    }
                    $adv = Get-StartupAdvice $_.BaseName "$target $arguments"
                    $items += [ordered]@{
                        id      = $itemId
                        name    = $_.BaseName
                        command = $_.FullName
                        target_path = $target
                        arguments = $arguments
                        source  = "启动文件夹 ($($fo.scope))"
                        type    = 'folder'
                        folder  = $fo.id
                        state   = $state
                        admin   = $fo.admin
                        advice        = $adv.level
                        advice_reason = $adv.reason
                    }
                }
        }
    }

    return $items
}

function Show-List($items) {
    Write-Host ""
    Write-Host "  ========== 开机启动项 ==========" -ForegroundColor White
    Write-Host ""
    if ($items.Count -eq 0) { Write-Host "  (没有发现启动项)"; return }
    $i = 0
    foreach ($it in $items) {
        $i++
        $flag = if ($it.state -eq 'disabled') { '[已禁用]' } else { '[启用中]' }
        $color = if ($it.state -eq 'disabled') { 'DarkGray' } else { 'White' }
        Write-Host ("  {0} {1}" -f $flag, $it.name) -ForegroundColor $color
        Write-Host ("       来源: {0}" -f $it.source) -ForegroundColor DarkGray
        Write-Host ("       命令: {0}" -f $it.command) -ForegroundColor DarkGray
        Write-Host ("       id  : {0}" -f $it.id) -ForegroundColor DarkCyan
        Write-Host ""
    }
    Write-Host "  禁用某项: open365 startup disable -Id <上面的id>" -ForegroundColor Cyan
    Write-Host "  恢复某项: open365 startup enable  -Id <上面的id>" -ForegroundColor Cyan
    Write-Host ""
}

# ---------- 禁用 / 启用（可还原） ----------

function Read-StartupRegValue($path, $name) {
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $key = Get-Item -LiteralPath $path
    try {
        if ($key.GetValueNames() -notcontains $name) { return $null }
        return @{
            kind = $key.GetValueKind($name)
            value = $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    } finally { $key.Close() }
}

function Test-StartupRegValueEqual($left, $right) {
    if ($null -eq $left -or $null -eq $right -or $left.kind -ne $right.kind) { return $false }
    $a = @($left.value); $b = @($right.value)
    if ($a.Count -ne $b.Count) { return $false }
    for ($i = 0; $i -lt $a.Count; $i++) {
        # Object.Equals 对字符串大小写敏感；不能把不同参数的旧命令丢掉。
        if (-not [object]::Equals($a[$i], $b[$i])) { return $false }
    }
    return $true
}

function Move-RegValue($fromKey, $toKey, $name, [switch]$ArchiveExisting) {
    $source = Read-StartupRegValue $fromKey $name
    if ($null -eq $source) { throw '启动项已变化，请刷新后重试。' }
    if (-not (Test-Path -LiteralPath $toKey)) { New-Item -Path $toKey -Force | Out-Null }
    $previous = Read-StartupRegValue $toKey $name
    $created = $false; $replaced = $false
    if ($null -ne $previous) {
        if (-not (Test-StartupRegValueEqual $source $previous)) {
            # 恢复时仍不覆盖现有 Run 值；只有禁用允许把旧备份移入历史。
            if (-not $ArchiveExisting) { throw '当前位置已有不同的启动项，已保留两份配置。请刷新查看当前项。' }
            $history = $toKey + '\History\' + [guid]::NewGuid().ToString('N')
            New-Item -Path $history -Force | Out-Null
            New-ItemProperty -LiteralPath $history -Name $name -Value $previous.value -PropertyType $previous.kind -ErrorAction Stop | Out-Null
            if (-not (Test-StartupRegValueEqual (Read-StartupRegValue $history $name) $previous)) { throw '旧备份归档校验失败，未禁用启动项。' }
            if (-not (Test-StartupRegValueEqual (Read-StartupRegValue $toKey $name) $previous)) { throw '备份在操作中发生变化，请刷新重试。' }
            New-ItemProperty -LiteralPath $toKey -Name $name -Value $source.value -PropertyType $source.kind -Force -ErrorAction Stop | Out-Null
            $replaced = $true
        }
        # 值与类型相同就复用已有备份，不需要再写一份。
    } else {
        New-ItemProperty -LiteralPath $toKey -Name $name -Value $source.value -PropertyType $source.kind -ErrorAction Stop | Out-Null
        $created = $true
    }
    try {
        if (-not (Test-StartupRegValueEqual (Read-StartupRegValue $fromKey $name) $source) -or
            -not (Test-StartupRegValueEqual (Read-StartupRegValue $toKey $name) $source)) {
            throw '启动项在操作中发生变化，已保留原项，请刷新重试。'
        }
        Remove-ItemProperty -LiteralPath $fromKey -Name $name -ErrorAction Stop
    } catch {
        # 删除原项失败时还原旧备份；不回滚其他进程在此期间写入的新值。
        if (Test-StartupRegValueEqual (Read-StartupRegValue $toKey $name) $source) {
            if ($replaced) { New-ItemProperty -LiteralPath $toKey -Name $name -Value $previous.value -PropertyType $previous.kind -Force -ErrorAction Stop | Out-Null }
            elseif ($created) { Remove-ItemProperty -LiteralPath $toKey -Name $name -ErrorAction Stop }
        }
        throw
    }
}

function Move-StartupFile([string]$from, [string]$to, [switch]$ArchiveExisting) {
    $archive = $null
    if (Test-Path -LiteralPath $to) {
        $sourceHash = (Get-FileHash -LiteralPath $from -Algorithm SHA256 -ErrorAction Stop).Hash
        $targetHash = (Get-FileHash -LiteralPath $to -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($sourceHash -ceq $targetHash) {
            [IO.File]::Delete($from)
            return
        }
        if (-not $ArchiveExisting) { throw '当前位置已有不同的启动文件，已保留两份配置。请刷新查看当前项。' }
        $history = Join-Path (Split-Path -LiteralPath $to) ('History\' + [guid]::NewGuid().ToString('N'))
        [void][IO.Directory]::CreateDirectory($history)
        $archive = Join-Path $history ([IO.Path]::GetFileName($to))
        [IO.File]::Move($to, $archive)
    }
    try { [IO.File]::Move($from, $to) }
    catch {
        if ($archive -and -not (Test-Path -LiteralPath $to)) { [IO.File]::Move($archive, $to) }
        throw
    }
}

function Set-ItemState([string]$targetId, [string]$toState) {
    $items = Get-StartupItems
    $item = $items | Where-Object { $_.id -eq $targetId } | Select-Object -First 1
    if (-not $item) { throw "找不到启动项: $targetId（先运行 list 查看正确 id）" }
    if ($item.state -eq $toState) {
        if (-not $Json) { Write-Host "  该项已经是 $toState 状态，无需操作。" -ForegroundColor Yellow }
        return @{ ok=$true; id=$targetId; state=$toState; changed=$false }
    }
    if ($item.admin -and -not (Test-Admin)) {
        throw "该项属于'所有用户'，禁用/启用需要管理员权限。请用 open365.bat（自动提权）。"
    }

    if ($item.type -eq 'registry') {
        $k = $RunKeys | Where-Object { $_.id -eq $item.regkey }
        $enabledKey  = Get-HivePath $k $false
        $disabledKey = Get-HivePath $k $true
        if ($toState -eq 'disabled') { Move-RegValue $enabledKey $disabledKey $item.name -ArchiveExisting }
        else                          { Move-RegValue $disabledKey $enabledKey $item.name }
    }
    elseif ($item.type -eq 'folder') {
        $fo = (Get-StartupFolders | Where-Object { $_.id -eq $item.folder }).path
        $disabledDir = Join-Path $fo 'Open365-Disabled'
        if (-not (Test-Path $disabledDir)) { New-Item -ItemType Directory -Path $disabledDir -Force | Out-Null }
        $fileName = Split-Path $item.command -Leaf
        if ($toState -eq 'disabled') {
            Move-StartupFile $item.command (Join-Path $disabledDir $fileName) -ArchiveExisting
        } else {
            Move-StartupFile $item.command (Join-Path $fo $fileName)
        }
    }
    $observed = @(Get-StartupItems | Where-Object { $_.id -eq $targetId })
    if ($observed.Count -ne 1 -or $observed[0].state -ne $toState) {
        throw '启动项未保持预期状态，可能已被程序重新添加。请检查软件自身的开机启动设置，再刷新查看。'
    }
    if (-not $Json) { Write-Host "  [OK] '$($item.name)' 已$(if($toState -eq 'disabled'){'禁用'}else{'恢复'})" -ForegroundColor Green }
    return @{ ok=$true; id=$targetId; state=$toState; changed=$true }
}

# 新增只写当前用户的快捷方式；临时文件在同卷备份目录，最后移动且绝不覆盖。
function Add-StartupItem([string]$itemName, [string]$programPath, [string]$programArguments) {
    if ([string]::IsNullOrWhiteSpace($itemName) -or $itemName.Length -gt 100 -or
        $itemName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or
        $itemName -match '[. ]$|^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])($|\.)') {
        throw '名称无效：请使用 1–100 个字符，不要包含路径符号或以空格、句点结尾。'
    }
    if (-not [IO.Path]::IsPathRooted($programPath) -or -not (Test-Path -LiteralPath $programPath -PathType Leaf)) {
        throw '找不到程序，请选择现有程序的完整路径。'
    }
    $programPath = (Get-Item -LiteralPath $programPath).FullName
    if ([IO.Path]::GetExtension($programPath) -notin '.exe', '.com', '.bat', '.cmd') {
        throw '请选择 .exe、.com、.bat 或 .cmd 程序。'
    }
    $folder = (Get-StartupFolders | Where-Object { $_.id -eq 'startup-user' }).path
    $backup = Join-Path $folder 'Open365-Disabled'
    $filename = $itemName + '.lnk'
    $destination = Join-Path $folder $filename
    if ((Test-Path -LiteralPath $destination) -or (Test-Path -LiteralPath (Join-Path $backup $filename))) {
        throw '已有同名启动项（可能已禁用），请换个名称或恢复原有项。'
    }
    [void][IO.Directory]::CreateDirectory($backup)
    $staging = Join-Path $backup ('.open365-' + [guid]::NewGuid().ToString('N') + '.lnk')
    $ws = $null; $link = $null
    try {
        $ws = New-Object -ComObject WScript.Shell
        $link = $ws.CreateShortcut($staging)
        $link.TargetPath = $programPath
        $link.Arguments = $programArguments
        $link.WorkingDirectory = [IO.Path]::GetDirectoryName($programPath)
        $link.Description = 'Open365 添加的开机启动项'
        $link.Save()
        [IO.File]::Move($staging, $destination)
    } finally {
        if ($link) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        if ($ws) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($ws) }
        if (Test-Path -LiteralPath $staging) { [IO.File]::Delete($staging) }
    }
    return @{ ok=$true; id="folder:startup-user:$filename"; state='enabled'; changed=$true }
}

# ---------- 入口 ----------

$output = $null
switch ($Action) {
    'list'    { $it = @(Get-StartupItems); if ($Json) { $output = @{ items=$it } } else { Show-List $it } }
    'add'     { $output = Add-StartupItem $Name $TargetPath $Arguments }
    'disable' { if (-not $Id) { throw '请用 -Id 指定要禁用的项' }; $output = Set-ItemState $Id 'disabled' }
    'enable'  { if (-not $Id) { throw '请用 -Id 指定要恢复的项' }; $output = Set-ItemState $Id 'enabled' }
    'help'    {
        Write-Host @"
Open365 启动项管理引擎

用法: startup.ps1 <action> [-Id <id>] [-Json]

  list                列出所有开机启动项（只读）
  disable -Id <id>    禁用某项（可还原，移到备份键/目录）
  enable  -Id <id>    恢复某项
  add -Name <名称> -TargetPath <程序完整路径> [-Arguments <参数>]
                      新增当前用户登录时自启（不立刻运行程序，不覆盖同名项）

禁用是可逆的：注册表项移到 ...\Run\Open365-Disabled，
启动文件夹快捷方式移到 Open365-Disabled 子目录。

加 -Json 输出结构化结果。
"@
    }
}

if ($Json -and $output) { $output | ConvertTo-Json -Depth 6 -Compress }
