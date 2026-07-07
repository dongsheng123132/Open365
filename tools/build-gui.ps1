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

$src = @(
    (Join-Path $gui 'Open365Tray.cs'),
    (Join-Path $gui 'Open365Manager.cs')
)
foreach ($f in $src) { if (-not (Test-Path $f)) { Write-Host "缺源文件: $f" -ForegroundColor Red; exit 1 } }

$cscArgs = @(
    '/nologo',
    '/target:winexe',
    '/optimize+',
    ('/out:' + $out),
    ('/win32manifest:' + (Join-Path $gui 'app.manifest')),
    '/reference:System.dll',
    '/reference:System.Drawing.dll',
    '/reference:System.Windows.Forms.dll',
    '/reference:System.Web.Extensions.dll',
    '/reference:Microsoft.VisualBasic.dll'
) + $src

& $csc @cscArgs
if ($LASTEXITCODE -eq 0) {
    $kb = [math]::Round((Get-Item $out).Length / 1KB, 1)
    Write-Host "[OK] 编译成功 -> $out ($kb KB)" -ForegroundColor Green
} else {
    Write-Host "[FAIL] 编译失败 (exit $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}
