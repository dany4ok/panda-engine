# FIXES

- stats: `mean` a împărțit la len(vals)-1 în loc de len(vals); `median` nu sortează vals și nu calculează mediana corectă pentru lungimi par/impare; `percentile` a folosit int(p/100 * len(vals)) în loc de int(p/100 * (len(vals)-1)).
- median: același modul stats — sortezare lipsă și index simplu pe o listă nesortată (pentru lungimi par/impare, lipsește mijlocul).
- percentile: același modul stats — index greșit (folosește len(vals) în loc de len(vals)-1), ducând la index din afara listei sau valoare greșită.
- report: `summarize` a citit cheia "value" în loc de "score" și nu a tratat lista goală (mean ar fi lansat eroare) — acum returneaza {'count': 0, 'total': 0, 'avg': 0}.
- cli: `main` a ignorat primul argument (argv[1:]) și nu a citit toate argumentele; acum sumă toate argumentele și afișează suma float.
- help: același modul cli — lipsea tratarea lui `--help`; acum se afișează "usage: cli.py <numbers>" și se returneaza 0.
