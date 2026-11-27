# Sarcina A — programare simpla

Implementeaza functia `slugify(text)` in `string_utils.py`.

Comportament cerut:
- convertește textul la lowercase;
- fiecare secvență de caractere non-alfanumerice devine un singur `-`;
- elimină `-` de la început și de la sfârșit;
- păstrează literele unicode (`ă`, `â`, `î`, `ș`, `ț`, `Ü`, `é` etc. sunt alfanumerice);
- pentru text gol returnează `""`.

Exemple: `"Hello, World!" -> "hello-world"`, `"  Multe   spatii!!  " -> "multe-spatii"`,
`"ăâîșț GPS" -> "ăâîșț-gps"`, `"---trim---" -> "trim"`.

Reguli:
- Nu modifica `truncate` sau alte functii existente.
- Nu adauga dependente si nu crea fisiere noi.
- Nu este necesar sa scrii teste.
