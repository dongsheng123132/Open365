<#
  Open365 主程序 —— 开源 · 轻量 · 透明的电脑维护工具
  统一菜单，调度 engine/ 下的各引擎。
#>
param(
    [Parameter(Position = 0)] [string]$Cmd,
    [Parameter(Position = 1)] [string]$Sub,
    [Parameter(ValueFromRemainingArguments = $true)] $Rest
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$engine = Join-Path $root 'engine'

function Run-Engine([string]$file, [object[]]$argv) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $engine $file) @argv
}

# 动作核心（ActionParity / 影核协议）：GUI、CLI、AI 共用的同一个动作入口。
# 调度器依旧不含业务逻辑——业务在 engine/，动作身份与契约在 core/registry.ps1。
function Run-Core([object[]]$argv) {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'core\action-core.ps1') @argv
    exit $LASTEXITCODE
}

# ---- 直接命令模式：open365.ps1 network diagnose ----
if ($Cmd) {
    $argv = @($Sub) + @($Rest) | Where-Object { $_ -ne $null }
    switch ($Cmd) {
        'network'   { Run-Engine 'network.ps1'   $argv }
        'clean'     { Run-Engine 'cleaner.ps1'   (@('clean') + $argv) }
        'scan'      { Run-Engine 'cleaner.ps1'   (@('scan')  + $argv) }
        'cleaner'   { Run-Engine 'cleaner.ps1'   $argv }
        'startup'   { Run-Engine 'startup.ps1'   $argv }
        'process'   { Run-Engine 'process.ps1'   $argv }
        'uninstall' { Run-Engine 'uninstall.ps1' $argv }
        'security'  { Run-Engine 'security.ps1'  $argv }
        'focus'     { Run-Engine 'focus.ps1'     $argv }
        'awake'     { Run-Engine 'focus.ps1'     $argv }
        # 光敲 open365 update 就是查更新（这条命令没别的意思，不必再写 check）。
        # 注意 $argv 在没有子命令时是 $null，而 @($null).Count 等于 1 —— 得先滤空再数。
        'update'    { $a = @($argv | Where-Object { $_ }); if ($a.Count -gt 0) { Run-Engine 'update.ps1' $a } else { Run-Engine 'update.ps1' @('check') } }
        'relocate'  { Run-Engine 'relocate.ps1' $argv }
        'sysinfo'   { $a = @($argv | Where-Object { $_ }); if ($a.Count -gt 0) { Run-Engine 'sysinfo.ps1' $a } else { Run-Engine 'sysinfo.ps1' @('info') } }
        'action'    { Run-Core                   $argv }
        default     { Write-Host "未知命令: $Cmd" -ForegroundColor Red }
    }
    return
}

# ---- 交互菜单模式 ----
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ===================================================================" -ForegroundColor Cyan
    Write-Host "        Open365   开源电脑助手   (无广告 · 无弹窗 · 无捆绑)" -ForegroundColor White
    Write-Host "  ===================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1]  网络修复     专治'微信能上、网页打不开'(LSP/Winsock)" -ForegroundColor White
    Write-Host "    [2]  垃圾清理     扫描并清理临时文件/缓存/回收站" -ForegroundColor White
    Write-Host "    [3]  开机加速     管理开机启动项(可一键还原)" -ForegroundColor White
    Write-Host "    [4]  软件卸载     强力卸载 + 扫残留(顽固软件也能卸)" -ForegroundColor White
    Write-Host "    [5]  安全护盾     换/卸杀软前必跑：查/开 Defender+防火墙+更新" -ForegroundColor White
    Write-Host "    [6]  守夜模式     让 AI 通宵干活：不熄屏/不睡眠(退出自动还原)" -ForegroundColor White
    Write-Host "    [7]  进程管理     列出运行进程并结束占用资源的进程" -ForegroundColor White
    Write-Host "    [8]  检查更新     看看有没有新版(只查不装，不上传任何信息)" -ForegroundColor White
    Write-Host "    [9]  软件搬家     微信/QQ/钉钉数据迁到别的盘(原位置留联接，可还原)" -ForegroundColor White
    Write-Host ""
    Write-Host "    [0]  退出" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  -------------------------------------------------------------------"
}

function Network-Menu {
    Write-Host ""
    Write-Host "  --- 网络修复 ---" -ForegroundColor Cyan
    Write-Host "    [1] 网络体检(先做这个，自动判断病因)"
    Write-Host "    [2] 一键全修复(winsock+tcpip+dns+ip+代理)"
    Write-Host "    [3] 只清代理 + 换公共DNS"
    Write-Host "    [9] 返回"
    $c = Read-Host "  选择"
    switch ($c) {
        '1' { Run-Engine 'network.ps1' @('diagnose') }
        '2' { Run-Engine 'network.ps1' @('repair-all') }
        '3' { Run-Engine 'network.ps1' @('clear-proxy'); Run-Engine 'network.ps1' @('set-dns') }
    }
    if ($c -ne '9') { Read-Host "`n  按回车继续" | Out-Null }
}

function Relocate-Menu {
    Write-Host ""
    Write-Host "  --- 软件搬家 ---" -ForegroundColor Cyan
    Write-Host "    [1] 查看可搬家的软件数据目录(微信/QQ/钉钉/企业微信)"
    Write-Host "    [2] 搬家(数据目录整体移到别的盘，原位置留联接，软件无感)"
    Write-Host "    [3] 还原(搬过的移回 C 盘原位置)"
    Write-Host "    [9] 返回"
    $c = Read-Host "  选择"
    switch ($c) {
        '1' { Run-Engine 'relocate.ps1' @('list') }
        '2' {
            Run-Engine 'relocate.ps1' @('list')
            $app = Read-Host "  要搬家哪个？(wechat/qq/dingtalk/wxwork)"
            if ($app) {
                $target = Read-Host "  搬到哪个目录？(如 D:\Open365搬家，不能和源目录同盘)"
                if ($target) { Run-Engine 'relocate.ps1' @('move', '-App', $app, '-Target', $target) }
            }
        }
        '3' {
            Run-Engine 'relocate.ps1' @('list')
            $app = Read-Host "  要还原哪个？(wechat/qq/dingtalk/wxwork)"
            if ($app) { Run-Engine 'relocate.ps1' @('restore', '-App', $app) }
        }
    }
    if ($c -ne '9') { Read-Host "`n  按回车继续" | Out-Null }
}

while ($true) {
    Show-Menu
    $choice = Read-Host "  请输入数字"
    switch ($choice) {
        '1' { Network-Menu }
        '2' {
            Run-Engine 'cleaner.ps1' @('scan')
            $go = Read-Host "  要执行清理吗？(Y/n)"
            if (-not $go -or $go -match '^[Yy]') { Run-Engine 'cleaner.ps1' @('clean') }
            Read-Host "`n  按回车继续" | Out-Null
        }
        '3' {
            Run-Engine 'startup.ps1' @('list')
            Write-Host "  禁用/恢复请用命令: open365 startup disable -Id <id>" -ForegroundColor Cyan
            Read-Host "`n  按回车继续" | Out-Null
        }
        '4' {
            $kw = Read-Host "  输入软件名关键词搜索(如 某软件)"
            if ($kw) {
                Run-Engine 'uninstall.ps1' @('search', $kw)
                Write-Host "  卸载请用命令: open365 uninstall uninstall <id>" -ForegroundColor Cyan
            }
            Read-Host "`n  按回车继续" | Out-Null
        }
        '5' {
            Run-Engine 'security.ps1' @('check')
            $go = Read-Host "  发现隐患要一键复位吗？(开启 Defender+防火墙+更新) (Y/n)"
            if (-not $go -or $go -match '^[Yy]') { Run-Engine 'security.ps1' @('enable-all') }
            Read-Host "`n  按回车继续" | Out-Null
        }
        '6' {
            $h = Read-Host "  守几小时后自动退出？(直接回车=一直保持到按键)"
            if ($h -match '^\d+$' -and [int]$h -gt 0) {
                Run-Engine 'focus.ps1' @('on', '-Hours', $h)
            } else {
                Run-Engine 'focus.ps1' @('on')
            }
            Read-Host "`n  按回车继续" | Out-Null
        }
        '7' {
            Run-Engine 'process.ps1' @('list')
            Write-Host "  结束某进程请用命令: open365 process kill -Id <PID>" -ForegroundColor Cyan
            Read-Host "`n  按回车继续" | Out-Null
        }
        '8' {
            Run-Engine 'update.ps1' @('check')
            Read-Host "`n  按回车继续" | Out-Null
        }
        '9' { Relocate-Menu }
        '0' { return }
    }
}
