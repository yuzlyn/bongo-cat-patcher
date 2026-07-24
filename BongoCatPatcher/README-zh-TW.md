# Bongo Cat DLL 補丁器

**繁體中文 (zh-TW)** | [English (en-US)](README-en-US.md)

本工具會修改遊戲目錄中的 `BongoCat_Data/Managed/Assembly-CSharp.dll`，預設設定如下：

- 自動購買已刷新的寶箱
- 以 Steam Token 到帳回呼為準，立即觸發一次開箱；1800 秒倒數保留為顯示與兜底
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

刷新時間允許範圍為 60 到 86400 秒。補丁只會在 Steam 已實際發放寶箱 Token 時自動開箱；Steam 掉落回呼確認 Token 後，最多約 1 秒就會觸發一次兌換，不必等待畫面倒數結束。成功後會恢復門控，避免本機舊快取造成重複兌換。寶箱 Token 與物品由 Steam 伺服器管理，本工具不會偽造或繞過伺服器庫存。

## Token 與倒數計時說明

遊戲原始寶箱週期為 `1800` 秒（30 分鐘），因此補丁的 `StockRefreshSeconds` 預設也設為 `1800`。遊戲每 60 秒向 Steam 發送掉落請求，但是否發放仍由 Steam 伺服器決定；每分鐘請求不代表每分鐘必定取得 Token。

- Token 先到、倒數未結束：最多約 1 秒內自動開箱，不再等待倒數。
- 沒有 Token：不執行無效兌換；每次 Steam 掉落回呼都會記錄結果並重新讀取庫存。
- 兌換失敗：立即重新整理 Steam 全量庫存，60 秒後再嘗試，不會在同一時間連續送出五次兌換。
- 修改 DLL 無法強制 Steam 產生 Token，也不能繞過 Steam 的伺服器庫存與掉落規則。

舊版補丁曾在沒有 Token 時強制呼叫開箱，遊戲記錄檔會反覆出現以下內容並最終顯示 Steam Error：

```text
SteamExchange | Not enough items to exchange for Chest Exchange, missing 1 of Chest Token
Chest Exchange failed after multiple retries, giving up!
```

補丁會保留真實 Token 檢查，避免此錯誤。雙擊 `Watch-ChestClaimLog.cmd` 可即時查看 Windows `Player.log` 中的領取流程：`TOKEN RECEIVED` 表示 Token 已到帳，`CLAIM SUCCESS` 表示 Steam 已消耗 Token 並回傳寶箱物品，`NO TOKEN` 或 `CLAIM FAILED` 表示尚未領到，程式會繼續刷新與重試。

其他可用參數：

```powershell
# 關閉自動開箱，同時保留其他設定
.\Patch-BongoCat.ps1 -DisableAutoBuy

# 自訂 Token 延遲或失敗後的重查時間
.\Patch-BongoCat.ps1 -TokenRetrySeconds 60

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
