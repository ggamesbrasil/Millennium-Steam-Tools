#requires -Version 5.1
<#
.SYNOPSIS
    Millennium Steam Tools -- uninstall menu.

.DESCRIPTION
    Millennium is removed via its own official installer UI (it ships a
    proper uninstall option). SteamTools and the LuaTools plugin have no
    official uninstaller, so removal is best-effort: known files are backed
    up to %TEMP%\MillenniumSteamTools\backups\ before being deleted.

.PARAMETER Millennium
.PARAMETER SteamTools
.PARAMETER LuaTools
.PARAMETER All
.PARAMETER Yes
    Assume "yes" on every confirmation prompt (unattended mode).
.PARAMETER NoElevate
    Don't try to relaunch elevated even if not running as Administrator.
#>

[CmdletBinding()]
param(
    [switch]$Millennium,
    [switch]$SteamTools,
    [switch]$LuaTools,
    [switch]$All,
    [switch]$Yes,
    [switch]$NoElevate
)

$Global:AssumeYes = $Yes.IsPresent

. (Join-Path $PSScriptRoot 'modules\Common.ps1')
. (Join-Path $PSScriptRoot 'modules\Millennium.ps1')
. (Join-Path $PSScriptRoot 'modules\SteamTools.ps1')
. (Join-Path $PSScriptRoot 'modules\LuaTools.ps1')

Initialize-Logging

if (-not $NoElevate) {
    if (-not (Test-IsAdministrator)) {
        $relaunchArgs = @('-Uninstall')
        if ($Millennium) { $relaunchArgs += '-Millennium' }
        if ($SteamTools) { $relaunchArgs += '-SteamTools' }
        if ($LuaTools) { $relaunchArgs += '-LuaTools' }
        if ($All) { $relaunchArgs += '-All' }
        if ($Yes) { $relaunchArgs += '-Yes' }

        $elevationResult = Request-Elevation -ScriptPath $PSCommandPath -OriginalArgs $relaunchArgs
        if ($null -eq $elevationResult) { exit }
        if ($elevationResult -eq $false) { exit 1 }
    }
} elseif (-not (Test-IsAdministrator)) {
    Write-Warn2 'Running without Administrator rights (-NoElevate). Some operations may fail.'
}

function Invoke-UninstallAll {
    Write-SectionHeader 'Uninstall All'
    Invoke-SafeAction -Label 'Step 1/3 -- LuaTools Plugin' -Action { Uninstall-LuaTools } | Out-Null
    Invoke-SafeAction -Label 'Step 2/3 -- SteamTools' -Action { Uninstall-SteamTools } | Out-Null
    Invoke-SafeAction -Label 'Step 3/3 -- Millennium' -Action { Uninstall-Millennium } | Out-Null
    Write-Rule
    Write-Ok 'Uninstall All finished.'
}

$hasSwitchAction = $Millennium -or $SteamTools -or $LuaTools -or $All

if ($hasSwitchAction) {
    if ($All) {
        Invoke-UninstallAll
        exit
    }
    if ($LuaTools) { Invoke-SafeAction -Label 'LuaTools Plugin' -Action { Uninstall-LuaTools } | Out-Null }
    if ($SteamTools) { Invoke-SafeAction -Label 'SteamTools' -Action { Uninstall-SteamTools } | Out-Null }
    if ($Millennium) { Invoke-SafeAction -Label 'Millennium' -Action { Uninstall-Millennium } | Out-Null }
    exit
}

$exitRequested = $false
do {
    Clear-Host
    Write-Banner
    $steamPath = Get-SteamPath
    Show-SteamPathLine -SteamPath $steamPath
    $tools = Get-ToolRegistry

    Write-Host ''
    Write-Host ' UNINSTALL MENU' -ForegroundColor $Palette.Accent
    Write-Warn2 'SteamTools and the LuaTools plugin have no official uninstaller -- removal is best-effort and backed up first.'

    $items = @(
        @{ Number = 1; Label = 'Uninstall Millennium'; Status = (Get-ToolStatusLabel $tools[0]) }
        @{ Number = 2; Label = 'Uninstall SteamTools'; Status = (Get-ToolStatusLabel $tools[1]); SubLabel = 'Best-effort' }
        @{ Number = 3; Label = 'Uninstall LuaTools Plugin'; Status = (Get-ToolStatusLabel $tools[3]); SubLabel = 'Best-effort' }
        @{ Number = 4; Label = 'Uninstall All'; Status = $null }
        @{ Number = 0; Label = 'Back'; Status = $null }
    )
    $choice = Show-Menu -Items $items -Prompt 'Choose an option'
    Write-ToLog -Line "Uninstall menu choice: '$choice'" -Level INFO

    switch ($choice) {
        '1' { Invoke-SafeAction -Label 'Millennium' -Action { Uninstall-Millennium } | Out-Null; Wait-KeyPress }
        '2' { Invoke-SafeAction -Label 'SteamTools' -Action { Uninstall-SteamTools } | Out-Null; Wait-KeyPress }
        '3' { Invoke-SafeAction -Label 'LuaTools Plugin' -Action { Uninstall-LuaTools } | Out-Null; Wait-KeyPress }
        '4' { Invoke-UninstallAll; Wait-KeyPress }
        '0' { $exitRequested = $true }
        default { Write-Warn2 "Unknown option: '$choice'"; Wait-KeyPress }
    }
} while (-not $exitRequested)

Write-Host ''
Write-Info2 "Log saved to: $(Get-LogPath)"
