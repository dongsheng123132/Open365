<#
.SYNOPSIS
    按关键词一键清理某软件的卸载残留（目录 + 注册表），留底可回滚。

.DESCRIPTION
    这是命令行便捷封装 —— 真正的清理逻辑在 engine\uninstall.ps1 的 residue-clean 里
    （目录移到备份区、注册表导出 .reg 后删，写「还原说明.txt」，绝不硬删）。
    复用引擎能力、不重复造轮子。

.PARAMETER Keyword
    要清理残留的软件名关键词（如某已卸载软件的品牌名）。必填，至少 2 个字符；
    过短或命中危险黑名单（windows/system/... ）会被引擎安全拦截。

.PARAMETER Yes
    跳过交互确认（自动化 / AI 用）。

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\clean-vendor-residue.ps1 -Keyword 某软件
    powershell -ExecutionPolicy Bypass -File tools\clean-vendor-residue.ps1 -Keyword 某软件 -Yes

.NOTES
    备份/还原位置在 %LOCALAPPDATA%\Open365\residue-backup\ 下，随时可搬回。
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$Keyword,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$engine = Join-Path (Split-Path $PSScriptRoot -Parent) 'engine\uninstall.ps1'
if (-not (Test-Path $engine)) { Write-Host "找不到引擎: $engine" -ForegroundColor Red; exit 1 }

# 注意：switch 参数不能靠数组 splat 传（会被当成位置参数），用 -Yes:$Yes 显式绑定。
& $engine residue-clean $Keyword -Yes:$Yes
exit $LASTEXITCODE
