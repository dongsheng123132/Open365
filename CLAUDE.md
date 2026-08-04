# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

Open365 is a Windows maintenance tool (无广告 · 无弹窗 · 无捆绑). All engines are pure PowerShell built on Windows built-in APIs (`netsh`, `Get-*` cmdlets, registry). No external dependencies, no background services, no network uploads. The only outbound request in the whole program is the user-initiated update check — see `engine/update.ps1` below.

Current version: read `VERSION` (single source of truth — the GUI, `core/registry.ps1`
and the update check all read that file; never hard-code a version number anywhere).

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

### Action Core (ActionParity / 影核协议)

`core/action-core.ps1` is the one entry point GUI, CLI, and AI all share. It adds
discovery, input/output contract validation, a deny-by-default gate for
system-changing actions, and a headless self-test. Dependency direction is
`core -> engine` only; engines stay unaware of it and still never reference each
other.

- `core/registry.ps1` is the **single source of truth** (action IDs, schemas,
  risk, bindings). `action-parity.json` is generated from it — never hand-edit;
  regenerate with `core\action-core.ps1 manifest -WriteManifest`.
- To share a new engine action: register it, call it from the GUI via
  `Program.RunAction("<id>", input, confirm)`, and set a stable
  `Name`/`AccessibleName` on the control.
- Verify with `powershell -File core\action-core.ps1 verify` and
  `powershell -File tests\test-action-parity.ps1`.
- Invoke it with `-File`, never `-Command`: `-Command` collapses the script exit
  code to 1 and destroys the 0/1/2/3 semantics.

Details and the current conformance boundary: [docs/影核协议改造.md](docs/影核协议改造.md).

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
| `engine/update.ps1` | `help` | `check` (read-only), `sources` |

### The one engine that goes out to the network — `engine/update.ps1`

Every other engine is strictly local. `update.ps1` is the single exception, and the
constraints on it are a product promise, not an implementation detail — do not relax
them without changing the README's 联网说明 table first:

- **Only when the user asks.** No startup check, no background timer, no telemetry.
  The GUI entry point is the 关于 dialog's 检查更新 button, nothing else.
- **GET only, empty body.** No machine ID, no hardware info, no usage stats.
- **Never downloads or installs.** It reports a version and a URL; the user decides.
- **`-Url` / `OPEN365_UPDATE_URL` is exclusive** — when a self-hosted source is given,
  it must NOT fall back to github (an intranet deployment must not silently phone home).
- **An unparseable remote version is `unknown`, never `update-available`** — never
  push a user toward a download based on a version string we couldn't compare.

Source of truth is the latest GitHub Release tag (API first for the release notes,
302-redirect on `/releases/latest` as the un-rate-limited fallback). Deliberately
**no `version.json` in the repo**: a second copy of the version number would drift
from the tag. Tests (`tests/test-update.ps1`) are fully offline — they feed fake
manifests through `-Url` and must never hit the network.

## GUI (C# WinForms)

Source: `gui/Open365Tray.cs` (system tray) + `gui/Open365Manager.cs` / `gui/Open365Pages.cs`
(management window) + `gui/Open365Dpi.cs` (high-DPI scaling).

The GUI is a "button panel" only — it calls engine scripts via `powershell -File engine/*.ps1 -Json` and parses the JSON output to render the UI. No business logic lives in the GUI code.

Compiled with Windows built-in `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`. References: `System.dll`, `System.Drawing.dll`, `System.Windows.Forms.dll`, `System.Web.Extensions.dll`, `Microsoft.VisualBasic.dll`. No NuGet packages.

After changing any `gui/*.cs` file, rebuild with `tools\build-gui.ps1`.
**Keep the UTF-8 BOM on every `gui/*.cs`** — without it `csc` decodes the file with the
system ANSI codepage and every Chinese string ships as mojibake.

### High-DPI rules (`gui/Open365Dpi.cs`) — read before touching layout

`app.manifest` declares `dpiAware=true`, so Windows does **not** bitmap-stretch us: the app
must scale itself. Point-sized fonts already grow with DPI; pixel coordinates do not. So:

* Layout is authored at **96 DPI design pixels**, then `Dpi.Apply(form)` scales the whole tree
  once (`Control.Scale` moves Bounds/Padding/Margin/MinimumSize but deliberately leaves `Font`
  alone — the DPI already handled the font).
* Anything `Control.Scale` can't reach must go through **`Dpi.Px(n)`**: `DataGridView`
  row/header heights, `DataGridViewCellStyle.Padding`, icon bitmap sizes (`Program.MdlIcon`
  scales internally — pass design px), owner-drawn offsets, and **anything built after the
  form was scaled** (e.g. `AddIssue`, the residue dialog).
* Constants inside `Resize` / `VisibleChanged` handlers must be `Dpi.Px(n)` too — those
  callbacks re-fire after scaling and will otherwise drag the layout back to 96 DPI.
* Font sizes go through **`Dpi.Pt(n)`** (a no-op in normal use; it only applies the extra
  factor when `OPEN365_UI_SCALE` is set).
* Pages are built detached and mounted on first click — mount them via `Mount(page)` so
  `Dpi.ScaleOnce` catches them. `Form.Scale` cannot reach a panel that isn't in the tree yet;
  this was the actual cause of the "everything squashed together" bug.
* Docking is processed **from the end of `Controls` backwards** — add children in reverse
  visual order (title card last, or it lands underneath its own content).

Verify without a high-DPI monitor: set `OPEN365_UI_SCALE=1.5`, which scales layout *and*
fonts so a 96-DPI dev box reproduces a 150% machine's real layout.

## Test pattern

Tests follow: **inject fake fault → run engine → assert it fixed → restore original state**.
Tests must not touch real user data. See `tests/test-network.ps1` for a reference implementation.
