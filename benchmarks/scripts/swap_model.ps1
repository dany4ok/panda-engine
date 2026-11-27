# LEGACY harness script — kept only for reproducing historical runs.
# It targets the retired external Strata loader (port 47831) and the old
# "C:\Users\x1p\Desktop\Panda" paths, none of which exist in the current engine.
# Current workflow: start the model with panda.exe (GUI Model Library or
# "panda.exe --console" -> S), then run benchmarks/scripts/run_probe.ps1.
param(
  [Parameter(Mandatory=$true)][ValidateSet('gyro','mini')][string]$Target,
  [switch]$Force,
  [string]$Root = 'C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench'
)
$ErrorActionPreference = 'Stop'
if (-not $Force) { throw "Refusing to swap models without -Force (another test may own the GPU). Review the script first." }

function Vram { (& nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits 2>$null) -join '/' }
function Log { param($s); "$((Get-Date).ToString('o'))  $s" }

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$before = Vram
$log = @()
$log += Log "SWAP target=$Target before_VRAM_used/free_MiB=$before"

if ($Target -eq 'gyro') {
  # Stop ONLY the benchmark-owned MiniCPM server (command line matches its config).
  $victims = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'panda-minicpmv' })
  foreach ($v in $victims) {
    $log += Log "STOP mini server PID=$($v.ProcessId) CMD=$($v.CommandLine)"
    Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue
  }
  $log += Log "Waiting for VRAM release..."
  Start-Sleep -Seconds 8
  $log += Log "VRAM_after_unload=$(Vram)"

  $loader = 'C:\Users\x1p\Desktop\Strata AI\Strata\load-gyro-s.ps1'
  if (-not (Test-Path $loader)) { throw "Missing official loader: $loader" }
  $log += Log "Running official load-gyro-s.ps1 (timeout ~115s)"
  & powershell -ExecutionPolicy Bypass -NoProfile -File $loader 2>&1 | ForEach-Object { $log += Log "LOAD: $_" }

  $ready = $false
  for ($i=0; $i -lt 12; $i++) {
    try { $r = Invoke-WebRequest -Uri 'http://127.0.0.1:47831/v1/models' -TimeoutSec 4 -UseBasicParsing; $ready = $true; $log += Log "ENDPOINT 47831 READY: $($r.Content.Substring(0,[Math]::Min(200,$r.Content.Length)))"; break } catch { Start-Sleep -Seconds 5 }
  }
  if (-not $ready) { throw 'Gyro-S endpoint 47831 did not become ready after load.' }
} else {
  # Stop ONLY benchmark-owned Panda Engine engine processes holding Gyro-S.
  $victims = @(Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match 'Panda Engine AI\\Panda Engine' -or $_.Name -match 'panda-(desktop|engine)' })
  foreach ($v in $victims) {
    $log += Log "STOP panda PID=$($v.ProcessId) NAME=$($v.Name)"
    Stop-Process -Id $v.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Seconds 8
  $log += Log "VRAM_after_unload=$(Vram)"

  $py  = 'C:\Users\x1p\Desktop\Panda\.venv\Scripts\python.exe'
  $srv = 'C:\Users\x1p\Desktop\Panda\serve\server.py'
  $cfg = 'C:\Users\x1p\Desktop\Panda\panda-minicpmv-q4_k_m.json'
  $wd  = 'C:\Users\x1p\Desktop\Panda Engine'
  foreach ($p in @($py,$srv,$cfg)) { if (-not (Test-Path $p)) { throw "Missing: $p" } }
  $out = Join-Path $Root 'mini_server_out.log'
  $err = Join-Path $Root 'mini_server_err.log'
  $swSrv = [System.Diagnostics.Stopwatch]::StartNew()
  $proc = Start-Process -FilePath $py -ArgumentList @($srv,'--engine','panda','--config',$cfg,'--port','8080') -WorkingDirectory $wd -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden -PassThru
  $log += Log "MINI_SERVER_PID=$($proc.Id) start_ms=$($swSrv.ElapsedMilliseconds)"

  $ready = $false
  for ($i=0; $i -lt 24; $i++) {
    try {
      $r = Invoke-RestMethod -Uri 'http://127.0.0.1:8080/v1/models' -TimeoutSec 4
      if ($r.data) { $ready = $true; $log += Log "ENDPOINT 8080 READY model=$($r.data[0].id) load_ms=$($swSrv.ElapsedMilliseconds)"; break }
    } catch { Start-Sleep -Seconds 5 }
  }
  if (-not $ready) { throw 'MiniCPM endpoint 8080 did not become ready after load.' }
}

$sw.Stop()
$log += Log "SWAP_DONE target=$Target total_ms=$([int]$sw.ElapsedMilliseconds) after_VRAM=$(Vram)"
$log | Out-File -FilePath (Join-Path $Root "swap_$Target.log") -Append -Encoding utf8

$rec = [ordered]@{ target=$Target; total_ms=[int]$sw.ElapsedMilliseconds; before=$before; after=(Vram); ts=(Get-Date).ToUniversalTime().ToString('o') }
$rec | ConvertTo-Json -Compress | Out-File -FilePath (Join-Path $Root 'swaps.jsonl') -Append -Encoding utf8
$log | Select-Object -Last 4
