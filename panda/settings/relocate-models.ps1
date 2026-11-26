# Makes <repo>\models the real storage folder for all NInfer artifacts.
# Before: <repo>\models is a junction -> <knownInkling>\models (files live there).
# After:  <repo>\models is a real directory with the files; <knownInkling>\models
#         becomes a junction pointing back to it, so the original launcher still works.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
if (-not $Force) { throw 'Refusing to relocate models without -Force.' }

$pandaDir = Split-Path -Parent $PSScriptRoot
$repo     = Split-Path -Parent $pandaDir
$cat      = Get-Content -LiteralPath (Join-Path $pandaDir 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$link     = Join-Path $repo 'models'
$old      = Join-Path $cat.roots.knownInkling 'models'
$log      = Join-Path $PSScriptRoot 'relocate-models.log'
function L($s) { $line = (Get-Date).ToString('o') + '  ' + $s; Write-Host $line; $line | Out-File -FilePath $log -Append -Encoding utf8 }

# Guard: an active download must not be interrupted mid-write.
$activeCurl = @(Get-CimInstance Win32_Process -Filter "Name='curl.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -match 'huggingface|\.part' })
if ($activeCurl.Count -gt 0) { throw 'An active model download is running. Wait for it to finish before relocating.' }

# Stop the NInfer server so model files are not locked.
foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue)) {
    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match 'ninfer') { L "STOP server PID=$($p.Id)"; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 3

$item = Get-Item -LiteralPath $link -ErrorAction Stop
if ($item.LinkType -ne 'Junction') { throw "<repo>\models is not a junction; refusing to overwrite an existing real folder." }
if ($item.Target -ne $old) { throw "Unexpected junction target: $($item.Target)" }
L "JUNCTION $link -> $old"

# cmd rmdir removes only the reparse point, never the target contents.
& cmd.exe /c ('rmdir "' + $link + '"') 2>&1 | ForEach-Object { L "rmdir: $_" }
if (Test-Path -LiteralPath $link) { throw 'Junction was not removed.' }

New-Item -ItemType Directory -Path $link | Out-Null
L "CREATED real folder $link"

$files = @(Get-ChildItem -LiteralPath $old -File -ErrorAction SilentlyContinue)
foreach ($f in $files) {
    Move-Item -LiteralPath $f.FullName -Destination (Join-Path $link $f.Name) -Force
    L "MOVED $($f.Name) $([math]::Round($f.Length/1GB,2)) GiB"
}

# Remove the now-empty original folder and leave a junction back to the real storage.
if (@(Get-ChildItem -LiteralPath $old -Force -ErrorAction SilentlyContinue).Count -eq 0) {
    & cmd.exe /c ('rmdir "' + $old + '"') 2>&1 | ForEach-Object { L "rmdir old: $_" }
} else {
    L "WARNING: $old still has entries; junction not created"
}
if (-not (Test-Path -LiteralPath $old)) {
    New-Item -ItemType Junction -Path $old -Target $link | Out-Null
    L "JUNCTION $old -> $link"
}
L 'RELOCATE DONE'
Get-ChildItem -LiteralPath $link -File | Select-Object Name,@{n='GiB';e={[math]::Round($_.Length/1GB,2)}} | Format-Table -AutoSize | Out-String | ForEach-Object { L $_ }
