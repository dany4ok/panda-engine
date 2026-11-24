# Inkling 2 Mini - launcher NInfer (doar motorul custom)
# PowerShell 5.1 compatible. ASCII messages only.

param([switch]$AutoStart)

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'Inkling 2 Mini - NInfer' } catch {}

$Root       = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition))
$ConfigPath = Join-Path $Root 'config.json'
$LogDir     = Join-Path $Root 'logs'
$RunDir     = Join-Path $Root 'run'
$StatsPath  = Join-Path $LogDir 'tokens.csv'
$NinferDir  = Join-Path $Root 'ninfer'
$ModelsDir  = Join-Path $Root 'models'
$Contexts   = @(65536, 98304, 131072)
$Reasons    = @('minimal','low','medium','high','xhigh','max')

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'config.json lipseste.' }
    return ((Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json)
}
function Save-Config($c) { ($c | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }

function Get-Exe {
    Get-ChildItem -LiteralPath $NinferDir -Recurse -File -Filter 'ninfer-serve.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}
function Get-FreeVram {
    try { $l = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null | Select-Object -First 1; if ($l) { return [math]::Round([double]$l/1024,1) } } catch {}
    return -1
}
function Register-Lifecycle([int]$ServerPid) {
    $me = $PID
    $cmd = 'while (Get-Process -Id {0} -ErrorAction SilentlyContinue) {{ Start-Sleep -Seconds 2 }}; Stop-Process -Id {1} -Force -ErrorAction SilentlyContinue' -f $me, $ServerPid
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd) | Out-Null
    Write-Host ("Modelul se va opri automat cand inchizi acest terminal (server PID {0})." -f $ServerPid)
}
function Get-Stats {
    if (-not (Test-Path -LiteralPath $StatsPath)) { return $null }
    $cut = (Get-Date).AddMinutes(-10)
    $rows = @(Import-Csv -LiteralPath $StatsPath -ErrorAction SilentlyContinue | Where-Object {
        $d = [datetime]::MinValue
        if ([datetime]::TryParse($_.time, [ref]$d)) { $d -gt $cut } else { $false }
    })
    if ($rows.Count -eq 0) { return $null }
    $gen  = [double](($rows | Measure-Object -Property gen_tokens -Sum).Sum)
    $tps  = [double](($rows | Measure-Object -Property gen_tps -Average).Average)
    $ptps = [double](($rows | Measure-Object -Property prompt_tps -Average).Average)
    return [pscustomobject]@{ Requests=$rows.Count; GenTokens=$gen; GenTps=$tps; PromptTps=$ptps; Rps=($rows.Count/600.0) }
}
function Show-Stats {
    $s = Get-Stats
    if ($s) {
        Write-Host ("  Statistici 10 min: gen {0:N1} t/s | read/prompt {1:N1} t/s | {2} tokeni | {3} req ({4:N2} req/s)" -f $s.GenTps, $s.PromptTps, $s.GenTokens, $s.Requests, $s.Rps)
    } else {
        Write-Host '  Statistici 10 min: n/a (se actualizeaza automat din /metrics)'
    }
}
function Choose([string]$title, [array]$opts, [int]$def) {
    Write-Host ''
    Write-Host "== $title =="
    for ($i=0; $i -lt $opts.Count; $i++) {
        $mark = if ($i -eq $def) { '  <-- default' } else { '' }
        Write-Host ('  [{0}] {1}{2}' -f ($i+1), $opts[$i], $mark)
    }
    $a = Read-Host ("Alege [1-{0}] (Enter = default)" -f $opts.Count)
    if ([string]::IsNullOrWhiteSpace($a)) { return $def }
    $n = 0
    if ([int]::TryParse($a,[ref]$n) -and $n -ge 1 -and $n -le $opts.Count) { return ($n-1) }
    return $def
}
function Show-Status($c) {
    $free = Get-FreeVram
    $conns = Get-NetTCPConnection -State Listen -LocalPort ([int]$c.port) -ErrorAction SilentlyContinue
    $state = if ($conns) { "ACTIV (PID $($conns[0].OwningProcess))" } else { 'OPRIT' }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host "  Inkling 2 Mini - NInfer"
    Write-Host ("  Context: {0}   Vision: DA   Spec: none   Reasoning: {1}" -f $c.context, $c.reasoning)
    Write-Host ("  Model: {0}" -f $c.artifact)
    Write-Host ("  Server: {0}   Port: {1}   VRAM liber: {2} GiB" -f $state, $c.port, $free)
    Show-Stats
    Write-Host '============================================================'
}
function Stop-Sampler {
    $sf = Join-Path $RunDir 'sampler.pid'
    if (Test-Path -LiteralPath $sf) {
        $id=0; if ([int]::TryParse((Get-Content $sf -Raw).Trim(),[ref]$id)) { $p=Get-Process -Id $id -ErrorAction SilentlyContinue; if($p){Stop-Process -Id $id -Force -ErrorAction SilentlyContinue} }
        Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue
    }
}
function Stop-Server($c) {
    Stop-Sampler
    $pf = Join-Path $RunDir 'server.pid'
    if (Test-Path -LiteralPath $pf) {
        $id=0; if ([int]::TryParse((Get-Content $pf -Raw).Trim(),[ref]$id)) { $p=Get-Process -Id $id -ErrorAction SilentlyContinue; if($p){Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; Write-Host ("Oprit PID {0}" -f $id)} }
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
    }
    Get-NetTCPConnection -State Listen -LocalPort ([int]$c.port) -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -match 'ninfer') { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Write-Host ("Oprit PID {0}" -f $p.Id) }
    }
}
function Wait-Health($c,[int]$maxSec) {
    for ($i=0; $i -lt $maxSec; $i++) {
        Start-Sleep -Seconds 1
        try { $h = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/health" -f $c.port) -TimeoutSec 2; if ($h -eq 'ok' -or $h.status -eq 'ok') { return $true } } catch {}
    }
    return $false
}
function Start-MetricsSampler($c) {
    $script = Join-Path $RunDir 'metrics-sampler.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    Stop-Sampler
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -ParentPid {1} -Port {2} -Csv "{3}"' -f $script, $PID, $c.port, $StatsPath
    $sp = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList $argLine
    $sp.Id | Set-Content -LiteralPath (Join-Path $RunDir 'sampler.pid') -Encoding ASCII
}
function Start-Ninfer($c) {
    $exe = Get-Exe
    if (-not $exe) { Write-Host 'EROARE: ninfer-serve.exe lipseste.'; return }
    $art = Join-Path $ModelsDir $c.artifact
    if (-not (Test-Path -LiteralPath $art)) { Write-Host "EROARE: artefactul $($c.artifact) lipseste."; return }
    Write-Host ("Pornesc NInfer: {0}" -f $exe)
    $argLine = '"' + $art + '" --model-id inkling-2-mini --max-context ' + [string]$c.context +
        ' --kv-capacity ' + [string]$c.context + ' --expert-residency device --vision --spec none' +
        ' --reasoning-loop conclude --presence-penalty 0 --frequency-penalty 0 --structured-output' +
        ' --host 127.0.0.1 --port ' + [string]$c.port
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LogDir "ninfer-$stamp.out.log") -RedirectStandardError (Join-Path $LogDir "ninfer-$stamp.err.log")
    $p.Id | Set-Content -LiteralPath (Join-Path $RunDir 'server.pid') -Encoding ASCII
    Register-Lifecycle $p.Id
    if (-not (Wait-Health $c 120)) {
        Write-Host 'EROARE: serverul nu e gata. Ultimele linii din log:'
        Get-Content (Join-Path $LogDir "ninfer-$stamp.err.log") -Tail 20
        return
    }
    Start-MetricsSampler $c
    Write-Host ("GATA: http://127.0.0.1:{0}/v1  |  ID OpenCode: ninfer/inkling-2-mini" -f $c.port)
    Session-Loop $c
}
function Test-Prompt($c) {
    $code = 'PONG' + (Get-Random -Maximum 99999)
    $body = @{ model='inkling-2-mini'; messages=@(@{role='user';content="Raspunde doar cu exact: $code"}); max_tokens=256; reasoning_effort=$c.reasoning } | ConvertTo-Json -Depth 5
    try {
        $r = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/chat/completions" -f $c.port) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 45
        $t = [string]$r.choices[0].message.content
        Write-Host ("  {0}: {1}" -f $(if($t.Contains($code)){'OK prompt citit'}else{'FAIL'}), $t)
        if ($r.timings -and $r.timings.predicted_per_second) {
            $genTps = [double]$r.timings.predicted_per_second
            $readTps = if ($r.timings.prompt_per_second) { [double]$r.timings.prompt_per_second } else { 0 }
            $gen = if ($r.usage.completion_tokens) { [double]$r.usage.completion_tokens } else { [double]$r.timings.predicted_n }
            Write-Host ("  acum: gen {0:N1} t/s | read/prompt {1:N1} t/s | {2} tokeni" -f $genTps, $readTps, $gen)
        }
        Show-Stats
    } catch { $d=''; try{$d=[string]$_.ErrorDetails.Message}catch{}; Write-Host ("  EROARE: {0} {1}" -f $_.Exception.Message,$d) }
}
function Settings($c) {
    while ($true) {
        Write-Host ''
        Write-Host ("  1. Context   : {0}" -f $c.context)
        Write-Host ("  2. Model     : {0}" -f $c.artifact)
        Write-Host ("  3. Reasoning : {0}" -f $c.reasoning)
        Write-Host '  0. Inapoi'
        switch (Read-Host 'Alege') {
            '1' { $d=[array]::IndexOf($Contexts,[int]$c.context); if($d -lt 0){$d=2}; $c.context=$Contexts[(Choose 'Context' @($Contexts|ForEach-Object{"$_ tokeni"}) $d)] }
            '2' {
                $arts = @(Get-ChildItem -LiteralPath $ModelsDir -File -Filter '*.ninfer' | ForEach-Object { $_.Name })
                if ($arts.Count -eq 0) { Write-Host 'Niciun artefact .ninfer.' } else {
                    $d=[array]::IndexOf($arts,$c.artifact); if($d -lt 0){$d=0}
                    $c.artifact = $arts[(Choose 'Artefact model' $arts $d)]
                }
            }
            '3' { $d=[array]::IndexOf($Reasons,$c.reasoning); if($d -lt 0){$d=5}; $c.reasoning=$Reasons[(Choose 'Reasoning' $Reasons $d)] }
            '0' { Save-Config $c; return }
        }
    }
}
function Session-Loop($c) {
    while ($true) {
        Write-Host ''
        Write-Host '  [T] test prompt   [S] status   [P] statistici 10 min   [O] opreste   [Q] iesire'
        switch ((Read-Host 'Comanda').ToUpper()) {
            'T' { Test-Prompt $c }
            'S' { Show-Status $c }
            'P' { Show-Stats }
            'O' { Stop-Server $c; Write-Host 'Oprit.'; return }
            'Q' { return }
            default { Write-Host 'Comanda necunoscuta.' }
        }
    }
}

$c = Read-Config
if ($AutoStart) { Stop-Server $c; Start-Ninfer $c; exit 0 }
while ($true) {
    Show-Status $c
    Write-Host ''
    Write-Host '  [1] Porneste modelul   [2] Setari   [3] Opreste   [4] Test prompt   [0] Iesire'
    switch (Read-Host 'Alege') {
        '1' { Stop-Server $c; Start-Ninfer $c }
        '2' { Settings $c }
        '3' { Stop-Server $c; Write-Host 'Oprit.' }
        '4' { Test-Prompt $c }
        '0' { exit 0 }
        default { Write-Host 'Comanda necunoscuta.' }
    }
}
