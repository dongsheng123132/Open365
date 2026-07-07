<#
  注销 360 残留的内核驱动与服务（卸载后仍在运行的自我保护驱动）。
  已加载的驱动在 sc delete 后需重启才彻底卸下。逐项记日志。
#>
$ErrorActionPreference = 'Continue'
$log = "C:\Users\ZhuanZ\Desktop\Open365\.tmp-drv-360.log"
"=== 注销 360 驱动/服务 ===" | Set-Content -Path $log -Encoding UTF8
function Log($m) { $m | Add-Content -Path $log -Encoding UTF8 }

$drivers = @(
    '360AntiHacker','360AntiHijack','360AntiSteal','360Camera',
    '360FsFlt','360Hvm','360qpesv','BAPIDRV','360AntiAttack'
)
$services = @('360bpsvc','Q360AMPPL')

foreach ($n in ($drivers + $services)) {
    $stop = (& sc.exe stop "$n" 2>&1) -join ' '
    $del  = (& sc.exe delete "$n" 2>&1) -join ' '
    Log ("[{0}] stop: {1} | delete: {2}" -f $n, $stop.Trim(), $del.Trim())
}
Log "=== 完成（重启后驱动彻底卸下）==="
