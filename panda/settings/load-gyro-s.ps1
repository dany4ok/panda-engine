param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'

$Root      = 'http://127.0.0.1:47831'
$Model     = 'gyro-gyro-s'
$StrataExe = 'C:\Users\x1p\Desktop\Strata AI\Strata\strata-desktop.exe'
$LogPath   = 'C:\Users\x1p\Desktop\Strata AI\Strata\load-gyro-s.log'

try { $Host.UI.RawUI.WindowTitle = 'Gyro-S (la cerere)' } catch {}

# Ascunde fereastra Strata in tray (WM_CLOSE; cu tray:true in shell-prefs,
# inchiderea ferestrei nu opreste aplicatia, ci o lasa in zona de notificari).
if (-not ('StrataWindow' -as [type])) {
    Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public class StrataWindow {
    public delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] public static extern int GetWindowThreadProcessId(IntPtr h, out int pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, IntPtr wp, IntPtr lp, uint flags, uint timeout, out IntPtr res);
}
'@
}

$script:trayReady = $true
$script:startedGui = $false
# Buget total ~115 s (cerinta: max ~2 minute). Hostul ~50 s + loadul ~50 s
# lasa putina marja, deci nu mai asteptam 15 minute in bucla de load.
$script:deadline = (Get-Date).AddSeconds(115)

function Hide-StrataWindow {
    $pids = @(Get-Process -Name 'strata-desktop' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return $false }
    $windows = New-Object System.Collections.Generic.List[IntPtr]
    $callback = [StrataWindow+EnumProc] {
        param($handle, $lparam)
        $owner = 0
        [void][StrataWindow]::GetWindowThreadProcessId($handle, [ref]$owner)
        if (($pids -contains $owner) -and [StrataWindow]::IsWindowVisible($handle)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][StrataWindow]::GetWindowText($handle, $sb, 256)
            $title = $sb.ToString()
            # Numai fereastra principala (titlu care incepe cu "Strata"); celelalte
            # ferestre sunt helperi (iconita tray, IME) si nu trebuie inchise.
            # Pattern ASCII: un en-dash literal ar fi decodat gresit de PS 5.1.
            if ($title -like 'Strata*') { $windows.Add($handle) }
        }
        return $true
    }
    [void][StrataWindow]::EnumWindows($callback, [IntPtr]::Zero)
    if ($windows.Count -eq 0) { return $false }
    foreach ($handle in $windows) {
        if (-not [StrataWindow]::IsWindowVisible($handle)) { continue }
        $result = [IntPtr]::Zero
        [void][StrataWindow]::SendMessageTimeout($handle, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero, 0x0002, 800, [ref]$result)
    }
    Start-Sleep -Milliseconds 200
    $stillVisible = @($windows | Where-Object {
        [StrataWindow]::IsWindow($_) -and [StrataWindow]::IsWindowVisible($_)
    })
    if ($stillVisible.Count -eq 0) {
        Log 'Fereastra Strata a fost ascunsa in tray.'
        return $true
    }
    Log 'Fereastra Strata inca e vizibila; mai incerc o data.'
    return $false
}

# Minimizare sigura in faza de startup: ShowWindow(SW_MINIMIZE) nu inchide
# aplicatia, deci nu riscam sa o oprim inainte sa-si initializeze tray-ul.
function Minimize-StrataWindow {
    $pids = @(Get-Process -Name 'strata-desktop' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return $false }
    $windows = New-Object System.Collections.Generic.List[IntPtr]
    $callback = [StrataWindow+EnumProc] {
        param($handle, $lparam)
        $owner = 0
        [void][StrataWindow]::GetWindowThreadProcessId($handle, [ref]$owner)
        if (($pids -contains $owner) -and [StrataWindow]::IsWindowVisible($handle)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][StrataWindow]::GetWindowText($handle, $sb, 256)
            if ($sb.ToString() -like 'Strata*') { $windows.Add($handle) }
        }
        return $true
    }
    [void][StrataWindow]::EnumWindows($callback, [IntPtr]::Zero)
    foreach ($handle in $windows) { [void][StrataWindow]::ShowWindow($handle, 6) }
    if ($windows.Count -gt 0) { return $true }
    return $false
}

function Test-StrataWindowVisible {
    $pids = @(Get-Process -Name 'strata-desktop' -ErrorAction SilentlyContinue | ForEach-Object { $_.Id })
    if ($pids.Count -eq 0) { return $false }
    $visible = $false
    $callback = [StrataWindow+EnumProc] {
        param($handle, $lparam)
        $owner = 0
        [void][StrataWindow]::GetWindowThreadProcessId($handle, [ref]$owner)
        if (($pids -contains $owner) -and [StrataWindow]::IsWindowVisible($handle)) {
            $sb = New-Object System.Text.StringBuilder 256
            [void][StrataWindow]::GetWindowText($handle, $sb, 256)
            if ($sb.ToString() -like 'Strata*') { $script:foundVisible = $true }
        }
        return $true
    }
    $script:foundVisible = $false
    [void][StrataWindow]::EnumWindows($callback, [IntPtr]::Zero)
    return $script:foundVisible
}

function Hide-Once {
    # Daca tray-ul nu e activ, WM_CLOSE ar putea inchide aplicatia: nu trimitem.
    if (-not $script:trayReady) { return $false }
    return Hide-StrataWindow
}

function Ensure-TrayHidden {
    $attempts = if ($script:startedGui) { 6 } else { 1 }
    for ($i = 0; $i -lt $attempts; $i++) {
        if (Hide-Once) { return }
        if ($i -lt ($attempts - 1)) { Start-Sleep -Seconds 2 }
    }
}

function Log([string]$Message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Message
    Write-Host $line
    try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch {}
}

function Get-NativeState([int]$TimeoutSec = 20) {
    Invoke-RestMethod -Uri "$Root/api/native?refresh=1" -TimeoutSec $TimeoutSec
}

function Wait-ForHost([int]$Attempts = 1, [int]$TimeoutSec = 10) {
    for ($i = 0; $i -lt $Attempts; $i++) {
        try { return (Get-NativeState -TimeoutSec $TimeoutSec) } catch { Start-Sleep -Seconds 2 }
    }
    return $null
}

# Asteapta hostul, dar MINIMIZEAZA fereastra Strata imediat ce apare.
# Nu trimitem WM_CLOSE aici: inainte ca tray-ul sa fie initializat, WM_CLOSE
# ar iesi din aplicatie si hostul nu ar mai porni niciodata.
function Wait-ForHostAndMinimize([int]$DeadlineSeconds = 100) {
    # Nu depasim niciodata bugetul global de ~115 s, chiar daca aceasta
    # functie e chemata de mai multe ori (faze diferite de recuperare).
    $remaining = ($script:deadline - (Get-Date)).TotalSeconds
    if ($remaining -le 0) { return $null }
    $seconds = [Math]::Min($DeadlineSeconds, [int]$remaining)
    $deadline = (Get-Date).AddSeconds($seconds)
    $lastNotice = (Get-Date).AddSeconds(-20)
    while ((Get-Date) -lt $deadline) {
        [void](Minimize-StrataWindow)
        # La pornire rece, /api/native?refresh=1 poate dura ~7 s (hardware refresh).
        try { return (Get-NativeState -TimeoutSec 12) } catch { Start-Sleep -Seconds 1 }
        if ((Get-Date) -gt $lastNotice) {
            Log '  Strata Control inca nu raspunde; se pregateste hostul ...'
            $lastNotice = Get-Date
        }
    }
    return $null
}

Log 'Pornesc verificarea Strata / Gyro-S.'

# Citim setarea tray inainte de orice pornire, ca sa stim daca e sigur sa
# trimitem WM_CLOSE (cu tray:false, inchiderea ferestrei opreste aplicatia).
try {
    $prefs = Get-Content -LiteralPath 'C:\Users\x1p\AppData\Local\Strata\shell-prefs.json' -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($prefs.tray -ne $true) {
        $script:trayReady = $false
        try {
            Invoke-RestMethod -Uri "$Root/api/shell/prefs" -Method Post -Body '{"tray":true}' -ContentType 'application/json' -TimeoutSec 20 | Out-Null
            Log 'Setarea "tray" a fost activata; se aplica la urmatorul start. Fereastra nu e inchisa in aceasta runda.'
        } catch {
            Log 'EROARE: nu pot activa setarea "tray". Reporneste Strata si activeaz-o manual in Settings.'
        }
    }
} catch {
    $script:trayReady = $false
    Log 'Nu pot citi shell-prefs.json; nu ascund fereastra in aceasta runda.'
}

# Verificare rapida doar daca GUI-ul exista; daca nu exista, hostul nu poate
# fi sus, asa ca evitam un timeout inutil de ~8 s.
$guiWasRunning = @(Get-Process -Name 'strata-desktop' -ErrorAction SilentlyContinue).Count -gt 0
$state = $null
if ($guiWasRunning) { $state = Wait-ForHost 1 }
if (-not $state) {
    Log 'Strata Control nu raspunde pe 47831.'
    $running = @(Get-Process -Name 'strata-desktop' -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        # Nici GUI-ul, nici hostul: pornim imediat si ascundem fereastra
        # inainte ca hostul sa fie gata (altfel apare popup pe desktop).
        Log 'Pornesc strata-desktop.exe ...'
        if (Test-Path -LiteralPath $StrataExe) { Start-Process -FilePath $StrataExe; $script:startedGui = $true }
        $state = Wait-ForHostAndMinimize
    } else {
        # GUI-ul e sus, dar hostul cazut: minimizam fereastra, ii mai dam
        # timp, apoi il repornim daca nu si-a revenit.
        [void](Minimize-StrataWindow)
        Log 'GUI-ul Strata e deschis, dar hostul lipseste. Astept circa 40 s inainte de repornire ...'
        $state = Wait-ForHostAndMinimize 80
        if (-not $state) {
            Log 'Repornesc strata-desktop.exe (hostul nu si-a revenit) ...'
            if (Test-Path -LiteralPath $StrataExe) { Start-Process -FilePath $StrataExe; $script:startedGui = $true }
            $state = Wait-ForHostAndMinimize
        }
    }
    if (-not $state) {
        Log 'EROARE: Strata Control nu a pornit. Deschide Strata manual o data.'
        Start-Sleep -Seconds 1
        exit 1
    }
    Log 'Strata Control a pornit.'
}

# Daca fereastra era deja deschisa (sau tocmai a pornit), o ascundem in tray.
Ensure-TrayHidden

$ready = @($state.instances) | Where-Object { $_.model -eq $Model -and $_.status -eq 'ready' } | Select-Object -First 1
if ($ready) {
    Log "Gyro-S e deja incarcat si gata (port $($ready.port)). Nu fac nimic."
    Start-Sleep -Seconds 4
    exit 0
}

if ($CheckOnly) {
    Log 'Verificare OK: hostul e disponibil, Gyro-S nu e incarcat in acest moment.'
    Start-Sleep -Seconds 4
    exit 0
}

Log 'Cer load pentru gyro-gyro-s in Strata ...'
Log 'Atentie: loadul cu multiple:false va descarca celelalte modele Strata active.'
$payload = @{
    kind = 'load'
    args = @{ model = $Model; multiple = $false; vision = 'yes' }
} | ConvertTo-Json -Depth 5

$jobId = $null
try {
    $started = Invoke-RestMethod -Uri "$Root/api/native/operations" -Method Post -Body $payload -ContentType 'application/json' -TimeoutSec 60
    $jobId = $started.id
    Log "Operatia $jobId a fost acceptata. Astept ready (poate dura ~1 min) ..."
} catch {
    $postError = $_
    # Un al doilea click, sau un load pornit din GUI, poate refuza POST-ul:
    # nu dam eroare, ci urmarim jobul de load deja in curs (nu orice job).
    $existing = $null
    try {
        $cur = Get-NativeState
        $existing = @($cur.jobs) | Where-Object {
            $_.kind -eq 'load' -and $_.model -eq $Model -and $_.state -notin @('done', 'error', 'cancelled')
        } | Select-Object -First 1
    } catch {}
    if ($existing) {
        $jobId = $existing.id
        Log "Exista deja un load in curs ($jobId); il urmaresc pe acesta."
    } else {
        $detail = $postError.Exception.Message
        $bodyText = ''
        try { $bodyText = [string]$postError.ErrorDetails.Message } catch {}
        if ($detail -match '409' -or $bodyText -match 'request|cereri|in curs') {
            Log 'EROARE: Strata are cereri in curs. Incheie-le si reapasa shortcutul.'
        } else {
            Log "EROARE la POST /api/native/operations: $detail $bodyText"
        }
        Start-Sleep -Seconds 1
        exit 1
    }
}

$deadline = $script:deadline
$lastLog = (Get-Date).AddSeconds(-20)
$ok = $false
$failed = $false

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    try { $st = Get-NativeState } catch { continue }

    $job = @($st.jobs) | Where-Object { $_.id -eq $jobId } | Select-Object -First 1
    $inst = @($st.instances) | Where-Object { $_.model -eq $Model } | Select-Object -First 1

    if ($job -and $job.state -in @('error', 'cancelled')) {
        Log "EROARE: $($job.summary)"
        $failed = $true
        break
    }
    if ($inst -and $inst.status -eq 'ready' -and $job -and $job.state -eq 'done') {
        Log "Gyro-S e gata (port $($inst.port), stare $($inst.status))."
        $ok = $true
        break
    }
    if ((Get-Date) -gt $lastLog) {
        $brief = if ($job -and $job.summary) { $job.summary } else { 'se pregateste ...' }
        Log "  inca se incarca: $brief"
        $lastLog = Get-Date
    }
}

if ($ok) {
    # O singura incercare, apoi verificare post-hoc (fara retry-uri costisitoare).
    [void](Hide-Once)
    if (Test-StrataWindowVisible) { Log 'AVERTISMENT: fereastra Strata e inca vizibila.' }
    Log 'GATA. OpenCode foloseste deja strata/gyro-gyro-s.'
    Start-Sleep -Seconds 1
    exit 0
}
if ($failed) {
    Log 'Incarcarea a esuat. Detalii in strata-desktop / log.'
    Start-Sleep -Seconds 1
    exit 1
}
Log 'EROARE: timeout dupa ~115 s (bugetul de 2 minute).'
Start-Sleep -Seconds 1
exit 1
