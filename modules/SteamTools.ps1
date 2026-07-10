#requires -Version 5.1
<#
    SteamTools.ps1
    Installs the official SteamTools (https://www.steamtools.net) -- the real
    product, NOT OpenSteamTool.

    SteamTools ships as an NSIS "Download Setup" installer:
      - Latest version is discovered by scraping the site (the setup filename
        is baked into the site's JS bundle, e.g. st-setup-1.8.30.exe), with a
        known-good URL as a fallback, so we always get the current release
        without hardcoding a version.
      - Because it's NSIS, it installs silently with "/S" (no GUI to babysit)
        and registers a proper Windows uninstaller.

    Detection and uninstall both go through the Windows uninstall registry:
      DisplayName "SteamTools", InstallLocation "C:\Program Files\SteamTools",
      QuietUninstallString "...\Uninstall.exe /S".

    steamtools.net sits behind Cloudflare, which blocks Invoke-WebRequest, so
    downloads/scraping use the curl-based helpers in Common.ps1.
#>

$Script:SteamToolsSiteRoot        = 'https://www.steamtools.net'
$Script:SteamToolsDownloadPage    = 'https://www.steamtools.net/'
$Script:SteamToolsResBase         = 'https://www.steamtools.net/res/'
# Known-good fallback if scraping the current version ever fails.
$Script:SteamToolsFallbackSetup   = 'https://www.steamtools.net/res/st-setup-1.8.30.exe'

# ---------------------------------------------------------------------------
# Detection (Windows uninstall registry)
# ---------------------------------------------------------------------------
function Get-SteamToolsUninstallEntry {
    $hives = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    return Get-ItemProperty $hives -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -match 'steam\s*tools?' } |
        Select-Object -First 1
}

function Test-SteamToolsInstalled {
    return [bool](Get-SteamToolsUninstallEntry)
}

# ---------------------------------------------------------------------------
# Resolve the latest setup URL (scrape, with fallback)
# ---------------------------------------------------------------------------
function Get-SteamToolsSetupUrl {
    try {
        $html = Invoke-HttpText -Url $Script:SteamToolsDownloadPage -TimeoutSec 25
        if ($html) {
            $bundle = [regex]::Match($html, '/assets/index-[A-Za-z0-9_-]+\.js').Value
            if ($bundle) {
                $js = Invoke-HttpText -Url ($Script:SteamToolsSiteRoot + $bundle) -TimeoutSec 25
                if ($js) {
                    $m = [regex]::Match($js, 'st-setup-\d+\.\d+\.\d+\.exe')
                    if ($m.Success) { return ($Script:SteamToolsResBase + $m.Value) }
                }
            }
        }
    } catch {
        Write-ToLog -Line "SteamTools version discovery failed: $($_.Exception.Message)" -Level WARN
    }
    Write-Warn2 'Could not detect the latest version -- using the known-good fallback.'
    return $Script:SteamToolsFallbackSetup
}

# ---------------------------------------------------------------------------
# Install (silent NSIS setup)
# ---------------------------------------------------------------------------
function Install-SteamTools {
    param([switch]$Clean)

    if (Test-SteamToolsInstalled) {
        if ($Clean) {
            Write-Info2 'SteamTools already installed -- clean reinstall requested, running the setup again.'
        } else {
            Write-Ok 'SteamTools is already installed.'
            if (-not (Confirm-Step -Message 'Run the setup again (repair/update)?')) { return }
        }
    }

    $setupUrl = Get-SteamToolsSetupUrl
    Write-Step "Latest SteamTools setup: $setupUrl"

    $setupPath = Join-Path $env:TEMP 'st-setup.exe'
    Write-Step 'Downloading the official SteamTools setup...'
    if (-not (Invoke-Download -Url $setupUrl -OutFile $setupPath -TimeoutSec 180)) {
        throw 'Failed to download the SteamTools setup from steamtools.net (Cloudflare block or network issue).'
    }

    Write-Step 'Installing SteamTools silently (/S)...'
    $proc = Start-Process -FilePath $setupPath -ArgumentList '/S' -Wait -PassThru
    Remove-Item $setupPath -Force -ErrorAction SilentlyContinue

    # The NSIS installer writes its registry entry as it finishes -- give it a
    # short window before deciding whether detection succeeded.
    $ok = $false
    for ($i = 0; $i -lt 12; $i++) {
        if (Test-SteamToolsInstalled) { $ok = $true; break }
        Start-Sleep -Milliseconds 500
    }

    if ($ok) {
        Write-Ok 'SteamTools installed successfully.'
    } else {
        Write-Warn2 "SteamTools setup finished (exit code $($proc.ExitCode)) but could not be confirmed in the registry."
    }
}

# ---------------------------------------------------------------------------
# Uninstall (official registered uninstaller, silent)
# ---------------------------------------------------------------------------
function Uninstall-SteamTools {
    $entry = Get-SteamToolsUninstallEntry
    if (-not $entry) {
        Write-Info2 'SteamTools does not appear to be installed. Nothing to do.'
        return
    }

    if ($entry.InstallLocation) { Write-Info2 "Found SteamTools at: $($entry.InstallLocation)" }
    if (-not (Confirm-Step -Message 'Uninstall SteamTools now (official uninstaller)?' -DefaultYes)) {
        Write-Info2 'Cancelled.'
        return
    }

    if (Test-SteamRunning) { Assert-SteamClosed -Force | Out-Null }

    # Prefer the silent uninstall command the installer registered.
    $silent = $true
    $cmd = $entry.QuietUninstallString
    if (-not $cmd) { $cmd = $entry.UninstallString; $silent = $false }
    if (-not $cmd) { throw 'No uninstall command is registered for SteamTools.' }

    # Split the registered command into an executable + arguments.
    $exe = $null
    $arguments = ''
    if ($cmd -match '^\s*"([^"]+)"\s*(.*)$') {
        $exe = $Matches[1]; $arguments = $Matches[2].Trim()
    } elseif ($cmd -match '^\s*(\S+\.exe)\s*(.*)$') {
        $exe = $Matches[1]; $arguments = $Matches[2].Trim()
    } else {
        $exe = $cmd
    }
    if ($silent -and $arguments -notmatch '/S') { $arguments = ("$arguments /S").Trim() }

    Write-Step 'Running the official SteamTools uninstaller...'
    if ($arguments) {
        Start-Process -FilePath $exe -ArgumentList $arguments -Wait
    } else {
        Start-Process -FilePath $exe -Wait
    }

    # NSIS uninstallers relaunch themselves from a temp copy, so -Wait can
    # return before removal finishes. Poll the registry for a few seconds.
    $gone = $false
    for ($i = 0; $i -lt 16; $i++) {
        if (-not (Test-SteamToolsInstalled)) { $gone = $true; break }
        Start-Sleep -Milliseconds 500
    }

    if ($gone) {
        Write-Ok 'SteamTools uninstalled successfully.'
    } else {
        Write-Warn2 'SteamTools still appears installed. The uninstaller may still be running -- re-check in a moment.'
    }
}
