# Mirrors *.md and build\Balance.exe from the project folder into balance-ai.
# Polls every 2 seconds (reliable in background). Uses rename-then-copy
# because overwriting cloud-only (placeholder) files fails on OneDrive.
# Registered as logon task "BalanceAISync". Stop: schtasks /End /TN "BalanceAISync"
$desk = -join ([char[]](1056,1072,1073,1086,1095,1080,1081,32,1089,1090,1086,1083))
$docs = -join ([char[]](1044,1086,1082,1091,1084,1077,1085,1090,1099))
$src = "$env:USERPROFILE\OneDrive\$docs\balance"
$dst = "$env:USERPROFILE\OneDrive\$desk\ivanovich\balance-ai"
New-Item -ItemType Directory -Force -Path $dst | Out-Null

function Sync-File($source, $target) {
    $bak = "$target.old"
    $renamed = $false
    if (Test-Path -LiteralPath $target) {
        try { Move-Item -LiteralPath $target -Destination $bak -Force; $renamed = $true } catch {}
    }
    try {
        Copy-Item -LiteralPath $source -Destination $target -Force -ErrorAction Stop
        if ($renamed) { Remove-Item -LiteralPath $bak -Force -ErrorAction SilentlyContinue }
    } catch {
        if ($renamed) { Move-Item -LiteralPath $bak -Destination $target -Force -ErrorAction SilentlyContinue }
    }
}

while ($true) {
    $items = @(Get-ChildItem -LiteralPath $src -Filter '*.md' -File -ErrorAction SilentlyContinue)
    $exe = Join-Path $src 'build\Balance.exe'
    if (Test-Path -LiteralPath $exe) { $items += Get-Item -LiteralPath $exe }

    foreach ($f in $items) {
        $target = Join-Path $dst $f.Name
        $need = $true
        if (Test-Path -LiteralPath $target) {
            $cur = Get-Item -LiteralPath $target
            if ($cur.Length -eq $f.Length -and $cur.LastWriteTimeUtc -eq $f.LastWriteTimeUtc) { $need = $false }
        }
        if ($need) { Sync-File $f.FullName $target }
    }
    Start-Sleep -Seconds 2
}
