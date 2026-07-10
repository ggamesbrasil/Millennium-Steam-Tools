#requires -Version 5.1
<#
.SYNOPSIS
    Millennium Steam Tools -- unified installer for Millennium, SteamTools and LuaTools.

.DESCRIPTION
    Interactive menu by default. Pass switches to run non-interactively:

.PARAMETER Millennium
    Install Millennium only (official GUI installer).

.PARAMETER SteamTools
    Install SteamTools only (official one-liner: irm steam.run | iex).

.PARAMETER LuaTools
    Install LuaTools using the official one-liner. Also installs/updates
    SteamTools + Millennium, as upstream's script does.

.PARAMETER LuaToolsPluginOnly
    Install just the LuaTools plugin. Requires Millennium + SteamTools to
    already be installed -- it will NOT install them for you.

.PARAMETER All
    Install everything: Millennium, then SteamTools, then the LuaTools
    plugin (via -LuaToolsPluginOnly, so SteamTools isn't reinstalled twice).

.PARAMETER Uninstall
    Jump straight to the uninstall menu.

.PARAMETER Yes
    Assume "yes" on every confirmation prompt (unattended mode).

.PARAMETER NoElevate
    Don't try to relaunch elevated even if not running as Administrator.

.EXAMPLE
    .\install.ps1
    Interactive menu.

.EXAMPLE
    .\install.ps1 -All -Yes
    Install everything, unattended.

.EXAMPLE
    .\install.ps1 -LuaToolsPluginOnly
    Install just the LuaTools plugin (fails fast if Millennium/SteamTools are missing).
#>

[CmdletBinding()]
param(
    [switch]$Millennium,
    [switch]$SteamTools,
    [switch]$LuaTools,
    [switch]$LuaToolsPluginOnly,
    [switch]$All,
    [switch]$Uninstall,
    [switch]$Yes,
    [switch]$NoElevate
)

$Global:AssumeYes = $Yes.IsPresent

. (Join-Path $PSScriptRoot 'modules\Common.ps1')
. (Join-Path $PSScriptRoot 'modules\Millennium.ps1')
. (Join-Path $PSScriptRoot 'modules\SteamTools.ps1')
. (Join-Path $PSScriptRoot 'modules\LuaTools.ps1')

Initialize-Logging

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
if (-not $NoElevate) {
    if (-not (Test-IsAdministrator)) {
        $relaunchArgs = @()
        if ($Millennium) { $relaunchArgs += '-Millennium' }
        if ($SteamTools) { $relaunchArgs += '-SteamTools' }
        if ($LuaTools) { $relaunchArgs += '-LuaTools' }
        if ($LuaToolsPluginOnly) { $relaunchArgs += '-LuaToolsPluginOnly' }
        if ($All) { $relaunchArgs += '-All' }
        if ($Uninstall) { $relaunchArgs += '-Uninstall' }
        if ($Yes) { $relaunchArgs += '-Yes' }

        $elevationResult = Request-Elevation -ScriptPath $PSCommandPath -OriginalArgs $relaunchArgs
        if ($null -eq $elevationResult) { exit }        # a new elevated process was spawned
        if ($elevationResult -eq $false) { exit 1 }      # user declined
    }
} elseif (-not (Test-IsAdministrator)) {
    Write-Warn2 'Running without Administrator rights (-NoElevate). Some operations may fail.'
}

Write-Banner

# ---------------------------------------------------------------------------
# Install All -- CLEAN reinstall of everything from scratch: Millennium, then
# SteamTools, then the plugin (not the official LuaTools one-liner, to avoid
# reinstalling SteamTools twice).
#
# "Clean" means every tool is reinstalled even if it's already present -- each
# step runs its installer again and the LuaTools plugin folder is wiped and
# redeployed fresh, as if starting from zero.
#
# Sequential gating: each step must verify as installed before the next one
# runs. If any step fails or can't be confirmed, the chain stops immediately
# so we never try to install the LuaTools plugin onto a missing Millennium.
# ---------------------------------------------------------------------------
function Invoke-InstallAll {
    Write-SectionHeader 'Install All (clean reinstall)'
    Write-Info2 'Reinstalling everything from scratch: Millennium -> SteamTools -> LuaTools Plugin.'
    Write-Info2 'All three are reinstalled even if already present. Each step must succeed before the next starts.'

    if (-not (Invoke-GatedStep -Label 'Step 1/3 -- Millennium' -Action { Install-Millennium -Clean } -VerifyFunction 'Test-MillenniumInstalled')) {
        Write-Rule
        Write-Err2 'Install All stopped at step 1 (Millennium). Fix the issue above and try again.'
        return
    }
    # Millennium's installer launches Steam when it finishes -- wait for that
    # delayed launch and close it before touching Steam files again.
    Assert-SteamClosed -SettleSeconds 10 -Force | Out-Null

    if (-not (Invoke-GatedStep -Label 'Step 2/3 -- SteamTools' -Action { Install-SteamTools -Clean } -VerifyFunction 'Test-SteamToolsInstalled')) {
        Write-Rule
        Write-Err2 'Install All stopped at step 2 (SteamTools). Millennium is installed; re-run to continue.'
        return
    }
    # The SteamTools installer can also start Steam -- settle and close again.
    Assert-SteamClosed -SettleSeconds 8 -Force | Out-Null

    if (-not (Invoke-GatedStep -Label 'Step 3/3 -- LuaTools Plugin' -Action { Install-LuaToolsPlugin -Clean } -VerifyFunction 'Test-LuaToolsInstalled')) {
        Write-Rule
        Write-Err2 'Install All stopped at step 3 (LuaTools plugin). Millennium + SteamTools are installed.'
        return
    }

    Write-Rule
    Write-Ok 'Install All finished -- Millennium, SteamTools and the LuaTools plugin were all reinstalled cleanly.'
}

# ---------------------------------------------------------------------------
# Non-interactive dispatch
# ---------------------------------------------------------------------------
$hasSwitchAction = $Millennium -or $SteamTools -or $LuaTools -or $LuaToolsPluginOnly -or $All -or $Uninstall

if ($hasSwitchAction) {
    if ($Uninstall) {
        & (Join-Path $PSScriptRoot 'uninstall.ps1') -Yes:$Yes -NoElevate
        exit
    }
    if ($All) {
        Invoke-InstallAll
        exit
    }
    if ($Millennium) { Invoke-SafeAction -Label 'Millennium' -Action { Install-Millennium } | Out-Null }
    if ($SteamTools) { Invoke-SafeAction -Label 'SteamTools' -Action { Install-SteamTools } | Out-Null }
    if ($LuaTools) { Invoke-SafeAction -Label 'LuaTools (Official)' -Action { Install-LuaTools } | Out-Null }
    if ($LuaToolsPluginOnly) { Invoke-SafeAction -Label 'LuaTools Plugin Only' -Action { Install-LuaToolsPlugin } | Out-Null }
    exit
}

# ---------------------------------------------------------------------------
# Interactive menu loop
# ---------------------------------------------------------------------------
$exitRequested = $false
do {
    Clear-Host
    Write-Banner
    $steamPath = Get-SteamPath
    Show-SteamPathLine -SteamPath $steamPath
    $tools = Get-ToolRegistry

    $items = @(
        @{ Number = 1; Label = 'Install Millennium'; Status = (Get-ToolStatusLabel $tools[0]) }
        @{ Number = 2; Label = 'Install SteamTools'; Status = (Get-ToolStatusLabel $tools[1]) }
        @{ Number = 3; Label = 'Install LuaTools (Official, full)'; Status = (Get-ToolStatusLabel $tools[2]); SubLabel = 'Also installs/updates SteamTools + Millennium' }
        @{ Number = 4; Label = 'Install LuaTools Plugin Only'; Status = (Get-ToolStatusLabel $tools[3]); SubLabel = 'Requires Millennium + SteamTools already installed' }
        @{ Number = 5; Label = 'Install All (clean reinstall)'; Status = $null; SubLabel = 'Reinstall everything from scratch, even if already installed' }
        @{ Number = 6; Label = 'Uninstall menu'; Status = $null }
        @{ Number = 0; Label = 'Exit'; Status = $null }
    )
    $choice = Show-Menu -Items $items -Prompt 'Choose an option'
    Write-ToLog -Line "Menu choice: '$choice'" -Level INFO

    switch ($choice) {
        '1' { Invoke-SafeAction -Label 'Millennium' -Action { Install-Millennium } | Out-Null; Wait-KeyPress }
        '2' { Invoke-SafeAction -Label 'SteamTools' -Action { Install-SteamTools } | Out-Null; Wait-KeyPress }
        '3' { Invoke-SafeAction -Label 'LuaTools (Official)' -Action { Install-LuaTools } | Out-Null; Wait-KeyPress }
        '4' { Invoke-SafeAction -Label 'LuaTools Plugin Only' -Action { Install-LuaToolsPlugin } | Out-Null; Wait-KeyPress }
        '5' { Invoke-InstallAll; Wait-KeyPress }
        '6' { & (Join-Path $PSScriptRoot 'uninstall.ps1') }
        '0' { $exitRequested = $true }
        default { Write-Warn2 "Unknown option: '$choice'"; Wait-KeyPress }
    }
} while (-not $exitRequested)

Write-Host ''
Write-Info2 "Log saved to: $(Get-LogPath)"
Write-Ok 'Goodbye!'
