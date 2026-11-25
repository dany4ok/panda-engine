# Panda Engine - unified launcher for Inkling 2 Mini, MiniCPM-V and Gyro-S.
# PowerShell 5.1 compatible. ASCII messages only.
param(
    [switch]$DryRun,
    [switch]$ResetState,
    [switch]$AutoStart,
    [string]$GuiAction = '',
    [string]$ModelId = '',
    [int]$Context = -1,
    [string]$GameMode = '',
    [switch]$AuthorizeGyroStop
)

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Panda Engine' } catch {}

$script:Repo      = Split-Path -Parent $PSScriptRoot
$script:Catalog   = Join-Path $PSScriptRoot 'catalog.json'
$script:StatePath = Join-Path $env:LOCALAPPDATA 'panda-engine\state.json'
$script:cat       = Get-Content -LiteralPath $script:Catalog -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RoutePath = Join-Path $PSScriptRoot 'state\route.json'
$script:RouterPidPath = Join-Path $PSScriptRoot 'state\router.pid'
$script:BackendOwnersPath = Join-Path $PSScriptRoot 'state\backend-owners.json'
$script:RouterPy  = Join-Path $script:cat.roots.knownMini '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $script:RouterPy)) { $script:RouterPy = 'python.exe' }
$script:OpenCodeCfg = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
$script:OCBackupPath = Join-Path $PSScriptRoot 'state\opencode-backup.json'
$script:OCV1Home = Join-Path $PSScriptRoot 'state\opencode-v1'
$script:OCV1Data = Join-Path $PSScriptRoot 'state\opencode-v1-data'
$script:GyroStopAuthorizationRequired = $false
$script:GyroStartLeftRunning = $false
$script:GyroStartOwnershipSaved = $false
$script:GyroStartProcessId = 0
$script:StateResetPending = [bool]$ResetState

function Get-State {
    if ($script:StateResetPending) {
        $resetMutex = Enter-BackendLifecycleLock
        if (-not $resetMutex) { throw 'Cannot reset state while another lifecycle action is in progress.' }
        try {
            if (Test-Path -LiteralPath $script:StatePath) { Remove-Item -LiteralPath $script:StatePath -Force }
            $script:StateResetPending = $false
        } finally {
            Exit-BackendLifecycleLock $resetMutex
        }
    }
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $s = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Gyro is loaded on demand by Strata, not downloaded by this launcher.
            $s.downloaded = @($s.downloaded | Where-Object { $_ -ne 'gyro-s' })
            # States written before game mode existed have no gameMode key.
            if ($null -eq $s.PSObject.Properties['gameMode']) { Add-Member -InputObject $s -NotePropertyName gameMode -NotePropertyValue $false }
            if ($null -eq $s.PSObject.Properties['context']) { Add-Member -InputObject $s -NotePropertyName context -NotePropertyValue ([int]$script:cat.ninfer.context) }
            if ([int]$s.context -notin @(65536, 98304, 131072)) { $s.context = [int]$script:cat.ninfer.context }
            # Keep the (informational) roots in state in sync with the catalog.
            $s.roots = @{ inkling = $script:cat.roots.knownInkling; mini = $script:cat.roots.knownMini; gyro = $script:cat.roots.knownGyro }
            return $s
        } catch {}
    }
    return @{
        version      = 1
        firstRunDone = $false
        downloaded   = @()
        active       = ''
        gameMode     = $false
        context      = [int]$script:cat.ninfer.context
        roots        = @{ inkling = $script:cat.roots.knownInkling; mini = $script:cat.roots.knownMini; gyro = $script:cat.roots.knownGyro }
    }
}
function Save-State($s) {
    $dir = Split-Path -Parent $script:StatePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $temporary = Join-Path $dir ('.state-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = $temporary + '.bak'
    try {
        ($s | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $script:StatePath) {
            [System.IO.File]::Replace($temporary, $script:StatePath, $backup)
        } else {
            [System.IO.File]::Move($temporary, $script:StatePath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}
function Update-ConsoleState([hashtable]$Changes, [string[]]$AddDownloaded = @(), [switch]$ActiveOnlyIfEmpty) {
    $mutex = Enter-BackendLifecycleLock
    if (-not $mutex) { throw 'Another backend lifecycle action is in progress; state was not saved.' }
    try {
        $latest = Get-State
        foreach ($key in $Changes.Keys) {
            if ($key -eq 'active' -and $ActiveOnlyIfEmpty -and $latest.active) { continue }
            $latest.$key = $Changes[$key]
        }
        if ($AddDownloaded.Count) {
            $latest.downloaded = @(@($latest.downloaded) + @($AddDownloaded) | Select-Object -Unique)
        }
        Save-State $latest
        return $latest
    } finally {
        Exit-BackendLifecycleLock $mutex
    }
}
function Find-Model($id) { @($script:cat.models) | Where-Object { $_.id -eq $id } | Select-Object -First 1 }
function Find-Exe($dir, $name) {
    if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { return $null }
    return (Get-ChildItem -LiteralPath $dir -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
}
function Ensure-Links {
    foreach ($name in @('ninfer','models')) {
        $link = Join-Path $script:Repo $name
        $src  = Join-Path $script:cat.roots.knownInkling $name
        if (-not (Test-Path -LiteralPath $link) -and (Test-Path -LiteralPath $src)) {
            New-Item -ItemType Junction -Path $link -Target $src | Out-Null
            Write-Host ("  Linked existing " + $name + " folder from the current Inkling install.")
        }
    }
}
function Test-NinferEngine {
    if (Find-Exe $script:Repo $script:cat.ninfer.exe) { return $true }
    return [bool](Find-Exe $script:cat.roots.knownInkling $script:cat.ninfer.exe)
}
function Test-Model($m) {
    if (-not $m) { return $false }
    switch ($m.kind) {
        'inkling' {
            $art = Join-Path $script:Repo ('models\' + $m.artifact)
            $alt = Join-Path $script:cat.roots.knownInkling ('models\' + $m.artifact)
            return ((Test-NinferEngine) -and ((Test-Path -LiteralPath $art) -or (Test-Path -LiteralPath $alt)))
        }
        'mini' {
            $root = $script:cat.roots.knownMini
            if (-not (Test-Path -LiteralPath (Join-Path $root '.venv\Scripts\python.exe'))) { return $false }
            if (-not (Test-Path -LiteralPath (Join-Path $root $m.serverConfig))) { return $false }
            $base = Split-Path -Parent $script:cat.roots.knownMiniData
            foreach ($f in $m.files) { if (-not (Test-Path -LiteralPath (Join-Path $base $f.target))) { return $false } }
            return $true
        }
        'gyro' {
            $poly = $script:cat.roots.knownMini
            if (-not (Test-Path -LiteralPath (Join-Path $poly $m.serverConfig))) { return $false }
            $cfg = Get-Content -LiteralPath (Join-Path $poly $m.serverConfig) -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in @($cfg.exe, $cfg.vision.exe, $cfg.vision.mmproj, $cfg.tokenizer)) {
                if (-not (Test-Path -LiteralPath $p)) { return $false }
            }
            foreach ($a in $cfg.args) { if ($a -like 'C:*' -and -not (Test-Path -LiteralPath $a)) { return $false } }
            return $true
        }
    }
    return $false
}
function Get-GameGuardPath($key) { Join-Path $script:cat.roots.knownMini $script:cat.game.$key }
function Test-GameGuard {
    foreach ($key in @('guard','fastConfig','cpuConfig')) {
        if (-not (Test-Path -LiteralPath (Get-GameGuardPath $key))) { return $false }
    }
    return $true
}
function Stop-GameGuard([switch]$LockHeld) {
    return (Stop-BackendOwnersForPort ([int]$script:cat.ports.mini) 'GameGuard' -LockHeld:$LockHeld)
}
function Stop-MiniBackend {
    $mutex = Enter-BackendLifecycleLock
    if (-not $mutex) {
        Write-Host '  ERROR: Another Panda backend lifecycle action is in progress.'
        return $false
    }
    try {
        if ([int]$script:cat.ports.mini -in @(Get-OtherRouterBackendPorts)) {
            Write-Host ("  Preserving MiniCPM backend on port " + $script:cat.ports.mini + "; another Panda API routes to it.")
            return $false
        }
        if (-not (Stop-GameGuard -LockHeld)) { return $false }
        if (-not (Stop-BackendOwnersForPort ([int]$script:cat.ports.mini) -LockHeld)) { return $false }
        $route = Get-Route
        if (-not $DryRun -and $route -and [int]$route.port -eq [int]$script:cat.ports.mini) { Clear-Route }
        return $true
    } finally {
        Exit-BackendLifecycleLock $mutex
    }
}
function Toggle-GameMode($s) {
    $mutex = Enter-BackendLifecycleLock
    if (-not $mutex) { Write-Host '  ERROR: Another Panda backend lifecycle action is in progress.'; return }
    try {
    $latest = Get-State
    $s.active = $latest.active
    $s.gameMode = $latest.gameMode
    $m = Find-Model $s.active
    if (-not $m -or $m.kind -ne 'mini') {
        Write-Host '  Game mode applies to MiniCPM only. Select it first with its menu number.'
        return
    }
    if ($DryRun) { Write-Host '  [dry-run] would toggle MiniCPM game mode'; return }
    if (-not $s.gameMode -and -not (Test-GameGuard)) {
        Write-Host '  ERROR: game mode files are missing from the Poly-strata install:'
        foreach ($key in @('guard','fastConfig','cpuConfig')) { Write-Host ("    " + (Get-GameGuardPath $key)) }
        return
    }
    $turningOn = -not [bool]$s.gameMode
    $s.gameMode = $turningOn
    $latest.gameMode = $turningOn
    Save-State $latest
    Write-Host ("  MiniCPM game mode: " + $(if ($s.gameMode) {'ON (adaptive VRAM guard)'} else {'OFF (normal GPU load)'}))
    if ($s.gameMode) {
        Write-Host '  Takes effect on the next START; the running backend was not changed. The guard switches GPU <-> RAM/SSD when VRAM gets tight.'
    } else {
        Write-Host '  Standard 128K profile takes effect on the next MiniCPM START; the running backend was not changed.'
    }
    } finally {
        Exit-BackendLifecycleLock $mutex
    }
}
function Set-Route($m, [int]$port, $Owner) {
    $listener = $script:LastReadyBackend
    if (-not $Owner -or -not $listener -or [string]$Owner.ModelId -ne [string]$m.id -or
        [int]$Owner.Port -ne $port -or [int]$listener.Port -ne $port -or
        -not $Owner.CommandLine -or -not $listener.CommandLine) {
        throw 'A verified backend owner and listener are required to publish a route.'
    }
    $dir = Split-Path -Parent $script:RoutePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $obj = @{
        version = 2
        generation = [guid]::NewGuid().ToString('N')
        listen = [int]$script:cat.ports.api
        port = $port
        name = $m.label
        model = $m.id
        kind = [string]$m.kind
        expectedModelName = Get-ExpectedBackendModelName $m ([string]$Owner.Role)
        artifact = [string]$m.artifact
        backendRoot = [System.IO.Path]::GetFullPath([string]$script:cat.roots.knownMini)
        expectedServerScriptPath = [System.IO.Path]::GetFullPath((Join-Path $script:cat.roots.knownMini 'serve\server.py'))
        owner = @{
            processId = [int]$Owner.ProcessId
            startedUtcTicks = [long]$Owner.StartedUtcTicks
            executablePath = [string]$Owner.ExecutablePath
            commandLine = [string]$Owner.CommandLine
            modelId = [string]$Owner.ModelId
            port = [int]$Owner.Port
            role = [string]$Owner.Role
        }
        listener = @{
            processId = [int]$listener.ProcessId
            startedUtcTicks = [long]$listener.StartedUtcTicks
            executablePath = [string]$listener.ExecutablePath
            commandLine = [string]$listener.CommandLine
        }
        authorizedConfigPaths = @(
            if ([string]$Owner.Role -eq 'GameGuard' -and [string]$m.kind -eq 'mini') {
                foreach ($configName in @([string]$script:cat.game.fastConfig, [string]$script:cat.game.cpuConfig)) {
                    [System.IO.Path]::GetFullPath((Join-Path $script:cat.roots.knownMini $configName))
                }
            }
        )
    }
    $tmp = $script:RoutePath + '.tmp'
    ($obj | ConvertTo-Json -Compress -Depth 4) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp $script:RoutePath -Force
}
function Clear-Route {
    if (Test-Path -LiteralPath $script:RoutePath) { Remove-Item -LiteralPath $script:RoutePath -Force }
}
function Get-Route {
    if (-not (Test-Path -LiteralPath $script:RoutePath)) { return $null }
    try { return (Get-Content -LiteralPath $script:RoutePath -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}
function Test-PandaRouterProcess($Process) {
    if (-not $Process -or $Process.Name -notin @('python.exe','pythonw.exe') -or -not $Process.CommandLine) { return $false }
    try { $routerScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'core\router.py')) } catch { return $false }
    $pattern = '^\s*(?:"[^"]+"|\S+)\s+"?' + [regex]::Escape($routerScript) + '"?\s+' +
        [regex]::Escape([string]$script:cat.ports.api) + '\s*$'
    return [regex]::IsMatch([string]$Process.CommandLine, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
}
function Get-RouterProcess {
    # Match the exact Python script invocation and port, not an incidental command-line mention.
    foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort ([int]$script:cat.ports.api) -ErrorAction SilentlyContinue)) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.OwningProcess) -ErrorAction SilentlyContinue
        if (Test-PandaRouterProcess $proc) { return $proc }
    }
    return $null
}
function Test-Router { return [bool](Get-RouterProcess) }
function Start-Router([switch]$LockHeld) {
    $mutex = $null
    if (-not $LockHeld) {
        $mutex = Enter-BackendLifecycleLock
        if (-not $mutex) {
            Write-Host '  ERROR: Another backend lifecycle action is in progress.'
            return $false
        }
    }
    try {
    $existing = Get-RouterProcess
    if ($existing) {
        if (-not $DryRun -and -not (Upgrade-LegacyRouteIfOwned)) {
            if (-not (Clear-StaleRouteIfBackendOffline)) {
                Write-Host '  ERROR: Existing router route could not be safely adopted or confirmed offline; it remains unchanged.'
                return $false
            }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:RouterPidPath) | Out-Null
        $existing.ProcessId | Set-Content -LiteralPath $script:RouterPidPath -Encoding UTF8
        return $true
    }
    # Never terminate another workspace's router or an unrelated process to free this port.
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$script:cat.ports.api) -ErrorAction SilentlyContinue)
    foreach ($c in $listeners) {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.OwningProcess) -ErrorAction SilentlyContinue
        $ownerName = if ($p) { $p.Name } else { 'unknown process' }
        $ownerId = if ($p) { $p.ProcessId } else { $c.OwningProcess }
        Write-Host ("  ERROR: API port " + $script:cat.ports.api + " is occupied by " + $ownerName + " (PID " + $ownerId + "). It was left untouched.")
        return $false
    }
    Start-Sleep -Milliseconds 800
    if ($DryRun) { Write-Host '  [dry-run] would start the Panda API router'; return $true }
    if (-not (Upgrade-LegacyRouteIfOwned)) {
        if (-not (Clear-StaleRouteIfBackendOffline)) {
            Write-Host '  ERROR: Existing route could not be safely adopted or confirmed offline; it remains unchanged.'
            return $false
        }
    }
    $scriptFile = Join-Path $PSScriptRoot 'core\router.py'
    Start-Process -FilePath $script:RouterPy -WorkingDirectory $script:Repo -WindowStyle Hidden -ArgumentList @('"' + $scriptFile + '"', [string]$script:cat.ports.api) | Out-Null
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Milliseconds 500
        $r = Get-RouterProcess
        if ($r) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:RouterPidPath) | Out-Null
            $r.ProcessId | Set-Content -LiteralPath $script:RouterPidPath -Encoding UTF8
            Write-Host ('  Panda API ready on http://127.0.0.1:' + $script:cat.ports.api + '/v1')
            return $true
        }
    }
    Write-Host '  ERROR: Panda API did not start. See logs\panda-router.log'
    return $false
    } finally {
        if ($mutex) { Exit-BackendLifecycleLock $mutex }
    }
}
function Stop-Router {
    if ($DryRun) {
        Write-Host '  [dry-run] would stop the Panda API router and clear its route'
        return $true
    }
    $apiPort = [int]$script:cat.ports.api
    $r = Get-RouterProcess
    if ($r) {
        Write-Host ("  Stopping Panda API (PID " + $r.ProcessId + ")")
        try {
            $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$r.ProcessId) -ErrorAction Stop
            $process = Get-Process -Id ([int]$r.ProcessId) -ErrorAction Stop
            $null = $process.Handle
            $process.Refresh()
            if ($current -and [string]::Equals([string]$current.CommandLine, [string]$r.CommandLine, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$current.CreationDate, [string]$r.CreationDate, [System.StringComparison]::Ordinal) -and
                [string]::Equals([string]$current.ExecutablePath, [string]$r.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) -and
                (Test-PandaRouterProcess $current)) {
                $process.Kill()
                $process.WaitForExit(5000)
                $process.Refresh()
                if (-not $process.HasExited) {
                    Write-Host '  WARNING: Panda API did not exit; preserving its PID and route records.'
                    return $false
                }
            } else {
                Write-Host '  WARNING: Router process identity changed; leaving it untouched.'
                return $false
            }
        } catch {
            Write-Host '  WARNING: Router process could not be revalidated; leaving it untouched.'
            return $false
        }
    } else {
        $savedPid = 0
        if (Test-Path -LiteralPath $script:RouterPidPath) {
            try { [void][int]::TryParse((Get-Content -LiteralPath $script:RouterPidPath -Raw).Trim(), [ref]$savedPid) } catch {}
            if ($savedPid -gt 0) {
                $savedProcess = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $savedPid) -ErrorAction SilentlyContinue
                if ($savedProcess -and (Test-PandaRouterProcess $savedProcess)) {
                    Write-Host '  WARNING: Recorded router process is alive but cannot be confirmed as the API listener; preserving its records.'
                    return $false
                }
            }
        }
    }

    try {
        $remainingListeners = @(Get-NetTCPConnection -State Listen -LocalPort $apiPort -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound,*') {
            $remainingListeners = @()
        } else {
            Write-Host '  WARNING: Cannot verify that the Panda API port is clear; preserving its PID and route records.'
            return $false
        }
    }
    if ($remainingListeners.Count -gt 0) {
        Write-Host ("  WARNING: API port " + $apiPort + ' still has a listener; preserving route records and leaving it untouched.')
        return $false
    }
    Remove-Item -LiteralPath $script:RouterPidPath -Force -ErrorAction SilentlyContinue
    Clear-Route
    return $true
}
function Get-RemoteInfo($url) {
    $len = [int64]0
    $sha = ''
    $status = 0
    $lines = & curl.exe -sIL --max-time 60 $url 2>$null
    $curlExit = $LASTEXITCODE
    foreach ($line in $lines) {
        if ($line -match '^HTTP/\S+\s+(\d+)') { $status = [int]$Matches[1]; $len = [int64]0; $sha = '' }
        if ($line -match '^content-length:\s*(\d+)\s*$') { $len = [int64]$Matches[1] }
        if ($line -match '^etag:\s*"([0-9a-fA-F]{64})"') { $sha = $Matches[1].ToLower() }
    }
    if ($curlExit -ne 0 -or $status -ne 200) { $len = [int64]0; $sha = '' }
    return @{ Length = $len; Sha256 = $sha }
}
function Invoke-Download($url, $dest) {
    $dir = Split-Path -Parent $dest
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $name = Split-Path -Leaf $dest
    $info = @{ Length = 0; Sha256 = '' }
    if (-not $DryRun) { $info = Get-RemoteInfo $url }
    $need = $true
    if (Test-Path -LiteralPath $dest) {
        $got = (Get-Item -LiteralPath $dest).Length
        if ($info.Length -gt 0 -and $got -eq $info.Length) { $need = $false; Write-Host ("  " + $name + ": already complete") }
        elseif ($info.Length -eq 0) { $need = $false; Write-Host ("  " + $name + ": exists (remote size unavailable)") }
    }
    if ($need) {
        $part = $dest + '.part'
        Write-Host ("  DOWNLOAD " + $name + $(if ($info.Length -gt 0) { (" (" + [Math]::Round($info.Length/1MB,1) + " MB)") } else { '' }))
        if ($DryRun) { Write-Host '  [dry-run] skipped'; return $true }
        if ($GuiAction -eq 'Install') {
            $encodedPath = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($part))
            Write-Host ("PANDA_DOWNLOAD " + $encodedPath + " " + [int64]$info.Length)
        }
        $ok = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -eq 2 -and (Test-Path -LiteralPath $part)) { Remove-Item -LiteralPath $part -Force }
            & curl.exe -L --fail --retry 3 -C - -o $part $url
            if ($LASTEXITCODE -eq 0) { $ok = $true; break }
            Write-Host ("  WARNING: download attempt " + $attempt + " failed (curl exit " + $LASTEXITCODE + "); check network access and available disk space.")
        }
        if ($GuiAction -eq 'Install') { Write-Host 'PANDA_DOWNLOAD_END' }
        if (-not $ok) { throw ("Download failed: " + $url) }
        $got = (Get-Item -LiteralPath $part).Length
        if ($info.Length -gt 0 -and $got -ne $info.Length) {
            Remove-Item -LiteralPath $part -Force
            throw ("Size mismatch for " + $name + ": " + $got + " vs " + $info.Length)
        }
        if ($info.Sha256 -and $got -le 2199023255552) {
            $hash = (Get-FileHash -LiteralPath $part -Algorithm SHA256).Hash.ToLower()
            if ($hash -ne $info.Sha256) {
                Remove-Item -LiteralPath $part -Force
                throw ("SHA256 mismatch for " + $name)
            }
            Write-Host ("  SHA256 verified for " + $name)
        }
        Move-Item -LiteralPath $part $dest -Force
    }
    return $true
}
function Ensure-NinferEngine {
    if (Test-NinferEngine) { Write-Host '  NInfer engine: already installed'; return $true }
    Write-Host '  NInfer engine: resolving latest GitHub release...'
    if ($DryRun) { Write-Host '  [dry-run] would download and extract the NInfer engine'; return $true }
    $rel = Invoke-RestMethod -Uri $script:cat.ninfer.releasesApi -TimeoutSec 60
    $assets = @($rel.assets | Where-Object { $_.name -like $script:cat.ninfer.assetMatch })
    if ($assets.Count -eq 0) { Write-Host '  ERROR: no matching NInfer release asset'; return $false }
    $base = $assets[0].name -replace '\.001$',''
    $parts = @($rel.assets | Where-Object { $_.name -like ($base + '.*') } | Sort-Object Name)
    $tmp = Join-Path $env:TEMP 'panda-engine-download'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $localParts = @()
    foreach ($p in $parts) {
        $out = Join-Path $tmp $p.name
        try { Invoke-Download $p.browser_download_url $out | Out-Null }
        catch { Write-Host ("  ERROR: " + $_.Exception.Message); return $false }
        $localParts += $out
    }
    $archive = Join-Path $tmp ($base + '.7z')
    if ($localParts.Count -eq 1) { Copy-Item $localParts[0] $archive -Force }
    else {
        $list = ($localParts | ForEach-Object { '"' + $_ + '"' }) -join ' + '
        & cmd.exe /c ('copy /b ' + $list + ' "' + $archive + '"') | Out-Null
    }
    $seven = @('C:\Program Files\7-Zip\7z.exe','C:\Program Files (x86)\7-Zip\7z.exe') | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    $dest = Join-Path $script:Repo 'ninfer'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if ($seven) { & $seven x $archive ('-o' + $dest) -y | Out-Null }
    else { Write-Host ('  ERROR: 7-Zip not found. Extract ' + $archive + ' into ' + $dest + ' manually.'); return $false }
    return (Test-NinferEngine)
}
function Ensure-Model($m) {
    Write-Host ("[" + $m.id + "] " + $m.label)
    if (Test-Model $m) { Write-Host '  already installed'; return $true }
    if ($DryRun) { Write-Host '  [dry-run] would install this model'; return $true }
    switch ($m.kind) {
        'inkling' {
            if (-not (Ensure-NinferEngine)) { return $false }
            $dest = Join-Path $script:Repo ('models\' + $m.artifact)
            try { return (Invoke-Download $m.url $dest) } catch { Write-Host ("  ERROR: " + $_.Exception.Message); return $false }
        }
        'mini' {
            $base = Split-Path -Parent $script:cat.roots.knownMiniData
            foreach ($f in $m.files) {
                try { Invoke-Download $f.url (Join-Path $base $f.target) | Out-Null }
                catch { Write-Host ("  ERROR: " + $_.Exception.Message); return $false }
            }
            if (-not (Test-Model $m)) {
                Write-Host '  ERROR: MiniCPM runtime is incomplete. Need the Poly-strata install with .venv\Scripts\python.exe, serve\server.py, strata-minicpmv-q4_k_m.json, and the expert profile + tokenizer in PolyStrata-data.'
                Write-Host '  See panda/README.md. The model is NOT marked installed.'
                return $false
            }
            return $true
        }
        'gyro' {
            if (Test-Model $m) {
                Write-Host '  Gyro-S model, pack and engine are bundled in Panda. Nothing to download.'
                return $true
            }
            Write-Host '  ERROR: Gyro-S files are missing from models\gyro-s*, models\gyro-s-pack, models\gyro-s-mtp or runtime\gyro-engine.'
            return $false
        }
    }
    return $false
}
function Get-OtherRouterBackendPorts {
    $protected = @()
    $allBackendPorts = @([int]$script:cat.ports.infer, [int]$script:cat.ports.mini, [int]$script:cat.ports.gyro)
    $ownRouterScript = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot 'core\router.py'))
    try { $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop) } catch {
        Write-Host '  WARNING: Cannot inspect running processes; protecting every backend port.'
        return $allBackendPorts
    }
    $routers = @($allProcesses | Where-Object {
        $_.Name -match 'python' -and $_.CommandLine -and $_.CommandLine -match '(?i)router\.py'
    })
    foreach ($router in $routers) {
        $match = [regex]::Match([string]$router.CommandLine, '(?i)"([^"]*router\.py)"|([^\s"]*router\.py)')
        $routerPath = if ($match.Groups[1].Success) { $match.Groups[1].Value } elseif ($match.Groups[2].Success) { $match.Groups[2].Value } else { '' }
        if (-not $routerPath -or -not [System.IO.Path]::IsPathRooted($routerPath)) {
            $protected += $allBackendPorts
            continue
        }
        try { $routerPath = [System.IO.Path]::GetFullPath($routerPath) } catch {
            $protected += $allBackendPorts
            continue
        }
        if ($routerPath.Equals($ownRouterScript, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        try {
            $routerListeners = @(Get-NetTCPConnection -State Listen -OwningProcess ([int]$router.ProcessId) -ErrorAction Stop)
        } catch {
            if ($_.FullyQualifiedErrorId -notlike 'CmdletizationQuery_NotFound,*') {
                $protected += $allBackendPorts
            }
            continue
        }
        if ($routerListeners.Count -eq 0) { continue }
        $foreignRepo = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $routerPath))
        $foreignRoutePath = Join-Path $foreignRepo 'panda\state\route.json'
        if (-not (Test-Path -LiteralPath $foreignRoutePath)) {
            $protected += $allBackendPorts
            continue
        }
        try {
            $foreignRoute = Get-Content -LiteralPath $foreignRoutePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $foreignPort = [int]$foreignRoute.port
            if ($foreignPort -in $allBackendPorts) { $protected += $foreignPort }
        } catch {
            $protected += $allBackendPorts
        }
    }
    return @($protected | Select-Object -Unique)
}

function Get-ModelBackendPort($Model) {
    if (-not $Model) { return 0 }
    switch ([string]$Model.kind) {
        'inkling' { return [int]$script:cat.ports.infer }
        'mini'    { return [int]$script:cat.ports.mini }
        'gyro'    { return [int]$script:cat.ports.gyro }
        default   { return 0 }
    }
}

function Get-BackendListenerSnapshot([int]$Port) {
    try {
        $connections = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
    } catch {
        if ($_.FullyQualifiedErrorId -like 'CmdletizationQuery_NotFound,*') {
            $connections = @()
        } else {
            return [pscustomobject]@{ Success = $false; Processes = @(); Error = $_.Exception.Message }
        }
    }
    $processes = @()
    foreach ($ownerPid in @($connections | Select-Object -ExpandProperty OwningProcess -Unique)) {
        try {
            $process = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$ownerPid) -ErrorAction Stop
        } catch {
            return [pscustomobject]@{ Success = $false; Processes = @(); Error = $_.Exception.Message }
        }
        if (-not $process) {
            return [pscustomobject]@{ Success = $false; Processes = @(); Error = ("Listener PID " + $ownerPid + " has no process record.") }
        }
        $processes += $process
    }
    return [pscustomobject]@{ Success = $true; Processes = @($processes); Error = '' }
}

function Test-PathUnderDirectory([string]$Path, [string]$Directory) {
    if (-not $Path -or -not $Directory) { return $false }
    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullDirectory = [System.IO.Path]::GetFullPath($Directory)
        if (-not $fullDirectory.EndsWith('\')) { $fullDirectory += '\' }
        return $fullPath.StartsWith($fullDirectory, [System.StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Test-CommandLineArgumentValue([string]$CommandLine, [string]$Name, [string]$Value) {
    if (-not $CommandLine -or -not $Name -or $null -eq $Value) { return $false }
    $escapedValue = [regex]::Escape([string]$Value)
    $pattern = '(?i)(?:^|\s)' + [regex]::Escape($Name) + '\s+(?:"' + $escapedValue + '"|' + $escapedValue + ')(?:\s|$)'
    return [regex]::IsMatch($CommandLine, $pattern)
}

function Test-BackendProcessSignature($Process, $Model, [int]$Port, [string]$Role = 'Server') {
    if (-not $Process -or -not $Model -or -not $Process.ExecutablePath -or -not $Process.CommandLine) { return $false }
    $commandLine = [string]$Process.CommandLine
    if ($Model.kind -eq 'inkling') {
        if ([System.IO.Path]::GetFileName([string]$Process.ExecutablePath) -ine [string]$script:cat.ninfer.exe) { return $false }
        $approved = (Test-PathUnderDirectory ([string]$Process.ExecutablePath) (Join-Path $script:Repo 'ninfer')) -or
            (Test-PathUnderDirectory ([string]$Process.ExecutablePath) (Join-Path $script:cat.roots.knownInkling 'ninfer'))
        return ($approved -and $commandLine.IndexOf([string]$Model.artifact, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            (Test-CommandLineArgumentValue $commandLine '--port' ([string]$Port)))
    }
    if ($Model.kind -in @('mini','gyro')) {
        try {
            $pythonPath = [System.IO.Path]::GetFullPath((Join-Path $script:cat.roots.knownMini '.venv\Scripts\python.exe'))
            $actualPath = [System.IO.Path]::GetFullPath([string]$Process.ExecutablePath)
        } catch {
            return $false
        }
        $approvedPython = [string]::Equals($actualPath, $pythonPath, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $approvedPython) {
            $venvConfig = Join-Path $script:cat.roots.knownMini '.venv\pyvenv.cfg'
            try {
                foreach ($line in @(Get-Content -LiteralPath $venvConfig -ErrorAction Stop)) {
                    if ($line -match '^\s*executable\s*=\s*(.+?)\s*$') {
                        $basePython = [System.IO.Path]::GetFullPath($Matches[1])
                        $approvedPython = [string]::Equals($actualPath, $basePython, [System.StringComparison]::OrdinalIgnoreCase)
                        break
                    }
                }
            } catch { return $false }
        }
        $hasServerScript = ($commandLine.IndexOf('serve\server.py', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) -or
            ($commandLine.IndexOf('serve/server.py', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
        $configs = if ($Role -eq 'GameGuard' -and $Model.kind -eq 'mini') {
            @(
                (Join-Path $script:cat.roots.knownMini ([string]$script:cat.game.fastConfig)),
                (Join-Path $script:cat.roots.knownMini ([string]$script:cat.game.cpuConfig))
            )
        } else {
            @([string]$Model.serverConfig)
        }
        $configMatches = $false
        foreach ($config in $configs) {
            if (Test-CommandLineArgumentValue $commandLine '--config' $config) { $configMatches = $true; break }
        }
        return ($approvedPython -and $hasServerScript -and
            (Test-CommandLineArgumentValue $commandLine '--engine' 'strata') -and $configMatches -and
            (Test-CommandLineArgumentValue $commandLine '--port' ([string]$Port)))
    }
    return $false
}

function Test-BackendManagerSignature($Process, $Owner, $Model) {
    if (-not $Process -or -not $Owner -or -not $Model -or -not $Process.ExecutablePath -or -not $Process.CommandLine) { return $false }
    if ([System.IO.Path]::GetFileName([string]$Process.ExecutablePath) -notin @('powershell.exe','pwsh.exe')) { return $false }
    $expectedScript = switch ([string]$Owner.Role) {
        'InklingLauncher' { Join-Path $PSScriptRoot 'legacy\start.ps1' }
        'GameGuard'       { Get-GameGuardPath 'guard' }
        default           { return $false }
    }
    try { $expectedScript = [System.IO.Path]::GetFullPath($expectedScript) } catch { return $false }
    if ([string]$Model.kind -eq 'inkling') {
        return ([string]$Owner.Role -eq 'InklingLauncher' -and
            ([string]$Process.CommandLine).IndexOf($expectedScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
    }
    if ([string]$Model.kind -eq 'mini' -and [string]$Owner.Role -eq 'GameGuard') {
        return (([string]$Process.CommandLine).IndexOf($expectedScript, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -and
            (Test-CommandLineArgumentValue ([string]$Process.CommandLine) '-Port' ([string]$Owner.Port)))
    }
    return $false
}

function Get-BackendOwners {
    if (-not (Test-Path -LiteralPath $script:BackendOwnersPath)) {
        return [pscustomobject]@{ Success = $true; Owners = @(); Error = '' }
    }
    try {
        $data = Get-Content -LiteralPath $script:BackendOwnersPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $data.PSObject.Properties['processes']) {
            return [pscustomobject]@{ Success = $false; Owners = @(); Error = 'Ownership file has no processes list.' }
        }
        return [pscustomobject]@{ Success = $true; Owners = @($data.processes); Error = '' }
    } catch {
        return [pscustomobject]@{ Success = $false; Owners = @(); Error = $_.Exception.Message }
    }
}

function Get-GyroBackendOwners($Owners) {
    $gyro = Find-Model 'gyro-s'
    if (-not $gyro) { return @() }
    $gyroPort = Get-ModelBackendPort $gyro
    $gyroOwners = @()
    foreach ($owner in @($Owners)) {
        if ([int]$owner.Port -ne $gyroPort -or [string]$owner.ModelId -ne [string]$gyro.id) { continue }
        $gyroOwners += $owner
    }
    return $gyroOwners
}

function Save-BackendOwners($Owners) {
    try {
        $directory = Split-Path -Parent $script:BackendOwnersPath
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
        $temporary = $script:BackendOwnersPath + '.tmp'
        ([pscustomobject]@{ version = 1; processes = @($Owners) } | ConvertTo-Json -Depth 8) |
            Set-Content -LiteralPath $temporary -Encoding UTF8
        Move-Item -LiteralPath $temporary -Destination $script:BackendOwnersPath -Force
        return $true
    } catch {
        Write-Host ("  ERROR: Could not save backend ownership records: " + $_.Exception.Message)
        return $false
    }
}

function New-BackendOwnerRecord([int]$ProcessId, $Model, [int]$Port, [string]$Role) {
    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        $process.Refresh()
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $ProcessId) -ErrorAction Stop
        if (-not $cim -or -not $cim.ExecutablePath -or -not $cim.CommandLine) { return $null }
        return [pscustomobject]@{
            ProcessId = [int]$ProcessId
            StartedUtcTicks = [long]$process.StartTime.ToUniversalTime().Ticks
            ExecutablePath = [string]$cim.ExecutablePath
            CommandLine = [string]$cim.CommandLine
            ModelId = [string]$Model.id
            Port = [int]$Port
            Role = [string]$Role
        }
    } catch {
        return $null
    }
}

function Get-BackendOwnerValidationState($Owner) {
    if (-not $Owner -or -not $Owner.ProcessId -or -not $Owner.StartedUtcTicks -or -not $Owner.ExecutablePath -or -not $Owner.CommandLine) {
        return [pscustomobject]@{ State = 'invalid'; Process = $null; Error = 'Ownership record is incomplete.' }
    }
    try {
        $cim = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$Owner.ProcessId) -ErrorAction Stop
    } catch {
        return [pscustomobject]@{ State = 'uninspectable'; Process = $null; Error = $_.Exception.Message }
    }
    if (-not $cim) {
        return [pscustomobject]@{ State = 'gone'; Process = $null; Error = '' }
    }
    try {
        $process = Get-Process -Id ([int]$Owner.ProcessId) -ErrorAction Stop
        $null = $process.Handle
        $process.Refresh()
        if (-not [string]::Equals([string]$cim.ExecutablePath, [string]$Owner.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) -or
            -not [string]::Equals([string]$cim.CommandLine, [string]$Owner.CommandLine, [System.StringComparison]::OrdinalIgnoreCase) -or
            [long]$process.StartTime.ToUniversalTime().Ticks -ne [long]$Owner.StartedUtcTicks) {
            return [pscustomobject]@{ State = 'mismatch'; Process = $null; Error = 'Process identity differs from its ownership record.' }
        }
        $model = Find-Model ([string]$Owner.ModelId)
        $port = [int]$Owner.Port
        if (-not $model -or $port -ne (Get-ModelBackendPort $model)) {
            return [pscustomobject]@{ State = 'mismatch'; Process = $null; Error = 'Model or backend port differs from the catalog.' }
        }
        if ([string]$Owner.Role -eq 'Server') {
            if (-not (Test-BackendProcessSignature $cim $model $port 'Server')) {
                return [pscustomobject]@{ State = 'mismatch'; Process = $null; Error = 'Backend command line does not match the model.' }
            }
        } elseif (-not (Test-BackendManagerSignature $cim $Owner $model)) {
            return [pscustomobject]@{ State = 'mismatch'; Process = $null; Error = 'Manager command line does not match the model.' }
        }
        return [pscustomobject]@{ State = 'valid'; Process = $cim; Error = '' }
    } catch {
        return [pscustomobject]@{ State = 'uninspectable'; Process = $null; Error = $_.Exception.Message }
    }
}

function Get-ValidatedBackendOwnerProcess($Owner) {
    $state = Get-BackendOwnerValidationState $Owner
    if ($state.State -eq 'valid') { return $state.Process }
    return $null
}

function Get-BackendProcessTree([int]$RootProcessId) {
    try {
        $all = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        return [pscustomobject]@{ Success = $false; Processes = @(); Error = $_.Exception.Message }
    }
    $descendants = @()
    $seen = @{}
    $seen[[string]$RootProcessId] = $true
    $frontier = @([int]$RootProcessId)
    for ($depth = 1; $depth -le 64 -and $frontier.Count -gt 0; $depth++) {
        $children = @($all | Where-Object {
            ($frontier -contains [int]$_.ParentProcessId) -and (-not $seen.ContainsKey([string]$_.ProcessId))
        })
        if ($children.Count -eq 0) { break }
        foreach ($child in $children) {
            $parent = $all | Where-Object { [int]$_.ProcessId -eq [int]$child.ParentProcessId } | Select-Object -First 1
            if (-not $parent -or -not $parent.CreationDate -or -not $child.CreationDate -or $child.CreationDate -lt $parent.CreationDate) {
                return [pscustomobject]@{ Success = $false; Processes = @(); Error = 'Unverifiable process ancestry.' }
            }
            $startTicks = [long]0
            try {
                $childProcess = Get-Process -Id ([int]$child.ProcessId) -ErrorAction Stop
                $childProcess.Refresh()
                $startTicks = [long]$childProcess.StartTime.ToUniversalTime().Ticks
            } catch {}
            $descendants += [pscustomobject]@{ Depth = $depth; Process = $child; StartedUtcTicks = $startTicks }
            $seen[[string]$child.ProcessId] = $true
        }
        $frontier = @($children | ForEach-Object { [int]$_.ProcessId })
    }
    return [pscustomobject]@{ Success = $true; Processes = @($descendants); Error = '' }
}

function Test-ProcessDescendsFrom([int]$ProcessId, [int]$RootProcessId) {
    if ($ProcessId -eq $RootProcessId) { return $true }
    $tree = Get-BackendProcessTree $RootProcessId
    if (-not $tree.Success) { return $false }
    return [bool](@($tree.Processes | Where-Object { [int]$_.Process.ProcessId -eq $ProcessId }).Count -gt 0)
}

function Get-BackendOwnerForListener($Process, $Model, [int]$Port, $Owners) {
    foreach ($owner in @($Owners)) {
        if ([int]$owner.Port -ne $Port -or [string]$owner.ModelId -ne [string]$Model.id) { continue }
        if (-not (Get-ValidatedBackendOwnerProcess $owner)) { continue }
        if (-not (Test-BackendProcessSignature $Process $Model $Port ([string]$owner.Role))) { continue }
        if (Test-ProcessDescendsFrom ([int]$Process.ProcessId) ([int]$owner.ProcessId)) { return $owner }
    }
    return $null
}

function Get-ManagedBackendOwnerForListener($Process, $Owners) {
    foreach ($owner in @($Owners)) {
        $model = Find-Model ([string]$owner.ModelId)
        if (-not $model -or [int]$owner.Port -le 0) { continue }
        $match = Get-BackendOwnerForListener $Process $model ([int]$owner.Port) @($owner)
        if ($match) { return $match }
    }
    return $null
}

function Get-ExpectedBackendModelName($Model, [string]$Role) {
    if (-not $Model -or $Model.kind -notin @('mini','gyro')) { return '' }
    $configs = if ($Role -eq 'GameGuard' -and $Model.kind -eq 'mini') {
        @([string]$script:cat.game.fastConfig, [string]$script:cat.game.cpuConfig)
    } else {
        @([string]$Model.serverConfig)
    }
    $providerModel = ([string]$Model.provider -split '/')[-1]
    foreach ($config in $configs) {
        $path = if ([System.IO.Path]::IsPathRooted($config)) { $config } else { Join-Path $script:cat.roots.knownMini $config }
        try {
            $identity = [string](Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).model_name
        } catch { continue }
        if (-not $identity) { continue }
        if ($Model.kind -eq 'mini' -and -not [string]::Equals($identity, $providerModel, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        if ($Model.kind -eq 'gyro' -and -not $identity.EndsWith($providerModel, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        return $identity
    }
    return ''
}

function Stop-TrackedBackendOwner($Owner) {
    $ownerState = Get-BackendOwnerValidationState $Owner
    if ($ownerState.State -eq 'gone') { return 'stale' }
    if ($ownerState.State -ne 'valid') {
        Write-Host ("  WARNING: Cannot confirm managed PID " + $Owner.ProcessId + ': ' + $ownerState.Error)
        return 'failed'
    }
    $tree = Get-BackendProcessTree ([int]$Owner.ProcessId)
    if (-not $tree.Success) {
        Write-Host ("  WARNING: Cannot enumerate descendants of managed PID " + $Owner.ProcessId + "; leaving it untouched.")
        return 'failed'
    }
    $children = @($tree.Processes | Sort-Object @{ Expression = { if ($_.Process.Name -match '^(?i)(powershell|pwsh)\.exe$') { 0 } else { 1 } } }, @{ Expression = 'Depth'; Descending = $true })
    foreach ($entry in $children) {
        $snapshot = $entry.Process
        $ownerState = Get-BackendOwnerValidationState $Owner
        if ($ownerState.State -ne 'valid') {
            Write-Host ("  WARNING: Managed PID " + $Owner.ProcessId + ' changed during cleanup; stopping the process tree here.')
            return 'failed'
        }
        try {
            if (-not [long]$entry.StartedUtcTicks) {
                Write-Host ("  WARNING: Descendant PID " + $snapshot.ProcessId + ' has no verifiable start time; stopping cleanup.')
                return 'failed'
            }
            $currentProcess = Get-Process -Id ([int]$snapshot.ProcessId) -ErrorAction Stop
            $null = $currentProcess.Handle
            $currentProcess.Refresh()
            $current = Get-CimInstance Win32_Process -Filter ("ProcessId=" + [int]$snapshot.ProcessId) -ErrorAction Stop
            if ($current -and $snapshot.ExecutablePath -and $snapshot.CommandLine -and
                [long]$currentProcess.StartTime.ToUniversalTime().Ticks -eq [long]$entry.StartedUtcTicks -and
                [string]$current.CreationDate -eq [string]$snapshot.CreationDate -and
                [string]::Equals([string]$current.ExecutablePath, [string]$snapshot.ExecutablePath, [System.StringComparison]::OrdinalIgnoreCase) -and
                [string]::Equals([string]$current.CommandLine, [string]$snapshot.CommandLine, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($DryRun) {
                    Write-Host ("  [dry-run] would stop owned descendant PID " + $snapshot.ProcessId)
                } else {
                    $currentProcess.Kill()
                    $null = $currentProcess.WaitForExit(5000)
                    $currentProcess.Refresh()
                    if (-not $currentProcess.HasExited) {
                        Write-Host ("  WARNING: Managed descendant PID " + $snapshot.ProcessId + ' did not exit.')
                        return 'failed'
                    }
                }
            } elseif ($current) {
                # A different process now owns this PID; never act on the replacement.
                continue
            }
        } catch {
            if (-not (Get-Process -Id ([int]$snapshot.ProcessId) -ErrorAction SilentlyContinue)) {
                continue
            }
            Write-Host ("  WARNING: Could not confirm descendant PID " + $snapshot.ProcessId + ' stopped.')
            return 'failed'
        }
    }
    if ($DryRun) { return 'dryrun' }
    $rootState = Get-BackendOwnerValidationState $Owner
    if ($rootState.State -eq 'gone') { return 'stopped' }
    if ($rootState.State -ne 'valid') {
        Write-Host ("  WARNING: Cannot revalidate managed root PID " + $Owner.ProcessId + '; preserving its ownership record.')
        return 'failed'
    }
    $root = $rootState.Process
    if ($root) {
        try {
            $rootProcess = Get-Process -Id ([int]$Owner.ProcessId) -ErrorAction Stop
            $null = $rootProcess.Handle
            $rootProcess.Refresh()
            if ([long]$rootProcess.StartTime.ToUniversalTime().Ticks -eq [long]$Owner.StartedUtcTicks) {
                $rootProcess.Kill()
                $null = $rootProcess.WaitForExit(5000)
                $rootProcess.Refresh()
                if (-not $rootProcess.HasExited) {
                    Write-Host ("  WARNING: Managed root PID " + $Owner.ProcessId + ' did not exit.')
                    return 'failed'
                }
            }
        } catch {
            $rootState = Get-BackendOwnerValidationState $Owner
            if ($rootState.State -ne 'gone') { return 'failed' }
        }
    }
    for ($i = 0; $i -lt 20; $i++) {
        $rootState = Get-BackendOwnerValidationState $Owner
        if ($rootState.State -eq 'gone') { return 'stopped' }
        if ($rootState.State -ne 'valid') {
            Write-Host ("  WARNING: Cannot confirm exit state for managed PID " + $Owner.ProcessId + '; preserving its ownership record.')
            return 'failed'
        }
        Start-Sleep -Milliseconds 200
    }
    Write-Host ("  WARNING: Managed process tree rooted at PID " + $Owner.ProcessId + " did not exit.")
    return 'failed'
}

function Enter-BackendLifecycleLock {
    try {
        $mutex = [System.Threading.Mutex]::new($false, 'Local\PandaEngineBackendLifecycle')
        try {
            $acquired = $mutex.WaitOne(5000)
        } catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }
        if (-not $acquired) { $mutex.Dispose(); return $null }
        return $mutex
    } catch {
        return $null
    }
}

function Exit-BackendLifecycleLock($Mutex) {
    if (-not $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch {}
    $Mutex.Dispose()
}

function Wait-ManagedBackendReady($Model, [int]$Port, $Owner, [int]$TimeoutSeconds = 90) {
    $script:LastReadyBackend = $null
    $expectedModelName = Get-ExpectedBackendModelName $Model ([string]$Owner.Role)
    if ($Model.kind -in @('mini','gyro') -and -not $expectedModelName) {
        Write-Host ("  ERROR: The configured model identity does not match " + $Model.label + '.')
        return $false
    }
    for ($i = 0; $i -lt $TimeoutSeconds; $i++) {
        if (-not (Get-ValidatedBackendOwnerProcess $Owner)) {
            Write-Host '  ERROR: The launched manager process exited before the backend became ready.'
            return $false
        }
        $snapshot = Get-BackendListenerSnapshot $Port
        if (-not $snapshot.Success) {
            Write-Host ("  ERROR: Cannot safely inspect backend port " + $Port + ': ' + $snapshot.Error)
            return $false
        }
        if ($snapshot.Processes.Count -gt 1) {
            Write-Host ("  ERROR: Multiple processes are listening on backend port " + $Port + '.')
            return $false
        }
        if ($snapshot.Processes.Count -eq 1) {
            $listener = $snapshot.Processes[0]
            if (-not (Test-BackendProcessSignature $listener $Model $Port ([string]$Owner.Role)) -or
                -not (Test-ProcessDescendsFrom ([int]$listener.ProcessId) ([int]$Owner.ProcessId))) {
                Write-Host ("  ERROR: Port " + $Port + ' is occupied by a process not owned for model ' + $Model.id + '; it was left untouched.')
                return $false
            }
            $healthy = $false
            try {
                $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + $Port + '/health') -TimeoutSec 2
                $healthy = ($health -eq 'ok') -or ([string]$health.status -eq 'ok')
                if ($Model.kind -in @('mini','gyro')) {
                    $healthy = ($healthy -and [string]::Equals([string]$health.model, $expectedModelName, [System.StringComparison]::OrdinalIgnoreCase))
                }
            } catch {}
            if ($healthy) {
                $after = Get-BackendListenerSnapshot $Port
                if ($after.Success -and $after.Processes.Count -eq 1 -and
                    [int]$after.Processes[0].ProcessId -eq [int]$listener.ProcessId -and
                    (Test-BackendProcessSignature $after.Processes[0] $Model $Port ([string]$Owner.Role)) -and
                    (Test-ProcessDescendsFrom ([int]$after.Processes[0].ProcessId) ([int]$Owner.ProcessId))) {
                    try {
                        $listenerProcess = Get-Process -Id ([int]$after.Processes[0].ProcessId) -ErrorAction Stop
                        $listenerProcess.Refresh()
                        if (-not $after.Processes[0].ExecutablePath) { throw 'Listener executable path is unavailable.' }
                        $listenerTicks = [long]$listenerProcess.StartTime.ToUniversalTime().Ticks
                        if (-not $listenerTicks) { throw 'Listener start time is unavailable.' }
                        $script:LastReadyBackend = [pscustomobject]@{
                            ProcessId = [int]$after.Processes[0].ProcessId
                            StartedUtcTicks = $listenerTicks
                            ExecutablePath = [string]$after.Processes[0].ExecutablePath
                            CommandLine = [string]$after.Processes[0].CommandLine
                            Port = [int]$Port
                        }
                        return $true
                    } catch {
                        Write-Host ("  ERROR: Cannot record verified backend listener identity: " + $_.Exception.Message)
                        return $false
                    }
                }
                Write-Host '  ERROR: Backend ownership changed during the health check.'
                return $false
            }
        }
        Start-Sleep -Seconds 1
    }
    Write-Host ("  ERROR: Model " + $Model.label + ' did not become healthy on port ' + $Port + ' before timeout.')
    return $false
}

function Upgrade-LegacyRouteIfOwned {
    $mutex = Enter-BackendLifecycleLock
    if (-not $mutex) {
        Write-Host '  ERROR: Cannot adopt a legacy route while another backend lifecycle action is in progress.'
        return $false
    }
    try {
    $route = Get-Route
    if (-not $route) { return $true }
    if ([int]$route.version -ge 2 -and $route.owner -and $route.listener -and $route.generation) { return $true }

    $model = Find-Model ([string]$route.model)
    if (-not $model) {
        Write-Host ("  ERROR: Legacy route model '" + $route.model + "' is not in the current catalog.")
        return $false
    }
    $port = Get-ModelBackendPort $model
    if ($port -le 0 -or [int]$route.port -ne $port) {
        Write-Host '  ERROR: Legacy route port does not match the catalog model.'
        return $false
    }
    $snapshot = Get-BackendListenerSnapshot $port
    if (-not $snapshot.Success -or $snapshot.Processes.Count -ne 1) {
        Write-Host ("  ERROR: Legacy backend on port " + $port + ' is absent or ambiguous; leaving the route unchanged.')
        return $false
    }
    $listener = $snapshot.Processes[0]
    $owner = $null
    if (Test-BackendProcessSignature $listener $model $port 'Server') {
        $owner = New-BackendOwnerRecord ([int]$listener.ProcessId) $model $port 'Server'
    } else {
        $roles = if ($model.kind -eq 'inkling') { @('InklingLauncher') }
            elseif ($model.kind -eq 'mini') { @('GameGuard') }
            else { @() }
        if ($roles.Count -eq 0) { return $false }
        try {
            $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        } catch {
            Write-Host ("  ERROR: Cannot inspect legacy backend managers: " + $_.Exception.Message)
            return $false
        }
        $candidates = @()
        foreach ($role in $roles) {
            $template = [pscustomobject]@{ Role = [string]$role; Port = [int]$port }
            foreach ($process in $processes) {
                if ((Test-BackendManagerSignature $process $template $model) -and
                    (Test-ProcessDescendsFrom ([int]$listener.ProcessId) ([int]$process.ProcessId))) {
                    $candidates += [pscustomobject]@{ ProcessId = [int]$process.ProcessId; Role = [string]$role }
                }
            }
        }
        if ($candidates.Count -ne 1) {
            Write-Host '  ERROR: Could not identify exactly one authorized legacy backend manager.'
            return $false
        }
        $candidate = $candidates[0]
        $owner = New-BackendOwnerRecord ([int]$candidate.ProcessId) $model $port ([string]$candidate.Role)
    }
    if (-not $owner) {
        Write-Host '  ERROR: Could not record the legacy backend owner; leaving the route unchanged.'
        return $false
    }

    $ownersRead = Get-BackendOwners
    if (-not $ownersRead.Success) {
        Write-Host ("  ERROR: Cannot read backend ownership records: " + $ownersRead.Error)
        return $false
    }
    $owners = @($ownersRead.Owners)
    $samePort = @($owners | Where-Object { [int]$_.Port -eq $port })
    if ($samePort.Count -gt 0) {
        if ($samePort.Count -ne 1) {
            Write-Host ("  ERROR: Port " + $port + ' has multiple ownership records; leaving every record unchanged.')
            return $false
        }
        $matching = @($samePort | Where-Object {
            [string]$_.ModelId -eq [string]$model.id -and
            [string]$_.Role -eq [string]$owner.Role -and
            [int]$_.ProcessId -eq [int]$owner.ProcessId -and
            (Get-ValidatedBackendOwnerProcess $_)
        })
        if ($matching.Count -ne 1) {
            Write-Host ("  ERROR: Port " + $port + ' already has a different or ambiguous backend owner record.')
            return $false
        }
        $owner = $matching[0]
    } else {
        $owners += $owner
    }
    if (-not (Wait-ManagedBackendReady $model $port $owner 5)) { return $false }

    if (-not (Save-BackendOwners $owners)) { return $false }
    try {
        Set-Route $model $port $owner
    } catch {
        Write-Host ("  ERROR: Could not publish the upgraded route: " + $_.Exception.Message)
        Save-BackendOwners $ownersRead.Owners | Out-Null
        return $false
    }
    Write-Host ("  Adopted the verified legacy route for " + $model.label + ' without restarting its backend.')
    return $true
    } finally {
        Exit-BackendLifecycleLock $mutex
    }
}

function Stop-BackendOwnersForPort([int]$Port, [string]$Role = '', [switch]$LockHeld) {
    $mutex = $null
    if (-not $LockHeld) {
        $mutex = Enter-BackendLifecycleLock
        if (-not $mutex) {
            Write-Host '  ERROR: Another Panda backend lifecycle action is in progress.'
            return $false
        }
    }
    try {
        if ($Port -in @(Get-OtherRouterBackendPorts)) {
            Write-Host ("  Preserving backend on port " + $Port + "; another Panda API routes to it.")
            return $false
        }
        $read = Get-BackendOwners
        if (-not $read.Success) {
            Write-Host ("  ERROR: Cannot read backend ownership records: " + $read.Error)
            return $false
        }
        $remaining = @()
        $allStopped = $true
        foreach ($owner in @($read.Owners)) {
            if ([int]$owner.Port -ne $Port -or ($Role -and [string]$owner.Role -ne $Role)) {
                $remaining += $owner
                continue
            }
            $result = Stop-TrackedBackendOwner $owner
            if ($result -eq 'failed') { $remaining += $owner; $allStopped = $false }
            elseif ($result -eq 'dryrun') { $remaining += $owner }
            elseif ($result -eq 'stale') { Write-Host ("  Removed stale ownership record for PID " + $owner.ProcessId + "; no process was stopped.") }
        }
        if ($DryRun) { return $allStopped }
        if (-not (Save-BackendOwners $remaining)) { return $false }
        if ($Role) { return $allStopped }
        $after = Get-BackendListenerSnapshot $Port
        if (-not $after.Success) {
            Write-Host ("  ERROR: Cannot confirm backend port " + $Port + ' is clear: ' + $after.Error)
            return $false
        }
        if ($after.Processes.Count -gt 0) {
            foreach ($process in $after.Processes) {
                Write-Host ("  WARNING: Leaving unowned listener " + $process.Name + " (PID " + $process.ProcessId + ") on port " + $Port + '.')
            }
            return $false
        }
        return $true
    } finally {
        if ($mutex) { Exit-BackendLifecycleLock $mutex }
    }
}

function Stop-CurrentEngine([switch]$LockHeld, [switch]$AuthorizeGyroStop) {
    $script:GyroStopAuthorizationRequired = $false
    $mutex = $null
    if (-not $LockHeld) {
        $mutex = Enter-BackendLifecycleLock
        if (-not $mutex) {
            Write-Host '  ERROR: Another Panda backend lifecycle action is in progress.'
            return $false
        }
    }
    try {
        $protectedPorts = @(Get-OtherRouterBackendPorts)
        $read = Get-BackendOwners
        if (-not $read.Success) {
            Write-Host ("  ERROR: Cannot read backend ownership records: " + $read.Error)
            return $false
        }
        $gyroOwners = @(Get-GyroBackendOwners $read.Owners)
        if ($gyroOwners.Count -gt 0 -and -not $AuthorizeGyroStop) {
            $script:GyroStopAuthorizationRequired = $true
            Write-Host '  A Gyro-S ownership record exists. Explicit authorization is required before backend cleanup.'
            return $false
        }
        $remaining = @()
        $allStopped = $true
        foreach ($owner in @($read.Owners)) {
            if ([int]$owner.Port -in $protectedPorts) {
                Write-Host ("  Preserving managed backend on port " + $owner.Port + "; another Panda API routes to it.")
                $remaining += $owner
                continue
            }
            $result = Stop-TrackedBackendOwner $owner
            if ($result -eq 'failed') {
                $remaining += $owner
                $allStopped = $false
            } elseif ($result -eq 'dryrun') {
                $remaining += $owner
            } elseif ($result -eq 'stale') {
                Write-Host ("  Removed stale ownership record for PID " + $owner.ProcessId + '; no process was stopped.')
            }
        }
        if ($DryRun) { return $allStopped }
        if (-not (Save-BackendOwners $remaining)) { return $false }
        foreach ($port in @([int]$script:cat.ports.infer, [int]$script:cat.ports.mini, [int]$script:cat.ports.gyro)) {
            if ($port -in $protectedPorts) { continue }
            $snapshot = Get-BackendListenerSnapshot $port
            if (-not $snapshot.Success) {
                Write-Host ("  WARNING: Cannot inspect port " + $port + ': ' + $snapshot.Error)
                $allStopped = $false
                continue
            }
            foreach ($process in $snapshot.Processes) {
                Write-Host ("  WARNING: Leaving unowned listener " + $process.Name + " (PID " + $process.ProcessId + ") on port " + $port + '.')
                $allStopped = $false
            }
        }
        return $allStopped
    } finally {
        if ($mutex) { Exit-BackendLifecycleLock $mutex }
    }
}

function Stop-PandaEngine([switch]$AuthorizeGyroStop) {
    $script:GyroStopAuthorizationRequired = $false
    $mutex = Enter-BackendLifecycleLock
    if (-not $mutex) {
        Write-Host '  ERROR: Another Panda backend lifecycle action is in progress.'
        return $false
    }
    try {
        $backendsStopped = Stop-CurrentEngine -LockHeld -AuthorizeGyroStop:$AuthorizeGyroStop
        if ($script:GyroStopAuthorizationRequired) { return $false }
        $routerStopped = Stop-Router
        return ([bool]$backendsStopped -and [bool]$routerStopped)
    } finally {
        Exit-BackendLifecycleLock $mutex
    }
}
function Clear-StaleRouteIfBackendOffline {
    $mutex = Enter-BackendLifecycleLock
    if (-not $mutex) {
        Write-Host '  WARNING: Another backend lifecycle action is in progress; preserving the route.'
        return $false
    }
    try {
    $route = Get-Route
    if (-not $route) { return $true }
    if ([int]$route.port -le 0) {
        Write-Host '  WARNING: Legacy route has no usable backend port; preserving the route.'
        return $false
    }
    $snapshot = Get-BackendListenerSnapshot ([int]$route.port)
    if (-not $snapshot.Success) {
        Write-Host ("  WARNING: Cannot inspect route backend on port " + $route.port + '; preserving the route.')
        return $false
    }
    if ($snapshot.Processes.Count -eq 0) {
        Clear-Route
        return $true
    }
    return $false
    } finally {
        Exit-BackendLifecycleLock $mutex
    }
}

function Start-Model($m, $s, [switch]$AuthorizeGyroStop, [switch]$LockHeld) {
    $script:GyroStopAuthorizationRequired = $false
    $script:GyroStartLeftRunning = $false
    $script:GyroStartOwnershipSaved = $false
    $script:GyroStartProcessId = 0
    if (-not (Test-Model $m)) {
        Write-Host '  Model is not installed. Use D to download it first.'
        return $false
    }
    if ($DryRun) { Write-Host ('  [dry-run] would start ' + $m.label); return $true }
    $backendPort = Get-ModelBackendPort $m
    if ($backendPort -le 0) {
        Write-Host '  ERROR: Model has no supported backend port.'
        return $false
    }
    $mutex = $null
    if (-not $LockHeld) {
        $mutex = Enter-BackendLifecycleLock
        if (-not $mutex) {
            Write-Host '  ERROR: Another Panda backend lifecycle action is in progress.'
            return $false
        }
    }
    try {
        if (-not $LockHeld) { $s = Get-State }
        if ($m.kind -eq 'mini' -and $s.gameMode -and -not (Test-GameGuard)) {
            Write-Host '  ERROR: Game Mode is selected, but its guard or configuration files are missing. MiniCPM was not started in standard mode.'
            return $false
        }
        if (-not (Start-Router -LockHeld)) { return $false }
        if ($backendPort -in @(Get-OtherRouterBackendPorts)) {
            Write-Host ("  ERROR: Backend port " + $backendPort + ' is protected because another Panda API routes to it; it was left untouched.')
            return $false
        }
        $read = Get-BackendOwners
        if (-not $read.Success) {
            Write-Host ("  ERROR: Cannot read backend ownership records: " + $read.Error)
            return $false
        }
        $preflight = Get-BackendListenerSnapshot $backendPort
        if (-not $preflight.Success) {
            Write-Host ("  ERROR: Cannot inspect backend port " + $backendPort + ': ' + $preflight.Error)
            return $false
        }
        if ($preflight.Processes.Count -gt 1) {
            Write-Host ("  ERROR: Multiple processes are listening on backend port " + $backendPort + '; no process was touched.')
            return $false
        }
        if ($preflight.Processes.Count -eq 1) {
            $existing = $preflight.Processes[0]
            $existingOwner = Get-ManagedBackendOwnerForListener $existing $read.Owners
            if (-not $existingOwner) {
                Write-Host ("  ERROR: Backend port " + $backendPort + ' is occupied by an unowned process; it was left untouched.')
                return $false
            }
            if ([string]$existingOwner.ModelId -eq [string]$m.id) {
                $matchesSettings = $true
                if ($m.kind -eq 'mini') {
                    $matchesSettings = (([string]$existingOwner.Role -eq 'GameGuard') -eq [bool]$s.gameMode)
                } elseif ($m.kind -eq 'inkling') {
                    $matchesSettings = Test-CommandLineArgumentValue ([string]$existing.CommandLine) '--max-context' ([string][int]$s.context)
                }
                if ($matchesSettings) {
                    if (-not (Wait-ManagedBackendReady $m $backendPort $existingOwner)) { return $false }
                    Set-Route $m $backendPort $existingOwner
                    Write-Host ('  Panda API: http://127.0.0.1:' + $script:cat.ports.api + '/v1  ->  ' + $m.label + ' (already running)')
                    return $true
                }
            }
        }
        $gyroOwners = @(Get-GyroBackendOwners $read.Owners)
        if ($gyroOwners.Count -gt 0 -and -not $AuthorizeGyroStop) {
            $script:GyroStopAuthorizationRequired = $true
            Write-Host '  A Gyro-S ownership record exists. Explicit authorization is required before switching to another model.'
            return $false
        }
        if (-not (Stop-CurrentEngine -LockHeld -AuthorizeGyroStop:$AuthorizeGyroStop)) {
            Write-Host '  ERROR: Existing managed backends could not be stopped safely; no new route was published.'
            if (-not $script:GyroStopAuthorizationRequired) { Clear-StaleRouteIfBackendOffline }
            return $false
        }
        Clear-Route
        $read = Get-BackendOwners
        if (-not $read.Success) {
            Write-Host ("  ERROR: Cannot reread backend ownership records: " + $read.Error)
            Clear-StaleRouteIfBackendOffline
            return $false
        }
        $afterStop = Get-BackendListenerSnapshot $backendPort
        if (-not $afterStop.Success -or $afterStop.Processes.Count -gt 0) {
            Write-Host ("  ERROR: Backend port " + $backendPort + ' is still occupied after managed cleanup; no process was touched and no route was published.')
            Clear-StaleRouteIfBackendOffline
            return $false
        }

        $started = $null
        $role = 'Server'
        switch ($m.kind) {
            'inkling' {
                $cfgPath = Join-Path $script:Repo 'config.json'
                $cfg = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { @{} }
                $cfg.artifact = $m.artifact
                $cfg.context  = [int]$s.context
                $cfg.reasoning = $script:cat.ninfer.reasoning
                $cfg.port     = $backendPort
                ($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
                $startPs1 = Join-Path $PSScriptRoot 'legacy\start.ps1'
                $role = 'InklingLauncher'
                $started = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:Repo -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $startPs1 + '"'),'-AutoStart')
            }
            'mini' {
                $root = $script:cat.roots.knownMini
                if ($s.gameMode) {
                    if (-not (Test-GameGuard)) {
                        Write-Host '  ERROR: Game Mode files disappeared before launch; MiniCPM was not started in standard mode.'
                        Clear-Route
                        return $false
                    }
                    $guard = Get-GameGuardPath 'guard'
                    $role = 'GameGuard'
                    $started = Start-Process -FilePath 'powershell.exe' -WorkingDirectory $root -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $guard + '"'),'-Port',[string]$backendPort)
                } else {
                    $python = Join-Path $root '.venv\Scripts\python.exe'
                    $started = Start-Process -FilePath $python -WorkingDirectory $root -WindowStyle Hidden -PassThru -ArgumentList @('serve\server.py','--engine','strata','--config',$m.serverConfig,'--port',[string]$backendPort)
                }
            }
            'gyro' {
                # Gyro-S runs from Panda's own bundled engine and pack. No Strata desktop.
                $root = $script:cat.roots.knownMini
                $python = Join-Path $root '.venv\Scripts\python.exe'
                $started = Start-Process -FilePath $python -WorkingDirectory $root -WindowStyle Hidden -PassThru -ArgumentList @('serve\server.py','--engine','strata','--config',$m.serverConfig,'--port',[string]$backendPort)
            }
        }
        if (-not $started) {
            Write-Host '  ERROR: The backend launcher process could not be started.'
            Clear-StaleRouteIfBackendOffline
            return $false
        }
        $owner = $null
        for ($i = 0; $i -lt 15 -and -not $owner; $i++) {
            $owner = New-BackendOwnerRecord ([int]$started.Id) $m $backendPort $role
            if (-not $owner) { Start-Sleep -Milliseconds 200 }
        }
        if (-not $owner) {
            Write-Host '  ERROR: Could not establish a verifiable backend owner; no route was published.'
            if (-not (Preserve-GyroAfterStartFailure $m $started 'owner verification failed' -AuthorizeGyroStop:$AuthorizeGyroStop -OwnershipSaved:$false)) {
                try { $started.Kill() } catch {}
            }
            Clear-StaleRouteIfBackendOffline
            return $false
        }
        $owners = @($read.Owners) + @($owner)
        if (-not (Save-BackendOwners $owners)) {
            if (-not (Preserve-GyroAfterStartFailure $m $started 'ownership persistence failed' -AuthorizeGyroStop:$AuthorizeGyroStop -OwnershipSaved:$false)) {
                Stop-TrackedBackendOwner $owner | Out-Null
            }
            Clear-StaleRouteIfBackendOffline
            return $false
        }
        $script:GyroStartOwnershipSaved = $true
        if (-not (Wait-ManagedBackendReady $m $backendPort $owner)) {
            if (-not (Preserve-GyroAfterStartFailure $m $started 'readiness verification failed' -AuthorizeGyroStop:$AuthorizeGyroStop -OwnershipSaved:$true)) {
                $stopResult = Stop-TrackedBackendOwner $owner
                if ($stopResult -eq 'stopped' -or $stopResult -eq 'stale') {
                    $owners = @($owners | Where-Object {
                        [int]$_.ProcessId -ne [int]$owner.ProcessId -or [long]$_.StartedUtcTicks -ne [long]$owner.StartedUtcTicks
                    })
                    Save-BackendOwners $owners | Out-Null
                }
            }
            Clear-StaleRouteIfBackendOffline
            return $false
        }
        Set-Route $m $backendPort $owner
        $route = Get-Route
        if (-not $route -or [int]$route.port -ne $backendPort -or [string]$route.model -ne [string]$m.id) {
            Write-Host '  ERROR: The verified backend route could not be published.'
            if (-not (Preserve-GyroAfterStartFailure $m $started 'route publication failed' -AuthorizeGyroStop:$AuthorizeGyroStop -OwnershipSaved:$true)) {
                $stopResult = Stop-TrackedBackendOwner $owner
                if ($stopResult -eq 'stopped' -or $stopResult -eq 'stale') {
                    $owners = @($owners | Where-Object {
                        [int]$_.ProcessId -ne [int]$owner.ProcessId -or [long]$_.StartedUtcTicks -ne [long]$owner.StartedUtcTicks
                    })
                    Save-BackendOwners $owners | Out-Null
                }
            }
            Clear-StaleRouteIfBackendOffline
            return $false
        }
        Write-Host ('  Panda API: http://127.0.0.1:' + $script:cat.ports.api + '/v1  ->  ' + $m.label + ' (internal ' + $backendPort + ')')
        return $true
    } catch {
        if ($started -and (Preserve-GyroAfterStartFailure $m $started 'startup verification raised an error' -AuthorizeGyroStop:$AuthorizeGyroStop -OwnershipSaved:$script:GyroStartOwnershipSaved)) {
            Write-Host '  Gyro-S was not terminated; inspect the reported PID and retained ownership state before retrying.'
        }
        Write-Host ("  ERROR: Model start failed: " + $_.Exception.Message)
        Clear-StaleRouteIfBackendOffline
        return $false
    } finally {
        if ($mutex) { Exit-BackendLifecycleLock $mutex }
    }
}
function Preserve-GyroAfterStartFailure($Model, $Process, [string]$Reason, [switch]$AuthorizeGyroStop, [switch]$OwnershipSaved) {
    if (-not $Model -or [string]$Model.kind -ne 'gyro' -or $AuthorizeGyroStop -or -not $Process) { return $false }
    $script:GyroStartLeftRunning = $true
    $script:GyroStartOwnershipSaved = [bool]$OwnershipSaved
    $script:GyroStartProcessId = [int]$Process.Id
    $ownershipMessage = if ($OwnershipSaved) { 'The ownership record was retained.' } else { 'No ownership record could be persisted; the PID may be untracked.' }
    Write-Host ("  WARNING: Gyro-S " + $Reason + "; PID " + $Process.Id + " was not terminated because no stop authorization was given. " + $ownershipMessage)
    return $true
}

function Start-ModelFromConsole($m, $s) {
    $started = Start-Model $m $s -AuthorizeGyroStop:$AuthorizeGyroStop
    if ($started -or -not $script:GyroStopAuthorizationRequired -or $AuthorizeGyroStop) { return [bool]$started }
    $answer = Read-Host ('A Gyro-S ownership record may represent a running process. Explicitly authorize cleanup to start ' + $m.label + '? (y/N)')
    if ($answer -in @('y','Y')) { return [bool](Start-Model $m $s -AuthorizeGyroStop) }
    return $false
}

function Install-OpenCodeLayer {
    $dest = Join-Path $env:USERPROFILE '.config\opencode'
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Write-Host 'This copies the Panda Engine OpenCode config (all 3 model providers) to:'
    Write-Host ('  ' + $dest)
    Write-Host 'Existing opencode.json, AGENT_RULES.md and plugins/ will be backed up with a timestamp.'
    $a = Read-Host 'Continue? (y/N)'
    if ($a -ne 'y' -and $a -ne 'Y') { return }
    if ($DryRun) { Write-Host '  [dry-run] skipped'; return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $cfg = Join-Path $dest 'opencode.json'
    $rules = Join-Path $dest 'AGENT_RULES.md'
    $pl = Join-Path $dest 'plugins'
    if (Test-Path -LiteralPath $cfg) { Copy-Item $cfg ($cfg + '.bak-panda-' + $stamp) -Force }
    if (Test-Path -LiteralPath $rules) { Copy-Item $rules ($rules + '.bak-panda-' + $stamp) -Force }
    if (Test-Path -LiteralPath $pl) { Copy-Item $pl ($pl + '.bak-panda-' + $stamp) -Recurse -Force }
    Copy-Item (Join-Path $script:Repo 'config\opencode.json') $cfg -Force
    Copy-Item (Join-Path $script:Repo 'AGENT_RULES.md') $rules -Force
    # Always refresh the bundled plugins, even when a plugins/ folder already exists.
    New-Item -ItemType Directory -Force -Path $pl | Out-Null
    Copy-Item (Join-Path $script:Repo 'plugins\*') $pl -Recurse -Force
    # Absolute instructions path to the bundled rules file (same content as the live setup).
    $cfgObj = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgObj.instructions = @($rules)
    # OpenCode parses JSON without a BOM; PS 5.1 Set-Content would emit one.
    $cfgJson = $cfgObj | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($cfg, $cfgJson, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host '  OpenCode layer installed. Model IDs: ninfer/inkling-2-mini, polystrata-mini/minicpm-v-4.7-35b-a3b-q4_k_m, strata/gyro-gyro-s'
}
function Backup-OpenCodeConfig {
    if (-not (Test-Path -LiteralPath $script:OpenCodeCfg)) { Write-Host '  OpenCode config not found. Press C first to install the layer.'; return $false }
    if ($DryRun) { Write-Host '  [dry-run] would back up the OpenCode config'; return $true }
    if (Test-Path -LiteralPath $script:OCBackupPath) { return $true }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = $script:OpenCodeCfg + '.bak-panda-' + $stamp
    Copy-Item -LiteralPath $script:OpenCodeCfg $backup -Force
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:OCBackupPath) | Out-Null
    @{ original = $script:OpenCodeCfg; backup = $backup; time = $stamp } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $script:OCBackupPath -Encoding UTF8
    Write-Host ("  OpenCode config backed up: " + $backup)
    return $true
}
function Restore-OpenCodeConfig {
    if ($DryRun) { return }
    if (-not (Test-Path -LiteralPath $script:OCBackupPath)) { return }
    try {
        $b = Get-Content -LiteralPath $script:OCBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($b.backup -and (Test-Path -LiteralPath $b.backup)) {
            Copy-Item -LiteralPath $b.backup $script:OpenCodeCfg -Force
            Write-Host '  OpenCode config restored from the Panda backup.'
            Remove-Item -LiteralPath $script:OCBackupPath -Force -ErrorAction SilentlyContinue
        } else {
            Write-Host '  WARNING: Panda OpenCode backup file is missing; config left as is.'
            Remove-Item -LiteralPath $script:OCBackupPath -Force -ErrorAction SilentlyContinue
        }
    } catch {
        # Keep the marker so the next launch can retry the restore.
        Write-Host '  ERROR: could not restore the OpenCode config; will retry next launch.'
    }
}
function Write-OpenCodeV1Config {
    # The CLI on PATH is OpenCode V1; the live config is V2 (OpenChamber). Build a V1 view
    # in an isolated config/data home so the CLI can list and use all Panda models.
    if ($DryRun -or -not (Test-Path -LiteralPath $script:OpenCodeCfg)) { return }
    $cfg = Get-Content -LiteralPath $script:OpenCodeCfg -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($pname in @($cfg.providers.PSObject.Properties.Name)) {
        $prov = $cfg.providers.$pname
        if (-not $prov.models) { continue }
        foreach ($mname in @($prov.models.PSObject.Properties.Name)) {
            $m = $prov.models.$mname
            if ($m.variants -is [array]) {
                $vobj = [ordered]@{}
                foreach ($v in $m.variants) {
                    $entry = [ordered]@{}
                    if ($v.name) { $entry['name'] = $v.name }
                    if ($v.body) { $entry['body'] = $v.body }
                    $vobj[$v.id] = $entry
                }
                $m.variants = $vobj
            }
        }
    }
    $v1 = [ordered]@{
        '$schema' = 'https://opencode.ai/config.json'
        model = $cfg.model
        provider = $cfg.providers
    }
    $json = $v1 | ConvertTo-Json -Depth 100
    $dir = Join-Path $script:OCV1Home 'opencode'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    New-Item -ItemType Directory -Force -Path $script:OCV1Data | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'opencode.json'), $json, (New-Object System.Text.UTF8Encoding($false)))
}
function Sync-OpenCodeConfig($m) {
    if ($DryRun) { Write-Host '  [dry-run] would sync the OpenCode config'; return $true }
    if (-not (Backup-OpenCodeConfig)) { return $false }
    try { $cfg = Get-Content -LiteralPath $script:OpenCodeCfg -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Write-Host '  ERROR: OpenCode config is not valid JSON.'; return $false }
    $api = 'http://127.0.0.1:' + $script:cat.ports.api + '/v1'
    foreach ($name in @('strata','ninfer','polystrata-mini','polystrata')) {
        if ($cfg.providers.PSObject.Properties[$name]) { $cfg.providers.$name.settings.baseURL = $api }
    }
    if ($m -and $m.provider) { $cfg.model = $m.provider }
    # OpenCode parses JSON without a BOM; PowerShell 5.1 Set-Content would add one.
    $json = $cfg | ConvertTo-Json -Depth 100
    [System.IO.File]::WriteAllText($script:OpenCodeCfg, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-OpenCodeV1Config
    Write-Host ("  OpenCode synced: model=" + $cfg.model + "  API=" + $api)
    return $true
}
function Start-OpenCode($m) {
    if ($DryRun) { Write-Host '  [dry-run] would start OpenCode against the Panda API'; return }
    if (-not $m) { Write-Host '  No active model. Pick one first.'; return }
    if (-not (Sync-OpenCodeConfig $m)) { return }
    $oc = (Get-Command opencode -ErrorAction SilentlyContinue).Source
    if (-not $oc) {
        $cli = Join-Path $env:LOCALAPPDATA 'Programs\ai.opencode.desktop\resources\opencode-cli.exe'
        if (Test-Path -LiteralPath $cli) { $oc = $cli }
    }
    if (-not $oc) { Write-Host '  ERROR: opencode not found on PATH or in the desktop install.'; return }
    Write-OpenCodeV1Config
    $oldCfgHome = $env:XDG_CONFIG_HOME
    $oldDataHome = $env:XDG_DATA_HOME
    try {
        $env:XDG_CONFIG_HOME = $script:OCV1Home
        $env:XDG_DATA_HOME = $script:OCV1Data
        if ($oc -like '*.ps1') {
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:Repo -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $oc + '"')) | Out-Null
        } else {
            Start-Process -FilePath $oc -WorkingDirectory $script:Repo | Out-Null
        }
    } finally {
        $env:XDG_CONFIG_HOME = $oldCfgHome
        $env:XDG_DATA_HOME = $oldDataHome
    }
    Write-Host '  OpenCode started in a new terminal, pointed at the Panda API.'
}
function Show-Menu($s) {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host '  P A N D A   E N G I N E'
    Write-Host '============================================================'
    $active = Find-Model $s.active
    $route = Get-Route
    $name = if ($active) { $active.label } else { 'none' }
    $installed = if ($active -and (Test-Model $active)) { 'OK' } else { '-' }
    $api = if (Test-Router) {
        if ($route) { 'API ' + $script:cat.ports.api + '->' + $route.port } else { 'API ' + $script:cat.ports.api + ' (no backend)' }
    } else { 'API off' }
    $gm = if ($s.gameMode) { 'Game ON' } else { 'Game off' }
    Write-Host ("  Status: " + $name + " [" + $installed + "] | " + $api + " | " + $gm)
    Write-Host '------------------------------------------------------------'
    foreach ($m in $script:cat.models) { Write-Host ("  " + $m.id.PadRight(16) + " " + $m.label.PadRight(32) + $(if (Test-Model $m) {'[OK]'} else {'[-]'})) }
    Write-Host '------------------------------------------------------------'
    $keys = @()
    for ($i=1; $i -le $script:cat.models.Count; $i++) { $keys += ("$i=" + $script:cat.models[$i-1].id) }
    Write-Host ('  Models: ' + ($keys -join '  '))
    Write-Host '  D Download/change models    S START (start active)'
    Write-Host '  G Toggle MiniCPM game mode  C Install OpenCode layer'
    Write-Host '  O OpenCode (active model)   X Stop API+backends'
    Write-Host '  R Reset first-run           Q Exit (restores OpenCode config)'
    Write-Host '============================================================'
}

function Get-GuiStatus {
    $s = Get-State
    $route = Get-Route
    $router = Get-RouterProcess
    $apiListeners = @(Get-NetTCPConnection -State Listen -LocalPort ([int]$script:cat.ports.api) -ErrorAction SilentlyContinue)
    $apiConflict = (-not $router) -and ($apiListeners.Count -gt 0)
    $health = $null
    if ($router) {
        try {
            $health = Invoke-RestMethod -Uri ('http://127.0.0.1:' + [int]$script:cat.ports.api + '/_panda/status') -TimeoutSec 3
        } catch {}
    }
    $backendRunning = [bool]($health -and $health.upstream_up)
    $routeModel = if ($route -and $backendRunning) { [string]$route.model } else { '' }
    $models = @(
        foreach ($m in @($script:cat.models)) {
            $modelId = [string]$m.id
            $files = @()
            if ($m.artifact) { $files += [string]$m.artifact }
            if ($m.files) { $files += @($m.files | ForEach-Object { [string]$_.name }) }
            if ($m.serverConfig) { $files += [string]$m.serverConfig }
            [pscustomobject]@{
                id         = $modelId
                label      = [string]$m.label
                kind       = [string]$m.kind
                provider   = [string]$m.provider
                files      = @($files)
                installed  = [bool](Test-Model $m)
                active     = ([string]$s.active -eq $modelId)
                running    = ($backendRunning -and $routeModel -eq $modelId)
                canInstall = ($m.kind -ne 'gyro')
            }
        }
    )
    $activeModel = Find-Model $s.active
    return [pscustomobject]@{
        success        = $true
        action         = 'status'
        activeId       = [string]$s.active
        activeLabel    = $(if ($activeModel) { [string]$activeModel.label } else { '' })
        apiRunning     = [bool]$router
        apiConflict    = [bool]$apiConflict
        backendRunning = $backendRunning
        context        = [int]$s.context
        gameMode       = [bool]$s.gameMode
        routeModel     = $routeModel
         routeName      = $(if ($route -and $backendRunning) { [string]$route.name } else { '' })
         routePort      = $(if ($route -and $backendRunning) { [int]$route.port } else { 0 })
        models         = $models
    }
}

function Invoke-GuiAction([string]$Action, [string]$SelectedModelId, [int]$Context, [string]$GameMode, [switch]$AuthorizeGyroStop) {
    try {
        $s = Get-State
        switch ($Action.ToLowerInvariant()) {
            'initialize' {
                Ensure-Links
                if (-not $DryRun) { Restore-OpenCodeConfig }
                if (-not (Start-Router)) {
                    return [pscustomobject]@{ success = $false; message = 'Panda API did not start. Check logs\panda-router.log.' }
                }
                $message = 'Panda API is ready.'
                try {
                    $roots = @([System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($script:Repo)),
                               [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($env:TEMP)),
                               [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath([string]$script:cat.roots.knownMiniData))) | Select-Object -Unique
                    foreach ($driveRoot in $roots) {
                        $drive = [System.IO.DriveInfo]::new($driveRoot)
                        $free = [long]$drive.AvailableFreeSpace
                        if ($free -lt 10GB) {
                            $message += (' Warning: only ' + [Math]::Round($free / 1GB, 1) + ' GiB free on ' + $driveRoot + '; model downloads and temporary files may require more space.')
                        }
                    }
                } catch {
                    $message += ' Free disk space could not be checked; verify space before downloading models.'
                }
                return [pscustomobject]@{ success = $true; message = $message }
            }
            'status' {
                return Get-GuiStatus
            }
            'install' {
                $m = Find-Model $SelectedModelId
                if (-not $m) { return [pscustomobject]@{ success = $false; message = 'Model is not in the Panda catalog.' } }
                if ($m.kind -eq 'gyro') { return [pscustomobject]@{ success = $false; message = 'Gyro-S files are bundled; no download action is available.' } }
                $ok = Ensure-Model $m
                if ($ok) {
                    $mutex = Enter-BackendLifecycleLock
                    if (-not $mutex) { return [pscustomobject]@{ success = $false; message = 'Files were installed, but state could not be saved because another action is in progress. Refresh status.' } }
                    try {
                    $s = Get-State
                    $tmp = @($s.downloaded) + @($m.id)
                    $s.downloaded = @($tmp | Select-Object -Unique)
                    Save-State $s
                    } finally {
                        Exit-BackendLifecycleLock $mutex
                    }
                    return [pscustomobject]@{ success = $true; message = ($m.label + ' is installed. It was not started.') }
                }
                return [pscustomobject]@{ success = $false; message = 'Installation did not complete. Check the launcher output and model files.' }
            }
            'setactive' {
                $m = Find-Model $SelectedModelId
                if (-not $m) { return [pscustomobject]@{ success = $false; message = 'Model is not in the Panda catalog.' } }
                if (-not (Test-Model $m)) { return [pscustomobject]@{ success = $false; message = 'Install the model before setting it active.' } }
                $mutex = Enter-BackendLifecycleLock
                if (-not $mutex) { return [pscustomobject]@{ success = $false; message = 'Another backend lifecycle action is in progress; selection was not changed.' } }
                try {
                $s = Get-State
                $s.active = $m.id
                Save-State $s
                } finally {
                    Exit-BackendLifecycleLock $mutex
                }
                return [pscustomobject]@{ success = $true; message = ($m.label + ' is selected for the next start; the running route was not changed.') }
            }
            'setcontext' {
                $m = Find-Model $SelectedModelId
                if (-not $m) { return [pscustomobject]@{ success = $false; message = 'Model is not in the Panda catalog.' } }
                if ($m.kind -ne 'inkling' -or $Context -notin @(65536, 98304, 131072)) {
                    return [pscustomobject]@{ success = $false; message = 'Context must be an allowed Inkling next-start value: 65536, 98304, or 131072.' }
                }
                $mutex = Enter-BackendLifecycleLock
                if (-not $mutex) { return [pscustomobject]@{ success = $false; message = 'Another backend lifecycle action is in progress; settings were not changed.' } }
                try {
                    $s = Get-State
                    $s.context = [int]$Context
                    Save-State $s
                } finally {
                    Exit-BackendLifecycleLock $mutex
                }
                return [pscustomobject]@{ success = $true; message = ('Inkling context ' + $Context + ' saved for the next start; the running backend was not changed.') }
            }
            'setgamemode' {
                $m = Find-Model $SelectedModelId
                if (-not $m -or $m.kind -ne 'mini') {
                    return [pscustomobject]@{ success = $false; message = 'Game Mode applies to MiniCPM only.' }
                }
                $modeValue = ([string]$GameMode).ToLowerInvariant()
                if ($modeValue -notin @('true', 'false')) {
                    return [pscustomobject]@{ success = $false; message = 'Game Mode value must be true or false.' }
                }
                if ($modeValue -eq 'true' -and -not (Test-GameGuard)) {
                    return [pscustomobject]@{ success = $false; message = 'Game Mode was not saved because its guard or configuration files are missing from the Poly-strata install.' }
                }
                $mutex = Enter-BackendLifecycleLock
                if (-not $mutex) { return [pscustomobject]@{ success = $false; message = 'Another backend lifecycle action is in progress; settings were not changed.' } }
                try {
                    $s = Get-State
                    $s.gameMode = ($modeValue -eq 'true')
                    Save-State $s
                } finally {
                    Exit-BackendLifecycleLock $mutex
                }
                return [pscustomobject]@{ success = $true; message = ('MiniCPM Game Mode saved as ' + $modeValue + ' for the next start; no backend was stopped or restarted.') }
            }
            'start' {
                $m = Find-Model $SelectedModelId
                if (-not $m) { return [pscustomobject]@{ success = $false; message = 'Model is not in the Panda catalog.' } }
                if (-not (Test-Model $m)) { return [pscustomobject]@{ success = $false; message = 'Install the model before starting it.' } }
                $mutex = Enter-BackendLifecycleLock
                if (-not $mutex) { return [pscustomobject]@{ success = $false; message = 'Another backend lifecycle action is in progress; try again after it completes.' } }
                try {
                $s = Get-State
                $oldActive = [string]$s.active
                $started = Start-Model $m $s -AuthorizeGyroStop:$AuthorizeGyroStop -LockHeld
                if (-not $started) {
                    if ($script:GyroStartLeftRunning) {
                        $s.active = $oldActive
                        Save-State $s
                        $ownershipMessage = if ($script:GyroStartOwnershipSaved) {
                            'The ownership record was retained.'
                        } else {
                            'Ownership persistence failed; the process may be untracked.'
                        }
                        return [pscustomobject]@{
                            success = $false
                            message = ('Gyro-S did not pass startup checks. PID ' + $script:GyroStartProcessId + ' was left running because no stop was authorized. ' + $ownershipMessage)
                        }
                    }
                    if ($script:GyroStopAuthorizationRequired) {
                        return [pscustomobject]@{
                            success = $false
                            requiresGyroStopAuthorization = $true
                            message = 'A Gyro-S ownership record exists and may represent a running process. Starting this model could stop it.'
                        }
                    }
                    $s.active = $oldActive
                    Save-State $s
                    return [pscustomobject]@{ success = $false; message = 'The backend did not pass ownership and readiness checks; the previous active selection was kept.' }
                }
                $route = Get-Route
                if ($route -and [string]$route.model -eq [string]$m.id -and [int]$route.port -eq (Get-ModelBackendPort $m)) {
                    $s.active = $m.id
                    try { Save-State $s } catch {
                        return [pscustomobject]@{
                            success = $false
                            message = ($m.label + ' is running and routed, but the active selection could not be saved: ' + $_.Exception.Message + ' Refresh status before retrying.')
                        }
                    }
                    return [pscustomobject]@{ success = $true; message = ($m.label + ' is healthy and routed through the Panda API.') }
                }
                $s.active = $oldActive
                Save-State $s
                return [pscustomobject]@{ success = $false; message = 'The model did not become the routed model; the previous active selection was kept.' }
                } finally {
                    Exit-BackendLifecycleLock $mutex
                }
            }
            'stop' {
                $backendsStopped = Stop-PandaEngine -AuthorizeGyroStop:$AuthorizeGyroStop
                if ($backendsStopped) {
                    return [pscustomobject]@{ success = $true; message = 'Panda API and verifiably owned backends stopped.' }
                }
                if ($script:GyroStopAuthorizationRequired) {
                    return [pscustomobject]@{
                        success = $false
                        requiresGyroStopAuthorization = $true
                        message = 'A Gyro-S ownership record exists and may represent a running process. Stopping Panda Engine could stop it.'
                    }
                }
                return [pscustomobject]@{ success = $false; message = 'Stop incomplete: API and/or an owned backend could not be confirmed stopped; unowned listeners were left untouched.' }
            }
            default {
                return [pscustomobject]@{ success = $false; message = ('Unknown GUI action: ' + $Action) }
            }
        }
    } catch {
        return [pscustomobject]@{ success = $false; message = $_.Exception.Message }
    }
}

if ($GuiAction) {
    $result = Invoke-GuiAction $GuiAction $ModelId $Context $GameMode -AuthorizeGyroStop:$AuthorizeGyroStop
    $result | ConvertTo-Json -Depth 12 -Compress
    return
}

$s = Get-State
Ensure-Links
# A previous session may have ended without Q: finish the pending restore first.
if (-not $DryRun) { Restore-OpenCodeConfig }
Start-Router | Out-Null
if (-not $s.firstRunDone) {
    Write-Host ''
    Write-Host 'First run - Panda Engine setup'
    Write-Host 'Select the models to download, separated by commas (e.g. 1,3,4).'
    Write-Host '  A = all    N = skip download'
    for ($i=1; $i -le $script:cat.models.Count; $i++) { Write-Host ("  " + $i + " " + $script:cat.models[$i-1].label) }
    $answer = Read-Host 'Your choice'
    if ($answer -match '^[Aa]$') { $answer = ((1..$script:cat.models.Count) -join ',') }
    if ($answer -notmatch '^[Nn]$') {
        foreach ($n in ($answer -split ',')) {
            $idx = 0
            if ([int]::TryParse($n.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $script:cat.models.Count) {
                $m = $script:cat.models[$idx-1]
                $installed = Ensure-Model $m
                if ($installed -and $m.kind -ne 'gyro') {
                    $tmp = @($s.downloaded) + @($m.id); $s.downloaded = @($tmp | Select-Object -Unique)
                }
            }
        }
    }
    $s.firstRunDone = $true
    if ($s.downloaded.Count -gt 0) { $s.active = $s.downloaded[0] }
    $s = Update-ConsoleState @{ firstRunDone = $true; active = $s.active } @($s.downloaded) -ActiveOnlyIfEmpty
    Write-Host 'Setup saved. This screen will not appear again.'
}
if ($AutoStart -and $s.active) {
    $null = Start-ModelFromConsole (Find-Model $s.active) $s
    return
}
while ($true) {
    Show-Menu $s
    $c = Read-Host 'Choice'
    switch -Regex ($c) {
        '^\d+$' {
            $idx = [int]$c - 1
            if ($idx -lt 0 -or $idx -ge $script:cat.models.Count) { Write-Host 'Unknown choice.'; break }
            $m = $script:cat.models[$idx]
            $s = Update-ConsoleState @{ active = $m.id }
            if (-not (Test-Model $m)) { Write-Host 'Not installed yet.'; $yn = Read-Host 'Download now? (y/N)'; if ($yn -eq 'y' -or $yn -eq 'Y') { $installed = Ensure-Model $m; if ($installed -and $m.kind -ne 'gyro') { $s = Update-ConsoleState @{} @($m.id) } } }
            else { $yn = Read-Host 'Start it now? (y/N)'; if ($yn -eq 'y' -or $yn -eq 'Y') { $null = Start-ModelFromConsole $m $s } }
        }
        '^[Dd]$' {
            Write-Host 'Select models to (re)download, separated by commas, or A for all:'
            foreach ($i in 1..$script:cat.models.Count) { Write-Host ("  $i " + $script:cat.models[$i-1].label) }
            $ans = Read-Host 'Your choice'
            if ($ans -match '^[Aa]$') { $ans = ((1..$script:cat.models.Count) -join ',') }
            foreach ($n in ($ans -split ',')) {
                $idx = 0
                if ([int]::TryParse($n.Trim(), [ref]$idx) -and $idx -ge 1 -and $idx -le $script:cat.models.Count) {
                    $m = $script:cat.models[$idx-1]
                    $installed = Ensure-Model $m
                    if ($installed -and $m.kind -ne 'gyro') { $s = Update-ConsoleState @{} @($m.id) }
                }
            }
        }
        '^[Ss]$' {
            $m = Find-Model $s.active
            if ($m) { $null = Start-ModelFromConsole $m $s } else { Write-Host 'No active model. Pick a model number first.' }
        }
        '^[Gg]$' { Toggle-GameMode $s }
        '^[Oo]$' { Start-OpenCode (Find-Model $s.active) }
        '^[Cc]$' { Install-OpenCodeLayer }
        '^[Rr]$' { $s = Update-ConsoleState @{ firstRunDone = $false }; Write-Host 'First-run setup will repeat on next launch.'; break }
        '^[Xx]$' {
            $stopped = Stop-PandaEngine -AuthorizeGyroStop:$AuthorizeGyroStop
            if ($script:GyroStopAuthorizationRequired -and -not $AuthorizeGyroStop) {
                $answer = Read-Host 'A Gyro-S ownership record may represent a running process. Explicitly authorize stopping it? (y/N)'
                if ($answer -in @('y','Y')) { $stopped = Stop-PandaEngine -AuthorizeGyroStop }
            }
            if ($stopped) { Write-Host 'Panda API and verifiably owned backends stopped.' } else { Write-Host 'Panda stop incomplete: API and/or an owned backend could not be confirmed stopped; unowned listeners were left untouched.' }
        }
        '^[Qq]$' { Restore-OpenCodeConfig; return }
        default { Write-Host 'Unknown choice.' }
    }
}
