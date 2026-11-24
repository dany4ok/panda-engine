param(
  [Parameter(Mandatory=$true)][string]$Out,
  [string]$Root = 'C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench'
)
$ErrorActionPreference = 'Stop'
$lines = @()
$lines += "# Evaluator hashes - frozen before batch2 execution"
$lines += "# $((Get-Date).ToUniversalTime().ToString('o'))"
Get-ChildItem (Join-Path $Root 'tasks') -Recurse -File -Include 'evaluate.py','hidden_test.mjs','hidden_extra.py','check_atlas.py' | Sort-Object FullName | ForEach-Object {
  $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  $rel = $_.FullName.Replace($Root + '\', '')
  $lines += "$h  $rel"
}
$lines | Out-File -FilePath $Out -Encoding utf8
"WROTE $Out ($($lines.Count - 2) files)"
