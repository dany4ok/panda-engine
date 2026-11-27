# HARNESS — Benchmark A/B: Gyro-S vs MiniCPM-V ca agent principal

> NOTA pentru snapshotul public: `$root`/calea `C:\Users\x1p\AppData\Local\Temp\opencode\gyro-mini-bench`
> de mai jos este specifica masinii originale. Adaptati-o la directorul in care ati copiat
> acest repo (`benchmarks/`); scripturile harness-ului se afla in `benchmarks/scripts/`.

Scope: 6 sarcini (A-F), aceeasi cerinta pentru ambele modele, sesiuni OpenCode reale
prin CLI (`opencode run`), evaluare independenta determinista dupa executie.

NU se modifica in timpul probei: configul global OpenCode, proiectele reale, agentii globali.
Singura exceptie e pasul 0 de mai jos (pregatirea configului), inainte de rulare.
NU se atinge workspace-ul concurent `...\Temp\opencode\ab-bench`.

## Modele

| Slot | ID OpenCode | Endpoint | Config |
|---|---|---|---|
| Gyro-S | `panda/gyro-gyro-s` | http://127.0.0.1:8081/v1 | global `~/.config/opencode/opencode.json` (trebuie sa contina providerul `panda`) |
| MiniCPM | `panda-mini/minicpm-v-4.7-35b-a3b-q4_k_m` | http://127.0.0.1:8081/v1 | `config/mini.opencode.json` copiat in `<work>/.opencode/opencode.json` |

Asimetrie necesara si documentata: MiniCPM primeste un config LOCAL de workspace
(`panda-mini`), chiar si dupa pasul 0 in care configul global contine acelasi provider;
scopul e ca fiecare rulare sa foloseasca identitatea si endpointul explicite ale
harness-ului. Gyro-S foloseste configul global. Agentii (reviewer etc.) si
permisiunile raman identice (mostenite din global). Niciunui model nu i se da
variant de reasoning (configul MiniCPM nu defineste variante) -> ambele ruleaza default.

## Ordine si izolare

- Batch 1: Gyro-S apoi MiniCPM. Batch 2 (daca timpul permite): MiniCPM apoi Gyro-S.
- Intre loturi se schimba ordinea (alternare), conform cerintei.
- Fiecare proba porneste din `tasks/<X>/seed` copiat curat in
  `results/<batch>/<model>/*/<X>/work`.
- Subagenti: in batch1 NU au fost dezactivati (Gyro 28, Mini 4) — limitare
  confirmata in RAPORT_FINAL.txt. In batch2 au fost DEZACTIVATI pentru ambele
  modele prin `config/gyro_nosub.opencode.json` si `config/mini_nosub.opencode.json`
  ({action:subagent, resource:*, effect:deny}), iar toate cele 12 metrics.json
  au 0 apeluri subagent. Verificarea independenta s-a facut dupa, prin
  evaluator determinist, nu prin subagenti.
- Prompt identic pentru toate cele 12+ run-uri (vedeti `run_probe.ps1`).

## Metrici colectate

- `wall_ms`: timp total pana la iesirea procesului.
- `ttft_ms`:proxy — delta dintre primul eveniment si prima bucata de text asistent
  (din `--format json`); daca evenimentele nu au timestamp, se marcheaza `null`.
- `tokens`: input / output / reasoning / cache_read / cache_write (din `usage`).
- `tool_calls`: numar de evenimente de apel instrument; `tool_names`: histograma.
- `time_in_tools_ms`: suma intervalelor dintre evenimente adiacente de instrument daca
  timestampurile exista, altfel `null`.
- `repair_attempts`: numar de secvente edit->shell(test) detectate in istoricul
  evenimentelor (heuristica, marcata ca atare).
- `vram_max_mib`, `vram_avg_mib`: sampler `nvidia-smi` la 2 s in timpul runului.
- `ram_peak_gb`: peak working set al procesului opencode + copii (best-effort).
- `eval.json`: rezultatul evaluatorului independent (criterii fixate inainte,
  cu doua corectii post-rulare documentate in EVALUATOR_CHANGELOG.txt).
- `exit_code`, `timed_out`.

## Criterii de evaluare (fixate inainte, cu exceptiile din EVALUATOR_CHANGELOG.txt)

Pentru fiecare sarcina evaluatorul verifica:
1. cerinte indeplinite corect (teste ascunse, nu cred claims-urile modelului);
2. teste automate trecute (inclusiv testele scrise de model);
3. buguri ramase (teste ascunse care esueaza);
4. buguri noi (regresiuni in zone.neatinse, comparativ cu seed-ul);
5. calitatea integrarii (teste care traverseaza modulele);
6. rezolvarea erorilor fara interventie (run-ul e non-interactiv, deci: 0 interventii;
   se masoara numarul de incercari de reparare);
7. calitate vizuala (doar D si E: evaluatorul face verificare STATICA a
   wiring-ului + integritate determinista a assetului. In batch2 Gyro a facut
   SI capturi provenientiate + pixel-match, cerute de REQUIREMENT.md; Mini nu
   le-a facut. Asimetria e documentata in RAPORT_FINAL_BATCH2.txt);
8. modificari inutile (numar de fișiere modificate fata de seed, exclusiv cele necesare);
9. finalizare (evaluatorul decide, nu modelul);
10. rezilienta (timeout, exit code, erori de instrument).

Raportul final foloseste `REPORT_TEMPLATE.txt` si calculeaza diferente procentuale reale.

## Rulare (cand slotul e liber)

`swap_model.ps1` si configul `gyro-mini-bench` sint **legacy** (loader extern Strata pe
47831 si vechi paths `Desktop\Panda`); nu mai pornesc backend-urile curente. Fluxul
suportat foloseste Panda Engine insusi:

```powershell
# Ruleaza din arborele curent al proiectului (configurile si scripturile actualizate).
$root = 'C:\Users\x1p\Desktop\panda engine\benchmarks'
# 0) configul global trebuie sa contina modelul panda/gyro-gyro-s.
#    Metoda sigura: copiaza config\opencode.json peste
#    ~/.config/opencode/opencode.json. Optiunea O din consola doar repointa
#    provideri deja existenti; nu adauga providerul sau modelul lipsa.
# 1) selecteaza si porneste modelul din GUI (Model Library -> Start) sau:
#    panda.exe --console   -> S   (activeaza modelul)
# 2) ruleaza cele 6 probe prin API-ul unificat de pe 8081
foreach ($t in 'A','B','C','D','E','F') {
  powershell -ExecutionPolicy Bypass -File "$root\scripts\run_probe.ps1" `
    -Model 'panda/gyro-gyro-s' -Task $t -Batch batch1 -Root $root
}
# 3) repeta pentru MiniCPM dupa selectarea/pornirea lui in Panda Engine
foreach ($t in 'A','B','C','D','E','F') {
  powershell -ExecutionPolicy Bypass -File "$root\scripts\run_probe.ps1" `
    -Model 'panda-mini/minicpm-v-4.7-35b-a3b-q4_k_m' -Task $t -Batch batch1 -Root $root
}
# 4) evaluare independenta + raport
powershell -ExecutionPolicy Bypass -File "$root\scripts\evaluate_all.ps1" -Root $root -Batch batch1
python "$root\scripts\build_report.py" --root $root --batch batch1
```

## Limitari cunoscute

- CLI: se foloseste V2 din aplicatia desktop
  `C:\Users\x1p\AppData\Local\Programs\ai.opencode.desktop\resources\opencode-cli.exe`
  (v2.3.2). CLI-ul V1 instalat prin npm nu poate citi configul V2 si nu poate
  inregistra providerii locali, deci a fost respins. Configul global NU a fost
  modificat in timpul runurilor (pregatirea din pasul 0 e facuta o singura data, inainte
  de rulare). V2 `run` nu are `--dir`, deci runnerul face `Push-Location` in workdir.
- MiniCPM e folosit in prezent de testul concurent; GPU-ul e plin. Rularea se face
  DOAR dupa eliberarea slotului (decizia utilizatorului: "Astept, apoi rulez").
- `ttft_ms` si `time_in_tools_ms` depind de formatul evenimentelor `--format json`;
  parserul e tolerant si marcheaza `null` cand datele nu exista. Nu inventam valori.
- Sarcina E: instrument de generare vizuala nu e disponibil agentilor benchmark-ului;
  folosim ACELASI atlas PNG pentru ambele modele si raportam limitarea.
- Sarcina D: folosim Three.js local (vendor), deci nu depindem de CDN/offline.
