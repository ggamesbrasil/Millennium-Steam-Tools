#requires -Version 5.1
<#
    LuaTools.ps1
    Two install paths, both exposed as separate menu entries:

    - Install-LuaTools        : the official one-liner
                                 (irm https://luatools.vercel.app/install-plugin.ps1 | iex).
                                 This is upstream's script; it also (re)installs/updates
                                 SteamTools + Millennium on its own, by design.

    - Install-LuaToolsPlugin  : OUR OWN reimplementation of just the plugin
                                 deployment step, ported from the official script
                                 (functions Install-Plugin / Enable-Plugin in
                                 install-plugin.ps1). It only DETECTS whether
                                 Millennium + SteamTools are present -- it never
                                 installs them. If either is missing it stops and
                                 tells the user which menu option to run first.
#>

Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$Script:LuaToolsOfficialInstallUrl = 'https://luatools.vercel.app/install-plugin.ps1'
$Script:LuaToolsPluginName = 'luatools'
$Script:LuaToolsPluginDownloadUrl = 'https://github.com/piqseu/ltsteamplugin/releases/latest/download/ltsteamplugin.zip'

# ---------------------------------------------------------------------------
# Detection
# ---------------------------------------------------------------------------
function Find-LuaToolsPluginDir {
    param([string]$SteamPath)
    if (-not $SteamPath) { return $null }

    $pluginsDir = Join-Path $SteamPath 'millennium\plugins'
    $legacyDir = Join-Path $SteamPath 'plugins'
    $scanDirs = @($pluginsDir, $legacyDir) | Where-Object { Test-Path $_ } | Select-Object -Unique

    foreach ($scanDir in $scanDirs) {
        foreach ($dir in (Get-ChildItem $scanDir -Directory -ErrorAction SilentlyContinue)) {
            $j = Join-Path $dir.FullName 'plugin.json'
            if (Test-Path $j) {
                try {
                    $m = Get-Content $j -Raw -Encoding UTF8 | ConvertFrom-Json
                    if ($m.name -eq $Script:LuaToolsPluginName) { return $dir.FullName }
                } catch {}
            }
        }
    }
    return $null
}

function Test-LuaToolsInstalled {
    $steamPath = Get-SteamPath
    return [bool](Find-LuaToolsPluginDir -SteamPath $steamPath)
}

# ---------------------------------------------------------------------------
# Official, full install (delegates entirely to upstream)
# ---------------------------------------------------------------------------
function Install-LuaTools {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry. Is Steam installed?' }

    Write-Info2 'This runs the official LuaTools installer. It also installs/updates SteamTools and Millennium as part of its own flow.'
    if (Test-LuaToolsInstalled) {
        Write-Ok 'The LuaTools plugin is already installed.'
        if (-not (Confirm-Step -Message 'Run the official installer anyway (repair/update everything)?')) { return }
    }

    Write-Step "Running the official LuaTools installer ($Script:LuaToolsOfficialInstallUrl)..."
    try {
        $scriptContent = Invoke-RestMethod -Uri $Script:LuaToolsOfficialInstallUrl -TimeoutSec 30
        Invoke-Expression $scriptContent
    } catch {
        throw "The official LuaTools installer failed: $($_.Exception.Message)"
    }

    if (Test-LuaToolsInstalled) {
        Write-Ok 'LuaTools installed successfully (SteamTools + Millennium + plugin).'
    } else {
        Write-Warn2 'Could not confirm the LuaTools plugin on disk after running the installer. Check the console output above for details.'
    }
}

# ---------------------------------------------------------------------------
# Plugin-only install (our own reimplementation, no forced reinstall of the
# other two tools -- only prerequisite detection)
# ---------------------------------------------------------------------------
function Install-LuaToolsPlugin {
    param([switch]$Clean)

    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry. Is Steam installed?' }

    $missing = @()
    if (-not (Test-MillenniumInstalled)) { $missing += 'Millennium (menu option 1)' }
    if (-not (Test-SteamToolsInstalled)) { $missing += 'SteamTools (menu option 2)' }
    if ($missing.Count -gt 0) {
        Write-Err2 'The LuaTools plugin needs Millennium and SteamTools already installed. Missing:'
        foreach ($m in $missing) { Write-Host "     - $m" -ForegroundColor $Palette.Err }
        Write-Info2 'Install the missing tool(s) first, then run this option again.'
        return
    }

    if (-not (Assert-SteamClosed -Force:$Clean)) {
        throw 'Steam must be closed to continue.'
    }

    $millDir = Join-Path $steamPath 'millennium'
    if (-not (Test-Path $millDir)) { New-Item -Path $millDir -ItemType Directory -Force | Out-Null }
    $pluginsDir = Join-Path $millDir 'plugins'
    if (-not (Test-Path $pluginsDir)) { New-Item -Path $pluginsDir -ItemType Directory -Force | Out-Null }

    $existing = Find-LuaToolsPluginDir -SteamPath $steamPath
    $targetDir = Join-Path $pluginsDir $Script:LuaToolsPluginName
    if ($existing) {
        if ($Clean) {
            # Clean reinstall: wipe the existing plugin folder so extraction
            # produces a pristine copy instead of merging over old files.
            Write-Step 'Existing LuaTools plugin found -- removing it for a clean reinstall.'
            Remove-Item -Path $existing -Recurse -Force -ErrorAction SilentlyContinue
            $targetDir = Join-Path $pluginsDir $Script:LuaToolsPluginName
        } else {
            Write-Step 'Existing LuaTools plugin found -- updating in place.'
            $targetDir = $existing
        }
    }

    $zipPath = Join-Path $env:TEMP "$($Script:LuaToolsPluginName).zip"
    Write-Step "Downloading the LuaTools plugin..."
    try {
        Invoke-WebRequest -Uri $Script:LuaToolsPluginDownloadUrl -OutFile $zipPath -UseBasicParsing -TimeoutSec 60
    } catch {
        throw "Failed to download the LuaTools plugin: $($_.Exception.Message)"
    }
    if (-not (Test-Path $zipPath)) { throw 'Failed to download the LuaTools plugin (file missing after download).' }

    Write-Step 'Extracting the plugin...'
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
                $dest = Join-Path $targetDir $entry.FullName
                $parentDir = Split-Path $dest -Parent
                if (-not (Test-Path $parentDir)) { New-Item -Path $parentDir -ItemType Directory -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $dest, $true)
            }
        } finally {
            $zip.Dispose()
        }
    } catch {
        Write-Warn2 'Direct extraction failed, falling back to Expand-Archive.'
        Expand-Archive -Path $zipPath -DestinationPath $targetDir -Force
    }
    Remove-Item -Path $zipPath -Force -ErrorAction SilentlyContinue

    Enable-LuaToolsPlugin -SteamPath $steamPath

    if (Test-LuaToolsInstalled) {
        Write-Ok 'LuaTools plugin installed successfully.'
    } else {
        Write-Warn2 'Could not confirm the plugin on disk after extraction.'
    }

    if (Confirm-Step -Message 'Start Steam now?' -DefaultYes) {
        Start-SteamProcess -SteamPath $steamPath -ClearBeta
    }
}

function Enable-LuaToolsPlugin {
    param([string]$SteamPath)

    $configDir = Join-Path $SteamPath 'millennium\config'
    $configPath = Join-Path $configDir 'config.json'

    if (-not (Test-Path $configPath)) {
        New-Item -Path $configDir -ItemType Directory -Force | Out-Null
        $config = @{ plugins = @{ enabledPlugins = @($Script:LuaToolsPluginName) } }
        $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
        Write-Ok 'Plugin enabled in a new config.json.'
        return
    }

    $config = (Get-Content $configPath -Raw -Encoding UTF8) | ConvertFrom-Json
    if (-not $config.plugins) {
        $config | Add-Member -MemberType NoteProperty -Name 'plugins' -Value ([pscustomobject]@{ enabledPlugins = @() }) -Force
    }
    if (-not $config.plugins.enabledPlugins) {
        $config.plugins | Add-Member -MemberType NoteProperty -Name 'enabledPlugins' -Value @() -Force
    }

    $pluginsList = @($config.plugins.enabledPlugins)
    if ($pluginsList -notcontains $Script:LuaToolsPluginName) {
        $pluginsList += $Script:LuaToolsPluginName
        $config.plugins.enabledPlugins = $pluginsList
        $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
    }
    Write-Ok 'Plugin enabled in config.json.'
}

# ---------------------------------------------------------------------------
# Uninstall (covers plugins from either install path -- there's only one on
# disk regardless of which option installed it)
# ---------------------------------------------------------------------------
function Uninstall-LuaTools {
    $steamPath = Get-SteamPath
    if (-not $steamPath) { throw 'Steam installation not found in the registry.' }

    $pluginDir = Find-LuaToolsPluginDir -SteamPath $steamPath
    if (-not $pluginDir) {
        Write-Info2 'The LuaTools plugin does not appear to be installed. Nothing to do.'
        return
    }

    if (-not (Confirm-Step -Message "Remove the LuaTools plugin from $pluginDir ?" -DefaultYes)) {
        Write-Info2 'Cancelled.'
        return
    }

    $backupRoot = New-BackupFolder -SteamPath $steamPath -Label 'LuaToolsPlugin'
    Write-Step "Backing up the plugin folder to $backupRoot"
    Backup-Item2 -Path $pluginDir -BackupRoot $backupRoot | Out-Null
    Remove-Item -Path $pluginDir -Recurse -Force -ErrorAction SilentlyContinue

    $configPath = Join-Path $steamPath 'millennium\config\config.json'
    if (Test-Path $configPath) {
        try {
            $config = (Get-Content $configPath -Raw -Encoding UTF8) | ConvertFrom-Json
            if ($config.plugins -and $config.plugins.enabledPlugins) {
                $config.plugins.enabledPlugins = @($config.plugins.enabledPlugins | Where-Object { $_ -ne $Script:LuaToolsPluginName })
                $config | ConvertTo-Json -Depth 10 | Set-Content $configPath -Encoding UTF8
            }
        } catch {
            Write-Warn2 "Could not update config.json automatically: $($_.Exception.Message)"
        }
    }

    if (-not (Test-LuaToolsInstalled)) {
        Write-Ok "LuaTools plugin removed. A backup was kept at $backupRoot"
    } else {
        Write-Warn2 'The plugin folder could not be fully removed. It may be in use -- try again after closing Steam.'
    }
}
