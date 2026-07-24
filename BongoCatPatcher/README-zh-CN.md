# Bongo Cat DLL 补丁器

本工具修改游戏目录中的 `BongoCat_Data/Managed/Assembly-CSharp.dll`，默认设置为：

- 自动购买已刷新的箱子
- 箱子检查与失败重试时间 300 秒
- 点击倍率 1000 倍

## 使用

1. 完全退出 Bongo Cat。
2. 双击 `Apply-Patch.cmd`。
3. 看到 `Patch complete` 后再启动游戏。

脚本会先检查目标类型和 IL 结构，并将原始 DLL 备份到：

`BongoCat_Data/Managed/BongoCatPatcher.Backups/`

需要恢复时，退出游戏并双击 `Restore-Original.cmd`。

## 自定义参数

在 PowerShell 中进入本目录后运行：

```powershell
.\Patch-BongoCat.ps1 -StockRefreshSeconds 600 -ClickMultiplier 100
```

刷新时间允许范围是 60 到 86400 秒。补丁只会在 Steam 已实际发放箱子 Token 时自动开箱；没有 Token 时会按设定时间再次检查，避免无效兑换触发 Steam Error。箱子 Token 和物品由 Steam 服务器管理，本工具不会伪造或绕过服务器库存。

其他可用参数：

```powershell
# 关闭自动开箱，同时保留其他设置
.\Patch-BongoCat.ps1 -DisableAutoBuy

# 将点击倍率恢复为 1
.\Patch-BongoCat.ps1 -ClickMultiplier 1

# 脚本放在游戏目录之外时，明确指定游戏目录
.\Patch-BongoCat.ps1 -GamePath 'D:\Steam\steamapps\common\BongoCat'

# 只预览修改，不写入 DLL
.\Patch-BongoCat.ps1 -WhatIf
```

## 复制到其他电脑

复制整个 `BongoCatPatcher` 文件夹到另一台电脑的 Bongo Cat 游戏根目录，然后双击 `Apply-Patch.cmd`。依赖库已包含在 `lib` 目录中，不需要安装 dnSpy、.NET SDK 或联网下载依赖。

Steam 更新游戏后，可以再次运行补丁器。脚本会按程序集版本分别保存原始备份；如果新版本的 IL 结构不兼容，它会停止并报告错误，不会写入 DLL。

第三方组件 dnlib 采用 MIT 许可证，许可证文本位于 `lib/dnlib-LICENSE.txt`。
