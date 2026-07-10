#requires -Version 5.1
<#
    SteamTools.ps1
    Installs SteamTools with two methods, tried in order:

      1. The official one-liner (irm steam.run | iex). We fetch it first and
         sanity-check the response, because steam.run can return an HTML error
         page (e.g. a 404) -- piping that straight into iex fails with a
         cryptic "'<' is not recognized as a name of a cmdlet" error.

      2. Fallback: download the SteamTools package (ost.zip) from GitHub and
         extract it into the Steam root. This is the exact package the official
         LuaTools installer uses, so it's reliable even when steam.run is down.

    Uninstall has no official counterpart, so it's a best-effort cleanup of
    the marker files SteamTools drops at the Steam root, with a backup taken
    first (see modules/Common.ps1 -> Backup-Item2).
#>

$Script:SteamToolsInstallUrl = 'https://steam.run'
# Same package the official LuaTools installer downloads for SteamTools.
$Script:SteamToolsPackageUrl = 'https://github.com/madoiscool/lt_api_links/releases/download/ost-148/ost.zip'
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
    param([switch]$Clean)

    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry. Is Steam installed?' }

    if (Test-SteamToolsInstalled) {
        if ($Clean) {
            Write-Info2 'SteamTools already installed -- clean reinstall requested, running the installer again.'
        } else {
            Write-Ok 'SteamTools is already installed.'
            if (-not (Confirm-Step -Message 'Run the installer anyway (repair/update)?')) { return }
        }
    }

    if (-not (Assert-SteamClosed -Force:$Clean)) {
        throw 'Steam must be closed to continue.'
    }

    # Method 1: the official one-liner, with a sanity check on the response.
    $installedOfficial = $false
    Write-Step "Trying the official SteamTools installer ($Script:SteamToolsInstallUrl)..."
    try {
        $scriptContent = Invoke-RestMethod -Uri $Script:SteamToolsInstallUrl -TimeoutSec 30
        $text = [string]$scriptContent
        if ([string]::IsNullOrWhiteSpace($text) -or $text.TrimStart().StartsWith('<')) {
            Write-Warn2 'steam.run did not return an installer script (it looks like an HTML/error page).'
        } else {
            Invoke-Expression $text
            if (Test-SteamToolsInstalled) { $installedOfficial = $true }
        }
    } catch {
        Write-Warn2 "Official installer unavailable: $($_.Exception.Message)"
    }

    # Method 2: fall back to the GitHub package if the official route failed.
    if (-not $installedOfficial) {
        Write-Info2 'Falling back to the GitHub SteamTools package...'
        Install-SteamToolsFromPackage -SteamPath $steamPath
    }

    if (Test-SteamToolsInstalled) {
        Write-Ok 'SteamTools installed successfully.'
    } else {
        throw 'SteamTools could not be installed by either method. Check your internet connection (or a possible ISP block) and try again.'
    }
}

# ---------------------------------------------------------------------------
# Fallback installer: download and extract the SteamTools package (ost.zip)
# into the Steam root, mirroring what the official LuaTools installer does.
# ---------------------------------------------------------------------------
function Install-SteamToolsFromPackage {
    param([string]$SteamPath)

    $zipFile = Join-Path $env:TEMP 'steamtools_ost.zip'
    Write-Step 'Downloading the SteamTools package from GitHub...'
    try {
        Invoke-WebRequest -Uri $Script:SteamToolsPackageUrl -OutFile $zipFile -UseBasicParsing -TimeoutSec 90
    } catch {
        throw "Failed to download the SteamTools package: $($_.Exception.Message)"
    }
    if (-not (Test-Path $zipFile)) { throw 'Failed to download the SteamTools package (file missing after download).' }

    # Steam must be fully closed before overwriting its DLLs.
    Stop-SteamProcesses

    Write-Step 'Extracting SteamTools into the Steam folder...'
    Expand-Archive -LiteralPath $zipFile -DestinationPath $SteamPath -Force
    Remove-Item -LiteralPath $zipFile -Force -ErrorAction SilentlyContinue

    # The package ships a steam.cfg that pins the client version; move it aside
    # (matches the official LuaTools installer, which runs the lua backend).
    $steamCfg = Join-Path $SteamPath 'steam.cfg'
    $steamCfgBak = Join-Path $SteamPath 'steam.cfg.bak'
    if (Test-Path -LiteralPath $steamCfg) {
        Move-Item -LiteralPath $steamCfg -Destination $steamCfgBak -Force -ErrorAction SilentlyContinue
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
