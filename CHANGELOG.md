# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/AlvaroAramayoChain/CardonOptimizer/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/AlvaroAramayoChain/CardonOptimizer/releases/tag/v1.0.0
