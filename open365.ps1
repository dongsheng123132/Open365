<#
  Open365 主程序 —— 开源替代 360 安全卫士
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

# ---- 直接命令模式：open365.ps1 network diagnose ----
if ($Cmd) {
    $argv = @($Sub) + @($Rest) | Where-Object { $_ -ne $null }
    switch ($Cmd) {
        'network'   { Run-Engine 'network.ps1'   $argv }
        'clean'     { Run-Engine 'cleaner.ps1'   (@('clean') + $argv) }
        'scan'      { Run-Engine 'cleaner.ps1'   (@('scan')  + $argv) }
        'cleaner'   { Run-Engine 'cleaner.ps1'   $argv }
        'startup'   { Run-Engine 'startup.ps1'   $argv }
        'uninstall' { Run-Engine 'uninstall.ps1' $argv }
        default     { Write-Host "未知命令: $Cmd" -ForegroundColor Red }
    }
    return
}

# ---- 交互菜单模式 ----
function Show-Menu {
    Clear-Host
    Write-Host ""
    Write-Host "  ===================================================================" -ForegroundColor Cyan
    Write-Host "        Open365   开源电脑助手   (替代 360，无广告 · 无捆绑)" -ForegroundColor White
    Write-Host "  ===================================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "    [1]  网络修复     专治'微信能上、网页打不开'(LSP/Winsock)" -ForegroundColor White
    Write-Host "    [2]  垃圾清理     扫描并清理临时文件/缓存/回收站" -ForegroundColor White
    Write-Host "    [3]  开机加速     管理开机启动项(可一键还原)" -ForegroundColor White
    Write-Host "    [4]  软件卸载     强力卸载 + 扫残留(可用来卸 360)" -ForegroundColor White
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
            $kw = Read-Host "  输入软件名关键词搜索(如 360)"
            if ($kw) {
                Run-Engine 'uninstall.ps1' @('search', $kw)
                Write-Host "  卸载请用命令: open365 uninstall uninstall <id>" -ForegroundColor Cyan
            }
            Read-Host "`n  按回车继续" | Out-Null
        }
        '0' { return }
    }
}
