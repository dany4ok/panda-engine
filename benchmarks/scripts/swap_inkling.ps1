param(
  [Parameter(Mandatory=$true)][string]$Artifact,
  [switch]$Force,
  [string]$Root = '',
  [int]$Context = 16384,
  [string]$Residency = 'device',
  [int]$HostMib = 0
)
$ErrorActionPreference = 'Stop'
if (-not $Force) { throw 'Refusing to swap the NInfer server without -Force (another test may own the GPU).' }
if (-not $Root) { $Root = Split-Path $PSScriptRoot -Parent }
$pandaRoot = Split-Path $Root -Parent
$cat = Get-Content -LiteralPath (Join-Path $pandaRoot 'panda\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$artPath = Join-Path $pandaRoot ('models\' + $Artifact)
if (-not (Test-Path -LiteralPath $artPath)) { throw "Missing artifact: $artPath" }
$exe = $null
foreach ($base in @((Join-Path $pandaRoot 'ninfer'), (Join-Path $cat.roots.knownInkling 'ninfer'))) {
    if (-not $exe -and (Test-Path -LiteralPath $base)) {
        $exe = Get-ChildItem -LiteralPath $base -Recurse -File -Filter $cat.ninfer.exe -ErrorAction SilentlyContinue |
               Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $exe) { throw 'ninfer-serve.exe not found' }
$logDir = Join-Path $pandaRoot 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

function Vram { (& nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits 2>$null) -join '/' }
function L($s) { $line = (Get-Date).ToString('o') + '  ' + $s; Write-Host $line; $line | Out-File -FilePath (Join-Path $Root 'swap_inkling.log') -Append -Encoding utf8 }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
L "SWAP artifact=$Artifact before_VRAM=$(Vram)"
foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort 8080 -ErrorAction SilentlyContinue)) {
    $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match 'ninfer|python') {
        L "STOP PID=$($p.Id) NAME=$($p.ProcessName)"
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
}
Start-Sleep -Seconds 5
L "VRAM_after_unload=$(Vram)"

$cfgPath = Join-Path $pandaRoot 'config.json'
$cfg = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { @{} }
$cfg.artifact  = $Artifact
$cfg.context   = [int]$Context
$cfg.reasoning = $cat.ninfer.reasoning
$cfg.port      = [int]$cat.ninfer.port
($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8

$argLine = '"' + $artPath + '" --model-id inkling-2-mini --max-context ' + [string]$cfg.context +
    ' --kv-capacity ' + [string]$cfg.context + ' --expert-residency ' + $Residency + ' --vision --spec none' +
    ' --reasoning-loop conclude --presence-penalty 0 --frequency-penalty 0 --structured-output' +
    ' --host 127.0.0.1 --port ' + [string]$cfg.port
if ($HostMib -gt 0 -and $Residency -eq 'host') { $argLine += ' --expert-host-mib ' + [string]$HostMib }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $logDir "bench-ninfer-$stamp.out.log"
$errLog = Join-Path $logDir "bench-ninfer-$stamp.err.log"
$proc = Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput $outLog -RedirectStandardError $errLog
L "SERVER_PID=$($proc.Id)"

$ready = $false
for ($i = 0; $i -lt 60; $i++) {
    if ($proc.HasExited) { L "SERVER_EXITED early code=$($proc.ExitCode)"; break }
    Start-Sleep -Seconds 1
    try {
        $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 1
        if ($r.data) { $ready = $true; break }
    } catch {}
}
if (-not $ready) {
    L "ERROR: endpoint not ready. Tail of stderr:"
    Get-Content -LiteralPath $errLog -Tail 25 -ErrorAction SilentlyContinue | ForEach-Object { L "  $_" }
    throw "Server did not become ready for $Artifact"
}
$sw.Stop()
L "SWAP_DONE artifact=$Artifact load_ms=$([int]$sw.ElapsedMilliseconds) after_VRAM=$(Vram)"
$rec = [ordered]@{ artifact=$Artifact; load_ms=[int]$sw.ElapsedMilliseconds; vram=(Vram); ts=(Get-Date).ToUniversalTime().ToString('o') }
$rec | ConvertTo-Json -Compress | Out-File -FilePath (Join-Path $Root 'swaps_inkling.jsonl') -Append -Encoding utf8
$rec | ConvertTo-Json -Compress
