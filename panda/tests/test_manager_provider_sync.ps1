# Behavioral test for Sync-OpenCodeConfig.
# Runs the real function extracted from panda.ps1 against a fixture config that
# contains both managed and foreign providers.
$ErrorActionPreference = 'Stop'
$pandaDir = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
$manager = Get-Content -LiteralPath (Join-Path $pandaDir 'panda.ps1') -Raw -Encoding UTF8
$catalog = Get-Content -LiteralPath (Join-Path $pandaDir 'catalog.json') -Raw -Encoding UTF8 | ConvertFrom-Json

function Get-FunctionSource([string]$Source, [string]$Marker) {
    $start = $Source.IndexOf($Marker)
    if ($start -lt 0) { throw "Missing function: $Marker" }
    $open = $Source.IndexOf('{', $start)
    $depth = 0
    for ($i = $open; $i -lt $Source.Length; $i++) {
        if ($Source[$i] -eq '{') { $depth++ }
        elseif ($Source[$i] -eq '}') {
            $depth--
            if ($depth -eq 0) { return $Source.Substring($start, $i - $start + 1) }
        }
    }
    throw "Unclosed function: $Marker"
}

$temp = Join-Path $env:TEMP ('panda-provider-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $temp | Out-Null
try {
    $cfgPath = Join-Path $temp 'opencode.json'
    $backupMarker = Join-Path $temp 'backup.json'
    $fixture = [ordered]@{
        providers = [ordered]@{
            ninfer       = @{ settings = @{ baseURL = 'http://old-local' } }
            'panda-mini' = @{ settings = @{ baseURL = 'http://old-local' } }
            panda        = @{ settings = @{ baseURL = 'http://old-local' } }
            strata       = @{ settings = @{ baseURL = 'http://strata-local' } }
            polystrata   = @{ settings = @{ baseURL = 'http://poly-local' } }
            ollama       = @{ settings = @{ baseURL = 'http://127.0.0.1:11434/v1' } }
        }
    }
    $fixture | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    @{ backup = 'none' } | ConvertTo-Json | Set-Content -LiteralPath $backupMarker -Encoding UTF8

    $script:OpenCodeCfg = $cfgPath
    $script:OCBackupPath = $backupMarker
    $script:OCV1Home = Join-Path $temp 'v1home'
    $script:OCV1Data = Join-Path $temp 'v1data'
    $script:cat = $catalog
    $DryRun = $false
    function Backup-OpenCodeConfig { return $true }
    function Write-OpenCodeV1Config { }

    Invoke-Expression (Get-FunctionSource $manager 'function Sync-OpenCodeConfig($m) {')
    $result = Sync-OpenCodeConfig $null
    if (-not $result) { throw 'Sync-OpenCodeConfig returned false' }

    $after = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $api = 'http://127.0.0.1:' + [string]$catalog.ports.api + '/v1'
    foreach ($name in @('ninfer', 'panda-mini', 'panda')) {
        if ($after.providers.$name.settings.baseURL -ne $api) { throw "$name was not repointed to $api" }
    }
    foreach ($name in @('strata', 'polystrata', 'ollama')) {
        if ($after.providers.$name.settings.baseURL -eq $api) { throw "$name was wrongly repointed" }
    }
    Write-Host 'PASS: Sync-OpenCodeConfig repointed only catalog-managed providers'

    Invoke-Expression (Get-FunctionSource $manager 'function Test-FilePrefix([string]$Path, [byte[]]$Sample) {')
    $samplePath = Join-Path $temp 'sample.bin'
    [System.IO.File]::WriteAllBytes($samplePath, [byte[]](1, 2, 3, 4, 5, 6, 7, 8))
    if (-not (Test-FilePrefix $samplePath ([byte[]](1, 2, 3, 4)))) { throw 'matching byte prefix was rejected' }
    if (Test-FilePrefix $samplePath ([byte[]](9, 2, 3, 4))) { throw 'mismatched byte prefix was accepted' }
    Write-Host 'PASS: Test-FilePrefix accepts a matching remote prefix and rejects a mismatch'
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
