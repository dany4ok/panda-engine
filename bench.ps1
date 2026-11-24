# Benchmark NInfer decode speed (tokens/s). Max 3 minutes per run.
param([int]$Tokens=256,[int]$Runs=3,[int]$MaxSeconds=150,[int]$Context=131072,[string]$Artifact='Inkling-2-Mini-UD-IQ1_M-ninfer-v3.ninfer',[string]$Residency='device',[string]$Spec='none')

$ErrorActionPreference='Continue'
$Root=Split-Path -Parent $MyInvocation.MyCommand.Definition
$deadline=(Get-Date).AddSeconds($MaxSeconds)
$LogDir=Join-Path $Root 'logs'
$port=8080
$exe=Get-ChildItem -LiteralPath (Join-Path $Root 'ninfer') -Recurse -File -Filter 'ninfer-serve.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
$art=Join-Path $Root ('models\' + $Artifact)
if(-not $exe -or -not (Test-Path $art)){ Write-Host "EROARE: exe=$exe artifact=$art"; exit 1 }

# stop old server on 8080
Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue | ForEach-Object { $p=Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; if($p -and $p.ProcessName -match 'ninfer'){Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue} }

$resFlags = if ($Residency -eq 'device') { 'device' } else { 'host --expert-host-mib 9500 --host-kv-mib 512' }
$extraFlags = '--reasoning-loop conclude --presence-penalty 0 --frequency-penalty 0 --structured-output'
$argLine='"'+ $art +'" --model-id inkling-2-mini --max-context '+$Context+' --kv-capacity '+$Context+' --expert-residency '+$resFlags+' --vision --spec '+$Spec+' '+$extraFlags+' --host 127.0.0.1 --port '+$port
$stamp=Get-Date -Format 'yyyyMMdd-HHmmss'
$p=Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LogDir "bench-ninfer-$stamp.out.log") -RedirectStandardError (Join-Path $LogDir "bench-ninfer-$stamp.err.log")
$me=$PID
$watch='while (Get-Process -Id {0} -ErrorAction SilentlyContinue) {{ Start-Sleep -Seconds 2 }}; Stop-Process -Id {1} -Force -ErrorAction SilentlyContinue' -f $me,$p.Id
$watcher = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$watch)
Write-Host ("Server PID {0}; astept health..." -f $p.Id)
$ok=$false
for($i=0;$i -lt 120;$i++){
    if((Get-Date) -gt $deadline){ Write-Host 'WATCHDOG timeout la health.'; break }
    if($p.HasExited){break}
    Start-Sleep -Seconds 1
    try{ $h=Invoke-RestMethod -Uri "http://127.0.0.1:$port/health" -TimeoutSec 2; if($h -eq 'ok' -or $h.status -eq 'ok'){$ok=$true;break} }catch{}
}
if(-not $ok){ Write-Host 'EROARE: serverul nu e gata.'; Get-Content (Join-Path $LogDir "bench-ninfer-$stamp.err.log") -Tail 30; Get-Content (Join-Path $LogDir "bench-ninfer-$stamp.out.log") -Tail 15; exit 1 }

$vals=@()
for($r=1;$r -le $Runs;$r++){
    if($r -gt 1){ Start-Sleep -Seconds 8 }
    if((Get-Date) -gt $deadline){ Write-Host 'WATCHDOG: opresc benchmarkul.'; break }
    $body=@{model='inkling-2-mini';messages=@(@{role='user';content='Scrie o poveste scurta despre un robot care deseneaza. Continua liber.'});max_tokens=$Tokens;reasoning_effort='max'}|ConvertTo-Json -Depth 5
    $sw=[Diagnostics.Stopwatch]::StartNew()
    try{
        $res=Invoke-RestMethod -Uri "http://127.0.0.1:$port/v1/chat/completions" -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 40
        $sw.Stop()
        $gen=[double]$res.usage.completion_tokens
        if($res.timings -and $res.timings.predicted_n){$gen=[double]$res.timings.predicted_n}
        $tps=$gen/[Math]::Max(0.001,$sw.Elapsed.TotalSeconds)
        if($res.timings -and $res.timings.predicted_per_second){$tps=[double]$res.timings.predicted_per_second}
        $vals+=$tps
        Write-Host ("  run {0}: {1} tok/s ({2} tokeni in {3:N2}s)" -f $r,[math]::Round($tps,1),$gen,$sw.Elapsed.TotalSeconds)
    }catch{ $d='';try{$d=[string]$_.ErrorDetails.Message}catch{}; Write-Host ("  run {0}: EROARE {1} {2}" -f $r,$_.Exception.Message,$d) }
}
if($vals.Count -gt 0){
    $avg=[math]::Round(($vals|Measure-Object -Average).Average,1)
    Write-Host ("REZULTAT: medie {0} tok/s | prag 80 -> {1}" -f $avg,$(if($avg -ge 80){'ATINS'}else{'NU ATINS'}))
    Add-Content -LiteralPath (Join-Path $LogDir 'bench-results.txt') -Value ("$(Get-Date -Format s) ninfer artifact=$Artifact residency=$Residency ctx=$Context avg=$avg")
} else { Write-Host 'Nici un run valid.' }
Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue
Write-Host 'Benchmark incheiat: serverul si watchdog-ul au fost oprite.'
