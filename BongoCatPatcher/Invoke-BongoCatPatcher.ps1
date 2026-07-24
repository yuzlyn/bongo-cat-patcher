param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Apply', 'Restore')]
    [string]$Action
)

$ErrorActionPreference = 'Stop'
$patchScript = Join-Path $PSScriptRoot 'Patch-BongoCat.ps1'
$exitCode = 0

if ($Action -eq 'Apply') {
    $Host.UI.RawUI.WindowTitle = 'Bongo Cat Patcher'
    Write-Host '========================================'
    Write-Host 'Bongo Cat 補丁器 / Bongo Cat Patcher'
    Write-Host '========================================'
    Write-Host '[zh-TW] 請先完全關閉 Bongo Cat，正在套用補丁...'
    Write-Host '[en-US] Close Bongo Cat before continuing. Applying patch...'
}
else {
    $Host.UI.RawUI.WindowTitle = 'Bongo Cat Restore'
    Write-Host '========================================'
    Write-Host 'Bongo Cat 原始檔還原 / Bongo Cat Restore'
    Write-Host '========================================'
    Write-Host '[zh-TW] 請先完全關閉 Bongo Cat，正在還原原始 DLL...'
    Write-Host '[en-US] Close Bongo Cat before continuing. Restoring the original DLL...'
}

Write-Host

try {
    if ($Action -eq 'Apply') {
        & $patchScript
    }
    else {
        & $patchScript -Restore
    }
}
catch {
    $exitCode = 1
    Write-Host $_.Exception.Message -ForegroundColor Red
}

Write-Host
if ($exitCode -eq 0 -and $Action -eq 'Apply') {
    Write-Host '[zh-TW] 補丁套用完成，可以啟動遊戲。'
    Write-Host '[en-US] Patch applied successfully. You can start the game.'
}
elseif ($exitCode -eq 0) {
    Write-Host '[zh-TW] 原始 DLL 已還原，可以啟動遊戲。'
    Write-Host '[en-US] Original DLL restored successfully. You can start the game.'
}
elseif ($Action -eq 'Apply') {
    Write-Host '[zh-TW] 補丁失敗。' -ForegroundColor Red
    Write-Host '[en-US] Patch failed.' -ForegroundColor Red
}
else {
    Write-Host '[zh-TW] 還原失敗。' -ForegroundColor Red
    Write-Host '[en-US] Restore failed.' -ForegroundColor Red
}

Write-Host
Write-Host '[zh-TW] 按任意鍵關閉此視窗。'
Write-Host '[en-US] Press any key to close this window.'
try {
    [void][Console]::ReadKey($true)
}
catch {
}

exit $exitCode
