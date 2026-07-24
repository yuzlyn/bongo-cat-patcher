# Bongo Cat DLL 補丁器

**繁體中文 (zh-TW)** | [English (en-US)](README-en-US.md)

適用於 Steam 版 Bongo Cat 的可攜式 DLL 補丁工具，不需要安裝 dnSpy 或 .NET SDK。

## 預設功能

- 自動購買已刷新的寶箱
- 以 Steam Token 到帳回呼為準，立即觸發一次開箱；成功後恢復門控避免重複兌換
- 點擊倍率為 1000 倍
- 修改前自動備份原始 `Assembly-CSharp.dll`
- 遊戲執行中會拒絕修改 DLL

## 下載與使用

1. 從 [Releases](https://github.com/yuzlyn/bongo-cat-patcher/releases/latest) 下載 `BongoCatPatcher-portable.zip`。
2. 將 ZIP 解壓縮至 Bongo Cat 遊戲根目錄，確認 `BongoCatPatcher` 與 `BongoCat.exe` 位於同一層。
3. 完全關閉 Bongo Cat。
4. 雙擊 `BongoCatPatcher\Apply-Patch.cmd`。
5. 看到 `Patch complete` 後再啟動遊戲。

Steam 遊戲目錄通常位於：

```text
Steam\steamapps\common\BongoCat
```

也可以在 Steam 遊戲庫中選擇「Bongo Cat → 管理 → 瀏覽本機檔案」。

## Token 與倒數計時

遊戲原始寶箱週期為 `1800` 秒（30 分鐘），因此補丁的 `StockRefreshSeconds` 預設也設為 `1800`。遊戲每 60 秒向 Steam 發送掉落請求，但是否發放仍由 Steam 伺服器決定；每分鐘請求不代表每分鐘必定取得 Token。

- Token 先到、倒數未結束：最多約 1 秒內自動開箱，不再等待倒數。
- 沒有 Token：不執行無效兌換；每次 Steam 掉落回呼都會記錄結果並重新讀取庫存。
- 兌換失敗：立即重新整理 Steam 全量庫存，60 秒後再嘗試，不會在同一時間連續送出五次兌換。
- 修改 DLL 無法強制 Steam 產生 Token，也不能繞過 Steam 的伺服器庫存與掉落規則。

舊版補丁在沒有 Token 時可能反覆嘗試兌換，並在記錄檔中出現：

```text
SteamExchange | Not enough items to exchange for Chest Exchange, missing 1 of Chest Token
Chest Exchange failed after multiple retries, giving up!
```

補丁會保留真實 Token 檢查，避免這類 Steam Error。雙擊 `BongoCatPatcher\Watch-ChestClaimLog.cmd` 可即時查看領取流程；`TOKEN RECEIVED` 表示 Token 到帳，`CLAIM SUCCESS` 表示已領到，`NO TOKEN` 或 `CLAIM FAILED` 表示尚未領到且會繼續重試。Windows 記錄檔位於：

```text
%USERPROFILE%\AppData\LocalLow\Irox Games\BongoCat\Player.log
```

## 自訂參數

在 PowerShell 中進入 `BongoCatPatcher` 資料夾後執行：

```powershell
.\Patch-BongoCat.ps1 -StockRefreshSeconds 600 -ClickMultiplier 100
```

其他常用參數：

```powershell
# 關閉自動開箱，同時保留其他設定
.\Patch-BongoCat.ps1 -DisableAutoBuy

# 自訂 Token 延遲或失敗後的重查時間
.\Patch-BongoCat.ps1 -TokenRetrySeconds 60

# 將點擊倍率還原為 1
.\Patch-BongoCat.ps1 -ClickMultiplier 1

# 只預覽修改，不寫入 DLL
.\Patch-BongoCat.ps1 -WhatIf

# 還原原始 DLL
.\Patch-BongoCat.ps1 -Restore
```

原始 DLL 備份位於 `BongoCat_Data\Managed\BongoCatPatcher.Backups\`。Steam 更新遊戲後可再次執行補丁器；若新版遊戲的 IL 結構不相容，工具會停止並顯示錯誤，不會寫入 DLL。

## 授權

本專案採用 [MIT License](LICENSE)。內附的 dnlib 同樣採用 MIT License，其授權文字位於 `BongoCatPatcher\lib\dnlib-LICENSE.txt`。
