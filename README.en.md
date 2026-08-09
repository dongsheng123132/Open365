<p align="center"><img src="docs/open365-demo.png" alt="Open365 running a read-only cleanup scan with itemized results" width="700" /></p>

<h1 align="center">Open365</h1>

<p align="center"><strong>An open-source, offline Windows maintenance assistant with no ads, bundles, telemetry, or background service.</strong></p>

<p align="center">
  <a href="README.md">中文</a> ·
  <a href="#install">Install</a> ·
  <a href="AGENTS.md">Automation guide</a> ·
  <a href="LICENSE">Apache-2.0</a>
</p>

Open365 rebuilds the practical parts of a PC utility suite with Windows-native tools only: PowerShell, `netsh`, `ipconfig`, registry APIs, and C# WinForms. It has no custom driver, no bundled SDK, no cloud account, and no network upload path.

## What it does

| Feature | Safety model |
| --- | --- |
| Network diagnostics and repair | Diagnoses the likely cause before applying the smallest repair. |
| Disk cleanup | Scans first; cleanup is explicit and targets only known-safe cache and temporary locations. |
| Startup and process management | Disabled startup items are restorable; critical system processes are protected. |
| Software uninstall and residue cleanup | Backs up recoverable residue before removal. |
| Windows security check | Checks and restores Defender, Firewall, and Windows Update. |
| Focus mode | Keeps a computer awake for unattended AI work and restores settings when it exits. |

## Install

Windows 10/11 includes the required runtime. Clone the repository and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

Options: `-Autostart` enables startup; `-NoLaunch` builds without opening the tray app; `-Uninstall` removes shortcuts and the autostart task without touching the source or your data.

## Human, CLI, and AI use the same actions

The GUI is a thin control surface. Its buttons call the same action core used by the CLI and AI automation, so the behavior is implemented once and can be verified without driving pixels.

```powershell
powershell -File core\action-core.ps1 list -Json
powershell -File core\action-core.ps1 describe security.check -Json
powershell -File core\action-core.ps1 run security.check -Json
powershell -File core\action-core.ps1 verify -Json
```

Coding agents can discover the authoritative registry, generated files, and exact
verification commands through `action-parity context . --json`. Executable evidence
is declared in `action-parity.verify.json` and correlates caller and core execution IDs.

Read-only actions are safe to inspect. System-changing actions require explicit confirmation. For the complete Chinese guide, commands, safety notes, and roadmap, see [README.md](README.md).

## License

[Apache-2.0](LICENSE)
