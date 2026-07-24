[CmdletBinding()]
param(
    [ValidateRange(1, 5000)]
    [int]$Tail = 200,

    [switch]$Once
)

$logPath = Join-Path $env:USERPROFILE 'AppData\LocalLow\Irox Games\BongoCat\Player.log'
$patterns = @(
    '[BongoCatPatcher]',
    'Chest Exchange failed',
    'SteamExchange | Not enough items'
)

if (-not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
    throw "Bongo Cat log not found: $logPath. Start the game once, then run this script again."
}

Write-Host "Watching chest claim log: $logPath"
Write-Host 'SUCCESS means Steam consumed a token and returned a chest item. FAILED/NO TOKEN means it was not claimed yet.'

function Write-ChestLines {
    process {
        $line = [string]$_
        foreach ($pattern in $patterns) {
            if ($line.Contains($pattern)) {
                Write-Output $line
                break
            }
        }
    }
}

if ($Once) {
    Get-Content -LiteralPath $logPath -Tail $Tail | Write-ChestLines
    return
}

Get-Content -LiteralPath $logPath -Tail $Tail -Wait | Write-ChestLines
