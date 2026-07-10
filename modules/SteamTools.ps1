#requires -Version 5.1
<#
    SteamTools.ps1
    Installs SteamTools via the official one-liner (irm steam.run | iex).
    We deliberately do NOT reimplement its internals -- it's a moving target
    maintained upstream, and reimplementing it would go stale. This module
    just wraps the official command with our own UX/logging/error handling.

    Uninstall has no official counterpart, so it's a best-effort cleanup of
    the marker files SteamTools drops at the Steam root, with a backup taken
    first (see modules/Common.ps1 -> Backup-Item2).
#>

$Script:SteamToolsInstallUrl = 'https://steam.run'
$Script:SteamToolsMarkerFiles = @('dwmapi.dll', 'xinput1_4.dll')

function Test-SteamToolsInstalled {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { return $false }
    foreach ($f in $Script:SteamToolsMarkerFiles) {
        if (Test-Path -LiteralPath (Join-Path $steamPath $f)) { return $true }
    }
    return $false
}

function Install-SteamTools {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry. Is Steam installed?' }

    if (Test-SteamToolsInstalled) {
        Write-Ok 'SteamTools is already installed.'
        if (-not (Confirm-Step -Message 'Run the installer anyway (repair/update)?')) { return }
    }

    if (Test-SteamRunning) {
        Write-Warn2 'Steam is running. The official installer will close it automatically if needed.'
        if (-not (Confirm-Step -Message 'Continue?' -DefaultYes)) { throw 'Cancelled by user.' }
    }

    Write-Step "Running the official SteamTools installer ($Script:SteamToolsInstallUrl)..."
    try {
        $scriptContent = Invoke-RestMethod -Uri $Script:SteamToolsInstallUrl -TimeoutSec 30
        Invoke-Expression $scriptContent
    } catch {
        throw "The official SteamTools installer failed: $($_.Exception.Message)"
    }

    if (Test-SteamToolsInstalled) {
        Write-Ok 'SteamTools installed successfully.'
    } else {
        Write-Warn2 'Could not confirm SteamTools files on disk after running the installer. Check the console output above for details.'
    }
}

function Uninstall-SteamTools {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry.' }

    if (-not (Test-SteamToolsInstalled)) {
        Write-Info2 'SteamTools does not appear to be installed. Nothing to do.'
        return
    }

    Write-Warn2 'SteamTools has no official uninstaller -- this removes the known files it drops at the Steam root (best-effort).'
    if (-not (Confirm-Step -Message 'A backup will be made first. Continue?' -DefaultYes)) {
        Write-Info2 'Cancelled.'
        return
    }

    if (Test-SteamRunning) { Stop-SteamProcesses; Write-Ok 'Steam closed.' }

    $backupRoot = New-BackupFolder -SteamPath $steamPath -Label 'SteamTools'
    Write-Step "Backing up affected files to $backupRoot"

    foreach ($f in $Script:SteamToolsMarkerFiles) {
        $full = Join-Path $steamPath $f
        if (Test-Path -LiteralPath $full) {
            Backup-Item2 -Path $full -BackupRoot $backupRoot | Out-Null
            Remove-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue
        }
    }

    # SteamTools' installer backs up the original steam.cfg to steam.cfg.bak
    # before dropping its own. Restore it if present.
    $cfgBak = Join-Path $steamPath 'steam.cfg.bak'
    $cfg = Join-Path $steamPath 'steam.cfg'
    if (Test-Path -LiteralPath $cfgBak) {
        Backup-Item2 -Path $cfg -BackupRoot $backupRoot | Out-Null
        Move-Item -LiteralPath $cfgBak -Destination $cfg -Force -ErrorAction SilentlyContinue
        Write-Info2 'Restored the original steam.cfg from backup.'
    }

    if (-not (Test-SteamToolsInstalled)) {
        Write-Ok "SteamTools files removed. A backup was kept at $backupRoot"
    } else {
        Write-Warn2 'Some SteamTools files could not be removed. They may be in use -- try again after closing Steam completely.'
    }
}
