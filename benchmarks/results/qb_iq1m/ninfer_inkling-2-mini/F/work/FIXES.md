stats: mean împartește sume la len(vals)-1 în loc de len(vals) — corectat la len(vals).
median: index de mijloc pe listă nesortată — corectat la listă sortată și medie între cele două elemente centrale pentru par.
percentile: index = int(p/100 * len(vals)) poate depăși bounds — corectat la int(p/100 * (len(vals) - 1)).
report: citește cheia "value" a rândurilor în loc de "score" — corectat la "score"; summarize([]) nu mai suferă excepție (avg = 0).
cli: ignoră primul argument (argv[1:]) și print sum fără float — parsează toate argumentele; --help nu era tratat — adăugat usage + return 0.
help: --help nu afisa usage și nu returna 0 — corectat.
