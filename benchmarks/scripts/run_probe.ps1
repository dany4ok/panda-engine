param(
  [Parameter(Mandatory=$true)][string]$Model,
  [Parameter(Mandatory=$true)][ValidateSet('A','B','C','D','E','F')][string]$Task,
  [Parameter(Mandatory=$true)][string]$Batch,
  [switch]$NoSub,
  [string]$Variant = '',
  [ValidateRange(1,100000)][int]$TimeoutSec = 0,
  [string]$Root = 'C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench'
)
$ErrorActionPreference = 'Stop'

# V2 CLI bundled with the desktop app: it reads the same V2 config as real sessions.
# The V1 npm CLI cannot read the global V2 config, so it is NOT used.
$exe = 'C:\Users\x1p\AppData\Local\Programs\ai.opencode.desktop\resources\opencode-cli.exe'
if (-not (Test-Path $exe)) { throw "opencode-cli.exe not found: $exe" }

$dirMap = @{ 'A'='A_simple'; 'B'='B_complex'; 'C'='C_debug'; 'D'='D_game'; 'E'='E_assets'; 'F'='F_agent' }
$modelSlug = ($Model -replace '[/:]','_')
$taskDir   = Join-Path $Root ("tasks\" + $dirMap[$Task])
$resultDir = Join-Path $Root "results\$Batch\$modelSlug\$Task"
$work      = Join-Path $resultDir 'work'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
New-Item -ItemType Directory -Force -Path $work | Out-Null

# clean copy of the seed, identical for both models
Copy-Item -Path (Join-Path $taskDir 'seed\*') -Destination $work -Recurse -Force
Copy-Item -Path (Join-Path $taskDir 'REQUIREMENT.md') -Destination (Join-Path $work 'REQUIREMENT.md') -Force

# Local workspace config. batch2 uses -NoSub: identical subagent deny for both models
# (V2: "permissions": [{action:subagent, resource:*, effect:deny}]).
$localCfg = $null
if ($NoSub) {
  $localCfg = if ($Model -like 'polystrata-mini*') { 'config\mini_nosub.opencode.json' } else { 'config\gyro_nosub.opencode.json' }
} elseif ($Model -like 'polystrata-mini*') {
  $localCfg = 'config\mini.opencode.json'
}
if ($localCfg) {
  New-Item -ItemType Directory -Force -Path (Join-Path $work '.opencode') | Out-Null
  Copy-Item -Path (Join-Path $Root $localCfg) `
            -Destination (Join-Path $work '.opencode\opencode.json') -Force
}

$prompt = 'Citeste REQUIREMENT.md din directorul curent si executa sarcina complet, fara intrebari. Modifica doar fisierele necesare. Ruleaza testele mentionate si verifica rezultatul inainte de a termina.'
$events  = Join-Path $resultDir 'events.jsonl'
$stderr  = Join-Path $resultDir 'stderr.log'
$vram    = Join-Path $resultDir 'vram.csv'
$metrics = Join-Path $resultDir 'metrics.json'
$evalOut = Join-Path $resultDir 'eval.json'

# VRAM/RAM sampler, 2s, runs only during this probe
$sampler = Start-Job -ScriptBlock {
  param($out, $stopFile)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  while (-not (Test-Path $stopFile)) {
    $line = & nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader,nounits 2>$null
    if ($line) { "$($sw.ElapsedMilliseconds),$($line -join ',')" | Out-File -FilePath $out -Append -Encoding ascii }
    Start-Sleep -Milliseconds 2000
  }
} -ArgumentList $vram, ($vram + '.stop')

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$startIso = (Get-Date).ToUniversalTime().ToString('o')
$exitCode = $null
$timedOut = $false
try {
  # V2 encodes the variant in the model ID: provider/model#variant (no --variant flag).
  $modelArg = if ($Variant) { "$Model#$Variant" } else { $Model }
  $argList = @('run','--model',$modelArg,'--format','json','--auto','--archived','--title',"$Batch/$modelSlug/$Task")
  $argList += $prompt
  if ($TimeoutSec -gt 0) {
    # Hard timeout: kill only this probe's process. Redirects are UTF-16; the parser accepts both.
    $proc = Start-Process -FilePath $exe -ArgumentList $argList -WorkingDirectory $work `
              -RedirectStandardOutput $events -RedirectStandardError $stderr -NoNewWindow -PassThru
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
      $timedOut = $true
      $proc.Kill()
      $exitCode = -1
    } else { $exitCode = $proc.ExitCode }
  } else {
    Push-Location $work
    try {
      & $exe @argList 2> $stderr | Out-File -FilePath $events -Encoding utf8
      $exitCode = $LASTEXITCODE
    } finally { Pop-Location }
  }
} finally {
  $sw.Stop()
  "stop" | Out-File -FilePath ($vram + '.stop') -Encoding ascii
  Wait-Job $sampler -Timeout 8 | Out-Null
  Stop-Job $sampler -ErrorAction SilentlyContinue
  Remove-Job $sampler -Force -ErrorAction SilentlyContinue
}
$endIso = (Get-Date).ToUniversalTime().ToString('o')

# parse event stream
node (Join-Path $Root 'scripts\parse_events.js') $events $metrics | Out-Null

# independent deterministic evaluation (criteria fixed before execution)
$evaluator = Join-Path $taskDir 'evaluate.py'
if (Test-Path $evaluator) {
  & python $evaluator --work $work --seed (Join-Path $taskDir 'seed') --out $evalOut 2>&1 | Out-File -FilePath (Join-Path $resultDir 'eval_stderr.log') -Encoding utf8
}

# VRAM aggregate
$vramMax = $null; $vramAvg = $null
if (Test-Path $vram) {
  $vals = @(Get-Content $vram | ForEach-Object { [double]($_ -split ',')[1] })
  if ($vals.Count -gt 0) { $vramMax = ($vals | Measure-Object -Maximum).Maximum; $vramAvg = [math]::Round(($vals | Measure-Object -Average).Average, 1) }
}

$m = Get-Content $metrics -Raw | ConvertFrom-Json
$m | Add-Member -NotePropertyName model -NotePropertyValue $Model -Force
$m | Add-Member -NotePropertyName task -NotePropertyValue $Task -Force
$m | Add-Member -NotePropertyName batch -NotePropertyValue $Batch -Force
$m | Add-Member -NotePropertyName wall_ms -NotePropertyValue ([int]$sw.ElapsedMilliseconds) -Force
$m | Add-Member -NotePropertyName start_iso -NotePropertyValue $startIso -Force
$m | Add-Member -NotePropertyName end_iso -NotePropertyValue $endIso -Force
$m | Add-Member -NotePropertyName exit_code -NotePropertyValue $exitCode -Force
$m | Add-Member -NotePropertyName timed_out -NotePropertyValue $timedOut -Force
$m | Add-Member -NotePropertyName vram_max_mib -NotePropertyValue $vramMax -Force
$m | Add-Member -NotePropertyName vram_avg_mib -NotePropertyValue $vramAvg -Force
$m | ConvertTo-Json -Depth 8 | Out-File -FilePath $metrics -Encoding utf8

"$Batch/$modelSlug/$Task wall_ms=$([int]$sw.ElapsedMilliseconds) exit=$exitCode tool_calls=$($m.tool_calls)"
