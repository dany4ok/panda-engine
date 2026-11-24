param(
  [Parameter(Mandatory=$true)][string]$ApiModel,
  [Parameter(Mandatory=$true)][string]$Variant,
  [string]$BaseUrl = 'http://127.0.0.1:8080/v1',
  [string]$ApiKey = 'ninfer-local-token',
  [string]$Label = ''
)
$headers = @{ Authorization = "Bearer $ApiKey"; 'Content-Type' = 'application/json' }
$snippets = @(
 'def f(nums): return sum(nums)/len(nums) if nums else 0',
 'def f(x, items=[]): items.append(x); return items',
 'def f(s): return s == s[::-1]',
 'def f(nums):
    for n in nums:
        if n < 0: nums.remove(n)
    return nums',
 'def f(n): return n % 2 == 0',
 'def f(n): return 1 if n <= 1 else n * f(n-2)'
)
$expected = @('OK','BUG','OK','BUG','OK','BUG')
$q = 'Pentru fiecare dintre cele 6 functii, spune DOAR "OK" daca e corecta sau "BUG" daca are o greseala. Raspunde cu exact 6 linii in format "1) OK", "2) BUG", fara explicatii.' + "`n`n"
for($i=0;$i -lt $snippets.Count;$i++){ $q += "$($i+1)) " + ($snippets[$i] -replace "`n"," ") + "`n" }
$body = @{ model=$ApiModel; messages=@(@{role='user';content=$q}); reasoning_effort=$Variant; max_tokens=4096 } | ConvertTo-Json -Depth 6
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
  $r=Invoke-RestMethod -Uri "$BaseUrl/chat/completions" -Method Post -Headers $headers -Body $body -TimeoutSec 600
  $sw.Stop(); $txt=[string]$r.choices[0].message.content
  $map=@{}; foreach($m in [regex]::Matches($txt,'(?m)^\s*(\d+)\)\s*(OK|BUG)\b')){ $map[[int]$m.Groups[1].Value]=$m.Groups[2].Value }
  $wrong=@(); for($i=1;$i -le 6;$i++){ $a=''; if($map.ContainsKey($i)){$a=$map[$i]}; if($a -ne $expected[$i-1]){$wrong+="${i}:[$a]"} }
  '{0} {1} REVIEW={2}/6 WRONG={3} MS={4}' -f $Label,$Variant,(6-$wrong.Count),($wrong -join ' | '),$sw.ElapsedMilliseconds
}catch{ $sw.Stop(); '{0} {1} REVIEW=ERR {2}' -f $Label,$Variant,$_.Exception.Message }
