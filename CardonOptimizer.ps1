#Requires -Version 5.1
<#
.SYNOPSIS
    CardonOptimizer - a simple and safe optimizer for Windows 10 and 11.

.DESCRIPTION
    Interactive console tool that cleans temporary files and applies a small,
    conservative set of performance tweaks in three levels (Standard, Advanced
    and Extreme-but-safe).

    Safety rules followed by this script:
      * Every change asks for explicit confirmation first.
      * A system restore point is created before applying a level.
      * The previous state of everything that is modified (registry values,
        service start types, power plan, startup entries, scheduled tasks) is
        saved to a JSON backup *before* the change is made, so it can be undone.
      * All change helpers honor the global $script:DryRun flag (preview mode).
      * It never touches Defender, Firewall, SmartScreen, UAC, Windows Update
        settings, the page file, the boot configuration or drivers, and it never
        downloads anything.

.PARAMETER Language
    Optional language code (file name in .\lang without extension). Used when
    the script relaunches itself elevated so the user is not asked twice.

.PARAMETER DeviceType
    Optional device type (Desktop or Notebook), passed on the elevated relaunch.

.NOTES
    Author : Alvaro Aramayo Chain - Desarrollo Cardón (https://desarrollocardon.com)
    License: MIT
    Repo   : https://github.com/AlvaroAramayoChain/CardonOptimizer
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive console UI that needs colored output.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Every change helper honors the global $script:DryRun flag instead of -WhatIf.')]
[CmdletBinding()]
param(
    [string]$Language,
    [ValidateSet('Desktop', 'Notebook')][string]$DeviceType
)

#region Constants and session state
# ---------------------------------------------------------------------------

$script:Version      = '1.1.0'
$script:Website      = 'https://desarrollocardon.com'
$script:Root         = $PSScriptRoot
$script:DataRoot     = Join-Path $env:LOCALAPPDATA 'CardonOptimizer'
$script:BackupRoot   = Join-Path $script:DataRoot 'backups'
$script:LogRoot      = Join-Path $script:DataRoot 'logs'
$script:LogFile      = $null     # Set by Initialize-CardonStorage. $null disables logging (used by tests).
$script:Text         = @{}       # Loaded language strings.
$script:LanguageCode = $null
$script:DryRun       = $false    # When $true, no helper changes anything: it only describes the change.
$script:Backup       = $null     # Current backup session (ordered hashtable).
$script:BackupPath   = $null
$script:Stats        = $null
$script:OsInfo       = $null
# 'Desktop' or 'Notebook', chosen after the language. Not named $DeviceType on purpose:
# at script scope that name is the -DeviceType parameter and assigning it would overwrite it.
$script:SessionDeviceType = $null
$script:Plan         = @{}       # Choices collected before a level is applied (startup items, apps, Ultimate).

$script:Colors = @{
    Title  = 'Cyan'
    Ok     = 'Green'
    Warn   = 'Yellow'
    Error  = 'Red'
    Detail = 'Gray'
    Info   = 'White'
}

# Built-in power scheme GUIDs (identical on every Windows installation).
$script:PowerSchemes = @{
    Balanced        = '381b4222-f694-41f0-9685-ff5bb260df2e'
    HighPerformance = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    UltimateSource  = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
    # Fixed GUID for the copy of "Ultimate Performance" created by this tool,
    # so it can be detected (idempotency) and removed again on undo.
    UltimateCardon  = 'cad0f0e7-5a1b-4c2d-9e3f-0123456789ab'
}

# The only services this tool may switch from Automatic to Manual. Never to Disabled.
$script:ManualServices = @(
    'Fax', 'MapsBroker', 'RetailDemo', 'WMPNetworkSvc',
    'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc'
)

# Explicit allow-list of preinstalled apps that are safe to remove. Nothing is preselected.
$script:BloatwareCatalog = @(
    @{ Package = 'Microsoft.MicrosoftSolitaireCollection'; Name = 'Microsoft Solitaire Collection' }
    @{ Package = 'Clipchamp.Clipchamp';                    Name = 'Clipchamp' }
    @{ Package = 'Microsoft.BingNews';                     Name = 'Microsoft News (Bing)' }
    @{ Package = 'Microsoft.BingWeather';                  Name = 'MSN Weather (Bing)' }
    @{ Package = 'Microsoft.GetHelp';                      Name = 'Get Help' }
    @{ Package = 'Microsoft.Getstarted';                   Name = 'Tips / Get Started' }
    @{ Package = 'Microsoft.WindowsFeedbackHub';           Name = 'Feedback Hub' }
    @{ Package = 'Microsoft.MixedReality.Portal';          Name = 'Mixed Reality Portal' }
    @{ Package = 'Microsoft.XboxApp';                      Name = 'Xbox Console Companion' }
    @{ Package = 'Microsoft.GamingApp';                    Name = 'Xbox (Game Pass)' }
    @{ Package = 'MicrosoftTeams';                         Name = 'Microsoft Teams (personal)' }
    @{ Package = 'Microsoft.SkypeApp';                     Name = 'Skype' }
    @{ Package = 'Microsoft.MicrosoftOfficeHub';           Name = 'Office Hub / Microsoft 365' }
    @{ Package = 'Microsoft.People';                       Name = 'People' }
    @{ Package = 'Microsoft.WindowsMaps';                  Name = 'Maps' }
    @{ Package = 'Microsoft.YourPhone';                    Name = 'Phone Link / Your Phone' }
)

# Packages that must never be removed, even if someone adds them to the catalog by mistake.
$script:ProtectedPackages = @(
    'Microsoft.WindowsStore', 'Microsoft.StorePurchaseApp', 'Microsoft.MicrosoftEdge',
    'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsCamera',
    'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.MSPaint',
    'Microsoft.WindowsTerminal', 'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI',
    'Microsoft.VCLibs', 'Microsoft.NET', 'Microsoft.UI.Xaml', 'Microsoft.WindowsAppRuntime',
    'Microsoft.Services.Store.Engagement', 'Microsoft.XboxIdentityProvider', 'Microsoft.Xbox.TCUI',
    'MSTeams'
)

# Startup entries matching any of these patterns are hidden from the startup list
# and can never be disabled: antivirus, audio, video and touchpad software.
# Over-matching is the safe failure mode (an item is just not offered).
$script:ProtectedStartupPatterns = @(
    # Antivirus and security
    'SecurityHealth', 'Defender', 'MsMpEng', 'Avast', '\bAVG', 'Avira', 'Kaspersky', '\bavp',
    '\bESET\b', '\begui', 'Norton', 'Symantec', 'McAfee', 'Bitdefender', 'Malwarebytes', '\bmbam',
    'Sophos', 'Trend ?Micro', 'Panda', 'Webroot', 'F-Secure', 'Comodo', '360Tray',
    # Audio drivers
    'Realtek', 'RtkAud', 'RAVCpl', 'RAVBg', 'Waves', 'MaxxAudio', 'Dolby', 'Nahimic', 'Conexant',
    'SmartAudio', '\bIDT\b', 'Sonic ?Studio', 'Creative ?Labs', 'CTHelper', 'Sound ?Blaster',
    # Video drivers
    'NVIDIA', '\bNv', '\bAMD', 'Radeon', '\bATI\b', 'igfx', 'Intel',
    # Touchpad and input drivers
    'Synaptics', 'SynTP', '\bELAN', 'ETDCtrl', '\bAlps', 'Apoint', 'Touch ?pad', 'Precision'
)

$script:BannerArt = @'
  ___                _              ___         _    _         _
 / __| __ _  _ _  __| | ___  _ _   / _ \  _ __ | |_ (_) _ __  (_) ___ ___  _ _
| (__ / _` || '_|/ _` |/ _ \| ' \ | (_) || '_ \|  _|| || '  \ | ||_ // -_)| '_|
 \___|\__,_||_|  \__,_|\___/|_||_| \___/ | .__/ \__||_||_|_|_||_|/__|\___||_|
                                         |_|
'@ -split "`r?`n"

#endregion

#region Text, console output and logging
# ---------------------------------------------------------------------------

function Get-CardonText {
    <# Returns a localized string, optionally formatted with -f. Missing keys show as [Key]. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments
    )
    $value = $script:Text[$Key]
    if ($null -eq $value) { return "[$Key]" }
    if ($Arguments) { return ($value -f $Arguments) }
    return $value
}

function Write-CardonLine {
    <# The only place that writes to the console. Text must never be a literal: use Get-CardonText. #>
    param(
        [string]$Text = '',
        [ValidateSet('Title', 'Ok', 'Warn', 'Error', 'Detail', 'Info')][string]$Style = 'Info',
        [switch]$NoNewline
    )
    Write-Host $Text -ForegroundColor $script:Colors[$Style] -NoNewline:$NoNewline
}

function Show-CardonText {
    <# Prints a localized message and writes it to the log. #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments,
        [ValidateSet('Title', 'Ok', 'Warn', 'Error', 'Detail', 'Info')][string]$Style = 'Info'
    )
    $message = Get-CardonText -Key $Key -Arguments $Arguments
    Write-CardonLine -Text $message -Style $Style
    $level = switch ($Style) { 'Ok' { 'OK' } 'Warn' { 'WARN' } 'Error' { 'ERROR' } 'Detail' { 'DETAIL' } default { 'INFO' } }
    Write-CardonLog -Message $message -Level $level
}

function Write-CardonLog {
    <# Appends a line to the session log. Logging problems never stop the program. #>
    param(
        [string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'DETAIL')][string]$Level = 'INFO'
    )
    if (-not $script:LogFile) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        $null = $_   # A log write failure must not interrupt the optimization.
    }
}

function Format-CardonSize {
    param([int64]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Format-CardonValue {
    <# Human readable representation of a registry value (byte arrays as hex). #>
    param($Value)
    if ($null -eq $Value) { return '-' }
    if ($Value -is [array]) { return (($Value | ForEach-Object { '{0:X2}' -f [int]$_ }) -join ' ') }
    return [string]$Value
}

function Wait-CardonEnter {
    $null = Read-Host -Prompt (Get-CardonText -Key 'Prompt_PressEnter')
}

function Wait-CardonBack {
    <# End of a secondary screen: Enter or 0 (or anything else) goes back to the main menu. #>
    $null = Read-Host -Prompt (Get-CardonText -Key 'Prompt_BackToMenu')
}

function Read-CardonYesNo {
    <# Asks a localized yes/no question until a valid answer is given. "0" always means "no / go back". #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments
    )
    $yes = Get-CardonText -Key 'YesKey'
    $no = Get-CardonText -Key 'NoKey'
    $prompt = '{0} ({1}/{2}, 0 = {3})' -f (Get-CardonText -Key $Key -Arguments $Arguments), $yes, $no, (Get-CardonText -Key 'Menu_Back')
    while ($true) {
        $answer = ([string](Read-Host -Prompt $prompt)).Trim()
        if ($answer -ieq $yes) { Write-CardonLog -Message ('{0} -> {1}' -f $prompt, $yes); return $true }
        if ($answer -ieq $no -or $answer -eq '0') { Write-CardonLog -Message ('{0} -> {1}' -f $prompt, $answer); return $false }
        Show-CardonText -Key 'Err_YesNo' -Arguments @($yes, $no) -Style Warn
    }
}

function ConvertTo-CardonSelection {
    <#
        Parses a list like "1,3,5-7" into item numbers between 1 and $Maximum.
        Empty input means "nothing selected". "0" means "cancel / go back" (Cancelled = $true).
        Returns Valid = $false on bad input.
    #>
    param(
        [string]$InputText,
        [Parameter(Mandatory)][int]$Maximum
    )
    $invalid = [pscustomobject]@{ Valid = $false; Cancelled = $false; Items = @() }
    $items = New-Object System.Collections.Generic.List[int]
    $text = ([string]$InputText).Trim()
    if ($text -eq '') { return [pscustomobject]@{ Valid = $true; Cancelled = $false; Items = @() } }
    if ($text -eq '0') { return [pscustomobject]@{ Valid = $true; Cancelled = $true; Items = @() } }
    foreach ($part in ($text -split '[,;\s]+')) {
        if ($part -eq '') { continue }
        if ($part -match '^(\d+)-(\d+)$') {
            $from = [int]$Matches[1]; $to = [int]$Matches[2]
            if ($from -gt $to -or $from -lt 1 -or $to -gt $Maximum) { return $invalid }
            $from..$to | ForEach-Object { $items.Add($_) }
        }
        elseif ($part -match '^\d+$') {
            $number = [int]$part
            if ($number -lt 1 -or $number -gt $Maximum) { return $invalid }
            $items.Add($number)
        }
        else {
            return $invalid
        }
    }
    return [pscustomobject]@{ Valid = $true; Cancelled = $false; Items = @($items | Sort-Object -Unique) }
}

function Read-CardonSelection {
    <# Asks the user to pick items from a numbered list. Returns the parsed selection (Items, Cancelled). #>
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][int]$Maximum
    )
    while ($true) {
        $selection = ConvertTo-CardonSelection -InputText (Read-Host -Prompt (Get-CardonText -Key $Key)) -Maximum $Maximum
        if ($selection.Valid) { return $selection }
        Show-CardonText -Key 'Err_Selection' -Arguments @($Maximum) -Style Warn
    }
}

#endregion

#region Language
# ---------------------------------------------------------------------------

function Get-CardonLanguageList {
    <# Every .psd1 file in .\lang is a language. Adding a language = adding a file. #>
    $folder = Join-Path $script:Root 'lang'
    $languages = foreach ($file in (Get-ChildItem -LiteralPath $folder -Filter '*.psd1' -File)) {
        try {
            $data = Import-PowerShellDataFile -LiteralPath $file.FullName
            [pscustomobject]@{
                Code      = $file.BaseName
                Name      = $data.LanguageName
                SortOrder = [int]$data.SortOrder
                Data      = $data
            }
        }
        catch {
            $null = $_   # A broken language file is simply not offered.
        }
    }
    return @($languages | Sort-Object SortOrder, Code)
}

function Import-CardonLanguage {
    param([Parameter(Mandatory)][string]$Code)
    $language = Get-CardonLanguageList | Where-Object { $_.Code -eq $Code } | Select-Object -First 1
    if (-not $language) { return $false }
    $script:Text = $language.Data
    $script:LanguageCode = $language.Code
    return $true
}

function Select-CardonLanguage {
    <#
        Each option uses texts from its own file, because at startup no language is loaded yet.
        With -AllowBack (from the main menu), "0" returns $false without changing anything.
    #>
    param([switch]$AllowBack)
    $languages = @(Get-CardonLanguageList)
    if ($languages.Count -eq 0) { throw (Join-Path $script:Root 'lang') }
    if ($languages.Count -eq 1) { [void](Import-CardonLanguage -Code $languages[0].Code); return $true }

    $options = for ($i = 0; $i -lt $languages.Count; $i++) { '{0}) {1}' -f ($i + 1), $languages[$i].Name }
    if ($AllowBack) { $options += '0) {0}' -f (Get-CardonText -Key 'Menu_Back') }
    $prompt = ($languages | ForEach-Object { $_.Data.LanguagePrompt }) -join ' / '
    Write-CardonLine
    Write-CardonLine -Text ('  ' + ($options -join '   ')) -Style Info
    while ($true) {
        $choice = ConvertTo-CardonSelection -InputText (Read-Host -Prompt $prompt) -Maximum $languages.Count
        if ($AllowBack -and $choice.Cancelled) { return $false }
        if ($choice.Valid -and $choice.Items.Count -eq 1) {
            [void](Import-CardonLanguage -Code $languages[$choice.Items[0] - 1].Code)
            return $true
        }
    }
}

#endregion

#region Device type
# ---------------------------------------------------------------------------

function Get-CardonDeviceType {
    <# The user's choice; if none was made yet, a guess based on the battery. #>
    if ($script:SessionDeviceType) { return $script:SessionDeviceType }
    if (Test-CardonBattery) { return 'Notebook' }
    return 'Desktop'
}

function Get-CardonDeviceName {
    return (Get-CardonText -Key ('Device_{0}' -f (Get-CardonDeviceType)))
}

function Select-CardonDeviceType {
    <#
        Asks whether this is a desktop or a notebook. The battery detection is only a
        suggestion: the user always decides. "0" returns $false without changing anything.
    #>
    param([string]$BackKey = 'Menu_Back')
    $hasBattery = Test-CardonBattery
    Write-CardonLine
    Show-CardonText -Key 'Device_Title' -Style Title
    $suggestion = if ($hasBattery) { 'Device_DetectedBattery' } else { 'Device_DetectedNoBattery' }
    Show-CardonText -Key $suggestion -Style Detail
    Write-CardonLine -Text ('  1) {0}   2) {1}   0) {2}' -f (Get-CardonText -Key 'Device_Desktop'), (Get-CardonText -Key 'Device_Notebook'), (Get-CardonText -Key $BackKey)) -Style Info

    while ($true) {
        $choice = ([string](Read-Host -Prompt (Get-CardonText -Key 'Prompt_Choice'))).Trim()
        if ($choice -eq '0') { return $false }
        if (@('1', '2') -notcontains $choice) { Show-CardonText -Key 'Err_MenuOption' -Style Warn; continue }

        $type = if ($choice -eq '1') { 'Desktop' } else { 'Notebook' }
        # A mismatch with the detection is only a soft warning.
        if ($type -eq 'Desktop' -and $hasBattery) { Show-CardonText -Key 'Device_MismatchDesktop' -Style Warn }
        if ($type -eq 'Notebook' -and -not $hasBattery) { Show-CardonText -Key 'Device_MismatchNotebook' -Style Warn }
        $script:SessionDeviceType = $type
        Show-CardonText -Key 'Device_Selected' -Arguments @((Get-CardonDeviceName)) -Style Ok
        return $true
    }
}

#endregion

#region Environment checks
# ---------------------------------------------------------------------------

function Test-CardonAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-CardonElevation {
    <# Relaunches this script elevated (UAC prompt). Returns $false if the user declined. #>
    param([string]$LanguageCode, [string]$DeviceType)
    $hostPath = (Get-Process -Id $PID).Path
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Language {1} -DeviceType {2}' -f $PSCommandPath, $LanguageCode, $DeviceType
    try {
        Start-Process -FilePath $hostPath -ArgumentList $arguments -Verb RunAs -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-CardonOsInfo {
    <# Cached information about the running Windows version. #>
    if ($script:OsInfo) { return $script:OsInfo }
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $build = [int]$os.BuildNumber
    $edition = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
    $script:OsInfo = [pscustomobject]@{
        Caption     = $os.Caption
        Build       = $build
        Edition     = $edition
        IsWindows11 = ($build -ge 22000)
        # Windows 10 and 11 report version 10.0. ProductType 1 = workstation (not Server).
        IsSupported = ($os.Version -like '10.0*' -and $os.ProductType -eq 1 -and $build -ge 10240)
    }
    return $script:OsInfo
}

function Test-CardonBattery {
    <# $true only when Windows actually reports a battery (laptops, tablets). #>
    try {
        return (@(Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop).Count -gt 0)
    }
    catch {
        return $false
    }
}

function Get-CardonMinimumTelemetryLevel {
    <# 0 (Security) is only honored by Enterprise/Education editions; others accept 1 (Required). #>
    $edition = (Get-CardonOsInfo).Edition
    if ($edition -match 'Enterprise|Education|IoT') { return 0 }
    return 1
}

function Invoke-CardonNative {
    <# Runs a console program and returns its exit code and output. #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList
    )
    $output = & $FilePath @ArgumentList 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($output | Out-String) }
}

#endregion

#region Storage, backup and restore point
# ---------------------------------------------------------------------------

function Initialize-CardonStorage {
    foreach ($folder in @($script:DataRoot, $script:BackupRoot, $script:LogRoot)) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder -Force | Out-Null }
    }
    $script:LogFile = Join-Path $script:LogRoot ('CardonOptimizer_{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function New-CardonBackupSession {
    <# Starts a new backup folder. Must be called before any change is applied. #>
    param([int]$Level)
    $script:BackupPath = Join-Path $script:BackupRoot (Get-Date -Format 'yyyyMMdd-HHmmss')
    New-Item -ItemType Directory -Path $script:BackupPath -Force -ErrorAction Stop | Out-Null
    $script:Backup = [ordered]@{
        Tool     = 'CardonOptimizer'
        Version  = $script:Version
        Created  = (Get-Date).ToString('s')
        Level    = $Level
        Computer = $env:COMPUTERNAME
        User     = $env:USERNAME
        Entries  = New-Object System.Collections.ArrayList
    }
    Save-CardonBackup
}

function Save-CardonBackup {
    <# Writes the backup to disk. Throws on failure so the pending change is not applied. #>
    $file = Join-Path $script:BackupPath 'backup.json'
    $script:Backup | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $file -Encoding UTF8 -ErrorAction Stop
}

function Add-CardonBackupEntry {
    <#
        Records the original state of something that is about to change.
        Only the first state of each target is kept, so re-running a level never
        overwrites the true original value.
    #>
    param([Parameter(Mandatory)][hashtable]$Entry)
    if ($null -eq $script:Backup) { throw (Get-CardonText -Key 'Err_NoBackupSession') }
    $existing = @($script:Backup.Entries | Where-Object { $_.Key -eq $Entry.Key })
    if ($existing.Count -gt 0) { return }
    $Entry.Timestamp = (Get-Date).ToString('s')
    [void]$script:Backup.Entries.Add([pscustomobject]$Entry)
    Save-CardonBackup
}

function Get-CardonLatestRestorePointDate {
    try {
        $points = @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop)
        if ($points.Count -eq 0) { return $null }
        $last = $points | Sort-Object -Property SequenceNumber | Select-Object -Last 1
        return [Management.ManagementDateTimeConverter]::ToDateTime($last.CreationTime)
    }
    catch {
        return $null
    }
}

function Invoke-CardonCheckpoint {
    <# Checkpoint-Computer exists only in Windows PowerShell 5.1; PowerShell 7 uses the WMI class. #>
    if (Get-Command -Name Checkpoint-Computer -ErrorAction SilentlyContinue) {
        Checkpoint-Computer -Description 'CardonOptimizer' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop -WarningAction SilentlyContinue
        return
    }
    $result = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
        Description = 'CardonOptimizer'; RestorePointType = [uint32]12; EventType = [uint32]100
    } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) { throw ('SystemRestore.CreateRestorePoint = {0}' -f $result.ReturnValue) }
}

function Enable-CardonSystemProtection {
    $drive = '{0}\' -f $env:SystemDrive
    if (Get-Command -Name Enable-ComputerRestore -ErrorAction SilentlyContinue) {
        Enable-ComputerRestore -Drive $drive -ErrorAction Stop
        return
    }
    $result = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName Enable -Arguments @{ Drive = $drive } -ErrorAction Stop
    if ($result.ReturnValue -ne 0) { throw ('SystemRestore.Enable = {0}' -f $result.ReturnValue) }
}

function New-CardonRestorePoint {
    <#
        Creates a restore point. Returns $true when it is OK to continue.
        Windows allows one restore point every 24 hours by default; that case is a
        warning, not an error: the user decides whether the recent point is enough.
    #>
    Show-CardonText -Key 'RP_Creating' -Style Info
    $lastPoint = Get-CardonLatestRestorePointDate
    if ($lastPoint -and $lastPoint -gt (Get-Date).AddHours(-24)) {
        Show-CardonText -Key 'RP_Recent' -Arguments @($lastPoint.ToString('g')) -Style Warn
        return (Read-CardonYesNo -Key 'Ask_ContinueRecentRP')
    }

    $started = Get-Date
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            Invoke-CardonCheckpoint
            $created = Get-CardonLatestRestorePointDate
            if ($created -and $created -ge $started.AddMinutes(-1)) {
                Show-CardonText -Key 'RP_Created' -Style Ok
                return $true
            }
            break
        }
        catch {
            Show-CardonText -Key 'RP_Failed' -Arguments @($_.Exception.Message) -Style Warn
            if ($attempt -eq 1 -and (Read-CardonYesNo -Key 'Ask_EnableProtection')) {
                try {
                    Enable-CardonSystemProtection
                    Show-CardonText -Key 'RP_ProtectionEnabled' -Style Ok
                    continue
                }
                catch {
                    Show-CardonText -Key 'Err_Generic' -Arguments @($_.Exception.Message) -Style Error
                }
            }
            break
        }
    }
    Show-CardonText -Key 'RP_NotCreated' -Style Warn
    return (Read-CardonYesNo -Key 'Ask_ContinueWithoutRP')
}

#endregion

#region Change helpers (all of them honor $script:DryRun and back up first)
# ---------------------------------------------------------------------------

function New-CardonResult {
    param(
        [ValidateSet('Changed', 'Unchanged', 'Skipped', 'Preview', 'Error')][string]$Status = 'Changed',
        [int64]$Bytes = 0,
        [string]$Detail
    )
    return [pscustomobject]@{ Status = $Status; Bytes = $Bytes; Detail = $Detail }
}

function Get-CardonCombinedStatus {
    <# Reduces the statuses of several sub-steps to a single step status. #>
    param([string[]]$Statuses)
    if ($Statuses -contains 'Changed') { return 'Changed' }
    if ($Statuses -contains 'Preview') { return 'Preview' }
    if ($Statuses -contains 'Skipped') { return 'Skipped' }
    return 'Unchanged'
}

function Test-CardonValueEqual {
    param($Current, $Desired)
    if ($Current -is [array] -or $Desired -is [array]) {
        return ((@($Current) -join ',') -eq (@($Desired) -join ','))
    }
    return ([string]$Current -eq [string]$Desired)
}

function Get-CardonRegistryValue {
    <# Reads a registry value without failing when the key or value does not exist. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $result = @{ KeyExists = $false; Exists = $false; Value = $null; Type = $null }
    if (Test-Path -LiteralPath $Path) {
        $result.KeyExists = $true
        $key = Get-Item -LiteralPath $Path
        if ($key.GetValueNames() -contains $Name) {
            $result.Exists = $true
            $result.Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
            $result.Type = $key.GetValueKind($Name).ToString()
        }
    }
    return $result
}

function Get-CardonMissingKeyRoot {
    <# Returns the top-most registry key in $Path that does not exist yet (or $null). #>
    param([string]$Path)
    $missing = $null
    $current = $Path
    while ($current -and -not (Test-Path -LiteralPath $current)) {
        $missing = $current
        $current = Split-Path -Path $current -Parent
    }
    return $missing
}

function Set-CardonRegistryValue {
    <# Sets a registry value after backing up its previous state. Idempotent. #>
    param(
        [Parameter(Mandatory)][string]$ActionId,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [ValidateSet('DWord', 'QWord', 'String', 'ExpandString', 'Binary', 'MultiString')][string]$Type = 'DWord'
    )
    $current = Get-CardonRegistryValue -Path $Path -Name $Name
    if ($current.Exists -and (Test-CardonValueEqual -Current $current.Value -Desired $Value)) { return 'Unchanged' }

    if ($script:DryRun) {
        $old = if ($current.Exists) { Format-CardonValue -Value $current.Value } else { Get-CardonText -Key 'Preview_NotSet' }
        Show-CardonText -Key 'Preview_Registry' -Arguments @($Path, $Name, $old, (Format-CardonValue -Value $Value)) -Style Detail
        return 'Preview'
    }

    Add-CardonBackupEntry -Entry @{
        Kind       = 'Registry'
        Key        = 'REG|{0}|{1}' -f $Path, $Name
        ActionId   = $ActionId
        Path       = $Path
        Name       = $Name
        Existed    = $current.Exists
        Value      = $current.Value
        Type       = $current.Type
        CreatedKey = (Get-CardonMissingKeyRoot -Path $Path)
    }
    if (-not $current.KeyExists) { New-Item -Path $Path -Force -ErrorAction Stop | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force -ErrorAction Stop | Out-Null
    return 'Changed'
}

function Get-CardonServiceState {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $service) { return $null }
    $delayed = Get-CardonRegistryValue -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\{0}' -f $Name) -Name 'DelayedAutostart'
    return [pscustomobject]@{
        Name      = $Name
        StartType = [string]$service.StartType
        Status    = [string]$service.Status
        Delayed   = ($delayed.Exists -and $delayed.Value -eq 1)
    }
}

function Set-CardonServiceManual {
    <# Switches an allowed service from Automatic to Manual. Never disables, never stops. #>
    param([Parameter(Mandatory)][string]$ActionId, [Parameter(Mandatory)][string]$Name)
    if ($script:ManualServices -notcontains $Name) { throw (Get-CardonText -Key 'Err_ServiceNotAllowed' -Arguments @($Name)) }

    $state = Get-CardonServiceState -Name $Name
    if (-not $state) {
        Show-CardonText -Key 'Detail_ServiceMissing' -Arguments @($Name) -Style Detail
        return 'Unchanged'
    }
    # Manual or Disabled services are left exactly as they are.
    if ($state.StartType -ne 'Automatic') { return 'Unchanged' }

    if ($script:DryRun) {
        Show-CardonText -Key 'Preview_Service' -Arguments @($Name, (Get-CardonText -Key ('StartType_{0}' -f $state.StartType))) -Style Detail
        return 'Preview'
    }
    Add-CardonBackupEntry -Entry @{
        Kind      = 'Service'
        Key       = 'SVC|{0}' -f $Name
        ActionId  = $ActionId
        Name      = $Name
        StartType = $state.StartType
        Delayed   = $state.Delayed
    }
    Set-Service -Name $Name -StartupType Manual -ErrorAction Stop
    return 'Changed'
}

function Get-CardonPowerSchemeList {
    <# Raw "powercfg /list" output (read-only). #>
    return (Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('/list')).Output
}

function Get-CardonActivePowerScheme {
    $output = (Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('/getactivescheme')).Output
    if ($output -match '([0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})') { return $Matches[1].ToLowerInvariant() }
    return $null
}

function Test-CardonPowerScheme {
    param([Parameter(Mandatory)][string]$Guid)
    return ((Get-CardonPowerSchemeList) -match [regex]::Escape($Guid))
}

function Get-CardonPowerSchemeName {
    <# Localized plan name as shown by powercfg, or the GUID if not found. #>
    param([string]$Guid)
    if (-not $Guid) { return '-' }
    if ((Get-CardonPowerSchemeList) -match ('{0}\s+\(([^)]+)\)' -f [regex]::Escape($Guid))) { return $Matches[1] }
    return $Guid
}

function Set-CardonPowerScheme {
    <# Activates a power plan after backing up the currently active one. #>
    param([Parameter(Mandatory)][string]$ActionId, [Parameter(Mandatory)][string]$Guid)
    $active = Get-CardonActivePowerScheme
    if ($active -eq $Guid) { return 'Unchanged' }

    if ($script:DryRun) {
        Show-CardonText -Key 'Preview_PowerScheme' -Arguments @((Get-CardonPowerSchemeName -Guid $active), (Get-CardonPowerSchemeName -Guid $Guid)) -Style Detail
        return 'Preview'
    }
    Add-CardonBackupEntry -Entry @{ Kind = 'PowerScheme'; Key = 'POWER'; ActionId = $ActionId; Guid = $active }
    $result = Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $Guid)
    if ($result.ExitCode -ne 0) { throw $result.Output }
    return 'Changed'
}

function New-CardonUltimatePowerScheme {
    <# Creates this tool's copy of "Ultimate Performance" if it does not exist. Returns its GUID. #>
    param([Parameter(Mandatory)][string]$ActionId)
    $guid = $script:PowerSchemes.UltimateCardon
    if (Test-CardonPowerScheme -Guid $guid) { return $guid }
    if ($script:DryRun) { return $guid }

    $result = Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('-duplicatescheme', $script:PowerSchemes.UltimateSource, $guid)
    if ($result.ExitCode -ne 0 -or -not (Test-CardonPowerScheme -Guid $guid)) { throw $result.Output }
    Add-CardonBackupEntry -Entry @{ Kind = 'PowerSchemeCreated'; Key = 'POWERNEW|{0}' -f $guid; ActionId = $ActionId; Guid = $guid }
    return $guid
}

function Disable-CardonScheduledTask {
    <# Disables a (non-Microsoft) logon task after backing up its state. #>
    param([Parameter(Mandatory)][string]$ActionId, [Parameter(Mandatory)][string]$TaskPath, [Parameter(Mandatory)][string]$TaskName)
    if ($TaskPath -like '\Microsoft\*') { throw (Get-CardonText -Key 'Err_ProtectedItem' -Arguments @($TaskName)) }
    $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop
    if ([string]$task.State -eq 'Disabled') { return 'Unchanged' }

    if ($script:DryRun) {
        Show-CardonText -Key 'Preview_Task' -Arguments @($TaskPath + $TaskName) -Style Detail
        return 'Preview'
    }
    Add-CardonBackupEntry -Entry @{
        Kind     = 'ScheduledTask'
        Key      = 'TASK|{0}{1}' -f $TaskPath, $TaskName
        ActionId = $ActionId
        TaskPath = $TaskPath
        TaskName = $TaskName
    }
    Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
    return 'Changed'
}

function Test-CardonProtectedPackage {
    param([Parameter(Mandatory)][string]$Package)
    foreach ($protected in $script:ProtectedPackages) {
        if ($Package -like ('{0}*' -f $protected)) { return $true }
    }
    return $false
}

function Remove-CardonAppPackage {
    <# Removes an allow-listed app for the current user. Not reversible (reinstall from the Store). #>
    param([Parameter(Mandatory)]$Package)
    if (Test-CardonProtectedPackage -Package $Package.Name) { throw (Get-CardonText -Key 'Err_ProtectedItem' -Arguments @($Package.Name)) }
    if (@($script:BloatwareCatalog | Where-Object { $_.Package -eq $Package.Name }).Count -eq 0) {
        throw (Get-CardonText -Key 'Err_ProtectedItem' -Arguments @($Package.Name))
    }
    if ($script:DryRun) { return 'Preview' }
    Remove-AppxPackage -Package $Package.PackageFullName -ErrorAction Stop
    return 'Changed'
}

function Clear-CardonDirectory {
    <#
        Deletes files inside $Path that match $Filter and are older than
        $OlderThanHours. Files in use are skipped silently. Junctions and symbolic
        links are never followed. In DryRun it only measures what would be freed.
    #>
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Filter = '*',
        [int]$OlderThanHours = 0,
        [switch]$RemoveEmptyFolders
    )
    $result = @{ Bytes = [int64]0; Files = 0 }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return $result }
    $cutoff = (Get-Date).AddHours(-$OlderThanHours)
    $root = New-Object System.IO.DirectoryInfo($Path)
    Remove-CardonDirectoryContent -Directory $root -Filter $Filter -Cutoff $cutoff -Result $result -RemoveEmptyFolders:$RemoveEmptyFolders
    return $result
}

function Remove-CardonDirectoryContent {
    <# Recursive worker of Clear-CardonDirectory. Never deletes $Directory itself. #>
    param(
        [System.IO.DirectoryInfo]$Directory,
        [string]$Filter,
        [datetime]$Cutoff,
        [hashtable]$Result,
        [switch]$RemoveEmptyFolders
    )
    try { $children = $Directory.GetFileSystemInfos() } catch { return }
    foreach ($child in $children) {
        # Never follow junctions or symbolic links: they may point outside the folder being cleaned.
        if ($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { continue }

        if ($child -is [System.IO.DirectoryInfo]) {
            Remove-CardonDirectoryContent -Directory $child -Filter $Filter -Cutoff $Cutoff -Result $Result -RemoveEmptyFolders:$RemoveEmptyFolders
            if ($RemoveEmptyFolders -and -not $script:DryRun) {
                # DirectoryInfo.Delete() without $true only succeeds when the folder is empty.
                try { $child.Delete() } catch { $null = $_ }
            }
            continue
        }
        if ($child.Name -notlike $Filter -or $child.LastWriteTime -gt $Cutoff) { continue }

        $length = $child.Length
        if ($script:DryRun) {
            $Result.Bytes += $length; $Result.Files++
            continue
        }
        try {
            $child.Delete()
            $Result.Bytes += $length; $Result.Files++
        }
        catch {
            $null = $_   # File in use or access denied: skip it without an error.
        }
    }
}

#endregion

#region Restore (undo)
# ---------------------------------------------------------------------------

function Restore-CardonRegistryEntry {
    <# Puts back the original value. If the value did not exist, removes it (and keys this tool created). #>
    param([Parameter(Mandatory)]$Entry)
    if ($Entry.Existed) {
        if (-not (Test-Path -LiteralPath $Entry.Path)) { New-Item -Path $Entry.Path -Force -ErrorAction Stop | Out-Null }
        $value = $Entry.Value
        if ($Entry.Type -eq 'Binary') { $value = [byte[]]@($Entry.Value) }
        if ($Entry.Type -eq 'MultiString') { $value = [string[]]@($Entry.Value) }
        New-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -Value $value -PropertyType $Entry.Type -Force -ErrorAction Stop | Out-Null
        return
    }

    $current = Get-CardonRegistryValue -Path $Entry.Path -Name $Entry.Name
    if ($current.Exists) { Remove-ItemProperty -LiteralPath $Entry.Path -Name $Entry.Name -ErrorAction Stop }

    # Remove only empty keys that this tool itself created, walking up to the first one it created.
    if ($Entry.CreatedKey) {
        $key = $Entry.Path
        while ($key -and $key.Length -ge $Entry.CreatedKey.Length) {
            $item = Get-Item -LiteralPath $key -ErrorAction SilentlyContinue
            if ($item -and $item.ValueCount -eq 0 -and $item.SubKeyCount -eq 0) {
                Remove-Item -LiteralPath $key -ErrorAction Stop
            }
            else {
                break
            }
            $key = Split-Path -Path $key -Parent
        }
    }
}

function Restore-CardonServiceEntry {
    param([Parameter(Mandatory)]$Entry)
    if (-not (Get-Service -Name $Entry.Name -ErrorAction SilentlyContinue)) { return }
    if ($Entry.Delayed) {
        $result = Invoke-CardonNative -FilePath 'sc.exe' -ArgumentList @('config', $Entry.Name, 'start=', 'delayed-auto')
        if ($result.ExitCode -ne 0) { throw $result.Output }
        return
    }
    Set-Service -Name $Entry.Name -StartupType $Entry.StartType -ErrorAction Stop
}

function Restore-CardonPowerSchemeEntry {
    param([Parameter(Mandatory)]$Entry)
    if (-not $Entry.Guid) { return }
    $result = Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $Entry.Guid)
    if ($result.ExitCode -ne 0) { throw $result.Output }
}

function Remove-CardonCreatedPowerScheme {
    <# Deletes the power plan this tool created. Windows cannot delete the active plan. #>
    param([Parameter(Mandatory)]$Entry)
    if (-not (Test-CardonPowerScheme -Guid $Entry.Guid)) { return }
    if ((Get-CardonActivePowerScheme) -eq $Entry.Guid) {
        [void](Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $script:PowerSchemes.Balanced))
    }
    $result = Invoke-CardonNative -FilePath 'powercfg.exe' -ArgumentList @('/delete', $Entry.Guid)
    if ($result.ExitCode -ne 0) { throw $result.Output }
}

function Restore-CardonScheduledTaskEntry {
    param([Parameter(Mandatory)]$Entry)
    Enable-ScheduledTask -TaskPath $Entry.TaskPath -TaskName $Entry.TaskName -ErrorAction Stop | Out-Null
}

function Restore-CardonEntry {
    <# Dispatches one backup entry to the matching restore function. #>
    param([Parameter(Mandatory)]$Entry)
    switch ($Entry.Kind) {
        'Registry'           { Restore-CardonRegistryEntry -Entry $Entry }
        'Service'            { Restore-CardonServiceEntry -Entry $Entry }
        'PowerScheme'        { Restore-CardonPowerSchemeEntry -Entry $Entry }
        'PowerSchemeCreated' { Remove-CardonCreatedPowerScheme -Entry $Entry }
        'ScheduledTask'      { Restore-CardonScheduledTaskEntry -Entry $Entry }
        default              { throw (Get-CardonText -Key 'Err_UnknownEntry' -Arguments @($Entry.Kind)) }
    }
}

function Get-CardonBackupList {
    <# Lists backups with at least one entry, newest first. #>
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) { return @() }
    $backups = foreach ($folder in (Get-ChildItem -LiteralPath $script:BackupRoot -Directory | Sort-Object Name -Descending)) {
        $file = Join-Path $folder.FullName 'backup.json'
        if (-not (Test-Path -LiteralPath $file)) { continue }
        try {
            $data = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
            $count = @($data.Entries).Count
            if ($count -eq 0) { continue }
            [pscustomobject]@{
                Path     = $folder.FullName
                File     = $file
                Data     = $data
                Created  = [string]$data.Created
                Level    = [int]$data.Level
                Count    = $count
                Restored = [bool]($data.PSObject.Properties['RestoredAt'])
            }
        }
        catch {
            Show-CardonText -Key 'Err_BackupUnreadable' -Arguments @($file) -Style Warn
        }
    }
    return @($backups)
}

function Restore-CardonBackup {
    <# Restores every entry of a backup in reverse order, using each action's Revert function. #>
    param([Parameter(Mandatory)]$BackupItem)
    $entries = @($BackupItem.Data.Entries)
    [array]::Reverse($entries)
    # A created power plan can only be deleted after the original plan is active again.
    $ordered = @($entries | Where-Object { $_.Kind -ne 'PowerSchemeCreated' }) + @($entries | Where-Object { $_.Kind -eq 'PowerSchemeCreated' })
    $catalog = Get-CardonActionCatalog
    $ok = 0; $failed = 0

    foreach ($entry in $ordered) {
        $label = if ($entry.Kind -eq 'Registry') { '{0}\{1}' -f $entry.Path, $entry.Name }
                 elseif ($entry.Kind -eq 'ScheduledTask') { $entry.TaskPath + $entry.TaskName }
                 elseif ($entry.Name) { $entry.Name } else { $entry.Guid }
        try {
            $action = $catalog | Where-Object { $_.Id -eq $entry.ActionId } | Select-Object -First 1
            if ($action -and $action.Revert) { & $action.Revert @($entry) } else { Restore-CardonEntry -Entry $entry }
            Show-CardonText -Key 'Restore_EntryOk' -Arguments @($label) -Style Ok
            $ok++
        }
        catch {
            Show-CardonText -Key 'Restore_EntryFailed' -Arguments @($label, $_.Exception.Message) -Style Error
            $failed++
        }
    }

    try {
        $BackupItem.Data | Add-Member -NotePropertyName 'RestoredAt' -NotePropertyValue (Get-Date).ToString('s') -Force
        $BackupItem.Data | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $BackupItem.File -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        Show-CardonText -Key 'Err_Generic' -Arguments @($_.Exception.Message) -Style Warn
    }
    return [pscustomobject]@{ Ok = $ok; Failed = $failed }
}

#endregion

#region Actions: level 1 (Standard)
# ---------------------------------------------------------------------------

function Invoke-CardonRegistryAction {
    <# Generic Apply for actions that only set the values declared in $Action.Registry. #>
    param([Parameter(Mandatory)]$Action)
    $build = (Get-CardonOsInfo).Build
    $statuses = foreach ($entry in $Action.Registry) {
        if ($entry.MinBuild -and $build -lt $entry.MinBuild) { continue }
        if ($entry.MaxBuild -and $build -gt $entry.MaxBuild) { continue }
        $value = if ($entry.Value -is [scriptblock]) { & $entry.Value } else { $entry.Value }
        $type = if ($entry.Type) { $entry.Type } else { 'DWord' }
        Set-CardonRegistryValue -ActionId $Action.Id -Path $entry.Path -Name $entry.Name -Value $value -Type $type
    }
    return (New-CardonResult -Status (Get-CardonCombinedStatus -Statuses @($statuses)))
}

function Invoke-CardonCleanup {
    <# Shared Apply for folder cleanups: $Targets = @(@{ Path; Filter; Hours; RemoveEmptyFolders }). #>
    param([Parameter(Mandatory)][object[]]$Targets)
    $bytes = [int64]0
    $files = 0
    $seen = @{}
    foreach ($target in $Targets) {
        if (-not $target.Path -or $seen.ContainsKey($target.Path)) { continue }
        $seen[$target.Path] = $true
        $filter = if ($target.Filter) { $target.Filter } else { '*' }
        $result = Clear-CardonDirectory -Path $target.Path -Filter $filter -OlderThanHours ([int]$target.Hours) -RemoveEmptyFolders:([bool]$target.RemoveEmptyFolders)
        $bytes += $result.Bytes
        $files += $result.Files
    }
    $status = if ($script:DryRun) { 'Preview' } elseif ($files -gt 0) { 'Changed' } else { 'Unchanged' }
    return (New-CardonResult -Status $status -Bytes $bytes -Detail (Get-CardonText -Key 'Detail_Files' -Arguments @($files)))
}

function Invoke-CardonTempCleanup {
    # Files touched in the last 24 hours are kept: an installer may still need them.
    return (Invoke-CardonCleanup -Targets @(
        @{ Path = $env:TEMP; Hours = 24; RemoveEmptyFolders = $true }
        @{ Path = (Join-Path $env:SystemRoot 'Temp'); Hours = 24; RemoveEmptyFolders = $true }
    ))
}

function Invoke-CardonThumbnailCleanup {
    # Explorer keeps some of these files open; those are skipped and rebuilt automatically.
    return (Invoke-CardonCleanup -Targets @(
        @{ Path = (Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'); Filter = 'thumbcache_*.db' }
    ))
}

function Invoke-CardonUpdateCacheCleanup {
    <# Clears already-downloaded update files. wuauserv is stopped only during the cleanup. #>
    $download = Join-Path $env:SystemRoot 'SoftwareDistribution\Download'
    $installer = Get-Service -Name 'TrustedInstaller' -ErrorAction SilentlyContinue
    if ($installer -and [string]$installer.Status -eq 'Running') {
        return (New-CardonResult -Status Skipped -Detail (Get-CardonText -Key 'Detail_UpdateInProgress'))
    }
    if ($script:DryRun) { return (Invoke-CardonCleanup -Targets @(@{ Path = $download; RemoveEmptyFolders = $true })) }

    $service = Get-Service -Name 'wuauserv' -ErrorAction Stop
    $wasRunning = ([string]$service.Status -eq 'Running')
    try {
        if ($wasRunning) { Stop-Service -Name 'wuauserv' -Force -ErrorAction Stop }
        return (Invoke-CardonCleanup -Targets @(@{ Path = $download; RemoveEmptyFolders = $true }))
    }
    finally {
        # Always leave the service as it was, even if the cleanup failed.
        if ($wasRunning) { Start-Service -Name 'wuauserv' -ErrorAction SilentlyContinue }
    }
}

function Invoke-CardonCrashDumpCleanup {
    $result = Invoke-CardonCleanup -Targets @(
        @{ Path = (Join-Path $env:SystemRoot 'Minidump'); Hours = 168 }
        @{ Path = (Join-Path $env:SystemRoot 'LiveKernelReports'); Filter = '*.dmp'; Hours = 168 }
        @{ Path = (Join-Path $env:LOCALAPPDATA 'CrashDumps'); Hours = 168 }
    )
    # The full memory dump lives directly in the Windows folder; only that single file is considered.
    $memoryDump = New-Object System.IO.FileInfo((Join-Path $env:SystemRoot 'MEMORY.DMP'))
    if ($memoryDump.Exists -and $memoryDump.LastWriteTime -lt (Get-Date).AddDays(-7)) {
        $length = $memoryDump.Length
        if ($script:DryRun) {
            $result.Bytes += $length
        }
        else {
            try { $memoryDump.Delete(); $result.Bytes += $length; $result.Status = 'Changed' } catch { $null = $_ }
        }
    }
    return $result
}

function Invoke-CardonRecycleBinCleanup {
    $count = 0
    $bytes = [int64]0
    try {
        $shell = New-Object -ComObject Shell.Application
        $items = $shell.NameSpace(10).Items()   # 10 = Recycle Bin
        $count = $items.Count
        foreach ($item in $items) { $bytes += [int64]$item.ExtendedProperty('Size') }
    }
    catch {
        $null = $_   # Size is only informative.
    }
    if ($count -eq 0) { return (New-CardonResult -Status Unchanged) }
    if ($script:DryRun) { return (New-CardonResult -Status Preview -Bytes $bytes) }
    Clear-RecycleBin -Force -ErrorAction Stop
    return (New-CardonResult -Status Changed -Bytes $bytes)
}

function Invoke-CardonDnsFlush {
    if ($script:DryRun) { return (New-CardonResult -Status Preview) }
    $result = Invoke-CardonNative -FilePath 'ipconfig.exe' -ArgumentList @('/flushdns')
    if ($result.ExitCode -ne 0) { throw $result.Output }
    return (New-CardonResult -Status Changed)
}

function Get-CardonPowerPlanTarget {
    <# Desktop: High performance if it exists, otherwise Balanced. Notebook: always Balanced. #>
    if ((Get-CardonDeviceType) -eq 'Notebook') { return $script:PowerSchemes.Balanced }
    if (Test-CardonPowerScheme -Guid $script:PowerSchemes.HighPerformance) { return $script:PowerSchemes.HighPerformance }
    return $script:PowerSchemes.Balanced
}

function Invoke-CardonPowerPlan {
    <# Level 1 power plan, depending on the device type. On desktops an active Ultimate plan is kept. #>
    param([Parameter(Mandatory)]$Action)
    $active = Get-CardonActivePowerScheme
    $isNotebook = ((Get-CardonDeviceType) -eq 'Notebook')
    if (-not $isNotebook -and $active -in @($script:PowerSchemes.HighPerformance, $script:PowerSchemes.UltimateCardon, $script:PowerSchemes.UltimateSource)) {
        return (New-CardonResult -Status Unchanged)
    }
    $target = Get-CardonPowerPlanTarget
    if ($isNotebook) { Show-CardonText -Key 'Detail_NotebookBalanced' -Style Detail }
    # The battery warning only makes sense when High performance is about to be activated.
    if ($target -eq $script:PowerSchemes.HighPerformance -and (Test-CardonBattery)) {
        Show-CardonText -Key 'Warn_BatteryHighPerformance' -Style Warn
    }
    return (New-CardonResult -Status (Set-CardonPowerScheme -ActionId $Action.Id -Guid $target))
}

#endregion

#region Actions: level 2 (Advanced)
# ---------------------------------------------------------------------------

function Test-CardonProtectedStartupItem {
    <# $true for antivirus, audio, video and touchpad entries, which are never offered. #>
    param([string]$Name, [string]$Command)
    $text = '{0} {1}' -f $Name, $Command
    foreach ($pattern in $script:ProtectedStartupPatterns) {
        if ($text -match $pattern) { return $true }
    }
    return $false
}

function Test-CardonStartupDisabled {
    <# StartupApproved stores 12 bytes; an odd first byte means "disabled" (same as Task Manager). #>
    param([string]$ApprovedPath, [string]$Name)
    $value = Get-CardonRegistryValue -Path $ApprovedPath -Name $Name
    if (-not $value.Exists -or $value.Value -isnot [array] -or $value.Value.Count -eq 0) { return $false }
    return (([int]$value.Value[0] -band 1) -eq 1)
}

function Get-CardonStartupItem {
    <# Enabled startup entries from the Run keys, the startup folders and logon scheduled tasks. #>
    $approvedRoot = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'
    $items = New-Object System.Collections.ArrayList

    $runKeys = @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKCU:\$approvedRoot\Run";   Source = 'Source_RegistryUser' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run';             Approved = "HKLM:\$approvedRoot\Run";   Source = 'Source_RegistryMachine' }
        @{ Path = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM:\$approvedRoot\Run32"; Source = 'Source_RegistryMachine' }
    )
    foreach ($run in $runKeys) {
        if (-not (Test-Path -LiteralPath $run.Path)) { continue }
        $key = Get-Item -LiteralPath $run.Path
        foreach ($name in $key.GetValueNames()) {
            if (-not $name -or (Test-CardonStartupDisabled -ApprovedPath $run.Approved -Name $name)) { continue }
            [void]$items.Add([pscustomobject]@{ Type = 'Registry'; Name = $name; Command = [string]$key.GetValue($name); Source = $run.Source; ApprovedPath = $run.Approved })
        }
    }

    $folders = @(
        @{ Path = [Environment]::GetFolderPath('Startup');       Approved = "HKCU:\$approvedRoot\StartupFolder"; Source = 'Source_FolderUser' }
        @{ Path = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM:\$approvedRoot\StartupFolder"; Source = 'Source_FolderMachine' }
    )
    foreach ($folder in $folders) {
        if (-not $folder.Path -or -not (Test-Path -LiteralPath $folder.Path)) { continue }
        foreach ($file in (Get-ChildItem -LiteralPath $folder.Path -File -Force | Where-Object { $_.Name -ne 'desktop.ini' })) {
            if (Test-CardonStartupDisabled -ApprovedPath $folder.Approved -Name $file.Name) { continue }
            [void]$items.Add([pscustomobject]@{ Type = 'Registry'; Name = $file.Name; Command = $file.FullName; Source = $folder.Source; ApprovedPath = $folder.Approved })
        }
    }

    try {
        $tasks = Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.TaskPath -notlike '\Microsoft\*' -and [string]$_.State -ne 'Disabled' -and
            @($_.Triggers | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskLogonTrigger' }).Count -gt 0
        }
        foreach ($task in $tasks) {
            $command = (@($task.Actions) | Select-Object -First 1).Execute
            [void]$items.Add([pscustomobject]@{ Type = 'Task'; Name = $task.TaskName; Command = [string]$command; Source = 'Source_Task'; TaskPath = $task.TaskPath })
        }
    }
    catch {
        $null = $_   # Task Scheduler not available: list only the other sources.
    }

    foreach ($item in $items) {
        $item | Add-Member -NotePropertyName 'Protected' -NotePropertyValue (Test-CardonProtectedStartupItem -Name $item.Name -Command $item.Command)
    }
    return @($items)
}

function Get-CardonStartupCandidate {
    <# Startup entries that may be offered (protected ones are hidden and counted). #>
    $all = @(Get-CardonStartupItem)
    $items = @($all | Where-Object { -not $_.Protected })
    $protectedCount = $all.Count - $items.Count
    if ($protectedCount -gt 0) { Show-CardonText -Key 'Startup_ProtectedHidden' -Arguments @($protectedCount) -Style Detail }
    return $items
}

function Show-CardonStartupList {
    param([object[]]$Items)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $command = [string]$Items[$i].Command
        if ($command.Length -gt 60) { $command = $command.Substring(0, 57) + '...' }
        Write-CardonLine -Text ('    {0,2}) {1}  [{2}]' -f ($i + 1), $Items[$i].Name, (Get-CardonText -Key $Items[$i].Source)) -Style Info
        Write-CardonLine -Text ('        {0}' -f $command) -Style Detail
    }
}

function Confirm-CardonContinueLevel {
    <# After "0" in a selection list: nothing from that list is applied; the user decides about the rest. #>
    Show-CardonText -Key 'Info_ListCancelled' -Style Warn
    return (Read-CardonYesNo -Key 'Ask_ContinueLevel')
}

function Request-CardonStartupSelection {
    <# Prepare step: the user picks startup programs BEFORE any restore point, backup or change. #>
    param([Parameter(Mandatory)]$Action)
    $script:Plan[$Action.Id] = @()
    Write-CardonLine
    Show-CardonText -Key ('Action_{0}_Name' -f $Action.Id) -Style Title
    $items = @(Get-CardonStartupCandidate)
    if ($items.Count -eq 0) { Show-CardonText -Key 'Startup_None' -Style Detail; return $true }

    Show-CardonStartupList -Items $items
    $selection = Read-CardonSelection -Key 'Ask_SelectStartup' -Maximum $items.Count
    if ($selection.Cancelled) { return (Confirm-CardonContinueLevel) }
    $script:Plan[$Action.Id] = @(foreach ($number in $selection.Items) { $items[$number - 1] })
    return $true
}

function Invoke-CardonStartupReview {
    <# Disables only the startup programs the user picked in the prepare step. Nothing is disabled automatically. #>
    param([Parameter(Mandatory)]$Action)
    if ($script:DryRun) {
        $items = @(Get-CardonStartupCandidate)
        if ($items.Count -eq 0) { return (New-CardonResult -Status Unchanged -Detail (Get-CardonText -Key 'Startup_None')) }
        Show-CardonStartupList -Items $items
        return (New-CardonResult -Status Preview -Detail (Get-CardonText -Key 'Startup_PreviewNote'))
    }

    $chosen = @($script:Plan[$Action.Id] | Where-Object { $_ })
    if ($chosen.Count -eq 0) { return (New-CardonResult -Status Skipped) }

    $statuses = foreach ($item in $chosen) {
        if ($item.Type -eq 'Task') {
            Disable-CardonScheduledTask -ActionId $Action.Id -TaskPath $item.TaskPath -TaskName $item.Name
        }
        else {
            # 0x03 followed by 11 zero bytes = disabled. Undo restores the previous bytes.
            Set-CardonRegistryValue -ActionId $Action.Id -Path $item.ApprovedPath -Name $item.Name -Value ([byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Type Binary
        }
    }
    return (New-CardonResult -Status (Get-CardonCombinedStatus -Statuses @($statuses)) -Detail (Get-CardonText -Key 'Detail_Items' -Arguments @($chosen.Count)))
}

function Invoke-CardonComponentCleanup {
    <# DISM component store cleanup WITHOUT /ResetBase, so installed updates can still be uninstalled. #>
    if ($script:DryRun) { return (New-CardonResult -Status Preview) }
    Show-CardonText -Key 'Detail_DismWait' -Style Detail
    $drive = Get-PSDrive -Name ($env:SystemDrive.TrimEnd(':'))
    $freeBefore = [int64]$drive.Free
    $dism = Join-Path $env:SystemRoot 'System32\dism.exe'
    $process = Start-Process -FilePath $dism -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup' -NoNewWindow -Wait -PassThru -ErrorAction Stop
    # 3010 = success, restart required.
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw (Get-CardonText -Key 'Err_ExitCode' -Arguments @('DISM', $process.ExitCode))
    }
    $freed = [Math]::Max([int64]0, [int64](Get-PSDrive -Name $drive.Name).Free - $freeBefore)
    return (New-CardonResult -Status Changed -Bytes $freed)
}

function Get-CardonFixedVolume {
    <# Fixed volumes with a drive letter and the media type of the disk they live on. #>
    $volumes = Get-Volume -ErrorAction Stop | Where-Object {
        [string]$_.DriveType -eq 'Fixed' -and $_.DriveLetter -and @('NTFS', 'ReFS') -contains [string]$_.FileSystem
    }
    $disks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue)
    foreach ($volume in $volumes) {
        $media = 'Unspecified'
        try {
            $partition = Get-Partition -DriveLetter $volume.DriveLetter -ErrorAction Stop
            $disk = $disks | Where-Object { [string]$_.DeviceId -eq [string]$partition.DiskNumber } | Select-Object -First 1
            if ($disk) { $media = [string]$disk.MediaType }
        }
        catch {
            $null = $_   # Unknown media type: the volume will be skipped.
        }
        [pscustomobject]@{ Letter = [string]$volume.DriveLetter; Media = $media }
    }
}

function Invoke-CardonDiskOptimization {
    <# TRIM on SSD, defragment on HDD, nothing when the type is unknown. Never defragments an SSD. #>
    $statuses = foreach ($volume in @(Get-CardonFixedVolume)) {
        switch ($volume.Media) {
            'SSD' {
                Show-CardonText -Key 'Detail_Trim' -Arguments @($volume.Letter) -Style Detail
                if ($script:DryRun) { 'Preview' } else { Optimize-Volume -DriveLetter $volume.Letter -ReTrim -ErrorAction Stop; 'Changed' }
            }
            'HDD' {
                Show-CardonText -Key 'Detail_Defrag' -Arguments @($volume.Letter) -Style Detail
                if ($script:DryRun) { 'Preview' } else { Optimize-Volume -DriveLetter $volume.Letter -Defrag -ErrorAction Stop; 'Changed' }
            }
            default {
                Show-CardonText -Key 'Detail_DiskUnknown' -Arguments @($volume.Letter) -Style Warn
                'Skipped'
            }
        }
    }
    return (New-CardonResult -Status (Get-CardonCombinedStatus -Statuses @($statuses)))
}

#endregion

#region Actions: level 3 (Extreme, but safe)
# ---------------------------------------------------------------------------

function Initialize-CardonAppxModule {
    # In PowerShell 7 the Appx module must be loaded through Windows PowerShell compatibility.
    if ($PSVersionTable.PSEdition -eq 'Core' -and -not (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue)) {
        Import-Module -Name Appx -UseWindowsPowerShell -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
    }
}

function Get-CardonInstalledBloatware {
    <# Allow-listed apps that are installed for the current user. #>
    Initialize-CardonAppxModule
    $installed = foreach ($app in $script:BloatwareCatalog) {
        if (Test-CardonProtectedPackage -Package $app.Package) { continue }
        $package = Get-AppxPackage -Name $app.Package -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($package) { [pscustomobject]@{ Name = $app.Name; Package = $package } }
    }
    return @($installed)
}

function Show-CardonBloatwareList {
    param([object[]]$Apps)
    Show-CardonText -Key 'Warn_BloatwareIrreversible' -Style Warn
    for ($i = 0; $i -lt $Apps.Count; $i++) {
        Write-CardonLine -Text ('    {0,2}) {1}' -f ($i + 1), $Apps[$i].Name) -Style Info
    }
}

function Request-CardonBloatwareSelection {
    <# Prepare step: the user picks apps to remove BEFORE any restore point, backup or change. #>
    param([Parameter(Mandatory)]$Action)
    $script:Plan[$Action.Id] = @()
    Write-CardonLine
    Show-CardonText -Key ('Action_{0}_Name' -f $Action.Id) -Style Title
    $installed = @(Get-CardonInstalledBloatware)
    if ($installed.Count -eq 0) { Show-CardonText -Key 'Bloat_None' -Style Detail; return $true }

    Show-CardonBloatwareList -Apps $installed
    $selection = Read-CardonSelection -Key 'Ask_SelectBloatware' -Maximum $installed.Count
    if ($selection.Cancelled) { return (Confirm-CardonContinueLevel) }
    $script:Plan[$Action.Id] = @(foreach ($number in $selection.Items) { $installed[$number - 1] })
    return $true
}

function Invoke-CardonBloatwareRemoval {
    <# Removes only the apps the user picked in the prepare step. #>
    param([Parameter(Mandatory)]$Action)
    if ($script:DryRun) {
        $installed = @(Get-CardonInstalledBloatware)
        if ($installed.Count -eq 0) { return (New-CardonResult -Status Unchanged -Detail (Get-CardonText -Key 'Bloat_None')) }
        Show-CardonBloatwareList -Apps $installed
        return (New-CardonResult -Status Preview -Detail (Get-CardonText -Key 'Bloat_PreviewNote'))
    }

    $chosen = @($script:Plan[$Action.Id] | Where-Object { $_ })
    if ($chosen.Count -eq 0) { return (New-CardonResult -Status Skipped) }

    $removed = 0
    foreach ($app in $chosen) {
        try {
            [void](Remove-CardonAppPackage -Package $app.Package)
            Show-CardonText -Key 'Bloat_Removed' -Arguments @($app.Name) -Style Ok
            $removed++
        }
        catch {
            Show-CardonText -Key 'Bloat_Failed' -Arguments @($app.Name, $_.Exception.Message) -Style Error
        }
    }
    $status = if ($removed -gt 0) { 'Changed' } else { 'Error' }
    return (New-CardonResult -Status $status -Detail (Get-CardonText -Key 'Detail_Items' -Arguments @($removed)))
}

function Invoke-CardonServicesManual {
    param([Parameter(Mandatory)]$Action)
    $statuses = foreach ($name in $script:ManualServices) { Set-CardonServiceManual -ActionId $Action.Id -Name $name }
    return (New-CardonResult -Status (Get-CardonCombinedStatus -Statuses @($statuses)))
}

function Test-CardonUltimateActive {
    param([string]$Guid)
    return (@($script:PowerSchemes.UltimateCardon, $script:PowerSchemes.UltimateSource) -contains $Guid)
}

function Request-CardonUltimateChoice {
    <# Prepare step: on desktops, ask whether to use Ultimate Performance. Never offered on notebooks. #>
    param([Parameter(Mandatory)]$Action)
    $script:Plan[$Action.Id] = $false
    if ((Get-CardonDeviceType) -eq 'Notebook') { return $true }
    if (Test-CardonUltimateActive -Guid (Get-CardonActivePowerScheme)) { return $true }

    Write-CardonLine
    Show-CardonText -Key ('Action_{0}_Name' -f $Action.Id) -Style Title
    Show-CardonText -Key 'Warn_UltimateDesktopOnly' -Style Warn
    if (Test-CardonBattery) { Show-CardonText -Key 'Warn_UltimateBattery' -Style Warn }
    # "N" or "0" here only skips this optional plan; the rest of the level continues.
    $script:Plan[$Action.Id] = Read-CardonYesNo -Key 'Ask_Ultimate'
    return $true
}

function Invoke-CardonUltimatePerformance {
    <# Optional, desktops only: applied only when the user said yes in the prepare step. #>
    param([Parameter(Mandatory)]$Action)
    if ((Get-CardonDeviceType) -eq 'Notebook') {
        return (New-CardonResult -Status Skipped -Detail (Get-CardonText -Key 'Ultimate_NotebookSkipped'))
    }
    $active = Get-CardonActivePowerScheme
    if (Test-CardonUltimateActive -Guid $active) { return (New-CardonResult -Status Unchanged) }

    if ($script:DryRun) {
        Show-CardonText -Key 'Warn_UltimateDesktopOnly' -Style Warn
        if (Test-CardonBattery) { Show-CardonText -Key 'Warn_UltimateBattery' -Style Warn }
        Show-CardonText -Key 'Preview_PowerScheme' -Arguments @((Get-CardonPowerSchemeName -Guid $active), (Get-CardonText -Key 'Ultimate_Name')) -Style Detail
        return (New-CardonResult -Status Preview)
    }
    if (-not $script:Plan[$Action.Id]) { return (New-CardonResult -Status Skipped) }

    $guid = New-CardonUltimatePowerScheme -ActionId $Action.Id
    return (New-CardonResult -Status (Set-CardonPowerScheme -ActionId $Action.Id -Guid $guid))
}

#endregion

#region Action catalog
# ---------------------------------------------------------------------------

function Get-CardonActionCatalog {
    <#
        Declarative list of every optimization. Fields:
          Id           Unique name. Texts come from Action_<Id>_Name / Action_<Id>_Desc in lang\*.psd1.
          Level        1 Standard, 2 Advanced, 3 Extreme. Each level includes the previous ones.
          Category     Registry, Service, Power, Startup, Cleanup, Maintenance or Bloatware.
          Reversible   $true when the change is saved in the backup and can be undone.
          Apply        Scriptblock receiving the action. Must honor $script:DryRun and be idempotent.
          Revert       Scriptblock receiving this action's backup entries ($null if not reversible).
          Registry     (optional) Values applied by Invoke-CardonRegistryAction.
          Interactive  The user chooses something for this step.
          Prepare      (interactive steps) Scriptblock that asks the user BEFORE the restore point and
                       backup are created. Returns $false when the user wants to go back to the menu.
          NeedsRestart The change is fully visible after signing out or restarting.
    #>
    $revert = { param($Entries) foreach ($entry in $Entries) { Restore-CardonEntry -Entry $entry } }
    $registry = { param($Action) Invoke-CardonRegistryAction -Action $Action }
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

    return @(
        # ---- Level 1: Standard -------------------------------------------------
        @{ Id = 'TempFiles'; Level = 1; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonTempCleanup } }
        @{ Id = 'ThumbnailCache'; Level = 1; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonThumbnailCleanup } }
        @{ Id = 'UpdateCache'; Level = 1; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonUpdateCacheCleanup } }
        @{ Id = 'CrashDumps'; Level = 1; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonCrashDumpCleanup } }
        @{ Id = 'RecycleBin'; Level = 1; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonRecycleBinCleanup } }
        @{ Id = 'DnsCache'; Level = 1; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonDnsFlush } }
        @{ Id = 'PowerPlan'; Level = 1; Category = 'Power'; Reversible = $true; Revert = $revert
           Apply = { param($Action) Invoke-CardonPowerPlan -Action $Action } }
        @{ Id = 'GameDvr'; Level = 1; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry
           Registry = @(
               @{ Path = 'HKCU:\System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 }
               @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 }
           ) }
        @{ Id = 'Suggestions'; Level = 1; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry
           Registry = @(
               @{ Path = $cdm; Name = 'SilentInstalledAppsEnabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SoftLandingEnabled'; Value = 0 }
               @{ Path = $cdm; Name = 'OemPreInstalledAppsEnabled'; Value = 0 }
               @{ Path = $cdm; Name = 'PreInstalledAppsEnabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SubscribedContent-310093Enabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SubscribedContent-338388Enabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SubscribedContent-338389Enabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SubscribedContent-338393Enabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SubscribedContent-353694Enabled'; Value = 0 }
               @{ Path = $cdm; Name = 'SubscribedContent-353696Enabled'; Value = 0 }
               @{ Path = $advanced; Name = 'Start_IrisRecommendations'; Value = 0; MinBuild = 22000 }
           ) }

        # ---- Level 2: Advanced -------------------------------------------------
        @{ Id = 'VisualEffects'; Level = 2; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry; NeedsRestart = $true
           Registry = @(
               @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Value = 3 }
               @{ Path = $advanced; Name = 'TaskbarAnimations'; Value = 0 }
               @{ Path = $advanced; Name = 'ListviewAlphaSelect'; Value = 0 }
               @{ Path = $advanced; Name = 'ListviewShadow'; Value = 0 }
               @{ Path = 'HKCU:\Software\Microsoft\Windows\DWM'; Name = 'EnableAeroPeek'; Value = 0 }
               # Kept on purpose so the system still looks good:
               @{ Path = $advanced; Name = 'IconsOnly'; Value = 0 }                                   # thumbnails
               @{ Path = 'HKCU:\Control Panel\Desktop'; Name = 'FontSmoothing'; Value = '2'; Type = 'String' }  # ClearType
           ) }
        @{ Id = 'StartupApps'; Level = 2; Category = 'Startup'; Reversible = $true; Revert = $revert; Interactive = $true; NeedsRestart = $true
           Prepare = { param($Action) Request-CardonStartupSelection -Action $Action }
           Apply = { param($Action) Invoke-CardonStartupReview -Action $Action } }
        @{ Id = 'BackgroundApps'; Level = 2; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry
           Registry = @(
               @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; Name = 'GlobalUserDisabled'; Value = 1 }
               @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'; Name = 'BackgroundAppGlobalToggle'; Value = 0 }
           ) }
        @{ Id = 'Widgets'; Level = 2; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry; NeedsRestart = $true
           Registry = @(
               @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'; Name = 'AllowNewsAndInterests'; Value = 0; MinBuild = 22000 }
               @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'; Name = 'EnableFeeds'; Value = 0; MaxBuild = 21999 }
           ) }
        @{ Id = 'Telemetry'; Level = 2; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry
           Registry = @(
               @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = { Get-CardonMinimumTelemetryLevel } }
           ) }
        @{ Id = 'ComponentCleanup'; Level = 2; Category = 'Cleanup'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonComponentCleanup } }
        @{ Id = 'DiskOptimization'; Level = 2; Category = 'Maintenance'; Reversible = $false; Revert = $null
           Apply = { Invoke-CardonDiskOptimization } }

        # ---- Level 3: Extreme (safe) -------------------------------------------
        @{ Id = 'Bloatware'; Level = 3; Category = 'Bloatware'; Reversible = $false; Revert = $null; Interactive = $true
           Prepare = { param($Action) Request-CardonBloatwareSelection -Action $Action }
           Apply = { param($Action) Invoke-CardonBloatwareRemoval -Action $Action } }
        @{ Id = 'ServicesManual'; Level = 3; Category = 'Service'; Reversible = $true; Revert = $revert; NeedsRestart = $true
           Apply = { param($Action) Invoke-CardonServicesManual -Action $Action } }
        @{ Id = 'Animations'; Level = 3; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry; NeedsRestart = $true
           Registry = @(
               @{ Path = 'HKCU:\Control Panel\Desktop\WindowMetrics'; Name = 'MinAnimate'; Value = '0'; Type = 'String' }
               @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 0 }
           ) }
        @{ Id = 'DeliveryOptimization'; Level = 3; Category = 'Registry'; Reversible = $true; Revert = $revert; Apply = $registry
           Registry = @(
               # 0 = HTTP only: downloads come from Microsoft, no peer-to-peer sharing.
               @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Name = 'DODownloadMode'; Value = 0 }
           ) }
        @{ Id = 'UltimatePerformance'; Level = 3; Category = 'Power'; Reversible = $true; Revert = $revert; Interactive = $true
           Prepare = { param($Action) Request-CardonUltimateChoice -Action $Action }
           Apply = { param($Action) Invoke-CardonUltimatePerformance -Action $Action } }
    )
}

#endregion

#region Level runner and summary
# ---------------------------------------------------------------------------

function Show-CardonLevelDescription {
    param([int]$Level, [object[]]$Actions)
    Write-CardonLine
    Show-CardonText -Key ('Level_{0}_Title' -f $Level) -Style Title
    Show-CardonText -Key ('Level_{0}_Summary' -f $Level) -Style Info
    Write-CardonLine
    foreach ($action in $Actions) {
        Write-CardonLine -Text ('  - {0}' -f (Get-CardonText -Key ('Action_{0}_Name' -f $action.Id))) -Style Info
        Write-CardonLine -Text ('      {0}' -f (Get-CardonText -Key ('Action_{0}_Desc' -f $action.Id))) -Style Detail
    }
    Write-CardonLine
    Show-CardonText -Key 'Info_DeviceProfile' -Arguments @((Get-CardonDeviceName)) -Style Detail
    if ((Get-CardonDeviceType) -eq 'Notebook') { Show-CardonText -Key 'Info_NotebookPower' -Style Detail }
    if ($Level -ge 2) { Show-CardonText -Key 'Warn_Level2_Time' -Style Warn }
    Show-CardonText -Key 'Info_SafetyNet' -Style Detail
    # Last thing shown right before the confirmation of the Extreme level.
    if ($Level -ge 3) {
        Write-CardonLine
        Show-CardonText -Key 'Warn_Level3_Apps' -Style Warn
        Show-CardonText -Key 'Info_StoreReinstall' -Style Detail
    }
}

function Write-CardonStepResult {
    param([Parameter(Mandatory)]$Result, [switch]$Inline)
    $styles = @{
        Changed   = @('Status_Ok', 'Ok')
        Unchanged = @('Status_Unchanged', 'Warn')
        Skipped   = @('Status_Skipped', 'Warn')
        Preview   = @('Status_Preview', 'Detail')
        Error     = @('Status_Error', 'Error')
    }
    $style = $styles[$Result.Status]
    $text = Get-CardonText -Key $style[0]
    if ($Result.Bytes -gt 0) { $text = '{0} ({1})' -f $text, (Format-CardonSize -Bytes $Result.Bytes) }
    if ($Result.Detail) { $text = '{0} - {1}' -f $text, $Result.Detail }
    if (-not $Inline) { $text = '    -> ' + $text }
    Write-CardonLine -Text $text -Style $style[1]
}

function Invoke-CardonAction {
    <# Runs one action. Any error is logged and reported; the level continues with the next step. #>
    param([Parameter(Mandatory)]$Action, [int]$Index, [int]$Total)
    $name = Get-CardonText -Key ('Action_{0}_Name' -f $Action.Id)
    $inline = -not ($script:DryRun -or $Action.Interactive)
    Write-CardonLine -Text ('[{0}/{1}] {2}... ' -f $Index, $Total, $name) -Style Info -NoNewline:$inline

    try {
        $result = & $Action.Apply $Action
        if ($null -eq $result -or $null -eq $result.Status) { $result = New-CardonResult -Status Changed }
    }
    catch {
        $result = New-CardonResult -Status Error -Detail $_.Exception.Message
    }
    Write-CardonStepResult -Result $result -Inline:$inline
    Write-CardonLog -Message ('{0} -> {1} {2}' -f $name, $result.Status, $result.Detail) -Level $(if ($result.Status -eq 'Error') { 'ERROR' } else { 'INFO' })

    switch ($result.Status) {
        'Changed'   { $script:Stats.Changed++; if ($Action.NeedsRestart) { $script:Stats.NeedsRestart = $true } }
        'Error'     { $script:Stats.Errors++ }
        'Preview'   { $script:Stats.Previewed++ }
        default     { $script:Stats.Skipped++ }
    }
    $script:Stats.FreedBytes += $result.Bytes
}

function Show-CardonSummary {
    param([switch]$Preview)
    Write-CardonLine
    Show-CardonText -Key 'Summary_Title' -Style Title
    $freed = Format-CardonSize -Bytes $script:Stats.FreedBytes
    if ($Preview) {
        Show-CardonText -Key 'Summary_PreviewNote' -Style Warn
        Show-CardonText -Key 'Summary_PreviewCount' -Arguments @($script:Stats.Previewed) -Style Info
        Show-CardonText -Key 'Summary_PreviewSpace' -Arguments @($freed) -Style Info
        return
    }
    Show-CardonText -Key 'Summary_Freed' -Arguments @($freed) -Style Ok
    Show-CardonText -Key 'Summary_Applied' -Arguments @($script:Stats.Changed) -Style Ok
    Show-CardonText -Key 'Summary_Skipped' -Arguments @($script:Stats.Skipped) -Style Warn
    $errorStyle = if ($script:Stats.Errors -gt 0) { 'Error' } else { 'Info' }
    Show-CardonText -Key 'Summary_Errors' -Arguments @($script:Stats.Errors) -Style $errorStyle
    if ($script:LogFile) { Show-CardonText -Key 'Summary_Log' -Arguments @($script:LogFile) -Style Detail }
    if ($script:BackupPath) { Show-CardonText -Key 'Summary_Backup' -Arguments @($script:BackupPath) -Style Detail }
    if ($script:Stats.NeedsRestart) { Show-CardonText -Key 'Summary_Restart' -Style Warn }
}

function Invoke-CardonLevel {
    <#
        Runs every action up to $Level. With -Preview nothing is changed:
        no restore point, no backup, no prompts.

        Real run, in two phases:
          1. Questions: level confirmation and every user choice (Prepare steps).
             Answering N or 0 returns to the menu with nothing created or changed.
          2. Changes: restore point, backup, then all actions without further questions.
    #>
    param([Parameter(Mandatory)][ValidateRange(1, 3)][int]$Level, [switch]$Preview)
    $actions = @(Get-CardonActionCatalog | Where-Object { $_.Level -le $Level })
    $script:Stats = @{ Changed = 0; Skipped = 0; Errors = 0; Previewed = 0; FreedBytes = [int64]0; NeedsRestart = $false }
    $script:Backup = $null
    $script:BackupPath = $null
    $script:Plan = @{}

    Show-CardonLevelDescription -Level $Level -Actions $actions
    if ($Preview) {
        Write-CardonLine
        Show-CardonText -Key 'Preview_Header' -Style Warn
    }
    else {
        if (-not (Read-CardonYesNo -Key 'Ask_ApplyLevel' -Arguments @((Get-CardonText -Key ('Level_{0}_Title' -f $Level))))) {
            Show-CardonText -Key 'Info_Cancelled' -Style Warn
            return
        }
        if (-not (Test-CardonAdministrator)) { Show-CardonText -Key 'Err_NotAdmin' -Style Error; return }
        if (-not (Get-CardonOsInfo).IsSupported) { Show-CardonText -Key 'Err_UnsupportedOs' -Arguments @((Get-CardonOsInfo).Caption) -Style Error; return }
        # All choices are collected first, so going back leaves no restore point or backup behind.
        foreach ($action in ($actions | Where-Object { $_.Prepare })) {
            if (-not (& $action.Prepare $action)) { Show-CardonText -Key 'Info_Cancelled' -Style Warn; return }
        }
        Write-CardonLine
        if (-not (New-CardonRestorePoint)) { Show-CardonText -Key 'Info_Cancelled' -Style Warn; return }
        try {
            New-CardonBackupSession -Level $Level
        }
        catch {
            # Without a backup nothing may be changed.
            Show-CardonText -Key 'Err_BackupFailed' -Arguments @($_.Exception.Message) -Style Error
            return
        }
    }

    $script:DryRun = [bool]$Preview
    try {
        Write-CardonLine
        for ($i = 0; $i -lt $actions.Count; $i++) {
            Invoke-CardonAction -Action $actions[$i] -Index ($i + 1) -Total $actions.Count
        }
    }
    finally {
        $script:DryRun = $false
    }
    Show-CardonSummary -Preview:$Preview
}

#endregion

#region Menus
# ---------------------------------------------------------------------------

function Show-CardonBanner {
    Write-CardonLine
    foreach ($line in $script:BannerArt) { Write-CardonLine -Text $line -Style Title }
    Write-CardonLine -Text ('  v{0}   {1}' -f $script:Version, $script:Website) -Style Detail
}

function Show-CardonSafetyNotice {
    Write-CardonLine
    Show-CardonText -Key 'Welcome_Tagline' -Style Info
    Show-CardonText -Key 'Welcome_Safety' -Style Warn
}

function Read-CardonLevelChoice {
    <# Returns 1-3, or 0 to go back. #>
    Write-CardonLine
    Show-CardonText -Key 'Preview_ChooseLevel' -Style Title
    foreach ($level in 1..3) { Write-CardonLine -Text ('  {0}) {1}' -f $level, (Get-CardonText -Key ('Level_{0}_Title' -f $level))) -Style Info }
    Write-CardonLine -Text ('  0) {0}' -f (Get-CardonText -Key 'Menu_Back')) -Style Info
    while ($true) {
        $choice = ([string](Read-Host -Prompt (Get-CardonText -Key 'Prompt_Choice'))).Trim()
        if ($choice -match '^[0-3]$') { return [int]$choice }
    }
}

function Invoke-CardonUndoMenu {
    <# Returns $false when the user chose "0) Back", so the caller goes straight to the main menu. #>
    $backups = @(Get-CardonBackupList)
    Write-CardonLine
    Show-CardonText -Key 'Undo_Title' -Style Title
    if ($backups.Count -eq 0) { Show-CardonText -Key 'Undo_None' -Style Warn; return $true }

    for ($i = 0; $i -lt $backups.Count; $i++) {
        $item = $backups[$i]
        $flag = if ($item.Restored) { Get-CardonText -Key 'Undo_AlreadyRestored' } else { '' }
        $levelName = Get-CardonText -Key ('Level_{0}_Title' -f $item.Level)
        Write-CardonLine -Text ('  {0,2}) {1}  {2}  ({3}) {4}' -f ($i + 1), $item.Created.Replace('T', ' '), $levelName, (Get-CardonText -Key 'Detail_Items' -Arguments @($item.Count)), $flag) -Style Info
    }
    Write-CardonLine -Text ('   0) {0}' -f (Get-CardonText -Key 'Menu_Back')) -Style Info
    Show-CardonText -Key 'Undo_AppsNote' -Style Detail
    while ($true) {
        $selection = Read-CardonSelection -Key 'Undo_Prompt' -Maximum $backups.Count
        if ($selection.Cancelled -or $selection.Items.Count -eq 0) { return $false }
        if ($selection.Items.Count -eq 1) { break }
        Show-CardonText -Key 'Err_Selection' -Arguments @($backups.Count) -Style Warn
    }

    $chosen = $backups[$selection.Items[0] - 1]
    if (-not (Read-CardonYesNo -Key 'Ask_Restore' -Arguments @($chosen.Created.Replace('T', ' ')))) { return $false }
    $result = Restore-CardonBackup -BackupItem $chosen
    Write-CardonLine
    Show-CardonText -Key 'Undo_Done' -Arguments @($result.Ok, $result.Failed) -Style $(if ($result.Failed -gt 0) { 'Warn' } else { 'Ok' })
    Show-CardonText -Key 'Summary_Restart' -Style Warn
    return $true
}

function Show-CardonLog {
    Write-CardonLine
    Show-CardonText -Key 'Log_Title' -Style Title
    $logs = @(Get-ChildItem -LiteralPath $script:LogRoot -Filter '*.log' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    if ($logs.Count -eq 0) { Show-CardonText -Key 'Log_None' -Style Warn; return }
    Show-CardonText -Key 'Log_Folder' -Arguments @($script:LogRoot) -Style Detail
    Show-CardonText -Key 'Log_Showing' -Arguments @($logs[0].Name) -Style Info
    foreach ($line in (Get-Content -LiteralPath $logs[0].FullName -Tail 40 -Encoding UTF8)) { Write-CardonLine -Text $line -Style Detail }
}

function Show-CardonMainMenu {
    Write-CardonLine
    Show-CardonText -Key 'Menu_Title' -Style Title
    Write-CardonLine -Text (Get-CardonText -Key 'Menu_Header' -Arguments @($script:Text.LanguageName, (Get-CardonDeviceName))) -Style Detail
    foreach ($option in @('1', '2', '3', '4', '5', '6', '7', '8', '0')) {
        Write-CardonLine -Text ('  {0}) {1}' -f $option, (Get-CardonText -Key ('Menu_{0}' -f $option))) -Style Info
    }
    return ([string](Read-Host -Prompt (Get-CardonText -Key 'Prompt_Choice'))).Trim()
}

function Invoke-CardonMenuChoice {
    <#
        Runs one main menu option. Every secondary screen comes back here; "0" on a
        secondary screen means "back". Returns $false only for "0" in the main menu (exit).
    #>
    param([string]$Choice)
    switch ($Choice) {
        '1' { Invoke-CardonLevel -Level 1; Wait-CardonBack }
        '2' { Invoke-CardonLevel -Level 2; Wait-CardonBack }
        '3' { Invoke-CardonLevel -Level 3; Wait-CardonBack }
        '4' {
            $level = Read-CardonLevelChoice
            if ($level -gt 0) { Invoke-CardonLevel -Level $level -Preview; Wait-CardonBack }
        }
        '5' { if (Invoke-CardonUndoMenu) { Wait-CardonBack } }
        '6' { Show-CardonLog; Wait-CardonBack }
        '7' { [void](Select-CardonLanguage -AllowBack) }
        '8' { [void](Select-CardonDeviceType) }
        '0' { Show-CardonText -Key 'Info_Goodbye' -Style Title; return $false }
        default { Show-CardonText -Key 'Err_MenuOption' -Style Warn }
    }
    return $true
}

function Start-CardonOptimizer {
    param([string]$LanguageCode, [string]$DeviceType)
    Show-CardonBanner
    if (-not ($LanguageCode -and (Import-CardonLanguage -Code $LanguageCode))) { [void](Select-CardonLanguage) }
    if (@('Desktop', 'Notebook') -contains $DeviceType) {
        $script:SessionDeviceType = $DeviceType
    }
    else {
        # "0" on the device screen goes back to the language selector.
        while (-not (Select-CardonDeviceType -BackKey 'Device_BackToLanguage')) { [void](Select-CardonLanguage) }
    }
    Show-CardonSafetyNotice

    if (-not (Test-CardonAdministrator)) {
        Show-CardonText -Key 'Elevation_Requesting' -Style Warn
        if (Request-CardonElevation -LanguageCode $script:LanguageCode -DeviceType $script:SessionDeviceType) { return }
        Show-CardonText -Key 'Elevation_Failed' -Style Error
        Wait-CardonEnter
        return
    }

    try {
        $os = Get-CardonOsInfo
    }
    catch {
        Show-CardonText -Key 'Err_Generic' -Arguments @($_.Exception.Message) -Style Error
        Wait-CardonEnter
        return
    }
    if (-not $os.IsSupported) {
        Show-CardonText -Key 'Err_UnsupportedOs' -Arguments @($os.Caption) -Style Error
        Wait-CardonEnter
        return
    }

    Initialize-CardonStorage
    Write-CardonLog -Message ('CardonOptimizer {0} | {1} | build {2} | PowerShell {3} | {4}' -f $script:Version, $os.Caption, $os.Build, $PSVersionTable.PSVersion, $script:SessionDeviceType)
    Show-CardonText -Key 'Info_System' -Arguments @($os.Caption, $os.Build) -Style Detail

    while (Invoke-CardonMenuChoice -Choice (Show-CardonMainMenu)) { }
}

#endregion

# Run only when executed directly. When dot-sourced (tests), just load the functions.
if ($MyInvocation.InvocationName -ne '.') {
    Start-CardonOptimizer -LanguageCode $Language -DeviceType $DeviceType
}
