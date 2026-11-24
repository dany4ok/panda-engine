# Sarcina E — assets & UI (sprite atlas + HUD)

Primesti ACELASI asset de test pentru ambele modele: `assets/atlas.png`, un atlas
4 cadre de 16x16 px (0 = idle, 1 = run dreapta, 2 = run stanga, 3 = hurt).
Instrument de generare vizuala NU e disponibil in acest benchmark — limitarea
e raportata explicit; nu modifici atlasul.

Implementeaza in `hud.js`:
- o masina de stari cu starile `idle`, `run`, `hurt`;
- animatie care foloseste TOATE cele 4 cadre (idle -> 0, run -> 1 si 2 alternand,
  hurt -> 3), cu `requestAnimationFrame`;
- actualizarea elementelor `#hp`, `#xp`, `#lv` si a barelor `#hpbar`, `#xpbar`
  dintr-un obiect `state = {hp, maxHp, xp, level}`;
- butonul `#hurt` schimba starea in `hurt` pentru ~0.3s apoi revine la `idle`;
- butonul `#run` comuta intre `idle` si `run`.

Reguli:
- Nu modifica `assets/atlas.png`, `index.html` sau `styles.css`.
- Ruleaza `python check_atlas.py` si confirma că trece.
- Verifica vizual in browser (captura) ca sprite-ul si barele se redeaza.
