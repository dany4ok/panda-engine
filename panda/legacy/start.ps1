# Inkling 2 Mini - NInfer launcher (custom engine only)
# PowerShell 5.1 compatible. ASCII output only.

param([switch]$AutoStart)

$ErrorActionPreference = 'Continue'
try { $Host.UI.RawUI.WindowTitle = 'Inkling 2 Mini - NInfer' } catch {}

$Root       = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$ConfigPath = Join-Path $Root 'config.json'
$LogDir     = Join-Path $Root 'logs'
$RunDir     = Join-Path $Root 'run'
$StatsPath  = Join-Path $LogDir 'tokens.csv'
$NinferDir  = Join-Path $Root 'ninfer'
$ModelsDir  = Join-Path $Root 'models'
$KnownInkling = ''
try {
    $catalog = Get-Content -LiteralPath (Join-Path $Root 'panda\catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $KnownInkling = [string]$catalog.roots.knownInkling
} catch {}
$ApprovedNinferDirs = @($NinferDir)
if ($KnownInkling) { $ApprovedNinferDirs += (Join-Path $KnownInkling 'ninfer') }
$Contexts   = @(65536, 98304, 131072)
$Reasons    = @('minimal','low','medium','high','xhigh','max')

$script:PrevMetrics = $null
$script:LiveText    = 'Live: connecting to /metrics...'
$script:LiveLen     = 0
$script:LiveEnabled = $true

function Read-Config {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw 'config.json is missing.' }
    return ((Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8) | ConvertFrom-Json)
}
function Save-Config($c) { ($c | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $ConfigPath -Encoding UTF8 }
function Test-PathUnderDirectory([string]$Path, [string]$Directory) {
    if (-not $Path -or -not $Directory) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        if (-not $fullDirectory.EndsWith('\')) { $fullDirectory += '\' }
        return $fullPath.StartsWith($fullDirectory, [System.StringComparison]::OrdinalIgnoreCase)
    } catch { return $false }
}
function Test-CommandLineArgumentValue([string]$CommandLine, [string]$Name, [string]$Value) {
    if (-not $CommandLine -or -not $Name -or $null -eq $Value) { return $false }
    $escapedValue = [regex]::Escape([string]$Value)
    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Name) + '\s+(?:"' + $escapedValue + '"|' + $escapedValue + ')(?:\s|$)'
    return [regex]::IsMatch($CommandLine, $pattern)
}
function New-NinferOwnerRecord($Process, $c) {
    try {
        $Process.Refresh()
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$Process.Id) -ErrorAction Stop
        if (-not $cim -or -not $cim.ExecutablePath -or -not $cim.CommandLine) { return $null }
        return [pscustomobject]@{
            ProcessId = [int]$Process.Id
            StartedUtcTicks = [long]$Process.StartTime.ToUniversalTime().Ticks
            ExecutablePath = [string]$cim.ExecutablePath
            CommandLine = [string]$cim.CommandLine
            Artifact = [string]$c.artifact
            Port = [int]$c.port
        }
    } catch { return $null }
}
function Get-ValidatedNinferOwner($c) {
    $ownerPath = Join-Path $RunDir 'server.pid'
    if (-not (Test-Path -LiteralPath $ownerPath)) { return $null }
    try {
        $owner = Get-Content -LiteralPath $ownerPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $owner.ProcessId -or -not $owner.StartedUtcTicks -or -not $owner.ExecutablePath -or -not $owner.CommandLine) { return $null }
        if ([int]$owner.Port -ne [int]$c.port -or -not $owner.Artifact) { return $null }
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$owner.ProcessId) -ErrorAction Stop
        $process = Get-Process -Id ([int]$owner.ProcessId) -ErrorAction Stop
        $process.Refresh()
        if (-not $cim -or
            -not [string]::Equals([string]$cim.ExecutablePath, [string]$owner.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$cim.CommandLine, [string]$owner.CommandLine, [System.StringComparison]::OrdinalIgnoreCase) -or
            [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$owner.StartedUtcTicks -or
            [System.IO.Path]::GetFileName([string]$cim.ExecutablePath) -ine 'ninfer-serve.exe') { return $null }
        $approved = $false
        foreach ($directory in $ApprovedNinferDirs) {
            if (Test-PathUnderDirectory ([string]$cim.ExecutablePath) $directory) { $approved = $true; break }
        }
        $artifactPath = Join-Path $ModelsDir ([string]$owner.Artifact)
        if (-not $approved -or
            ([string]$cim.CommandLine).IndexOf($artifactPath, [System.StringComparison]::OrdinalIgnoreCase) -lt 0 -or
            -not (Test-CommandLineArgumentValue ([string]$cim.CommandLine) '--port' ([string]$owner.Port))) { return $null }
        return $process
    } catch { return $null }
}

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
    try {
        $server = Get-Process -Id $ServerPid -ErrorAction Stop
        $server.Refresh()
        $startTicks = $server.StartTime.ToUniversalTime().Ticks
    } catch { return }
    $cmd = '$parentId=' + $me + '; $serverId=' + $ServerPid + '; $startTicks=[long]' + $startTicks +
        '; while (Get-Process -Id $parentId -ErrorAction SilentlyContinue) { Start-Sleep -Seconds 2 };' +
        ' try { $p=Get-Process -Id $serverId -ErrorAction Stop; $p.Refresh(); if ($p.StartTime.ToUniversalTime().Ticks -eq $startTicks) { $p.Kill() } } catch {}'
    Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Command',$cmd) | Out-Null
    Write-Host ("Model will stop automatically when you close this terminal (server PID {0})." -f $ServerPid)
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
function Get-Metrics($c, [int]$TimeoutSec = 4) {
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/metrics" -f $c.port) -UseBasicParsing -TimeoutSec $TimeoutSec
        $t = [string]$r.Content
        $m = [regex]::Match($t, 'llamacpp:tokens_predicted_total\s+([\d.]+)')
        $tok = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        $m = [regex]::Match($t, 'llamacpp:tokens_predicted_seconds_total\s+([\d.]+)')
        $sec = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        $m = [regex]::Match($t, 'llamacpp:prompt_tokens_total\s+([\d.]+)')
        $prm = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        $m = [regex]::Match($t, 'llamacpp:prompt_seconds_total\s+([\d.]+)')
        $psec = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        $m = [regex]::Match($t, 'llamacpp:predicted_tokens_seconds\s+([\d.]+)')
        $avgGen = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        $m = [regex]::Match($t, 'llamacpp:prompt_tokens_seconds\s+([\d.]+)')
        $avgPrm = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        $m = [regex]::Match($t, 'llamacpp:requests_processing\s+([\d.]+)')
        $reqProc = if ($m.Success) { [double]$m.Groups[1].Value } else { $null }
        return [pscustomobject]@{ Tok=$tok; Sec=$sec; Prm=$prm; PSec=$psec; AvgGen=$avgGen; AvgPrm=$avgPrm; ReqProc=$reqProc }
    } catch { return $null }
}

# Redraw a single line in place. No ANSI dependency: pad to the previous length.
function Write-LiveLine([string]$buf = '') {
    $line = "  $($script:LiveText)  > $buf"
    $pad  = ''
    if ($line.Length -lt $script:LiveLen) { $pad = ' ' * ($script:LiveLen - $line.Length) }
    [Console]::Write("`r" + $line + $pad + "`r" + $line)
    $script:LiveLen = $line.Length
}

# Refresh the live counters from /metrics once per tick.
function Update-LiveText($c) {
    $m = Get-Metrics $c 1
    if ($null -eq $m -or $null -eq $m.Tok) {
        $script:LiveText = 'Live: server offline (/metrics not responding)'
        return
    }
    if ($null -eq $script:PrevMetrics) {
        $script:PrevMetrics = $m
        $script:LiveText = 'Live: collecting baseline...'
        return
    }
    $dTok  = [math]::Max(0, $m.Tok  - $script:PrevMetrics.Tok)
    $dSec  = [math]::Max(0, $m.Sec  - $script:PrevMetrics.Sec)
    $dPrm  = [math]::Max(0, $m.Prm  - $script:PrevMetrics.Prm)
    $dPSec = [math]::Max(0, $m.PSec - $script:PrevMetrics.PSec)
    $gen  = if ($dSec  -gt 0.05) { $dTok / $dSec }  else { 0 }
    $read = if ($dPSec -gt 0.05) { $dPrm / $dPSec } else { 0 }
    $req  = if ($null -ne $m.ReqProc) { $m.ReqProc } else { 0 }
    $script:LiveText = ("Live: gen {0:N1} t/s | read {1:N1} t/s | {2:N0} tok | {3:N0} req" -f $gen, $read, $m.Tok, $req)
    $script:PrevMetrics = $m
}

# Non-blocking input: the live line keeps updating while a command is being typed.
function Read-LiveInput($c, [string]$label) {
    if (-not $script:LiveEnabled) { return (Read-Host $label) }
    Write-Host ''
    $buf = ''
    $last = [datetime]::MinValue
    Update-LiveText $c
    Write-LiveLine $buf
    $last = Get-Date
    while ($true) {
        $ready = $false
        try { $ready = [Console]::KeyAvailable } catch { return (Read-Host $label) }
        if ($ready) {
            $k = $null
            try { $k = [Console]::ReadKey($true) } catch { return (Read-Host $label) }
            if ($k.Key -eq 'Enter') {
                [Console]::Write("`n")
                $script:LiveLen = 0
                return $buf
            } elseif ($k.Key -eq 'Backspace') {
                if ($buf.Length -gt 0) { $buf = $buf.Substring(0, $buf.Length - 1) }
            } elseif ($k.Key -eq 'Escape') {
                $buf = ''
            } elseif ($k.KeyChar -ne [char]0) {
                $buf += $k.KeyChar
            }
            Write-LiveLine $buf
        }
        if (((Get-Date) - $last).TotalSeconds -ge 1) {
            Update-LiveText $c
            Write-LiveLine $buf
            $last = Get-Date
        }
        Start-Sleep -Milliseconds 40
    }
}

function Show-Stats {
    $s = Get-Stats
    if ($s) {
        Write-Host ("  10 min stats: gen {0:N1} t/s | read/prompt {1:N1} t/s | {2:N0} tokens | {3:N0} req ({4:N2} req/s)" -f $s.GenTps, $s.PromptTps, $s.GenTokens, $s.Requests, $s.Rps)
    } else {
        Write-Host '  10 min stats: n/a (auto-updating from /metrics)'
    }
}
function Choose([string]$title, [array]$opts, [int]$def) {
    Write-Host ''
    Write-Host "== $title =="
    for ($i=0; $i -lt $opts.Count; $i++) {
        $mark = if ($i -eq $def) { '  <-- default' } else { '' }
        Write-Host ('  [{0}] {1}{2}' -f ($i+1), $opts[$i], $mark)
    }
    $a = Read-Host ("Select [1-{0}] (Enter = default)" -f $opts.Count)
    if ([string]::IsNullOrWhiteSpace($a)) { return $def }
    $n = 0
    if ([int]::TryParse($a,[ref]$n) -and $n -ge 1 -and $n -le $opts.Count) { return ($n-1) }
    return $def
}
function Show-Status($c) {
    $free = Get-FreeVram
    $conns = Get-NetTCPConnection -State Listen -LocalPort ([int]$c.port) -ErrorAction SilentlyContinue
    $state = if ($conns) { "ACTIVE (PID $($conns[0].OwningProcess))" } else { 'STOPPED' }
    Write-Host ''
    Write-Host '============================================================'
    Write-Host "  Inkling 2 Mini - NInfer"
    Write-Host ("  Context: {0}   Vision: YES   Spec: none   Reasoning: {1}" -f $c.context, $c.reasoning)
    Write-Host ("  Model: {0}" -f $c.artifact)
    Write-Host ("  Server: {0}   Port: {1}   VRAM free: {2} GiB" -f $state, $c.port, $free)
    Show-Stats
    Write-Host '============================================================'
}
function Stop-Sampler {
    $sf = Join-Path $RunDir 'sampler.pid'
    if (Test-Path -LiteralPath $sf) {
        $id=0
        if ([int]::TryParse((Get-Content $sf -Raw).Trim(),[ref]$id)) {
            $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $id) -ErrorAction SilentlyContinue
            $samplerScript = Join-Path $RunDir 'metrics-sampler.ps1'
            if ($p -and [int]$p.ParentProcessId -eq $PID -and $p.CommandLine -and
                $p.CommandLine.IndexOf($samplerScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
                (Test-CommandLineArgumentValue ([string]$p.CommandLine) '-ParentPid' ([string]$PID))) {
                Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath $sf -Force -ErrorAction SilentlyContinue
    }
}
function Stop-Server($c) {
    Stop-Sampler
    $pf = Join-Path $RunDir 'server.pid'
    if (Test-Path -LiteralPath $pf) {
        $owner = $null
        try { $owner = Get-Content -LiteralPath $pf -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
        $ownedProcess = Get-ValidatedNinferOwner $c
        $removeOwnerRecord = $false
        if ($ownedProcess) {
            try {
                $ownedProcess.Kill()
                $ownedProcess.WaitForExit(5000)
                $ownedProcess.Refresh()
                if ($ownedProcess.HasExited) {
                    $removeOwnerRecord = $true
                    Write-Host ("Stopped owned NInfer server PID {0}" -f $owner.ProcessId)
                } else {
                    Write-Host 'WARNING: Owned NInfer server did not exit; preserving its ownership record.'
                }
            } catch {
                Write-Host 'WARNING: Owned NInfer server could not be confirmed stopped; preserving its ownership record.'
            }
        } elseif ($owner -and $owner.ProcessId) {
            Write-Host 'WARNING: NInfer ownership could not be confirmed; leaving the process and ownership record untouched.'
        } else {
            Write-Host 'WARNING: NInfer ownership record is unreadable; preserving it for safe recovery.'
        }
        if ($removeOwnerRecord) { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
    }
    $script:PrevMetrics = $null
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
    if (-not $exe) { Write-Host 'ERROR: ninfer-serve.exe is missing.'; return }
    $art = Join-Path $ModelsDir $c.artifact
    if (-not (Test-Path -LiteralPath $art)) { Write-Host "ERROR: artifact $($c.artifact) is missing."; return }
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$c.port) -ErrorAction SilentlyContinue)
    if ($listeners.Count -gt 0) {
        Write-Host ("ERROR: port {0} is occupied; no unowned process was touched." -f $c.port)
        return
    }
    New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
    New-Item -ItemType Directory -Force -Path $RunDir | Out-Null
    Write-Host ("Starting NInfer: {0}" -f $exe)
    $argLine = '"' + $art + '" --model-id inkling-2-mini --max-context ' + [string]$c.context +
        ' --kv-capacity ' + [string]$c.context + ' --expert-residency device --vision --spec none' +
        ' --reasoning-loop conclude --presence-penalty 0 --frequency-penalty 0 --structured-output' +
        ' --host 127.0.0.1 --port ' + [string]$c.port
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $p = Start-Process -FilePath $exe -ArgumentList $argLine -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $LogDir "ninfer-$stamp.out.log") -RedirectStandardError (Join-Path $LogDir "ninfer-$stamp.err.log")
    $owner = $null
    for ($i = 0; $i -lt 15 -and -not $owner; $i++) {
        $owner = New-NinferOwnerRecord $p $c
        if (-not $owner) { Start-Sleep -Milliseconds 200 }
    }
    if (-not $owner) {
        Write-Host 'ERROR: Could not establish NInfer process ownership; stopping only the just-launched process.'
        try { $p.Kill() } catch {}
        return
    }
    try {
        $owner | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $RunDir 'server.pid') -Encoding UTF8
    } catch {
        Write-Host 'ERROR: Could not save NInfer ownership; stopping only the just-launched process.'
        try { $p.Kill() } catch {}
        return
    }
    Register-Lifecycle $p.Id
    if (-not (Wait-Health $c 120)) {
        Write-Host 'ERROR: server not ready. Last log lines:'
        Get-Content (Join-Path $LogDir "ninfer-$stamp.err.log") -Tail 20
        return
    }
    Start-MetricsSampler $c
    $script:PrevMetrics = $null
    Write-Host ("READY: http://127.0.0.1:{0}/v1  |  OpenCode ID: ninfer/inkling-2-mini" -f $c.port)
    Write-Host '  Live metrics refresh automatically every second. No key press needed.'
    Session-Loop $c
}
function Test-Prompt($c) {
    $code = 'PONG' + (Get-Random -Maximum 99999)
    $body = @{ model='inkling-2-mini'; messages=@(@{role='user';content="Reply with exactly: $code"}); max_tokens=256; reasoning_effort=$c.reasoning } | ConvertTo-Json -Depth 5
    try {
        $r = Invoke-RestMethod -Uri ("http://127.0.0.1:{0}/v1/chat/completions" -f $c.port) -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 45
        $t = [string]$r.choices[0].message.content
        Write-Host ("  {0}: {1}" -f $(if($t.Contains($code)){'OK prompt read'}else{'FAIL'}), $t)
        if ($r.timings -and $r.timings.predicted_per_second) {
            $genTps = [double]$r.timings.predicted_per_second
            $readTps = if ($r.timings.prompt_per_second) { [double]$r.timings.prompt_per_second } else { 0 }
            $gen = if ($r.usage.completion_tokens) { [double]$r.usage.completion_tokens } else { [double]$r.timings.predicted_n }
            Write-Host ("  now: gen {0:N1} t/s | read/prompt {1:N1} t/s | {2:N0} tokens" -f $genTps, $readTps, $gen)
        }
        Show-Stats
    } catch { $d=''; try{$d=[string]$_.ErrorDetails.Message}catch{}; Write-Host ("  ERROR: {0} {1}" -f $_.Exception.Message,$d) }
}
function Settings($c) {
    while ($true) {
        Write-Host ''
        Write-Host ("  1. Context   : {0}" -f $c.context)
        Write-Host ("  2. Model     : {0}" -f $c.artifact)
        Write-Host ("  3. Reasoning : {0}" -f $c.reasoning)
        Write-Host '  0. Back'
        switch (Read-Host 'Select') {
            '1' { $d=[array]::IndexOf($Contexts,[int]$c.context); if($d -lt 0){$d=2}; $c.context=$Contexts[(Choose 'Context' @($Contexts|ForEach-Object{"$_ tokens"}) $d)] }
            '2' {
                $arts = @(Get-ChildItem -LiteralPath $ModelsDir -File -Filter '*.ninfer' | ForEach-Object { $_.Name })
                if ($arts.Count -eq 0) { Write-Host 'No .ninfer artifact found.' } else {
                    $d=[array]::IndexOf($arts,$c.artifact); if($d -lt 0){$d=0}
                    $c.artifact = $arts[(Choose 'Model artifact' $arts $d)]
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
        Write-Host '  [T] test prompt   [S] status   [P] 10 min stats   [L] toggle live   [O] stop   [Q] exit'
        $a = Read-LiveInput $c 'Command'
        switch ($a.ToUpper()) {
            'T' { Test-Prompt $c }
            'S' { Show-Status $c }
            'P' { Show-Stats }
            'L' {
                $script:LiveEnabled = -not $script:LiveEnabled
                Write-Host ("Live display: {0}" -f $(if($script:LiveEnabled){'ON'}else{'OFF'}))
            }
            'O' { Stop-Server $c; Write-Host 'Stopped.'; return }
            'Q' { return }
            default { Write-Host 'Unknown command.' }
        }
    }
}

$c = Read-Config
if ($AutoStart) { Stop-Server $c; Start-Ninfer $c; exit 0 }
while ($true) {
    Show-Status $c
    Write-Host ''
    Write-Host '  [1] Start model   [2] Settings   [3] Stop   [4] Test prompt   [0] Exit'
    $a = Read-LiveInput $c 'Select'
    switch ($a.ToUpper()) {
        '1' { Stop-Server $c; Start-Ninfer $c }
        '2' { Settings $c }
        '3' { Stop-Server $c; Write-Host 'Stopped.' }
        '4' { Test-Prompt $c }
        '0' { exit 0 }
        default { Write-Host 'Unknown command.' }
    }
}
