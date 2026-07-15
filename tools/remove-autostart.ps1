# Remove the Open365 tray auto-start scheduled task.
schtasks.exe /Delete /TN 'Open365Tray' /F
