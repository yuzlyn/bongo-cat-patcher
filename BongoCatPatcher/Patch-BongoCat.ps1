[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GamePath,

    [ValidateRange(60, 86400)]
    [int]$StockRefreshSeconds = 300,

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
    $buyMethod = Get-SingleItem (($module.GetTypes() | Where-Object FullName -eq 'BongoCat.ShopItem').Methods | Where-Object {
        $_.Name -eq 'Buy' -and $_.Parameters.Count -eq 1
    }) 'ShopItem.Buy method'

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
