# 开发用：启动 GUI、截下管理中心窗口、关掉进程。只为人眼验收界面，不参与构建。
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-shot.ps1 -Page startup -Out C:\tmp\a.png
param(
    [string]$Page = 'home',
    [string]$Out = "$env:TEMP\open365-ui.png",
    [int]$Wait = 5000,
    [string]$Exe                      # 不传就自动优先用 build-gui-preview.ps1 产的免提权副本
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @"
using System;using System.Collections.Generic;using System.Runtime.InteropServices;
public class Win32 {
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L,T,R,B; }

  // 托盘程序的 MainWindowHandle 往往是那个隐藏的消息窗口（会停在 -25600,-25600），
  // 不是我们要截的管理中心窗体。所以按 pid 枚举，挑面积最大的可见窗口。
  public static IntPtr BiggestVisible(int pid) {
    IntPtr best = IntPtr.Zero; long bestArea = 0;
    EnumWindows(delegate(IntPtr h, IntPtr p) {
      int wpid; GetWindowThreadProcessId(h, out wpid);
      if (wpid != pid || !IsWindowVisible(h)) return true;
      RECT r; if (!GetWindowRect(h, out r)) return true;
      long area = (long)(r.R - r.L) * (r.B - r.T);
      if ((r.R - r.L) < 200 || (r.B - r.T) < 200) return true;   // 滤掉消息窗/提示窗
      if (area > bestArea) { bestArea = area; best = h; }
      return true;
    }, IntPtr.Zero);
    return best;
  }
}
"@

# 本脚本必须自己声明 DPI 感知，否则在高分屏（比如 2048x1280）上 Windows 会给
# 我们**虚拟化后的**坐标：GetWindowRect 报 1014 宽，实际窗口是它的两倍，
# CopyFromScreen 只截到窗口左上角四分之一，看起来就像「表格右边被切掉了」。
[void][Win32]::SetProcessDPIAware()

$root = Split-Path $PSScriptRoot -Parent
# 正式 exe 是 requireAdministrator：非提权的本脚本既 SetWindowPos 不动它、也
# SetForegroundWindow 不了它（UIPI 隔离），最后会把屏幕 (0,0) 处**别人的窗口**
# 截下来还报 [OK]。所以默认优先用 build-gui-preview.ps1 产的 asInvoker 副本。
if (-not $Exe) {
    $preview = Join-Path $env:TEMP 'o365ui\Open365.exe'
    $Exe = if (Test-Path $preview) { $preview } else { Join-Path $root 'Open365.exe' }
}
$exe = $Exe
if (-not (Test-Path $exe)) { Write-Host "没有 Open365.exe，先跑 tools\build-gui-preview.ps1（截图用）或 tools\build-gui.ps1"; exit 1 }
Write-Host "[..] 截图目标: $exe"

$p = Start-Process -FilePath $exe -ArgumentList '--open', $Page -PassThru
try {
    # 先轮询等窗口出现，再等 $Wait 让页面把内容填好。
    # 两段分开是有意的：窗口出现 ≠ 内容就绪，清理页要先跑完一次扫描才有行，
    # 一看到窗口就截会得到一张空表。
    $h = [IntPtr]::Zero
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        if ($p.HasExited) { Write-Host "进程提前退出了"; exit 2 }
        $h = [Win32]::BiggestVisible($p.Id)
        if ($h -ne [IntPtr]::Zero) { break }
    }
    if ($h -eq [IntPtr]::Zero) { Write-Host "拿不到窗口句柄"; exit 2 }
    Write-Host "[..] 窗口已出现，等 $Wait ms 让页面加载完"
    Start-Sleep -Milliseconds $Wait
    # 先把窗口钉到屏幕左上角再截：GetWindowRect 拿到的是含 DWM 阴影边的坐标，
    # 直接按它 CopyFromScreen 会整体偏移，截出一圈桌面背景。
    # HWND_TOP=0, SWP_NOSIZE=0x0001 | SWP_SHOWWINDOW=0x0040
    [void][Win32]::SetWindowPos($h, [IntPtr]::Zero, 0, 0, 0, 0, 0x0041)
    [void][Win32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 900
    $r = New-Object Win32+RECT
    [void][Win32]::GetWindowRect($h, [ref]$r)
    $w = $r.R - $r.L; $ht = $r.B - $r.T
    if ($w -lt 200 -or $ht -lt 200) { Write-Host "[FAIL] 窗口尺寸异常 ($w x $ht)"; exit 3 }

    # 用 PrintWindow 直接向窗口要它自己的像素，而不是去屏幕上「抠」那块区域。
    # CopyFromScreen 有两个治不好的毛病：窗口被别的程序盖住就截到别人（后台
    # 进程调 SetForegroundWindow 会被 Windows 拦掉，这事经常发生），以及必须
    # 先把窗口挪到左上角。PW_RENDERFULLCONTENT=0x2 连带把 WinForms 的内容画全。
    $bmp = New-Object System.Drawing.Bitmap $w, $ht
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $hdc = $g.GetHdc()
    $ok = [Win32]::PrintWindow($h, $hdc, 0x2)
    $g.ReleaseHdc($hdc)
    if (-not $ok) {
        $g.Dispose(); $bmp.Dispose()
        Write-Host "[FAIL] PrintWindow 失败，没有截到窗口内容"
        exit 4
    }
    $bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Host "[OK] $Out  ($w x $ht)"
} finally {
    try { $p.Kill() } catch { }
}
