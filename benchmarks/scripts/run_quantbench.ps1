# Runs the A-F harness for each Inkling quantization at a fixed context, one server at a time.
# Calls swap/probe scripts in-process (no nested powershell pipes, which deadlock here).
param(
  [Parameter(Mandatory=$true)][string]$Pairs,
  [string]$BatchPrefix = 'qb',
  [string]$Tasks = 'A,B,C,D,E,F',
  [int]$TimeoutSec = 900,
  [int]$Context = 131072,
  [string]$Residency = 'device',
  [int]$HostMib = 0
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$pandaRoot = Split-Path $root -Parent
$progress = Join-Path $root 'quantbench-progress.log'
function L($s) { $line = (Get-Date).ToString('o') + '  ' + $s; Write-Host $line; $line | Out-File -FilePath $progress -Append -Encoding utf8 }
$swap = Join-Path $PSScriptRoot 'swap_inkling.ps1'
$probe = Join-Path $PSScriptRoot 'run_probe.ps1'
function Test-Endpoint {
    try { $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 4; return [bool]$r.data }
    catch { return $false }
}
function Do-Swap($artifact) {
    & $swap -Artifact $artifact -Force -Root $root -Context $Context -Residency $Residency -HostMib $HostMib | Out-Null
    return (Test-Endpoint)
}

L "BENCH START pairs=$Pairs context=$Context residency=$Residency hostmib=$HostMib"
foreach ($pair in ($Pairs -split ',')) {
    if (-not $pair.Trim()) { continue }
    $parts = $pair -split '=', 2
    if ($parts.Count -ne 2) { throw "Bad pair: $pair" }
    $slug = $parts[0].Trim()
    $artifact = $parts[1].Trim()
    if (-not (Test-Path -LiteralPath (Join-Path $pandaRoot ('models\' + $artifact)))) { L "SKIP $slug (artifact missing)"; continue }
    $batch = $BatchPrefix + '_' + $slug.ToLowerInvariant()
    L "=== MODEL $slug ctx=$Context batch=$batch ==="
    if (-not (Do-Swap $artifact)) { L ("  SKIP " + $slug + ": server did not become ready"); continue }
    foreach ($t in ($Tasks -split ',')) {
        $t = $t.Trim()
        if (-not $t) { continue }
        if (-not (Test-Endpoint)) {
            L "  server lost before $slug/$t - re-swapping"
            if (-not (Do-Swap $artifact)) { L "  SKIP $slug/$t : server unavailable"; continue }
        }
        L "  PROBE $slug/$t start"
        & $probe -Model 'ninfer/inkling-2-mini' -Task $t -Batch $batch -NoSub -TimeoutSec $TimeoutSec -Root $root | ForEach-Object { L "  probe: $_" }
    }
    L "=== MODEL $slug DONE ==="
}
L 'BENCH ALL DONE'
