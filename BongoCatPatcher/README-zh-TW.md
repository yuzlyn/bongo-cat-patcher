# Bongo Cat DLL 補丁器

**繁體中文 (zh-TW)** | [English (en-US)](README-en-US.md)

本工具只會修改遊戲目錄中的 `BongoCat_Data/Managed/Assembly-CSharp.dll`，提供兩項功能：

- 遊戲原本判定寶箱可購買時，自動呼叫原有的購買與開箱流程。
- 將每次點擊取得的貓咪數量調整為指定倍率，預設為 1000 倍。

## 使用方式

1. 完全關閉 Bongo Cat。
2. 雙擊 `Apply-Patch.cmd`。
3. 看到 `Patch complete` 後再啟動遊戲。

腳本會先檢查目標型別與 IL 結構，並將原始 DLL 備份至：

`BongoCat_Data/Managed/BongoCatPatcher.Backups/`

需要還原時，請關閉遊戲並雙擊 `Restore-Original.cmd`。

## 自訂點擊倍率

在 PowerShell 中進入本資料夾後執行：

```powershell
.\Patch-BongoCat.ps1 -ClickMultiplier 100
```

補丁不會改變倒數時間、Steam Token 檢查、庫存重新整理、失敗重試或交換次數。Steam 的原始流程仍決定何時有可領取的寶箱與如何兌換；補丁只在遊戲已判定可購買時替代一次滑鼠點擊。

其他可用參數：

```powershell
# 將點擊倍率還原為 1
.\Patch-BongoCat.ps1 -ClickMultiplier 1

# 腳本位於遊戲目錄之外時，明確指定遊戲目錄
.\Patch-BongoCat.ps1 -GamePath 'D:\Steam\steamapps\common\BongoCat'

# 只預覽修改，不寫入 DLL
.\Patch-BongoCat.ps1 -WhatIf
```

## 複製到其他電腦

將整個 `BongoCatPatcher` 資料夾複製到另一台電腦的 Bongo Cat 遊戲根目錄，再雙擊 `Apply-Patch.cmd`。相依程式庫已包含在 `lib` 資料夾中，不需要安裝 dnSpy、.NET SDK 或透過網路下載相依套件。

Steam 更新遊戲後可以再次執行補丁器。腳本會依組件版本分別保存原始備份；如果新版的 IL 結構不相容，工具會停止並回報錯誤，不會寫入 DLL。

第三方元件 dnlib 採用 MIT License，授權文字位於 `lib/dnlib-LICENSE.txt`。
