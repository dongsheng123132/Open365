# Convert a .bat from UTF-8 to GBK (so Chinese cmd parses it without garbling).
# Usage: powershell -ExecutionPolicy Bypass -File tools\bat-to-gbk.ps1 <path-to-bat>
param([Parameter(Mandatory=$true)][string]$Path)
$txt = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
$gbk = [System.Text.Encoding]::GetEncoding(936)
[System.IO.File]::WriteAllText($Path, $txt, $gbk)
Write-Output "Converted to GBK: $Path"
