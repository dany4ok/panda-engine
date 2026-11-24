param([int]$ParentPid, [int]$Port, [string]$Csv)

$prevTok = $null; $prevSec = $null; $prevPrompt = $null; $prevPSec = $null
if (-not (Test-Path -LiteralPath $Csv)) { Add-Content -LiteralPath $Csv -Value 'time,gen_tokens,gen_tps,prompt_tps' }

while (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) {
    Start-Sleep -Seconds 10
    try {
        $r = Invoke-WebRequest -Uri ("http://127.0.0.1:{0}/metrics" -f $Port) -UseBasicParsing -TimeoutSec 3
        $c = $r.Content
        $tok  = [double]([regex]::Match($c, 'llamacpp:tokens_predicted_total\s+([\d.]+)').Groups[1].Value)
        $sec  = [double]([regex]::Match($c, 'llamacpp:tokens_predicted_seconds_total\s+([\d.]+)').Groups[1].Value)
        $prm  = [double]([regex]::Match($c, 'llamacpp:prompt_tokens_total\s+([\d.]+)').Groups[1].Value)
        $psec = [double]([regex]::Match($c, 'llamacpp:prompt_seconds_total\s+([\d.]+)').Groups[1].Value)

        if ($null -ne $prevTok -and $tok -gt $prevTok) {
            $dTok = $tok - $prevTok
            $dSec = [Math]::Max(0.001, $sec - $prevSec)
            $dPr  = $prm - $prevPrompt
            $dPS  = [Math]::Max(0.001, $psec - $prevPSec)
            $line = '{0:yyyy-MM-dd HH:mm:ss},{1},{2},{3}' -f (Get-Date), [int]$dTok, [math]::Round($dTok/$dSec,1), [math]::Round($dPr/$dPS,1)
            Add-Content -LiteralPath $Csv -Value $line
        }
        $prevTok = $tok; $prevSec = $sec; $prevPrompt = $prm; $prevPSec = $psec
    } catch { }
}
