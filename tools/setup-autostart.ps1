# Create a logon scheduled task so Open365 tray auto-starts elevated (no UAC at logon).
$exe = 'C:\Users\ZhuanZ\Desktop\Open365\Open365.exe'
$log = 'C:\Users\ZhuanZ\Desktop\Open365\.tmp-task.log'
$out = schtasks.exe /Create /TN 'Open365Tray' /TR "`"$exe`"" /SC ONLOGON /RL HIGHEST /F 2>&1
$verify = schtasks.exe /Query /TN 'Open365Tray' /FO LIST 2>&1
Set-Content -Path $log -Value (@($out) + '----VERIFY----' + @($verify)) -Encoding UTF8
