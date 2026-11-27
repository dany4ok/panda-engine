# Sarcina D — joc tip Vampire Survivors (Three.js local, offline)

Implementeaza TOATE TODO-urile din `game/core.js` si `game/scene.js`.
Three.js e vendor-izat in `vendor/three.module.min.js` (nu depindem de CDN).

## Specificatie mecanici (core.js)

- `xpNeeded(level) = 10 + (level-1)*5`.
- `Player.gainXp(n)`: aduna xp; cat timp `xp >= xpNeeded(level)`, scade si
  creste level-ul; returneaza numarul de level-up-uri.
- `Player.takeDamage(n)`: `hp = max(0, hp-n)`, returneaza hp-ul.
- `Enemy(id,hp,speed)` cu `x=0,y=0`; `update(dt,px,py)` muta inamicul spre
  (px,py) cu `speed*dt` pe directia normalizata.
- `spawnWave(n)`: `n` inamici cu id `e<n>_<i>`, `hp = 10+2*n`, `speed = 50+n`,
  `x = 200+i*20`, `y = 100+i*10`.
- `nearestEnemy(enemies,px,py)`: inamicul cu distanta patratica minima sau null.
- `tryAttack(now,last,cooldown)`: true daca `now-last >= cooldown`.
- `applyUpgrade(player,name)`: `damage` +5, `speed` +20, `maxhp` +20 si hp +20;
  nume necunoscut -> throw.
- `Game.update(dt)`:
  1. `time += dt`; daca `time >= (wave+1)*30`: `wave++`, adauga `spawnWave(wave)`,
     push `"wave:<n>"` in `events`.
  2. fiecare inamic `update(dt, player.x, player.y)`.
  3. inamici la distanta < 15 de player: `player.takeDamage(1)`, eliminati, push `"hit"`.
  4. daca `tryAttack(time, lastAttack, 0.5)`: tinta = `nearestEnemy`; daca tinta
     si distanta <= 150: `target.hp -= player.damage`, `lastAttack = time`, push `"attack"`.
  5. inamici cu `hp <= 0`: eliminati, `player.gainXp(5)`, push `"kill"`.

## Specificatie vizuala (scene.js + index.html)

- Scene Three.js cu renderer, camera, player mesh si mesh-uri pentru inamici.
- HUD actualizeaza `#hp`, `#xp`, `#lv` din `game.player`.
- Bucla foloseste `requestAnimationFrame` si apeleaza `game.update(dt)`.
- `renderer.render(scene, camera)` in fiecare frame.

Verifica: `node --test` (testele tale, daca vrei) si deschide `index.html`
intr-un browser pentru a confirma randarea. Nu adauga dependente.
