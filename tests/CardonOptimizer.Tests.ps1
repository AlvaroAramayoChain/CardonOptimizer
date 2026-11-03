#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester 5 tests for CardonOptimizer.

    Run from the repository root (no administrator rights needed):
        Invoke-Pester -Path .\tests -Output Detailed

    These tests never modify the system: they parse the script, inspect the
    action catalog, use mocks for every state-changing command and run the
    levels in preview (DryRun) mode only. File deletion is tested inside
    Pester's temporary TestDrive folder.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Variables set in BeforeAll are used inside It blocks.')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Parameters are used inside the FindAll predicate scriptblock.')]
param()

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $ScriptPath = Join-Path $RepoRoot 'CardonOptimizer.ps1'

    # Dot-sourcing only defines the functions: the script does not start its menu.
    . $ScriptPath

    $parseTokens = $null
    $parseErrors = $null
    $ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$parseTokens, [ref]$parseErrors)
    # Source code without comments, used to look for forbidden commands.
    $CodeText = ($parseTokens | Where-Object { $_.Kind -ne 'Comment' } | ForEach-Object { $_.Text }) -join ' '

    $Languages = @{}
    foreach ($file in (Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'lang') -Filter '*.psd1')) {
        $Languages[$file.BaseName] = Import-PowerShellDataFile -LiteralPath $file.FullName
    }
    [void](Import-CardonLanguage -Code 'en')
    $Catalog = @(Get-CardonActionCatalog)

    function Get-TestCommandAst {
        param([string[]]$Name)
        $ScriptAst.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.CommandAst] -and $Name -contains $node.GetCommandName()
        }, $true)
    }

    function Get-TestParentFunctionName {
        param($Node)
        $parent = $Node.Parent
        while ($parent -and $parent -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $parent = $parent.Parent }
        if ($parent) { return $parent.Name }
        return $null
    }
}

Describe 'Repository files' {
    It 'every PowerShell file parses without errors' {
        foreach ($file in (Get-ChildItem -LiteralPath $RepoRoot -Recurse -File | Where-Object { @('.ps1', '.psd1') -contains $_.Extension })) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty -Because $file.Name
        }
    }

    It 'every .ps1 and .psd1 file is UTF-8 with BOM (accents in Windows PowerShell 5.1)' {
        foreach ($file in (Get-ChildItem -LiteralPath $RepoRoot -Recurse -File | Where-Object { @('.ps1', '.psd1') -contains $_.Extension })) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue -Because $file.Name
        }
    }

    It 'script-scope variables never overwrite the script parameters' {
        # At script scope, $script:<Name> IS the parameter $<Name>: assigning it would lose the value passed on relaunch.
        $parameters = @($ScriptAst.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        $parameters | Should -Contain 'DeviceType'
        # Only script-level assignments or explicit $script: ones count; locals inside functions do not clash.
        $assigned = $ScriptAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true) |
            Where-Object { $_.Left -is [System.Management.Automation.Language.VariableExpressionAst] } |
            Where-Object { $_.Left.VariablePath.UserPath -like 'script:*' -or -not (Get-TestParentFunctionName -Node $_) } |
            ForEach-Object { $_.Left.VariablePath.UserPath -replace '^script:', '' }
        foreach ($name in $parameters) { $assigned | Should -Not -Contain $name -Because "`$$name is a script parameter" }
    }

    It 'contains the required project files' {
        foreach ($name in @('Ejecutar.bat', 'README.md', 'LICENSE', 'CHANGELOG.md', '.gitignore', 'lang\es.psd1', 'lang\en.psd1', 'tests\MANUAL-TESTING.md')) {
            Join-Path $RepoRoot $name | Should -Exist
        }
    }
}

Describe 'Language files' {
    It 'includes Spanish and English' {
        $Languages.Keys | Should -Contain 'es'
        $Languages.Keys | Should -Contain 'en'
    }

    It 'all languages have exactly the same keys as es.psd1' {
        $reference = @($Languages['es'].Keys | Sort-Object)
        foreach ($code in $Languages.Keys) {
            $keys = @($Languages[$code].Keys | Sort-Object)
            Compare-Object -ReferenceObject $reference -DifferenceObject $keys | Should -BeNullOrEmpty -Because "lang\$code.psd1"
        }
    }

    It 'no value is empty' {
        foreach ($code in $Languages.Keys) {
            foreach ($key in $Languages[$code].Keys) {
                [string]$Languages[$code][$key] | Should -Not -BeNullOrEmpty -Because "$code.$key"
            }
        }
    }

    It 'every translation uses the same {n} placeholders' {
        foreach ($key in $Languages['es'].Keys) {
            $expected = @([regex]::Matches([string]$Languages['es'][$key], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
            foreach ($code in $Languages.Keys) {
                $actual = @([regex]::Matches([string]$Languages[$code][$key], '\{\d+\}') | ForEach-Object Value | Sort-Object -Unique) -join ','
                $actual | Should -Be $expected -Because "$code.$key"
            }
        }
    }

    It 'every literal -Key used by the script exists in every language' {
        $keyCommands = Get-TestCommandAst -Name @('Get-CardonText', 'Show-CardonText', 'Read-CardonYesNo', 'Read-CardonSelection')
        $keys = foreach ($command in $keyCommands) {
            $elements = $command.CommandElements
            for ($i = 1; $i -lt $elements.Count - 1; $i++) {
                if ($elements[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $elements[$i].ParameterName -eq 'Key' -and
                    $elements[$i + 1] -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                    $elements[$i + 1].Value
                }
            }
        }
        @($keys).Count | Should -BeGreaterThan 50
        foreach ($key in ($keys | Sort-Object -Unique)) {
            foreach ($code in $Languages.Keys) { $Languages[$code].ContainsKey($key) | Should -BeTrue -Because "$code is missing '$key'" }
        }
    }

    It 'every key built at runtime exists in every language' {
        $dynamic = @('LanguageName', 'LanguagePrompt', 'SortOrder', 'YesKey', 'NoKey', 'StartType_Automatic',
                     'Device_Desktop', 'Device_Notebook', 'Device_BackToLanguage', 'Menu_Back')
        $dynamic += foreach ($action in $Catalog) { "Action_$($action.Id)_Name"; "Action_$($action.Id)_Desc" }
        $dynamic += foreach ($level in 1..3) { "Level_$($level)_Title"; "Level_$($level)_Summary" }
        $dynamic += foreach ($option in 0..8) { "Menu_$option" }
        $dynamic += 'Status_Ok', 'Status_Unchanged', 'Status_Skipped', 'Status_Preview', 'Status_Error'
        $dynamic += 'Source_RegistryUser', 'Source_RegistryMachine', 'Source_FolderUser', 'Source_FolderMachine', 'Source_Task'
        foreach ($key in $dynamic) {
            foreach ($code in $Languages.Keys) { $Languages[$code].ContainsKey($key) | Should -BeTrue -Because "$code is missing '$key'" }
        }
    }

    It 'adding a language only requires a file: every file is listed by the selector' {
        $listed = @(Get-CardonLanguageList | ForEach-Object Code)
        foreach ($code in $Languages.Keys) { $listed | Should -Contain $code }
        $listed[0] | Should -Be 'es'
    }
}

Describe 'No hardcoded visible text' {
    It 'Write-Host is only used inside Write-CardonLine' {
        foreach ($command in (Get-TestCommandAst -Name @('Write-Host'))) {
            Get-TestParentFunctionName -Node $command | Should -Be 'Write-CardonLine'
        }
    }

    It 'output commands never receive literal words (texts come from lang\*.psd1)' {
        $outputCommands = @('Write-Host', 'Write-CardonLine', 'Show-CardonText', 'Read-Host', 'Read-CardonYesNo', 'Read-CardonSelection',
                            'Write-Warning', 'Write-Output', 'Write-Progress', 'Write-Information')
        $nonTextParameters = @('ForegroundColor', 'BackgroundColor', 'Style', 'Key')
        $stringTypes = { param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }

        $violations = foreach ($command in (Get-TestCommandAst -Name $outputCommands)) {
            $elements = $command.CommandElements
            for ($i = 1; $i -lt $elements.Count; $i++) {
                $element = $elements[$i]
                if ($element -is [System.Management.Automation.Language.CommandParameterAst]) {
                    if ($nonTextParameters -contains $element.ParameterName -and -not $element.Argument) { $i++ }
                    continue
                }
                foreach ($string in $element.FindAll($stringTypes, $true)) {
                    # Member names ($_.Exception.Message) and nested command names are code, not text.
                    if ($string.Parent -is [System.Management.Automation.Language.MemberExpressionAst] -and $string.Parent.Member -eq $string) { continue }
                    if ($string.Parent -is [System.Management.Automation.Language.CommandAst] -and $string.Parent.CommandElements[0] -eq $string) { continue }
                    # Keys passed to Get-CardonText are not visible text.
                    $parent = $string.Parent
                    $isKey = $false
                    while ($parent -and $parent -ne $command) {
                        if ($parent -is [System.Management.Automation.Language.CommandAst] -and $parent.GetCommandName() -eq 'Get-CardonText') { $isKey = $true; break }
                        $parent = $parent.Parent
                    }
                    if ($isKey) { continue }
                    $value = $string.Value -replace '\$\{[^}]+\}|\$\([^)]*\)|\$[\w:]+', ''
                    if ($value -match '\p{L}{2,}') { '{0}: {1}' -f $string.Extent.StartLineNumber, $string.Extent.Text }
                }
            }
        }
        $violations | Should -BeNullOrEmpty
    }
}

Describe 'Action catalog' {
    It 'has 21 actions with unique ids (9 Standard, 7 Advanced, 5 Extreme)' {
        $Catalog.Count | Should -Be 21
        @($Catalog.Id | Sort-Object -Unique).Count | Should -Be 21
        @($Catalog | Where-Object Level -eq 1).Count | Should -Be 9
        @($Catalog | Where-Object Level -eq 2).Count | Should -Be 7
        @($Catalog | Where-Object Level -eq 3).Count | Should -Be 5
    }

    It 'every action has an Apply scriptblock' {
        foreach ($action in $Catalog) { $action.Apply | Should -BeOfType [scriptblock] -Because $action.Id }
    }

    It 'every reversible action has a Revert scriptblock' {
        foreach ($action in ($Catalog | Where-Object { $_.Reversible })) { $action.Revert | Should -BeOfType [scriptblock] -Because $action.Id }
    }

    It 'only cleanup, maintenance and app removal are marked as not reversible' {
        foreach ($action in ($Catalog | Where-Object { -not $_.Reversible })) {
            $action.Category | Should -BeIn @('Cleanup', 'Maintenance', 'Bloatware') -Because $action.Id
            $action.Revert | Should -BeNullOrEmpty -Because $action.Id
        }
    }

    It 'file cleanups and bloatware removal are marked as not reversible' {
        foreach ($action in ($Catalog | Where-Object { $_.Category -in @('Cleanup', 'Bloatware') })) {
            $action.Reversible | Should -BeFalse -Because $action.Id
        }
    }

    It 'registry entries are complete' {
        foreach ($action in ($Catalog | Where-Object { $_.Registry })) {
            foreach ($entry in $action.Registry) {
                $entry.Path | Should -Match '^HK(CU|LM):\\' -Because $action.Id
                $entry.Name | Should -Not -BeNullOrEmpty -Because $action.Id
                $null -ne $entry.Value | Should -BeTrue -Because "$($action.Id) $($entry.Name)"
            }
        }
    }

    It 'startup, bloatware and Ultimate Performance are interactive (the user chooses)' {
        foreach ($id in @('StartupApps', 'Bloatware', 'UltimatePerformance')) {
            ($Catalog | Where-Object Id -eq $id).Interactive | Should -BeTrue -Because $id
        }
    }

    It 'every interactive action asks in a Prepare step (before restore point and backup)' {
        foreach ($action in ($Catalog | Where-Object { $_.Interactive })) { $action.Prepare | Should -BeOfType [scriptblock] -Because $action.Id }
        foreach ($action in ($Catalog | Where-Object { -not $_.Interactive })) { $action.Prepare | Should -BeNullOrEmpty -Because $action.Id }
    }
}

Describe 'Red lines' {
    It 'no registry value touches Defender, Firewall, SmartScreen, UAC, Windows Update, page file, mitigations or boot' {
        $forbidden = 'Windows Defender', 'Defender', 'Firewall', 'SharedAccess', 'SmartScreen', 'CurrentVersion\Policies\System',
                     'EnableLUA', 'WindowsUpdate', 'Memory Management', 'PagingFiles', 'FeatureSettingsOverride', 'BCD0',
                     'SecurityHealth', 'Services\'
        foreach ($action in ($Catalog | Where-Object { $_.Registry })) {
            foreach ($entry in $action.Registry) {
                foreach ($fragment in $forbidden) {
                    ('{0}\{1}' -f $entry.Path, $entry.Name) | Should -Not -BeLike "*$fragment*" -Because $action.Id
                }
            }
        }
    }

    It 'the code contains no forbidden commands (downloads, Invoke-Expression, Defender, firewall, BCD, drivers, ResetBase)' {
        $forbidden = 'Invoke-Expression', '\biex\b', 'Invoke-WebRequest', 'Invoke-RestMethod', 'WebClient', 'Start-BitsTransfer',
                     'DownloadString', 'DownloadFile', 'Set-MpPreference', 'Add-MpPreference', 'DisableAntiSpyware', 'netsh',
                     'NetFirewall', 'bcdedit', 'ResetBase', 'pnputil', 'Remove-WindowsDriver', 'EnableLUA', 'ConsentPrompt',
                     'FeatureSettingsOverride', 'PagingFiles', 'pagefile', 'WinSxS', 'SmartScreen', 'FromBase64String', 'EncodedCommand'
        foreach ($pattern in $forbidden) { $CodeText | Should -Not -Match $pattern -Because $pattern }
    }

    It 'only the allowed services can be set to Manual, and none is critical' {
        $script:ManualServices | Should -Be @('Fax', 'MapsBroker', 'RetailDemo', 'WMPNetworkSvc', 'XblAuthManager', 'XblGameSave', 'XboxNetApiSvc')
        $critical = 'WinDefend', 'WdNisSvc', 'mpssvc', 'BFE', 'wuauserv', 'UsoSvc', 'WaaSMedicSvc', 'BITS', 'wscsvc',
                    'SecurityHealthService', 'Sense', 'EventLog', 'DiagTrack', 'Dnscache', 'CryptSvc', 'TrustedInstaller'
        foreach ($service in $critical) { $script:ManualServices | Should -Not -Contain $service }
    }

    It 'Set-Service is never used to disable a service' {
        foreach ($command in (Get-TestCommandAst -Name @('Set-Service'))) {
            $command.Extent.Text | Should -Not -Match 'Disabled'
            $command.Extent.Text | Should -Match '-StartupType (Manual|\$Entry\.StartType)'
            $command.Extent.Text | Should -Not -Match 'wuauserv'
        }
        $CodeText | Should -Not -Match "start=\S*\s*,?\s*'disabled'"
    }

    It 'Set-CardonServiceManual refuses services outside the allowed list' {
        { Set-CardonServiceManual -ActionId 'Test' -Name 'WinDefend' } | Should -Throw
    }

    It 'registry values and keys are only removed by the restore function' {
        foreach ($command in (Get-TestCommandAst -Name @('Remove-ItemProperty', 'Remove-Item'))) {
            Get-TestParentFunctionName -Node $command | Should -Be 'Restore-CardonRegistryEntry'
            $command.Extent.Text | Should -Not -Match '-Recurse'
        }
    }

    It 'the bloatware catalog contains no protected package' {
        foreach ($app in $script:BloatwareCatalog) {
            Test-CardonProtectedPackage -Package $app.Package | Should -BeFalse -Because $app.Package
        }
    }

    It 'Store, Edge, Calculator, Photos, Camera, Notepad, Paint, Terminal, App Installer, Security and runtimes are protected' {
        $essential = 'Microsoft.WindowsStore', 'Microsoft.MicrosoftEdge.Stable', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos',
                     'Microsoft.WindowsCamera', 'Microsoft.WindowsNotepad', 'Microsoft.Paint', 'Microsoft.WindowsTerminal',
                     'Microsoft.DesktopAppInstaller', 'Microsoft.SecHealthUI', 'Microsoft.VCLibs.140.00', 'Microsoft.NET.Native.Framework.2.2',
                     'Microsoft.UI.Xaml.2.8'
        foreach ($package in $essential) { Test-CardonProtectedPackage -Package $package | Should -BeTrue -Because $package }
    }

    It 'Remove-CardonAppPackage refuses protected and non-listed packages' {
        Mock Remove-AppxPackage { }
        { Remove-CardonAppPackage -Package ([pscustomobject]@{ Name = 'Microsoft.WindowsStore'; PackageFullName = 'x' }) } | Should -Throw
        { Remove-CardonAppPackage -Package ([pscustomobject]@{ Name = 'Contoso.SomeApp'; PackageFullName = 'x' }) } | Should -Throw
        Should -Invoke Remove-AppxPackage -Times 0 -Exactly
    }

    It 'Microsoft scheduled tasks can never be disabled' {
        Mock Disable-ScheduledTask { }
        { Disable-CardonScheduledTask -ActionId 'Test' -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' } | Should -Throw
        Should -Invoke Disable-ScheduledTask -Times 0 -Exactly
    }
}

Describe 'Helpers' {
    It 'ConvertTo-CardonSelection parses lists and ranges' {
        (ConvertTo-CardonSelection -InputText '1,3, 5-7' -Maximum 9).Items | Should -Be @(1, 3, 5, 6, 7)
        (ConvertTo-CardonSelection -InputText '2 2 1' -Maximum 3).Items | Should -Be @(1, 2)
        (ConvertTo-CardonSelection -InputText '' -Maximum 3).Items.Count | Should -Be 0
        (ConvertTo-CardonSelection -InputText '0' -Maximum 3).Valid | Should -BeTrue
        (ConvertTo-CardonSelection -InputText '0' -Maximum 3).Cancelled | Should -BeTrue
        (ConvertTo-CardonSelection -InputText '' -Maximum 3).Cancelled | Should -BeFalse
        (ConvertTo-CardonSelection -InputText '4' -Maximum 3).Valid | Should -BeFalse
        (ConvertTo-CardonSelection -InputText 'abc' -Maximum 3).Valid | Should -BeFalse
        (ConvertTo-CardonSelection -InputText '3-1' -Maximum 3).Valid | Should -BeFalse
    }

    It 'Get-CardonCombinedStatus reduces sub-step statuses' {
        Get-CardonCombinedStatus -Statuses @('Unchanged', 'Changed') | Should -Be 'Changed'
        Get-CardonCombinedStatus -Statuses @('Unchanged', 'Preview') | Should -Be 'Preview'
        Get-CardonCombinedStatus -Statuses @('Unchanged', 'Skipped') | Should -Be 'Skipped'
        Get-CardonCombinedStatus -Statuses @() | Should -Be 'Unchanged'
    }

    It 'Test-CardonValueEqual compares numbers, strings and byte arrays' {
        Test-CardonValueEqual -Current 0 -Desired 0 | Should -BeTrue
        Test-CardonValueEqual -Current '2' -Desired '2' | Should -BeTrue
        Test-CardonValueEqual -Current 1 -Desired 0 | Should -BeFalse
        Test-CardonValueEqual -Current ([byte[]](3, 0)) -Desired ([byte[]](3, 0)) | Should -BeTrue
        Test-CardonValueEqual -Current ([byte[]](2, 0)) -Desired ([byte[]](3, 0)) | Should -BeFalse
    }

    It 'Format-CardonSize uses readable units' {
        Format-CardonSize -Bytes 500 | Should -Be '500 B'
        Format-CardonSize -Bytes 2048 | Should -Be '2 KB'
    }

    It 'protects antivirus, audio, video and touchpad startup entries' {
        $protected = @(
            @('SecurityHealthSystray', 'C:\Windows\System32\SecurityHealthSystray.exe'),
            @('RtkAudUService', 'C:\Windows\System32\RtkAudUService64.exe'),
            @('NvBackend', 'C:\Program Files\NVIDIA Corporation\Update Core\NvBackend.exe'),
            @('AMD Software', 'C:\Program Files\AMD\CNext\CNext\RadeonSoftware.exe'),
            @('SynTPEnh', 'C:\Program Files\Synaptics\SynTP\SynTPEnh.exe'),
            @('ETDCtrl', 'C:\Program Files\Elantech\ETDCtrl.exe'),
            @('AvastUI.exe', 'C:\Program Files\Avast Software\Avast\AvLaunch.exe'),
            @('ESET', 'C:\Program Files\ESET\ESET Security\ecmds.exe')
        )
        foreach ($item in $protected) { Test-CardonProtectedStartupItem -Name $item[0] -Command $item[1] | Should -BeTrue -Because $item[0] }
    }

    It 'offers ordinary startup programs' {
        $ordinary = @(
            @('Spotify', 'C:\Users\u\AppData\Roaming\Spotify\Spotify.exe /minimized'),
            @('Discord', 'C:\Users\u\AppData\Local\Discord\Update.exe --processStart Discord.exe'),
            @('Steam', 'C:\Program Files (x86)\Steam\steam.exe -silent'),
            @('Adobe Creative Cloud', 'C:\Program Files\Adobe\Adobe Creative Cloud\ACC\Creative Cloud.exe'),
            @('ResetHelper', 'C:\Tools\reset-helper.exe')
        )
        foreach ($item in $ordinary) { Test-CardonProtectedStartupItem -Name $item[0] -Command $item[1] | Should -BeFalse -Because $item[0] }
    }
}

Describe 'Clear-CardonDirectory (inside TestDrive only)' {
    BeforeEach {
        $target = Join-Path $TestDrive 'clean'
        $outside = Join-Path $TestDrive 'outside'
        New-Item -ItemType Directory -Path (Join-Path $target 'sub'), $outside -Force | Out-Null
        $old = (Get-Date).AddDays(-3)
        foreach ($path in @((Join-Path $target 'old.tmp'), (Join-Path $target 'sub\old2.tmp'), (Join-Path $outside 'keep.txt'))) {
            Set-Content -LiteralPath $path -Value 'data'
            (Get-Item -LiteralPath $path).LastWriteTime = $old
        }
        Set-Content -LiteralPath (Join-Path $target 'recent.tmp') -Value 'data'
        # A junction pointing outside the folder: it must never be followed.
        New-Item -ItemType Junction -Path (Join-Path $target 'link') -Target $outside | Out-Null
    }

    AfterEach {
        $script:DryRun = $false
        $link = Join-Path $TestDrive 'clean\link'
        if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
        Remove-Item -LiteralPath (Join-Path $TestDrive 'clean'), (Join-Path $TestDrive 'outside') -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'in DryRun only measures and deletes nothing' {
        $script:DryRun = $true
        $result = Clear-CardonDirectory -Path $target -OlderThanHours 24 -RemoveEmptyFolders
        $result.Files | Should -Be 2
        Join-Path $target 'old.tmp' | Should -Exist
        Join-Path $target 'sub\old2.tmp' | Should -Exist
    }

    It 'deletes old files, keeps recent ones and never follows junctions' {
        $script:DryRun = $false
        $result = Clear-CardonDirectory -Path $target -OlderThanHours 24 -RemoveEmptyFolders
        $result.Files | Should -Be 2
        Join-Path $target 'old.tmp' | Should -Not -Exist
        Join-Path $target 'sub\old2.tmp' | Should -Not -Exist
        Join-Path $target 'recent.tmp' | Should -Exist
        Join-Path $outside 'keep.txt' | Should -Exist
        $target | Should -Exist
    }
}

Describe 'Backup safety (mocked, nothing is written)' {
    BeforeEach {
        $script:DryRun = $false
        Mock New-Item { }
        Mock New-ItemProperty { }
        Mock Save-CardonBackup { }
        Mock Get-CardonRegistryValue { @{ KeyExists = $true; Exists = $true; Value = 1; Type = 'DWord' } }
        Mock Get-CardonMissingKeyRoot { $null }
    }

    AfterEach {
        $script:Backup = $null
    }

    It 'refuses to change anything when there is no backup session' {
        $script:Backup = $null
        { Set-CardonRegistryValue -ActionId 'Test' -Path 'HKCU:\Software\CardonTest' -Name 'Value' -Value 0 } | Should -Throw
        Should -Invoke New-ItemProperty -Times 0 -Exactly
    }

    It 'never writes when the backup could not be saved (backup happens first)' {
        Mock Add-CardonBackupEntry { throw 'disk full' }
        { Set-CardonRegistryValue -ActionId 'Test' -Path 'HKCU:\Software\CardonTest' -Name 'Value' -Value 0 } | Should -Throw
        Should -Invoke New-ItemProperty -Times 0 -Exactly
    }

    It 'backs up the previous value and then writes the new one' {
        Mock Add-CardonBackupEntry { }
        Set-CardonRegistryValue -ActionId 'Test' -Path 'HKCU:\Software\CardonTest' -Name 'Value' -Value 0 | Should -Be 'Changed'
        Should -Invoke Add-CardonBackupEntry -Times 1 -Exactly -ParameterFilter { $Entry.Existed -and $Entry.Value -eq 1 -and $Entry.Type -eq 'DWord' }
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter { $Value -eq 0 }
    }

    It 'is idempotent: nothing happens when the value is already set' {
        Mock Add-CardonBackupEntry { }
        Set-CardonRegistryValue -ActionId 'Test' -Path 'HKCU:\Software\CardonTest' -Name 'Value' -Value 1 | Should -Be 'Unchanged'
        Should -Invoke Add-CardonBackupEntry -Times 0 -Exactly
        Should -Invoke New-ItemProperty -Times 0 -Exactly
    }

    It 'keeps only the original state when the same value changes twice' {
        $script:Backup = [ordered]@{ Entries = New-Object System.Collections.ArrayList }
        Add-CardonBackupEntry -Entry @{ Kind = 'Registry'; Key = 'REG|A|B'; Value = 1 }
        Add-CardonBackupEntry -Entry @{ Kind = 'Registry'; Key = 'REG|A|B'; Value = 0 }
        $script:Backup.Entries.Count | Should -Be 1
        $script:Backup.Entries[0].Value | Should -Be 1
    }

    It 'undo removes a value that did not exist before' {
        Mock Remove-ItemProperty { }
        Mock Get-Item { $null }
        Restore-CardonRegistryEntry -Entry ([pscustomobject]@{ Path = 'HKCU:\Software\CardonTest'; Name = 'Value'; Existed = $false; CreatedKey = $null })
        Should -Invoke Remove-ItemProperty -Times 1 -Exactly
    }

    It 'undo restores binary values (startup entries) with their original bytes' {
        Mock Test-Path { $true }
        Restore-CardonRegistryEntry -Entry ([pscustomobject]@{ Path = 'HKCU:\Software\CardonTest'; Name = 'App'; Existed = $true; Type = 'Binary'; Value = @(2, 0, 0) })
        Should -Invoke New-ItemProperty -Times 1 -Exactly -ParameterFilter { $Value -is [byte[]] -and $Value[0] -eq 2 -and $PropertyType -eq 'Binary' }
    }

    It 'undo re-enables scheduled tasks that were disabled' {
        Mock Enable-ScheduledTask { }
        Restore-CardonEntry -Entry ([pscustomobject]@{ Kind = 'ScheduledTask'; TaskPath = '\'; TaskName = 'SomeUpdater' })
        Should -Invoke Enable-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskPath -eq '\' -and $TaskName -eq 'SomeUpdater' }
    }

    It 'undo uses the Revert function of the action that made the change' {
        Mock Restore-CardonEntry { }
        Mock Set-Content { }
        Mock Show-CardonText { }
        $data = [pscustomobject]@{ Entries = @(
            [pscustomobject]@{ Kind = 'ScheduledTask'; ActionId = 'StartupApps'; TaskPath = '\'; TaskName = 'A' }
            [pscustomobject]@{ Kind = 'Registry'; ActionId = 'GameDvr'; Path = 'HKCU:\X'; Name = 'Y'; Existed = $false }
        ) }
        $result = Restore-CardonBackup -BackupItem ([pscustomobject]@{ Data = $data; File = 'unused.json' })
        $result.Ok | Should -Be 2
        Should -Invoke Restore-CardonEntry -Times 2 -Exactly
    }
}

Describe 'Preview mode changes nothing (no administrator rights needed)' {
    BeforeAll {
        # Every command that could change the system fails loudly if it is ever called.
        $script:MutatingCommands = @(
            'New-Item', 'New-ItemProperty', 'Set-ItemProperty', 'Remove-Item', 'Remove-ItemProperty', 'Set-Service', 'Stop-Service',
            'Start-Service', 'Remove-AppxPackage', 'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Optimize-Volume',
            'Checkpoint-Computer', 'Enable-ComputerRestore', 'Clear-RecycleBin', 'Start-Process', 'Set-Content', 'Add-Content',
            'Invoke-CimMethod'
        )
        foreach ($name in $script:MutatingCommands) { Mock -CommandName $name -MockWith { throw 'A state-changing command was called in preview mode.' } }
        Mock Read-Host { throw 'The preview must not ask anything.' }
        Mock Write-Host { }
        # powercfg may only be called to read (/list, /getactivescheme); ipconfig, dism and sc never.
        # Reads get a fake answer (a default mock is needed: Pester 6 does not fall back to the real command).
        Mock Invoke-CardonNative -MockWith { [pscustomobject]@{ ExitCode = 0; Output = 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (Balanced) *' } }
        Mock Invoke-CardonNative -ParameterFilter { @('/list', '/getactivescheme') -notcontains $ArgumentList[0] } -MockWith { throw 'Native command called in preview mode.' }
    }

    It 'runs the full Extreme level as preview without errors, prompts, backups or changes' {
        { Invoke-CardonLevel -Level 3 -Preview } | Should -Not -Throw
        $script:Stats.Errors | Should -Be 0
        ($script:Stats.Previewed + $script:Stats.Skipped) | Should -Be 21
        $script:Stats.Changed | Should -Be 0
        $script:Backup | Should -BeNullOrEmpty
        $script:DryRun | Should -BeFalse
        foreach ($name in $script:MutatingCommands) { Should -Invoke -CommandName $name -Times 0 -Exactly }
        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke Invoke-CardonNative -Times 0 -Exactly -ParameterFilter { @('/list', '/getactivescheme') -notcontains $ArgumentList[0] }
    }
}

Describe 'Device type (desktop / notebook)' {
    BeforeEach {
        $script:DryRun = $false
        $script:Plan = @{}
        Mock Write-Host { }
        Mock Read-Host { throw 'Unexpected prompt.' }
    }

    AfterEach {
        $script:SessionDeviceType = $null
        $script:DryRun = $false
    }

    It 'without a choice, the device type is guessed from the battery' {
        $script:SessionDeviceType = $null
        Mock Test-CardonBattery { $true }
        Get-CardonDeviceType | Should -Be 'Notebook'
        Mock Test-CardonBattery { $false }
        Get-CardonDeviceType | Should -Be 'Desktop'
    }

    It 'level 1 uses High performance on desktops and Balanced on notebooks' {
        Mock Get-CardonActivePowerScheme { '00000000-0000-0000-0000-000000000000' }
        Mock Test-CardonPowerScheme { $true }
        Mock Test-CardonBattery { $false }
        Mock Set-CardonPowerScheme { 'Changed' }
        $action = $Catalog | Where-Object Id -eq 'PowerPlan'

        $script:SessionDeviceType = 'Desktop'
        [void](Invoke-CardonPowerPlan -Action $action)
        Should -Invoke Set-CardonPowerScheme -Times 1 -Exactly -ParameterFilter { $Guid -eq $script:PowerSchemes.HighPerformance }

        $script:SessionDeviceType = 'Notebook'
        [void](Invoke-CardonPowerPlan -Action $action)
        Should -Invoke Set-CardonPowerScheme -Times 1 -Exactly -ParameterFilter { $Guid -eq $script:PowerSchemes.Balanced }
    }

    It 'on notebooks an active High performance plan goes back to Balanced' {
        Mock Get-CardonActivePowerScheme { $script:PowerSchemes.HighPerformance }
        Mock Test-CardonBattery { $true }
        Mock Set-CardonPowerScheme { 'Changed' }
        $script:SessionDeviceType = 'Notebook'
        [void](Invoke-CardonPowerPlan -Action ($Catalog | Where-Object Id -eq 'PowerPlan'))
        Should -Invoke Set-CardonPowerScheme -Times 1 -Exactly -ParameterFilter { $Guid -eq $script:PowerSchemes.Balanced }
    }

    It 'the battery warning only appears when High performance is activated on a computer with a battery' {
        Mock Get-CardonActivePowerScheme { $script:PowerSchemes.Balanced }
        Mock Test-CardonPowerScheme { $true }
        Mock Set-CardonPowerScheme { 'Changed' }
        Mock Show-CardonText { }
        $action = $Catalog | Where-Object Id -eq 'PowerPlan'

        Mock Test-CardonBattery { $true }
        $script:SessionDeviceType = 'Notebook'
        [void](Invoke-CardonPowerPlan -Action $action)
        Should -Invoke Show-CardonText -Times 0 -Exactly -ParameterFilter { $Key -eq 'Warn_BatteryHighPerformance' }

        Mock Test-CardonBattery { $false }
        $script:SessionDeviceType = 'Desktop'
        [void](Invoke-CardonPowerPlan -Action $action)
        Should -Invoke Show-CardonText -Times 0 -Exactly -ParameterFilter { $Key -eq 'Warn_BatteryHighPerformance' }

        Mock Test-CardonBattery { $true }
        [void](Invoke-CardonPowerPlan -Action $action)
        Should -Invoke Show-CardonText -Times 1 -Exactly -ParameterFilter { $Key -eq 'Warn_BatteryHighPerformance' }
    }

    It 'Ultimate Performance is never offered or applied on notebooks' {
        Mock Get-CardonActivePowerScheme { $script:PowerSchemes.Balanced }
        Mock New-CardonUltimatePowerScheme { 'x' }
        Mock Set-CardonPowerScheme { 'Changed' }
        $action = $Catalog | Where-Object Id -eq 'UltimatePerformance'
        $script:SessionDeviceType = 'Notebook'

        Request-CardonUltimateChoice -Action $action | Should -BeTrue
        $script:Plan['UltimatePerformance'] | Should -BeFalse
        (Invoke-CardonUltimatePerformance -Action $action).Status | Should -Be 'Skipped'
        $script:DryRun = $true
        (Invoke-CardonUltimatePerformance -Action $action).Status | Should -Be 'Skipped'

        Should -Invoke Read-Host -Times 0 -Exactly
        Should -Invoke New-CardonUltimatePowerScheme -Times 0 -Exactly
        Should -Invoke Set-CardonPowerScheme -Times 0 -Exactly
    }

    It 'Ultimate Performance is offered on desktops and only applied after a yes' {
        Mock Get-CardonActivePowerScheme { $script:PowerSchemes.HighPerformance }
        Mock Test-CardonBattery { $false }
        Mock Read-Host { 'N' }
        Mock Set-CardonPowerScheme { 'Changed' }
        $action = $Catalog | Where-Object Id -eq 'UltimatePerformance'
        $script:SessionDeviceType = 'Desktop'

        Request-CardonUltimateChoice -Action $action | Should -BeTrue
        Should -Invoke Read-Host -Times 1 -Exactly
        (Invoke-CardonUltimatePerformance -Action $action).Status | Should -Be 'Skipped'
        Should -Invoke Set-CardonPowerScheme -Times 0 -Exactly
    }

    It 'the device screen stores the choice and warns softly on a mismatch' {
        Mock Test-CardonBattery { $false }
        Mock Show-CardonText { }
        Mock Read-Host { '2' }
        Select-CardonDeviceType | Should -BeTrue
        $script:SessionDeviceType | Should -Be 'Notebook'
        Should -Invoke Show-CardonText -Times 1 -Exactly -ParameterFilter { $Key -eq 'Device_MismatchNotebook' }
    }
}

Describe 'Back navigation: 0 returns to the menu without restore points or backups' {
    BeforeAll {
        function Use-TestAnswer {
            param([string[]]$Answer)
            $script:TestAnswers = New-Object System.Collections.Queue
            foreach ($item in $Answer) { $script:TestAnswers.Enqueue($item) }
        }
    }

    BeforeEach {
        $script:SessionDeviceType = 'Desktop'
        $script:DryRun = $false
        Mock Write-Host { }
        Mock Read-Host { $script:TestAnswers.Dequeue() }
        Mock New-CardonRestorePoint { $true }
        Mock New-CardonBackupSession { }
        Mock Invoke-CardonCheckpoint { }
        Mock Invoke-CardonAction { }
        Mock Test-CardonAdministrator { $true }
        Mock Test-CardonBattery { $false }
        Mock Get-CardonOsInfo { [pscustomobject]@{ Caption = 'Windows 11 Pro'; Build = 26100; Edition = 'Professional'; IsWindows11 = $true; IsSupported = $true } }
        Mock Get-CardonActivePowerScheme { $script:PowerSchemes.HighPerformance }
        Mock Get-CardonStartupItem {
            @(
                [pscustomobject]@{ Type = 'Registry'; Name = 'Spotify'; Command = 'spotify.exe'; Source = 'Source_RegistryUser'; ApprovedPath = 'HKCU:\X'; Protected = $false }
                [pscustomobject]@{ Type = 'Registry'; Name = 'Steam'; Command = 'steam.exe'; Source = 'Source_RegistryUser'; ApprovedPath = 'HKCU:\X'; Protected = $false }
            )
        }
        Mock Get-AppxPackage { $null }
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Clipchamp.Clipchamp'; PackageFullName = 'Clipchamp.Clipchamp_1' } } -ParameterFilter { $Name -eq 'Clipchamp.Clipchamp' }
    }

    AfterEach {
        $script:SessionDeviceType = $null
        $script:Plan = @{}
    }

    It 'answering <_> to the level confirmation returns to the menu (all levels)' -ForEach @('0', 'N') {
        foreach ($level in 1..3) {
            Use-TestAnswer -Answer @($_)
            Invoke-CardonLevel -Level $level
        }
        Should -Invoke New-CardonRestorePoint -Times 0 -Exactly
        Should -Invoke New-CardonBackupSession -Times 0 -Exactly
        Should -Invoke Invoke-CardonAction -Times 0 -Exactly
    }

    It '0 in the startup list, then not continuing, changes nothing' {
        Use-TestAnswer -Answer @('Y', '0', 'N')
        Invoke-CardonLevel -Level 2
        $script:TestAnswers.Count | Should -Be 0
        Should -Invoke New-CardonRestorePoint -Times 0 -Exactly
        Should -Invoke New-CardonBackupSession -Times 0 -Exactly
        Should -Invoke Invoke-CardonAction -Times 0 -Exactly
    }

    It '0 in the app list, then 0 again (back), changes nothing' {
        Use-TestAnswer -Answer @('Y', '', '0', '0')
        Invoke-CardonLevel -Level 3
        $script:TestAnswers.Count | Should -Be 0
        Should -Invoke New-CardonRestorePoint -Times 0 -Exactly
        Should -Invoke New-CardonBackupSession -Times 0 -Exactly
        Should -Invoke Invoke-CardonAction -Times 0 -Exactly
    }

    It '0 in a list and then continuing applies the level but nothing from that list' {
        Use-TestAnswer -Answer @('Y', '0', 'Y')
        Invoke-CardonLevel -Level 2
        @($script:Plan['StartupApps']).Count | Should -Be 0
        Should -Invoke New-CardonRestorePoint -Times 1 -Exactly
        Should -Invoke Invoke-CardonAction -Times 16 -Exactly
    }

    It 'all questions are asked before the restore point; notebooks are not asked about Ultimate' {
        $script:SessionDeviceType = 'Notebook'
        Mock New-CardonRestorePoint { $false }   # stop right after the questions
        Use-TestAnswer -Answer @('Y', '', '')
        Invoke-CardonLevel -Level 3
        Should -Invoke Read-Host -Times 3 -Exactly
        Should -Invoke New-CardonBackupSession -Times 0 -Exactly
    }

    It 'preview: 0 when choosing the level goes back without running anything' {
        Mock Invoke-CardonLevel { }
        Use-TestAnswer -Answer @('0')
        Invoke-CardonMenuChoice -Choice '4' | Should -BeTrue
        Should -Invoke Invoke-CardonLevel -Times 0 -Exactly
    }

    It 'undo: 0 in the backup list goes back without restoring' {
        Mock Get-CardonBackupList { @([pscustomobject]@{ Path = 'x'; File = 'x'; Data = $null; Created = '2026-11-03T10:00:00'; Level = 1; Count = 3; Restored = $false }) }
        Mock Restore-CardonBackup { }
        Use-TestAnswer -Answer @('0')
        Invoke-CardonMenuChoice -Choice '5' | Should -BeTrue
        Should -Invoke Restore-CardonBackup -Times 0 -Exactly
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'log: Enter or 0 goes back to the menu' {
        Mock Show-CardonLog { }
        Use-TestAnswer -Answer @('0')
        Invoke-CardonMenuChoice -Choice '6' | Should -BeTrue
        Should -Invoke Read-Host -Times 1 -Exactly
    }

    It 'language: 0 goes back without changing the language' {
        Use-TestAnswer -Answer @('0')
        Invoke-CardonMenuChoice -Choice '7' | Should -BeTrue
        $script:LanguageCode | Should -Be 'en'
    }

    It 'device type: 0 goes back without changing the device type' {
        Use-TestAnswer -Answer @('0')
        Invoke-CardonMenuChoice -Choice '8' | Should -BeTrue
        $script:SessionDeviceType | Should -Be 'Desktop'
    }

    It 'only 0 in the main menu exits' {
        Invoke-CardonMenuChoice -Choice '0' | Should -BeFalse
        Should -Invoke New-CardonRestorePoint -Times 0 -Exactly
        Should -Invoke New-CardonBackupSession -Times 0 -Exactly
    }
}
