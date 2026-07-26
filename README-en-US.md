# Bongo Cat DLL Patcher

[繁體中文 (zh-TW)](README.md) | **English (en-US)**

A portable DLL patcher for the Steam version of Bongo Cat. It does not require dnSpy or the .NET SDK.

## Default Features

- When the game has determined that a chest can be purchased, automatically call its existing purchase and chest-opening flow
- Applies a 1000x click multiplier
- When joining a multiplayer lobby, tightly place other players' cats along the right, top, left, then bottom screen edges with each cat's bottom facing its edge
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

## Chest Behavior

The patch keeps chest and Steam drop checks on the official 15-minute interval. After the 15-minute event, the Steam drop callback only wakes a local shop check; the game's original purchase and chest-opening flow is called only when `Chest_Token` or `Emote_Chest_Token` has synchronized, the game marks the chest ready, and the normal payment condition passes. A missing token or failed exchange keeps the chest pending and continues checking local inventory state, without sending repeated Steam exchange requests every 60 seconds.

## Custom Parameters

Open PowerShell in the `BongoCatPatcher` folder and run:

```powershell
.\Patch-BongoCat.ps1 -ClickMultiplier 100
```

Other common options:

```powershell
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
