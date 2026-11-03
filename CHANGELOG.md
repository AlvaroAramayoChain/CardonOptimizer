# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-11-03

### Added
- Device type screen after the language selector: `1) Desktop  2) Notebook / laptop  0) Back`.
  The battery (`Win32_Battery`) is detected and shown as a suggestion; the user always decides, with a
  soft warning on a mismatch. The choice is shown in the main menu header next to the language.
- Main menu option `8) Change device type`.
- `0` means "Back" on every secondary screen (preview level chooser, undo list, log, language,
  device type, level confirmations and selection lists). Only the main menu uses `0` to exit.
- "Press Enter or 0 to go back to the menu" at the end of every secondary screen.
- README warnings: removing apps cannot be undone, do not use on organization-managed PCs, and the
  restore point / 24-hour limit.
- `tests/MANUAL-TESTING.md`: manual test plan for a virtual machine.
- Notebooks running on battery (`Win32_Battery.BatteryStatus`) skip DISM and HDD defragmentation, with a
  yellow "connect the charger and run the level again" warning; SSD TRIM still runs. Counted as skipped, not
  as an error. Plugged-in notebooks and desktops are not affected (on desktops the battery is not checked).

### Changed
- Power plan depends on the device type: desktops get High performance (or Balanced), notebooks keep
  Balanced. Ultimate Performance is only offered on desktops; on notebooks the step is skipped with a note.
- Levels now ask every question first (confirmation, startup programs, apps, Ultimate Performance) and only
  then create the restore point and the backup. Going back at any question leaves nothing created or changed.
- In the startup and app lists, Enter selects nothing and `0` cancels the list; after cancelling, the user
  confirms whether to continue with the rest of the level or go back to the menu.
- Yes/No questions also accept `0` (= no / back). `N` returns to the menu instead of closing the program.
- The "removed apps cannot be undone" reminder is shown right before confirming the Extreme level.

## [1.0.0] - 2026-11-03

### Added
- Interactive console menu with ASCII banner, colors and step-by-step progress (`[3/21] ... OK`).
- Language selector (Spanish / English). All texts live in `lang/*.psd1`; a new language is a new file.
- Three optimization levels, each including the previous one:
  - **Standard**: temporary files, thumbnail cache, Windows Update download cache, old crash dumps,
    Recycle Bin, DNS cache, High performance power plan, Game DVR, Start/Settings suggestions and ads.
  - **Advanced**: visual effects (keeping font smoothing and thumbnails), user-chosen startup programs,
    background apps (per user), widgets / news and interests, minimum telemetry for the edition,
    DISM component cleanup (without `/ResetBase`), TRIM on SSD / defragmentation on HDD.
  - **Extreme (safe)**: user-chosen removal of allow-listed preinstalled apps, 7 unneeded services set to
    Manual (never Disabled), window animations and transparency, Delivery Optimization P2P off,
    optional Ultimate Performance power plan.
- Preview mode: shows what a level would change without applying anything (`$script:DryRun`).
- System restore point before applying a level, with handling of the 24-hour limit and of disabled
  system protection.
- JSON backup of every modified item in `%LOCALAPPDATA%\CardonOptimizer\backups\<date-time>\`.
- Undo menu: restores registry values, service start types, power plan, startup entries and
  scheduled tasks from any backup.
- Session logs in `%LOCALAPPDATA%\CardonOptimizer\logs\` and a log viewer.
- `Ejecutar.bat` double-click launcher with UAC elevation and per-process `ExecutionPolicy Bypass`.
- Pester 5 test suite and PSScriptAnalyzer-clean code.

[Unreleased]: https://github.com/AlvaroAramayoChain/CardonOptimizer/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/AlvaroAramayoChain/CardonOptimizer/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/AlvaroAramayoChain/CardonOptimizer/releases/tag/v1.0.0
