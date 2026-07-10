#requires -Version 5.1
<#
    Common.ps1
    Shared UI, logging, elevation, and Steam-detection helpers used by every
    module and by install.ps1 / uninstall.ps1. Dot-source this file first.
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$Script:ProgressPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ---------------------------------------------------------------------------
# Palette
# ---------------------------------------------------------------------------
$Script:Palette = @{
    Border  = 'Cyan'
    Title   = 'White'
    Accent  = 'Magenta'
    Muted   = 'DarkGray'
    Ok      = 'Green'
    Warn    = 'Yellow'
    Err     = 'Red'
    Info    = 'Cyan'
}

# ---------------------------------------------------------------------------
# Logging (console + file)
#
# Lightweight file logger: one timestamped log per run under
# %TEMP%\MillenniumSteamTools\. Every status line, section header, menu
# choice and caught exception is appended, so a failed run leaves a full
# trail without needing a heavyweight PowerShell transcript.
# ---------------------------------------------------------------------------
$Script:LogFile = $null

function Initialize-Logging {
    $logDir = Join-Path $env:TEMP 'MillenniumSteamTools'
    if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $Script:LogFile = Join-Path $logDir "run-$stamp.log"

    $header = @(
        "==============================================================",
        " Millennium Steam Tools -- run log",
        " Started : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
        " User    : $env:USERNAME",
        " Admin   : $(Test-IsAdministrator)",
        " PS      : $($PSVersionTable.PSVersion)",
        " OS      : $([System.Environment]::OSVersion.VersionString)",
        "=============================================================="
    )
    $header | Out-File -FilePath $Script:LogFile -Encoding UTF8
}

function Get-LogPath { return $Script:LogFile }

function Write-ToLog {
    param(
        [string]$Line,
        [ValidateSet('INFO', 'STEP', 'OK', 'WARN', 'ERR', 'EXCEPTION')]
        [string]$Level = 'INFO'
    )
    if (-not $Script:LogFile) { return }
    try {
        "[{0}] [{1,-5}] {2}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Line |
            Out-File -FilePath $Script:LogFile -Append -Encoding UTF8
    } catch {
        # Never let a logging failure abort the actual work.
    }
}

function Write-Status {
    param(
        [ValidateSet('Step', 'Ok', 'Warn', 'Err', 'Info')]
        [string]$Type,
        [string]$Message
    )
    # ASCII-only tags -- some console fonts don't render Unicode icons/emoji,
    # so they'd show as empty boxes. Plain tags render everywhere.
    $tags = @{ Step = '[>]'; Ok = '[OK]'; Warn = '[!]'; Err = '[X]'; Info = '[i]' }
    $colors = @{ Step = 'White'; Ok = $Palette.Ok; Warn = $Palette.Warn; Err = $Palette.Err; Info = $Palette.Info }

    Write-Host (" {0,-4} " -f $tags[$Type]) -ForegroundColor $colors[$Type] -NoNewline
    Write-Host $Message -ForegroundColor $colors[$Type]

    $levelMap = @{ Step = 'STEP'; Ok = 'OK'; Warn = 'WARN'; Err = 'ERR'; Info = 'INFO' }
    Write-ToLog -Line $Message -Level $levelMap[$Type]
}

function Write-Step { param([string]$Message) Write-Status -Type Step -Message $Message }
function Write-Ok   { param([string]$Message) Write-Status -Type Ok   -Message $Message }
function Write-Warn2 { param([string]$Message) Write-Status -Type Warn -Message $Message }
function Write-Err2  { param([string]$Message) Write-Status -Type Err  -Message $Message }
function Write-Info2 { param([string]$Message) Write-Status -Type Info -Message $Message }

# ---------------------------------------------------------------------------
# Banner / visual chrome
# ---------------------------------------------------------------------------
function Get-ConsoleWidth {
    try { return [Math]::Max(60, [Math]::Min(100, $Host.UI.RawUI.WindowSize.Width)) }
    catch { return 80 }
}

function Write-Banner {
    $width = Get-ConsoleWidth
    $title = 'MILLENNIUM STEAM TOOLS'
    $subtitle = 'Millennium + SteamTools + LuaTools -- unified installer'

    $border = '+' + ('=' * ($width - 2)) + '+'
    Write-Host $border -ForegroundColor $Palette.Border

    $pad = [Math]::Max(0, [int](($width - 2 - $title.Length) / 2))
    Write-Host '|' -ForegroundColor $Palette.Border -NoNewline
    Write-Host (' ' * $pad) -NoNewline
    Write-Host $title -ForegroundColor $Palette.Title -NoNewline
    Write-Host (' ' * ($width - 2 - $pad - $title.Length)) -NoNewline
    Write-Host '|' -ForegroundColor $Palette.Border

    $pad2 = [Math]::Max(0, [int](($width - 2 - $subtitle.Length) / 2))
    Write-Host '|' -ForegroundColor $Palette.Border -NoNewline
    Write-Host (' ' * $pad2) -NoNewline
    Write-Host $subtitle -ForegroundColor $Palette.Muted -NoNewline
    Write-Host (' ' * ($width - 2 - $pad2 - $subtitle.Length)) -NoNewline
    Write-Host '|' -ForegroundColor $Palette.Border

    Write-Host $border -ForegroundColor $Palette.Border
    Write-Host ''
}

function Write-SectionHeader {
    param([string]$Title)
    $width = Get-ConsoleWidth
    Write-Host ''
    Write-Host ("-- $Title ").PadRight($width, '-') -ForegroundColor $Palette.Accent
    Write-ToLog -Line "---- $Title ----" -Level INFO
}

function Write-Rule {
    Write-Host ('-' * (Get-ConsoleWidth)) -ForegroundColor $Palette.Muted
}

# ---------------------------------------------------------------------------
# Confirmation prompts (honor -Yes / $Global:AssumeYes)
# ---------------------------------------------------------------------------
function Confirm-Step {
    param(
        [string]$Message,
        [switch]$DefaultYes
    )
    if ($Global:AssumeYes) { return $true }

    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    Write-Host (" {0,-4} " -f '[?]') -ForegroundColor $Palette.Accent -NoNewline
    Write-Host "$Message $suffix " -ForegroundColor $Palette.Accent -NoNewline
    $answer = Read-Host
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes.IsPresent }
    return $answer.Trim().ToLower() -in @('y', 'yes', 's', 'sim')
}

# ---------------------------------------------------------------------------
# Elevation
# ---------------------------------------------------------------------------
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Request-Elevation {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$OriginalArgs
    )

    if (Test-IsAdministrator) { return $true }

    Write-Warn2 'This action needs Administrator rights (Steam files live under Program Files).'
    if (-not (Confirm-Step -Message 'Relaunch this script elevated now?' -DefaultYes)) {
        Write-Err2 'Cannot continue without Administrator rights. Aborting.'
        return $false
    }

    $argString = ($OriginalArgs -join ' ')
    Write-Step 'Relaunching elevated...'

    # Relaunch with the SAME PowerShell host that's currently running (pwsh 7
    # or Windows PowerShell 5.1), rather than hard-coding powershell.exe --
    # keeps the user's chosen engine and avoids a silent downgrade to 5.1.
    $psExe = (Get-Process -Id $PID).Path
    if (-not $psExe) { $psExe = 'powershell.exe' }

    Start-Process -FilePath $psExe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $argString" `
        -Verb RunAs
    return $null # signal caller: a new elevated process was started, current one should exit
}

# ---------------------------------------------------------------------------
# Networking / downloads
#
# Some hosts (notably steamtools.net, behind Cloudflare) reject PowerShell's
# Invoke-WebRequest with HTTP 403 -- the .NET HTTP stack gets fingerprinted
# as a bot. Native curl.exe (shipped with Windows 10 1803+ / Windows 11) is
# not blocked, so we try it first and fall back to Invoke-WebRequest for
# hosts that are fine with it (e.g. GitHub).
# ---------------------------------------------------------------------------
$Script:BrowserUserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

function Get-CurlPath {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path $curl) { return $curl }
    $cmd = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function Invoke-HttpText {
    # Fetch a URL as text (used for scraping). Returns $null on failure.
    param([string]$Url, [int]$TimeoutSec = 30)

    $curl = Get-CurlPath
    if ($curl) {
        $out = & $curl -sL -A $Script:BrowserUserAgent --max-time $TimeoutSec $Url 2>$null
        if ($LASTEXITCODE -eq 0 -and $out) { return ($out -join "`n") }
    }
    try {
        return [string](Invoke-RestMethod -Uri $Url -TimeoutSec $TimeoutSec -UserAgent $Script:BrowserUserAgent)
    } catch {
        return $null
    }
}

function Invoke-Download {
    # Download a URL to a file. Returns $true if a non-empty file was written.
    param([string]$Url, [string]$OutFile, [int]$TimeoutSec = 120)

    if (Test-Path $OutFile) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }

    $curl = Get-CurlPath
    if ($curl) {
        & $curl -sL -A $Script:BrowserUserAgent --max-time $TimeoutSec -o $OutFile $Url 2>$null
        if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)) { return $true }
    }
    try {
        Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -UserAgent $Script:BrowserUserAgent
    } catch {
        return $false
    }
    return (Test-Path $OutFile) -and ((Get-Item $OutFile).Length -gt 0)
}

# ---------------------------------------------------------------------------
# Steam detection
# ---------------------------------------------------------------------------
function Get-SteamPath {
    $registries = @(
        'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam',
        'HKLM:\SOFTWARE\Valve\Steam',
        'HKCU:\SOFTWARE\Valve\Steam'
    )
    foreach ($reg in $registries) {
        if (-not (Test-Path $reg)) { continue }
        $path = (Get-ItemProperty -Path $reg -Name 'InstallPath' -ErrorAction SilentlyContinue).InstallPath
        if (-not $path) { continue }
        if ((Test-Path $path) -and (Test-Path (Join-Path $path 'steam.exe'))) {
            return $path
        }
    }
    return $null
}

function Test-SteamRunning {
    return [bool](Get-Process -Name 'steam', 'steamwebhelper' -ErrorAction SilentlyContinue)
}

function Stop-SteamProcesses {
    while (Test-SteamRunning) {
        Get-Process -Name 'steam', 'steamwebhelper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
}

# ---------------------------------------------------------------------------
# Ensure Steam is closed before a step that patches Steam files.
#
# Several installers (notably Millennium's, and the official SteamTools /
# LuaTools scripts) LAUNCH Steam when they finish. That launch is async, so
# Steam can appear a couple of seconds *after* the previous step returned.
# When -SettleSeconds is given, this watches for that delayed launch and
# closes Steam as soon as it shows up, so the next step starts clean.
#
# Returns $true if Steam ended up closed, $false if the user declined.
# ---------------------------------------------------------------------------
function Assert-SteamClosed {
    param(
        [int]$SettleSeconds = 0,   # watch this long for a delayed auto-launch
        [switch]$Force             # close without asking (Install All / clean / -Yes)
    )

    if ($SettleSeconds -gt 0) {
        Write-Step "Watching for Steam to auto-start (up to ${SettleSeconds}s) so it can be closed..."
        $deadline = (Get-Date).AddSeconds($SettleSeconds)
        while ((Get-Date) -lt $deadline -and -not (Test-SteamRunning)) {
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not (Test-SteamRunning)) { return $true }

    if ($Force -or $Global:AssumeYes) {
        Write-Step 'Steam is running -- closing it for this step.'
        Stop-SteamProcesses
        Write-Ok 'Steam closed.'
        return $true
    }

    Write-Warn2 'Steam is running and must be closed for this step.'
    if (Confirm-Step -Message 'Close Steam now?' -DefaultYes) {
        Stop-SteamProcesses
        Write-Ok 'Steam closed.'
        return $true
    }
    return $false
}

function Start-SteamProcess {
    param([string]$SteamPath, [switch]$ClearBeta)
    $exe = Join-Path $SteamPath 'steam.exe'
    if (-not (Test-Path $exe)) { return }
    if ($ClearBeta) {
        Start-Process $exe -ArgumentList '-clearbeta'
    } else {
        Start-Process $exe
    }
}

# ---------------------------------------------------------------------------
# Backup helper (used by the best-effort uninstallers)
# ---------------------------------------------------------------------------
function Backup-Item2 {
    param([string]$Path, [string]$BackupRoot)
    if (-not (Test-Path $Path)) { return $null }
    if (-not (Test-Path $BackupRoot)) { New-Item -Path $BackupRoot -ItemType Directory -Force | Out-Null }
    $dest = Join-Path $BackupRoot (Split-Path $Path -Leaf)
    Copy-Item -Path $Path -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
    return $dest
}

function New-BackupFolder {
    param([string]$SteamPath, [string]$Label)
    $stamp = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
    $root = Join-Path $env:TEMP "MillenniumSteamTools\backups\$Label-$stamp"
    New-Item -Path $root -ItemType Directory -Force | Out-Null
    return $root
}

# ---------------------------------------------------------------------------
# Safe runner -- wraps an install/uninstall action with consistent
# messaging + error handling so the menu never crashes the whole session.
#
# Returns a clean [bool]: $true when the action ran without throwing,
# $false when it threw. Any stray pipeline output from the action is
# swallowed with Out-Null so the boolean can be trusted by callers that
# gate on it (e.g. sequential "Install All").
# ---------------------------------------------------------------------------
function Invoke-SafeAction {
    param(
        [string]$Label,
        [scriptblock]$Action
    )
    Write-SectionHeader $Label
    try {
        & $Action | Out-Null
        return $true
    } catch {
        Write-Err2 "$Label failed: $($_.Exception.Message)"
        Write-ToLog -Line "$Label -- $($_.Exception.ToString())" -Level EXCEPTION
        return $false
    }
}

# ---------------------------------------------------------------------------
# Gated step -- runs an action, then confirms success by re-checking the
# tool's own detection function. Used by "Install All" so each step must
# report a positive status before the next one runs.
#
# Returns $true only when BOTH the action didn't throw AND the verify
# function (if given) now reports the tool as installed.
# ---------------------------------------------------------------------------
function Invoke-GatedStep {
    param(
        [string]$Label,
        [scriptblock]$Action,
        [string]$VerifyFunction
    )
    $ranOk = Invoke-SafeAction -Label $Label -Action $Action
    if (-not $ranOk) {
        Write-ToLog -Line "$Label -- action threw; gate = FAIL" -Level ERR
        return $false
    }
    if ($VerifyFunction) {
        $installed = [bool](& (Get-Item "function:$VerifyFunction"))
        if ($installed) {
            Write-Ok "$Label verified."
        } else {
            Write-Err2 "$Label could not be verified on disk."
            Write-ToLog -Line "$Label -- verify '$VerifyFunction' returned false; gate = FAIL" -Level ERR
        }
        return $installed
    }
    return $true
}

# ---------------------------------------------------------------------------
# Tool registry -- the single source of truth for the menu, "Install All"
# and dependency checks. Adding a future tool = add one entry here plus its
# module file; nothing else in install.ps1/uninstall.ps1 needs to change.
# ---------------------------------------------------------------------------
function Get-ToolRegistry {
    return @(
        [ordered]@{
            Key         = 'Millennium'
            Name        = 'Millennium'
            Description = 'Steam client theming & plugin framework (official installer)'
            Test        = 'Test-MillenniumInstalled'
            Install     = 'Install-Millennium'
            Uninstall   = 'Uninstall-Millennium'
            Prereqs     = @()
        },
        [ordered]@{
            Key         = 'SteamTools'
            Name        = 'SteamTools'
            Description = 'DLC/manifest unlocker (official steamtools.net setup)'
            Test        = 'Test-SteamToolsInstalled'
            Install     = 'Install-SteamTools'
            Uninstall   = 'Uninstall-SteamTools'
            Prereqs     = @()
        },
        [ordered]@{
            Key         = 'LuaTools'
            Name        = 'LuaTools (Official, full)'
            Description = 'Official one-liner -- also installs/updates SteamTools + Millennium'
            Test        = 'Test-LuaToolsInstalled'
            Install     = 'Install-LuaTools'
            Uninstall   = 'Uninstall-LuaTools'
            Prereqs     = @()
        },
        [ordered]@{
            Key         = 'LuaToolsPlugin'
            Name        = 'LuaTools Plugin Only'
            Description = 'Just the plugin -- requires Millennium + SteamTools already installed'
            Test        = 'Test-LuaToolsInstalled'
            Install     = 'Install-LuaToolsPlugin'
            Uninstall   = 'Uninstall-LuaTools'
            Prereqs     = @('Millennium', 'SteamTools')
        }
    )
}

function Test-ToolPrereqs {
    param([hashtable]$Tool, [array]$Registry)
    $missing = @()
    foreach ($prereqKey in $Tool.Prereqs) {
        $prereqTool = $Registry | Where-Object { $_.Key -eq $prereqKey }
        if (-not $prereqTool) { continue }
        $installed = & (Get-Item "function:$($prereqTool.Test)")
        if (-not $installed) { $missing += $prereqTool.Name }
    }
    return $missing
}

function Get-ToolStatusLabel {
    param([hashtable]$Tool)
    $installed = & (Get-Item "function:$($Tool.Test)")
    if ($installed) { return '[Installed]' }
    return '[Not installed]'
}

# ---------------------------------------------------------------------------
# Generic numbered menu renderer -- used for both the install and uninstall
# flows so the visual style stays identical everywhere.
# ---------------------------------------------------------------------------
function Show-Menu {
    param(
        [array]$Items,
        [string]$Prompt = 'Choose an option'
    )
    Write-Host ''
    foreach ($item in $Items) {
        Write-Host " [$($item.Number)] " -ForegroundColor $Palette.Accent -NoNewline
        Write-Host $item.Label.PadRight(40) -ForegroundColor $Palette.Title -NoNewline
        if ($item.Status) {
            $color = if ($item.Status -match 'Not') { $Palette.Err } elseif ($item.Status -match 'Installed') { $Palette.Ok } else { $Palette.Muted }
            Write-Host $item.Status -ForegroundColor $color
        } else {
            Write-Host ''
        }
        if ($item.SubLabel) {
            Write-Host ('      ' + $item.SubLabel) -ForegroundColor $Palette.Muted
        }
    }
    Write-Host ''
    Write-Host " $Prompt > " -ForegroundColor $Palette.Accent -NoNewline
    return (Read-Host).Trim()
}

function Show-SteamPathLine {
    param([string]$SteamPath)
    if ($SteamPath) {
        Write-Host ' Steam path: ' -ForegroundColor $Palette.Muted -NoNewline
        Write-Host $SteamPath -ForegroundColor $Palette.Title
    } else {
        Write-Host ' Steam path: ' -ForegroundColor $Palette.Muted -NoNewline
        Write-Host 'not detected' -ForegroundColor $Palette.Err
    }
}

function Wait-KeyPress {
    param([string]$Message = 'Press any key to continue...')
    Write-Host ''
    Write-Host " $Message" -ForegroundColor $Palette.Muted
    try {
        # Flush any buffered Enter left over from the previous Read-Host so
        # this doesn't return instantly without an actual key press.
        $Host.UI.RawUI.FlushInputBuffer()
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    } catch {
        Read-Host | Out-Null
    }
}
