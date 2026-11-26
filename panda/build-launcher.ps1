# Rebuild panda.exe from panda/panda-launcher.cs with the Panda icon embedded.
# Usage: powershell -File panda/build-launcher.ps1 [-Out <path>]
# Requires the .NET Framework C# compiler (csc.exe), shipped with Windows.
param(
  [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'panda.exe')
)

$root = Split-Path -Parent $PSScriptRoot
$source = Join-Path $PSScriptRoot 'panda-launcher.cs'
$icon = Join-Path $root 'panda.ico'

$csc = Get-ChildItem 'C:\Windows\Microsoft.NET\Framework64' -Filter csc.exe -Recurse -ErrorAction SilentlyContinue |
  Sort-Object FullName -Descending | Select-Object -First 1
if (-not $csc) { throw 'csc.exe not found under C:\Windows\Microsoft.NET\Framework64' }
if (-not (Test-Path -LiteralPath $source)) { throw "missing source: $source" }
if (-not (Test-Path -LiteralPath $icon)) { throw "missing icon: $icon (run panda/make_panda_icon.py first)" }

& $csc.FullName /nologo /target:winexe /win32icon:$icon /out:$Out $source
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }
Write-Output "wrote $Out $((Get-Item -LiteralPath $Out).Length) bytes"
