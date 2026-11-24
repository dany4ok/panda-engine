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
# dedicated 10-problem set used by the output-cap probe (includes the photo riddle as #4)
$capProblems = @(
 @{n=1; q='grila 3x3 de patrate unitare: total patrate'; p='\b14\b'},
 @{n=2; q='melc 10m, urca 3m ziua, aluneca 2m noaptea, zile'; p='\b8\b'},
 @{n=3; q='sirul 1,11,21,1211,111221, urmatorul'; p='\b312211\b'},
 @{n=4; q='tatal acestui om e fiul tatalui meu, cine e in fotografie'; p='\bfiu|\bson|\bbaiat\b'},
 @{n=5; q='5 masini, 5 obiecte, 5 minute; 100 masini, 100 obiecte, minute'; p='\b5\b'},
 @{n=6; q='8 bile, una mai grea, cantariri pe balanta'; p='\b2\b'},
 @{n=7; q='e 91 prim? da sau nu'; p='\bnu\b|\bno\b'},
 @{n=8; q="in cuvantul 'eleven', cate litere e?"; p='\b3\b'},
 @{n=9; q='triunghi 3,4,5, aria'; p='\b6\b'},
 @{n=10; q='azi marti, peste 100 de zile'; p='\bjoi\b|\bthursday\b'}
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
      $sw=[Diagnostics.Stopwatch]::StartNew()
      try {
        $x = Invoke-Chat $v $messages $MaxTokens
        $u = $x.usage; $c = $x.choice
        $wrong += Grade-Batch ([string]$c.message.content) $b
        $tot += $x.ms; $out += $u.completion_tokens
        if ($u.completion_tokens_details) { $rea += $u.completion_tokens_details.reasoning_tokens }
        if ($c.finish_reason -eq 'length') { $trunc++ }
      } catch {
        # a failed batch means every answer in it is wrong, not just one; keep its elapsed time
        $sw.Stop(); $tot += $sw.ElapsedMilliseconds
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
  $rea = 0; if ($x.usage.completion_tokens_details) { $rea = $x.usage.completion_tokens_details.reasoning_tokens }
  'COUNT {0} OK={1}/200 LINES={2} DUPS={3} MS={4} OUT={5} REASON={6} FIN={7}' -f `
    $v, $ok, $nums.Count, $dups, $x.ms, $x.usage.completion_tokens, $rea, $x.choice.finish_reason
}

# --- method 4: needle in ~128k haystack, cold then warm cache ---
$half = 'The quick brown fox jumps over the lazy dog. '
$long = ($half*5400) + ' CODUL SECRET ESTE ZX7-QM42. ' + ($half*5400) + "`n`nIgnora tot textul de mai sus. Care este codul secret? Raspunde doar cu codul."
foreach ($v in $variants) {
  $x = Invoke-Chat $v @(@{role='user';content=$long}) 1024
  'NEEDLE {0} PASS=cold HIT={1} IN={2} CACHED={3} MS={4} FIN={5}' -f `
    $v, ([string]$x.choice.message.content -match 'ZX7.QM42'), $x.usage.prompt_tokens, $x.usage.prompt_tokens_details.cached_tokens, $x.ms, $x.choice.finish_reason
  $w = Invoke-Chat $v @(@{role='user';content=$long}) 1024
  'NEEDLE {0} PASS=warm HIT={1} IN={2} CACHED={3} MS={4} FIN={5}' -f `
    $v, ([string]$w.choice.message.content -match 'ZX7.QM42'), $w.usage.prompt_tokens, $w.usage.prompt_tokens_details.cached_tokens, $w.ms, $w.choice.finish_reason
}

# --- method 5: output-cap footgun, dedicated 10-problem set at 6144 vs 16384 ---
foreach ($v in @('xhigh','max')) {
  foreach ($cap in @(6144,16384)) {
    $qs = ($capProblems | ForEach-Object { "$($_.n)) $($_.q)" }) -join "`n"
    $messages = @(@{role='system';content=$sys}, @{role='user';content="Raspunde la fiecare. O linie per raspuns, format N) raspuns.`n$qs"})
    $x = Invoke-Chat $v $messages $cap
    $wrong = Grade-Batch ([string]$x.choice.message.content) $capProblems
    $rea = 0; if ($x.usage.completion_tokens_details) { $rea = $x.usage.completion_tokens_details.reasoning_tokens }
    'CAP {0} cap={1} SCORE={2}/10 WRONG={3} OUT={4} REASON={5} FIN={6} MS={7} CONTENT_EMPTY={8}' -f `
      $v, $cap, (10-$wrong.Count), ($wrong -join ' | '), $x.usage.completion_tokens, $rea, $x.choice.finish_reason, $x.ms, ([string]::IsNullOrWhiteSpace([string]$x.choice.message.content))
  }
}

# --- method 6: prefill throughput and engine limit ---
foreach ($n in @(1000,3500,7000,10800)) {
  $txt = ($half * $n) + "`n`nIgnora textul. Ce este 7*8? Doar numarul."
  $x = Invoke-Chat 'low' @(@{role='user';content=$txt}) 256
  'PREFILL reps={0} IN={1} MS={2} TOKS={3}' -f $n, $x.usage.prompt_tokens, $x.ms, [math]::Round($x.usage.prompt_tokens/($x.ms/1000.0))
}
try {
  $tooLong = ($half * 12500) + "`n`nIgnora textul. Ce este 7*8? Doar numarul."
  $null = Invoke-Chat 'low' @(@{role='user';content=$tooLong}) 64
  'LIMIT reps=12500 ACCEPTED (unexpected)'
} catch {
  'LIMIT reps=12500 REJECTED detail=$($_.ErrorDetails.Message)'
}
