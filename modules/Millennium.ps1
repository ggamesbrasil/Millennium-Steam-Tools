#requires -Version 5.1
<#
    Millennium.ps1
    Installs/uninstalls Millennium via the official GUI installer:
    https://github.com/SteamClientHomebrew/Installer

    The installer is a self-contained wizard that already handles install,
    repair and removal -- we just fetch it and hand off to it.
#>

$Script:MillenniumInstallerUrl = 'https://github.com/SteamClientHomebrew/Installer/releases/latest/download/MillenniumInstaller-Windows.exe'

function Test-MillenniumInstalled {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { return $false }
    # wsock32.dll is the proxy DLL dropped at the Steam root by both the
    # legacy (millennium.dll / python311.dll) and current Millennium layouts.
    foreach ($f in @('wsock32.dll', 'millennium.dll', 'python311.dll')) {
        if (Test-Path -LiteralPath (Join-Path $steamPath $f)) { return $true }
    }
    return $false
}

function Get-MillenniumInstallerPath {
    $dest = Join-Path $env:TEMP 'MillenniumInstaller-Windows.exe'
    Write-Step 'Downloading the official Millennium installer...'
    Invoke-WebRequest -Uri $Script:MillenniumInstallerUrl -OutFile $dest -UseBasicParsing -TimeoutSec 60
    if (-not (Test-Path $dest)) { throw 'Could not download MillenniumInstaller-Windows.exe.' }
    return $dest
}

function Install-Millennium {
    param([switch]$Clean)

    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry. Is Steam installed?' }

    if (Test-MillenniumInstalled) {
        if ($Clean) {
            Write-Info2 'Millennium already installed -- clean reinstall requested, running the installer again.'
        } else {
            Write-Ok 'Millennium is already installed.'
            if (-not (Confirm-Step -Message 'Run the installer anyway (repair/update)?')) { return }
        }
    }

    if (-not (Assert-SteamClosed -Force:$Clean)) {
        throw 'Steam must be closed to continue.'
    }

    $installerPath = Get-MillenniumInstallerPath
    Write-Step 'Launching the Millennium installer window...'
    Write-Warn2 'IMPORTANT: complete the wizard, then CLOSE the installer window to continue here.'
    Write-Warn2 'The installer opens Steam when it finishes -- that is normal. You still need to'
    Write-Warn2 'close the INSTALLER window (it may be hidden behind Steam) for this script to resume.'
    Start-Process -FilePath $installerPath -Wait
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    # The installer may still be flushing files for a moment after its window
    # closes; give detection a few tries before deciding.
    $detected = $false
    for ($i = 0; $i -lt 6; $i++) {
        if (Test-MillenniumInstalled) { $detected = $true; break }
        Start-Sleep -Milliseconds 500
    }

    if ($detected) {
        Write-Ok 'Millennium installed successfully.'
    } else {
        Write-Warn2 'Could not confirm Millennium files on disk -- if the wizard reported success, this is likely a detection quirk, not a real failure.'
    }
}

function Uninstall-Millennium {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry.' }

    if (-not (Test-MillenniumInstalled)) {
        Write-Info2 'Millennium does not appear to be installed. Nothing to do.'
        return
    }

    Write-Info2 'Millennium ships its own official uninstaller UI.'
    if (-not (Confirm-Step -Message 'Launch the Millennium installer to remove it now?' -DefaultYes)) {
        Write-Info2 'Skipped. You can re-run this option any time.'
        return
    }

    if (Test-SteamRunning) {
        Write-Warn2 'Steam is running and must be closed before uninstalling.'
        Stop-SteamProcesses
        Write-Ok 'Steam closed.'
    }

    $installerPath = Get-MillenniumInstallerPath
    Write-Step 'Launching the installer -- choose "Uninstall" / "Remove" in the wizard.'
    Start-Process -FilePath $installerPath -Wait
    Remove-Item -Path $installerPath -Force -ErrorAction SilentlyContinue

    if (-not (Test-MillenniumInstalled)) {
        Write-Ok 'Millennium removed successfully.'
    } else {
        Write-Warn2 'Millennium files are still present. If you chose "Uninstall" in the wizard and still see this, a manual check may be needed.'
    }
}
