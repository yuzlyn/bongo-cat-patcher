# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README-zh-TW.md) | **English (en-US)**

This tool modifies `BongoCat_Data/Managed/Assembly-CSharp.dll` in the game directory and provides three features:

- Set chest countdowns and Steam drop events to 15 minutes, then use the Steam drop callback to start the existing purchase and opening flow only after the token is present.
- Apply a configurable click multiplier, 1000x by default.
- When joining a multiplayer lobby, place cats tightly along the right, top, left, then bottom screen edges. Each cat rotates so its bottom faces the edge it occupies, rather than scattering upright cats across the desktop.

## Usage

1. Close Bongo Cat completely.
2. Double-click `Apply-Patch.cmd`.
3. Start the game after `Patch complete` appears.

The script validates the target types and IL structure before creating an original DLL backup in:

`BongoCat_Data/Managed/BongoCatPatcher.Backups/`

To restore the game, close it and double-click `Restore-Original.cmd`.

## Click Multiplier

Open PowerShell in this folder and run:

```powershell
.\Patch-BongoCat.ps1 -ClickMultiplier 100
```

The patch removes the legacy popup-triggered auto-purchase hook. A Steam inventory-drop callback wakes the shop check; the original purchase and opening flow is called only when `Chest_Token` or `Emote_Chest_Token` exists, the game marks the chest ready, and the normal payment condition passes. If the countdown reaches `00:00` before a token synchronizes, the chest remains pending and only local inventory state is checked. No repeated Steam exchange request is sent, and the original exchange starts as soon as the token appears.

Other options:

```powershell
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
