# Millennium Steam Tools

A single, friendly PowerShell installer for three community Steam add-ons:

| Tool | What it does | Official source |
|---|---|---|
| **[Millennium](https://docs.steambrew.app/users/)** | Steam client theming & plugin framework | [SteamClientHomebrew/Installer](https://github.com/SteamClientHomebrew/Installer) |
| **[SteamTools](https://steamtools.net/)** | DLC / manifest unlocker | `irm steam.run \| iex` |
| **[LuaTools](https://wiki.lua.tools/docs/luatools/steam-plugin/get-started)** | Millennium plugin to add/remove games and apply compatibility fixes from Steam store pages | `irm https://luatools.vercel.app/install-plugin.ps1 \| iex` |

You get full control: install each tool on its own, install everything in one go, or uninstall anything you no longer want — nothing runs without your confirmation.

## Why this exists

Each tool already has its own official one-liner/installer. This project doesn't replace them — it **wraps** them behind one consistent menu, with:

- A live status view (✔ / ✖) so you always know what's already installed.
- A real standalone way to install **just the LuaTools plugin**, even though LuaTools' own official script always drags in SteamTools + Millennium too (see [How LuaTools Plugin Only works](#how-luatools-plugin-only-works) below).
- Consistent logging, confirmations, elevation handling, and best-effort backups before anything destructive.

## Requirements

- Windows 10/11 with Steam installed.
- PowerShell 5.1+ (built into Windows) or PowerShell 7+.
- Administrator rights (the script offers to relaunch itself elevated if needed — Steam's install folder usually lives under `Program Files`).
- An internet connection (every install downloads from the tool's official source).

## Quick start

Clone or download this repository, then from the project folder:

```powershell
.\install.ps1
```

This opens the interactive menu:

```
 [1] Install Millennium                      [Installed]
 [2] Install SteamTools                      [Not installed]
 [3] Install LuaTools (Official, full)       [Not installed]
      Also installs/updates SteamTools + Millennium
 [4] Install LuaTools Plugin Only            [Not installed]
      Requires Millennium + SteamTools already installed
 [5] Install All (clean reinstall)
      Reinstall everything from scratch, even if already installed
 [6] Uninstall menu
 [0] Exit
```

The interface is plain ASCII (no Unicode icons or emoji) so it renders correctly in every console font, including the classic Windows PowerShell console.

If Windows blocks the script from running, allow it for the current session first:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

## Command-line usage

Every action is also available as a switch, for scripted / unattended installs:

```powershell
.\install.ps1 -Millennium              # Millennium only
.\install.ps1 -SteamTools              # SteamTools only
.\install.ps1 -LuaTools                # Official LuaTools one-liner (installs all 3)
.\install.ps1 -LuaToolsPluginOnly      # Just the plugin (Millennium + SteamTools must already exist)
.\install.ps1 -All                     # Clean reinstall of all 3 (Millennium -> SteamTools -> LuaTools Plugin)
.\install.ps1 -All -Yes                # Same, unattended (auto-confirm every prompt)
.\install.ps1 -Uninstall               # Jump straight to the uninstall menu
.\install.ps1 -All -NoElevate          # Don't try to relaunch as Administrator
```

`uninstall.ps1` takes the matching switches: `-Millennium`, `-SteamTools`, `-LuaTools`, `-All`, `-Yes`, `-NoElevate`.

## How "Install All (clean reinstall)" works

`Install All` performs a **clean reinstall of everything from scratch** — every tool is reinstalled even if it's already present, as if you were setting up a fresh machine. It runs three independent, visible steps:

1. Reinstall Millennium (runs the official installer again)
2. Reinstall SteamTools (runs the official one-liner again)
3. Reinstall the LuaTools plugin — the existing plugin folder is **wiped and redeployed fresh** (not merged over), so you end up with a pristine copy.

It deliberately does **not** just call the official LuaTools one-liner (which would reinstall SteamTools and Millennium too), so SteamTools isn't reinstalled twice in the same run.

**Sequential gating:** each step must report a positive status before the next one starts. After every step the script re-checks the tool's own detection (e.g. after step 1 it confirms Millennium's files are actually on disk). If a step fails or can't be confirmed, the chain stops immediately with a clear message — so it never tries to drop the LuaTools plugin onto a half-installed Millennium.

## How "LuaTools Plugin Only" works

LuaTools' official script ([`install-plugin.ps1`](https://luatools.vercel.app/install-plugin.ps1)) always installs/reinstalls SteamTools and Millennium as part of its own flow — there's no official flag to skip that.

To give you a genuinely independent option, this project reimplements **just the plugin deployment step** (ported from the official script's own `Install-Plugin` / `Enable-Plugin` logic): download `ltsteamplugin.zip`, extract it to `<Steam>\millennium\plugins\luatools\`, and enable it in `<Steam>\millennium\config\config.json`.

Before doing any of that, it **checks** whether Millennium and SteamTools are already installed:

- If both are present → installs the plugin, nothing else is touched.
- If either is missing → it stops immediately and tells you exactly what to install first (menu options 1 / 2). **It will never install them for you** — that's what the "LuaTools (Official, full)" option is for.

This means you can safely re-run `Install LuaTools Plugin Only` to update just the plugin without ever touching your existing Millennium/SteamTools setup.

## Uninstalling

Open the uninstall menu with `.\uninstall.ps1` (or option `6` in the main menu):

- **Millennium** — relaunches the official Millennium installer, which has its own built-in removal option in the wizard.
- **SteamTools** and **LuaTools plugin** — neither ships an official uninstaller. Removal is **best-effort**: this project deletes the specific files/folders it knows each tool creates, but only after backing them up first.

Every uninstall backs up what it's about to touch to:

```
%TEMP%\MillenniumSteamTools\backups\<Tool>-<timestamp>\
```

so you can always restore manually if something looks wrong afterwards.

## Logs

Every run writes a timestamped log to:

```
%TEMP%\MillenniumSteamTools\run-<timestamp>.log
```

Each log starts with an environment header (user, admin state, PowerShell and OS version) and then records every step, status line, menu choice and — most importantly — the full detail of any error or caught exception. The path is printed when you exit, so it's easy to find if something fails and you want to see exactly what happened.

## Project structure

```
install.ps1              Main entry point — interactive menu + CLI switches
uninstall.ps1             Uninstall menu + CLI switches
modules/
  Common.ps1              Shared UI (banner, menu, colors), logging, elevation,
                           Steam detection, and the tool registry
  Millennium.ps1           Install-Millennium / Uninstall-Millennium / Test-MillenniumInstalled
  SteamTools.ps1           Install-SteamTools / Uninstall-SteamTools / Test-SteamToolsInstalled
  LuaTools.ps1             Install-LuaTools (official) / Install-LuaToolsPlugin (plugin-only) /
                           Uninstall-LuaTools / Test-LuaToolsInstalled
```

Everything is driven by a small tool registry in `modules/Common.ps1` (`Get-ToolRegistry`) — each entry declares its name, its install/uninstall/detect functions, and its prerequisites. Adding a future tool means adding one module file plus one entry in that registry; the menu, `Install All`, and prerequisite checks all pick it up automatically.

## Troubleshooting

- **"Steam installation not found in the registry"** — make sure Steam has been run at least once (its registry keys are created on first launch).
- **A step fails partway through** — check the log file (see above); most steps are safe to just re-run.
- **SteamTools/LuaTools install fails to download** — this is usually the installer's own upstream server being blocked by your ISP/network; see the `.gg/luatools` Discord linked in LuaTools' own error screen for known workarounds.

## Credits

This project only orchestrates the official installers/scripts published by each tool's own team:

- Millennium — [SteamClientHomebrew](https://github.com/SteamClientHomebrew)
- SteamTools — [steamtools.net](https://steamtools.net/)
- LuaTools — [wiki.lua.tools](https://wiki.lua.tools/)
