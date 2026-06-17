# Add UTF-8 BOM to all .ps1 files so Windows PowerShell 5.x parses Chinese correctly.
# Usage: powershell -ExecutionPolicy Bypass -File tools\add-bom.ps1
# (Kept ASCII-only on purpose so this bootstrap file never needs a BOM itself.)
$root = Split-Path $PSScriptRoot -Parent
$bom = New-Object System.Text.UTF8Encoding($true)
$count = 0
Get-ChildItem -Path $root -Recurse -Include *.ps1 |
    Where-Object { $_.FullName -notmatch 'add-bom\.ps1$' } |
    ForEach-Object {
        $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
        $hasBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
        if (-not $hasBom) {
            $txt = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
            [System.IO.File]::WriteAllText($_.FullName, $txt, $bom)
            Write-Output "  + BOM added: $($_.Name)"
            $count++
        }
    }
Write-Output "Done. Processed $count file(s)."
