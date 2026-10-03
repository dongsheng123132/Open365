param([string]$OutputDirectory = 'artifacts/startup-ui')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$out = [IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
[void][IO.Directory]::CreateDirectory($out)
$exe = Join-Path $out 'startup-ui-tests.exe'
$sources = @(Get-ChildItem -LiteralPath (Join-Path $root 'gui') -Filter '*.cs' | ForEach-Object { $_.FullName })
$sources += Join-Path $PSScriptRoot 'StartupUiTests.cs'
$csc = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
& $csc /nologo /target:exe /main:Open365.StartupUiTests "/out:$exe" /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll /reference:System.Web.Extensions.dll @sources
if ($LASTEXITCODE -ne 0) { exit 1 }
$oldScale = $env:OPEN365_UI_SCALE
try {
    foreach ($scale in @('1', '1.5')) {
        $env:OPEN365_UI_SCALE = $scale
        $target = Join-Path $out $scale
        & $exe $target
        if ($LASTEXITCODE -ne 0) { exit 1 }
    }
} finally { $env:OPEN365_UI_SCALE = $oldScale }
