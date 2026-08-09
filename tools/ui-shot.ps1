# 开发用：启动 GUI、截下管理中心窗口、关掉进程。只为人眼验收界面，不参与构建。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-shot.ps1 -Page startup -Out C:\tmp\a.png
param(
    [string]$Page = 'home',
    [string]$Out = "$env:TEMP\open365-ui.png",
    [int]$Wait = 5000
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }
}
"@

$root = Split-Path $PSScriptRoot -Parent
$exe = Join-Path $root 'Open365.exe'
if (-not (Test-Path $exe)) { Write-Host "没有 Open365.exe，先跑 tools\build-gui.ps1"; exit 1 }

$p = Start-Process -FilePath $exe -ArgumentList '--open', $Page -PassThru
try {
    Start-Sleep -Milliseconds $Wait
    $p.Refresh()
    $h = $p.MainWindowHandle
    if ($h -eq [IntPtr]::Zero) { Write-Host "拿不到窗口句柄"; exit 2 }
    # 先把窗口钉到屏幕左上角再截：GetWindowRect 拿到的是含 DWM 阴影边的坐标，
    # 直接按它 CopyFromScreen 会整体偏移，截出一圈桌面背景。
    # HWND_TOP=0, SWP_NOSIZE=0x0001 | SWP_SHOWWINDOW=0x0040
    [void][Win32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0041)
    [void][Win32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 900
    $r = New-Object Win32+RECT
    [void][Win32]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    $r.L = 0; $r.T = 0
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht))
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "[OK] $Out  ($w x $ht)"
} finally {
    try { $p.Kill() } catch { }
}
