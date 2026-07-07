# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Open365 is a Windows maintenance tool (无广告 · 无弹窗 · 无捆绑). All engines are pure PowerShell built on Windows built-in APIs (`netsh`, `Get-*` cmdlets, registry). No external dependencies, no background services, no network uploads.

Current version: 1.1.0

## Commands

### Run all tests
```powershell
powershell -ExecutionPolicy Bypass -File tests\run-all.ps1
```

### Run a single test file
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test-network.ps1
```

### Build the GUI exe
```powershell
powershell -ExecutionPolicy Bypass -File tools\build-gui.ps1
```
Requires .NET Framework 4.x (uses Windows built-in `csc.exe`). Output: `Open365.exe`.

### Fix UTF-8 BOM after creating a new engine file
```powershell
powershell -ExecutionPolicy Bypass -File tools\add-bom.ps1
```
Windows PowerShell 5.x needs UTF-8 BOM to read Chinese characters correctly. Run this after creating any new `.ps1` file with Chinese content.

### Run the main tool interactively
```powershell
powershell -ExecutionPolicy Bypass -File open365.ps1
```
Or double-click `open365.bat` (auto-elevates to admin).

## Architecture — the single most important rule

**Each engine in `engine/*.ps1` is fully independent. No cross-engine calls, no shared library.**

`open365.ps1` is only a dispatcher — it never contains business logic. All real work lives in `engine/*.ps1`.

### Engine file contract

Every engine follows this exact pattern:

```powershell
param(
    [Parameter(Position = 0)]
    [ValidateSet('action1', 'action2', ..., 'help')]
    [string]$Action = 'help',   # default MUST be read-only
    [switch]$Json,              # structured output for GUI/automation
    ...
)
```

Rules enforced by `docs/架构约定.md`:
1. Default action must be **read-only** (e.g. `list`, `diagnose`, `check`, `status`).
2. Any action that modifies the system must call `Require-Admin` first.
3. Destructive actions must be reversible where possible (e.g. startup disable = move to backup, not delete).
4. Helper functions (`Test-Admin`, `Write-Step`, etc.) are **duplicated per engine** — do not extract a shared library.
5. All engines support `-Json` for structured output (`ConvertTo-Json -Depth 6 -Compress`).

### Adding a new engine

1. Create `engine/<name>.ps1` following the contract above.
2. Run `tools/add-bom.ps1` to add UTF-8 BOM.
3. Verify it runs standalone: `powershell -File engine/<name>.ps1 help`
4. Add two lines to `open365.ps1`: one in the `switch` dispatcher, one in the interactive menu.
5. Add a test in `tests/test-<name>.ps1` using the **mock fault → verify fix → auto-restore** pattern.
6. Update README function table, command list, and roadmap.

### Wiring into `open365.ps1`

```powershell
# In the switch ($Cmd) block:
'foo' { Run-Engine 'foo.ps1' $argv }

# In the while ($true) menu loop:
'8' { Run-Engine 'foo.ps1' @('list') ... }
```

## Current engines

| File | Default action | Key actions |
|------|----------------|-------------|
| `engine/network.ps1` | `help` | `diagnose` (read-only), `repair-all`, `clear-proxy`, `set-dns` |
| `engine/cleaner.ps1` | — | `scan` (read-only), `clean` |
| `engine/startup.ps1` | — | `list`, `disable -Id`, `enable -Id` |
| `engine/process.ps1` | `help` | `list`, `kill -Id` |
| `engine/uninstall.ps1` | — | `search`, `uninstall`, `residue` |
| `engine/security.ps1` | — | `check` (read-only), `enable-all`, `scan` |
| `engine/focus.ps1` | — | `on`, `on -Hours N`, `status` |

## GUI (C# WinForms)

Source: `gui/Open365Tray.cs` (system tray) + `gui/Open365Manager.cs` (management window).

The GUI is a "button panel" only — it calls engine scripts via `powershell -File engine/*.ps1 -Json` and parses the JSON output to render the UI. No business logic lives in the GUI code.

Compiled with Windows built-in `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`. References: `System.dll`, `System.Drawing.dll`, `System.Windows.Forms.dll`, `System.Web.Extensions.dll`, `Microsoft.VisualBasic.dll`. No NuGet packages.

After changing any `gui/*.cs` file, rebuild with `tools\build-gui.ps1`.

## Test pattern

Tests follow: **inject fake fault → run engine → assert it fixed → restore original state**.
Tests must not touch real user data. See `tests/test-network.ps1` for a reference implementation.
