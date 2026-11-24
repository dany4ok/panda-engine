# Sarcina F — sarcina complexă de agent (investigare → plan → fix → teste → verificare)

Proiectul `report_tool` are o suita de teste care ESUEAZA. `BUGS.md` descrie
simptomele. Trebuie sa:

1. Investighezi cauzele reale (nu doar simptomele).
2. Repari TOATE bugurile astfel incat `python -m unittest discover -v` sa treaca.
3. Nu modifici fisierele din `tests/` (sunt verificate prin hash).
4. Scrii `FIXES.md` cu **cauza radacina** pentru fiecare bug (cate o linie per
   modul: `stats`, `median`, `percentile`, `report`, `cli`, `help`).
5. Pastrezi diff-ul minim: nu refactoriza, nu adauga dependente.
6. Rulezi testele si verifici rezultatul inainte de a termina.

Comportament suplimentar cerut (teste ascunse):
- `percentile` foloseste indexul `int(p/100 * (len(vals)-1))` pe lista sortata.
- `summarize([])` -> `{'count': 0, 'total': 0, 'avg': 0}`.
- `percentile([1,2,3], 0) == 1` si `percentile([1,2,3], 100) == 3`.
- `main(['5'])` afiseaza `5.0`; `main(['-1','2'])` afiseaza `1.0`.
