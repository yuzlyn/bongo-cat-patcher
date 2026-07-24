# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README.md) | **English (en-US)**

A portable DLL patcher for the Steam version of Bongo Cat. It does not require dnSpy or the .NET SDK.

## Default Features

- Automatically purchases refreshed chests
- Checks for chests and retries failures every 300 seconds (five minutes)
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

Starting with `v1.0.5`, the patch preserves the real token check to prevent this Steam Error. On Windows, the game log is located at:

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
