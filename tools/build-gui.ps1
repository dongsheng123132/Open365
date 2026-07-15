# 编译 Open365 GUI -> Open365.exe
# 用 Windows 自带的 .NET Framework csc（无需安装任何 SDK / VS），保持"透明、零依赖"。
# 用法: powershell -ExecutionPolicy Bypass -File tools\build-gui.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$gui = Join-Path $root 'gui'
$out = Join-Path $root 'Open365.exe'

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }
if (-not (Test-Path $csc)) { Write-Host "找不到 csc.exe（需要 .NET Framework 4.x）" -ForegroundColor Red; exit 1 }

$src = @(Get-ChildItem -Path $gui -Filter '*.cs' | ForEach-Object { $_.FullName })
if ($src.Count -eq 0) { Write-Host "gui/ 下没有源文件" -ForegroundColor Red; exit 1 }

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    ('/out:' + $out),
    ('/win32manifest:' + (Join-Path $gui 'app.manifest')),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll'
) + $src

& $csc @cscArgs
if ($LASTEXITCODE -eq 0) {
    $kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
    Write-Host "[OK] 编译成功 -> $out ($kb KB)" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 编译失败 (exit $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}
