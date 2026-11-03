@echo off
rem ---------------------------------------------------------------------------
rem  CardonOptimizer launcher (double click).
rem  Runs CardonOptimizer.ps1 with "-ExecutionPolicy Bypass" for THIS process
rem  only (the system policy is not changed) and asks for administrator rights.
rem ---------------------------------------------------------------------------
setlocal
set "CARDON_SCRIPT=%~dp0CardonOptimizer.ps1"

if not exist "%CARDON_SCRIPT%" (
    echo [CardonOptimizer] No se encuentra / Not found: "%CARDON_SCRIPT%"
    pause
    exit /b 1
)

rem "net session" only succeeds when the console already has administrator rights.
net session >nul 2>&1
if %errorlevel% equ 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%CARDON_SCRIPT%"
    exit /b %errorlevel%
)

rem Not elevated: open a new elevated window (UAC prompt).
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File \"' + $env:CARDON_SCRIPT + '\"')"
if %errorlevel% neq 0 (
    echo [CardonOptimizer] Se necesitan permisos de administrador / Administrator rights are required.
    pause
)
endlocal
