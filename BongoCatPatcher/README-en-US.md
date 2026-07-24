# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README-zh-TW.md) | **English (en-US)**

This tool modifies `BongoCat_Data/Managed/Assembly-CSharp.dll` in the game directory. Its default settings are:

- Automatically purchases refreshed chests
- Checks for chests and retries failures every 300 seconds
- Applies a 1000x click multiplier

## Usage

1. Close Bongo Cat completely.
2. Double-click `Apply-Patch.cmd`.
3. Start the game after `Patch complete` appears.

The script validates the target types and IL structure before creating an original DLL backup in:

`BongoCat_Data/Managed/BongoCatPatcher.Backups/`

To restore the game, close it and double-click `Restore-Original.cmd`.

## Custom Parameters

Open PowerShell in this folder and run:

```powershell
.\Patch-BongoCat.ps1 -StockRefreshSeconds 600 -ClickMultiplier 100
```

The refresh interval can be set from 60 to 86400 seconds. The patch opens a chest only after Steam has granted the corresponding chest token. Without a token, it checks again after the configured interval instead of making an invalid exchange that causes a Steam Error. Steam manages all chest tokens and items; this tool does not forge or bypass the server inventory.

## Tokens and Countdown

`StockRefreshSeconds` controls the local check and failure retry interval. It does not control the Steam server's chest drop interval. The default value of `300` checks the inventory for a chest token every five minutes.

- If the countdown ends and a token is available, the patch automatically opens the chest when you have enough pet points. Steam grants the actual item.
- If no token is available, no invalid exchange is attempted and the countdown restarts at five minutes.
- A restarted countdown without a chest usually means Steam has not granted a token yet; it does not mean the patch failed.
- Modifying the DLL cannot force Steam to generate a token every five minutes or bypass Steam's server-side inventory and drop rules.

Older patch versions could repeatedly attempt an exchange without a token, producing these log messages:

```text
SteamExchange | Not enough items to exchange for Chest Exchange, missing 1 of Chest Token
Chest Exchange failed after multiple retries, giving up!
```

Starting with `v1.0.5`, the patch preserves the real token check to prevent this Steam Error. On Windows, the game log is located at `%USERPROFILE%\AppData\LocalLow\Irox Games\BongoCat\Player.log`.

Other options:

```powershell
# Disable automatic chest opening while keeping other settings
.\Patch-BongoCat.ps1 -DisableAutoBuy

# Restore the click multiplier to 1
.\Patch-BongoCat.ps1 -ClickMultiplier 1

# Specify the game directory when this script is stored elsewhere
.\Patch-BongoCat.ps1 -GamePath 'D:\Steam\steamapps\common\BongoCat'

# Preview changes without writing to the DLL
.\Patch-BongoCat.ps1 -WhatIf
```

## Copying to Another Computer

Copy the complete `BongoCatPatcher` folder into the Bongo Cat game directory on the other computer, then double-click `Apply-Patch.cmd`. The `lib` folder includes the required dependency, so dnSpy, the .NET SDK, and network downloads are not required.

You can run the patcher again after a Steam game update. The script stores original backups separately for each assembly version. If the new IL structure is incompatible, the patcher stops with an error and does not write to the DLL.

The bundled dnlib dependency uses the MIT License. Its license text is located at `lib/dnlib-LICENSE.txt`.
