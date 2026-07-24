[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GamePath,

    [ValidateRange(60, 86400)]
    [int]$StockRefreshSeconds = 1800,

    [ValidateRange(10, 3600)]
    [int]$TokenRetrySeconds = 60,

    [ValidateRange(1, 1000000)]
    [int]$ClickMultiplier = 1000,

    [switch]$DisableAutoBuy,

    [switch]$Restore
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Resolve-GamePath {
    param([string]$RequestedPath)

    if ($RequestedPath) {
        return (Resolve-Path -LiteralPath $RequestedPath).Path
    }

    $candidates = @(
        $PSScriptRoot,
        (Split-Path -Parent $PSScriptRoot)
    )

    foreach ($candidate in $candidates) {
        $assemblyPath = Join-Path $candidate 'BongoCat_Data\Managed\Assembly-CSharp.dll'
        if (Test-Path -LiteralPath $assemblyPath -PathType Leaf) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Cannot find the BongoCat game directory. Use -GamePath to specify it.'
}

function Get-SingleItem {
    param($Items, [string]$Description)

    $all = @($Items)
    if ($all.Count -ne 1) {
        throw "Expected one $Description, found $($all.Count). The game version may be unsupported."
    }
    return $all[0]
}

function Test-MethodCall {
    param($Instruction, [string]$DeclaringType, [string]$MethodName)

    if ($null -eq $Instruction -or $null -eq $Instruction.Operand) {
        return $false
    }

    $code = $Instruction.OpCode.Code
    if ($code -ne [dnlib.DotNet.Emit.Code]::Call -and
        $code -ne [dnlib.DotNet.Emit.Code]::Callvirt) {
        return $false
    }

    $called = $Instruction.Operand
    return ([string]$called.Name -eq $MethodName -and
        [string]$called.DeclaringType.FullName -eq $DeclaringType)
}

function Test-FieldInstruction {
    param($Instruction, $Field)

    return ($null -ne $Instruction -and
        $null -ne $Instruction.Operand -and
        [string]$Instruction.Operand -eq [string]$Field.FullName)
}

function Test-StringMarker {
    param($Method, [string]$Marker)

    return @($Method.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldstr -and
        [string]$_.Operand -eq $Marker
    }).Count -gt 0
}

function New-InstructionCopy {
    param($Instruction)

    if ($null -eq $Instruction.Operand) {
        return [dnlib.DotNet.Emit.Instruction]::new($Instruction.OpCode)
    }
    return [dnlib.DotNet.Emit.Instruction]::new($Instruction.OpCode, $Instruction.Operand)
}

function Find-AutoBuySite {
    param($Module, $ShopType, $ShopItemField)

    $candidates = @()
    $candidates += @($ShopType.Methods | Where-Object {
        $_.HasBody -and ($_.Name -eq 'ShowReadyChestPopup' -or $_.Name -eq 'TimerUpdate')
    })
    $candidates += @($Module.GetTypes() | Where-Object {
        $_.DeclaringType -eq $ShopType -and $_.Name -like '<TimerUpdate>*'
    } | ForEach-Object {
        $_.Methods | Where-Object { $_.HasBody -and $_.Name -eq 'MoveNext' }
    })

    foreach ($method in $candidates) {
        $instructions = $method.Body.Instructions
        for ($i = 2; $i -lt ($instructions.Count - 1); $i++) {
            if (-not (Test-MethodCall $instructions[$i] 'BongoCat.ShopItem' 'CanBuy')) {
                continue
            }
            if (-not (Test-FieldInstruction $instructions[$i - 1] $ShopItemField)) {
                continue
            }

            $branch = $instructions[$i + 1]
            if ($branch.OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Brfalse -and
                $branch.OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Brfalse_S) {
                continue
            }
            if ($null -eq $branch.Operand) {
                continue
            }

            $exitIndex = $instructions.IndexOf($branch.Operand)
            if ($exitIndex -le ($i + 1)) {
                continue
            }

            return [pscustomobject]@{
                Method = $method
                CanBuyIndex = $i
                ExitInstruction = $branch.Operand
                OwnerLoad = $instructions[$i - 2]
            }
        }
    }

    throw 'Could not find the CanBuy condition used by the chest popup timer. The game version may be unsupported.'
}

function Test-AutoBuyPatch {
    param($Site, $ShopItemField)

    $instructions = $Site.Method.Body.Instructions
    $exitIndex = $instructions.IndexOf($Site.ExitInstruction)
    if ($exitIndex -lt 3) {
        return $false
    }

    return ((Test-FieldInstruction $instructions[$exitIndex - 2] $ShopItemField) -and
        (Test-MethodCall $instructions[$exitIndex - 1] 'BongoCat.ShopItem' 'Buy'))
}

function Find-StockTokenRetrySite {
    param($Module, $ShopType, $StockTimeLeftField)

    $timerMoveNext = Get-SingleItem ($Module.GetTypes() | Where-Object {
        $_.DeclaringType -eq $ShopType -and $_.Name -like '<TimerUpdate>*'
    } | ForEach-Object {
        $_.Methods | Where-Object { $_.HasBody -and $_.Name -eq 'MoveNext' }
    }) 'Shop.TimerUpdate state machine MoveNext method'

    $instructions = $timerMoveNext.Body.Instructions
    for ($i = 0; $i -lt ($instructions.Count - 4); $i++) {
        if (-not (Test-MethodCall $instructions[$i] 'Heathen.SteamworksIntegration.ItemData' 'GetTotalQuantity')) {
            continue
        }

        $quantityResult = $instructions[$i + 1]
        $branch = $quantityResult
        $isBypassed = $false
        $bypassInstruction = $null
        if ($quantityResult.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Pop -and
            $instructions[$i + 2].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Br) {
            $bypassInstruction = $instructions[$i + 2]
            $branch = $bypassInstruction
            $isBypassed = $true
        }

        if ($branch.OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Brtrue -and
            $branch.OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Brtrue_S -and
            $branch.OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Br -and
            $branch.OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Br_S) {
            continue
        }
        if ($null -eq $branch.Operand) {
            continue
        }

        $retryOffset = if ($isBypassed) { 4 } else { 3 }
        if (-not $instructions[$i + $retryOffset].IsLdcI4() -or
            -not (Test-FieldInstruction $instructions[$i + $retryOffset + 1] $StockTimeLeftField)) {
            continue
        }

        return [pscustomobject]@{
            Method = $timerMoveNext
            QuantityInstruction = $instructions[$i]
            QuantityResultInstruction = $quantityResult
            BypassInstruction = $bypassInstruction
            ReadyInstruction = $branch.Operand
            RetryWaitInstruction = $instructions[$i + $retryOffset]
            IsBypassed = $isBypassed
        }
    }

    throw 'Could not find the stock-token retry branch in Shop.TimerUpdate. The game version may be unsupported.'
}

function Find-SteamFailureRetrySite {
    param($ShopType, $StockTimeLeftField)

    $method = Get-SingleItem ($ShopType.Methods | Where-Object {
        $_.Name -eq 'SetSuccessVisuals' -and $_.HasBody
    }) 'Shop.SetSuccessVisuals method'

    $matches = @()
    $instructions = $method.Body.Instructions
    for ($i = 1; $i -lt $instructions.Count; $i++) {
        if ($instructions[$i - 1].IsLdcI4() -and
            (Test-FieldInstruction $instructions[$i] $StockTimeLeftField)) {
            $matches += $instructions[$i - 1]
        }
    }

    $retryWaitInstruction = Get-SingleItem $matches 'Steam failure retry initializer in Shop.SetSuccessVisuals'
    return [pscustomobject]@{
        Method = $method
        RetryWaitInstruction = $retryWaitInstruction
        RetryWaitStoreInstruction = $instructions[$instructions.IndexOf($retryWaitInstruction) + 1]
    }
}

function Find-ChestExchangeRetrySite {
    param($Module)

    $chestExchanger = Get-SingleItem ($Module.GetTypes() | Where-Object {
        $_.FullName -eq 'Steam.ChestExchanger'
    }) 'Steam.ChestExchanger type'
    $openChest = Get-SingleItem ($chestExchanger.Methods | Where-Object {
        $_.Name -eq 'OpenChest' -and $_.HasBody
    }) 'Steam.ChestExchanger.OpenChest method'

    $instructions = $openChest.Body.Instructions
    $matches = @()
    for ($i = 1; $i -lt $instructions.Count; $i++) {
        if ($instructions[$i - 1].IsLdcI4() -and
            (Test-MethodCall $instructions[$i] 'Steam.ChestExchanger' 'ExchangeWhenReady')) {
            $matches += $instructions[$i - 1]
        }
    }

    return Get-SingleItem $matches 'initial chest exchange retry count'
}

function Find-TokenPollGate {
    param($TokenSite, $StockTimeLeftField)

    $instructions = $TokenSite.Method.Body.Instructions
    $quantityIndex = $instructions.IndexOf($TokenSite.QuantityInstruction)
    for ($i = $quantityIndex - 1; $i -ge [Math]::Max(3, $quantityIndex - 16); $i--) {
        $isOriginal = (($instructions[$i].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Bgt -or
                $instructions[$i].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Bgt_S) -and
            $instructions[$i - 1].IsLdcI4() -and
            (Test-FieldInstruction $instructions[$i - 2] $StockTimeLeftField))
        $isUnsafeBypass = (($instructions[$i].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Br -or
                $instructions[$i].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Br_S) -and
            $instructions[$i].Operand -eq $instructions[$i + 1] -and
            $instructions[$i - 1].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Nop -and
            $instructions[$i - 2].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Nop -and
            $instructions[$i - 3].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Nop)
        if (-not $isOriginal -and -not $isUnsafeBypass) {
            continue
        }

        return [pscustomobject]@{
            OwnerLoadInstruction = $instructions[$i - 3]
            TimeLoadInstruction = $instructions[$i - 2]
            ZeroInstruction = $instructions[$i - 1]
            BranchInstruction = $instructions[$i]
            TokenCheckInstruction = $instructions[$i + 1]
            IsUnsafeBypass = $isUnsafeBypass
        }
    }

    throw 'Could not find the countdown gate before the stock-token check.'
}

function Assert-GameIsClosed {
    $process = Get-Process -Name 'BongoCat' -ErrorAction SilentlyContinue
    if ($process) {
        throw 'BongoCat is running. Close the game before applying or restoring the patch.'
    }
}

$resolvedGamePath = Resolve-GamePath $GamePath
$targetDll = Join-Path $resolvedGamePath 'BongoCat_Data\Managed\Assembly-CSharp.dll'
$dnlibPath = Join-Path $PSScriptRoot 'lib\dnlib.dll'
$managedPath = Split-Path -Parent $targetDll
$backupPath = Join-Path $managedPath 'BongoCatPatcher.Backups'

if (-not (Test-Path -LiteralPath $targetDll -PathType Leaf)) {
    throw "Assembly not found: $targetDll"
}
if (-not (Test-Path -LiteralPath $dnlibPath -PathType Leaf)) {
    throw "dnlib is missing: $dnlibPath"
}

Assert-GameIsClosed

if (-not ('dnlib.DotNet.ModuleDefMD' -as [type])) {
    Add-Type -Path $dnlibPath
}

if ($Restore) {
    $restoreModule = [dnlib.DotNet.ModuleDefMD]::Load($targetDll)
    try {
        $restoreMvid = $restoreModule.Mvid.ToString('N')
    }
    finally {
        $restoreModule.Dispose()
    }

    $originalDll = Join-Path $backupPath "Assembly-CSharp.original.$restoreMvid.dll"
    if (-not (Test-Path -LiteralPath $originalDll -PathType Leaf)) {
        throw "No original backup matches this game version: $originalDll"
    }

    if ($PSCmdlet.ShouldProcess($targetDll, 'Restore the original Assembly-CSharp.dll')) {
        Copy-Item -LiteralPath $originalDll -Destination $targetDll -Force
        $restoredHash = (Get-FileHash -LiteralPath $targetDll -Algorithm SHA256).Hash
        Write-Host "Restored original DLL. SHA-256: $restoredHash"
    }
    return
}

$module = [dnlib.DotNet.ModuleDefMD]::Load($targetDll)
$tempDll = Join-Path $managedPath 'Assembly-CSharp.dll.bongocatpatcher.tmp'
$changes = @()

try {
    $shop = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'BongoCat.Shop') 'BongoCat.Shop type'
    $pets = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'BongoCat.Pets') 'BongoCat.Pets type'
    $shopItemField = Get-SingleItem ($shop.Fields | Where-Object Name -eq '_shopItem') 'Shop._shopItem field'
    $stockField = Get-SingleItem ($shop.Fields | Where-Object Name -eq '_stockRefreshTime') 'Shop._stockRefreshTime field'
    $stockTimeLeftField = Get-SingleItem ($shop.Fields | Where-Object Name -eq 'StockRefreshTimeLeft') 'Shop.StockRefreshTimeLeft field'
    $buyMethod = Get-SingleItem (($module.GetTypes() | Where-Object FullName -eq 'BongoCat.ShopItem').Methods | Where-Object {
        $_.Name -eq 'Buy' -and $_.Parameters.Count -eq 1
    }) 'ShopItem.Buy method'
    $shopItem = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'BongoCat.ShopItem') 'BongoCat.ShopItem type'
    $waitingForServerField = Get-SingleItem ($shopItem.Fields | Where-Object Name -eq '_waitingForServer') 'ShopItem._waitingForServer field'
    $normalShopField = Get-SingleItem ($shop.Fields | Where-Object Name -eq 'NormalShop') 'Shop.NormalShop field'
    $emoteShopField = Get-SingleItem ($shop.Fields | Where-Object Name -eq 'EmoteShop') 'Shop.EmoteShop field'
    $steamInventory = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'SteamTools.Game/Inventory') 'SteamTools.Game.Inventory type'
    $chestTokenField = Get-SingleItem ($steamInventory.Fields | Where-Object Name -eq 'Chest_Token') 'Inventory.Chest_Token field'
    $emoteChestTokenField = Get-SingleItem ($steamInventory.Fields | Where-Object Name -eq 'Emote_Chest_Token') 'Inventory.Emote_Chest_Token field'
    $unityLogMethod = Get-SingleItem ($module.GetMemberRefs() | Where-Object {
        $_.Name -eq 'Log' -and
        $_.DeclaringType.FullName -eq 'UnityEngine.Debug' -and
        $_.MethodSig.Params.Count -eq 1 -and
        $_.MethodSig.Params[0].FullName -eq 'System.Object'
    }) 'UnityEngine.Debug.Log(object) method reference'
    $getTotalQuantityMethod = Get-SingleItem ($module.GetMemberRefs() | Where-Object {
        $_.Name -eq 'GetTotalQuantity' -and
        $_.DeclaringType.FullName -eq 'Heathen.SteamworksIntegration.ItemData'
    }) 'ItemData.GetTotalQuantity method reference'

    $shopConstructor = Get-SingleItem ($shop.Methods | Where-Object {
        $_.Name -eq '.ctor' -and $_.HasBody
    }) 'Shop constructor'
    $constructorInstructions = $shopConstructor.Body.Instructions
    $stockStoreIndex = -1
    for ($i = 1; $i -lt $constructorInstructions.Count; $i++) {
        if (Test-FieldInstruction $constructorInstructions[$i] $stockField) {
            $stockStoreIndex = $i
            break
        }
    }
    if ($stockStoreIndex -lt 1 -or -not $constructorInstructions[$stockStoreIndex - 1].IsLdcI4()) {
        throw 'Could not find the integer initializer for Shop._stockRefreshTime.'
    }
    $stockValueInstruction = $constructorInstructions[$stockStoreIndex - 1]
    $oldStockValue = $stockValueInstruction.GetLdcI4Value()
    if ($oldStockValue -ne $StockRefreshSeconds) {
        $stockValueInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4
        $stockValueInstruction.Operand = [int]$StockRefreshSeconds
        $changes += "Stock refresh: $oldStockValue -> $StockRefreshSeconds seconds"
    }

    $addPet = Get-SingleItem ($pets.Methods | Where-Object {
        $_.Name -eq 'AddPet' -and $_.HasBody -and $_.Parameters.Count -eq 2
    }) 'Pets.AddPet(int) method'
    $valueParameter = Get-SingleItem ($addPet.Parameters | Where-Object {
        -not $_.IsHiddenThisParameter -and $_.Type.FullName -eq 'System.Int32'
    }) 'AddPet value parameter'
    $petInstructions = $addPet.Body.Instructions
    $hasMultiplierPatch = ($petInstructions.Count -ge 4 -and
        $petInstructions[0].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldarg_1 -and
        $petInstructions[1].IsLdcI4() -and
        $petInstructions[2].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Mul -and
        ($petInstructions[3].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Starg -or
            $petInstructions[3].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Starg_S) -and
        $petInstructions[3].Operand -eq $valueParameter)

    if ($hasMultiplierPatch) {
        $oldMultiplier = $petInstructions[1].GetLdcI4Value()
        if ($ClickMultiplier -eq 1) {
            for ($i = 0; $i -lt 4; $i++) {
                $petInstructions.RemoveAt(0)
            }
            $changes += "Click multiplier: removed x$oldMultiplier"
        }
        elseif ($oldMultiplier -ne $ClickMultiplier) {
            $petInstructions[1].OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4
            $petInstructions[1].Operand = [int]$ClickMultiplier
            $changes += "Click multiplier: x$oldMultiplier -> x$ClickMultiplier"
        }
    }
    elseif ($ClickMultiplier -ne 1) {
        $petInstructions.Insert(0, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Starg, $valueParameter))
        $petInstructions.Insert(0, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Mul))
        $petInstructions.Insert(0, [dnlib.DotNet.Emit.Instruction]::CreateLdcI4($ClickMultiplier))
        $petInstructions.Insert(0, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_1))
        $changes += "Click multiplier: x1 -> x$ClickMultiplier"
    }

    $autoBuySite = Find-AutoBuySite $module $shop $shopItemField
    $hasAutoBuyPatch = Test-AutoBuyPatch $autoBuySite $shopItemField
    $autoInstructions = $autoBuySite.Method.Body.Instructions
    $exitIndex = $autoInstructions.IndexOf($autoBuySite.ExitInstruction)

    if ($DisableAutoBuy -and $hasAutoBuyPatch) {
        $autoInstructions.RemoveAt($exitIndex - 1)
        $autoInstructions.RemoveAt($exitIndex - 2)
        $autoInstructions.RemoveAt($exitIndex - 3)
        $changes += 'Automatic chest purchase: disabled'
    }
    elseif (-not $DisableAutoBuy -and -not $hasAutoBuyPatch) {
        $ownerLoad = New-InstructionCopy $autoBuySite.OwnerLoad
        $autoInstructions.Insert($exitIndex, $ownerLoad)
        $autoInstructions.Insert($exitIndex + 1, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $shopItemField))
        $autoInstructions.Insert($exitIndex + 2, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $buyMethod))
        $changes += "Automatic chest purchase: enabled in $($autoBuySite.Method.Name)"
    }

    $stockTokenRetrySite = Find-StockTokenRetrySite $module $shop $stockTimeLeftField
    $oldRetryWait = $stockTokenRetrySite.RetryWaitInstruction.GetLdcI4Value()
    if ($oldRetryWait -ne $TokenRetrySeconds) {
        $stockTokenRetrySite.RetryWaitInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4
        $stockTokenRetrySite.RetryWaitInstruction.Operand = [int]$TokenRetrySeconds
        $changes += "Stock-token retry wait: $oldRetryWait -> $TokenRetrySeconds seconds"
    }
    if ($stockTokenRetrySite.IsBypassed) {
        $tokenInstructions = $stockTokenRetrySite.Method.Body.Instructions
        $stockTokenRetrySite.QuantityResultInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Brtrue
        $stockTokenRetrySite.QuantityResultInstruction.Operand = $stockTokenRetrySite.ReadyInstruction
        $tokenInstructions.Remove($stockTokenRetrySite.BypassInstruction) | Out-Null
        $changes += "Stock-token check: restored in $($stockTokenRetrySite.Method.Name)"
    }

    $pollMarker = '[BongoCatPatcher] TOKEN DETECTED: chest token is present; starting immediate claim.'
    $pollGate = Find-TokenPollGate $stockTokenRetrySite $stockTimeLeftField
    if ($pollGate.IsUnsafeBypass) {
        $retryStoreIndex = $stockTokenRetrySite.Method.Body.Instructions.IndexOf($stockTokenRetrySite.RetryWaitInstruction) + 1
        $retryExitBranch = $stockTokenRetrySite.Method.Body.Instructions[$retryStoreIndex + 1]
        $ownerLoad = New-InstructionCopy $pollGate.TokenCheckInstruction

        $pollGate.OwnerLoadInstruction.OpCode = $ownerLoad.OpCode
        $pollGate.OwnerLoadInstruction.Operand = $ownerLoad.Operand
        $pollGate.TimeLoadInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldfld
        $pollGate.TimeLoadInstruction.Operand = $stockTimeLeftField
        $pollGate.ZeroInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0
        $pollGate.ZeroInstruction.Operand = $null
        $pollGate.BranchInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Bgt
        $pollGate.BranchInstruction.Operand = $retryExitBranch.Operand
        $changes += 'Chest claim debounce: restored countdown gate to prevent stale-token duplicate exchanges'
    }
    if (-not (Test-StringMarker $stockTokenRetrySite.Method $pollMarker)) {
        $readyInstruction = $stockTokenRetrySite.ReadyInstruction
        $readyIndex = $stockTokenRetrySite.Method.Body.Instructions.IndexOf($readyInstruction)
        $readyLog = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr, $pollMarker)
        $stockTokenRetrySite.Method.Body.Instructions.Insert($readyIndex, $readyLog)
        $stockTokenRetrySite.Method.Body.Instructions.Insert($readyIndex + 1,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod))
        $stockTokenRetrySite.QuantityResultInstruction.Operand = $readyLog
        $changes += 'Token-driven chest claim: token callbacks trigger an immediate, single exchange'
    }

    $steamFailureRetrySite = Find-SteamFailureRetrySite $shop $stockTimeLeftField
    $oldSteamFailureWait = $steamFailureRetrySite.RetryWaitInstruction.GetLdcI4Value()
    if ($oldSteamFailureWait -ne $TokenRetrySeconds) {
        $steamFailureRetrySite.RetryWaitInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4
        $steamFailureRetrySite.RetryWaitInstruction.Operand = [int]$TokenRetrySeconds
        $changes += "Steam failure retry wait: $oldSteamFailureWait -> $TokenRetrySeconds seconds"
    }

    $getAllItemsMethod = Get-SingleItem ($module.GetMemberRefs() | Where-Object {
        $_.Name -eq 'GetAllItems' -and
        $_.DeclaringType.FullName -eq 'Heathen.SteamworksIntegration.API.Inventory/Client'
    }) 'Steam inventory GetAllItems method reference'
    $failureInstructions = $steamFailureRetrySite.Method.Body.Instructions
    $failureStoreIndex = $failureInstructions.IndexOf($steamFailureRetrySite.RetryWaitStoreInstruction)
    $hasFailureRefresh = ($failureStoreIndex -ge 0 -and
        $failureStoreIndex + 2 -lt $failureInstructions.Count -and
        $failureInstructions[$failureStoreIndex + 1].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldnull -and
        (Test-MethodCall $failureInstructions[$failureStoreIndex + 2] 'Heathen.SteamworksIntegration.API.Inventory/Client' 'GetAllItems'))
    if (-not $hasFailureRefresh) {
        $failureInstructions.Insert($failureStoreIndex + 1,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldnull))
        $failureInstructions.Insert($failureStoreIndex + 2,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $getAllItemsMethod))
        $changes += 'Steam inventory refresh after a failed chest exchange: enabled'
    }

    $playtimeDropClosure = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'BongoCat.PlaytimeItemDrop/<>c') 'PlaytimeItemDrop closure type'
    $dropCallback = Get-SingleItem ($playtimeDropClosure.Methods | Where-Object {
        $_.Name -eq '<Start>b__1_1' -and $_.HasBody
    }) 'Playtime token-drop callback'
    $dropCallbackMarker = '[BongoCatPatcher] DROP CALLBACK: Steam finished a token-drop request.'
    if (-not (Test-StringMarker $dropCallback $dropCallbackMarker)) {
        $dropInstructions = $dropCallback.Body.Instructions
        $returnInstruction = $dropInstructions[$dropInstructions.Count - 1]
        $normalTokenLog = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr,
            '[BongoCatPatcher] TOKEN RECEIVED: normal chest token is in inventory.')
        $emoteTokenLog = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr,
            '[BongoCatPatcher] TOKEN RECEIVED: emote chest token is in inventory.')
        $noTokenLog = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr,
            '[BongoCatPatcher] NO TOKEN: drop request completed without a chest token; inventory refresh requested.')
        $refreshInstruction = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldnull)

        $newInstructions = @(
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr, $dropCallbackMarker),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsflda, $chestTokenField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $getTotalQuantityMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_I8),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Bgt, $normalTokenLog),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsflda, $emoteChestTokenField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $getTotalQuantityMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_I8),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Bgt, $emoteTokenLog),
            $noTokenLog,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Br, $refreshInstruction),
            $normalTokenLog,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $normalShopField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse, $refreshInstruction),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $normalShopField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $stockTimeLeftField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Br, $refreshInstruction),
            $emoteTokenLog,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $emoteShopField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse, $refreshInstruction),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $emoteShopField),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $stockTimeLeftField),
            $refreshInstruction,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $getAllItemsMethod)
        )
        $returnIndex = $dropInstructions.IndexOf($returnInstruction)
        for ($i = 0; $i -lt $newInstructions.Count; $i++) {
            $dropInstructions.Insert($returnIndex + $i, $newInstructions[$i])
        }
        $changes += 'Token-drop callback: immediate claim trigger and receipt/no-token logs enabled'
    }

    $startBuy = Get-SingleItem ($shopItem.Methods | Where-Object {
        $_.Name -eq 'StartBuy' -and $_.HasBody
    }) 'ShopItem.StartBuy method'
    $claimStartMarker = '[BongoCatPatcher] CLAIM START: submitting chest exchange to Steam.'
    $startBuyInstructions = $startBuy.Body.Instructions
    $startMarkerInstruction = @($startBuyInstructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldstr -and $_.Operand -eq $claimStartMarker
    }) | Select-Object -First 1
    $waitingStore = @($startBuyInstructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Stfld -and
        (Test-FieldInstruction $_ $waitingForServerField)
    }) | Select-Object -First 1
    if ($null -eq $waitingStore) {
        throw 'Could not find the ShopItem._waitingForServer guard assignment.'
    }
    $waitingStoreIndex = $startBuyInstructions.IndexOf($waitingStore)
    $markerIsAfterGuard = ($null -ne $startMarkerInstruction -and
        $startBuyInstructions.IndexOf($startMarkerInstruction) -eq ($waitingStoreIndex + 1))
    if (-not $markerIsAfterGuard) {
        if ($null -ne $startMarkerInstruction) {
            $markerIndex = $startBuyInstructions.IndexOf($startMarkerInstruction)
            if ($markerIndex + 1 -lt $startBuyInstructions.Count -and
                (Test-MethodCall $startBuyInstructions[$markerIndex + 1] 'UnityEngine.Debug' 'Log')) {
                $startBuyInstructions.RemoveAt($markerIndex + 1)
            }
            $startBuyInstructions.Remove($startMarkerInstruction) | Out-Null
        }
        $waitingStoreIndex = $startBuyInstructions.IndexOf($waitingStore)
        $startBuyInstructions.Insert($waitingStoreIndex + 1,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr, $claimStartMarker))
        $startBuyInstructions.Insert($waitingStoreIndex + 2,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod))
        $changes += 'Chest claim start log: moved after the duplicate-request guard'
    }

    $claimCallback = Get-SingleItem ($shopItem.Methods | Where-Object {
        $_.Name -eq 'Callback' -and $_.HasBody
    }) 'ShopItem.Callback method'
    $claimSuccessMarker = '[BongoCatPatcher] CLAIM SUCCESS: Steam exchanged the token and granted the chest item.'
    if (-not (Test-StringMarker $claimCallback $claimSuccessMarker)) {
        $callbackInstructions = $claimCallback.Body.Instructions
        $originalFirst = $callbackInstructions[0]
        $successLog = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr, $claimSuccessMarker)
        $callbackPrefix = @(
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_1),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_M1),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Bne_Un, $successLog),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr,
                '[BongoCatPatcher] CLAIM FAILED: Steam rejected the exchange; inventory will refresh and retry when a token is visible.'),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod),
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Br, $originalFirst),
            $successLog,
            [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $unityLogMethod)
        )
        for ($i = 0; $i -lt $callbackPrefix.Count; $i++) {
            $callbackInstructions.Insert($i, $callbackPrefix[$i])
        }
        $changes += 'Chest claim result logs: success and failure enabled'
    }

    $exchangeRetryInstruction = Find-ChestExchangeRetrySite $module
    $oldExchangeRetries = $exchangeRetryInstruction.GetLdcI4Value()
    if ($oldExchangeRetries -ne 0) {
        $exchangeRetryInstruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0
        $exchangeRetryInstruction.Operand = $null
        $changes += "Immediate chest exchange retries: $oldExchangeRetries -> 0"
    }

    if ($changes.Count -eq 0) {
        Write-Host 'No changes needed; the requested settings are already applied.'
        return
    }

    Write-Host 'Planned changes:'
    foreach ($change in $changes) {
        Write-Host "  - $change"
    }

    if (-not $PSCmdlet.ShouldProcess($targetDll, 'Patch Assembly-CSharp.dll')) {
        return
    }

    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null
    $mvid = $module.Mvid.ToString('N')
    $originalDll = Join-Path $backupPath "Assembly-CSharp.original.$mvid.dll"
    if (-not (Test-Path -LiteralPath $originalDll -PathType Leaf)) {
        Copy-Item -LiteralPath $targetDll -Destination $originalDll
    }

    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $currentHash = (Get-FileHash -LiteralPath $targetDll -Algorithm SHA256).Hash
    $historyDll = Join-Path $backupPath "Assembly-CSharp.prepatch.$timestamp.$($currentHash.Substring(0, 12)).dll"
    Copy-Item -LiteralPath $targetDll -Destination $historyDll

    if (Test-Path -LiteralPath $tempDll) {
        Remove-Item -LiteralPath $tempDll -Force
    }
    $stockTokenRetrySite.Method.Body.SimplifyBranches()
    $module.Write($tempDll)
}
finally {
    $module.Dispose()
}

try {
    $verificationModule = [dnlib.DotNet.ModuleDefMD]::Load($tempDll)
    $verificationModule.Dispose()
    Copy-Item -LiteralPath $tempDll -Destination $targetDll -Force
}
finally {
    if (Test-Path -LiteralPath $tempDll) {
        Remove-Item -LiteralPath $tempDll -Force
    }
}

$newHash = (Get-FileHash -LiteralPath $targetDll -Algorithm SHA256).Hash
Write-Host "Patch complete. SHA-256: $newHash"
Write-Host "Original backup: $originalDll"
