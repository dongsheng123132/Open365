# 自测：守夜模式"挡更新自动重启"的还原算法（三个分支都不留残留）
# 用 HKCU 临时键（无需管理员），复刻 focus.ps1 的 Block/Restore 逻辑。
$ErrorActionPreference = 'Stop'
$VAL = 'NoAutoRebootWithLoggedOnUsers'

function RunCycle([string]$KEY) {
    $wuKeyCreated = $false; $wuHadValue = $false; $wuOldValue = $null
    # --- Block ---
    if (-not (Test-Path $KEY)) {
        New-Item -Path $KEY -Force | Out-Null
        $wuKeyCreated = $true
    } else {
        $cur = Get-ItemProperty -Path $KEY -Name $VAL -ErrorAction SilentlyContinue
        if ($null -ne $cur -and $cur.PSObject.Properties.Name -contains $VAL) {
            $wuHadValue = $true; $wuOldValue = $cur.$VAL
        }
    }
    Set-ItemProperty -Path $KEY -Name $VAL -Value 1 -Type DWord
    $applied = (Get-ItemProperty $KEY -Name $VAL).$VAL
    # --- Restore ---
    if ($wuKeyCreated) {
        Remove-Item -Path $KEY -Recurse -Force -ErrorAction SilentlyContinue
    } elseif ($wuHadValue) {
        Set-ItemProperty -Path $KEY -Name $VAL -Value $wuOldValue -Type DWord
    } else {
        Remove-ItemProperty -Path $KEY -Name $VAL -ErrorAction SilentlyContinue
    }
    return $applied
}

$base = 'HKCU:\Software\Open365Test_focus'
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok) {
    if ($ok) { Write-Host "  [PASS] $name" -ForegroundColor Green; $script:pass++ }
    else     { Write-Host "  [FAIL] $name" -ForegroundColor Red;   $script:fail++ }
}

# 场景A：键不存在（我们建）-> 还原应整键消失
$kA = $base + 'A'; if (Test-Path $kA) { Remove-Item $kA -Recurse -Force }
$a = RunCycle $kA
Check "A 键我们建：挡更新时值=1 且 还原后整键消失" ($a -eq 1 -and -not (Test-Path $kA))

# 场景B：键在但无该值 -> 还原后键留、该值消失、旁边的值不动
$kB = $base + 'B'; New-Item $kB -Force | Out-Null
New-ItemProperty $kB -Name 'keepme' -Value 7 -PropertyType DWord -Force | Out-Null
$b = RunCycle $kB
$valGone = -not ((Get-ItemProperty $kB).PSObject.Properties.Name -contains $VAL)
$keepOk = (Get-ItemProperty $kB -Name keepme).keepme -eq 7
Check "B 键已存在：还原后该值消失 且 邻值 keepme 保留" ($b -eq 1 -and $valGone -and $keepOk)
Remove-Item $kB -Recurse -Force

# 场景C：原本有该值=0 -> 还原后必须写回0（不是删掉）
$kC = $base + 'C'; New-Item $kC -Force | Out-Null
New-ItemProperty $kC -Name $VAL -Value 0 -PropertyType DWord -Force | Out-Null
$c = RunCycle $kC
$restored = (Get-ItemProperty $kC -Name $VAL).$VAL
Check "C 原本有值=0：还原后精确写回 0" ($c -eq 1 -and $restored -eq 0)
Remove-Item $kC -Recurse -Force

# 清理
if (Test-Path $base) { Remove-Item $base -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ""
Write-Host "  结果: $pass 通过, $fail 失败" -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Red' })
if ($fail -gt 0) { exit 1 }
