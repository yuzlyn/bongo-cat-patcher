# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README-zh-TW.md) | **English (en-US)**

This tool modifies `BongoCat_Data/Managed/Assembly-CSharp.dll` in the game directory and provides only two features:

- When the game has determined that a chest can be purchased, automatically call its existing purchase and chest-opening flow.
- Apply a configurable click multiplier, 1000x by default.

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

The patch does not change countdowns, Steam token checks, inventory refreshes, failure retries, or exchange retry counts. Steam's original flow still decides when a chest is available and how it is exchanged; the patch only replaces one mouse click after the game has already confirmed that purchase is available.

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
