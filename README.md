# Bongo Cat DLL 補丁器

**繁體中文 (zh-TW)** | [English (en-US)](README-en-US.md)

適用於 Steam 版 Bongo Cat 的可攜式 DLL 補丁工具，不需要安裝 dnSpy 或 .NET SDK。

## 預設功能

- 遊戲原本判定寶箱可購買時，自動呼叫原有的購買與開箱流程
- 點擊倍率為 1000 倍
- 進入多人房間時，其他玩家的貓會貼在螢幕右緣或上緣，且底部朝向所貼的邊緣
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

## 寶箱行為

補丁將寶箱與 Steam 掉落檢查固定為 15 分鐘。Steam 掉落回呼在 token 出現、遊戲標記寶箱可領取且原有支付條件成立時，自動呼叫原有的購買與開箱流程；token 尚未同步或交換失敗時，會等待下一個 15 分鐘事件，避免每 60 秒反覆請求。

## 自訂參數

在 PowerShell 中進入 `BongoCatPatcher` 資料夾後執行：

```powershell
.\Patch-BongoCat.ps1 -ClickMultiplier 100
```

其他常用參數：

```powershell
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
