# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README.md) | **English (en-US)**

A portable DLL patcher for the Steam version of Bongo Cat. It does not require dnSpy or the .NET SDK.

## Default Features

- Automatically purchases refreshed chests
- Uses the Steam token-arrival callback to trigger one immediate claim, then restores the gate to prevent duplicate exchanges
- Applies a 1000x click multiplier
- Automatically backs up the original `Assembly-CSharp.dll` before patching
- Refuses to modify the DLL while the game is running

## Download and Usage

1. Download `BongoCatPatcher-portable.zip` from [Releases](https://github.com/yuzlyn/bongo-cat-patcher/releases/latest).
2. Extract the ZIP into the Bongo Cat game directory. The `BongoCatPatcher` folder should be next to `BongoCat.exe`.
3. Close Bongo Cat completely.
4. Double-click `BongoCatPatcher\Apply-Patch.cmd`.
5. Start the game after `Patch complete` appears.

The Steam game directory is usually located at:

```text
Steam\steamapps\common\BongoCat
```

You can also select Bongo Cat in your Steam library, then choose Manage > Browse local files.

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

The patch preserves the real token check to prevent this Steam Error. Double-click `BongoCatPatcher\Watch-ChestClaimLog.cmd` to follow the result: `TOKEN RECEIVED` means the token arrived, `CLAIM SUCCESS` means it was claimed, and `NO TOKEN` or `CLAIM FAILED` means refresh/retry remains active. On Windows, the game log is located at:

```text
%USERPROFILE%\AppData\LocalLow\Irox Games\BongoCat\Player.log
```

## Custom Parameters

Open PowerShell in the `BongoCatPatcher` folder and run:

```powershell
.\Patch-BongoCat.ps1 -StockRefreshSeconds 600 -ClickMultiplier 100
```

Other common options:

```powershell
# Disable automatic chest opening while keeping other settings
.\Patch-BongoCat.ps1 -DisableAutoBuy

# Change the recheck delay after a delayed token or failed exchange
.\Patch-BongoCat.ps1 -TokenRetrySeconds 60

# Restore the click multiplier to 1
.\Patch-BongoCat.ps1 -ClickMultiplier 1

# Preview changes without writing to the DLL
.\Patch-BongoCat.ps1 -WhatIf

# Restore the original DLL
.\Patch-BongoCat.ps1 -Restore
```

Original DLL backups are stored in `BongoCat_Data\Managed\BongoCatPatcher.Backups\`. You can run the patcher again after a Steam game update. If the new game version has an incompatible IL structure, the patcher stops with an error and does not write to the DLL.

## License

This project is licensed under the [MIT License](LICENSE). The bundled dnlib dependency also uses the MIT License; its license text is located at `BongoCatPatcher\lib\dnlib-LICENSE.txt`.
