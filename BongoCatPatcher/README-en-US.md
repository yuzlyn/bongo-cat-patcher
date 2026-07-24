# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README-zh-TW.md) | **English (en-US)**

This tool modifies `BongoCat_Data/Managed/Assembly-CSharp.dll` in the game directory. Its default settings are:

- Automatically purchases refreshed chests
- Uses the Steam token-arrival callback to trigger one immediate claim; the 1800-second countdown remains for display and fallback
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

The refresh interval can be set from 60 to 86400 seconds. The patch opens a chest only after Steam has granted the corresponding chest token. Once the Steam drop callback confirms the token, one exchange starts within about one second without waiting for the visible countdown. The gate is restored after success so stale local inventory data cannot submit a duplicate exchange. Steam manages all chest tokens and items; this tool does not forge or bypass the server inventory.

## Tokens and Countdown

The game's original chest interval is `1800` seconds (30 minutes), so the patch uses `1800` as the default `StockRefreshSeconds`. The game sends a drop request to Steam every 60 seconds, but Steam still decides whether to grant a token; one request per minute does not guarantee one token per minute.

- If a token arrives before the countdown ends, the patch automatically opens the chest within about one second.
- If no token is available, no invalid exchange is attempted. Every Steam drop callback is logged and requests a full inventory refresh.
- After a failed exchange, the patch refreshes the complete Steam inventory and retries after 60 seconds instead of sending five immediate exchange requests.
- Modifying the DLL cannot force Steam to generate a token or bypass Steam's server-side inventory and drop rules.

Older patch versions could repeatedly attempt an exchange without a token, producing these log messages:

```text
SteamExchange | Not enough items to exchange for Chest Exchange, missing 1 of Chest Token
Chest Exchange failed after multiple retries, giving up!
```

The patch preserves the real token check to prevent this Steam Error. Double-click `Watch-ChestClaimLog.cmd` to follow the claim flow in the Windows `Player.log`: `TOKEN RECEIVED` means the token arrived, `CLAIM SUCCESS` means Steam consumed it and returned the chest item, and `NO TOKEN` or `CLAIM FAILED` means it has not been claimed yet and refresh/retry remains active.

Other options:

```powershell
# Disable automatic chest opening while keeping other settings
.\Patch-BongoCat.ps1 -DisableAutoBuy

# Change the recheck delay after a delayed token or failed exchange
.\Patch-BongoCat.ps1 -TokenRetrySeconds 60

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
