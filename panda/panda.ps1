# Panda Engine - unified launcher for Inkling 2 Mini, MiniCPM-V and Gyro-S.
# PowerShell 5.1 compatible. ASCII messages only.
param([switch]$DryRun, [switch]$ResetState, [switch]$AutoStart)

$ErrorActionPreference = 'Stop'
try { $Host.UI.RawUI.WindowTitle = 'Panda Engine' } catch {}

$script:Repo      = Split-Path -Parent $PSScriptRoot
$script:Catalog   = Join-Path $PSScriptRoot 'catalog.json'
$script:StatePath = Join-Path $env:LOCALAPPDATA 'panda-engine\state.json'
$script:cat       = Get-Content -LiteralPath $script:Catalog -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-State {
    if ($ResetState -and (Test-Path -LiteralPath $script:StatePath)) {
        Remove-Item -LiteralPath $script:StatePath -Force
    }
    if (Test-Path -LiteralPath $script:StatePath) {
        try {
            $s = Get-Content -LiteralPath $script:StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Gyro is loaded on demand by Strata, not downloaded by this launcher.
            $s.downloaded = @($s.downloaded | Where-Object { $_ -ne 'gyro-s' })
            return $s
        } catch {}
    }
    return @{
        version      = 1
        firstRunDone = $false
        downloaded   = @()
        active       = ''
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
        'gyro' { return (Test-Path -LiteralPath (Join-Path $script:cat.roots.knownGyro $m.exe)) }
    }
    return $false
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
            Write-Host '  NOTE: the Strata pack/tokenizer in PolyStrata-data must exist; the server config is reused from the current setup.'
            return $true
        }
        'gyro' {
            if (Test-Path -LiteralPath (Join-Path $script:cat.roots.knownGyro $m.exe)) {
                Write-Host '  Strata desktop present. The model itself is downloaded by the loader on first start; nothing to store here.'
                return $true
            }
            Write-Host '  ERROR: Strata desktop not found. Install Strata desktop, then run Panda Engine again.'
            return $false
        }
    }
    return $false
}
function Stop-CurrentEngine([string]$ExceptKind = '') {
    $ports = @(8080, 47831)
    foreach ($port in $ports) {
        if ($ExceptKind -eq 'gyro' -and $port -eq 47831) { continue }
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
    Stop-CurrentEngine $m.kind
    switch ($m.kind) {
        'inkling' {
            $cfgPath = Join-Path $script:Repo 'config.json'
            $cfg = if (Test-Path -LiteralPath $cfgPath) { Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json } else { @{} }
            $cfg.artifact = $m.artifact
            $cfg.context  = [int]$script:cat.ninfer.context
            $cfg.reasoning = $script:cat.ninfer.reasoning
            $cfg.port     = [int]$script:cat.ninfer.port
            ($cfg | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
            $startPs1 = Join-Path $script:Repo 'start.ps1'
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $script:Repo -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $startPs1 + '"'),'-AutoStart') | Out-Null
            Write-Host '  Inkling started: http://127.0.0.1:8080/v1  (ninfer/inkling-2-mini)'
        }
        'mini' {
            $root = $script:cat.roots.knownMini
            $python = Join-Path $root '.venv\Scripts\python.exe'
            Start-Process -FilePath $python -WorkingDirectory $root -ArgumentList @('serve\server.py','--engine','strata','--config',$m.serverConfig,'--port',[string]$m.port) | Out-Null
            Write-Host '  MiniCPM started: http://127.0.0.1:8080/v1  (polystrata-mini/minicpm-v-4.7-35b-a3b-q4_k_m)'
        }
        'gyro' {
            $root = $script:cat.roots.knownGyro
            $loader = Join-Path $root $m.loader
            Start-Process -FilePath 'powershell.exe' -WorkingDirectory $root -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-NoExit','-File',('"' + $loader + '"')) | Out-Null
            Write-Host '  Gyro-S loading via Strata: http://127.0.0.1:47831/v1  (strata/gyro-gyro-s)'
        }
    }
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
    if (-not (Test-Path -LiteralPath $pl)) { Copy-Item (Join-Path $script:Repo 'plugins') $pl -Recurse -Force }
    # Match the live setup: absolute instructions path to the copied rules file.
    $cfgObj = Get-Content -LiteralPath $cfg -Raw -Encoding UTF8 | ConvertFrom-Json
    $cfgObj.instructions = @($rules)
    ($cfgObj | ConvertTo-Json -Depth 100) | Set-Content -LiteralPath $cfg -Encoding UTF8
    Write-Host '  OpenCode layer installed. Model IDs: ninfer/inkling-2-mini, polystrata-mini/minicpm-v-4.7-35b-a3b-q4_k_m, strata/gyro-gyro-s'
}
function Show-Menu($s) {
    Write-Host ''
    Write-Host '============================================================'
    Write-Host '  P A N D A   E N G I N E'
    Write-Host '============================================================'
    $active = Find-Model $s.active
    if ($active) { Write-Host ("  Active model : " + $active.label + "  [" + $(if (Test-Model $active) {'installed'} else {'NOT installed'}) + "]") }
    else { Write-Host '  Active model : none' }
    Write-Host '------------------------------------------------------------'
    foreach ($m in $script:cat.models) { Write-Host ("  " + $m.id.PadRight(16) + " " + $m.label.PadRight(32) + $(if (Test-Model $m) {'[OK]'} else {'[-]'})) }
    Write-Host '------------------------------------------------------------'
    Write-Host '  1 Inkling IQ1_M   2 Inkling Q2_K_XL   3 MiniCPM   4 Gyro-S'
    Write-Host '  D Download/change models    S PORNIRE (start active)'
    Write-Host '  C Install OpenCode layer    R Reset first-run    Q Exit'
    Write-Host '============================================================'
}

$s = Get-State
Ensure-Links
if (-not $s.firstRunDone) {
    Write-Host ''
    Write-Host 'First run - Panda Engine setup'
    Write-Host 'Select the models to download, separated by commas (e.g. 1,3,4).'
    Write-Host '  A = all    N = skip download'
    for ($i=1; $i -le $script:cat.models.Count; $i++) { Write-Host ("  " + $i + " " + $script:cat.models[$i-1].label) }
    $answer = Read-Host 'Your choice'
    if ($answer -match '^[Aa]$') { $answer = '1,2,3,4' }
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
        '^[1-4]$' {
            $m = $script:cat.models[[int]$c - 1]
            $s.active = $m.id; Save-State $s
            if (-not (Test-Model $m)) { Write-Host 'Not installed yet.'; $yn = Read-Host 'Download now? (y/N)'; if ($yn -eq 'y' -or $yn -eq 'Y') { $installed = Ensure-Model $m; if ($installed -and $m.kind -ne 'gyro') { $tmp = @($s.downloaded) + @($m.id); $s.downloaded = @($tmp | Select-Object -Unique) }; Save-State $s } }
            else { $yn = Read-Host 'Start it now? (y/N)'; if ($yn -eq 'y' -or $yn -eq 'Y') { Start-Model $m $s } }
        }
        '^[Dd]$' {
            Write-Host 'Select models to (re)download, separated by commas, or A for all:'
            foreach ($i in 1..$script:cat.models.Count) { Write-Host ("  $i " + $script:cat.models[$i-1].label) }
            $ans = Read-Host 'Your choice'
            if ($ans -match '^[Aa]$') { $ans = '1,2,3,4' }
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
            if ($m) { Start-Model $m $s } else { Write-Host 'No active model. Pick 1-4 first.' }
        }
        '^[Cc]$' { Install-OpenCodeLayer }
        '^[Rr]$' { $s.firstRunDone = $false; Save-State $s; Write-Host 'First-run setup will repeat on next launch.'; break }
        '^[Qq]$' { return }
        default { Write-Host 'Unknown choice.' }
    }
}
