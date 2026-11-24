param(
  [Parameter(Mandatory=$true)][string]$Batch,
  [string]$Root = 'C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench'
)
$ErrorActionPreference = 'Stop'
$dirMap = @{ 'A'='A_simple'; 'B'='B_complex'; 'C'='C_debug'; 'D'='D_game'; 'E'='E_assets'; 'F'='F_agent' }
$base = Join-Path $Root "results\$Batch"
if (-not (Test-Path $base)) { throw "No results for batch $Batch" }

$summary = Join-Path $base 'summary.jsonl'
if (Test-Path $summary) { Remove-Item $summary -Force }
$missing = @()

Get-ChildItem $base -Directory -Recurse | Where-Object { $_.Name -match '^[A-F]$' } | ForEach-Object {
  $dir = $_.FullName
  $model = $_.Parent.Name
  $task = $_.Name
  $eval = Join-Path $dir 'eval.json'
  $metrics = Join-Path $dir 'metrics.json'
  if (-not (Test-Path $eval)) {
    # try to (re)run evaluator
    $seed = Join-Path $Root ("tasks\" + $dirMap[$task] + "\seed")
    $work = Join-Path $dir 'work'
    if (Test-Path $work) { & python (Join-Path $Root ("tasks\" + $dirMap[$task] + "\evaluate.py")) --work $work --seed $seed --out $eval 2>&1 | Out-Null }
  }
  if (-not (Test-Path $eval)) { $missing += "$model/$task"; return }
  if (-not (Test-Path $metrics)) { $missing += "$model/$task (metrics)"; return }

  $e = Get-Content $eval -Raw | ConvertFrom-Json
  $m = Get-Content $metrics -Raw | ConvertFrom-Json
  $row = [ordered]@{
    model = $model; task = $task;
    passed = $e.passed; total = $e.total; score = $e.score;
    wall_ms = $m.wall_ms; tool_calls = $m.tool_calls; repairs = $m.repair_attempts_heuristic;
    exit_code = $m.exit_code; timed_out = $m.timed_out;
    vram_max_mib = $m.vram_max_mib;
  }
  $row | ConvertTo-Json -Compress | Out-File -FilePath $summary -Append -Encoding utf8
}

"SUMMARY=$summary"
if ($missing.Count) { "MISSING: $($missing -join ', ')" } else { "All probes have metrics + independent evaluation." }
