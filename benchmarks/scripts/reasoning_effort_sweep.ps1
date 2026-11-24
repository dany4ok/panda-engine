# Reproducible reasoning_effort sweep for inkling-2-mini (NInfer).
# Graded, batched, multi-run. See benchmarks/BENCHMARK-ink-reasoning-effort-1h.txt.
param(
  [string]$BaseUrl = 'http://127.0.0.1:8080/v1',
  [string]$ApiKey = 'ninfer-local-token',
  [string]$Model = 'inkling-2-mini',
  [int]$Runs = 4,
  [int]$MaxTokens = 16384
)

$ErrorActionPreference = 'Continue'

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
$batches = @($problems[0..7], $problems[8..15], $problems[16..22])

function Grade-Batch([string]$txt, $set) {
  $map = @{}
  foreach ($m in [regex]::Matches($txt, '(?m)^\s*\**\s*(\d+)\s*[\)\.]\s*\**\s*(.*)$')) {
    $map[[int]$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
  }
  $wrong = @()
  foreach ($p in $set) {
    $a = ''
    if ($map.ContainsKey($p.n)) { $a = $map[$p.n] }
    if ($a -notmatch $p.p) { $wrong += "$($p.n):[$($a -replace '\s+',' ')]" }
  }
  return ,$wrong
}

foreach ($v in @('low','medium','high','xhigh','max')) {
  $tot = 0; $out = 0; $rea = 0; $wrong = @(); $trunc = 0
  foreach ($run in 1..$Runs) {
    foreach ($b in $batches) {
      $qs = ($b | ForEach-Object { "$($_.n)) $($_.q)" }) -join "`n"
      $body = @{
        model = $Model
        messages = @(
          @{ role='system'; content=$sys },
          @{ role='user'; content="Raspunde la fiecare. O linie per raspuns, format N) raspuns.`n$qs" }
        )
        reasoning_effort = $v
        max_tokens = $MaxTokens
      } | ConvertTo-Json -Depth 6
      $sw = [Diagnostics.Stopwatch]::StartNew()
      try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post `
          -Headers @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' } `
          -Body $body -TimeoutSec 600
        $sw.Stop()
        $u = $r.usage; $c = $r.choices[0]
        $w = Grade-Batch ([string]$c.message.content) $b
        $tot += $sw.ElapsedMilliseconds
        $out += $u.completion_tokens
        if ($u.completion_tokens_details) { $rea += $u.completion_tokens_details.reasoning_tokens }
        if ($c.finish_reason -eq 'length') { $trunc++ }
        $wrong += $w
      } catch {
        $sw.Stop(); $tot += $sw.ElapsedMilliseconds; $wrong += 'ERR'
      }
    }
  }
  $answers = $problems.Count * $Runs
  $score = $answers - $wrong.Count
  '{0} SCORE={1}/{2} WRONG={3} MS={4} OUT={5} REASON={6} TRUNC={7}' -f `
    $v, $score, $answers, ($wrong -join ' | '), $tot, $out, $rea, $trunc
}
