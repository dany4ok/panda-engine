# Downloads additional Inkling quantizations listed in catalog.json.
# Resumable (curl -C -), verifies remote Content-Length, logs to download-quants.log.
param([string]$Ids = 'inkling-q3kxl,inkling-iq4xs,inkling-apex')
$ErrorActionPreference = 'Stop'
$pandaDir = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $pandaDir
$cat  = Get-Content -LiteralPath (Join-Path $pandaDir 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$log  = Join-Path $PSScriptRoot 'download-quants.log'
function L($s) {
    $line = (Get-Date).ToString('o') + '  ' + $s
    Write-Host $line
    $line | Out-File -FilePath $log -Append -Encoding utf8
}
foreach ($raw in ($Ids -split ',')) {
    $id = $raw.Trim()
    if (-not $id) { continue }
    $m = @($cat.models) | Where-Object { $_.id -eq $id } | Select-Object -First 1
    if (-not $m) { L "MISSING catalog id: $id"; continue }
    $dest = Join-Path $repo ('models\' + $m.artifact)
    $part = $dest + '.part'
    L "START $id -> $dest"
    $len = [int64]0
    try {
        $headers = & curl.exe -sIL --max-time 60 $m.url 2>$null
        foreach ($line in $headers) {
            if ($line -match '^content-length:\s*(\d+)\s*$') { $len = [int64]$Matches[1] }
        }
    } catch {}
    L "remote_length=$len"
    if (Test-Path -LiteralPath $dest) {
        $got = (Get-Item -LiteralPath $dest).Length
        if ($len -gt 0 -and $got -eq $len) { L "SKIP already complete ($got bytes)"; continue }
    }
    $ok = $false
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        L "curl attempt $attempt"
        & curl.exe -L --fail --retry 3 -C - -o $part $m.url
        $ec = $LASTEXITCODE
        L "curl exit=$ec"
        if ($ec -eq 0) { $ok = $true; break }
        if ($attempt -eq 3) { throw "Download failed: $id (curl $ec)" }
    }
    if (-not $ok) { throw "Download failed: $id" }
    $got = (Get-Item -LiteralPath $part).Length
    if ($len -gt 0 -and $got -ne $len) {
        Remove-Item -LiteralPath $part -Force
        throw "Size mismatch for $id : $got vs $len"
    }
    Move-Item -LiteralPath $part $dest -Force
    L "DONE $id size=$got"
}
L 'ALL DONE'
