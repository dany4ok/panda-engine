param(
  [Parameter(Mandatory=$true)][string]$Batch,
  [string]$Root = 'C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench'
)
$ErrorActionPreference = 'Stop'
$base = Join-Path $Root "results\$Batch"
Get-ChildItem $base -Directory -Recurse | Where-Object { $_.Name -match '^[A-F]$' } | ForEach-Object {
  $dir = $_.FullName
  $events = Join-Path $dir 'events.jsonl'
  $metrics = Join-Path $dir 'metrics.json'
  if (-not (Test-Path $events) -or -not (Test-Path $metrics)) { return }
  $tmp = Join-Path $dir '_parsed_tmp.json'
  node (Join-Path $Root 'scripts\parse_events.js') $events $tmp | Out-Null
  if (-not (Test-Path $tmp)) { return }
  $p = Get-Content $tmp -Raw -Encoding utf8 | ConvertFrom-Json
  $m = Get-Content $metrics -Raw -Encoding utf8 | ConvertFrom-Json
  foreach ($k in @('events','first_event_ms','last_event_ms','ttft_ms','first_text_ms','tool_calls','tool_names','edit_calls','test_calls','repair_attempts_heuristic','tokens','note')) {
    if ($p.PSObject.Properties.Name -contains $k) {
      $m | Add-Member -NotePropertyName $k -NotePropertyValue $p.$k -Force
    }
  }
  $m | ConvertTo-Json -Depth 8 | Out-File -FilePath $metrics -Encoding utf8
  Remove-Item $tmp -Force
  "$($_.Parent.Name)/$($_.Name): events=$($p.events) tools=$($p.tool_calls) out_tokens=$($p.tokens.output) ttft=$($p.ttft_ms)"
}
