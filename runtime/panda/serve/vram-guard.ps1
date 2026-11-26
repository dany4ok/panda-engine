param(
    [int]$Port          = 8080,
    [int]$PollSeconds   = 1,       # fine-grained polling; the poll counts below keep the timing
    [int]$FastToGameMs  = 11000,   # free VRAM below this (model NOT loaded) -> another app needs the GPU
    [int]$GameToFastMs  = 13000,   # free VRAM above this -> GPU is free again
    [int]$FastToGamePolls = 8,     # ~8 s of low VRAM before switching to RAM/SSD
    [int]$GameToFastPolls = 12,    # ~12 s of free VRAM before switching back to GPU
    [int]$PressureFreeMib = 1500,  # fast mode, model loaded: free below this = another app took the reserved headroom
    [int]$PressurePolls   = 5      # ~5 s of pressure -> release VRAM, overriding any hot-time guarantee
)

# VRAM-only adaptive guard.
# No process-name heuristics and no idle timer in the fast config (idle_unload_s: 0):
#   model unloaded + free < 11 GB  -> RAM/SSD mode, 0 experts in VRAM
#   free > 13 GB                   -> fast GPU mode (model loads on request)
#   model loaded + free < 1.5 GB   -> another app took the reserved headroom; switch
#                                    to RAM/SSD after ~5 s, regardless of how long the
#                                    model has been loaded (pressure overrides hot time)
# With no pressure there is no idle timer at all (idle_unload_s: 0), so the model stays
# in VRAM indefinitely (well beyond 5 minutes).
# The fast config reserves ~4 GB of VRAM (--vram-reserve-mib 4000) so free VRAM stays
# a meaningful signal while the model is loaded. The gap between thresholds avoids flapping.
# Log + console: panda-adaptive-guard.log

$ErrorActionPreference = 'SilentlyContinue'
$ProgressPreference    = 'SilentlyContinue'

$Root     = Split-Path -Parent $PSScriptRoot
$FastCfg  = Join-Path $Root 'panda-minicpmv-q4_k_m-review.json'
$GameCfg  = Join-Path $Root 'panda-minicpmv-q4_k_m-cpu.json'
$Python   = Join-Path $Root '.venv\Scripts\python.exe'
$ServerPy = 'serve\server.py'
$Log      = Join-Path $Root 'panda-adaptive-guard.log'
$Base     = "http://127.0.0.1:$Port"
$script:OwnedServer = $null
$script:UnverifiedStartedProcess = $null
$script:EngineEnumerationSucceeded = $true

function Rotate-Log([string]$path) {
    try {
        if ($path -and (Test-Path $path) -and (Get-Item $path).Length -gt 5MB) {
            $bak = $path -replace '\.log$', ".old-$(Get-Date -Format yyyyMMdd-HHmmss).log"
            Move-Item $path $bak -Force
        }
    } catch { }
}

function Log([string]$msg) {
    Rotate-Log $Log
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
    Add-Content -Path $Log -Value $line -Encoding UTF8
    Write-Host $line
}

function Get-FreeVramMib {
    try {
        $v = & nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>$null
        if ($v -match '(\d+)') { return [int]$Matches[1] }
    } catch { }
    return $null
}

function Get-Health {
    # One request gives both "server up" and "model loaded".
    try {
        $h = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/health') -TimeoutSec 5
        return [pscustomobject]@{ Up = $true; Loaded = [bool]$h.loaded }
    } catch {
        return [pscustomobject]@{ Up = $false; Loaded = $false }
    }
}

function Test-Busy {
    # A running or queued request must never be killed by a config switch.
    try {
        $s = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/status') -TimeoutSec 5
        return [bool]($s.busy -or $s.queued)
    } catch {
        # Unreadable status: behave as if a task is running, never switch blindly.
        return $true
    }
}

function Get-PortListenerSnapshot {
    try {
        $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
        $processIds = @($connections | ForEach-Object { [int]$_.OwningProcess } | Select-Object -Unique)
        return [pscustomobject]@{ Success = $true; ProcessIds = $processIds; Error = '' }
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound,*') {
            return [pscustomobject]@{ Success = $true; ProcessIds = @(); Error = '' }
        }
        return [pscustomobject]@{ Success = $false; ProcessIds = @(); Error = $_.Exception.Message }
    }
}

function Get-VerifiedOwnedServer {
    $record = $script:OwnedServer
    if (-not $record -or [int]$record.Port -ne $Port) { return $null }
    try {
        $live = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$record.ProcessId) -ErrorAction Stop
        $process = $record.Process
        if (-not $process) { return $null }
        $null = $process.Handle
        $process.Refresh()
        $startTicks = [long]$process.StartTime.ToUniversalTime().Ticks
        $executable = [System.IO.Path]::GetFullPath([string]$live.ExecutablePath)
        if ([int]$live.ProcessId -ne [int]$record.ProcessId -or
            [int]$live.ParentProcessId -ne [int]$record.ParentProcessId -or
            $startTicks -ne [long]$record.StartedUtcTicks -or
            -not [string]::Equals($executable, [string]$record.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$live.CommandLine, [string]$record.CommandLine, [System.StringComparison]::Ordinal)) {
            return $null
        }
        return [pscustomobject]@{ Cim = $live; Process = $process }
    } catch {
        return $null
    }
}

function Get-OurServerPids {
    $owned = Get-VerifiedOwnedServer
    if ($owned) { return @([int]$script:OwnedServer.ProcessId) }
    return @()
}

function Test-OwnedServerListener([int]$ListenerPid) {
    $owned = Get-VerifiedOwnedServer
    if (-not $owned) { return $false }
    if ($ListenerPid -eq [int]$script:OwnedServer.ProcessId) { return $true }
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        $listener = $processes | Where-Object { [int]$_.ProcessId -eq $ListenerPid } | Select-Object -First 1
        if (-not $listener -or [string]$listener.CommandLine -ne [string]$script:OwnedServer.CommandLine) { return $false }
        return (Test-ProcessDescendsFrom $ListenerPid ([int]$script:OwnedServer.ProcessId) $processes)
    } catch { return $false }
}

function Test-ProcessDescendsFrom([int]$ProcessId, [int]$AncestorId, $Processes) {
    $byId = @{}
    foreach ($process in $Processes) { $byId[[int]$process.ProcessId] = $process }
    $seen = @{}
    $current = $ProcessId
    for ($depth = 0; $depth -lt 64; $depth++) {
        if ($current -le 0 -or $seen.ContainsKey($current)) { return $false }
        $seen[$current] = $true
        if (-not $byId.ContainsKey($current)) { return $false }
        $parent = [int]$byId[$current].ParentProcessId
        if (-not $byId.ContainsKey($parent) -or -not $byId[$current].CreationDate -or
            -not $byId[$parent].CreationDate -or $byId[$current].CreationDate -lt $byId[$parent].CreationDate) {
            return $false
        }
        if ($parent -eq $AncestorId) { return $true }
        $current = $parent
    }
    return $false
}

function Get-OurEnginePids {
    $script:EngineEnumerationSucceeded = $false
    $servers = @(Get-OurServerPids)
    if (-not $servers.Count) {
        $script:EngineEnumerationSucceeded = $true
        return @()
    }
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        return @()
    }
    $rootPath = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    $mine = @()
    foreach ($process in $processes) {
        if ($process.Name -notin @('panda-poly.exe','panda-vision.exe') -or
            -not $process.ExecutablePath -or
            [string]$process.CommandLine -notmatch 'minicpmv-Q4_K_M') { continue }
        try { $executable = [System.IO.Path]::GetFullPath([string]$process.ExecutablePath) } catch { continue }
        if (-not $executable.StartsWith($rootPath, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        foreach ($serverPid in $servers) {
            if (Test-ProcessDescendsFrom ([int]$process.ProcessId) ([int]$serverPid) $processes) {
                $mine += [int]$process.ProcessId
                break
            }
        }
    }
    $script:EngineEnumerationSucceeded = $true
    return @($mine | Select-Object -Unique)
}

function Stop-PidIfOurs([int]$procId) {
    if ($procId -le 0 -or $procId -eq $PID) { return $false }
    if ($script:OwnedServer -and $procId -eq [int]$script:OwnedServer.ProcessId) {
        $owned = Get-VerifiedOwnedServer
        if (-not $owned) { return $false }
        try {
            $listeners = Get-PortListenerSnapshot
            if (-not $listeners.Success) { return $false }
            foreach ($listenerPid in $listeners.ProcessIds) {
                if ([int]$listenerPid -eq $procId) { continue }
                if (-not (Test-OwnedServerListener ([int]$listenerPid))) { return $false }
                $listenerProcess = Get-Process -Id ([int]$listenerPid) -ErrorAction Stop
                $null = $listenerProcess.Handle
                if (-not (Test-OwnedServerListener ([int]$listenerPid))) { return $false }
                $listenerProcess.Kill()
                $null = $listenerProcess.WaitForExit(5000)
                if (-not $listenerProcess.HasExited) { return $false }
            }
            $owned.Process.Refresh()
            if (-not $owned.Process.HasExited) { $owned.Process.Kill() }
            $null = $owned.Process.WaitForExit(5000)
            $owned.Process.Refresh()
            if (-not $owned.Process.HasExited) { return $false }
            $script:OwnedServer = $null
            return $true
        } catch { return $false }
    }

    $enginePids = @(Get-OurEnginePids)
    if (-not $script:EngineEnumerationSucceeded -or $enginePids -notcontains $procId) { return $false }
    try {
        $before = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
        $process = Get-Process -Id $procId -ErrorAction Stop
        $null = $process.Handle
        $process.Refresh()
        $startTicks = [long]$process.StartTime.ToUniversalTime().Ticks
        $after = Get-CimInstance Win32_Process -Filter "ProcessId=$procId" -ErrorAction Stop
        $process.Refresh()
        if ([long]$process.StartTime.ToUniversalTime().Ticks -ne $startTicks -or
            [string]$before.CommandLine -ne [string]$after.CommandLine -or
            [string]$before.ExecutablePath -ne [string]$after.ExecutablePath -or
            @(Get-OurEnginePids) -notcontains $procId) {
            return $false
        }
        $process.Kill()
        $null = $process.WaitForExit(5000)
        $process.Refresh()
        if (-not $process.HasExited) { return $false }
        $remainingEngines = @(Get-OurEnginePids)
        return ($script:EngineEnumerationSucceeded -and $remainingEngines -notcontains $procId)
    } catch {
        return $false
    }
}

function Free-Port {
    return (Stop-Server)
}

function Stop-Server {
    $snapshot = Get-PortListenerSnapshot
    if (-not $snapshot.Success) {
        Log "nu pot inspecta listenerii de pe portul $Port; nu opresc niciun proces. $($snapshot.Error)"
        return $false
    }
    $owners = @($snapshot.ProcessIds)
    $owned = Get-VerifiedOwnedServer
    if ($script:OwnedServer -and -not $owned) {
        try {
            $script:OwnedServer.Process.Refresh()
            if (-not $script:OwnedServer.Process.HasExited) {
                Log 'nu pot revalida procesul administrat care inca ruleaza; il las neatins si pastrez proprietatea.'
                return $false
            }
            $script:OwnedServer = $null
        } catch {
            Log 'nu pot confirma daca procesul administrat a iesit; pastrez proprietatea.'
            return $false
        }
    }
    $ownedPid = if ($owned) { [int]$script:OwnedServer.ProcessId } else { 0 }
    $foreign = @($owners | Where-Object { -not (Test-OwnedServerListener ([int]$_)) })
    if ($foreign.Count) {
        Log "portul $Port este ocupat de un proces neadministrat (PID $($foreign -join ', ')); il las neatins."
        return $false
    }

    $enginePids = @(Get-OurEnginePids)
    if (-not $script:EngineEnumerationSucceeded) {
        Log 'nu pot enumera procesele engine; pastrez serverul si proprietatea lui.'
        return $false
    }
    $engineStopFailed = $false
    foreach ($procId in $enginePids) {
        if (-not (Stop-PidIfOurs ([int]$procId))) { $engineStopFailed = $true }
    }
    $remainingEngines = @(Get-OurEnginePids)
    if (-not $script:EngineEnumerationSucceeded -or $engineStopFailed -or $remainingEngines.Count -gt 0) {
        Log 'nu pot confirma oprirea tuturor proceselor engine administrate; serverul ramane neatins.'
        return $false
    }
    if ($ownedPid -gt 0 -and -not (Stop-PidIfOurs $ownedPid)) {
        Log "nu pot revalida serverul administrat (PID $ownedPid); il las neatins."
        return $false
    }
    Start-Sleep -Seconds 2
    $remaining = Get-PortListenerSnapshot
    if (-not $remaining.Success -or $remaining.ProcessIds.Count) {
        Log "portul $Port ramane ocupat dupa oprirea proceselor administrate; nu ating listenerul ramas."
        return $false
    }
    return $true
}

function New-ServerOwnershipRecord($startedProcess, [string]$cfg) {
    try {
        $procId = [int]$startedProcess.Id
        $process = $startedProcess
        $null = $process.Handle
        $process.Refresh()
        $startedUtcTicks = [long]$process.StartTime.ToUniversalTime().Ticks
        $processExecutable = [System.IO.Path]::GetFullPath([string]$process.MainModule.FileName)
        $live = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $procId) -ErrorAction Stop
        $executable = [System.IO.Path]::GetFullPath([string]$live.ExecutablePath)
        $expectedExecutable = [System.IO.Path]::GetFullPath($Python)
        $configPath = [System.IO.Path]::GetFullPath($cfg)
        $commandLine = [string]$live.CommandLine
        $required = @($ServerPy, '--engine', 'panda', '--config', $configPath, '--port', [string]$Port)
        if ([int]$live.ParentProcessId -ne $PID -or
            -not [string]::Equals($executable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        if (-not [string]::Equals($processExecutable, $executable, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $null
        }
        foreach ($token in $required) {
            if ($commandLine.IndexOf([string]$token, [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { return $null }
        }
        return [pscustomobject]@{
            ProcessId = $procId
            ParentProcessId = [int]$live.ParentProcessId
            StartedUtcTicks = $startedUtcTicks
            ExecutablePath = $executable
            CommandLine = $commandLine
            ModelConfig = $configPath
            Port = $Port
            Process = $process
        }
    } catch {
        return $null
    }
}

function Stop-JustStartedServerSafely($startedProcess) {
    try {
        $null = $startedProcess.Handle
        $startedProcess.Refresh()
        if ($startedProcess.HasExited) { return $true }
        $executable = [System.IO.Path]::GetFullPath([string]$startedProcess.MainModule.FileName)
        $expectedExecutable = [System.IO.Path]::GetFullPath($Python)
        if (-not [string]::Equals($executable, $expectedExecutable, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
        $startedProcess.Kill()
        $null = $startedProcess.WaitForExit(5000)
        return [bool]$startedProcess.HasExited
    } catch {
        return $false
    }
}

function Start-Server([string]$cfg) {
    if (-not (Free-Port)) {
        Log "nu pornesc serverul: portul $Port nu a putut fi eliberat in siguranta."
        return $false
    }
    try { $cfgObj = Get-Content $cfg -Raw | ConvertFrom-Json; Rotate-Log $cfgObj.log } catch { }
    $a = @($ServerPy, '--engine', 'panda', '--config', ('"' + $cfg + '"'), '--port', "$Port")
    $started = Start-Process -FilePath $Python -ArgumentList $a -WorkingDirectory $Root -NoNewWindow -PassThru
    if (-not $started) {
        Log 'pornirea procesului Python administrat a esuat.'
        return $false
    }
    $script:OwnedServer = New-ServerOwnershipRecord $started $cfg
    if (-not $script:OwnedServer) {
        Log 'identitatea procesului pornit nu a putut fi validata; incerc oprirea doar prin handle-ul returnat la lansare.'
        if (-not (Stop-JustStartedServerSafely $started)) {
            Log 'procesul lansat nu a putut fi oprit in siguranta; nu voi opri procese dupa nume sau port.'
            $script:UnverifiedStartedProcess = $started
        }
        return $false
    }
    for ($i = 0; $i -lt 90; $i++) {
        Start-Sleep -Seconds 1
        $owned = Get-VerifiedOwnedServer
        $snapshot = Get-PortListenerSnapshot
        if (-not $snapshot.Success) {
            Log "nu pot inspecta listenerii de pe portul $Port in asteptarea serverului: $($snapshot.Error)"
            break
        }
        if ($owned -and $snapshot.ProcessIds.Count -eq 1 -and
            (Test-OwnedServerListener ([int]$snapshot.ProcessIds[0])) -and (Get-Health).Up) {
            $mod = 'RAPID (GPU la cerere)'
            if ($cfg -eq $GameCfg) { $mod = 'JOC (RAM/SSD, 0 experti in VRAM)' }
            Log "serverul este gata: $mod"
            return $true
        }
    }
    Log 'serverul nu a devenit gata; incerc oprirea doar prin identitatea procesului pornit.'
    if (-not (Stop-Server)) {
        $enginePids = @(Get-OurEnginePids)
        if (-not $script:EngineEnumerationSucceeded) {
            Log 'nu pot enumera procesele engine; pastrez serverul si inregistrarea lui pentru recuperare sigura.'
            return $false
        }
        $engineStopFailed = $false
        foreach ($procId in $enginePids) {
            if (-not (Stop-PidIfOurs ([int]$procId))) { $engineStopFailed = $true }
        }
        $remainingEngines = @(Get-OurEnginePids)
        if (-not $script:EngineEnumerationSucceeded -or $engineStopFailed -or $remainingEngines.Count -gt 0) {
            Log 'nu pot confirma oprirea tuturor proceselor engine; pastrez serverul si inregistrarea lui.'
            return $false
        }
        if (Stop-JustStartedServerSafely $started) {
            $script:OwnedServer = $null
            Log 'serverul pornit de acest guard a fost oprit prin handle-ul sau; listenerul neadministrat a ramas neatins.'
        } else {
            Log 'procesul lansat nu a putut fi oprit in siguranta; nu voi opri niciun listener neadministrat.'
        }
    }
    return $false
}

function Request-Switch([string]$target, [string]$why) {
    if (Test-Busy) {
        if (-not $script:pending) {
            Log "$why -> task in curs, aman comutarea (nu opresc nimic)."
            $script:pending = $target
            $script:pendingSince = Get-Date
        }
        return
    }
    Log "$why -> trec in modul $target"
    $cfg = if ($target -eq 'game') { $GameCfg } else { $FastCfg }
    if (Switch-To $target $cfg) { $script:mode = $target }
}

function Switch-To([string]$newMode, [string]$cfg) {
    $previous = $script:mode
    Log "trecere in modul $newMode"
    if (-not (Stop-Server)) {
        Log 'oprirea serverului nu a putut fi confirmata; pastrez modul curent.'
        return $false
    }
    if (Start-Server $cfg) {
        Log "trecere reusita."
        return $true
    }
    Log "pornire esuata; revin la modul $previous"
    $backCfg = if ($previous -eq 'game') { $GameCfg } else { $FastCfg }
    if (-not (Start-Server $backCfg)) { Log "revenirea a esuat; verifica logul serverului." }
    return $false
}

Log "=== adaptive guard start (doar VRAM, fara detectare de procese) ==="

# Decide initial mode from VRAM: a low reading means another app already owns the GPU.
$free = Get-FreeVramMib
if ($null -eq $free -or $free -lt $FastToGameMs) {
    if ($null -eq $free) {
        Log 'VRAM indisponibila la pornire -> mod joc precaut (RAM/SSD)'
    } else {
        Log "VRAM ocupata la pornire ($free MiB libere) -> mod joc (RAM/SSD)"
    }
    $mode = 'game'
    $ok = Start-Server $GameCfg
} else {
    Log "VRAM libera la pornire ($free MiB) -> mod rapid (GPU la cerere)"
    $mode = 'fast'
    $ok = Start-Server $FastCfg
}
if (-not $ok) {
    Log 'serverul nu a pornit; pastrez guard-ul activ pana confirm oprirea procesului lansat.'
    while ($script:OwnedServer -or $script:UnverifiedStartedProcess) {
        if ($script:OwnedServer) {
            try {
                $script:OwnedServer.Process.Refresh()
                if ($script:OwnedServer.Process.HasExited) { $script:OwnedServer = $null }
                elseif (Stop-Server) { break }
            } catch {}
        }
        if ($script:UnverifiedStartedProcess) {
            try {
                $script:UnverifiedStartedProcess.Refresh()
                if ($script:UnverifiedStartedProcess.HasExited -or
                    (Stop-JustStartedServerSafely $script:UnverifiedStartedProcess)) {
                    $script:UnverifiedStartedProcess = $null
                    break
                }
            } catch {}
        }
        if ($script:OwnedServer -or $script:UnverifiedStartedProcess) { Start-Sleep -Seconds 3 }
    }
    Log 'serverul esuat a fost confirmat oprit; ies din guard.'
    exit 1
}
Log "modelul NU e incarcat; se incarca la prima cerere si ramane in VRAM cat timp nu e presiune. Daca alta aplicatie cere memorie, eliberez VRAM in ~$PressurePolls s."

$script:mode = $mode
$pending = $null
$pendingSince = $null
$lowCount = 0
$highCount = 0
$down = 0

while ($true) {
    Start-Sleep -Seconds $PollSeconds

    $health = Get-Health
    if (-not $health.Up) {
        $down++
        if ($down -ge 3) {
            Log "serverul nu raspunde; repornesc in modul $($script:mode)"
            if (-not (Stop-Server)) {
                Log 'oprirea nu a putut fi confirmata; pastrez guard-ul activ si reiau verificarea.'
                Start-Sleep -Seconds 3
                continue
            }
            $cfg = if ($script:mode -eq 'game') { $GameCfg } else { $FastCfg }
            if (-not (Start-Server $cfg)) {
                Log 'repornirea esuata; guard-ul ramane activ si va reincerca recuperarea.'
                Start-Sleep -Seconds 3
            } else {
                $down = 0
            }
        }
        continue
    }
    $down = 0

    # Apply a postponed switch only when the current task has finished.
    if ($pending) {
        if (Test-Busy) {
            if ($pendingSince -and ((Get-Date) - $pendingSince).TotalSeconds -gt 600) {
                Log "taskul dureaza >10 min; comutarea ramane amanata."
                $pendingSince = Get-Date
            }
            continue
        }
        $target = $pending
        # Re-check VRAM: the situation may have changed while the task was running.
        $nowFree = Get-FreeVramMib
        if ($null -ne $nowFree) {
            $right = $target
            if ($nowFree -lt $FastToGameMs) { $right = 'game' }
            elseif ($nowFree -gt $GameToFastMs) { $right = 'fast' }
            if ($right -ne $target) {
                Log "VRAM schimbata intre timp ($nowFree MiB): corectez $target -> $right"
                $target = $right
            }
        }
        $pending = $null
        $pendingSince = $null
        Log "taskul s-a terminat; aplic comutarea in modul $target"
        $cfg = if ($target -eq 'game') { $GameCfg } else { $FastCfg }
        if (Switch-To $target $cfg) { $script:mode = $target }
    }

    $free = Get-FreeVramMib
    if ($null -eq $free) { continue }

    if ($script:mode -eq 'fast') {
        # Never interrupt a running or queued request.
        if (Test-Busy) { $lowCount = 0; continue }

        $engineBusy = Get-Process -Name 'panda-poly','panda-vision' -ErrorAction SilentlyContinue
        if ($health.Loaded -or $engineBusy) {
            if (-not $health.Loaded) { $lowCount = 0; continue }   # still loading
            # The fast config reserves headroom, so free VRAM is meaningful even
            # while loaded. A drop below the floor = another app took that memory.
            # Pressure overrides hot time: no minimum wait before releasing VRAM.
            if ($free -lt $PressureFreeMib) {
                $lowCount++
                if ($lowCount -ge $PressurePolls) {
                    Request-Switch 'game' "VRAM luata de alta aplicatie ($free MiB libere)"
                    $lowCount = 0
                }
            } else { $lowCount = 0 }
            continue
        }

        # Model not loaded: the original free-VRAM criterion applies.
        if ($free -lt $FastToGameMs) {
            $lowCount++
            if ($lowCount -ge $FastToGamePolls) {
                Request-Switch 'game' "VRAM ocupata de alta aplicatie ($free MiB libere)"
                $lowCount = 0
            }
        } else { $lowCount = 0 }
    }
    else {
        # Game mode uses only ~3 GB VRAM, so a high reading means the GPU is free.
        if ($free -gt $GameToFastMs) {
            $highCount++
            if ($highCount -ge $GameToFastPolls) {
                Request-Switch 'fast' "VRAM libera din nou ($free MiB)"
                $highCount = 0
            }
        } else { $highCount = 0 }
    }
}
