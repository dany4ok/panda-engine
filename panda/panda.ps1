# Panda Engine - unified launcher for Inkling 2 Mini, MiniCPM-V and Gyro-S.
# PowerShell 5.1 compatible. ASCII messages only.
param([switch]$DryRun, [switch]$ResetState, [switch]$AutoStart)

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Panda Engine' } catch {}

$script:Repo      = Split-Path -Parent $PSScriptRoot
$script:Catalog   = Join-Path $PSScriptRoot 'catalog.json'
$script:StatePath = Join-Path $env:LOCALAPPDATA 'panda-engine\state.json'
$script:cat       = Get-Content -LiteralPath $script:Catalog -Raw -Encoding UTF8 | ConvertFrom-Json
$script:RoutePath = Join-Path $PSScriptRoot 'state\route.json'
$script:RouterPidPath = Join-Path $PSScriptRoot 'state\router.pid'
$script:RouterPy  = Join-Path $script:cat.roots.knownMini '.venv\Scripts\python.exe'
if (-not (Test-Path -LiteralPath $script:RouterPy)) { $script:RouterPy = 'python.exe' }
$script:OpenCodeCfg = Join-Path $env:USERPROFILE '.config\opencode\opencode.json'
$script:OCBackupPath = Join-Path $PSScriptRoot 'state\opencode-backup.json'
$script:OCV1Home = Join-Path $PSScriptRoot 'state\opencode-v1'
$script:OCV1Data = Join-Path $PSScriptRoot 'state\opencode-v1-data'

function Get-State {
    if ($ResetState -and (Test-Path -LiteralPath $script:StatePath)) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $s = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Gyro is loaded on demand by Strata, not downloaded by this launcher.
            $s.downloaded = @($s.downloaded | Where-Object { $_ -ne 'gyro-s' })
            # States written before game mode existed have no gameMode key.
            if ($null -eq $s.PSObject.Properties['gameMode']) { Add-Member -InputObject $s -NotePropertyName gameMode -NotePropertyValue $false }
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
        roots        = @{ inkling = $script:cat.roots.knownInkling; mini = $script:cat.roots.knownMini; gyro = $script:cat.roots.knownGyro }
    }
}
function Save-State($s) {
    $dir = Split-Path -Parent $script:StatePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    ($s | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $script:StatePath -Encoding UTF8
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
function Stop-GameGuard {
    # The guard can restart the server, so it must die before port 8080 is freed.
    $name = Split-Path -Leaf (Get-GameGuardPath 'guard')
    $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('powershell.exe','pwsh.exe') -and $_.CommandLine -and $_.CommandLine -like ('*' + $name + '*')
    })
    foreach ($p in $procs) {
        Write-Host ("  Stopping VRAM game guard (PID " + $p.ProcessId + ")")
        if (-not $DryRun) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
function Stop-MiniBackend {
    # Used when turning game mode off: stop only MiniCPM, never Inkling or Gyro.
    Stop-GameGuard
    $port = [int]$script:cat.ports.mini
    foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
        $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -match 'python') {
            Write-Host ("  Stopping MiniCPM server (PID " + $p.Id + ")")
            if (-not $DryRun) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -in @('strata-poly.exe','strata-vision.exe') -and $_.CommandLine -like '*minicpmv-Q4_K_M*'
    })) {
        Write-Host ("  Stopping MiniCPM engine (PID " + $p.ProcessId + ")")
        if (-not $DryRun) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Clear-Route
}
function Toggle-GameMode($s) {
    $m = Find-Model $s.active
    if (-not $m -or $m.kind -ne 'mini') {
        Write-Host '  Game mode applies to MiniCPM only. Select it first with its menu number.'
        return
    }
    if (-not $s.gameMode -and -not (Test-GameGuard)) {
        Write-Host '  ERROR: game mode files are missing from the Poly-strata install:'
        foreach ($key in @('guard','fastConfig','cpuConfig')) { Write-Host ("    " + (Get-GameGuardPath $key)) }
        return
    }
    $s.gameMode = -not [bool]$s.gameMode
    Save-State $s
    Write-Host ("  MiniCPM game mode: " + $(if ($s.gameMode) {'ON (adaptive VRAM guard)'} else {'OFF (normal GPU load)'}))
    if ($s.gameMode) {
        Write-Host '  Takes effect on START; the guard switches GPU <-> RAM/SSD when VRAM gets tight.'
    } else {
        Stop-MiniBackend
        Write-Host '  Guard stopped (only MiniCPM was affected). Press S to start it in normal mode.'
    }
}
function Set-Route($m, [int]$port) {
    $dir = Split-Path -Parent $script:RoutePath
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $obj = @{ listen = [int]$script:cat.ports.api; port = $port; name = $m.label; model = $m.id }
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
function Get-RouterProcess {
    # Identify the router by what it is, not by a PID file that can go stale.
    foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort ([int]$script:cat.ports.api) -ErrorAction SilentlyContinue)) {
        $proc = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.OwningProcess) -ErrorAction SilentlyContinue
        if ($proc -and $proc.Name -match 'python' -and $proc.CommandLine -like '*router.py*') { return $proc }
    }
    return $null
}
function Test-Router { return [bool](Get-RouterProcess) }
function Start-Router {
    $existing = Get-RouterProcess
    if ($existing) {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:RouterPidPath) | Out-Null
        $existing.ProcessId | Set-Content -LiteralPath $script:RouterPidPath -Encoding UTF8
        return $true
    }
    # Free the port only from something that is NOT our router (an old direct backend).
    foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort ([int]$script:cat.ports.api) -ErrorAction SilentlyContinue)) {
        $p = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $c.OwningProcess) -ErrorAction SilentlyContinue
        if ($p -and $p.Name -match 'ninfer|python|strata') {
            Write-Host ("  Freeing API port from " + $p.Name + " (PID " + $p.ProcessId + ")")
            if (-not $DryRun) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    }
    Start-Sleep -Milliseconds 800
    if ($DryRun) { Write-Host '  [dry-run] would start the Panda API router'; return $true }
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
}
function Stop-Router {
    $r = Get-RouterProcess
    if ($r) {
        Write-Host ("  Stopping Panda API (PID " + $r.ProcessId + ")")
        if (-not $DryRun) { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    Remove-Item -LiteralPath $script:RouterPidPath -Force -ErrorAction SilentlyContinue
    Clear-Route
}
function Get-RemoteInfo($url) {
    $len = [int64]0
    $sha = ''
    $lines = & curl.exe -sIL --max-time 60 $url 2>$null
    foreach ($line in $lines) {
        if ($line -match '^content-length:\s*(\d+)\s*$') { $len = [int64]$Matches[1] }
        if ($line -match '^etag:\s*"([0-9a-fA-F]{64})"') { $sha = $Matches[1].ToLower() }
    }
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
        $ok = $false
        for ($attempt = 1; $attempt -le 2; $attempt++) {
            if ($attempt -eq 2 -and (Test-Path -LiteralPath $part)) { Remove-Item -LiteralPath $part -Force }
            & curl.exe -L --fail --retry 3 -C - -o $part $url
            if ($LASTEXITCODE -eq 0) { $ok = $true; break }
            Write-Host ("  download attempt " + $attempt + " failed (curl exit " + $LASTEXITCODE + ")")
        }
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
function Stop-CurrentEngine([string]$ExceptKind = '') {
    # Stop the VRAM guard first: otherwise it can restart the server while we switch models.
    Stop-GameGuard
    # Backends listen on internal ports; port 8080 belongs to the Panda API router.
    $ports = @([int]$script:cat.ports.infer, [int]$script:cat.ports.mini)
    if ($ExceptKind -ne 'gyro') { $ports += [int]$script:cat.ports.gyro }
    foreach ($port in $ports) {
        foreach ($c in @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)) {
            $p = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
            if ($p -and $p.ProcessName -match 'ninfer|python|strata') {
                Write-Host ("  Stopping " + $p.ProcessName + " (PID " + $p.Id + ") on port " + $port)
                if (-not $DryRun) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            }
            elseif ($p) { Write-Host ("  WARNING: port " + $port + " held by " + $p.ProcessName + "; not touching it.") }
        }
    }
    if ($ExceptKind -eq 'gyro') { return }
    $gyroRoot = $script:cat.roots.knownGyro
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^strata' -and $_.Path -and $_.Path.StartsWith($gyroRoot) })) {
        Write-Host ("  Stopping " + $p.ProcessName + " (PID " + $p.Id + ")")
        if (-not $DryRun) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}
function Start-Model($m, $s) {
    if (-not (Test-Model $m)) {
        Write-Host '  Model is not installed. Use D to download it first.'
        return
    }
    if ($DryRun) { Write-Host ('  [dry-run] would start ' + $m.label); return }
    if (-not (Start-Router)) { return }
    Stop-CurrentEngine $m.kind
    $backendPort = switch ($m.kind) {
        'inkling' { [int]$script:cat.ports.infer }
        'mini'    { [int]$script:cat.ports.mini }
        'gyro'    { [int]$script:cat.ports.gyro }
    }
    switch ($m.kind) {
        'inkling' {
            $cfgPath = Join-Path $script:Repo 'config.json'
            $cfg = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { @{} }
            $cfg.artifact = $m.artifact
            $cfg.context  = [int]$script:cat.ninfer.context
            $cfg.reasoning = $script:cat.ninfer.reasoning
            $cfg.port     = $backendPort
            ($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
            $startPs1 = Join-Path $PSScriptRoot 'legacy\start.ps1'
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:Repo -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $startPs1 + '"'),'-AutoStart') | Out-Null
        }
        'mini' {
            $root = $script:cat.roots.knownMini
            if ($s.gameMode) {
                if (Test-GameGuard) {
                    $guard = Get-GameGuardPath 'guard'
                    Start-Process -FilePath 'powershell.exe' -WorkingDirectory $root -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $guard + '"'),'-Port',[string]$backendPort) | Out-Null
                    Set-Route $m $backendPort
                    Write-Host '  MiniCPM game guard started (adaptive VRAM, internal port ' + $backendPort + ').'
                    Write-Host '  The guard owns its server and switches GPU <-> RAM/SSD when VRAM gets tight.'
                    Write-Host ('  Panda API: http://127.0.0.1:' + $script:cat.ports.api + '/v1  ->  ' + $m.label)
                    return
                }
                Write-Host '  WARNING: game mode files not found; starting MiniCPM in normal mode instead.'
            }
            $python = Join-Path $root '.venv\Scripts\python.exe'
            Start-Process -FilePath $python -WorkingDirectory $root -ArgumentList @('serve\server.py','--engine','strata','--config',$m.serverConfig,'--port',[string]$backendPort) | Out-Null
        }
        'gyro' {
            # Gyro-S runs from Panda's own bundled engine and pack. No Strata desktop.
            $root = $script:cat.roots.knownMini
            $python = Join-Path $root '.venv\Scripts\python.exe'
            Start-Process -FilePath $python -WorkingDirectory $root -ArgumentList @('serve\server.py','--engine','strata','--config',$m.serverConfig,'--port',[string]$backendPort) | Out-Null
        }
    }
    Set-Route $m $backendPort
    Write-Host ('  Panda API: http://127.0.0.1:' + $script:cat.ports.api + '/v1  ->  ' + $m.label + ' (internal ' + $backendPort + ')')
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
    Save-State $s
    Write-Host 'Setup saved. This screen will not appear again.'
}
if ($AutoStart -and $s.active) {
    Start-Model (Find-Model $s.active) $s
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
            $s.active = $m.id; Save-State $s
            if (-not (Test-Model $m)) { Write-Host 'Not installed yet.'; $yn = Read-Host 'Download now? (y/N)'; if ($yn -eq 'y' -or $yn -eq 'Y') { $installed = Ensure-Model $m; if ($installed -and $m.kind -ne 'gyro') { $tmp = @($s.downloaded) + @($m.id); $s.downloaded = @($tmp | Select-Object -Unique) }; Save-State $s } }
            else { $yn = Read-Host 'Start it now? (y/N)'; if ($yn -eq 'y' -or $yn -eq 'Y') { Start-Model $m $s } }
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
                    if ($installed -and $m.kind -ne 'gyro') { $tmp = @($s.downloaded) + @($m.id); $s.downloaded = @($tmp | Select-Object -Unique) }
                }
            }
            Save-State $s
        }
        '^[Ss]$' {
            $m = Find-Model $s.active
            if ($m) { Start-Model $m $s } else { Write-Host 'No active model. Pick a model number first.' }
        }
        '^[Gg]$' { Toggle-GameMode $s }
        '^[Oo]$' { Start-OpenCode (Find-Model $s.active) }
        '^[Cc]$' { Install-OpenCodeLayer }
        '^[Rr]$' { $s.firstRunDone = $false; Save-State $s; Write-Host 'First-run setup will repeat on next launch.'; break }
        '^[Xx]$' { Stop-CurrentEngine; Stop-Router; Write-Host 'Panda API and all backends stopped.' }
        '^[Qq]$' { Restore-OpenCodeConfig; return }
        default { Write-Host 'Unknown choice.' }
    }
}
