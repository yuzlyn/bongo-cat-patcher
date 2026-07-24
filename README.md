# Bongo Cat DLL 補丁器

**繁體中文 (zh-TW)** | [English (en-US)](README-en-US.md)

適用於 Steam 版 Bongo Cat 的可攜式 DLL 補丁工具，不需要安裝 dnSpy 或 .NET SDK。

## 預設功能

- 自動購買已刷新的寶箱
- 寶箱檢查與失敗重試時間為 300 秒（五分鐘）
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

`StockRefreshSeconds` 設定的是本機檢查與失敗重試週期，不是 Steam 伺服器的寶箱發放週期。預設值 `300` 表示每五分鐘檢查一次庫存中的寶箱 Token。

- 倒數結束且已有 Token：寵物點數足夠時會自動開箱，實際物品由 Steam 發放。
- 倒數結束但沒有 Token：不執行無效兌換，倒數會重新從五分鐘開始。
- 倒數重新開始但沒有收到寶箱，通常表示 Steam 尚未發放 Token，不代表補丁失效。
- 修改 DLL 無法強制 Steam 每五分鐘產生 Token，也不能繞過 Steam 的伺服器庫存與掉落規則。

舊版補丁在沒有 Token 時可能反覆嘗試兌換，並在記錄檔中出現：

```text
SteamExchange | Not enough items to exchange for Chest Exchange, missing 1 of Chest Token
Chest Exchange failed after multiple retries, giving up!
```

`v1.0.5` 起會保留真實 Token 檢查，避免這類 Steam Error。Windows 記錄檔位於：

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
