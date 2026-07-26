[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$GamePath,

    [ValidateRange(1, 1000000)]
    [int]$ClickMultiplier = 1000,

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

function Get-TimerUpdateMethod {
    param($Module, $ShopType)

    return Get-SingleItem ($Module.GetTypes() | Where-Object {
        $_.DeclaringType -eq $ShopType -and $_.Name -like '<TimerUpdate>*'
    } | ForEach-Object {
        $_.Methods | Where-Object { $_.HasBody -and $_.Name -eq 'MoveNext' }
    }) 'Shop.TimerUpdate state-machine MoveNext method'
}

function Remove-LegacyPopupAutoBuy {
    param($ShopType, $ShopItemField, $BuyMethod)

    $popup = Get-SingleItem ($ShopType.Methods | Where-Object {
        $_.HasBody -and $_.Name -eq 'ShowReadyChestPopup'
    }) 'Shop.ShowReadyChestPopup method'
    $instructions = $popup.Body.Instructions

    for ($i = 2; $i -lt $instructions.Count; $i++) {
        if ((Test-FieldInstruction $instructions[$i - 1] $ShopItemField) -and
            (Test-MethodCall $instructions[$i] 'BongoCat.ShopItem' 'Buy')) {
            $instructions.RemoveAt($i)
            $instructions.RemoveAt($i - 1)
            $instructions.RemoveAt($i - 2)
            return $true
        }
    }
    return $false
}

function Find-TokenReadySite {
    param($TimerMethod, $ChestReadyField, $ShowReadyMethod)

    $instructions = $TimerMethod.Body.Instructions
    for ($i = 1; $i -lt ($instructions.Count - 1); $i++) {
        if (-not (Test-FieldInstruction $instructions[$i] $ChestReadyField)) {
            continue
        }
        for ($j = $i + 1; $j -lt [Math]::Min($i + 6, $instructions.Count); $j++) {
            if (Test-MethodCall $instructions[$j] 'BongoCat.Shop' 'ShowReadyChestPopup') {
                return $j
            }
        }
    }

    throw 'Could not find the Steam-token-ready event in Shop.TimerUpdate. The game version may be unsupported.'
}

function Test-TokenReadyAutoBuyPatch {
    param($TimerMethod, [int]$InsertIndex, $ShopItemField, $AutoClaimMethod)

    $instructions = $TimerMethod.Body.Instructions
    if ($InsertIndex -lt 3) {
        return $false
    }
    return ((Test-FieldInstruction $instructions[$InsertIndex - 2] $ShopItemField) -and
        $instructions[$InsertIndex - 1].Operand -eq $AutoClaimMethod)
}

function Add-AutoClaimMethod {
    param($Module, $ShopItemType, $BuyMethod)

    $existing = @($ShopItemType.Methods | Where-Object Name -eq 'TryAutoClaimWhenReady')
    if ($existing.Count -eq 1) {
        return [pscustomobject]@{ Method = $existing[0]; Changed = $false }
    }
    if ($existing.Count -ne 0) {
        throw "Expected at most one ShopItem.TryAutoClaimWhenReady method, found $($existing.Count)."
    }

    $startBuy = Get-SingleItem ($ShopItemType.Methods | Where-Object {
        $_.Name -eq 'StartBuy' -and $_.HasBody
    }) 'ShopItem.StartBuy method'
    $waitingField = Get-SingleItem ($ShopItemType.Fields | Where-Object Name -eq '_waitingForServer') 'ShopItem._waitingForServer field'
    $priceField = Get-SingleItem ($ShopItemType.Fields | Where-Object Name -eq '_price') 'ShopItem._price field'
    $petsType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.Pets') 'BongoCat.Pets type'
    $petsInstance = Get-SingleItem ($petsType.Fields | Where-Object Name -eq 'Instance') 'Pets.Instance field'
    $canSpendPets = Get-SingleItem ($startBuy.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'BongoCat.Pets' 'CanSpendPets'
    } | ForEach-Object Operand) 'Pets.CanSpendPets reference'
    $debugLog = @($Module.GetTypes() | ForEach-Object Methods | Where-Object HasBody | ForEach-Object {
        $_.Body.Instructions | Where-Object {
            [string]$_.Operand -eq 'System.Void UnityEngine.Debug::Log(System.Object)'
        } | ForEach-Object Operand
    })[0]
    if ($null -eq $debugLog) {
        throw 'Could not find UnityEngine.Debug.Log(object). The game version may be unsupported.'
    }

    $signature = [dnlib.DotNet.MethodSig]::CreateInstance($Module.CorLibTypes.Void)
    $method = [dnlib.DotNet.MethodDefUser]::new('TryAutoClaimWhenReady', $signature)
    $method.Attributes = [dnlib.DotNet.MethodAttributes](
        [int][dnlib.DotNet.MethodAttributes]::Public -bor
        [int][dnlib.DotNet.MethodAttributes]::HideBySig
    )
    $method.Body = [dnlib.DotNet.Emit.CilBody]::new()
    $ret = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret)
    $body = $method.Body.Instructions
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $waitingField))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brtrue_S, $ret))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $petsInstance))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $priceField))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $canSpendPets))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse_S, $ret))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldstr, '[BongoCatPatcher] Chest token and payment ready; starting automatic exchange.'))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $debugLog))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $body.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $BuyMethod))
    $body.Add($ret)
    $ShopItemType.Methods.Add($method)
    return [pscustomobject]@{ Method = $method; Changed = $true }
}

function Set-Int32FieldInitializer {
    param($Type, $Field, [int]$Value, [string]$Description)

    $constructor = Get-SingleItem ($Type.Methods | Where-Object {
        $_.IsConstructor -and $_.HasBody
    }) "$Description constructor"
    $instructions = $constructor.Body.Instructions
    for ($i = 1; $i -lt $instructions.Count; $i++) {
        if ((Test-FieldInstruction $instructions[$i] $Field) -and $instructions[$i - 1].IsLdcI4()) {
            $oldValue = $instructions[$i - 1].GetLdcI4Value()
            $instructions[$i - 1].OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4
            $instructions[$i - 1].Operand = $Value
            return $oldValue
        }
    }
    throw "Could not find $Description initializer. The game version may be unsupported."
}

function Set-TokenMissingDelay {
    param($TimerMethod, $StockRefreshTimeLeftField, $StockRefreshTimeField)

    $instructions = $TimerMethod.Body.Instructions
    for ($i = 1; $i -lt $instructions.Count; $i++) {
        if (-not (Test-FieldInstruction $instructions[$i] $StockRefreshTimeLeftField)) {
            continue
        }
        if ($instructions[$i - 1].IsLdcI4()) {
            $oldValue = $instructions[$i - 1].GetLdcI4Value()
            if ($oldValue -eq 0) {
                return $false
            }
            if ($oldValue -eq 60) {
                $instructions[$i - 1] = [dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0)
                return $true
            }
        }
        elseif ((Test-FieldInstruction $instructions[$i - 1] $StockRefreshTimeField) -and
            $i -ge 2 -and $instructions[$i - 2].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldloc_1) {
            # Upgrade the previous patch, which postponed a missing token for
            # another full interval and could miss a just-arrived token.
            $instructions.RemoveAt($i - 1)
            $instructions.RemoveAt($i - 2)
            $instructions.Insert($i - 2, [dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0))
            return $true
        }
    }
    return $false
}

function Set-ExchangeFailureDelay {
    param($ShopType, $StockRefreshTimeLeftField, $StockRefreshTimeField)

    $failureVisuals = Get-SingleItem ($ShopType.Methods | Where-Object {
        $_.Name -eq 'SetSuccessVisuals' -and $_.HasBody
    }) 'Shop.SetSuccessVisuals method'
    $instructions = $failureVisuals.Body.Instructions
    for ($i = 1; $i -lt $instructions.Count; $i++) {
        if (-not (Test-FieldInstruction $instructions[$i] $StockRefreshTimeLeftField)) {
            continue
        }
        if ($instructions[$i - 1].IsLdcI4()) {
            $oldValue = $instructions[$i - 1].GetLdcI4Value()
            if ($oldValue -eq 0) {
                return $false
            }
            if ($oldValue -eq 60) {
                $instructions[$i - 1] = [dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0)
                return $true
            }
        }
        elseif ((Test-FieldInstruction $instructions[$i - 1] $StockRefreshTimeField) -and
            $i -ge 2 -and $instructions[$i - 2].OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldarg_0) {
            $instructions.RemoveAt($i - 1)
            $instructions.RemoveAt($i - 2)
            $instructions.Insert($i - 2, [dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0))
            return $true
        }
    }
    return $false
}

function Set-PlaytimeDropInterval {
    param($Module, [int]$IntervalMilliseconds)

    $dropType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.PlaytimeItemDrop') 'BongoCat.PlaytimeItemDrop type'
    $start = Get-SingleItem ($dropType.Methods | Where-Object { $_.Name -eq 'Start' -and $_.HasBody }) 'PlaytimeItemDrop.Start method'
    $oneMinuteCount = 0
    $fifteenMinuteCount = 0
    foreach ($instruction in $start.Body.Instructions) {
        if ($instruction.IsLdcI4() -and $instruction.GetLdcI4Value() -eq 60000) {
            $instruction.OpCode = [dnlib.DotNet.Emit.OpCodes]::Ldc_I4
            $instruction.Operand = $IntervalMilliseconds
            $oneMinuteCount++
        }
        elseif ($instruction.IsLdcI4() -and $instruction.GetLdcI4Value() -eq $IntervalMilliseconds) {
            $fifteenMinuteCount++
        }
    }
    if ($oneMinuteCount -eq 2) {
        return [pscustomobject]@{ Type = $dropType; Changed = $true }
    }
    if ($oneMinuteCount -eq 0 -and $fifteenMinuteCount -eq 2) {
        return [pscustomobject]@{ Type = $dropType; Changed = $false }
    }
    throw "Expected two matching playtime-drop intervals, found $oneMinuteCount one-minute and $fifteenMinuteCount fifteen-minute values. The game version may be unsupported."
}

function Add-TokenDropListener {
    param($Module, $DropType, $ShopType, $StockRefreshTimeLeftField)

    $listenerType = Get-SingleItem ($Module.GetTypes() | Where-Object {
        $_.DeclaringType -eq $DropType -and $_.Name -eq '<>c'
    }) 'PlaytimeItemDrop callback type'
    $listener = Get-SingleItem ($listenerType.Methods | Where-Object {
        $_.Name -eq '<Start>b__1_1' -and $_.HasBody
    }) 'PlaytimeItemDrop token callback'
    if ($listener.Body.Instructions | Where-Object { Test-FieldInstruction $_ $StockRefreshTimeLeftField }) {
        return $false
    }
    if ($listener.Body.Instructions.Count -ne 1 -or $listener.Body.Instructions[0].OpCode.Code -ne [dnlib.DotNet.Emit.Code]::Ret) {
        throw 'The playtime-drop token callback has already been modified or is unsupported.'
    }

    $normalShop = Get-SingleItem ($ShopType.Fields | Where-Object { $_.Name -eq 'NormalShop' }) 'Shop.NormalShop field'
    $emoteShop = Get-SingleItem ($ShopType.Fields | Where-Object { $_.Name -eq 'EmoteShop' }) 'Shop.EmoteShop field'
    $ret = $listener.Body.Instructions[0]
    $skipNormal = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $skipEmote = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $body = $listener.Body.Instructions
    $body.Insert(0, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $normalShop))
    $body.Insert(1, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse_S, $skipNormal))
    $body.Insert(2, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $normalShop))
    $body.Insert(3, [dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0))
    $body.Insert(4, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $StockRefreshTimeLeftField))
    $body.Insert(5, $skipNormal)
    $body.Insert(6, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $emoteShop))
    $body.Insert(7, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse_S, $skipEmote))
    $body.Insert(8, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldsfld, $emoteShop))
    $body.Insert(9, [dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0))
    $body.Insert(10, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $StockRefreshTimeLeftField))
    $body.Insert(11, $skipEmote)
    return $true
}

function Set-MultiplayerEdgePositioning {
    param($Module)

    $member = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.Multiplayer.LobbyMemberInstance') 'BongoCat.Multiplayer.LobbyMemberInstance type'
    $reparent = Get-SingleItem ($member.Methods | Where-Object { $_.Name -eq 'ReparentAndPositionCat' -and $_.HasBody -and $_.Parameters.Count -eq 2 }) 'LobbyMemberInstance.ReparentAndPositionCat method'
    $position = Get-SingleItem ($member.Methods | Where-Object { $_.Name -eq 'PositionCatRandomly' -and $_.HasBody -and $_.Parameters.Count -eq 1 }) 'LobbyMemberInstance.PositionCatRandomly method'

    $catField = Get-SingleItem ($member.Fields | Where-Object Name -eq 'cat') 'LobbyMemberInstance.cat field'
    $draggableField = Get-SingleItem ($member.Fields | Where-Object Name -eq '_draggable') 'LobbyMemberInstance._draggable field'
    $draggableType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.Draggable') 'BongoCat.Draggable type'
    $rotatorField = Get-SingleItem ($draggableType.Fields | Where-Object Name -eq '_catRotator') 'Draggable._catRotator field'
    $rotatorType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'CatRotator') 'CatRotator type'
    $rotationStateField = Get-SingleItem ($rotatorType.Fields | Where-Object Name -eq '_rotationState') 'CatRotator._rotationState field'
    $rotatorTransformField = Get-SingleItem ($rotatorType.Fields | Where-Object Name -eq '_catTransform') 'CatRotator._catTransform field'
    $accessMask = [int][dnlib.DotNet.FieldAttributes]::FieldAccessMask
    foreach ($field in @($rotatorField, $rotationStateField, $rotatorTransformField)) {
        $attributes = ([int]$field.Attributes -band (-bnot $accessMask)) -bor [int][dnlib.DotNet.FieldAttributes]::Public
        $field.Attributes = [dnlib.DotNet.FieldAttributes]$attributes
    }
    $draggableType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.Draggable') 'BongoCat.Draggable type'
    $rotatorField = Get-SingleItem ($draggableType.Fields | Where-Object Name -eq '_catRotator') 'Draggable._catRotator field'
    $rotatorType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'CatRotator') 'CatRotator type'
    $rotationStateField = Get-SingleItem ($rotatorType.Fields | Where-Object Name -eq '_rotationState') 'CatRotator._rotationState field'
    $rotatorTransformField = Get-SingleItem ($rotatorType.Fields | Where-Object Name -eq '_catTransform') 'CatRotator._catTransform field'
    if ($position.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Stfld -and [string]$_.Operand -eq [string]$rotationStateField
    }) {
        return $false
    }
    $getTransform = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Component' 'get_transform'
    } | ForEach-Object Operand) 'UnityEngine.Component.get_transform reference'
    $setPosition = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'set_position'
    } | ForEach-Object Operand) 'UnityEngine.Transform.set_position reference'
    $fetchRelativePos = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'BongoCat.Draggable' 'FetchRelativePos'
    } | ForEach-Object Operand) 'Draggable.FetchRelativePos reference'
    $screenInfo = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Screen' 'get_mainWindowDisplayInfo'
    } | ForEach-Object Operand) 'Screen.get_mainWindowDisplayInfo reference'
    $randomRange = @($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Random' 'Range' -and
        [string]$_.Operand -eq 'System.Int32 UnityEngine.Random::Range(System.Int32,System.Int32)'
    } | ForEach-Object Operand)[0]
    if ($null -eq $randomRange) {
        throw 'Could not find UnityEngine.Random.Range(int, int). The game version may be unsupported.'
    }
    $vector3Ctor = Get-SingleItem ($position.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Newobj -and
        [string]$_.Operand -eq 'System.Void UnityEngine.Vector3::.ctor(System.Single,System.Single,System.Single)'
    } | ForEach-Object Operand) 'UnityEngine.Vector3(float, float, float) constructor reference'
    $quaternionEuler = Get-SingleItem (($rotatorType.Methods | Where-Object { $_.Name -eq 'Start' }).Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Quaternion' 'Euler'
    } | ForEach-Object Operand) 'UnityEngine.Quaternion.Euler reference'
    $setLocalRotation = Get-SingleItem (($rotatorType.Methods | Where-Object { $_.Name -eq 'Start' }).Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'set_localRotation'
    } | ForEach-Object Operand) 'UnityEngine.Transform.set_localRotation reference'
    $workArea = @($position.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldflda -and
        [string]$_.Operand -eq 'UnityEngine.RectInt UnityEngine.DisplayInfo::workArea'
    } | ForEach-Object Operand)[0]
    if ($null -eq $workArea) {
        throw 'Could not find DisplayInfo.workArea. The game version may be unsupported.'
    }

    $rectCalls = @{}
    foreach ($name in @('get_xMin', 'get_xMax', 'get_yMin', 'get_yMax')) {
        $rectCalls[$name] = Get-SingleItem ($position.Body.Instructions | Where-Object {
            Test-MethodCall $_ 'UnityEngine.RectInt' $name
        } | ForEach-Object Operand) "UnityEngine.RectInt.$name reference"
    }
    $setParent = @($reparent.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'SetParent'
    } | ForEach-Object Operand)[0]
    if ($null -eq $setParent) {
        throw 'Could not find UnityEngine.Transform.SetParent. The game version may be unsupported.'
    }

    # Joining a lobby always assigns an edge position. Right is selected 75% of the time;
    # the top edge is the fallback, so cats no longer appear in the middle of the desktop.
    $position.Body.Instructions.Clear()
    $position.Body.ExceptionHandlers.Clear()
    $position.Body.Variables.Clear()
    $position.Body.InitLocals = $true
    $display = New-Object dnlib.DotNet.Emit.Local($screenInfo.ReturnType)
    $position.Body.Variables.Add($display)
    $rotator = New-Object dnlib.DotNet.Emit.Local($rotatorField.FieldType)
    $position.Body.Variables.Add($rotator)
    $topEdge = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $finish = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0)
    $edge = $position.Body.Instructions

    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $screenInfo))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stloc, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::CreateLdcI4(0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::CreateLdcI4(4))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $randomRange))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse, $topEdge))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $catField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $getTransform))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloca_S, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldflda, $workArea))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $rectCalls['get_xMax']))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_R4))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloca_S, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldflda, $workArea))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $rectCalls['get_yMin']))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloca_S, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldflda, $workArea))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $rectCalls['get_yMax']))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $randomRange))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_R4))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Newobj, $vector3Ctor))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setPosition))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $draggableField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $rotatorField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse, $finish))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::CreateLdcI4(1))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $rotationStateField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $rotatorTransformField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]90))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $quaternionEuler))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setLocalRotation))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Br, $finish))
    $edge.Add($topEdge)
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $catField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $getTransform))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloca_S, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldflda, $workArea))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $rectCalls['get_xMin']))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloca_S, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldflda, $workArea))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $rectCalls['get_xMax']))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $randomRange))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_R4))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloca_S, $display))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldflda, $workArea))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $rectCalls['get_yMax']))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_R4))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Newobj, $vector3Ctor))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setPosition))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $draggableField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $rotatorField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Brfalse, $finish))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::CreateLdcI4(2))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $rotationStateField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc, $rotator))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $rotatorTransformField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]180))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $quaternionEuler))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setLocalRotation))
    $edge.Add($finish)
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $draggableField))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $fetchRelativePos))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $savePos = Get-SingleItem ($member.Methods | Where-Object { $_.Name -eq 'SavePos' -and $_.Parameters.Count -eq 1 }) 'LobbyMemberInstance.SavePos method'
    $quaternionEuler = Get-SingleItem (($rotatorType.Methods | Where-Object { $_.Name -eq 'Start' }).Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Quaternion' 'Euler'
    } | ForEach-Object Operand) 'UnityEngine.Quaternion.Euler reference'
    $setLocalRotation = Get-SingleItem (($rotatorType.Methods | Where-Object { $_.Name -eq 'Start' }).Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'set_localRotation'
    } | ForEach-Object Operand) 'UnityEngine.Transform.set_localRotation reference'
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $savePos))
    $edge.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret))

    $reparent.Body.Instructions.Clear()
    $reparent.Body.ExceptionHandlers.Clear()
    $reparent.Body.Variables.Clear()
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $catField))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $getTransform))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_1))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setParent))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $position))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret))
    return $true
}

function Set-MultiplayerPerimeterPositioning {
    param($Module)

    $member = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.Multiplayer.LobbyMemberInstance') 'BongoCat.Multiplayer.LobbyMemberInstance type'
    $reparent = Get-SingleItem ($member.Methods | Where-Object { $_.Name -eq 'ReparentAndPositionCat' -and $_.HasBody -and $_.Parameters.Count -eq 2 }) 'LobbyMemberInstance.ReparentAndPositionCat method'
    $position = Get-SingleItem ($member.Methods | Where-Object { $_.Name -eq 'PositionCatRandomly' -and $_.HasBody -and $_.Parameters.Count -eq 1 }) 'LobbyMemberInstance.PositionCatRandomly method'
    if ($member.Fields | Where-Object Name -eq '_autoArrangeIndex') {
        return $false
    }

    $catField = Get-SingleItem ($member.Fields | Where-Object Name -eq 'cat') 'LobbyMemberInstance.cat field'
    $draggableField = Get-SingleItem ($member.Fields | Where-Object Name -eq '_draggable') 'LobbyMemberInstance._draggable field'
    $draggableType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'BongoCat.Draggable') 'BongoCat.Draggable type'
    $rotatorField = Get-SingleItem ($draggableType.Fields | Where-Object Name -eq '_catRotator') 'Draggable._catRotator field'
    $rotatorType = Get-SingleItem ($Module.GetTypes() | Where-Object FullName -eq 'CatRotator') 'CatRotator type'
    $rotationStateField = Get-SingleItem ($rotatorType.Fields | Where-Object Name -eq '_rotationState') 'CatRotator._rotationState field'
    $rotatorTransformField = Get-SingleItem ($rotatorType.Fields | Where-Object Name -eq '_catTransform') 'CatRotator._catTransform field'
    $saveRotation = Get-SingleItem ($rotatorType.Methods | Where-Object { $_.Name -eq 'SaveRotation' -and $_.HasBody -and $_.Parameters.Count -eq 1 }) 'CatRotator.SaveRotation method'
    $outOfBoundsFix = Get-SingleItem ($draggableType.Methods | Where-Object { $_.Name -eq 'OutOfBoundsFix' -and $_.HasBody -and $_.Parameters.Count -eq 1 }) 'Draggable.OutOfBoundsFix method'
    $getTransform = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Component' 'get_transform'
    } | ForEach-Object Operand) 'UnityEngine.Component.get_transform reference'
    $setPosition = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'set_position'
    } | ForEach-Object Operand) 'UnityEngine.Transform.set_position reference'
    $fetchRelativePos = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'BongoCat.Draggable' 'FetchRelativePos'
    } | ForEach-Object Operand) 'Draggable.FetchRelativePos reference'
    $screenInfo = Get-SingleItem ($position.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Screen' 'get_mainWindowDisplayInfo'
    } | ForEach-Object Operand) 'Screen.get_mainWindowDisplayInfo reference'
    $vector3Ctor = Get-SingleItem ($position.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Newobj -and
        [string]$_.Operand -eq 'System.Void UnityEngine.Vector3::.ctor(System.Single,System.Single,System.Single)'
    } | ForEach-Object Operand) 'UnityEngine.Vector3(float, float, float) constructor reference'
    $workArea = @($position.Body.Instructions | Where-Object {
        $_.OpCode.Code -eq [dnlib.DotNet.Emit.Code]::Ldflda -and
        [string]$_.Operand -eq 'UnityEngine.RectInt UnityEngine.DisplayInfo::workArea'
    } | ForEach-Object Operand)[0]
    if ($null -eq $workArea) {
        throw 'Could not find DisplayInfo.workArea. The game version may be unsupported.'
    }
    $rectCalls = @{}
    foreach ($name in @('get_xMin', 'get_xMax', 'get_yMin', 'get_yMax')) {
        $rectCalls[$name] = Get-SingleItem ($position.Body.Instructions | Where-Object {
            Test-MethodCall $_ 'UnityEngine.RectInt' $name
        } | ForEach-Object Operand) "UnityEngine.RectInt.$name reference"
    }
    $savePos = Get-SingleItem ($member.Methods | Where-Object { $_.Name -eq 'SavePos' -and $_.Parameters.Count -eq 1 }) 'LobbyMemberInstance.SavePos method'
    $quaternionEuler = Get-SingleItem (($rotatorType.Methods | Where-Object { $_.Name -eq 'Start' }).Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Quaternion' 'Euler'
    } | ForEach-Object Operand) 'UnityEngine.Quaternion.Euler reference'
    $setLocalRotation = Get-SingleItem (($rotatorType.Methods | Where-Object { $_.Name -eq 'Start' }).Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'set_localRotation'
    } | ForEach-Object Operand) 'UnityEngine.Transform.set_localRotation reference'
    $getSiblingIndex = @($Module.GetTypes() | ForEach-Object Methods | Where-Object HasBody | ForEach-Object {
        $_.Body.Instructions | Where-Object { Test-MethodCall $_ 'UnityEngine.Transform' 'GetSiblingIndex' } | ForEach-Object Operand
    })[0]
    if ($null -eq $getSiblingIndex) {
        throw 'Could not find UnityEngine.Transform.GetSiblingIndex. The game version may be unsupported.'
    }
    $setParent = @($reparent.Body.Instructions | Where-Object {
        Test-MethodCall $_ 'UnityEngine.Transform' 'SetParent'
    } | ForEach-Object Operand)[0]
    if ($null -eq $setParent) {
        throw 'Could not find UnityEngine.Transform.SetParent. The game version may be unsupported.'
    }

    $getterSignature = [dnlib.DotNet.MethodSig]::CreateInstance($rotatorField.FieldType)
    $getRotator = [dnlib.DotNet.MethodDefUser]::new('GetAutoArrangeRotator', $getterSignature)
    $getRotator.Attributes = [dnlib.DotNet.MethodAttributes](
        [int][dnlib.DotNet.MethodAttributes]::Public -bor
        [int][dnlib.DotNet.MethodAttributes]::HideBySig
    )
    $getRotator.Body = [dnlib.DotNet.Emit.CilBody]::new()
    $getRotator.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $getRotator.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $rotatorField))
    $getRotator.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret))
    $draggableType.Methods.Add($getRotator)

    # Use the game's world-corner correction after rotation so scale and pivot
    # are accounted for when a cat is placed against a display edge.
    $fitSignature = [dnlib.DotNet.MethodSig]::CreateInstance($Module.CorLibTypes.Void)
    $fitToScreen = [dnlib.DotNet.MethodDefUser]::new('FitAutoArrangedCatToScreen', $fitSignature)
    $fitToScreen.Attributes = [dnlib.DotNet.MethodAttributes](
        [int][dnlib.DotNet.MethodAttributes]::Public -bor
        [int][dnlib.DotNet.MethodAttributes]::HideBySig
    )
    $fitToScreen.Body = [dnlib.DotNet.Emit.CilBody]::new()
    $fitToScreen.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $fitToScreen.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $outOfBoundsFix))
    $fitToScreen.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Pop))
    $fitToScreen.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret))
    $draggableType.Methods.Add($fitToScreen)

    $rotationSignature = [dnlib.DotNet.MethodSig]::CreateInstance($Module.CorLibTypes.Void, $Module.CorLibTypes.Int32)
    $setAutoRotation = [dnlib.DotNet.MethodDefUser]::new('SetAutoArrangeRotation', $rotationSignature)
    $setAutoRotation.Attributes = [dnlib.DotNet.MethodAttributes](
        [int][dnlib.DotNet.MethodAttributes]::Public -bor
        [int][dnlib.DotNet.MethodAttributes]::HideBySig
    )
    $setAutoRotation.Body = [dnlib.DotNet.Emit.CilBody]::new()
    $rotationBody = $setAutoRotation.Body.Instructions
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_1))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Stfld, $rotationStateField))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $rotatorTransformField))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldc_R4, [single]0))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_1))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::CreateLdcI4(90))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Mul))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Conv_R4))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $quaternionEuler))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setLocalRotation))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $saveRotation))
    $rotationBody.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret))
    $rotatorType.Methods.Add($setAutoRotation)

    $attributes = [dnlib.DotNet.FieldAttributes](
        [int][dnlib.DotNet.FieldAttributes]::Private -bor
        [int][dnlib.DotNet.FieldAttributes]::Static
    )
    $counterField = [dnlib.DotNet.FieldDefUser]::new(
        '_autoArrangeIndex',
        [dnlib.DotNet.FieldSig]::new($Module.CorLibTypes.Int32),
        $attributes
    )
    $member.Fields.Add($counterField)

    $position.Body.Instructions.Clear()
    $position.Body.ExceptionHandlers.Clear()
    $position.Body.Variables.Clear()
    $position.Body.InitLocals = $true
    $display = [dnlib.DotNet.Emit.Local]::new($screenInfo.ReturnType)
    $index = [dnlib.DotNet.Emit.Local]::new($Module.CorLibTypes.Int32)
    $lane = [dnlib.DotNet.Emit.Local]::new($Module.CorLibTypes.Int32)
    $side = [dnlib.DotNet.Emit.Local]::new($Module.CorLibTypes.Int32)
    $capacity = [dnlib.DotNet.Emit.Local]::new($Module.CorLibTypes.Int32)
    $rotator = [dnlib.DotNet.Emit.Local]::new($rotatorField.FieldType)
    $position.Body.Variables.Add($display)
    $position.Body.Variables.Add($index)
    $position.Body.Variables.Add($lane)
    $position.Body.Variables.Add($side)
    $position.Body.Variables.Add($capacity)
    $position.Body.Variables.Add($rotator)

    $il = $position.Body.Instructions
    $right = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $top = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $left = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $bottom = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $chooseTop = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $chooseLeft = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $chooseBottom = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $rotate = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $finish = [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Nop)
    $add = {
        param($OpCode, $Operand)
        $instruction = [dnlib.DotNet.Emit.Instruction]::new()
        $instruction.OpCode = $OpCode
        if ($null -ne $Operand) { $instruction.Operand = $Operand }
        [void]$il.Add($instruction)
    }

    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $screenInfo
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $display
    # Use the current lobby hierarchy, which starts from zero whenever the
    # multiplayer cat container is recreated.
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $catField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getTransform
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getSiblingIndex
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $index
    # Fill each whole side before continuing clockwise: right, top, left, bottom.
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 156
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Div) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Add) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Bge) $chooseTop
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $right

    [void]$il.Add($chooseTop)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 156
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Div) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Add) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Bge) $chooseLeft
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $top

    [void]$il.Add($chooseLeft)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 156
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Div) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Add) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Bge) $chooseBottom
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $left

    [void]$il.Add($chooseBottom)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 156
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Div) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Add) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $index
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $capacity
    & $add ([dnlib.DotNet.Emit.OpCodes]::Rem) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $bottom

    # Right edge, bottom to top.
    [void]$il.Add($right)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $catField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getTransform
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Mul) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Add) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_R4) ([single]0)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Newobj) $vector3Ctor
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $setPosition
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_1) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $side
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $rotate

    # Top edge, right to left.
    [void]$il.Add($top)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $catField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getTransform
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Mul) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_R4) ([single]0)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Newobj) $vector3Ctor
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $setPosition
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_2) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $side
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $rotate

    # Left edge, top to bottom.
    [void]$il.Add($left)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $catField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getTransform
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMax']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Mul) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Sub) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_R4) ([single]0)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Newobj) $vector3Ctor
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $setPosition
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_3) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $side
    & $add ([dnlib.DotNet.Emit.OpCodes]::Br) $rotate

    # Bottom edge, left to right.
    [void]$il.Add($bottom)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $catField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getTransform
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_xMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $lane
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4) 88
    & $add ([dnlib.DotNet.Emit.OpCodes]::Mul) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Add) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloca_S) $display
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldflda) $workArea
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $rectCalls['get_yMin']
    & $add ([dnlib.DotNet.Emit.OpCodes]::Conv_R4) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_R4) ([single]0)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Newobj) $vector3Ctor
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $setPosition
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldc_I4_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $side

    [void]$il.Add($rotate)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $draggableField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $getRotator
    & $add ([dnlib.DotNet.Emit.OpCodes]::Stloc) $rotator
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $rotator
    & $add ([dnlib.DotNet.Emit.OpCodes]::Brfalse) $finish
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $rotator
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldloc) $side
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $setAutoRotation

    [void]$il.Add($finish)
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $draggableField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $fitToScreen
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldfld) $draggableField
    & $add ([dnlib.DotNet.Emit.OpCodes]::Callvirt) $fetchRelativePos
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ldarg_0) $null
    & $add ([dnlib.DotNet.Emit.OpCodes]::Call) $savePos
    & $add ([dnlib.DotNet.Emit.OpCodes]::Ret) $null

    # Always arrange on lobby creation. The stock method restores cached
    # positions and otherwise bypasses PositionCatRandomly entirely.
    $reparent.Body.Instructions.Clear()
    $reparent.Body.ExceptionHandlers.Clear()
    $reparent.Body.Variables.Clear()
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $catField))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $getTransform))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_1))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $setParent))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldarg_0))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Call, $position))
    $reparent.Body.Instructions.Add([dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ret))
    return $true
}

function Assert-GameIsClosed {
    param([string]$TargetGamePath)

    $target = (Resolve-Path -LiteralPath $TargetGamePath).Path.TrimEnd('\')
    foreach ($process in @(Get-Process -Name 'BongoCat' -ErrorAction SilentlyContinue)) {
        try {
            $processDirectory = Split-Path -Parent $process.Path
            if ((Resolve-Path -LiteralPath $processDirectory).Path.TrimEnd('\') -eq $target) {
                throw 'BongoCat is running. Close the game before applying or restoring the patch.'
            }
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            throw 'Could not verify the BongoCat process location. Close the game before applying or restoring the patch.'
        }
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

Assert-GameIsClosed $resolvedGamePath

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
    $shopItemType = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'BongoCat.ShopItem') 'BongoCat.ShopItem type'
    $pets = Get-SingleItem ($module.GetTypes() | Where-Object FullName -eq 'BongoCat.Pets') 'BongoCat.Pets type'
    $shopItemField = Get-SingleItem ($shop.Fields | Where-Object Name -eq '_shopItem') 'Shop._shopItem field'
    $stockRefreshTimeField = Get-SingleItem ($shop.Fields | Where-Object Name -eq '_stockRefreshTime') 'Shop._stockRefreshTime field'
    $stockRefreshTimeLeftField = Get-SingleItem ($shop.Fields | Where-Object Name -eq 'StockRefreshTimeLeft') 'Shop.StockRefreshTimeLeft field'
    $chestReadyField = Get-SingleItem ($shop.Fields | Where-Object Name -eq 'ChestIsReady') 'Shop.ChestIsReady field'
    $buyMethod = Get-SingleItem ($shopItemType.Methods | Where-Object {
        $_.Name -eq 'Buy' -and $_.Parameters.Count -eq 1
    }) 'ShopItem.Buy method'

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

    if (Set-MultiplayerPerimeterPositioning $module) {
        $changes += 'Multiplayer cats: arranged right, top, left, then bottom'
    }

    if (Remove-LegacyPopupAutoBuy $shop $shopItemField $buyMethod) {
        $changes += 'Automatic chest purchase: removed legacy popup hook'
    }

    $oldRefreshSeconds = Set-Int32FieldInitializer $shop $stockRefreshTimeField 900 'Shop stock refresh'
    if ($oldRefreshSeconds -ne 900) {
        $changes += "Chest countdown: $oldRefreshSeconds seconds -> official 900 seconds"
    }

    $timerUpdate = Get-TimerUpdateMethod $module $shop
    if (Set-TokenMissingDelay $timerUpdate $stockRefreshTimeLeftField $stockRefreshTimeField) {
        $changes += 'Missing Steam token: keep the chest pending at 00:00 until local inventory sync completes'
    }
    if (Set-ExchangeFailureDelay $shop $stockRefreshTimeLeftField $stockRefreshTimeField) {
        $changes += 'Failed Steam exchange: keep the chest pending instead of discarding the ready state'
    }

    $autoClaimResult = Add-AutoClaimMethod $module $shopItemType $buyMethod
    $tokenReadyInsertIndex = Find-TokenReadySite $timerUpdate $chestReadyField $null
    $instructions = $timerUpdate.Body.Instructions
    if ($tokenReadyInsertIndex -ge 3 -and
        (Test-FieldInstruction $instructions[$tokenReadyInsertIndex - 2] $shopItemField) -and
        (Test-MethodCall $instructions[$tokenReadyInsertIndex - 1] 'BongoCat.ShopItem' 'Buy')) {
        for ($i = 0; $i -lt 3; $i++) {
            $instructions.RemoveAt($tokenReadyInsertIndex - 3)
        }
        $tokenReadyInsertIndex -= 3
        $changes += 'Automatic chest purchase: upgraded legacy direct-buy hook'
    }
    if (-not (Test-TokenReadyAutoBuyPatch $timerUpdate $tokenReadyInsertIndex $shopItemField $autoClaimResult.Method)) {
        $instructions.Insert($tokenReadyInsertIndex, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldloc_1))
        $instructions.Insert($tokenReadyInsertIndex + 1, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Ldfld, $shopItemField))
        $instructions.Insert($tokenReadyInsertIndex + 2, [dnlib.DotNet.Emit.Instruction]::new([dnlib.DotNet.Emit.OpCodes]::Callvirt, $autoClaimResult.Method))
        $changes += 'Automatic chest purchase: enabled when token and payment are both ready'
    }

    $playtimeDropResult = Set-PlaytimeDropInterval $module 900000
    if ($playtimeDropResult.Changed) {
        $changes += 'Steam playtime drop listener: one event every 900 seconds'
    }
    if (Add-TokenDropListener $module $playtimeDropResult.Type $shop $stockRefreshTimeLeftField) {
        $changes += 'Steam token listener: wakes the ready check when an inventory-drop callback arrives'
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
    $timerUpdate.Body.SimplifyBranches()
    $timerUpdate.Body.OptimizeBranches()
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
