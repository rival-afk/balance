# Copies the built game and docs to the shared balance-ai folder.
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File sync.ps1
$ErrorActionPreference = 'Stop'
$desk = -join ([char[]](1056,1072,1073,1086,1095,1080,1081,32,1089,1090,1086,1083))
$docs = -join ([char[]](1044,1086,1082,1091,1084,1077,1085,1090,1099))
$src = "$env:USERPROFILE\OneDrive\$docs\balance"
$dst = "$env:USERPROFILE\OneDrive\$desk\ivanovich\balance-ai"

New-Item -ItemType Directory -Force -Path $dst | Out-Null
$items = @(Get-ChildItem -LiteralPath $src -Filter '*.md' -File)
$exe = Join-Path $src 'build\Balance.exe'
if (Test-Path -LiteralPath $exe) { $items += Get-Item -LiteralPath $exe } else { Write-Warning "build\Balance.exe not found - run the build first" }

foreach ($f in $items) {
    Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dst $f.Name) -Force
    Write-Output ("copied {0}" -f $f.Name)
}
Write-Output ("done -> {0}" -f $dst)
