# 开发用：把 GUI 编成一份 **不要求管理员** 的副本，放到 %TEMP%\o365ui\ 里。
# 只为在无人值守（不弹 UAC）的情况下截图验收界面 —— 布局与正式 exe 完全一致，
# 区别只是 manifest 里 requireAdministrator 换成 asInvoker，改系统的动作会失败。
# 不产出到仓库，不参与发布。用法: powershell -NoProfile -ExecutionPolicy Bypass -File tools\build-gui-preview.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$gui = Join-Path $root 'gui'
$dst = Join-Path $env:TEMP 'o365ui'
New-Item -ItemType Directory -Force -Path $dst | Out-Null

$man = Join-Path $dst 'preview.manifest'
(Get-Content (Join-Path $gui 'app.manifest') -Raw).Replace('requireAdministrator', 'asInvoker') |
    Set-Content -Path $man -Encoding UTF8

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

$src = @(Get-ChildItem -Path $gui -Filter '*.cs' | ForEach-Object { $_.FullName })
$cscArgs = @(
    '/nologo', '/target:winexe',
    ('/out:' + (Join-Path $dst 'Open365.exe')),
    ('/win32manifest:' + $man),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll'
) + $src

& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { Write-Host '[FAIL] 预览版编译失败'; exit 1 }

Copy-Item (Join-Path $root 'VERSION') $dst -Force
Copy-Item (Join-Path $root 'engine') $dst -Recurse -Force
Copy-Item (Join-Path $root 'core') $dst -Recurse -Force
Write-Host "[OK] 预览版 -> $dst\Open365.exe"
