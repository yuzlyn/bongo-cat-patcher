# Bongo Cat DLL 補丁器

**繁體中文 (zh-TW)** | [English (en-US)](README-en-US.md)

本工具會修改遊戲目錄中的 `BongoCat_Data/Managed/Assembly-CSharp.dll`，預設設定如下：

- 自動購買已刷新的寶箱
- 寶箱檢查與失敗重試時間為 300 秒
- 點擊倍率為 1000 倍

## 使用方式

1. 完全關閉 Bongo Cat。
2. 雙擊 `Apply-Patch.cmd`。
3. 看到 `Patch complete` 後再啟動遊戲。

腳本會先檢查目標型別與 IL 結構，並將原始 DLL 備份至：

`BongoCat_Data/Managed/BongoCatPatcher.Backups/`

需要還原時，請關閉遊戲並雙擊 `Restore-Original.cmd`。

## 自訂參數

在 PowerShell 中進入本資料夾後執行：

```powershell
.\Patch-BongoCat.ps1 -StockRefreshSeconds 600 -ClickMultiplier 100
```

刷新時間允許範圍為 60 到 86400 秒。補丁只會在 Steam 已實際發放寶箱 Token 時自動開箱；沒有 Token 時會依設定時間再次檢查，避免無效兌換觸發 Steam Error。寶箱 Token 與物品由 Steam 伺服器管理，本工具不會偽造或繞過伺服器庫存。

## Token 與倒數計時說明

`StockRefreshSeconds` 設定的是本機檢查與失敗重試週期，不是 Steam 伺服器的寶箱發放週期。預設值 `300` 表示每五分鐘檢查一次庫存中的寶箱 Token。

- 倒數結束且已有 Token：寵物點數足夠時會自動開箱，實際物品由 Steam 發放。
- 倒數結束但沒有 Token：不執行無效兌換，倒數會重新從五分鐘開始。
- 倒數重新開始但沒有收到寶箱，不代表補丁失效；通常表示 Steam 尚未發放 Token。
- 修改 DLL 無法強制 Steam 每五分鐘產生 Token，也不能繞過 Steam 的伺服器庫存與掉落規則。

舊版補丁曾在沒有 Token 時強制呼叫開箱，遊戲記錄檔會反覆出現以下內容並最終顯示 Steam Error：

```text
SteamExchange | Not enough items to exchange for Chest Exchange, missing 1 of Chest Token
Chest Exchange failed after multiple retries, giving up!
```

`v1.0.5` 起會保留真實 Token 檢查，避免此錯誤。Windows 記錄檔位於 `%USERPROFILE%\AppData\LocalLow\Irox Games\BongoCat\Player.log`。

其他可用參數：

```powershell
# 關閉自動開箱，同時保留其他設定
.\Patch-BongoCat.ps1 -DisableAutoBuy

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
