<#
  ActionParity 可执行证据入口。

  先运行现有无头契约测试，再用同一份 C# GUI Host 源码编译控制台测试外壳，
  分别从 GUI bridge 与公共 CLI 把调用方 execution_id 送进动作核心。
  输出文件只记录真实观察；任一 ID 没有原样到达核心，脚本即失败。
#>

param(
    [string]$ObservationsPath = 'artifacts/action-parity/parity-observations.json'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$root = Split-Path $PSScriptRoot -Parent
$manifestPath = Join-Path $root 'action-parity.json'
$harness = Join-Path $root '_harness.exe'
$inputFiles = @()

function New-ProbeInput($action) {
    $probe = [ordered]@{}
    foreach ($name in @($action.input_schema.required | Where-Object { $_ })) {
        if ($name -eq 'query') { $probe[$name] = 'open365' }
        elseif ($name -eq 'id') { $probe[$name] = 'reg:hklm-run:Open365EvidenceProbe' }
        else { $probe[$name] = 'open365-evidence-probe' }
    }
    return $probe
}

function New-InputFile([string]$json) {
    $path = Join-Path $env:TEMP ('open365-evidence-' + [guid]::NewGuid().ToString('N') + '.json')
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:inputFiles += $path
    return $path
}

function Parse-Envelope($text) {
    try { return (($text | Out-String).Trim() | ConvertFrom-Json) } catch { return $null }
}

try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'test-action-parity.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Open365 动作契约测试失败。' }

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\build-gui.ps1') -TestHarness
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $harness)) { throw 'GUI Host 测试外壳编译失败。' }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $observations = @()
    $failures = @()

    foreach ($action in @($manifest.actions)) {
        $inputJson = (New-ProbeInput $action) | ConvertTo-Json -Compress
        foreach ($binding in @($action.bindings | Where-Object { $_.surface -in @('desktop', 'cli') })) {
            $requestId = 'open365-' + $binding.surface + '-' + [guid]::NewGuid().ToString('N')
            $envelope = $null

            if ($binding.surface -eq 'desktop') {
                $encoded = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($inputJson))
                $text = & $harness --action-test $action.id --execution-id $requestId --input-base64 $encoded 2>$null
                $envelope = Parse-Envelope $text
            } else {
                $inputFile = New-InputFile $inputJson
                $text = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'open365.ps1') action run $action.id -ExecutionId $requestId -InputFile $inputFile -Json 2>$null
                $envelope = Parse-Envelope $text
            }

            $coreId = if ($envelope) { [string]$envelope.execution_id } else { '' }
            if (-not $envelope -or $coreId -ne $requestId) {
                $failures += "$($action.id)@$($binding.surface): request=$requestId core=$coreId"
                continue
            }
            $observations += [ordered]@{
                action_id            = $action.id
                surface              = $binding.surface
                request_execution_id = $requestId
                core_execution_id    = $coreId
            }
        }
    }

    if ($failures.Count -gt 0) { throw ('执行 ID 没有到达同一核心: ' + ($failures -join '; ')) }

    $target = if ([System.IO.Path]::IsPathRooted($ObservationsPath)) {
        $ObservationsPath
    } else {
        Join-Path $root $ObservationsPath
    }
    $target = [System.IO.Path]::GetFullPath($target)
    $parent = Split-Path $target -Parent
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($target, (($observations | ConvertTo-Json -Depth 6) + "`n"), (New-Object System.Text.UTF8Encoding($false)))
    Write-Output "observed`t$($observations.Count)`t$target"
} finally {
    foreach ($path in $inputFiles) { Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $harness -ErrorAction SilentlyContinue
}
