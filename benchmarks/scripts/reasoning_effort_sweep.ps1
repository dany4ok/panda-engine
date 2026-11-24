# Reproducible reasoning_effort sweep for inkling-2-mini (NInfer).
# Covers every section of benchmarks/BENCHMARK-ink-reasoning-effort-1h.txt.
param(
  [string]$BaseUrl = 'http://127.0.0.1:8080/v1',
  [string]$ApiKey = 'ninfer-local-token',
  [string]$Model = 'inkling-2-mini',
  [int]$Runs = 4,
  [int]$MaxTokens = 16384
)

$ErrorActionPreference = 'Continue'
$headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }

$problems = @(
 @{n=1;  q='17*23+456'; p='\b847\b'},
 @{n=2;  q='2^10+3^4'; p='\b1105\b'},
 @{n=3;  q='radical din 144'; p='\b12\b'},
 @{n=4;  q='15% din 200'; p='\b30\b'},
 @{n=5;  q='media numerelor 2,4,6,8'; p='\b5\b'},
 @{n=6;  q='suma numerelor 1..100'; p='\b5050\b'},
 @{n=7;  q='111*111'; p='\b12321\b'},
 @{n=8;  q='99^2'; p='\b9801\b'},
 @{n=9;  q='7*8'; p='\b56\b'},
 @{n=10; q='e 91 prim? da sau nu'; p='\bnu\b|\bno\b'},
 @{n=11; q='cate litere r in strawberry'; p='\b3\b'},
 @{n=12; q="In cuvantul 'eleven', cate dintre litere sunt litera e?"; p='\b3\b'},
 @{n=13; q='triunghi cu laturile 3,4,5, aria'; p='\b6\b'},
 @{n=14; q='perimetrul dreptunghiului 3x5'; p='\b16\b'},
 @{n=15; q='azi e marti, ce zi e peste 100 de zile'; p='\bjoi\b|\bthursday\b'},
 @{n=16; q='o batie si o minge costa 1.10; batia costa cu 1.00 mai mult decat mingea. Cat costa mingea?'; p='0[.,]05|\b5\b centi|\b5\b cent'},
 @{n=17; q='melc iesit din fantana de 10m: urca 3m ziua, aluneca 2m noaptea. In cate zile iese?'; p='\b8\b'},
 @{n=18; q='grila 3x3 de patrate unitare: total patrate de toate marimile'; p='\b14\b'},
 @{n=19; q='8 bile, una mai grea: numarul minim de cantariri pe balanta'; p='\b2\b'},
 @{n=20; q='5 masini fac 5 obiecte in 5 minute. 100 masini fac 100 obiecte in cate minute?'; p='\b5\b'},
 @{n=21; q='17 oi, mor toate afara de 9. Cate raman?'; p='\b9\b'},
 @{n=22; q='sirul 1,11,21,1211,111221: urmatorul termen'; p='\b312211\b'},
 @{n=23; q='un om spune: tatal acestui om din fotografie e fiul tatalui meu. Cine e in fotografie?'; p='\bfiu|\bson|\bbaiat\b'}
)
$sys = 'Esti un asistent precise. Raspunde doar cu raspunsul final, scurt, fara explicatii.'
$variants = @('low','medium','high','xhigh','max')
$batches = @($problems[0..7], $problems[8..15], $problems[16..22])

function Invoke-Chat([string]$effort, $messages, [int]$maxTokens) {
  $body = @{ model=$Model; messages=$messages; reasoning_effort=$effort; max_tokens=$maxTokens } | ConvertTo-Json -Depth 8
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $r = Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 600
  $sw.Stop()
  return @{ usage=$r.usage; choice=$r.choices[0]; ms=$sw.ElapsedMilliseconds }
}
function Grade-Batch([string]$txt, $set) {
  $map = @{}
  foreach ($m in [regex]::Matches($txt, '(?m)^\s*\**\s*(\d+)\s*[\)\.]\s*\**\s*(.*)$')) { $map[[int]$m.Groups[1].Value] = $m.Groups[2].Value.Trim() }
  $wrong = @()
  foreach ($p in $set) {
    $a = ''
    if ($map.ContainsKey($p.n)) { $a = $map[$p.n] }
    if ($a -notmatch $p.p) { $wrong += "$($p.n):[$($a -replace '\s+',' ')]" }
  }
  return ,$wrong
}

# --- method 1: batched accuracy, $Runs runs ---
foreach ($v in $variants) {
  $tot=0; $out=0; $rea=0; $wrong=@(); $trunc=0
  foreach ($run in 1..$Runs) {
    foreach ($b in $batches) {
      $qs = ($b | ForEach-Object { "$($_.n)) $($_.q)" }) -join "`n"
      $messages = @(@{role='system';content=$sys}, @{role='user';content="Raspunde la fiecare. O linie per raspuns, format N) raspuns.`n$qs"})
      try {
        $x = Invoke-Chat $v $messages $MaxTokens
        $u = $x.usage; $c = $x.choice
        $wrong += Grade-Batch ([string]$c.message.content) $b
        $tot += $x.ms; $out += $u.completion_tokens
        if ($u.completion_tokens_details) { $rea += $u.completion_tokens_details.reasoning_tokens }
        if ($c.finish_reason -eq 'length') { $trunc++ }
      } catch {
        # a failed batch means every answer in it is wrong, not just one
        $tot += 0
        foreach ($p in $b) { $wrong += "$($p.n):[ERR]" }
      }
    }
  }
  $answers = $problems.Count * $Runs
  'ACC {0} SCORE={1}/{2} WRONG={3} MS={4} OUT={5} REASON={6} TRUNC={7} MS_PER_BATCH={8}' -f `
    $v, ($answers-$wrong.Count), $answers, ($wrong -join ' | '), $tot, $out, $rea, $trunc, [math]::Round($tot/($Runs*3))
}

# --- method 2: one problem per request ---
foreach ($v in $variants) {
  $wrong=@(); $tot=0; $trunc=0
  foreach ($p in $problems) {
    $messages = @(@{role='user';content="Raspunde doar cu raspunsul final, fara explicatii. $($p.q)"})
    try {
      $x = Invoke-Chat $v $messages 8192
      $tot += $x.ms
      if ($x.choice.finish_reason -eq 'length') { $trunc++ }
      if ([string]$x.choice.message.content -notmatch $p.p) { $wrong += "$($p.n):[$($x.choice.message.content -replace '\s+',' ')]" }
    } catch { $wrong += "$($p.n):[ERR]" }
  }
  'SINGLE {0} SCORE={1}/{2} WRONG={3} MS={4} TRUNC={5}' -f $v, ($problems.Count-$wrong.Count), $problems.Count, ($wrong -join ' | '), $tot, $trunc
}

# --- method 3: counting 1..200 (loop probe) ---
foreach ($v in $variants) {
  $messages = @(@{role='user';content='Scrie numerele de la 1 la 200, fiecare pe linia sa, in ordine, fara alte cuvinte.'})
  $x = Invoke-Chat $v $messages 4096
  $nums=@(); foreach ($ln in ([string]$x.choice.message.content -split "`n")) { if ($ln.Trim() -match '^\d+$') { $nums += [int]$ln.Trim() } }
  $ok=0; for ($i=0; $i -lt $nums.Count -and $i -lt 200; $i++) { if ($nums[$i] -eq $i+1) { $ok++ } else { break } }
  $dups = $nums.Count - ($nums | Select-Object -Unique).Count
  'COUNT {0} OK={1}/200 LINES={2} DUPS={3} MS={4} OUT={5} FIN={6}' -f $v, $ok, $nums.Count, $dups, $x.ms, $x.usage.completion_tokens, $x.choice.finish_reason
}

# --- method 4: needle in ~128k haystack ---
$half = 'The quick brown fox jumps over the lazy dog. '
$long = ($half*5400) + ' CODUL SECRET ESTE ZX7-QM42. ' + ($half*5400) + "`n`nIgnora tot textul de mai sus. Care este codul secret? Raspunde doar cu codul."
foreach ($v in $variants) {
  $x = Invoke-Chat $v @(@{role='user';content=$long}) 1024
  'NEEDLE {0} HIT={1} IN={2} CACHED={3} MS={4} FIN={5}' -f `
    $v, ([string]$x.choice.message.content -match 'ZX7.QM42'), $x.usage.prompt_tokens, $x.usage.prompt_tokens_details.cached_tokens, $x.ms, $x.choice.finish_reason
}

# --- method 5: output-cap footgun, 10 problems at 6144 vs 16384 ---
$ten = @($problems[0..9])
foreach ($v in @('xhigh','max')) {
  foreach ($cap in @(6144,16384)) {
    $qs = ($ten | ForEach-Object { "$($_.n)) $($_.q)" }) -join "`n"
    $messages = @(@{role='system';content=$sys}, @{role='user';content="Raspunde la fiecare. O linie per raspuns, format N) raspuns.`n$qs"})
    $x = Invoke-Chat $v $messages $cap
    'CAP {0} cap={1} OUT={2} REASON={3} FIN={4} MS={5} CONTENT_EMPTY={6}' -f `
      $v, $cap, $x.usage.completion_tokens, $x.usage.completion_tokens_details.reasoning_tokens, $x.choice.finish_reason, $x.ms, ([string]::IsNullOrWhiteSpace([string]$x.choice.message.content))
  }
}

# --- method 6: prefill throughput ---
foreach ($n in @(1000,3500,7000,10800)) {
  $txt = ($half * $n) + "`n`nIgnora textul. Ce este 7*8? Doar numarul."
  $x = Invoke-Chat 'low' @(@{role='user';content=$txt}) 256
  'PREFILL reps={0} IN={1} MS={2} TOKS={3}' -f $n, $x.usage.prompt_tokens, $x.ms, [math]::Round($x.usage.prompt_tokens/($x.ms/1000.0))
}
