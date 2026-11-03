# Manual testing (virtual machine)

The Pester tests (`Invoke-Pester -Path .\tests`) never change the system, so the real
changes must be checked by hand. **Run these steps only in a disposable virtual machine**
(Hyper-V, VirtualBox, VMware) with Windows 10 and Windows 11, and take a VM snapshot first.

Notation: `[ ]` = step to check. Note the result and any error shown in red.

## 0. Preparation

- [ ] Windows 10 22H2 VM and Windows 11 (23H2 or 24H2) VM, fully updated, with a snapshot.
- [ ] One VM **without** battery (default) and, if possible, one with an emulated battery
      (e.g. Hyper-V on a laptop host) to test the detection.
- [ ] Copy the repository to `C:\Test\Cardon Optimizer` (a path **with a space**).
- [ ] Install a couple of startup apps (e.g. Spotify, Steam or any updater) to have startup entries.

## 1. Launch and elevation

- [ ] Double-click `Ejecutar.bat` from a standard window: the UAC prompt appears; accept it.
- [ ] Decline UAC once: the bilingual "administrator rights are required" message appears and the window waits.
- [ ] Run `powershell -ExecutionPolicy Bypass -File .\CardonOptimizer.ps1` from a non-elevated console:
      language and device type are asked, then a new elevated window opens **without asking them again**.
- [ ] Accents and "ñ" are displayed correctly in Windows PowerShell 5.1.
- [ ] (Optional) Repeat with PowerShell 7: `pwsh -ExecutionPolicy Bypass -File .\CardonOptimizer.ps1`.

## 2. Language and device type (new in 1.1.0)

- [ ] The language selector shows `1) Español   2) English`.
- [ ] The device screen shows `1) Desktop   2) Notebook / laptop   0) Back (to choose language)`.
- [ ] Without battery: "No battery detected: this looks like a desktop computer". With battery: "Battery detected...".
- [ ] `0` on the device screen goes back to the language selector.
- [ ] Choosing **Notebook** on a VM without battery shows the soft mismatch warning and continues.
- [ ] Choosing **Desktop** on a VM with battery shows the soft mismatch warning and continues.
- [ ] The main menu header shows the language and the device type.
- [ ] Option `8` changes the device type and the header updates; `0` there goes back without changes.
- [ ] Option `7` changes the language; `0` there goes back without changes.

## 3. Back navigation (new in 1.1.0)

For each step, check afterwards that **no new folder** appeared in
`%LOCALAPPDATA%\CardonOptimizer\backups\` and that **no new restore point** was created
(`Get-ComputerRestorePoint` in an elevated Windows PowerShell).

- [ ] Option 4 → `0`: back to the main menu.
- [ ] Option 4 → level 3 → the preview ends with "Press Enter or 0 to go back to the menu" → `0`: back to the menu.
- [ ] Options 1, 2 and 3 → answer `0` to the confirmation: back to the menu.
- [ ] Options 1, 2 and 3 → answer `N` to the confirmation: back to the menu (the program does not close).
- [ ] Option 2 → `Y` → in the startup list type `0` → "List cancelled" → answer `N`: back to the menu.
- [ ] Option 3 → `Y` → startup list Enter → in the app list type `0` → answer `0`: back to the menu.
- [ ] Option 2 → `Y` → startup list `0` → answer `Y`: the level runs, and **no** startup program was disabled.
- [ ] Option 5 → the backup list shows `0) Back` → `0`: back to the menu, nothing restored.
- [ ] Option 6 → shows the log → Enter: back to the menu.
- [ ] The "removed apps cannot be undone" warning is the last text shown before confirming level 3.

## 4. Preview (option 4)

- [ ] Preview of levels 1, 2 and 3 completes without errors and without asking anything.
- [ ] The summary says "This was only a preview: nothing was changed" and shows the estimated space.
- [ ] Desktop: step 21 shows "Power plan: ... -> Ultimate Performance". Notebook: step 21 is "Skipped - not offered on notebooks".

## 5. Level 1 (Standard)

- [ ] A restore point is created (or, if one exists from the last 24 h, the warning appears and you can choose).
- [ ] With system protection disabled (`Disable-ComputerRestore C:\`): it offers to enable it; accept and check it works.
- [ ] Every step prints `[n/21] ... OK` / `Skipped` and none is red.
- [ ] Temp folders, thumbnail cache, Recycle Bin and `SoftwareDistribution\Download` are emptied; `wuauserv` is running again afterwards.
- [ ] **Desktop:** `powercfg /getactivescheme` shows High performance (or Balanced if High performance does not exist).
- [ ] **Notebook:** `powercfg /getactivescheme` shows Balanced. Start from High performance to check it switches to Balanced.
- [ ] The battery warning appears **only** with "Desktop" selected on a VM with battery.
- [ ] Game DVR and Start/Settings suggestions are off (Settings → Gaming / Personalization → Start).
- [ ] Running level 1 a second time: the registry steps show "Skipped (already applied)".

## 6. Level 2 (Advanced)

- [ ] The startup list shows your test apps and hides antivirus/audio/video/touchpad entries.
- [ ] Select one item: after the level, Task Manager → Startup shows it as **Disabled**.
- [ ] Visual effects: animations off, but font smoothing and thumbnails still on (Explorer shows image previews).
- [ ] Widgets / News and interests are gone from the taskbar after signing out.
- [ ] `HKLM\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry` = 1 (Home/Pro) or 0 (Enterprise/Education).
- [ ] DISM finishes with exit code 0 (or 3010); `Optimize-Volume` runs ReTrim on SSD / Defrag on HDD.

## 6b. Notebook running on battery (new in 1.1.0)

Needs a VM with an emulated battery (or a real laptop with a snapshot/restore point).
Check the state with `Get-CimInstance Win32_Battery | Select BatteryStatus` (1 = on battery, 2 = plugged in).

- [ ] **Notebook + unplugged:** the level 2 description warns that DISM and HDD defragmentation will be skipped.
- [ ] **Notebook + unplugged:** step "DISM" shows in yellow `Skipped - Running on battery: connect the charger and run the level again`.
- [ ] **Notebook + unplugged:** "Optimizing drives" runs TRIM on SSD and shows "HDD -> defragmentation skipped (running on battery)" in yellow.
- [ ] **Notebook + unplugged:** the summary counts these as **Skipped**, and Errors stays at 0. The rest of the level runs normally.
- [ ] **Notebook + plugged in:** DISM and defragmentation run normally (check with option 4 first: both show "Would apply").
- [ ] **Desktop selected** (even on a VM with an unplugged battery): DISM and defragmentation run normally and no battery warning appears.
- [ ] Unplug the charger **during** a level: the decision is taken when each step starts (expected; no crash).

## 7. Level 3 (Extreme)

- [ ] The app list shows only installed apps from the allow-list, none preselected.
- [ ] Remove one app (e.g. Solitaire): it disappears; Store, Edge, Calculator, Photos, etc. remain.
- [ ] `Get-Service MapsBroker, XblAuthManager, XblGameSave, XboxNetApiSvc | Select Name, StartType`: Manual (never Disabled).
- [ ] **Desktop:** the Ultimate Performance question appears before the restore point; answer `Y` → the plan is active.
- [ ] **Notebook:** no Ultimate Performance question; step 21 is skipped with the notebook note.
- [ ] Window animations and transparency are off; `DODownloadMode` = 0.

## 8. Undo (option 5)

- [ ] The list shows the backups with date, level and number of items.
- [ ] Restore the level 3 backup: registry values, services (Automatic again), power plan, startup entries
      **and disabled scheduled tasks** return to their original state; the Ultimate Performance copy is deleted.
- [ ] Keys that the script created (e.g. `HKLM\SOFTWARE\Policies\Microsoft\Dsh`) are removed if they are empty.
- [ ] Removed apps are **not** restored (expected); reinstall one from Microsoft Store.
- [ ] The backup shows `[already restored]`; restoring it again causes no errors.

## 9. Log and files

- [ ] Option 6 shows the last 40 lines of the newest log in `%LOCALAPPDATA%\CardonOptimizer\logs\`.
- [ ] The log contains the device type, every step and every Yes/No answer.
- [ ] `backup.json` contains the original values (DWORD, String and Binary) for each changed item.

## 10. Not supported

- [ ] On Windows Server (VM): the "Unsupported system" message appears and nothing is applied.
